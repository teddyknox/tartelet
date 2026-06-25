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
        let process = Process()
        let sendableProcess = SendableProcess(process)
        return try await withTaskCancellationHandler {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.arguments = arguments
            process.launchPath = executablePath
            process.standardInput = nil
            process.environment = environment
            try process.run()
            // Track the running process so the app can terminate it (and the virtual machine it
            // manages) when quitting, instead of leaking it. See `ProcessRegistry`.
            processRegistry?.register(sendableProcess)
            defer { processRegistry?.unregister(sendableProcess) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Explicitly close the pipe file handle to prevent running out of file descriptors.
            // See https://github.com/swiftlang/swift/issues/57827
            try pipe.fileHandleForReading.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProcessShellError.unexpectedTerminationStatus(process.terminationStatus)
            }
            return String(data: data, encoding: .utf8) ?? ""
        } onCancel: {
            // Send `SIGINT` (as Ctrl-C would) rather than `SIGTERM` so `tart` shuts its virtual
            // machine down cleanly instead of being killed and leaking the machine.
            if sendableProcess.process.isRunning {
                sendableProcess.process.interrupt()
            }
        }
    }
}
