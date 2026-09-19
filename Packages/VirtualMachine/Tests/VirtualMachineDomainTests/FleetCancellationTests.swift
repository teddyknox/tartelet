import GitHubDomain
import VirtualMachineDomain
import XCTest

final class FleetCancellationTests: XCTestCase {
    @MainActor
    func testStopWaitsForDeletionAndPreventsRestartDuringCleanup() async throws {
        let harness = FleetSlotHarness()
        let fleet = VirtualMachineFleet(
            logger: harness.logger,
            baseVirtualMachine: harness.base,
            runnerRegistry: harness.registry,
            runnerConfiguration: Configuration(),
            identityReader: harness.identityReader,
            clock: harness.clock
        )
        fleet.start(numberOfMachines: 1)
        try await harness.waitUntil("guest start") { harness.recorder.clones.last?.hasStarted == true }
        let gate = AsyncTestGate()
        let deleting = expectation(description: "deleting")
        try harness.latestClone().beforeDelete = {
            deleting.fulfill(); await gate.wait()
        }
        let stop = Task { await fleet.stopAndWait(forTermination: true) }
        await fulfillment(of: [deleting], timeout: 1)
        XCTAssertTrue(fleet.isStarted)
        XCTAssertTrue(fleet.isStopping)
        fleet.start(numberOfMachines: 1)
        XCTAssertEqual(harness.recorder.clones.count, 1)
        gate.open()
        await stop.value
        XCTAssertFalse(fleet.isStarted)
        XCTAssertFalse(fleet.isStopping)
        XCTAssertTrue(fleet.slotStatuses.isEmpty)
        fleet.start(numberOfMachines: 1)
        XCTAssertFalse(fleet.isStarted, "Quit must prevent new work before the registry takes its final snapshot")
        XCTAssertEqual(harness.events.filter { $0 == "delete base-1" }.count, 1)
    }

    func testSlowPredeadlineObservationIsNotDatedAtResponseCompletion() async throws {
        let harness = FleetSlotHarness()
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        for _ in 0 ..< 8 { try await harness.tick(slot) }
        let gate = AsyncTestGate()
        let requested = expectation(description: "requested at 270 seconds")
        harness.registry.beforeResult = {
            requested.fulfill(); await gate.wait()
        }
        let generation = try await harness.clock.advanceWhenSleeping(by: 30)
        await fulfillment(of: [requested], timeout: 1)
        harness.clock.advance(by: 60)  // request returns at 330 seconds with its old negative snapshot
        gate.open()
        try await harness.waitUntil("poll settled") {
            harness.clock.sleepGeneration > generation || slot.status.state == .idle
        }
        XCTAssertEqual(slot.status.state, .bootstrapped)
        XCTAssertFalse(harness.events.contains("forceStop base-1"))
        cycle.cancel()
        _ = await cycle.value
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
