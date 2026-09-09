import Foundation
import GitHubDomain
import VirtualMachineDomain
import XCTest

final class GitHubClientActionsRunnerRegistryTests: XCTestCase {
    private var client = FakeGitHubClient()
    private var registry = GitHubClientActionsRunnerRegistry(
        client: FakeGitHubClient(),
        configuration: FakeRunnerConfiguration()
    )

    override func setUp() {
        super.setUp()
        client = FakeGitHubClient()
        registry = GitHubClientActionsRunnerRegistry(client: client, configuration: FakeRunnerConfiguration())
    }

    func testStatusMapping() async throws {
        client.runners = [
            GitHubRunner(id: 1, name: "runner 1", isOnline: true, isBusy: true),
            GitHubRunner(id: 2, name: "runner 2", isOnline: true, isBusy: false),
            GitHubRunner(id: 3, name: "runner 3", isOnline: false, isBusy: false)
        ]

        let busy = try await registry.status(ofRunnerNamed: "runner 1")
        let idle = try await registry.status(ofRunnerNamed: "runner 2")
        let offline = try await registry.status(ofRunnerNamed: "runner 3")
        let missing = try await registry.status(ofRunnerNamed: "runner 4")

        XCTAssertEqual(busy, .online(id: 1, isBusy: true))
        XCTAssertEqual(idle, .online(id: 2, isBusy: false))
        XCTAssertEqual(offline, .offline(id: 3))
        XCTAssertEqual(missing, .unregistered)
    }

    func testMatchesExactNameOnly() async throws {
        client.runners = [GitHubRunner(id: 1, name: "runner 12", isOnline: true, isBusy: false)]

        let status = try await registry.status(ofRunnerNamed: "runner 1")

        XCTAssertEqual(status, .unregistered)
    }

    func testTokenIsReusedAcrossPolls() async throws {
        _ = try await registry.status(ofRunnerNamed: "runner 1")
        _ = try await registry.status(ofRunnerNamed: "runner 1")
        _ = try await registry.status(ofRunnerNamed: "runner 1")

        XCTAssertEqual(client.tokenRequests, 1)
        XCTAssertEqual(client.listRequests, 3)
    }

    func testTokenIsDroppedAfterFailure() async throws {
        _ = try await registry.status(ofRunnerNamed: "runner 1")
        client.listError = FakeAPIError()
        do {
            _ = try await registry.status(ofRunnerNamed: "runner 1")
            XCTFail("expected the API error to propagate")
        } catch {}
        client.listError = nil
        _ = try await registry.status(ofRunnerNamed: "runner 1")

        XCTAssertEqual(client.tokenRequests, 2)
    }

    func testTokenIsRefreshedAfterItsLifetime() async throws {
        registry = GitHubClientActionsRunnerRegistry(
            client: client,
            configuration: FakeRunnerConfiguration(),
            tokenLifetime: 0
        )

        _ = try await registry.status(ofRunnerNamed: "runner 1")
        _ = try await registry.status(ofRunnerNamed: "runner 1")

        XCTAssertEqual(client.tokenRequests, 2)
    }
}

private struct FakeRunnerConfiguration: GitHubActionsRunnerConfiguration {
    var runnerDisableDefaultLabels = false
    var runnerDisableUpdates = false
    var runnerScope: GitHubRunnerScope = .repo
    var runnerLabels = "tartelet"
    var runnerGroup = ""
    var runnerName = "runner"
}

private final class FakeGitHubClient: GitHubClient, @unchecked Sendable {
    var runners: [GitHubRunner] = []
    var listError: Error?
    private(set) var tokenRequests = 0
    private(set) var listRequests = 0

    func getAppAccessToken(runnerScope: GitHubRunnerScope) async throws -> GitHubAppAccessToken {
        tokenRequests += 1
        return GitHubAppAccessToken("token-\(tokenRequests)")
    }

    func getRunnerRegistrationToken(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> GitHubRunnerRegistrationToken {
        GitHubRunnerRegistrationToken("registration")
    }

    func getRunnerDownloadURL(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> URL {
        URL(string: "https://example.com/runner.tar.gz")!
    }

    func getRunners(
        with appAccessToken: GitHubAppAccessToken,
        runnerScope: GitHubRunnerScope
    ) async throws -> [GitHubRunner] {
        listRequests += 1
        if let listError {
            throw listError
        }
        return runners
    }
}
