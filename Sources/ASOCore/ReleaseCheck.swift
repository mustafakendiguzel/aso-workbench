import Foundation

/// The latest GitHub release and whether it is newer than the running build: the release JSON read, the download for
/// this platform chosen, and only GitHub addresses ever handed to a browser.
public enum ReleaseCheck {
    public enum Platform: String, Sendable, Codable {
        case macOS, windows, linux

        public static var current: Platform {
            #if os(macOS)
            .macOS
            #elseif os(Windows)
            .windows
            #else
            .linux
            #endif
        }
    }

    public struct Release: Sendable, Codable, Equatable {
        public let version: String
        public let title: String
        /// The version's CHANGELOG section (the release script uses it as the notes).
        public let notes: String
        public let pageURL: String
        /// The package for this platform; absent when the release has none.
        public let downloadURL: String?
        public let publishedAt: Date?

        public init(version: String, title: String, notes: String, pageURL: String, downloadURL: String?, publishedAt: Date?) {
            self.version = version
            self.title = title
            self.notes = notes
            self.pageURL = pageURL
            self.downloadURL = downloadURL
            self.publishedAt = publishedAt
        }
    }

    /// The GitHub API address of a repository's latest release.
    public static func latestReleaseURL(repository: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// Reads `releases/latest`. Throws when the JSON is not a release with a version tag.
    public static func parse(_ data: Data, repository: String, platform: Platform = .current) throws -> Release {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = json["tag_name"] as? String,
              let version = SemanticVersion(tag) else {
            throw ASOError.decoding(service: "GitHub", detail: "Unexpected release format.")
        }
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (name: String, url: String)? in
            guard let name = asset["name"] as? String, let url = asset["browser_download_url"] as? String, isGitHub(url) else { return nil }
            return (name, url)
        }
        let page = (json["html_url"] as? String).flatMap { isGitHub($0) ? $0 : nil } ?? "https://github.com/\(repository)/releases"
        return Release(version: version.description, title: json["name"] as? String ?? tag, notes: json["body"] as? String ?? "", pageURL: page,
                       downloadURL: download(among: assets, for: platform),
                       publishedAt: (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// The package for the platform: the disk image (else the zip) on macOS; on Windows and Linux the window's package
    /// (`aso-workbench-windows-…`), else the command line's (`aso-windows-…`).
    public static func download(among assets: [(name: String, url: String)], for platform: Platform) -> String? {
        func first(_ match: (String) -> Bool) -> String? { assets.first { match($0.name.lowercased()) }?.url }
        switch platform {
        case .macOS:
            return first { $0.hasSuffix(".dmg") } ?? first { $0.hasSuffix(".zip") && !$0.contains("windows") && !$0.contains("linux") }
        case .windows:
            return first { $0.hasPrefix("aso-workbench-windows") && $0.hasSuffix(".zip") } ?? first { $0.contains("windows") && $0.hasSuffix(".zip") }
        case .linux:
            return first { $0.hasPrefix("aso-workbench-linux") && $0.hasSuffix(".tar.gz") } ?? first { $0.contains("linux") && $0.hasSuffix(".tar.gz") }
        }
    }

    /// Newer than the running version, and not the one the user chose to skip (a check they asked for shows it anyway).
    public static func shouldOffer(_ release: Release, current: String, skipped: String?, userInitiated: Bool) -> Bool {
        guard let latest = SemanticVersion(release.version), let running = SemanticVersion(current), latest > running else { return false }
        return userInitiated || release.version != skipped
    }

    /// Only https addresses on github.com or GitHub's download hosts are opened.
    public static func isGitHub(_ address: String) -> Bool {
        guard let url = URL(string: address), url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
    }
}
