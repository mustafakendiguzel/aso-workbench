import Foundation
import ASOProviders
#if os(Windows)
import WinSDK
#endif

/// API keys in `credentials.json` in the data folder, in the same shape the macOS app writes, so on a Mac the
/// command line and the app share one file. Entries this type does not know (such as the app's website-session
/// cookies) are kept as they are.
///
/// The file is readable only by its owner: folder 0700 and file 0600 where POSIX permissions exist; on Windows the
/// contents are encrypted with DPAPI for the current user account. Written atomically so a crash never leaves half a
/// key. Keys never appear in output, logs or the data file.
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
    /// Marks a Windows file whose rest is a DPAPI blob. Files without it are plain JSON (other platforms, or written
    /// before encryption), read as they are and encrypted on the next write.
    static let protectedPrefix = Data("ASO-DPAPI-1\n".utf8)

    static func read(_ url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        #if os(Windows)
        if raw.starts(with: protectedPrefix) { return try DPAPI.unprotect(raw.dropFirst(protectedPrefix.count)) }
        #endif
        return raw
    }

    static func write(_ data: Data, to url: URL) throws {
        #if os(Windows)
        try (protectedPrefix + DPAPI.protect(data)).write(to: url, options: .atomic)
        #else
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }
}

#if os(Windows)
/// Windows Data Protection API: encryption bound to the current user's logon credentials, so the file is useless to
/// other accounts and on other computers.
enum DPAPI {
    static func protect(_ data: Data) throws -> Data {
        try transform(data, "encrypt the keys") { input, output in
            CryptProtectData(input, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), output)
        }
    }

    static func unprotect(_ data: Data) throws -> Data {
        try transform(data, "decrypt the keys (they were saved by another Windows account or computer; save them again)") { input, output in
            CryptUnprotectData(input, nil, nil, nil, nil, DWORD(CRYPTPROTECT_UI_FORBIDDEN), output)
        }
    }

    private static func transform(_ data: Data, _ action: String,
                                  _ call: (UnsafeMutablePointer<DATA_BLOB>, UnsafeMutablePointer<DATA_BLOB>) -> Bool) throws -> Data {
        var bytes = [UInt8](data)
        var output = DATA_BLOB()
        let succeeded = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            var input = DATA_BLOB(cbData: DWORD(buffer.count), pbData: buffer.baseAddress)
            return call(&input, &output)
        }
        guard succeeded, let result = output.pbData else {
            throw EngineError.database("Windows could not \(action) (error \(GetLastError())).")
        }
        defer { LocalFree(result) }
        return Data(bytes: result, count: Int(output.cbData))
    }
}
#endif
