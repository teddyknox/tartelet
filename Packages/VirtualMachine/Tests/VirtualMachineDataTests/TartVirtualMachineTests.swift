import Foundation
import ShellDomain
@testable import VirtualMachineData
import VirtualMachineDomain
import XCTest

final class TartVirtualMachineTests: XCTestCase {
    private var home = FileManager.default.temporaryDirectory
    private var shell = FakeShell()
    private var inspector = FakeInspector()
    private var provider = FixedHome()
    private lazy var tart = makeTart()
    private let timing = TartVirtualMachine.StopTiming(
        interrupt: .milliseconds(20),
        cancellation: .milliseconds(20),
        kill: .seconds(1)
    )

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("TartTests-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        shell = FakeShell()
        inspector = FakeInspector()
        provider = FixedHome()
        provider.homeFolderURL = home
        tart = makeTart()
        let root = home
        shell.responder = { _, arguments in
            do {
                if arguments.first == "clone", let name = arguments.last {
                    let directory = root.appendingPathComponent("vms/\(name)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for file in ["config.json", "disk.img", "nvram.bin"] {
                        try Data("x".utf8).write(to: directory.appendingPathComponent(file))
                    }
                }
                return .success("")
            } catch {
                return .failure(error)
            }
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testClonePublishesMarkedDirectoryWithoutChangingRunnerVisibleName() async throws {
        let clone = try await vm("base").clone(named: "base-1")
        XCTAssertEqual(clone.name, "base-1")
        let owner = try XCTUnwrap(OwnedVirtualMachineDirectory.read(tart: tart, name: "base-1", source: "base"))
        try owner.verify(tart: tart)
        let command = try XCTUnwrap(shell.invocations.first { $0.arguments.first == "clone" })
        XCTAssertEqual(command.arguments[1], "base")
        XCTAssertTrue(command.arguments[2].hasPrefix(".tartelet-clone-"))
        try await clone.delete()
    }

    func testUnmarkedDirectoryAndBaseImageAreNeverStoppedOrDeleted() async throws {
        for name in ["base", "base-1"] { _ = try directory(name, owned: false) }
        do { _ = try await vm("base").clone(named: "base-1"); XCTFail("must refuse collision") } catch {}
        do { try await vm("base").delete(); XCTFail("must refuse base image") } catch {}
        XCTAssertTrue(shell.invocations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("vms/base-1/disk.img").path))
    }

    func testRejectsTraversalSymlinksHardlinksAndCopiedMarkers() async throws {
        _ = try directory("base", owned: false)
        let original = try directory("base-1", owned: true)
        for name in ["../base", "base", ".", "bad/name"] {
            do { _ = try await vm("base").clone(named: name); XCTFail("unsafe name \(name)") } catch {}
        }
        let alias = home.appendingPathComponent("vms/alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        do { try await vm("alias").delete(); XCTFail("symlink") } catch {}
        let disk = original.appendingPathComponent("disk.img")
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.linkItem(at: home.appendingPathComponent("vms/base/disk.img"), to: disk)
        do { try await vm("base-1").delete(); XCTFail("shared inode") } catch {}
        try FileManager.default.removeItem(at: disk)
        try Data().write(to: disk)
        let copied = home.appendingPathComponent("vms/copied")
        try FileManager.default.copyItem(at: original, to: copied)
        do { try await vm("copied").delete(); XCTFail("copied marker") } catch {}
        XCTAssertTrue(shell.invocations.isEmpty)
    }

    func testMissingConfigCleanupReapsHelperBeforeRemovingDisk() async throws {
        let directory = try directory("base-1", owned: true)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config.json"))
        inspector.add(helper)
        inspector.beforeKill = {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disk.img").path))
        }
        shell.responder = { _, arguments in
            if arguments.first == "delete" {
                return .failure(ShellExecutionError.tart(status: 2, standardError: "does not exist"))
            }
            return .success("")
        }
        try await vm("base-1").delete()
        XCTAssertEqual(inspector.killed, [helper])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPrecloneCleanupAlsoReapsOrphans() async throws {
        _ = try directory("base-1", owned: true)
        inspector.add(helper)
        let clone = try await vm("base").clone(named: "base-1")
        XCTAssertEqual(inspector.killed, [helper])
        XCTAssertEqual(shell.invocations.first?.arguments.first, "stop")
        try await clone.delete()
    }

    func testUnrelatedDiskHolderOrInspectionFailurePreventsDeletion() async throws {
        let directory = try directory("base-1", owned: true)
        let unrelated = HostVMProcess(
            pid: 123,
            executable: "/tmp/VirtualizationBackup",
            startedAtSeconds: 1,
            startedAtMicroseconds: 0,
            mayKill: false
        )
        inspector.add(unrelated)
        do { try await vm("base-1").delete(); XCTFail("unrelated holder") } catch {}
        XCTAssertTrue(inspector.killed.isEmpty)
        inspector.error = FakeInspectionError()
        do { try await vm("base-1").delete(); XCTFail("failed inspection") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(shell.invocations.contains { $0.arguments.first == "delete" })
    }

    func testRunningDeleteErrorLeavesDirectoryIntact() async throws {
        let directory = try directory("base-1", owned: true)
        shell.responder = { _, arguments in
            arguments.first == "delete"
                ? .failure(ShellExecutionError.tart(status: 1, standardError: "is running")) : .success("")
        }
        do { try await vm("base-1").delete(); XCTFail("running") } catch let error as TartError {
            XCTAssertEqual(error, .virtualMachineIsRunning("base-1"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancelledDeleteStillRunsAndCleansHelpers() async throws {
        let directory = try directory("base-1", owned: true)
        inspector.add(helper)
        let machine = vm("base-1")
        let task = Task { try await machine.delete() }
        task.cancel()
        try await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(inspector.killed, [helper])
    }

    func testForceStopCompletesHelperCleanupAfterRunReturnsZero() async throws {
        _ = try directory("base-1", owned: true)
        let machine = vm("base-1")
        let start = Task { try await machine.start() }
        let process = try await runProcess()
        inspector.add(helper)
        shell.responder = { _, arguments in
            if arguments.first == "stop" { process.exit() }
            return .success("")
        }
        let stop = Task { await machine.forceStop() }
        stop.cancel()
        await stop.value
        try await start.value
        XCTAssertEqual(inspector.killed, [helper])
        XCTAssertEqual(process.signals, [])
    }

    func testCancellationWaitsForInterruptThenKillsIgnoringRun() async throws {
        shell.runIgnoresInterrupt = true
        let machine = vm("base")
        let start = Task { try await machine.start() }
        let process = try await runProcess()
        start.cancel()
        _ = await start.result
        XCTAssertEqual(process.signals, [SIGINT, SIGKILL])
        XCTAssertFalse(process.isRunning)
    }

    func testNormalStartReturnsWhenGuestPowersOff() async throws {
        let machine = vm("base")
        let start = Task { try await machine.start() }
        let process = try await runProcess()
        process.exit()
        try await start.value
        XCTAssertEqual(process.signals, [])
    }

    func testLeasePreventsOverlappingCycleAndReleasesAfterDeletion() async throws {
        let base = vm("base")
        let first = try await base.clone(named: "base-1")
        do { _ = try await base.clone(named: "base-1"); XCTFail("overlap") } catch {}
        try await first.delete()
        let second = try await base.clone(named: "base-1")
        await first.forceStop()  // a retained old object must never stop its replacement
        XCTAssertEqual(inspector.killed, [])
        try await second.delete()
    }

    func testSettingsChangeCannotRedirectExistingMachineCleanup() async throws {
        let directory = try directory("base-1", owned: true)
        let machine = vm("base-1")
        provider.homeFolderURL = home.appendingPathComponent("elsewhere")
        try await machine.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(shell.invocations.allSatisfy { $0.environment["TART_HOME"] == home.path })
    }

    func testUnreapedCommandKeepsSlotLockedUntilActualExit() async throws {
        let lease = try VirtualMachineLease(tart: tart, name: "base-1")
        let process = FakeShellProcess()
        lease.keepUntilExit(process)
        lease.release()
        XCTAssertThrowsError(try lease.ensureReady())
        XCTAssertThrowsError(try VirtualMachineLease(tart: tart, name: "base-1"))
        process.exit()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var next: VirtualMachineLease?
        while next == nil, ContinuousClock.now < deadline {
            next = try? VirtualMachineLease(tart: tart, name: "base-1")
            if next == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertNotNil(next)
        next?.release()
    }

    private func makeTart() -> Tart {
        Tart(homeProvider: provider, shell: shell, logger: nil, executablePath: "/opt/homebrew/bin/tart")
    }
    private func vm(_ name: String) -> TartVirtualMachine {
        TartVirtualMachine(tart: tart, vmName: name, inspector: inspector, timing: timing)
    }
    private var helper: HostVMProcess {
        HostVMProcess(
            pid: 42,
            executable: HostProcessInspector.helperExecutable,
            startedAtSeconds: 1,
            startedAtMicroseconds: 0,
            mayKill: true
        )
    }
    private func directory(_ name: String, owned: Bool) throws -> URL {
        let directory = tart.virtualMachineDirectoryURL(name: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["config.json", "disk.img", "nvram.bin"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(file))
        }
        if owned {
            _ = try OwnedVirtualMachineDirectory.create(tart: tart, staging: directory, name: name, source: "base")
        }
        return directory
    }
    private func runProcess() async throws -> FakeShellProcess {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while shell.launchedProcesses.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try XCTUnwrap(shell.launchedProcesses.first)
    }
}

private final class FixedHome: TartHomeProvider { var homeFolderURL: URL? }
private struct FakeInspectionError: Error {}
private final class FakeInspector: HostProcessInspecting {
    private let lock = NSLock()
    private var active: [HostVMProcess] = []
    private var signaled: [HostVMProcess] = []
    var error: Error?
    var beforeKill: () -> Void = {}
    var killed: [HostVMProcess] { lock.withLock { signaled } }
    func add(_ process: HostVMProcess) { lock.withLock { active.append(process) } }
    func processes(tart: Tart, name: String) async throws -> [HostVMProcess] {
        if let error { throw error }
        return lock.withLock { active }
    }
    func kill(_ process: HostVMProcess) throws {
        beforeKill()
        lock.withLock {
            signaled.append(process); active.removeAll { $0 == process }
        }
    }
    func hasExited(_ process: HostVMProcess) -> Bool { lock.withLock { !active.contains(process) } }
}
