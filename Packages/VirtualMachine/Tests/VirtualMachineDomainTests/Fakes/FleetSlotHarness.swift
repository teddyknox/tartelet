import Foundation
import VirtualMachineDomain

enum FleetSlotHarnessError: Error, CustomStringConvertible {
    case timedOut(String)
    case noClone

    var description: String {
        switch self {
        case let .timedOut(waitingFor):
            "Timed out waiting for \(waitingFor)"
        case .noClone:
            "No clone has been created yet"
        }
    }
}

/// Fixtures and helpers shared by the fleet slot tests.
final class FleetSlotHarness {
    let recorder = FakeVirtualMachineRecorder()
    let registry = FakeRunnerRegistry()
    let identityReader = FakeGuestIdentityReader()

    init() { registry.recorder = recorder }
    let guestLogReader = FakeGuestLogReader()
    let clock = ManualClock()
    let logger = SpyLogger()
    let policy = FleetSlotPolicy(
        bootTimeout: .seconds(300),
        registrationTimeout: .seconds(300),
        shutdownTimeout: .seconds(180),
        maximumLifetime: .seconds(3 * 60 * 60),
        pollInterval: .seconds(30),
        retryDelay: .seconds(10)
    )
    private(set) lazy var base = FakeVirtualMachine(name: "base", recorder: recorder)

    func makeSlot(
        policy: FleetSlotPolicy? = nil,
        deregistrationTimeout: Duration = .seconds(20),
        statusDidChange: @escaping @Sendable (VirtualMachineFleetSlotStatus) -> Void = { _ in }
    ) -> VirtualMachineFleetSlot {
        VirtualMachineFleetSlot(
            name: "base-1",
            runnerName: "runner 1",
            baseVirtualMachine: base,
            runnerRegistry: registry,
            identityReader: identityReader,
            guestLogReader: guestLogReader,
            policy: policy ?? self.policy,
            clock: clock,
            logger: logger,
            deregistrationTimeout: deregistrationTimeout,
            statusDidChange: statusDidChange
        )
    }

    var events: [String] {
        recorder.events
    }

    func latestClone() throws -> FakeVirtualMachine {
        guard let clone = recorder.clones.last else {
            throw FleetSlotHarnessError.noClone
        }
        return clone
    }

    /// Wakes the watchdog for one poll and waits until it has dealt with it: it is either asleep
    /// again or the cycle has ended.
    func tick(_ slot: VirtualMachineFleetSlot) async throws {
        let generation = try await clock.advanceWhenSleeping(by: 30)
        try await waitUntil("the watchdog to settle") {
            self.clock.sleepGeneration > generation || slot.status.state == .idle
        }
    }

    func waitForState(_ slot: VirtualMachineFleetSlot, _ state: FleetSlotState) async throws {
        try await waitUntil("state \(state.rawValue)") { slot.status.state == state }
        if state == .booting {
            try await waitUntil("start observer to be installed") {
                self.recorder.clones.last?.hasStarted == true
            }
        }
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw FleetSlotHarnessError.timedOut(description)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
