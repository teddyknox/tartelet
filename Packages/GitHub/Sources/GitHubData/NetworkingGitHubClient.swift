import Foundation
import GitHubDomain
import NetworkingDomain

private enum NetworkingGitHubClientError: LocalizedError {
    case organizationNameUnavailable
    case repositoryNameUnavailable
    case repositoryOwnerNameUnavailable
    case appIDUnavailable
    case privateKeyUnavailable
    case appIsNotInstalled
    case downloadNotFound(os: String, architecture: String)
    case invalidRunnersURL

    var errorDescription: String? {
        switch self {
        case .organizationNameUnavailable:
            return "The organization name is not available"
        case .repositoryNameUnavailable:
            return "The repository name is not available"
        case .repositoryOwnerNameUnavailable:
            return "The repository owner name is not available"
        case .appIDUnavailable:
            return "The app ID is not available"
        case .privateKeyUnavailable:
            return "The private key is not available"
        case .appIsNotInstalled:
            return "The GitHub app has not been installed. Please install it from the developer settings."
        case let .downloadNotFound(os, architecture):
            return "Could not find a download for \(os) (\(architecture))"
        case .invalidRunnersURL:
            return "Could not build the URL for listing runners"
        }
    }
}

public final class NetworkingGitHubClient: GitHubClient {
    private let baseURL = URL(string: "https://api.github.com")!
    private let credentialsStore: GitHubCredentialsStore
    private let networkingService: NetworkingService

    public init(credentialsStore: GitHubCredentialsStore, networkingService: NetworkingService) {
        self.credentialsStore = credentialsStore
        self.networkingService = networkingService
    }

    public func getAppAccessToken(runnerScope: GitHubRunnerScope) async throws -> GitHubAppAccessToken {
        let appInstallation = try await getAppInstallation(runnerScope: runnerScope)
        let installationID = String(appInstallation.id)
        let appID = String(appInstallation.appId)
        let url = baseURL.appending(path: "/app/installations/\(installationID)/access_tokens")
        guard let privateKey = credentialsStore.privateKey else {
            throw NetworkingGitHubClientError.privateKeyUnavailable
        }
        let jwtToken = try GitHubJWTTokenFactory.makeJWTToken(privateKey: privateKey, appID: appID)
        var request = URLRequest(url: url).addingBearerToken(jwtToken)
        request.httpMethod = "POST"
        return try await networkingService.load(
            IntermediateGitHubAppAccessToken.self,
            from: request
        ).map { parameters in
            GitHubAppAccessToken(parameters.value.token)
        }
    }

