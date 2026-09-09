import Foundation
@testable import ShellData
import ShellDomain
import XCTest

final class ProcessShellTests: XCTestCase {
    func testBoundedResidentMemoryWhileOutputPipeRemainsOpen() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("ShellMemory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: ready) }
        let baseline = residentBytes()
        let process = try ProcessShell().launchExecutable(
            atPath: "/bin/sh",
            withArguments: ["-c", "head -c 67108864 /dev/zero; printf ready > \"$1\"; exec sleep 30", "sh", ready.path]
        )
        defer { process.kill() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let growth = max(0, Int64(residentBytes()) - Int64(baseline))
        XCTAssertLessThan(growth, 32 * 1_048_576, "the 64 MiB stream must not accumulate before EOF")
        process.kill()
        _ = try? await process.waitForExit()
    }

    func testDrainsBothPipesAndKeepsOnlyTheirLastMegabyte() async throws {
        let process = try ProcessShell().launchExecutable(
            atPath: "/bin/zsh",
            withArguments: [
                "-c",
                "head -c 33554432 /dev/zero; printf tail; head -c 33554432 /dev/zero >&2; printf error >&2; exit 7"
            ]
        )
        do {
            _ = try await process.output(timeout: .seconds(20))
            XCTFail("expected nonzero exit")
        } catch let error as ShellExecutionError {
            XCTAssertEqual(error.terminationStatus, 7)
            XCTAssertEqual(error.standardOutput.utf8.count, 1_048_576)
            XCTAssertTrue(error.standardOutput.hasSuffix("tail"))
            XCTAssertEqual(error.standardError.utf8.count, 1_048_576)
            XCTAssertTrue(error.standardError.hasSuffix("error"))
        }
    }

    func testGrandchildPipeGracePreservesPartialOutputAndReleasesHandle() async throws {
        let shell = ProcessShell()
        var handle: ShellProcess? = try shell.launchExecutable(
            atPath: "/bin/sh",
            withArguments: ["-c", "printf partial; sleep 5 &"]
        )
        weak var released = handle
        let start = ContinuousClock.now
        let output = try await handle!.output(timeout: .seconds(8))
        XCTAssertEqual(output, "partial")
        XCTAssertLessThan(start.duration(to: .now), .seconds(4.5))
        handle = nil
        // Dispatch cancellation handlers may still be returning after resuming the waiter.
        for _ in 0 ..< 100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(released, "pipe reader ownership must be released after the grace period")
    }

    func testCancelledWaitStillWaitsAndEscalatesAnInterruptIgnoringChild() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("ShellReady-\(UUID())")
        defer { try? FileManager.default.removeItem(at: ready) }
        let process = try ProcessShell().launchExecutable(
            atPath: "/bin/sh",
            withArguments: ["-c", "trap '' INT; printf ready > \"$1\"; exec sleep 30", "sh", ready.path]
        )
        defer { process.kill() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "SIGINT handler must be installed")
        let task = Task {
            try await process.output(timeout: .seconds(30), interruptGrace: .milliseconds(100))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(process.isRunning)
        let cancelledWait = Task { await process.waitForExit(timeout: .seconds(1)) }
        cancelledWait.cancel()
        let didExit = await cancelledWait.value
        XCTAssertTrue(didExit)
    }

    func testMultipleWaitersAndTimeoutsResumeExactlyOnce() async throws {
        let process = try ProcessShell().launchExecutable(atPath: "/bin/sleep", withArguments: ["0.2"])
        await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 100 {
                group.addTask {
                    await process.waitForExit(timeout: index.isMultiple(of: 2) ? .milliseconds(5) : .seconds(5))
                }
            }
            var completed = 0
            for await _ in group { completed += 1 }
            XCTAssertEqual(completed, 100)
        }
        let output = try await process.waitForExit()
        XCTAssertEqual(output, "")
    }

    func testRegistryHandlesFastExitsLaunchFailureAndQuitBarrier() async throws {
        let registry = ProcessRegistry()
        let shell = ProcessShell(processRegistry: registry)
        for _ in 0 ..< 100 {
            _ = try await shell.runExecutable(atPath: "/usr/bin/true", withArguments: [])
        }
        XCTAssertEqual(registry.registeredCount, 0)
        XCTAssertThrowsError(try shell.launchExecutable(atPath: "/no/such/executable", withArguments: []))
        XCTAssertEqual(registry.registeredCount, 0)
        registry.terminateAll(gracePeriod: 0)
        XCTAssertThrowsError(try shell.launchExecutable(atPath: "/usr/bin/true", withArguments: []))
        XCTAssertEqual(registry.registeredCount, 0)
    }

    private func residentBytes() -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        XCTAssertEqual(proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size), size)
        return info.pti_resident_size
    }
}
