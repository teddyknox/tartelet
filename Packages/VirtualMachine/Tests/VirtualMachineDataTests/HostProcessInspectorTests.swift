import Foundation
import ShellData
import ShellDomain
@testable import VirtualMachineData
import XCTest

final class HostProcessInspectorTests: XCTestCase {
    func testRunIdentityRequiresExactNameHomeAndSubcommand() {
        let home = URL(fileURLWithPath: "/tmp/a home")
        let arguments = ["/opt/homebrew/bin/tart", "run", "--dir=cache:/tmp/cache", "base-1"]
        XCTAssertTrue(
            HostProcessInspector.isRun(
                arguments: arguments,
                environment: ["TART_HOME": home.path],
                home: home,
                name: "base-1"
            )
        )
        XCTAssertFalse(
            HostProcessInspector.isRun(
                arguments: arguments,
                environment: ["TART_HOME": "/tmp/other"],
                home: home,
                name: "base-1"
            )
        )
        XCTAssertFalse(
            HostProcessInspector.isRun(
                arguments: arguments,
                environment: ["TART_HOME": home.path],
                home: home,
                name: "base-2"
            )
        )
        XCTAssertFalse(
            HostProcessInspector.isRun(
                arguments: ["tart", "delete", "base-1"],
                environment: ["TART_HOME": home.path],
                home: home,
                name: "base-1"
            )
        )
    }

    func testReadsActualArgumentVectorAndEnvironmentWithoutSplittingSpaces() async throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ProcessInspectorFixture").path
        let process = try ProcessShell().launchExecutable(
            atPath: executable,
            withArguments: ["a name"],
            environment: ["TART_HOME": "/tmp/a home"]
        )
        defer { process.kill() }
        let identity = try XCTUnwrap(HostProcessInspector.argumentsAndEnvironment(process.processIdentifier))
        XCTAssertEqual(identity.arguments, [executable, "a name"])
        XCTAssertEqual(identity.environment["TART_HOME"], "/tmp/a home")
        process.kill()
        _ = try? await process.waitForExit()
    }

    func testMissingEnvironmentIsNeverTreatedAsDefaultHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart")
        XCTAssertFalse(
            HostProcessInspector.isRun(
                arguments: ["tart", "run", "base-1"],
                environment: [:],
                home: home,
                name: "base-1"
            )
        )
    }

    func testRealDiskReaderIsReportedButNeverEligibleForKilling() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Inspector-\(UUID())")
        let directory = home.appendingPathComponent("vms/base-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let disk = directory.appendingPathComponent("disk.img")
        try Data("disk".utf8).write(to: disk)
        let shell = ProcessShell()
        let executable = home.appendingPathComponent("VirtualizationBackup")
        try FileManager.default.copyItem(at: fixtureURL, to: executable)
        let process = try shell.launchExecutable(atPath: executable.path, withArguments: ["hold", disk.path])
        defer { process.kill() }
        let inspector = HostProcessInspector(shell: shell)
        let tart = Tart(
            homeProvider: Home(homeFolderURL: home),
            shell: shell,
            logger: nil,
            executablePath: "/opt/homebrew/bin/tart"
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var processes: [HostVMProcess] = []
        repeat {
            processes = try await inspector.processes(tart: tart, name: "base-1")
            if processes.contains(where: { $0.pid == process.processIdentifier }) { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let holder = try XCTUnwrap(processes.first { $0.pid == process.processIdentifier })
        XCTAssertFalse(holder.mayKill)
        XCTAssertThrowsError(try inspector.kill(holder))
        XCTAssertTrue(process.isRunning)
        process.kill()
        _ = try? await process.waitForExit()
    }

    func testFindsOrphanByExactRunIdentityWithoutConfigPathname() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Orphan-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("tart")
        try FileManager.default.copyItem(at: fixtureURL, to: executable)
        let shell = ProcessShell()
        let name = "slot-\(UUID())"
        let process = try shell.launchExecutable(
            atPath: executable.path,
            withArguments: ["run", name],
            environment: ["TART_HOME": home.path]
        )
        defer { process.kill() }
        let inspector = HostProcessInspector(shell: shell)
        let tart = Tart(
            homeProvider: Home(homeFolderURL: home),
            shell: shell,
            logger: nil,
            executablePath: executable.path
        )
        let matches = try await inspector.processes(tart: tart, name: name)
        let own = try XCTUnwrap(matches.first { $0.pid == process.processIdentifier })
        XCTAssertTrue(own.mayKill)
        let otherHome = Tart(
            homeProvider: Home(homeFolderURL: home.appendingPathComponent("other")),
            shell: shell,
            logger: nil,
            executablePath: executable.path
        )
        let others = try await inspector.processes(tart: otherHome, name: name)
        XCTAssertFalse(others.contains { $0.pid == process.processIdentifier })
        try inspector.kill(own)
        _ = try? await process.waitForExit()
        XCTAssertTrue(inspector.hasExited(own))
    }

    private var fixtureURL: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ProcessInspectorFixture")
    }
}

private struct Home: TartHomeProvider { let homeFolderURL: URL? }
