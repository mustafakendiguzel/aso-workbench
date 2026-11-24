import Foundation
import ASOCore
import ASOProviders

/// GitHub releases behind a protocol, so the check is tested without the network.
public protocol ReleaseSource: Sendable {
    /// The latest release, or nil when none is published.
    func latest(repository: String, currentVersion: String, platform: ReleaseCheck.Platform) async throws -> ReleaseCheck.Release?
}

extension GitHubReleases: ReleaseSource {}

extension Engine {
    public struct UpdateCheck: Sendable, Codable, Equatable {
        public let current: String
        /// The latest published release; absent when there is none.
        public let latest: String?
        /// A newer release to offer.
        public let available: Bool
        /// Newer, but skipped by the user (automatic checks only).
        public let skipped: Bool
        public let release: ReleaseCheck.Release?

        public init(current: String, latest: String?, available: Bool, skipped: Bool, release: ReleaseCheck.Release?) {
            self.current = current
            self.latest = latest
            self.available = available
            self.skipped = skipped
            self.release = release
        }
    }

    /// Asks GitHub for the latest release. An automatic check leaves out the version the user skipped; one they asked for
    /// shows it anyway. Nothing about the user or their data is sent.
    public static func checkForUpdate(source: any ReleaseSource, repository: String = AppInfo.repository,
                                      current: String = EngineEnvironment.version, skipped: String? = nil, userInitiated: Bool = true,
                                      platform: ReleaseCheck.Platform = .current) async throws -> UpdateCheck {
        guard let release = try await source.latest(repository: repository, currentVersion: current, platform: platform) else {
            return UpdateCheck(current: current, latest: nil, available: false, skipped: false, release: nil)
        }
        let newer = ReleaseCheck.shouldOffer(release, current: current, skipped: nil, userInitiated: true)
        let offered = ReleaseCheck.shouldOffer(release, current: current, skipped: skipped.flatMap { $0.isEmpty ? nil : $0 }, userInitiated: userInitiated)
        return UpdateCheck(current: current, latest: release.version, available: offered, skipped: newer && !offered, release: newer ? release : nil)
    }
}
