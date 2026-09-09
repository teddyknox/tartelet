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
