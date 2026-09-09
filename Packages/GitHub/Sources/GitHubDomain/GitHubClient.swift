import Foundation

public protocol GitHubClient {
    func getAppAccessToken(runnerScope: GitHubRunnerScope) async throws -> GitHubAppAccessToken
    func getRunnerRegistrationToken(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> GitHubRunnerRegistrationToken
    func getRunnerDownloadURL(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> URL
    /// Lists every self-hosted runner registered in the scope, following pagination.
    func getRunners(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> [GitHubRunner]
}
