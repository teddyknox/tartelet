import Foundation

/// Configuration is set before launch. Registry membership is locked by ProcessRegistry;
/// ProcessShellProcess owns output/wait state and uses Foundation's process-status and signal APIs.
final class SendableProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

extension SendableProcess: Hashable {
    static func == (lhs: SendableProcess, rhs: SendableProcess) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
