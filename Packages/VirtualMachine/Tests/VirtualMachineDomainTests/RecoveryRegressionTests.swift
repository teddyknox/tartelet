import Foundation
@testable import VirtualMachineDomain
import XCTest

final class RecoveryRegressionTests: XCTestCase {
    func testLateBootstrapFromPreviousCycleCannotBootstrapReplacement() async throws {
        let harness = FleetSlotHarness()
        let slot = harness.makeSlot()
        let first = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let old = try harness.latestClone()
        old.exitGuest()
        _ = await first.value
        let second = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let revision = slot.status.revision
        old.bootstrap()
        XCTAssertEqual(slot.status.state, .booting)
        XCTAssertEqual(slot.status.revision, revision)
        try harness.latestClone().bootstrap()
        XCTAssertEqual(slot.status.state, .bootstrapped)
        XCTAssertGreaterThan(slot.status.revision, revision)
        try harness.latestClone().exitGuest()
        _ = await second.value
    }

    func testTimeoutCancelsTheActualOperation() async throws {
        let started = expectation(description: "operation started")
        let cancelled = expectation(description: "operation cancelled")
        let operation = Task {
            try await withTimeout(.milliseconds(100)) {
                try await withTaskCancellationHandler {
                    started.fulfill()
                    try await Task.sleep(for: .seconds(30))
                } onCancel: {
                    cancelled.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        do { try await operation.value; XCTFail("timeout") } catch is TimeoutError {}
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testTimeoutDoesNotJoinCancellationIgnoringOperation() async throws {
        let gate = AsyncTestGate()
        let finished = expectation(description: "caller returned")
        let task = Task {
            do {
                try await withTimeout(.milliseconds(30)) { await gate.wait() }; XCTFail("timeout")
            } catch is TimeoutError {} catch { XCTFail("\(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        gate.open()
        await task.value
    }

    func testRecoveryCompletesBeforeSingleDeleteWhenExitCancelsWatchdog() async throws {
        let harness = FleetSlotHarness()
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        let clone = try harness.latestClone()
        let gate = AsyncTestGate()
        let cleanupStarted = expectation(description: "helper cleanup started")
        clone.afterForcedExit = {
            cleanupStarted.fulfill()
            await gate.wait()
            XCTAssertFalse(Task.isCancelled, "normal run return must not cancel force-stop cleanup")
            harness.recorder.record("helper cleanup finished")
        }
        // Advance directly; tick waits for recovery completion, which this test holds at the gate.
        try await harness.clock.advanceWhenSleeping(by: 301)
        await fulfillment(of: [cleanupStarted], timeout: 1)
        cycle.cancel()  // Quit during an already committed recovery must also finish it.
        XCTAssertFalse(harness.events.contains("delete base-1"))
        gate.open()
        let outcome = await cycle.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(harness.events.suffix(2), ["helper cleanup finished", "delete base-1"])
        XCTAssertEqual(harness.events.filter { $0 == "delete base-1" }.count, 1)
        XCTAssertFalse(harness.events.contains("delete was cancelled"))
    }

    func testInitialOldRegistrationIsIgnoredAndAPIOutagePostponesClone() async throws {
        let harness = FleetSlotHarness()
        let slot = harness.makeSlot()
        harness.registry.result = .failure(FakeAPIError())
        let failed = await slot.runCycle()
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(harness.events.isEmpty)
        harness.identityReader.id = 100
        harness.registry.status = .online(id: 99, isBusy: true)
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        for _ in 0 ..< 3 { try await harness.tick(slot) }
        XCTAssertEqual(slot.status.state, .bootstrapped)
        XCTAssertEqual(harness.logger.messages.filter { $0.contains("previous guest's registration") }.count, 1)
        harness.registry.status = .online(id: 100, isBusy: false)
        try await harness.tick(slot)
        XCTAssertEqual(slot.status.state, .registered)
        try harness.latestClone().exitGuest()
        _ = await cycle.value
    }

    func testPredeadlineObservationCannotTripDuringAPIOutageAndLogsAreThrottled() async throws {
        let harness = FleetSlotHarness()
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        for _ in 0 ..< 9 { try await harness.tick(slot) }  // last successful negative at 270 seconds
        harness.registry.result = .failure(FakeAPIError())
        for _ in 0 ..< 12 { try await harness.tick(slot) }
        XCTAssertEqual(slot.status.state, .bootstrapped)
        XCTAssertEqual(harness.logger.messages.filter { $0.contains("could not read the runner list") }.count, 2)
        harness.registry.status = .unregistered
        try await harness.tick(slot)
        let outcome = await cycle.value
        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertTrue(harness.logger.messages.contains { $0.contains("runner list is available again") })
    }

    func testDrainingDoesNotFlapToRegisteredAfterBusyAndLifetimeIncludesIdle() async throws {
        let harness = FleetSlotHarness()
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        harness.registry.status = .online(id: 1, isBusy: false)
        try await harness.tick(slot)
        let entered = slot.status.stateEnteredAt
        for _ in 0 ..< 3 { try await harness.tick(slot) }
        XCTAssertEqual(slot.status.state, .draining)
        XCTAssertEqual(slot.status.stateEnteredAt, entered)
        try harness.latestClone().exitGuest()
        _ = await cycle.value

        harness.identityReader.id = 2
        let idleSlot = harness.makeSlot()
        harness.registry.status = .unregistered
        let idle = Task { await idleSlot.runCycle() }
        try await harness.waitForState(idleSlot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 2, isBusy: false)
        try await harness.tick(idleSlot)
        try await harness.clock.advanceWhenSleeping(by: 10_800)
        let idleOutcome = await idle.value
        XCTAssertEqual(idleOutcome, .forcedStop)
    }
}

extension RecoveryRegressionTests {
    func testBootFailureReleasesObservedRegistrationWhenGuestIdentityCannotBeRead() async throws {
        let harness = FleetSlotHarness()
        harness.registry.status = .offline(id: 99)
        harness.identityReader.error = FakeAPIError()
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        for _ in 0 ..< 11 { try await harness.tick(slot) }
        let outcome = await cycle.value
        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(harness.events.suffix(3), ["deregister 99", "forceStop base-1", "delete base-1"])
    }

    func testLifetimeRecycleReleasesBeforeStopAndReplacementReportsFreshIdentity() async throws {
        let harness = FleetSlotHarness()
        var policy = harness.policy
        policy.maximumLifetime = .seconds(60)
        let slot = harness.makeSlot(policy: policy)
        let first = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 1, isBusy: false)
        for _ in 0 ..< 3 { try await harness.tick(slot) }
        let outcome = await first.value
        XCTAssertEqual(outcome, .forcedStop)
        XCTAssertEqual(
            harness.events, ["clone base-1", "start base-1", "deregister 1", "forceStop base-1", "delete base-1"]
        )
        harness.identityReader.id = 2
        let second = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 2, isBusy: false)
        try await harness.tick(slot)
        XCTAssertEqual(slot.status.state, .registered)
        harness.registry.status = .online(id: 1, isBusy: true)
        try await harness.tick(slot)
        XCTAssertEqual(slot.status.state, .registered, "a mismatched stale id must not change this guest")
        try harness.latestClone().exitGuest()
        _ = await second.value
        XCTAssertTrue(harness.logger.messages.contains { message in
            message.contains("observed fresh runner identity 2 via guest-reported id")
        })
    }

    func testReplacementReusesIDAfterSessionConflictThenRegistersWithoutDeadline() async throws {
        let harness = FleetSlotHarness()
        harness.registry.status = .offline(id: 12_118)
        harness.identityReader.id = 12_118
        harness.guestLogReader.log = "A session for this runner already exists / Error: Conflict"
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        // The listener spends two minutes reconnecting after --replace reused the old id.
        for _ in 0 ..< 4 { try await harness.tick(slot) }
        XCTAssertEqual(slot.status.state, .bootstrapped)
        harness.registry.status = .online(id: 12_118, isBusy: false)
        for _ in 0 ..< 10 { try await harness.tick(slot) }
        XCTAssertEqual(slot.status.state, .registered)
        XCTAssertFalse(harness.logger.messages.contains { $0.contains("deadline tripped") })
        try harness.latestClone().exitGuest()
        _ = await cycle.value
        XCTAssertFalse(harness.events.contains("forceStop base-1"))
    }

    func testReusedIdentityGoesDirectlyBusyAndSurvivesBothDeadlinesUntilJobEnds() async throws {
        let harness = FleetSlotHarness()
        harness.registry.status = .offline(id: 12_118)
        harness.identityReader.id = 12_118
        var policy = harness.policy
        policy.maximumLifetime = .seconds(120)
        let slot = harness.makeSlot(policy: policy)
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        for _ in 0 ..< 4 { try await harness.tick(slot) }
        harness.registry.status = .online(id: 12_118, isBusy: true)
        for _ in 0 ..< 20 { try await harness.tick(slot) }
        XCTAssertEqual(slot.status.state, .busy)
        XCTAssertFalse(harness.events.contains("forceStop base-1"))
        harness.registry.status = .unregistered
        try await harness.tick(slot)
        XCTAssertEqual(slot.status.state, .draining)
        try harness.latestClone().exitGuest()
        _ = await cycle.value
        XCTAssertFalse(harness.logger.messages.contains { $0.contains("deadline tripped") })
    }

    func testDeregistrationFailureAndTimeoutStillStopWithDistinctReasons() async throws {
        for timesOut in [false, true] {
            let harness = FleetSlotHarness()
            let gate = AsyncTestGate()
            if timesOut {
                harness.registry.beforeDeregister = { await gate.wait() }
            } else {
                harness.registry.deregistrationError = FakeAPIError()
            }
            let slot = harness.makeSlot(deregistrationTimeout: .milliseconds(30))
            let cycle = Task { await slot.runCycle() }
            try await harness.waitForState(slot, .booting)
            try harness.latestClone().bootstrap()
            for _ in 0 ..< 10 { try await harness.tick(slot) }
            let outcome = await cycle.value
            XCTAssertEqual(outcome, .forcedStop)
            XCTAssertEqual(harness.events.suffix(3), ["deregister 1", "forceStop base-1", "delete base-1"])
            let expected = timesOut ? "deregistration via GitHub API timed out" : "deregistration via GitHub API failed"
            XCTAssertTrue(harness.logger.messages.contains { message in
                message.contains(expected) && message.contains("falling through to forced stop")
            })
            gate.open()
        }
    }

    func testQuitWaitsForDeregistrationBeforeStoppingGuest() async throws {
        let harness = FleetSlotHarness()
        let slot = harness.makeSlot()
        let cycle = Task { await slot.runCycle() }
        try await harness.waitForState(slot, .booting)
        try harness.latestClone().bootstrap()
        harness.registry.status = .online(id: 1, isBusy: false)
        try await harness.tick(slot)
        let gate = AsyncTestGate()
        harness.registry.beforeDeregister = { await gate.wait() }
        cycle.cancel()
        try await harness.waitUntil("deregistration") { harness.events.contains("deregister 1") }
        XCTAssertFalse(harness.events.contains("forceStop base-1"))
        XCTAssertFalse(harness.events.contains("delete base-1"))
        gate.open()
        let outcome = await cycle.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(harness.events.suffix(3), ["deregister 1", "forceStop base-1", "delete base-1"])
    }

}

/// Reusable, cancellation-ignoring latch. Opening before the waiter is installed is safe.
final class AsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let waiters = lock.withLock {
            isOpen = true
            let pending = self.waiters
            self.waiters = []
            return pending
        }
        waiters.forEach { $0.resume() }
    }
}