    public func getRunnerDownloadURL(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> URL {
        let url = try await baseURL.appending(path: runnerScope.runnerDownloadPath(using: credentialsStore))
        let request = URLRequest(url: url).addingBearerToken(appAccessToken.rawValue)
        let downloads = try await networkingService.load([GitHubRunnerDownload].self, from: request).map(\.value)
        let os = "osx"
        let architecture = "arm64"
        guard let download = downloads.first(where: { $0.os == os && $0.architecture == architecture }) else {
            throw NetworkingGitHubClientError.downloadNotFound(os: os, architecture: architecture)
        }
        return download.downloadURL
    }

    public func getRunnerRegistrationToken(
      with appAccessToken: GitHubAppAccessToken,
      runnerScope: GitHubRunnerScope
    ) async throws -> GitHubRunnerRegistrationToken {
        let url = try await baseURL.appending(path: runnerScope.runnerRegistrationPath(using: credentialsStore))
        var request = URLRequest(url: url).addingBearerToken(appAccessToken.rawValue)
        request.httpMethod = "POST"
        return try await networkingService.load(
            IntermediateGitHubRunnerRegistrationToken.self,
            from: request
        ).map { parameters in
            GitHubRunnerRegistrationToken(parameters.value.token)
        }
    }

    public func getRunners(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> [GitHubRunner] {
        let path = try await runnerScope.runnersPath(using: credentialsStore)
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard var pageURL = components?.url else {
            throw NetworkingGitHubClientError.invalidRunnersURL
        }
        var runners: [GitHubRunner] = []
        // GitHub paginates with a `Link` header. Bound the walk so a misbehaving server can't keep us here.
        for _ in 0 ..< Self.maximumRunnerPages {
            let request = URLRequest(url: pageURL).addingBearerToken(appAccessToken.rawValue)
            let response = await networkingService.load(GitHubRunnerListPage.self, from: request)
            let page = try response.map(\.value)
            runners += page.runners.map { runner in
                GitHubRunner(
                    id: runner.id,
                    name: runner.name,
                    isOnline: runner.status == "online",
                    isBusy: runner.busy
                )
            }
            guard let nextPageURL = response.httpURLResponse?.nextPageURL else {
                return runners
            }
            pageURL = nextPageURL
        }
        return runners
    }
}

private extension NetworkingGitHubClient {
    private static let maximumRunnerPages = 50

    private func getAppInstallation(runnerScope: GitHubRunnerScope) async throws -> GitHubAppInstallation {
        let url = baseURL.appending(path: "/app/installations")
        let token = try await getAppJWTToken()
        let request = URLRequest(url: url).addingBearerToken(token)
        let appInstallations = try await networkingService.load(
            [GitHubAppInstallation].self,
            from: request
        ).map(\.value)
        let loginName = await runnerScope.runnerLogin(using: credentialsStore)
        guard let appInstallation = appInstallations.first(where: { $0.account.login == loginName }) else {
            throw NetworkingGitHubClientError.appIsNotInstalled
        }
        return appInstallation
    }

    private func getAppJWTToken() async throws -> String {
        guard let privateKey = credentialsStore.privateKey else {
            throw NetworkingGitHubClientError.privateKeyUnavailable
        }
        guard let appID = credentialsStore.appId else {
            throw NetworkingGitHubClientError.appIDUnavailable
        }
        return try GitHubJWTTokenFactory.makeJWTToken(privateKey: privateKey, appID: appID)
    }
}

private extension URLRequest {
    func addingBearerToken(_ token: String) -> URLRequest {
        var mutableRequest = self
        mutableRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return mutableRequest
    }
}

private extension GitHubRunnerScope {
    func runnerRegistrationPath(using credentialsStore: GitHubCredentialsStore) async throws -> String {
        switch self {
        case .organization:
            guard let organizationName = credentialsStore.organizationName else {
                throw NetworkingGitHubClientError.organizationNameUnavailable
            }
            return "/orgs/\(organizationName)/actions/runners/registration-token"
        case .repo:
            guard let repositoryName = credentialsStore.repositoryName else {
                throw NetworkingGitHubClientError.repositoryNameUnavailable
            }
            guard let ownerName = credentialsStore.ownerName else {
                throw NetworkingGitHubClientError.repositoryOwnerNameUnavailable
            }

            return "/repos/\(ownerName)/\(repositoryName)/actions/runners/registration-token"
        }
    }

    func runnerDownloadPath(using credentialsStore: GitHubCredentialsStore) async throws -> String {
        switch self {
        case .organization:
            guard let organizationName = credentialsStore.organizationName else {
                throw NetworkingGitHubClientError.organizationNameUnavailable
            }
            return "/orgs/\(organizationName)/actions/runners/downloads"
        case .repo:
            guard let repositoryName = credentialsStore.repositoryName else {
                throw NetworkingGitHubClientError.repositoryNameUnavailable
            }
            guard let ownerName = credentialsStore.ownerName else {
                throw NetworkingGitHubClientError.repositoryOwnerNameUnavailable
            }
            return "/repos/\(ownerName)/\(repositoryName)/actions/runners/downloads"
        }
    }

    func runnersPath(using credentialsStore: GitHubCredentialsStore) async throws -> String {
        switch self {
        case .organization:
            guard let organizationName = credentialsStore.organizationName else {
                throw NetworkingGitHubClientError.organizationNameUnavailable
            }
            return "/orgs/\(organizationName)/actions/runners"
        case .repo:
            guard let repositoryName = credentialsStore.repositoryName else {
                throw NetworkingGitHubClientError.repositoryNameUnavailable
            }
            guard let ownerName = credentialsStore.ownerName else {
                throw NetworkingGitHubClientError.repositoryOwnerNameUnavailable
            }
            return "/repos/\(ownerName)/\(repositoryName)/actions/runners"
        }
    }

    func runnerLogin(using credentialsStore: GitHubCredentialsStore) async -> String? {
        switch self {
        case .organization:
            return credentialsStore.organizationName
        case .repo:
            return credentialsStore.ownerName
        }
    }
}

private extension HTTPURLResponse {
    /// The `rel="next"` URL of a `Link` header, e.g.
    /// `<https://api.github.com/repositories/1/actions/runners?per_page=100&page=2>; rel="next", <...>; rel="last"`.
    var nextPageURL: URL? {
        guard let link = value(forHTTPHeaderField: "Link") else {
            return nil
        }
        for entry in link.split(separator: ",") {
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, parts.dropFirst().contains(where: { $0 == "rel=\"next\"" }) else {
                continue
            }
            let target = parts[0]
            guard target.hasPrefix("<"), target.hasSuffix(">") else {
                continue
            }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }
}
