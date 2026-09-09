import Foundation
import ShellDomain

/// Answers questions about host processes through `lsof` and `ps`.
struct HostProcessInspector {
    let shell: Shell

    /// Identifiers of the processes that hold the file open. Empty when nobody does.
    func processIdentifiers(holdingFileAt fileURL: URL) async throws -> [Int32] {
        let output: String
        do {
            output = try await shell.runExecutable(
                atPath: "/usr/sbin/lsof",
                withArguments: ["-t", "--", fileURL.path]
            )
        } catch let error as ShellExecutionError where error.terminationStatus == 1 {
            // lsof exits with 1 when no process holds the file.
            output = error.standardOutput
        }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    func commandName(ofProcess processIdentifier: Int32) async throws -> String {
        let output = try await shell.runExecutable(
            atPath: "/bin/ps",
            withArguments: ["-o", "comm=", "-p", String(processIdentifier)]
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
