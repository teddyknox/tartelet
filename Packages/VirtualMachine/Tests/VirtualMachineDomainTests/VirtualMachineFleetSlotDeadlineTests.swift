import LoggingDomain
import VirtualMachineDomain
import XCTest

/// The host-side deadlines and the forced stop they lead to.
final class VirtualMachineFleetSlotDeadlineTests: XCTestCase {
    private var harness = FleetSlotHarness()

    override func setUp() {
        super.setUp()
        harness = FleetSlotHarness()
    }

    func testRegistrationTimeoutForcesStopThenReclones() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let first = try harness.latestClone()
        first.bootstrap()
        try await harness.waitForState(slot, .bootstrapped)
        harness.registry.status = .unregistered

        // Nine polls, 270 s after bootstrap: still within the deadline.
        for _ in 0 ..< 9 {
            try await harness.tick(slot)
        }
        XCTAssertEqual(slot.status.state, .bootstrapped)
        XCTAssertFalse(harness.events.contains("forceStop base-1"))

        // The observation at 300 s trips it.
        try await harness.tick(slot)
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "forceStop base-1", "delete base-1"])
        XCTAssertEqual(harness.guestLogReader.reads, ["base-1"], "the guest log is captured before the forced stop")
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("registration deadline tripped") })
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("fake guest log") })
        XCTAssertEqual(slot.status.state, .idle)

        // The slot is clean, so the next cycle clones straight away.
        let second = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        XCTAssertEqual(harness.recorder.clones.count, 2)
        XCTAssertFalse(try harness.latestClone() === first)
        try harness.latestClone().exitGuest()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .completed)
    }

    func testJobFinishesButGuestNeverExitsForcesStopAfterShutdownDeadline() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        try await harness.waitForState(slot, .bootstrapped)

        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .busy)

        // The job is cancelled: the ephemeral runner unregisters, but the guest keeps running.
        harness.registry.status = .unregistered
        try await harness.tick(slot)
        try await harness.waitForState(slot, .draining)

        for _ in 0 ..< 6 {
            try await harness.tick(slot)
        }
        XCTAssertEqual(slot.status.state, .draining, "180 s in draining is not yet past the deadline")
        XCTAssertFalse(harness.events.contains("forceStop base-1"))

        try await harness.tick(slot)
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "forceStop base-1", "delete base-1"])
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("shutdown deadline tripped") })
    }

    func testTransientAPIErrorsDoNotTripRegistrationDeadline() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let clone = try harness.latestClone()
        clone.bootstrap()
        try await harness.waitForState(slot, .bootstrapped)

        harness.registry.result = .failure(FakeAPIError())
        // Twelve failed polls, 360 s after bootstrap: well past the 300 s deadline.
        for _ in 0 ..< 12 {
            try await harness.tick(slot)
        }
        XCTAssertEqual(slot.status.state, .bootstrapped)
        XCTAssertFalse(harness.events.contains("forceStop base-1"))
        XCTAssertEqual(harness.registry.queries.count, 13, "one baseline plus twelve failed polls")

        harness.registry.status = .online(id: 1, isBusy: false)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .registered)

        harness.registry.status = .unregistered
        try await harness.tick(slot)
        try await harness.waitForState(slot, .draining)
        clone.exitGuest()
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "delete base-1"])
    }

    func testBootTimeoutForcesStopWhenGuestNeverBootstraps() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)

        for _ in 0 ..< 10 {
            try await harness.tick(slot)
        }
        XCTAssertEqual(slot.status.state, .booting, "300 s is not yet past the boot deadline")
        try await harness.tick(slot)
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "forceStop base-1", "delete base-1"])
        XCTAssertEqual(
            harness.registry.queries.count, 1, "only the pre-clone identity baseline is read before bootstrap"
        )
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("boot deadline tripped") })
    }

    func testLifetimeCapForcesStopEvenWhileBusy() async throws {
        var shortLived = harness.policy
        shortLived.maximumLifetime = .seconds(600)
        let slot = harness.makeSlot(policy: shortLived)
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .busy)

        while !harness.events.contains("forceStop base-1"), slot.status.state != .idle {
            try await harness.tick(slot)
        }
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("lifetime deadline tripped") })
        XCTAssertGreaterThan(harness.clock.now.timeIntervalSince(ManualClock().now), 600)
    }

    func testForcedStopThatDoesNotEndTartRunIsCancelledAfterGracePeriod() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let clone = try harness.latestClone()
        clone.forceStopEndsStart = false
        clone.bootstrap()
        try await harness.waitForState(slot, .bootstrapped)
        harness.registry.status = .unregistered

        for _ in 0 ..< 10 {
            try await harness.tick(slot)
        }
        try await harness.waitUntil("the forced stop") { self.harness.events.contains("forceStop base-1") }
        XCTAssertEqual(slot.status.state, .recovering)

        // `tart run` still has not returned; after the grace period it is cancelled outright.
        try await harness.clock.advanceWhenSleeping(by: 60)
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(harness.events.last, "delete base-1")
    }

    func testGuestLogFailureDoesNotPreventForcedStop() async throws {
        harness.guestLogReader.error = FakeAPIError()
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)

        for _ in 0 ..< 11 {
            try await harness.tick(slot)
        }
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(harness.guestLogReader.reads, ["base-1"])
        XCTAssertTrue(harness.events.contains("forceStop base-1"))
    }
}
