import Foundation

public struct ShellProcessTimeoutError: LocalizedError {
    /// Retains ownership if the child has not exited; callers must not reuse its mutation target.
    public let process: ShellProcess
    public var processIdentifier: Int32 { process.processIdentifier }
    public let didExit: Bool

    public init(process: ShellProcess, didExit: Bool) {
        self.process = process
        self.didExit = didExit
    }

    public var errorDescription: String? {
        "Process \(processIdentifier) exceeded its deadline"
            + (didExit ? " and was stopped" : " and has not exited after SIGKILL")
    }
}
