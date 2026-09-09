import Foundation
import LoggingDomain
import ShellDomain
@testable import VirtualMachineData
import VirtualMachineDomain
import XCTest

final class TartVirtualMachineTests: XCTestCase {
    private var tartHome = FileManager.default.temporaryDirectory
    private var shell = FakeShell()
    private var tart = Tart(
        homeProvider: FixedTartHomeProvider(homeFolderURL: nil),
        shell: FakeShell(),
        logger: nil,
        executablePath: "/opt/homebrew/bin/tart"
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        tartHome = FileManager.default.temporaryDirectory
            .appending(component: "TartVirtualMachineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tartHome, withIntermediateDirectories: true)
        shell = FakeShell()
        tart = Tart(
            homeProvider: FixedTartHomeProvider(homeFolderURL: tartHome),
            shell: shell,
            logger: nil,
            executablePath: "/opt/homebrew/bin/tart"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tartHome)
        try super.tearDownWithError()
    }

    // MARK: - Delete

    func testDeleteRemovesDirectoryWhenTartClaimsTheMachineDoesNotExist() async throws {
        let directory = try makeVirtualMachineDirectory(named: "base-1", files: ["disk.img", "nvram.bin"])
        shell.responder = { _, arguments in
            if arguments.first == "delete" {
                return .failure(ShellExecutionError.tart(
                    status: 2,
                    standardError: "the specified VM \"base-1\" does not exist\n"
                ))
            }
            return .success("")
        }

        try await TartVirtualMachine(tart: tart, vmName: "base-1").delete()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "the corrupt directory must be gone"
        )
        XCTAssertEqual(shell.invocations.map(\.arguments), [["delete", "base-1"]])
    }

    func testDeleteSucceedsWhenTartDeletesTheDirectory() async throws {
        let directory = try makeVirtualMachineDirectory(named: "base-1", files: Self.completeFiles)
        shell.responder = { _, arguments in
            if arguments.first == "delete" {
                try? FileManager.default.removeItem(at: directory)
            }
            return .success("")
        }

        try await TartVirtualMachine(tart: tart, vmName: "base-1").delete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDeleteRethrowsWhenTheMachineIsRunning() async throws {
        let directory = try makeVirtualMachineDirectory(named: "base-1", files: Self.completeFiles)
        shell.responder = { _, arguments in
            if arguments.first == "delete" {
                return .failure(ShellExecutionError.tart(status: 1, standardError: "VM \"base-1\" is running\n"))
            }
            return .success("")
        }

        do {
            try await TartVirtualMachine(tart: tart, vmName: "base-1").delete()
            XCTFail("expected delete to fail while the machine is running")
        } catch let error as TartError {
            XCTAssertEqual(error, .virtualMachineIsRunning("base-1"))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path),
            "a running machine's files are left alone"
        )
    }

    // MARK: - Clone

    func testCloneStopsAndRemovesALeftoverDirectoryFirst() async throws {
        let directory = try makeVirtualMachineDirectory(named: "base-1", files: ["disk.img", "nvram.bin"])
        var cloneSawLeftoverDirectory = false
        shell.responder = { _, arguments in
            switch arguments.first {
            case "stop":
                return .failure(ShellExecutionError.tart(status: 2, standardError: "VM \"base-1\" is not running\n"))
            case "delete":
                return .failure(ShellExecutionError.tart(
                    status: 2,
                    standardError: "the specified VM \"base-1\" does not exist\n"
                ))
            case "clone":
                cloneSawLeftoverDirectory = FileManager.default.fileExists(atPath: directory.path)
                return .success("")
            default:
                return .success("")
            }
        }

        let clone = try await TartVirtualMachine(tart: tart, vmName: "base").clone(named: "base-1")

        XCTAssertEqual(clone.name, "base-1")
        XCTAssertEqual(shell.invocations.map(\.arguments), [
            ["stop", "base-1", "--timeout", "20"],
            ["delete", "base-1"],
            ["clone", "base", "base-1"]
        ])
        XCTAssertFalse(cloneSawLeftoverDirectory, "the slot must be clean before cloning into it")
    }

