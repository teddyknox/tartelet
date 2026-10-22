import GitHubDomain
import VirtualMachineDomain
import XCTest

/// The host slept under the fleet (2026-10-21/22: a lid-closed MacBook that dark-woke for seconds
/// at a time). Deadlines must count only awake time, and a deadline must never win against GitHub
/// reporting the guest busy.
final class HostSleepRegressionTests: XCTestCase {
    private var harness = FleetSlotHarness()

    override func setUp() {
        super.setUp()
        harness = FleetSlotHarness()
    }

    func testBootDeadlineCountsOnlyAwakeTime() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)

        for _ in 0 ..< 4 { try await harness.tick(slot) }  // 120 s awake
        harness.clock.hostSleeps(for: 900)  // 15 min asleep: the poll wakes with the host
        for _ in 0 ..< 6 { try await harness.tick(slot) }  // 300 s awake, 20 min of wall time
        XCTAssertEqual(slot.status.state, .booting, "a sleep gap is not boot time")
        XCTAssertFalse(harness.events.contains("forceStop base-1"))

        try await harness.tick(slot)  // 330 s awake
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        let trip = try XCTUnwrap(harness.logger.messages.first { $0.contains("boot deadline tripped") })
        XCTAssertTrue(trip.contains("5m30s awake"), trip)
        XCTAssertTrue(trip.contains("the host was asleep for 15m00s"), trip)
    }

    func testRegistrationDeadlineIgnoresHostSleepBetweenBootstrapAndObservation() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let clone = try harness.latestClone()
        clone.bootstrap()
        try await harness.waitForState(slot, .bootstrapped)
        harness.registry.status = .unregistered

        for _ in 0 ..< 2 { try await harness.tick(slot) }  // 60 s awake
        harness.clock.hostSleeps(for: 1_200)  // 20 min asleep
        try await harness.tick(slot)  // the first observation after waking: 90 s awake since bootstrap
        XCTAssertEqual(slot.status.state, .bootstrapped)
        XCTAssertFalse(harness.events.contains("forceStop base-1"))

        harness.registry.status = .online(id: 1, isBusy: false)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .registered)
        let registered = try XCTUnwrap(harness.logger.messages.first { $0.contains("bootstrapped -> registered") })
        XCTAssertTrue(registered.contains("host asleep 20m00s of it"), registered)

        harness.registry.status = .unregistered
        try await harness.tick(slot)
        clone.exitGuest()
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(harness.logger.messages.contains { $0.contains("deadline tripped") })
    }

    func testShutdownDeadlineCountsOnlyAwakeTime() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        try await harness.waitForState(slot, .bootstrapped)
        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .busy)
        harness.registry.status = .unregistered
        try await harness.tick(slot)
        try await harness.waitForState(slot, .draining)

        for _ in 0 ..< 3 { try await harness.tick(slot) }  // 90 s awake
        harness.clock.hostSleeps(for: 600)
        for _ in 0 ..< 3 { try await harness.tick(slot) }  // 180 s awake
        XCTAssertEqual(slot.status.state, .draining, "180 s awake is not yet past the 180 s deadline")
        XCTAssertFalse(harness.events.contains("forceStop base-1"))

        try await harness.tick(slot)
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        let trip = try XCTUnwrap(harness.logger.messages.first { $0.contains("shutdown deadline tripped") })
        XCTAssertTrue(trip.contains("3m30s awake in draining"), trip)
        XCTAssertTrue(trip.contains("the host was asleep for 10m00s"), trip)
    }

    func testRegistrationDeadlineKeepsGuestGitHubReportsBusy() async throws {
        // The host slept through the registration: the stale list says unregistered, the deadline
        // trips, and the release is refused because the guest took a job in the meantime.
        harness.registry.deregistrationError = GitHubRunnerBusyError(id: 1)
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let clone = try harness.latestClone()
        clone.bootstrap()
        try await harness.waitForState(slot, .bootstrapped)
        harness.registry.status = .unregistered

        for _ in 0 ..< 10 { try await harness.tick(slot) }
        try await harness.waitForState(slot, .busy)

        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "deregister 1"])
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("registration deadline tripped") })
        XCTAssertTrue(harness.logger.messages.contains { message in
            message.contains("refused for runner id 1: it is still running a job; keeping the guest")
        })
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("recovering -> busy") })

        // The watchdog polls on. Busy observations keep it busy; the job ending drains it, and
        // the guest powers off on its own exactly as if no deadline had ever tripped.
        harness.registry.status = .online(id: 1, isBusy: true)
        for _ in 0 ..< 20 { try await harness.tick(slot) }
        XCTAssertEqual(slot.status.state, .busy)
        harness.registry.deregistrationError = nil
        harness.registry.status = .unregistered
        try await harness.tick(slot)
        try await harness.waitForState(slot, .draining)
        clone.exitGuest()
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "deregister 1", "delete base-1"])
    }

    func testKeptGuestCanStillBeRecoveredByALaterDeadline() async throws {
        harness.registry.deregistrationError = GitHubRunnerBusyError(id: 1)
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        try await harness.waitForState(slot, .bootstrapped)
        harness.registry.status = .unregistered
        for _ in 0 ..< 10 { try await harness.tick(slot) }
        try await harness.waitForState(slot, .busy)

        // The job ends but the guest wedges in draining: the shutdown deadline must still be able
        // to force it off, so the kept-guest recovery cannot have been the slot's one cleanup.
        harness.registry.deregistrationError = nil
        try await harness.tick(slot)
        try await harness.waitForState(slot, .draining)
        for _ in 0 ..< 7 { try await harness.tick(slot) }
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(
            harness.events,
            ["clone base-1", "start base-1", "deregister 1", "deregister 1", "forceStop base-1", "delete base-1"]
        )
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("shutdown deadline tripped") })
    }

    func testQuitStillStopsGuestGitHubReportsBusy() async throws {
        harness.registry.deregistrationError = GitHubRunnerBusyError(id: 1)
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .busy)

        cycle.cancel()
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(
            harness.events, ["clone base-1", "start base-1", "deregister 1", "forceStop base-1", "delete base-1"]
        )
        XCTAssertTrue(harness.logger.messages.contains { message in
            message.contains("refused for runner id 1: it is still running a job; falling through to forced stop")
        })
        XCTAssertEqual(slot.status.state, .idle)
    }

    @MainActor
    func testFleetPreventsHostSleepWhileRunning() async throws {
        let prevention = SpyHostSleepPrevention()
        let fleet = VirtualMachineFleet(
            logger: harness.logger,
            baseVirtualMachine: harness.base,
            runnerRegistry: harness.registry,
            runnerConfiguration: Configuration(),
            identityReader: harness.identityReader,
            clock: harness.clock,
            hostSleepPrevention: prevention
        )
        XCTAssertEqual(prevention.events, [])

        fleet.start(numberOfMachines: 1)
        try await harness.waitUntil("guest start") { self.harness.recorder.clones.last?.hasStarted == true }
        XCTAssertEqual(prevention.events, ["begin: Tartelet is running 1 GitHub Actions runner VM(s)"])

        await fleet.stopAndWait()
        XCTAssertFalse(fleet.isStarted)
        XCTAssertEqual(prevention.events.last, "end")
        XCTAssertEqual(prevention.events.count, 2)
    }
}

private final class SpyHostSleepPrevention: HostSleepPrevention, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] {
        lock.withLock { recorded }
    }

    func begin(reason: String) {
        lock.withLock { recorded.append("begin: \(reason)") }
    }

    func end() {
        lock.withLock { recorded.append("end") }
    }
}

private struct Configuration: GitHubActionsRunnerConfiguration {
    let runnerDisableDefaultLabels = false
    let runnerDisableUpdates = false
    let runnerScope = GitHubRunnerScope.repo
    let runnerLabels = ""
    let runnerGroup = ""
    let runnerName = "runner"
}
