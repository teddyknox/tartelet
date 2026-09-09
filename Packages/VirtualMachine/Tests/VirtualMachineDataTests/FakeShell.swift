import Foundation
import ShellDomain

final class FakeShellProcess: ShellProcess, @unchecked Sendable {
    let processIdentifier: Int32 = 4_242
    private let lock = NSLock()
    private var running = true
    private var receivedSignals: [Int32] = []
    private var exitContinuations: [CheckedContinuation<Result<String, Error>, Never>] = []
    private var pendingExit: Result<String, Error>?

    var isRunning: Bool {
        lock.withLock { running }
    }

    var signals: [Int32] {
        lock.withLock { receivedSignals }
    }

    func interrupt() {
        lock.withLock { receivedSignals.append(SIGINT) }
    }

    func terminate() {
        lock.withLock { receivedSignals.append(SIGTERM) }
    }

    func kill() {
        lock.withLock { receivedSignals.append(SIGKILL) }
    }

    func waitForExit() async throws -> String {
        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            lock.lock()
            if let pendingExit {
                lock.unlock()
                continuation.resume(returning: pendingExit)
                return
            }
            exitContinuations.append(continuation)
            lock.unlock()
        }
        return try result.get()
    }

    func waitForExit(timeout: Duration) async -> Bool {
        !isRunning
    }

    /// Ends the process from the test's side.
    func exit(with result: Result<String, Error> = .success("")) {
        lock.lock()
        running = false
        pendingExit = result
        let continuations = exitContinuations
        exitContinuations = []
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}

final class FakeShell: Shell, @unchecked Sendable {
    struct Invocation: Equatable {
        let path: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recordedInvocations: [Invocation] = []
    private var launched: [FakeShellProcess] = []

    /// Decides the outcome of `runExecutable` by executable path and arguments.
    var responder: (String, [String]) -> Result<String, Error> = { _, _ in .success("") }

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    var launchedProcesses: [FakeShellProcess] {
        lock.withLock { launched }
    }

    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        lock.withLock { recordedInvocations.append(Invocation(path: executablePath, arguments: arguments)) }
        return try responder(executablePath, arguments).get()
    }

    func launchExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) throws -> ShellProcess {
        let process = FakeShellProcess()
        lock.withLock {
            recordedInvocations.append(Invocation(path: executablePath, arguments: arguments))
            launched.append(process)
        }
        return process
    }
}

extension ShellExecutionError {
    static func tart(status: Int32, standardError: String = "", standardOutput: String = "") -> ShellExecutionError {
        ShellExecutionError(
            executablePath: "/opt/homebrew/bin/tart",
            arguments: [],
            terminationStatus: status,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}
