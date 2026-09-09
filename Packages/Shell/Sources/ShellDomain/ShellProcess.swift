import Foundation

/// A handle to a single running executable launched through a ``Shell``.
///
/// Unlike ``Shell/runExecutable(atPath:withArguments:environment:)``, which blocks until the
/// process exits and can only be stopped through task cancellation, a handle lets the caller
/// signal one specific invocation and wait for it with a bound. This is what the fleet uses to
/// force-stop a wedged `tart run` without cancelling the whole fleet.
public protocol ShellProcess: AnyObject, Sendable {
    /// Identifier of the running process.
    var processIdentifier: Int32 { get }
    /// Whether the process has not exited yet.
    var isRunning: Bool { get }
    /// Sends `SIGINT`, as Ctrl-C would. `tart run` responds by stopping its virtual machine and exiting.
    func interrupt()
    /// Sends `SIGTERM`.
    func terminate()
    /// Sends `SIGKILL`. The process cannot ignore this.
    func kill()
    /// Waits for the process to exit and returns its standard output.
    ///
    /// Throws ``ShellExecutionError`` when the process exits with a non-zero status. The wait is not
    /// interrupted by task cancellation; use ``waitForExit(timeout:)`` to bound it.
    func waitForExit() async throws -> String
    /// Waits up to `timeout` for the process to exit.
    ///
    /// Returns `true` when the process has exited. The wait is unaffected by task cancellation so
    /// that a forced stop can complete its escalation even while the fleet is being torn down.
    func waitForExit(timeout: Duration) async -> Bool
}

public extension ShellProcess {
    /// Bounds a command and reaps it before returning. Cancellation skips the remaining command
    /// budget; signal escalation uses cancellation-independent waits supplied by the handle.
    func output(
        timeout: Duration? = nil,
        interruptGrace: Duration = .seconds(2),
        killGrace: Duration = .seconds(5)
    ) async throws -> String {
        let race = ProcessExitRace()
        Task {
            if let timeout {
                race.resolve(await self.waitForExit(timeout: timeout))
            } else {
                _ = try? await self.waitForExit()
                race.resolve(true)
            }
        }
        return try await withTaskCancellationHandler {
            // The unstructured task only waits; command ownership stays here through escalation.
            let exited = await race.wait()
            if !exited {
                interrupt()
                if !(await waitForExit(timeout: interruptGrace)) {
                    kill()
                }
                let didExit = await waitForExit(timeout: killGrace)
                if Task.isCancelled, didExit {
                    throw CancellationError()
                }
                throw ShellProcessTimeoutError(process: self, didExit: didExit)
            }
            try Task.checkCancellation()
            return try await waitForExit()
        } onCancel: {
            race.resolve(false)
        }
    }
}

/// Cancellation and process completion may arrive before the waiter is installed. All state is
/// protected by the lock; exactly one result and one continuation are delivered.
private final class ProcessExitRace: @unchecked Sendable {
    private enum Outcome { case exited, expired }
    private let lock = NSLock()
    private var result: Outcome?
    private var continuation: CheckedContinuation<Bool, Never>?

    func resolve(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result ? .exited : .expired
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result == .exited)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
