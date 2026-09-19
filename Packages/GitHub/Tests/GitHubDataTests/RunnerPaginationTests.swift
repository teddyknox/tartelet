import Foundation
import GitHubData
import GitHubDomain
import NetworkingDomain
import XCTest

final class RunnerPaginationTests: XCTestCase {
    func testFollowsNextLinkWithHundredPerPageInBothScopes() async throws {
        for (scope, path) in [
            (GitHubRunnerScope.organization, "/orgs/org/actions/runners"), (.repo, "/repos/owner/repo/actions/runners")
        ] {
            let network = PageNetwork { _, index in
                let next = "https://api.github.com\(path)?per_page=100&page=2"
                let headers =
                    index == 0
                    ? [
                        "Link":
                            "<\(next)>; rel=\"next\", <\(next)>; rel=\"last\""
                    ] : [:]
                return PageReply(data: Self.page(id: index + 1), headers: headers)
            }
            let client = NetworkingGitHubClient(credentialsStore: Credentials(), networkingService: network)
            let runners = try await client.getRunners(with: GitHubAppAccessToken("test"), runnerScope: scope)
            XCTAssertEqual(runners.map(\.id), [1, 2])
            XCTAssertEqual(network.requests.count, 2)
            XCTAssertEqual(network.requests.first?.url?.path, path)
            XCTAssertTrue(network.requests.allSatisfy { $0.url?.query?.contains("per_page=100") == true })
            XCTAssertTrue(
                network.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test" }
            )
            XCTAssertTrue(runners[0].isOnline)
            XCTAssertFalse(runners[0].isBusy)
        }
    }

    func testNoNextLinkCompletesEvenWithOtherLinkRelations() async throws {
        let network = PageNetwork { _, _ in
            PageReply(data: Self.page(id: 1), headers: ["Link": "<https://api.github.com/previous>; rel=\"prev\""])
        }
        let client = NetworkingGitHubClient(credentialsStore: Credentials(), networkingService: network)
        let runners = try await client.getRunners(with: GitHubAppAccessToken("test"), runnerScope: .organization)
        XCTAssertEqual(runners.count, 1)
        XCTAssertEqual(network.requests.count, 1)
    }

    func testPaginationLimitAndPageFailureNeverReturnPartialList() async throws {
        for failingPage in [2, 51] {
            let network = PageNetwork { _, index in
                let next = "https://api.github.com/orgs/org/actions/runners?per_page=100&page=\(index + 2)"
                return PageReply(
                    data: Self.page(id: index),
                    headers: ["Link": "<\(next)>; rel=\"next\""],
                    error: index + 1 == failingPage ? TestError() : nil
                )
            }
            let client = NetworkingGitHubClient(credentialsStore: Credentials(), networkingService: network)
            do {
                _ = try await client.getRunners(with: GitHubAppAccessToken("test"), runnerScope: .organization)
                XCTFail("partial list")
            } catch {}
            XCTAssertEqual(network.requests.count, min(failingPage, 50))
        }
    }

    func testDeletesExactRunnerInBothScopesAndAcceptsAlreadyAbsent() async throws {
        for (scope, path) in [
            (GitHubRunnerScope.organization, "/orgs/org/actions/runners/12118"),
            (.repo, "/repos/owner/repo/actions/runners/12118")
        ] {
            for status in [204, 404, 403] {
                let network = PageNetwork { _, _ in
                    PageReply(data: Data(), error: status == 204 ? nil : TestError(), status: status)
                }
                let client = NetworkingGitHubClient(credentialsStore: Credentials(), networkingService: network)
                do {
                    try await client.deleteRunner(id: 12_118, with: GitHubAppAccessToken("test"), runnerScope: scope)
                    XCTAssertNotEqual(status, 403)
                } catch { XCTAssertEqual(status, 403) }
                XCTAssertEqual(network.requests.first?.httpMethod, "DELETE")
                XCTAssertEqual(network.requests.first?.url?.path, path)
                XCTAssertEqual(network.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            }
        }
    }

    private static func page(id: Int) -> Data {
        Data(
            "{\"total_count\":2,\"runners\":[{\"id\":\(id),\"name\":\"runner\",\"status\":\"online\",\"busy\":false}]}"
                .utf8
        )
    }
}

private struct TestError: Error {}
private struct PageReply {
    let data: Data
    var headers: [String: String] = [:]
    var error: Error?
    var status = 200
}
private final class PageNetwork: NetworkingService {
    private(set) var requests: [URLRequest] = []
    let responder: (URLRequest, Int) -> PageReply
    init(_ responder: @escaping (URLRequest, Int) -> PageReply) { self.responder = responder }
    func data(from request: URLRequest) async -> NetworkResponse<Data> {
        let reply = responder(request, requests.count)
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers
        )
        if let error = reply.error {
            return .failure(withError: error, httpURLResponse: response)
        }
        return .success(
            with: reply.data,
            httpURLResponse: HTTPURLResponse(
                url: request.url!,
                statusCode: reply.status,
                httpVersion: nil,
                headerFields: reply.headers
            )
        )
    }
    func load<T: Decodable>(_ valueType: T.Type, from request: URLRequest) async -> NetworkResponse<T> {
        await data(from: request).map { parameters in
            .success(
                with: try JSONDecoder().decode(valueType, from: parameters.value),
                httpURLResponse: parameters.httpURLResponse
            )
        }
    }
}
private final class Credentials: GitHubCredentialsStore {
    var organizationName: String? = "org"
    var repositoryName: String? = "repo"
    var ownerName: String? = "owner"
    var appId: String?
    var privateKey: Data?
    func setOrganizationName(_ organizationName: String?) { self.organizationName = organizationName }
    func setRepository(_ repositoryName: String?, withOwner ownerName: String?) {
        self.repositoryName = repositoryName; self.ownerName = ownerName
    }
    func setAppID(_ appID: String?) { self.appId = appID }
    func setPrivateKey(_ privateKeyData: Data?) { self.privateKey = privateKeyData }
}
