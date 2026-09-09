import Foundation

/// A self-hosted runner as listed by GitHub for an organization or a repository.
public struct GitHubRunner: Equatable {
    public let id: Int
    public let name: String
    /// Whether GitHub reports the runner as `online`. Any other status (`offline`) is reported as `false`.
    public let isOnline: Bool
    /// Whether the runner is currently executing a job.
    public let isBusy: Bool

    public init(id: Int, name: String, isOnline: Bool, isBusy: Bool) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
        self.isBusy = isBusy
    }
}
