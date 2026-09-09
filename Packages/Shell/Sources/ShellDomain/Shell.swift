public protocol Shell {
    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String]
    ) async throws -> String
    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) async throws -> String
    /// Launches the executable and returns immediately with a handle to the running process.
    ///
    /// The caller is responsible for waiting on the handle. See ``ShellProcess``.
    func launchExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) throws -> ShellProcess
}

public extension Shell {
    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration
    ) async throws -> String {
        try Task.checkCancellation()
        let process = try launchExecutable(atPath: executablePath, withArguments: arguments, environment: environment)
        return try await process.output(timeout: timeout)
    }

    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String]
    ) async throws -> String {
        try await runExecutable(
            atPath: executablePath,
            withArguments: arguments,
            environment: [:]
        )
    }

    func launchExecutable(
        atPath executablePath: String,
        withArguments arguments: [String]
    ) throws -> ShellProcess {
        try launchExecutable(
            atPath: executablePath,
            withArguments: arguments,
            environment: [:]
        )
    }
}