    func testCloneDoesNotTouchTartWhenTheSlotIsClean() async throws {
        _ = try await TartVirtualMachine(tart: tart, vmName: "base").clone(named: "base-1")

        XCTAssertEqual(shell.invocations.map(\.arguments), [["clone", "base", "base-1"]])
    }

    // MARK: - Start and forced stop

    func testStartLaunchesTartRunAndReturnsWhenItExits() async throws {
        let virtualMachine = TartVirtualMachine(tart: tart, vmName: "base-1")
        let start = Task { try await virtualMachine.start(observer: nil) }
        let process = try await launchedProcess()

        XCTAssertEqual(shell.invocations.first?.arguments.first, "run")
        XCTAssertEqual(shell.invocations.first?.arguments.last, "base-1")
        process.exit()

        try await start.value
    }

    func testForceStopEscalatesFromTartStopToSignalsAndLooksForLingeringHelpers() async throws {
        let directory = try makeVirtualMachineDirectory(named: "base-1", files: Self.completeFiles)
        shell.responder = { path, arguments in
            if path.hasSuffix("lsof") {
                return .failure(ShellExecutionError(
                    executablePath: path,
                    arguments: arguments,
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: ""
                ))
            }
            return .success("")
        }
        let virtualMachine = TartVirtualMachine(tart: tart, vmName: "base-1")
        let start = Task { try await virtualMachine.start(observer: nil) }
        let process = try await launchedProcess()

        await virtualMachine.forceStop()

        XCTAssertTrue(shell.invocations.map(\.arguments).contains(["stop", "base-1", "--timeout", "20"]))
        XCTAssertEqual(
            process.signals,
            [SIGINT, SIGKILL],
            "a tart run that ignores tart stop is interrupted, then killed"
        )
        let diskImagePath = directory.appending(path: "disk.img").path
        XCTAssertTrue(shell.invocations.contains { $0.path.hasSuffix("lsof") && $0.arguments.last == diskImagePath })
        process.exit(with: .failure(ShellExecutionError.tart(status: 9)))
        do {
            try await start.value
            XCTFail("expected start to report the killed process")
        } catch {}
    }

    func testForceStopSkipsSignalsWhenTartStopEndedTheProcess() async throws {
        _ = try makeVirtualMachineDirectory(named: "base-1", files: Self.completeFiles)
        let virtualMachine = TartVirtualMachine(tart: tart, vmName: "base-1")
        let start = Task { try await virtualMachine.start(observer: nil) }
        let process = try await launchedProcess()
        shell.responder = { path, arguments in
            if arguments.first == "stop" {
                process.exit()
            }
            if path.hasSuffix("lsof") {
                return .success("")
            }
            return .success("")
        }

        await virtualMachine.forceStop()
        try await start.value

        XCTAssertEqual(process.signals, [])
    }

    func testCancellingStartInterruptsAndThenKillsTartRun() async throws {
        let virtualMachine = TartVirtualMachine(tart: tart, vmName: "base-1")
        let start = Task { try await virtualMachine.start(observer: nil) }
        let process = try await launchedProcess()

        start.cancel()
        try await waitUntil("signals") { process.signals == [SIGINT, SIGKILL] }
        process.exit(with: .failure(ShellExecutionError.tart(status: 9)))
        _ = await start.result
    }
}

private struct FixedTartHomeProvider: TartHomeProvider {
    let homeFolderURL: URL?
}

private extension TartVirtualMachineTests {
    private struct TimedOut: Error {}
    private static let completeFiles = ["config.json", "disk.img", "nvram.bin"]

    @discardableResult
    private func makeVirtualMachineDirectory(named name: String, files: [String]) throws -> URL {
        let directory = tart.virtualMachineDirectoryURL(name: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data("x".utf8).write(to: directory.appending(path: file))
        }
        return directory
    }

    private func launchedProcess() async throws -> FakeShellProcess {
        try await waitUntil("launched process") { !self.shell.launchedProcesses.isEmpty }
        return shell.launchedProcesses[0]
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(description)")
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
