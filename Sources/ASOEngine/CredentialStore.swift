import Foundation
import ASOProviders

/// API keys in `credentials.json` in the data folder, in the same shape the macOS app writes, so on a Mac the
/// command line and the app share one file. Entries this type does not know (such as the app's website-session
/// cookies) are kept as they are.
///
/// The file is readable only by its owner: folder 0700 and file 0600 where POSIX permissions exist, written
/// atomically so a crash never leaves half a key. Keys never appear in output, logs or the data file.
public struct CredentialStore: Sendable {
    public enum Service: String, CaseIterable, Sendable, Codable {
        case appleAds = "apple-ads"
        case appStoreConnect = "asc"
        case openRouter = "openrouter"
        case revenueCat = "revenuecat"

        public var title: String {
            switch self {
            case .appleAds: "Apple Ads"
            case .appStoreConnect: "App Store Connect"
            case .openRouter: "OpenRouter"
            case .revenueCat: "RevenueCat"
            }
        }
    }

    struct OpenRouterKey: Codable { var apiKey: String }
    struct RevenueCatKeys: Codable { var keys: [String] }

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("credentials.json")
    }

    public func appleAds() throws -> AppleAdsCredentials? { try load(.appleAds) }
    public func appStoreConnect() throws -> ASCCredentials? { try load(.appStoreConnect) }
    public func openRouterKey() throws -> String? { (try load(.openRouter) as OpenRouterKey?)?.apiKey }
    public func revenueCatKeys() throws -> [String] { (try load(.revenueCat) as RevenueCatKeys?)?.keys ?? [] }

    public func save(_ credentials: AppleAdsCredentials) throws { try save(credentials.sanitized, as: .appleAds) }
    public func save(_ credentials: ASCCredentials) throws { try save(credentials.sanitized, as: .appStoreConnect) }
    public func saveOpenRouterKey(_ key: String) throws { try save(OpenRouterKey(apiKey: key), as: .openRouter) }
    public func saveRevenueCatKeys(_ keys: [String]) throws { try save(RevenueCatKeys(keys: keys), as: .revenueCat) }

    /// Deletes one service's keys; false when there were none.
    @discardableResult
    public func remove(_ service: Service) throws -> Bool {
        var all = try readAll()
        guard all.removeValue(forKey: service.rawValue) != nil else { return false }
        try writeAll(all)
        return true
    }

    // MARK: File

    private func load<T: Decodable>(_ service: Service) throws -> T? {
        guard let raw = try readAll()[service.rawValue] else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: raw))
        } catch {
            throw EngineError.database("The stored \(service.title) keys cannot be read; save them again.")
        }
    }

    private func save<T: Encodable>(_ value: T, as service: Service) throws {
        var all = try readAll()
        all[service.rawValue] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        try writeAll(all)
    }

    private func readAll() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try CredentialFile.read(fileURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.database("\(fileURL.lastPathComponent) is not a valid key file.")
        }
        return json
    }

    private func writeAll(_ all: [String: Any]) throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try CredentialFile.write(JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]), to: fileURL)
    }
}

/// How the key file's bytes reach the disk. Owner-only permissions where POSIX permissions exist.
enum CredentialFile {
    static func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    static func write(_ data: Data, to url: URL) throws {
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        #endif
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}
