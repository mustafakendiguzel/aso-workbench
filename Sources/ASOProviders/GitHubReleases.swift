import Foundation
import ASOCore

/// One unauthenticated request to api.github.com for the latest release of the repository; nothing about the user or
/// their data is sent.
public struct GitHubReleases: Sendable {
    private let http = HTTPClient(serviceName: "GitHub releases", allowedHosts: ["api.github.com"])

    public init() {}

    /// The latest release, or nil when the repository has published none.
    public func latest(repository: String, currentVersion: String, platform: ReleaseCheck.Platform = .current) async throws -> ReleaseCheck.Release? {
        let request = HTTPClient.request(ReleaseCheck.latestReleaseURL(repository: repository),
                                         headers: ["Accept": "application/vnd.github+json", "User-Agent": "ASO-Workbench/\(currentVersion)"], timeout: 20)
        let response = try await http.send(request)
        if response.status == 404 { return nil }
        try http.check(response)
        return try ReleaseCheck.parse(response.data, repository: repository, platform: platform)
    }
}
