import Foundation
import AppKit
import ASOCore
import ASOProviders

/// Tells people when a newer release is on GitHub. One unauthenticated request to api.github.com for the latest release
/// of `AppInfo.repository`; nothing about the user or their data is sent. The download itself happens in the browser.
@Observable
final class UpdateChecker {
    struct Release: Sendable, Equatable {
        let version: String
        let title: String
        let notes: String
        let pageURL: URL
        let downloadURL: URL?
        let publishedAt: Date?
    }

    enum Result: Equatable { case upToDate(String), available(Release), failed(String) }

    private(set) var available: Release?
    private(set) var lastResult: Result?
    private(set) var isChecking = false
    private let releases = GitHubReleases()
    private let defaults = UserDefaults.standard

    var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "updates.automatic") }
    }
    var lastChecked: Date? { defaults.object(forKey: "updates.lastChecked") as? Date }
    var skippedVersion: String? {
        get { defaults.string(forKey: "updates.skipped") }
        set { defaults.set(newValue, forKey: "updates.skipped") }
    }

    init() {
        automatic = defaults.object(forKey: "updates.automatic") as? Bool ?? true
    }

    /// At most once a day, and only when automatic checks are on.
    func checkIfDue() async {
        guard automatic else { return }
        if let last = lastChecked, Date.now.timeIntervalSince(last) < 20 * 3600 { return }
        await check(userInitiated: false)
    }

    @discardableResult
    func check(userInitiated: Bool) async -> Result {
        guard !isChecking else { return lastResult ?? .failed("Already checking") }
        isChecking = true
        defer { isChecking = false }
        let result: Result
        do {
            // No release published yet counts as up to date.
            if let latest = try await releases.latest(repository: AppInfo.repository, currentVersion: AppInfo.version, platform: .macOS),
               ReleaseCheck.shouldOffer(latest, current: AppInfo.version, skipped: nil, userInitiated: true) {
                result = .available(Release(version: latest.version, title: latest.title, notes: latest.notes,
                                            pageURL: URL(string: latest.pageURL) ?? AppInfo.repositoryURL.appendingPathComponent("releases"),
                                            downloadURL: latest.downloadURL.flatMap(URL.init(string:)), publishedAt: latest.publishedAt))
            } else {
                result = .upToDate(AppInfo.version)
            }
            defaults.set(Date.now, forKey: "updates.lastChecked")
        } catch {
            result = .failed(error.localizedDescription)
        }
        lastResult = result
        if case .available(let r) = result, userInitiated || r.version != skippedVersion { available = r } else if case .upToDate = result { available = nil }
        AppLog.write("[updates] \(result)")
        return result
    }

    func skip(_ release: Release) {
        skippedVersion = release.version
        available = nil
    }

    /// Opens GitHub in the browser; only github.com URLs are ever opened.
    func open(_ url: URL) {
        guard ReleaseCheck.isGitHub(url.absoluteString) else { return }
        NSWorkspace.shared.open(url)
    }
}
