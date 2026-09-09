import Foundation
import ShellDomain

public struct ProcessShell: Shell {
    private let processRegistry: ProcessRegistry?

    public init(processRegistry: ProcessRegistry? = nil) {
        self.processRegistry = processRegistry
    }

    public func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        try await runExecutable(
            atPath: executablePath,
            withArguments: arguments,
            environment: environment,
            timeout: .seconds(60)
        )
    }

    public func launchExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) throws -> ShellProcess {
        try launchProcess(
            atPath: executablePath,
            withArguments: arguments,
            environment: environment
        )
    }
}

private extension ProcessShell {
    private func launchProcess(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) throws -> ProcessShellProcess {
        let process = ProcessShellProcess(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            registry: processRegistry
        )
        try process.launch()
        return process
    }
}
