import Foundation
import LoggingDomain

/// Runs one slot's clone → boot → register → job → power off → delete cycles. Host deadlines
/// recycle wedged guests; registration deadlines require successful runner-list observations.
/// Deletion runs once after both start and any committed recovery have finished.
///
/// There is one lifecycle caller per slot. State shared with bootstrap/status callbacks is
/// protected by `lock`; the runner observer actor owns polling-failure logging state.
public final class VirtualMachineFleetSlot: @unchecked Sendable {
    public let name: String
    public let runnerName: String
    public var status: VirtualMachineFleetSlotStatus {
        lock.withLock { makeStatus() }
    }

    private let baseVirtualMachine: VirtualMachine
    private let runnerObserver: FleetRunnerObserver
    private let guestLogReader: VirtualMachineGuestLogReader?
    private let policy: FleetSlotPolicy
    private let clock: FleetClock
    private let logger: Logger
    private let statusDidChange: @Sendable (VirtualMachineFleetSlotStatus) -> Void

    private let lock = NSLock()
    private var state: FleetSlotState = .idle
    private var stateEnteredAt: Date
    private var cycleStartedAt: Date?
    private var cycleID = UUID()
    private var bootstrappedAt: Date?
    private var hasBeenBusy = false
    private var lastObservation: (status: GitHubActionsRunnerStatus, at: Date)?
    private var runnerIdentity = FleetRunnerIdentity()
    private var revision: UInt64 = 0

    public init(
        name: String,
        runnerName: String,
        baseVirtualMachine: VirtualMachine,
        runnerRegistry: GitHubActionsRunnerRegistry,
        guestLogReader: VirtualMachineGuestLogReader?,
        policy: FleetSlotPolicy,
        clock: FleetClock,
        logger: Logger,
        statusDidChange: @escaping @Sendable (VirtualMachineFleetSlotStatus) -> Void = { _ in }
    ) {
        self.name = name
        self.runnerName = runnerName
        self.baseVirtualMachine = baseVirtualMachine
        self.runnerObserver = FleetRunnerObserver(
            registry: runnerRegistry, runnerName: runnerName, slotName: name, clock: clock, logger: logger
        )
        self.guestLogReader = guestLogReader
        self.policy = policy
        self.clock = clock
        self.logger = logger
        self.statusDidChange = statusDidChange
        self.stateEnteredAt = clock.now
    }

    /// Runs cycles until cancelled, or until `shouldStopAfterCycle` returns `true` between cycles.
    public func run(shouldStopAfterCycle: @escaping @Sendable () async -> Bool) async {
        log(
            "slot started for runner \"\(runnerName)\"; deadlines: boot \(format(policy.bootTimeout)),"
            + " registration \(format(policy.registrationTimeout)), shutdown \(format(policy.shutdownTimeout)),"
            + " lifetime \(format(policy.maximumLifetime)); polling every \(format(policy.pollInterval))"
        )
        while !Task.isCancelled {
            let outcome = await runCycle()
            if Task.isCancelled || outcome == .cancelled {
                break
            }
            if await shouldStopAfterCycle() {
                log("stopping after this cycle as requested")
                break
            }
            if outcome == .failed {
                if await runnerObserver.isAvailable {
                    log("cycle failed; trying again in \(format(policy.retryDelay))")
                }
                do {
                    try await clock.sleep(for: policy.retryDelay)
                } catch {
                    break
                }
            }
        }
        log("slot stopped")
    }

    /// One full cycle: clone, run under the watchdog, delete. Exposed for tests.
    public func runCycle() async -> CycleOutcome {
        // Establish identity before this guest can register, including after an app restart.
        // An API failure postpones cloning; it must not make an old online entry look fresh.
        guard let baseline = await runnerObserver.read() else {
            return Task.isCancelled ? .cancelled : .failed
        }
        beginCycle(baselineID: baseline.id)
        transition(to: .cloning)
        let virtualMachine: VirtualMachine
        do {
            try Task.checkCancellation()
            virtualMachine = try await baseVirtualMachine.clone(named: name)
        } catch {
            logger.error("[slot \(name)] cloning failed: \(error.localizedDescription)")
            transition(to: .idle, reason: "clone failed")
            return Task.isCancelled ? .cancelled : .failed
        }
        var outcome = await runVirtualMachine(virtualMachine)
        // Both the normal and the forced path end here, so the clone is deleted exactly once.
        do {
            // Teardown owns its cancellation independently. Data implementations bound and reap
            // commands, and must verify helpers have exited before deleting the owned directory.
            try await Task.detached { try await virtualMachine.delete() }.value
            log("deleted clone")
        } catch {
            logger.error(
                "[slot \(name)] deleting the clone failed: \(error.localizedDescription);"
                + " the next clone will clean the slot first"
            )
            if outcome == .completed {
                outcome = .failed
            }
        }
        transition(to: .idle)
        return outcome
    }

