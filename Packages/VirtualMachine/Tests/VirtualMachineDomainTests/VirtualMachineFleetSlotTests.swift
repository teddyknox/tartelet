import LoggingDomain
import VirtualMachineDomain
import XCTest

/// The slot's lifecycle: the healthy cycle, stale registrations, cancellation and failures.
/// Deadlines are covered in `VirtualMachineFleetSlotDeadlineTests`.
final class VirtualMachineFleetSlotTests: XCTestCase {
    private var harness = FleetSlotHarness()

    override func setUp() {
        super.setUp()
        harness = FleetSlotHarness()
    }

    func testHealthySlotCyclesWithoutForcedStop() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let clone = try harness.latestClone()
        clone.bootstrap()
        try await harness.waitForState(slot, .bootstrapped)

        harness.registry.status = .online(id: 1, isBusy: false)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .registered)

        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .busy)

        harness.registry.status = .unregistered
        try await harness.tick(slot)
        try await harness.waitForState(slot, .draining)

        clone.exitGuest()
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(slot.status.state, .idle)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "delete base-1"])
        XCTAssertEqual(harness.registry.queries, ["runner 1", "runner 1", "runner 1"])
        XCTAssertTrue(harness.guestLogReader.reads.isEmpty)
        XCTAssertFalse(harness.logger.messages.contains { $0.contains("deadline tripped") })
    }

    func testRunStopsAfterCycleWhenAsked() async throws {
        let slot = harness.makeSlot()
        let run = Task { await slot.run { true } }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().exitGuest()
        await run.value

        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "delete base-1"])
        XCTAssertEqual(slot.status.state, .idle)
    }

    func testStaleRegistrationOfPreviousGuestIsIgnored() async throws {
        let slot = harness.makeSlot()
        var cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .busy)
        // The guest dies while busy; GitHub keeps listing its registration for a while.
        try harness.latestClone().exitGuest(with: .failure(FakeGuestKilled()))
        _ = await cycle.value

        cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        try await harness.waitForState(slot, .bootstrapped)
        try await harness.tick(slot)
        XCTAssertEqual(slot.status.state, .bootstrapped, "the old registration must not count as the new guest's")
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("previous guest's registration") })

        harness.registry.status = .online(id: 2, isBusy: false)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .registered)
        harness.registry.status = .unregistered
        try await harness.tick(slot)
        try await harness.waitForState(slot, .draining)
        try harness.latestClone().exitGuest()
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(harness.events.contains("forceStop base-1"))
    }

    func testCancellingTheSlotStopsTheGuestAndDeletesIt() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 1, isBusy: false)
        try await harness.tick(slot)
        try await harness.waitForState(slot, .registered)

        cycle.cancel()
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "delete base-1"])
        XCTAssertEqual(slot.status.state, .idle)
    }

    func testCloneFailureEndsTheCycleAsFailed() async throws {
        harness.base.cloneError = FakeAPIError()
        let slot = harness.makeSlot()

        let outcome = await slot.runCycle()

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(harness.events, ["clone base-1"])
        XCTAssertEqual(slot.status.state, .idle)
    }

    func testStartFailureStillDeletesTheClone() async throws {
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().exitGuest(with: .failure(FakeAPIError()))
        let outcome = await cycle.value

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(harness.events, ["clone base-1", "start base-1", "delete base-1"])
    }

    func testStatusChangesAreReported() async throws {
        let reported = ReportedStatuses()
        let slot = harness.makeSlot { reported.append($0) }
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().exitGuest()
        _ = await cycle.value

        XCTAssertEqual(reported.states, [.cloning, .booting, .exited, .idle])
        XCTAssertEqual(reported.statuses.first?.runnerName, "runner 1")
    }
}

private final class ReportedStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [VirtualMachineFleetSlotStatus] = []

    var statuses: [VirtualMachineFleetSlotStatus] {
        lock.withLock { all }
    }

    var states: [FleetSlotState] {
        statuses.map(\.state)
    }

    func append(_ status: VirtualMachineFleetSlotStatus) {
        lock.withLock { all.append(status) }
    }
}
