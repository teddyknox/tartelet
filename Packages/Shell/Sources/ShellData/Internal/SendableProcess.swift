import Foundation

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
