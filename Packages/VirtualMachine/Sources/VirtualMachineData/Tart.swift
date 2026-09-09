import Foundation
import LoggingDomain
import ShellDomain

public enum TartError: LocalizedError, Equatable {
    case virtualMachineDoesNotExist(String)
    case virtualMachineIsNotRunning(String)
    case virtualMachineIsRunning(String)

    public var errorDescription: String? {
        switch self {
        case let .virtualMachineDoesNotExist(name):
            "tart reports that the virtual machine named \(name) does not exist"
        case let .virtualMachineIsNotRunning(name):
            "tart reports that the virtual machine named \(name) is not running"
        case let .virtualMachineIsRunning(name):
            "tart reports that the virtual machine named \(name) is running"
        }
    }
}

public struct Tart {
    let shell: Shell
    let logger: Logger?

    private let homeProvider: TartHomeProvider
    private let executablePathOverride: String?
    private var environment: [String: String]? {
        guard let homeFolderURL = homeProvider.homeFolderURL else {
            return nil
        }
        return ["TART_HOME": homeFolderURL.path(percentEncoded: false)]
    }

    public init(homeProvider: TartHomeProvider, shell: Shell, logger: Logger? = nil) {
        self.init(homeProvider: homeProvider, shell: shell, logger: logger, executablePath: nil)
    }

    init(homeProvider: TartHomeProvider, shell: Shell, logger: Logger?, executablePath: String?) {
        self.homeProvider = homeProvider
        self.shell = shell
        self.logger = logger
        self.executablePathOverride = executablePath
    }

    /// The directory tart keeps its virtual machines in: the configured home folder or `~/.tart`.
    public var homeFolderURL: URL {
        homeProvider.homeFolderURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(component: ".tart")
    }

    /// Where tart stores the files of the virtual machine named `name`.
    public func virtualMachineDirectoryURL(name: String) -> URL {
        homeFolderURL
            .appending(component: "vms", directoryHint: .isDirectory)
            .appending(component: name, directoryHint: .isDirectory)
    }

    public func clone(sourceName: String, newName: String) async throws {
        try await executeCommand(withArguments: ["clone", sourceName, newName])
    }

    /// Launches `tart run` and returns without waiting for it. The process exits when the guest powers off.
    public func launchRun(name: String) throws -> ShellProcess {
        let cacheFolder = homeFolderURL.appendingPathComponent("cache")
        if !FileManager.default.fileExists(atPath: cacheFolder.path) {
            try FileManager.default.createDirectory(atPath: cacheFolder.path, withIntermediateDirectories: true)
        }
        var runArgs = ["run", "--dir=cache:\(cacheFolder.path())"]
        if let tartRunOptions = ProcessInfo.processInfo.environment["TARTELET_RUN_OPTIONS"] {
            runArgs.append(tartRunOptions)
        }
        runArgs.append(name)
        return try launchCommand(withArguments: runArgs)
    }

    /// Asks tart to stop the running virtual machine: `SIGINT` to its process, `SIGKILL` after `timeout`.
    public func stop(name: String, timeout: Duration) async throws {
        let seconds = max(1, Int(timeout.components.seconds))
        do {
            try await executeCommand(withArguments: ["stop", name, "--timeout", String(seconds)])
        } catch {
            throw Self.mapError(error, virtualMachineName: name)
        }
    }

    public func delete(name: String) async throws {
        do {
            try await executeCommand(withArguments: ["delete", name])
        } catch {
            throw Self.mapError(error, virtualMachineName: name)
        }
    }

    public func list() async throws -> [String] {
        let result = try await executeCommand(withArguments: ["list", "-q", "--source", "local"])
        return result.split(separator: "\n").map(String.init)
    }

    public func getIPAddress(ofVirtualMachineNamed name: String) async throws -> String {
        do {
            let result = try await executeCommand(withArguments: ["ip", name])
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Self.mapError(error, virtualMachineName: name)
        }
    }
}

private extension Tart {
    private func executablePath() throws -> String {
        if let executablePathOverride {
            return executablePathOverride
        }
        return try TartLocator(shell: shell).locate()
    }

    @discardableResult
    private func executeCommand(withArguments arguments: [String]) async throws -> String {
        let filePath = try executablePath()
        if let environment {
            return try await shell.runExecutable(
                atPath: filePath,
                withArguments: arguments,
                environment: environment
            )
        } else {
            return try await shell.runExecutable(
                atPath: filePath,
                withArguments: arguments
            )
        }
    }

    private func launchCommand(withArguments arguments: [String]) throws -> ShellProcess {
        let filePath = try executablePath()
        if let environment {
            return try shell.launchExecutable(
                atPath: filePath,
                withArguments: arguments,
                environment: environment
            )
        } else {
            return try shell.launchExecutable(
                atPath: filePath,
                withArguments: arguments
            )
        }
    }

    /// Turns tart's stderr into typed errors for the cases the fleet has to tell apart.
    private static func mapError(_ error: Error, virtualMachineName name: String) -> Error {
        guard let executionError = error as? ShellExecutionError else {
            return error
        }
        let standardError = executionError.standardError
        if standardError.contains("does not exist") {
            return TartError.virtualMachineDoesNotExist(name)
        }
        if standardError.contains("is not running") {
            return TartError.virtualMachineIsNotRunning(name)
        }
        if standardError.contains("is running") {
            return TartError.virtualMachineIsRunning(name)
        }
        return error
    }
}
