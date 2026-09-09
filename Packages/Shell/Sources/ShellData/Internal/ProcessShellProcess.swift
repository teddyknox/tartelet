import Foundation
import ShellDomain

/// Process state, output and waiter ownership are protected by `lock`. Pipe reads run on
/// dedicated dispatch queues, never on Swift's cooperative executor, and never block at EOF.
final class ProcessShellProcess: ShellProcess, @unchecked Sendable {
    private static let maximumCapturedBytes = 1_048_576
    private static let pipeDrainGracePeriod: TimeInterval = 3

    let executablePath: String
    let arguments: [String]
    var processIdentifier: Int32 { sendableProcess.process.processIdentifier }
    var isRunning: Bool { lock.withLock { !hasExited } }

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
    private var waiters: [UUID: (Bool) -> Void] = [:]
    private var readers: [ProcessPipeReader] = []

    init(executablePath: String, arguments: [String], environment: [String: String], registry: ProcessRegistry?) {
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
        // Keep the handle alive if its caller drops it. finish() breaks this cycle after both
        // termination and reader cancellation, so registry removal and descriptor closure finish.
        process.terminationHandler = { [self] _ in didTerminate() }
        readers = [
            makeReader(standardOutputPipe.fileHandleForReading, into: \.standardOutputData),
            makeReader(standardErrorPipe.fileHandleForReading, into: \.standardErrorData)
        ]
        do {
            if let registry {
                try registry.launch(sendableProcess)
            } else {
                try process.run()
            }
        } catch {
            process.terminationHandler = nil
            readers.forEach { $0.cancel() }
            closeWriteEnds()
            throw error
        }
        closeWriteEnds()
    }

    func interrupt() { signal(SIGINT) }
    func terminate() { signal(SIGTERM) }
    func kill() { signal(SIGKILL) }

    func waitForExit() async throws -> String {
        _ = await wait(timeout: nil)
        let status = sendableProcess.process.terminationStatus
        let (standardOutput, standardError) = lock.withLock {
            // A tail can start inside a UTF-8 scalar. Preserve the rest of the diagnostics.
            // swiftlint:disable:next optional_data_string_conversion
            (String(decoding: standardOutputData, as: UTF8.self), String(decoding: standardErrorData, as: UTF8.self))
        }
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
        await wait(timeout: timeout)
    }
}

private extension ProcessShellProcess {
    func closeWriteEnds() {
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()
    }

    func signal(_ number: Int32) {
        let process = sendableProcess.process
        guard process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, number)
    }

    func makeReader(
        _ handle: FileHandle,
        into keyPath: ReferenceWritableKeyPath<ProcessShellProcess, Data>
    ) -> ProcessPipeReader {
        ProcessPipeReader(handle: handle) { [weak self] data in
            guard let self else {
                return
            }
            lock.withLock {
                self[keyPath: keyPath].append(data)
                if self[keyPath: keyPath].count > Self.maximumCapturedBytes {
                    self[keyPath: keyPath] = Data(self[keyPath: keyPath].suffix(Self.maximumCapturedBytes))
                }
            }
        } didClose: { [weak self] in
            guard let self else {
                return
            }
            let finished = lock.withLock {
                self.openPipes -= 1
                return self.hasExited && self.openPipes == 0
            }
            if finished { finish() }
        }
    }

    func didTerminate() {
        registry?.unregister(sendableProcess)
        let finished = lock.withLock {
            hasExited = true
            return openPipes == 0
        }
        if finished {
            finish()
        } else {
            // Cancellation closes descriptors and publishes partial data before callers resume.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeDrainGracePeriod) { [weak self] in
                self?.readers.forEach { $0.cancel() }
            }
        }
    }

    func finish() {
        let callbacks: [(Bool) -> Void] = lock.withLock {
            guard !isFinished else {
                return []
            }
            isFinished = true
            let callbacks = Array(waiters.values)
            waiters.removeAll()
            return callbacks
        }
        sendableProcess.process.terminationHandler = nil
        callbacks.forEach { $0(true) }
    }

    func wait(timeout: Duration?) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let finished = lock.withLock {
                if isFinished {
                    return true
                }
                waiters[id] = { continuation.resume(returning: $0) }
                return false
            }
            if finished {
                continuation.resume(returning: true)
            } else if let timeout {
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self else {
                        return
                    }
                    let callback = lock.withLock { self.waiters.removeValue(forKey: id) }
                    callback?(false)
                }
            }
        }
    }
}
