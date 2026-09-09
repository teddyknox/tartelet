import Foundation
import ShellDomain

/// Signals and timeout waits match ProcessShell: SIGINT normally exits zero; timed waits ignore
/// Swift cancellation. All mutable process state is protected by the lock.
final class FakeShellProcess: ShellProcess, @unchecked Sendable {
    let processIdentifier: Int32 = 4_242
    var ignoresInterrupt = false  // configured before the process is used
    private let lock = NSLock()
    private var receivedSignals: [Int32] = []
    private var result: Result<String, Error>?
    private var waiters: [UUID: (Bool) -> Void] = [:]
    var isRunning: Bool { lock.withLock { result == nil } }
    var signals: [Int32] { lock.withLock { receivedSignals } }

    func interrupt() {
        lock.withLock { receivedSignals.append(SIGINT) }
        if !ignoresInterrupt { exit() }
    }
    func terminate() { signal(SIGTERM) }
    func kill() { signal(SIGKILL) }
    private func signal(_ number: Int32) {
        lock.withLock { receivedSignals.append(number) }
        exit(with: .failure(ShellExecutionError.tart(status: number)))
    }
    func waitForExit() async throws -> String {
        _ = await wait(timeout: nil)
        return try lock.withLock { try result!.get() }
    }
    func waitForExit(timeout: Duration) async -> Bool { await wait(timeout: timeout) }
    private func wait(timeout: Duration?) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let exited = lock.withLock {
                if result != nil {
                    return true
                }
                waiters[id] = { continuation.resume(returning: $0) }
                return false
            }
            if exited {
                continuation.resume(returning: true)
            } else if let timeout {
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                    lock.withLock { waiters.removeValue(forKey: id) }?(false)
                }
            }
        }
    }
    func exit(with result: Result<String, Error> = .success("")) {
        let callbacks: [(Bool) -> Void] = lock.withLock {
            guard self.result == nil else {
                return []
            }
            self.result = result
            let callbacks = Array(waiters.values)
            waiters.removeAll()
            return callbacks
        }
        callbacks.forEach { $0(true) }
    }
}

final class FakeShell: Shell, @unchecked Sendable {
    struct Invocation { let path: String; let arguments: [String]; let environment: [String: String] }
    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private var processes: [FakeShellProcess] = []
    var responder: (String, [String]) -> Result<String, Error> = { _, _ in .success("") }
    var runIgnoresInterrupt = false
    var invocations: [Invocation] { lock.withLock { recorded } }
    var launchedProcesses: [FakeShellProcess] { lock.withLock { processes } }

    func runExecutable(atPath path: String, withArguments arguments: [String], environment: [String: String])
        async throws -> String {
        try await runExecutable(atPath: path, withArguments: arguments, environment: environment, timeout: .seconds(60))
    }
    func launchExecutable(atPath path: String, withArguments arguments: [String], environment: [String: String]) throws
        -> ShellProcess {
        let process = FakeShellProcess()
        if arguments.first == "run" { process.ignoresInterrupt = runIgnoresInterrupt }
        lock.withLock { recorded.append(Invocation(path: path, arguments: arguments, environment: environment)) }
        if arguments.first != "run" { process.exit(with: responder(path, arguments)) }
        lock.withLock { processes.append(process) }
        return process
    }
}

extension ShellExecutionError {
    static func tart(status: Int32, standardError: String = "") -> ShellExecutionError {
        ShellExecutionError(
            executablePath: "/opt/homebrew/bin/tart",
            arguments: [],
            terminationStatus: status,
            standardOutput: "",
            standardError: standardError
        )
    }
}
