import Foundation
import ShellData
@testable import VirtualMachineData
import XCTest

final class TartLocatorTests: XCTestCase {
    func testHomebrewWrapperResolvesToInspectableNativeProcess() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Brew-\(UUID())")
        defer { try? files.removeItem(at: root) }
        let formula = root.appendingPathComponent("Cellar/tart/2.32.1")
        let native = formula.appendingPathComponent("libexec/tart.app/Contents/MacOS/tart")
        let wrapper = formula.appendingPathComponent("bin/tart")
        let launcher = root.appendingPathComponent("bin/tart")
        for file in [native, wrapper, launcher] {
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let fixture = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ProcessInspectorFixture")
        try files.copyItem(at: fixture, to: native)
        try Data("#!/bin/bash\nexec \"\(native.path)\" \"$@\"\n".utf8).write(to: wrapper)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try files.createSymbolicLink(at: launcher, withDestinationURL: wrapper)

        let shell = ProcessShell()
        let located = try TartLocator(shell: shell, candidates: [launcher.path]).locate()
        XCTAssertEqual(located, native.resolvingSymlinksInPath().path)
        let name = "slot-\(UUID())"
        // Launch through the actual Homebrew-style wrapper, whose exec replaces the process image.
        let process = try shell.launchExecutable(
            atPath: launcher.path,
            withArguments: ["run", name],
            environment: ["TART_HOME": root.path]
        )
        defer { process.kill() }
        let inspector = HostProcessInspector(shell: shell)
        let tart = Tart(homeProvider: Home(homeFolderURL: root), shell: shell, logger: nil, executablePath: located)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var match: HostVMProcess?
        repeat {
            match = try await inspector.processes(tart: tart, name: name)
                .first { $0.pid == process.processIdentifier }
            if match != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        let owned = try XCTUnwrap(match)
        XCTAssertTrue(owned.mayKill)
        try inspector.kill(owned)
        let exited = await process.waitForExit(timeout: .seconds(5))
        XCTAssertTrue(exited)
    }

    func testStandaloneExecutableRemainsSupported() throws {
        let fixture = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ProcessInspectorFixture")
        XCTAssertEqual(
            try TartLocator(shell: ProcessShell(), candidates: [fixture.path]).locate(),
            fixture.resolvingSymlinksInPath().path
        )
    }
}

private struct Home: TartHomeProvider { let homeFolderURL: URL? }