    /// Called by the cycle's ``FleetSlotCycleObserver`` when the guest's SSH bootstrap completes.
    func didBootstrap(cycleID: UUID) {
        transition(
            to: .bootstrapped,
            from: .booting,
            cycleID: cycleID,
            reason: "SSH bootstrap completed; waiting for runner \"\(runnerName)\" to come online"
        )
    }
}

// MARK: - Running one clone

private extension VirtualMachineFleetSlot {
    private func beginCycle(baselineID: Int?) {
        lock.withLock {
            cycleStartedAt = clock.now
            cycleID = UUID()
            bootstrappedAt = nil
            hasBeenBusy = false
            runnerIdentity.beginCycle(baselineID: baselineID)
            lastObservation = nil
        }
    }

    private func runVirtualMachine(_ virtualMachine: VirtualMachine) async -> CycleOutcome {
        transition(to: .booting)
        let observer = FleetSlotCycleObserver(slot: self, cycleID: lock.withLock { cycleID })
        var exitResult: Result<Void, Error>?
        var didTrip = false
        await withTaskGroup(of: RunEvent.self) { group in
            group.addTask {
                do {
                    try await virtualMachine.start(observer: observer)
                    return .exited(.success(()))
                } catch {
                    return .exited(.failure(error))
                }
            }
            group.addTask {
                .watchdogFinished(tripped: await self.watch(virtualMachine))
            }
            for await event in group {
                switch event {
                case let .exited(result):
                    exitResult = result
                    // The guest is gone: stop the watchdog. A recovery already in progress runs
                    // to completion; cancellation cannot interrupt it.
                    group.cancelAll()
                case let .watchdogFinished(tripped):
                    didTrip = tripped
                    if tripped, exitResult == nil {
                        group.addTask { [clock] in
                            try? await clock.sleep(for: Self.forcedExitGracePeriod)
                            return .forcedExitGraceElapsed
                        }
                    }
                case .forcedExitGraceElapsed:
                    if exitResult == nil {
                        log(
                            "tart run has not returned \(format(Self.forcedExitGracePeriod)) after the forced stop;"
                            + " cancelling it"
                        )
                        group.cancelAll()
                    }
                }
            }
        }
        return finishRun(exitResult: exitResult, didTrip: didTrip)
    }

    private func finishRun(exitResult: Result<Void, Error>?, didTrip: Bool) -> CycleOutcome {
        switch exitResult {
        case .success:
            transition(to: .exited, reason: didTrip ? "tart run returned after the forced stop" : "tart run returned")
        case let .failure(error):
            transition(to: .exited, reason: "tart run ended with an error: \(error.localizedDescription)")
        case nil:
            transition(to: .exited, reason: "tart run did not report an exit")
        }
        if Task.isCancelled {
            return .cancelled
        }
        if didTrip {
            return .forcedStop
        }
        if case .failure = exitResult {
            return .failed
        }
        return .completed
    }
}

// MARK: - Watchdog

