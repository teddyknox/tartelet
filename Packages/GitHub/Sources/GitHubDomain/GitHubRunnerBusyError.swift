import Foundation

/// GitHub refused to delete a self-hosted runner because it is running a job (HTTP 422,
/// "Runner … is still running a job"). The registration is intact and the job is live.
public struct GitHubRunnerBusyError: LocalizedError, Equatable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }

    public var errorDescription: String? {
        "GitHub refused to delete runner \(id): it is still running a job"
    }
}
