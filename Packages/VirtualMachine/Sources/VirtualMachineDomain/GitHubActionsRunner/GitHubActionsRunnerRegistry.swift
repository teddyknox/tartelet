import Foundation
import GitHubDomain

/// What GitHub currently reports for one runner name.
///
/// Replacement can reuse an id while a prior listener session is still live. The guest must
/// report its configured agentId; a change in the runner list alone does not establish identity.
public enum GitHubActionsRunnerStatus: Equatable {
    /// No runner with the name is listed. An ephemeral runner disappears once its job is done.
    case unregistered
    case online(id: Int, isBusy: Bool)
    case offline(id: Int)

    public var id: Int? {
        switch self {
        case .unregistered:
            nil
        case let .online(id, _):
            id
        case let .offline(id):
            id
        }
    }
}

/// Looks up the registration state of the runner a fleet slot is responsible for.
public protocol GitHubActionsRunnerRegistry {
    func deregisterRunner(id: Int) async throws
    func status(ofRunnerNamed name: String) async throws -> GitHubActionsRunnerStatus
}

/// ``GitHubActionsRunnerRegistry`` backed by the GitHub API, polled with the app installation token.
///
/// Installation tokens are valid for an hour; one is cached and reused so a 30-second poll costs a
/// single request. Any failure drops the cached token so the next poll starts from a fresh one.
public actor GitHubClientActionsRunnerRegistry: GitHubActionsRunnerRegistry {
    private let client: GitHubClient
    private let configuration: GitHubActionsRunnerConfiguration
    private let tokenLifetime: TimeInterval
    private var cachedToken: (token: GitHubAppAccessToken, obtainedAt: Date)?

    public init(
        client: GitHubClient,
        configuration: GitHubActionsRunnerConfiguration,
        tokenLifetime: TimeInterval = 45 * 60
    ) {
        self.client = client
        self.configuration = configuration
        self.tokenLifetime = tokenLifetime
    }

    public func deregisterRunner(id: Int) async throws {
        do {
            let token = try await accessToken()
            try Task.checkCancellation()
            try await client.deleteRunner(id: id, with: token, runnerScope: configuration.runnerScope)
        } catch {
            cachedToken = nil
            throw error
        }
    }

    public func status(ofRunnerNamed name: String) async throws -> GitHubActionsRunnerStatus {
        let token = try await accessToken()
        let runners: [GitHubRunner]
        do {
            runners = try await client.getRunners(with: token, runnerScope: configuration.runnerScope)
        } catch {
            cachedToken = nil
            throw error
        }
        guard let runner = runners.first(where: { $0.name == name }) else {
            return .unregistered
        }
        return runner.isOnline ? .online(id: runner.id, isBusy: runner.isBusy) : .offline(id: runner.id)
    }
}

private extension GitHubClientActionsRunnerRegistry {
    private func accessToken() async throws -> GitHubAppAccessToken {
        if let cachedToken, Date().timeIntervalSince(cachedToken.obtainedAt) < tokenLifetime {
            return cachedToken.token
        }
        let token = try await client.getAppAccessToken(runnerScope: configuration.runnerScope)
        cachedToken = (token, Date())
        return token
    }
}