private extension VirtualMachineFleetSlot {
    /// Polls and enforces deadlines until the guest exits (the task is cancelled) or a deadline
    /// trips, in which case the guest is forced off before returning `true`.
    private func watch(_ virtualMachine: VirtualMachine) async -> Bool {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: policy.pollInterval)
            } catch {
                return false
            }
            if Task.isCancelled {
                return false
            }
            let observationStartedAt = clock.now
            if needsObservation, let observation = await runnerObserver.read() {
                // A slow pre-deadline request is not evidence of the runner's state after the
                // deadline. Conservatively date successful observations at request start.
                apply(observation, at: observationStartedAt)
            }
            // The guest may have exited during the poll; the group cancels us when it does.
            if Task.isCancelled {
                return false
            }
            if let deadline = trippedDeadline(at: clock.now) {
                // .exited cancels this watcher when tart stop succeeds. Recovery is already
                // committed at this point and must finish helper cleanup before the group exits.
                await Task.detached { await self.recover(virtualMachine, deadline: deadline) }.value
                return true
            }
        }
        return false
    }

    private var needsObservation: Bool {
        let state = lock.withLock { self.state }
        return switch state {
        case .bootstrapped, .registered, .busy, .draining:
            true
        case .idle, .cloning, .booting, .recovering, .exited:
            false
        }
    }

    private func apply(_ rawObservation: GitHubActionsRunnerStatus, at now: Date) {
        let (state, hasBeenBusy, application) = lock.withLock {
            let application = runnerIdentity.observe(rawObservation)
            if application.isFresh {
                self.hasBeenBusy = false
                if case .online(_, isBusy: true) = rawObservation { self.hasBeenBusy = true }
            }
            if let observation = application.status { lastObservation = (observation, now) }
            return (self.state, self.hasBeenBusy, application)
        }
        if let id = application.newlyIgnoredID {
            log("ignoring runner id \(id): the previous guest's registration, not yet replaced")
        }
        guard let observation = application.status else {
            return
        }
        if application.isFresh {
            let next: FleetSlotState
            if case let .online(_, isBusy) = observation {
                next = isBusy ? .busy : .registered
            } else {
                next = .bootstrapped
            }
            transition(to: next, from: state, reason: "observed fresh runner identity \(observation.id ?? 0)")
            return
        }
        guard let next = FleetSlotRules.transition(from: state, on: observation, hasBeenBusy: hasBeenBusy) else {
            return
        }
        transition(to: next.state, from: state, reason: next.reason)
    }

    private func trippedDeadline(at now: Date) -> FleetSlotRules.Deadline? {
        let context: FleetSlotRules.DeadlineContext? = lock.withLock {
            guard let cycleStartedAt else {
                return nil
            }
            return FleetSlotRules.DeadlineContext(
                state: state,
                stateEnteredAt: stateEnteredAt,
                cycleStartedAt: cycleStartedAt,
                bootstrappedAt: bootstrappedAt,
                lastObservation: lastObservation,
                runnerName: runnerName,
                policy: policy,
                now: now
            )
        }
        return context.flatMap(FleetSlotRules.deadline(in:))
    }

    private func recover(_ virtualMachine: VirtualMachine, deadline: FleetSlotRules.Deadline) async {
        transition(to: .recovering, reason: "\(deadline.trip) deadline tripped: \(deadline.detail)")
        let recoveryStartedAt = clock.now
        if let guestLogReader {
            do {
                let guestLog = try await withTimeout(Self.guestLogTimeout) {
                    try await guestLogReader.readGuestLog(of: virtualMachine)
                }
                logger.info("[slot \(name)] guest diagnostics before the forced stop:\n\(guestLog)")
            } catch {
                log("could not read the guest log before the forced stop: \(error.localizedDescription)")
            }
        }
        log("forcing the virtual machine to stop")
        await virtualMachine.forceStop()
        log("forced stop finished after \(format(clock.now.timeIntervalSince(recoveryStartedAt)))")
    }
}

// MARK: - State bookkeeping

private extension VirtualMachineFleetSlot {
    /// Moves to `newState`, unless `from` is given and the slot has moved on in the meantime.
    private func transition(
        to newState: FleetSlotState,
        from: FleetSlotState? = nil,
        cycleID expectedCycleID: UUID? = nil,
        reason: String? = nil
    ) {
        let now = clock.now
        let result: (status: VirtualMachineFleetSlotStatus, message: String)? = lock.withLock {
            guard newState != state, from == nil || from == state,
                  expectedCycleID == nil || expectedCycleID == cycleID else {
                return nil
            }
            let previousState = state
            let timeInPreviousState = now.timeIntervalSince(stateEnteredAt)
            state = newState
            revision += 1
            stateEnteredAt = now
            if newState == .bootstrapped, bootstrappedAt == nil {
                bootstrappedAt = now
            }
            if newState == .busy {
                hasBeenBusy = true
            }
            var message = "\(previousState.rawValue) -> \(newState.rawValue)"
            message += " (\(format(timeInPreviousState)) in \(previousState.rawValue)"
            if let cycleStartedAt {
                message += ", \(format(now.timeIntervalSince(cycleStartedAt))) since clone started"
            }
            message += ")"
            if let reason {
                message += ": \(reason)"
            }
            if newState == .idle {
                cycleStartedAt = nil
            }
            return (makeStatus(), message)
        }
        guard let result else {
            return
        }
        log(result.message)
        statusDidChange(result.status)
    }

    private func makeStatus() -> VirtualMachineFleetSlotStatus {
        VirtualMachineFleetSlotStatus(
            name: name,
            runnerName: runnerName,
            state: state,
            stateEnteredAt: stateEnteredAt,
            cycleStartedAt: cycleStartedAt,
            revision: revision
        )
    }

    private func log(_ message: String) {
        logger.info("[slot \(name)] \(message)")
    }
}
