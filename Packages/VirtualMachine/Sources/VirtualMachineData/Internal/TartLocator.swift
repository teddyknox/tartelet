import Foundation
import ShellDomain

enum TartLocatorError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Tart could not be found"
        }
    }
}

struct TartLocator {
    let shell: Shell
    var candidates = ["/opt/homebrew/bin/tart", "/Applications/tart.app/Contents/MacOS/tart"]

    func locate() throws -> String {
        let fileManager: FileManager = .default
        guard let filePath = candidates.first(where: { fileManager.fileExists(atPath: $0) }) else {
            throw TartLocatorError.notFound
        }
        let executable = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
        let bin = executable.deletingLastPathComponent()
        let version = bin.deletingLastPathComponent()
        let formula = version.deletingLastPathComponent()
        // Homebrew's bin/tart is a shell wrapper which execs this bundled binary. Use the
        // same native path for launch and orphan identification; the wrapper never owns a VM.
        if bin.lastPathComponent == "bin",
           formula.lastPathComponent == "tart",
           formula.deletingLastPathComponent().lastPathComponent == "Cellar" {
            let native = version.appendingPathComponent("libexec/tart.app/Contents/MacOS/tart")
            if fileManager.isExecutableFile(atPath: native.path) {
                return native.resolvingSymlinksInPath().path
            }
        }
        return executable.path
    }
}
