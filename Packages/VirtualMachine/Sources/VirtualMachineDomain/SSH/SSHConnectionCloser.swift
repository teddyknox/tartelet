import Foundation
import SSHDomain

/// Cancellation and an operation's catch block may both request closure. The lock creates only
/// one close task; transport closure is bounded and independent of either caller's cancellation.
final class SSHConnectionCloser<Connection: SSHConnection>: @unchecked Sendable {
    private let connection: Connection
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(_ connection: Connection) { self.connection = connection }

    @discardableResult
    func begin() -> Task<Void, Never> {
        lock.withLock {
            if let task {
                return task
            }
            let connection = self.connection
            let task = Task.detached {
                _ = try? await withTimeout(.seconds(5)) { try await connection.close() }
            }
            self.task = task
            return task
        }
    }

    func close() async { await begin().value }
}
