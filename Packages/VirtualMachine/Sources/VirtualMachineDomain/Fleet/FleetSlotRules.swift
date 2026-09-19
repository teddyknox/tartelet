import Foundation

/// The pure decision tables of a fleet slot: where an observation of the runner list moves the
/// slot, and which deadline has tripped. Kept free of I/O and time sources so they read as tables.
enum FleetSlotRules {
    struct Transition: Equatable {
        let state: FleetSlotState
        let reason: String
    }

    /// The state to move to when `observation` is made in `state`, if any.
    static func transition(
        from state: FleetSlotState,
        on observation: GitHubActionsRunnerStatus,
        hasBeenBusy: Bool
    ) -> Transition? {
        switch (state, observation) {
        case let (.bootstrapped, .online(id, isBusy)):
            return Transition(state: isBusy ? .busy : .registered, reason: "runner is online (guest-reported id \(id))")
        case (.registered, .online(_, isBusy: true)):
            return Transition(state: .busy, reason: "runner picked up a job")
        case (.registered, .unregistered):
            return Transition(
                state: .draining,
                reason: "runner is no longer registered (its job finished between polls, or it was removed)"
            )
        case (.registered, .offline):
            return Transition(state: .draining, reason: "runner went offline")
        case (.busy, .online(_, isBusy: false)):
            return Transition(state: .draining, reason: "ephemeral runner is idle after its job")
        case (.busy, .unregistered):
            return Transition(state: .draining, reason: "runner unregistered after its job")
        case (.busy, .offline):
            return Transition(state: .draining, reason: "runner went offline during its job")
        case (.draining, .online(_, isBusy: true)):
            return Transition(state: .busy, reason: "runner reports busy again")
        case (.draining, .online(_, isBusy: false)) where !hasBeenBusy:
            return Transition(state: .registered, reason: "runner is back online")
        default:
            return nil
        }
    }

    struct DeadlineContext {
        let state: FleetSlotState
        let stateEnteredAt: Date
        let cycleStartedAt: Date
        let bootstrappedAt: Date?
        let lastObservation: (status: GitHubActionsRunnerStatus, at: Date)?
        let runnerName: String
        let policy: FleetSlotPolicy
        let now: Date
    }

    struct Deadline: Equatable {
        let trip: VirtualMachineFleetSlot.DeadlineTrip
        let detail: String
    }

    /// The deadline that has tripped in `context`, if any. State deadlines come before the
    /// lifetime cap, which is the last resort.
    static func deadline(in context: DeadlineContext) -> Deadline? {
        if let deadline = stateDeadline(in: context) {
            return deadline
        }
        let lifetime = context.now.timeIntervalSince(context.cycleStartedAt)
        guard context.state == .registered,
              lifetime > context.policy.maximumLifetime.timeInterval,
              let observation = context.lastObservation,
              context.now.timeIntervalSince(observation.at) < context.policy.pollInterval.timeInterval,
              case .online(_, isBusy: false) = observation.status else {
            return nil
        }
        return Deadline(
            trip: .lifetimeExceeded,
            detail: "clone has existed for \(format(lifetime)), longer than the lifetime cap of"
                + " \(format(context.policy.maximumLifetime)) (state \(context.state.rawValue))"
        )
    }
}

private extension FleetSlotRules {
    private static func stateDeadline(in context: DeadlineContext) -> Deadline? {
        let policy = context.policy
        let inState = context.now.timeIntervalSince(context.stateEnteredAt)
        switch context.state {
        case .booting:
            guard inState > policy.bootTimeout.timeInterval else {
                return nil
            }
            return Deadline(
                trip: .bootTimeout,
                detail: "guest did not complete its SSH bootstrap within \(format(policy.bootTimeout))"
                    + " (\(format(inState)) since tart run started)"
            )
        case .bootstrapped:
            // Only an observation taken after the deadline can trip it, so that an API outage
            // spanning the deadline never does.
            guard let bootstrappedAt = context.bootstrappedAt, let observation = context.lastObservation else {
                return nil
            }
            let sinceBootstrap = observation.at.timeIntervalSince(bootstrappedAt)
            guard sinceBootstrap >= policy.registrationTimeout.timeInterval, !observation.status.isOnline else {
                return nil
            }
            return Deadline(
                trip: .registrationTimeout,
                detail: "runner \"\(context.runnerName)\" was \(observation.status.summary)"
                    + " \(format(sinceBootstrap)) after bootstrap (deadline \(format(policy.registrationTimeout)))"
            )
        case .draining:
            guard inState > policy.shutdownTimeout.timeInterval else {
                return nil
            }
            return Deadline(
                trip: .shutdownTimeout,
                detail: "guest did not power off within \(format(policy.shutdownTimeout)) of its runner finishing"
                    + " (\(format(inState)) in draining)"
            )
        case .idle, .cloning, .registered, .busy, .recovering, .exited:
            return nil
        }
    }

    private static func format(_ duration: Duration) -> String {
        FleetDurationFormatter.string(from: duration)
    }

    private static func format(_ interval: TimeInterval) -> String {
        FleetDurationFormatter.string(from: interval)
    }
}

extension GitHubActionsRunnerStatus {
    var isOnline: Bool {
        if case .online = self {
            return true
        }
        return false
    }

    var summary: String {
        switch self {
        case .unregistered:
            "not registered"
        case let .online(_, isBusy):
            isBusy ? "online and busy" : "online and idle"
        case .offline:
            "offline"
        }
    }
}
