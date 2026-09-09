import Foundation

/// Thrown when an executable exits with a non-zero termination status.
///
/// Carries the process' standard error so callers can tell failure modes apart, e.g. `tart delete`
/// reporting that a virtual machine does not exist versus that it is still running.
public struct ShellExecutionError: LocalizedError {
    public let executablePath: String
    public let arguments: [String]
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(
        executablePath: String,
        arguments: [String],
        terminationStatus: Int32,
        standardOutput: String,
        standardError: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var errorDescription: String? {
        let trimmedStandardError = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedStandardError.isEmpty {
            return "Unexpected termination status: \(terminationStatus)"
        }
        return "Unexpected termination status: \(terminationStatus): \(trimmedStandardError)"
    }
}
