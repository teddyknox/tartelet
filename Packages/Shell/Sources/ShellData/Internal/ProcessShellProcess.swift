import Foundation
import ShellDomain

/// ``ShellProcess`` backed by Foundation's `Process`.
///
/// Standard output and standard error are drained on dedicated threads so that a long-running
/// child such as `tart run` never blocks a thread of the Swift concurrency pool, and so that the
/// process cannot stall on a full pipe. Waiters are resumed once the process has exited and its
/// pipes have been drained (or shortly after exit if a grandchild keeps a pipe open).
final class ProcessShellProcess: ShellProcess, @unchecked Sendable {
    /// Keep at most this many bytes of each stream; `tart` writes very little, but a runaway child
    /// must not grow the app's memory without bound.
    private static let maximumCapturedBytes = 1_048_576
    /// How long to keep waiting for the pipes to hit EOF after the process has exited.
    private static let pipeDrainGracePeriod: TimeInterval = 3

    let executablePath: String
    let arguments: [String]

    var processIdentifier: Int32 {
        sendableProcess.process.processIdentifier
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !hasExited
    }

    private let sendableProcess: SendableProcess
    private let registry: ProcessRegistry?
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let lock = NSLock()
    private var standardOutputData = Data()
    private var standardErrorData = Data()
    private var hasExited = false
    private var openPipes = 2
    private var isFinished = false
    private var waiters: [() -> Void] = []

    init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        registry: ProcessRegistry?
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.registry = registry
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = nil
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.environment = environment
        sendableProcess = SendableProcess(process)
    }

    func launch() throws {
        let process = sendableProcess.process
        process.terminationHandler = { [weak self] _ in
            self?.didTerminate()
        }
        do {
            try process.run()
        } catch {
            // Nothing will ever write to the pipes, so close them to avoid leaking descriptors.
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForReading.close()
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            throw error
        }
        // Track the running process so the app can terminate it (and the virtual machine it
        // manages) when quitting, instead of leaking it. See `ProcessRegistry`.
        registry?.register(sendableProcess)
        // The parent must close its copies of the write ends, otherwise the read ends never see
        // EOF after the child exits.
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()
        startDraining(standardOutputPipe.fileHandleForReading, into: \.standardOutputData)
        startDraining(standardErrorPipe.fileHandleForReading, into: \.standardErrorData)
    }

    func interrupt() {
        signal(SIGINT)
    }

    func terminate() {
        signal(SIGTERM)
    }

    func kill() {
        signal(SIGKILL)
    }

    func waitForExit() async throws -> String {
        await waitUntilFinished()
        let status = sendableProcess.process.terminationStatus
        let (standardOutput, standardError) = capturedOutput()
        guard status == 0 else {
            throw ShellExecutionError(
                executablePath: executablePath,
                arguments: arguments,
                terminationStatus: status,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }
        return standardOutput
    }

    func waitForExit(timeout: Duration) async -> Bool {
        let timeoutSeconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        let box = ContinuationBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            box.continuation = continuation
            let finishedAlready: Bool = lock.withLock {
                if isFinished {
                    return true
                }
                waiters.append { box.resume(with: true) }
                return false
            }
            if finishedAlready {
                box.resume(with: true)
                return
            }
            // A dispatch timer rather than `Task.sleep` so the bound holds even when the awaiting
            // task has been cancelled, as it is while the fleet is being torn down.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                box.resume(with: false)
            }
        }
    }
}

private extension ProcessShellProcess {
    /// Resumes a `Bool` continuation exactly once, from whichever of exit or timeout comes first.
    final class ContinuationBox: @unchecked Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()

        func resume(with value: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    private func signal(_ signalNumber: Int32) {
        let process = sendableProcess.process
        guard process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, signalNumber)
    }

    private func startDraining(
        _ fileHandle: FileHandle,
        into keyPath: ReferenceWritableKeyPath<ProcessShellProcess, Data>
    ) {
        let thread = Thread { [self] in
            // Blocks until the write end is closed by every process holding it.
            let data = fileHandle.readDataToEndOfFile()
            // Explicitly close the pipe file handle to prevent running out of file descriptors.
            // See https://github.com/swiftlang/swift/issues/57827
            try? fileHandle.close()
            lock.lock()
            self[keyPath: keyPath] = Self.truncated(data)
            openPipes -= 1
            let finished = hasExited && openPipes == 0
            lock.unlock()
            if finished {
                finish()
            }
        }
        thread.name = "ProcessShell drain \(URL(fileURLWithPath: executablePath).lastPathComponent)"
        thread.start()
    }

    private func didTerminate() {
        registry?.unregister(sendableProcess)
        lock.lock()
        hasExited = true
        let finished = openPipes == 0
        lock.unlock()
        if finished {
            finish()
        } else {
            // A grandchild may still hold a pipe open. Do not make waiters depend on it.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeDrainGracePeriod) { [weak self] in
                self?.finish()
            }
        }
    }

    private func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter()
        }
    }

    private func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeNow: Bool = lock.withLock {
                if isFinished {
                    return true
                }
                waiters.append { continuation.resume() }
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    private func capturedOutput() -> (String, String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(data: standardOutputData, encoding: .utf8) ?? "",
            String(data: standardErrorData, encoding: .utf8) ?? ""
        )
    }

    private static func truncated(_ data: Data) -> Data {
        guard data.count > maximumCapturedBytes else {
            return data
        }
        return data.suffix(maximumCapturedBytes)
    }
}
