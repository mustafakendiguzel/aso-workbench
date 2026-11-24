import Foundation
import ASOCore
import ASOProviders

/// What a service's stored keys look like, without the secrets: identifiers, the public-key fingerprint, counts.
public struct ConnectionStatus: Sendable, Codable, Equatable {
    public let service: String
    public let title: String
    public let configured: Bool
    /// Non-secret facts that help check the setup (e.g. the fingerprint to compare with the key uploaded to Apple).
    public let details: [String: String]
}

/// Saving, inspecting and testing the keys of each external service.
public enum Connections {
    public static func status(_ store: CredentialStore) throws -> [ConnectionStatus] {
        try CredentialStore.Service.allCases.map { service in
            var details: [String: String] = [:]
            switch service {
            case .appleAds:
                if let c = try store.appleAds() {
                    details = ["clientID": c.clientID, "keyID": c.keyID, "orgID": c.orgID, "keyFingerprint": fingerprint(c.privateKeyPEM)]
                }
            case .appStoreConnect:
                if let c = try store.appStoreConnect() {
                    details = ["keyID": c.keyID, "issuerID": c.issuerID, "keyFingerprint": fingerprint(c.privateKeyPEM)]
                }
            case .openRouter:
                if try store.openRouterKey() != nil { details = ["key": "stored"] }
            case .revenueCat:
                let keys = try store.revenueCatKeys()
                if !keys.isEmpty { details = ["keys": String(keys.count)] }
            }
            return ConnectionStatus(service: service.rawValue, title: service.title, configured: !details.isEmpty, details: details)
        }
    }

    /// Validates and stores Apple Ads keys: every identifier present and the private key a P-256 PEM key.
    public static func saveAppleAds(clientID: String, keyID: String, orgID: String, privateKeyPEM: String, in store: CredentialStore) throws {
        let credentials = AppleAdsCredentials(clientID: clientID, keyID: keyID, orgID: orgID, privateKeyPEM: privateKeyPEM).sanitized
        guard credentials.isComplete else { throw EngineError.invalidArgument("Apple Ads needs a client ID, key ID, org ID and the private key.") }
        _ = try ES256Signer(pem: credentials.privateKeyPEM)
        try store.save(credentials)
    }

    /// Validates and stores App Store Connect keys. The key ID may be read from Apple's file name, AuthKey_<KEYID>.p8.
    public static func saveAppStoreConnect(keyID: String?, issuerID: String, privateKeyPEM: String, keyFileName: String?,
                                           in store: CredentialStore) throws {
        let id = keyID?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? keyFileName.flatMap(keyID(fromFileName:))
        guard let id else { throw EngineError.invalidArgument("App Store Connect needs the key ID (or the AuthKey_<KEYID>.p8 file name).") }
        let credentials = ASCCredentials(keyID: id, issuerID: issuerID, privateKeyPEM: privateKeyPEM).sanitized
        guard credentials.isComplete else { throw EngineError.invalidArgument("App Store Connect needs a key ID, issuer ID and the .p8 key.") }
        _ = try ES256Signer(pem: credentials.privateKeyPEM)
        try store.save(credentials)
    }

    public static func saveOpenRouterKey(_ key: String, in store: CredentialStore) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw EngineError.invalidArgument("The OpenRouter key is empty or contains spaces.") }
        try store.saveOpenRouterKey(key)
    }

    /// One key per line or comma; blanks and repeats are dropped.
    public static func saveRevenueCatKeys(_ text: String, in store: CredentialStore) throws -> Int {
        var seen = Set<String>()
        let keys = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !keys.isEmpty else { throw EngineError.invalidArgument("No RevenueCat key given.") }
        try store.saveRevenueCatKeys(keys)
        return keys.count
    }

    /// One cheap authenticated call against the service; returns what it answered.
    public static func verify(_ service: CredentialStore.Service, store: CredentialStore) async throws -> String {
        switch service {
        case .appleAds:
            guard let c = try store.appleAds() else { throw ASOError.notConfigured(service: service.title) }
            return try await AppleAdsPopularityProvider(credentials: c).verify()
        case .appStoreConnect:
            guard let c = try store.appStoreConnect() else { throw ASOError.notConfigured(service: service.title) }
            return try await ASCMetadataProvider(credentials: c).verify()
        case .openRouter:
            guard let key = try store.openRouterKey() else { throw ASOError.notConfigured(service: service.title) }
            return try await JevClient(apiKey: key).verify()
        case .revenueCat:
            let keys = try store.revenueCatKeys()
            guard !keys.isEmpty else { throw ASOError.notConfigured(service: service.title) }
            var names: [String] = []
            for key in keys { names += try await RevenueCatProvider().projects(key: key).map(\.name) }
            return names.isEmpty ? "The keys work; they see no projects." : "\(names.count) project(s): \(names.joined(separator: ", "))."
        }
    }

    /// "AuthKey_2X9R4HXF34.p8" → "2X9R4HXF34", the way App Store Connect names downloaded keys.
    static func keyID(fromFileName name: String) -> String? {
        let base = (name as NSString).lastPathComponent
        guard base.hasPrefix("AuthKey_"), base.hasSuffix(".p8") else { return nil }
        let id = String(base.dropFirst("AuthKey_".count).dropLast(".p8".count))
        return id.isEmpty ? nil : id
    }

    private static func fingerprint(_ pem: String) -> String {
        (try? ES256Signer(pem: pem).publicKeyFingerprint) ?? "unreadable key"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
