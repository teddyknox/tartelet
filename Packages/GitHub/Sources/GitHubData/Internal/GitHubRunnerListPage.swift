import Foundation

/// One page of `GET /orgs/{org}/actions/runners` or `GET /repos/{owner}/{repo}/actions/runners`.
struct GitHubRunnerListPage: Codable {
    struct Runner: Codable {
        let id: Int
        let name: String
        let status: String
        let busy: Bool
    }

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }

    let totalCount: Int
    let runners: [Runner]
}
