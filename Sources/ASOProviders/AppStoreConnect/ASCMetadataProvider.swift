import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import ASOCore

/// App Store Connect API v1 metadata adapter.
///
/// Write safety rules:
///  * Only GET requests are retried; a PATCH whose outcome is unknown is followed by a re-read, never a blind retry.
///  * The editable `appInfo` is chosen by state, not by `limit=1` (a live app has two).
///  * Every apply re-reads the locale afterwards and returns what Apple actually holds.
public actor ASCMetadataProvider: MetadataProvider {
    public nonisolated let id: ProviderID = .appStoreConnect

    private let http = HTTPClient(serviceName: "App Store Connect", allowedHosts: ["api.appstoreconnect.apple.com"])
    private var credentials: ASCCredentials?
    private var cachedToken: (value: String, expiresAt: Date)?

    public init(credentials: ASCCredentials?) {
        self.credentials = credentials
    }

    public func update(credentials: ASCCredentials?) {
        self.credentials = credentials
        cachedToken = nil
    }

    public var isConfigured: Bool { credentials?.isComplete == true }

    // MARK: Auth

    private func bearer() throws -> String {
        guard let creds = credentials, creds.isComplete else { throw ASOError.notConfigured(service: "App Store Connect") }
        if let t = cachedToken, t.expiresAt > Date().addingTimeInterval(30) { return t.value }
        let signer = try ES256Signer(pem: creds.privateKeyPEM)
        let now = Int(Date().timeIntervalSince1970)
        let jwt = try signer.sign(header: ["alg": "ES256", "kid": creds.keyID, "typ": "JWT"],
                                  payload: ["iss": creds.issuerID, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"])
        cachedToken = (jwt, Date().addingTimeInterval(900))
        return jwt
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let url = URL(string: "https://api.appstoreconnect.apple.com" + path)!
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let request = HTTPClient.request(url, method: method, headers: [
            "Authorization": "Bearer \(try bearer())",
            "Content-Type": "application/json",
        ], body: data)
        var response = try await http.send(request)
        // Single retry for idempotent reads on transient server errors.
        if method == "GET", (500...599).contains(response.status) {
            try? await Task.sleep(for: .seconds(1.5))
            response = try await http.send(request)
        }
        if response.status == 409 {
            let msg = Self.errorMessage(response.data)
            throw ASOError.conflict("App Store Connect rejected the change (409): \(msg)")
        }
        try http.check(response)
        if response.data.isEmpty { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ASOError.decoding(service: "App Store Connect", detail: "Expected a JSON object.")
        }
        return json
    }

    static func errorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]], let first = errors.first else {
            return String(decoding: data.prefix(300), as: UTF8.self)
        }
        let code = first["code"] as? String ?? ""
        let detail = first["detail"] as? String ?? first["title"] as? String ?? ""
        return "\(code) \(detail)".trimmingCharacters(in: .whitespaces)
    }

    // MARK: Reads

    public func verify() async throws -> String {
        let json = try await call("GET", "/v1/apps?limit=5")
        let apps = (json["data"] as? [[String: Any]]) ?? []
        let names = apps.compactMap { ($0["attributes"] as? [String: Any])?["name"] as? String }
        return apps.isEmpty ? "Connected, but no apps are visible to this key." : "Connected. Apps: \(names.joined(separator: ", "))"
    }

    public func resolveAppID(bundleID: String) async throws -> String {
        let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
        let json = try await call("GET", "/v1/apps?filter[bundleId]=\(encoded)")
        guard let first = (json["data"] as? [[String: Any]])?.first, let id = first["id"] as? String else {
            throw ASOError.invalidInput("No App Store Connect app found for bundle id \(bundleID) with this key.")
        }
        return id
    }

    struct Resource {
        let id: String
        let attributes: [String: Any]
        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? String else { return nil }
            self.id = id
            self.attributes = raw["attributes"] as? [String: Any] ?? [:]
        }
    }

    private func list(_ path: String) async throws -> [Resource] {
        ((try await call("GET", path))["data"] as? [[String: Any]] ?? []).compactMap(Resource.init)
    }

    private static let editableVersionStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY",
    ]
    private static let frozenInfoStates: Set<String> = ["READY_FOR_SALE", "REPLACED_WITH_NEW_INFO", "READY_FOR_DISTRIBUTION"]

    private func editableVersion(ascAppID: String) async throws -> Resource? {
        let versions = try await list("/v1/apps/\(ascAppID)/appStoreVersions?filter[platform]=IOS&limit=10")
        return versions.first { Self.editableVersionStates.contains(($0.attributes["appStoreState"] as? String) ?? ($0.attributes["appVersionState"] as? String) ?? "") }
            ?? versions.first
    }

    /// The privacy policy URL Apple holds (first locale that has one), so the legal footer needs no manual entry.
    public func privacyPolicyURL(ascAppID: String) async throws -> String? {
        guard let info = try await editableAppInfo(ascAppID: ascAppID) else { return nil }
        let locs = try await list("/v1/appInfos/\(info.id)/appInfoLocalizations?limit=200")
        let preferred = locs.first { ($0.attributes["locale"] as? String) == "en-US" } ?? locs.first { !(($0.attributes["privacyPolicyUrl"] as? String) ?? "").isEmpty }
        return (preferred?.attributes["privacyPolicyUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    public struct VersionInfo: Sendable, Hashable { public let id: String; public let versionString: String; public let state: String; public let isEditable: Bool }

    /// Every iOS version Apple lists for the app (newest first), with whether its metadata can still be edited.
    public func versions(ascAppID: String) async throws -> [VersionInfo] {
        try await list("/v1/apps/\(ascAppID)/appStoreVersions?filter[platform]=IOS&limit=10").map { r in
            let state = (r.attributes["appStoreState"] as? String) ?? (r.attributes["appVersionState"] as? String) ?? ""
            return VersionInfo(id: r.id, versionString: r.attributes["versionString"] as? String ?? "?", state: state, isEditable: Self.editableVersionStates.contains(state))
        }
    }

    /// Creates a new iOS version record in "Prepare for Submission" (the build is uploaded separately, e.g. from Xcode).
    public func createVersion(ascAppID: String, versionString: String) async throws -> VersionInfo {
        let json = try await call("POST", "/v1/appStoreVersions", body: ["data": [
            "type": "appStoreVersions", "attributes": ["platform": "IOS", "versionString": versionString],
            "relationships": ["app": ["data": ["type": "apps", "id": ascAppID]]],
        ]])
        guard let r = (json["data"] as? [String: Any]).flatMap(Resource.init) else { throw ASOError.decoding(service: "App Store Connect", detail: "No version in response.") }
        return VersionInfo(id: r.id, versionString: r.attributes["versionString"] as? String ?? versionString, state: r.attributes["appStoreState"] as? String ?? "PREPARE_FOR_SUBMISSION", isEditable: true)
    }

    /// Makes sure the locale exists on the editable version (release-note fields) and on the app info (name/subtitle),
    /// creating what is missing, and returns the locale's snapshot afterwards.
    public func ensureLocalizations(ascAppID: String, locale: AppLocale, name: String) async throws -> MetadataSnapshot {
        guard let version = try await editableVersion(ascAppID: ascAppID),
              Self.editableVersionStates.contains((version.attributes["appStoreState"] as? String) ?? (version.attributes["appVersionState"] as? String) ?? "") else {
            throw ASOError.unsupported("No editable version: the live version cannot take new metadata. Create a new version first (Apply sheet → New version).")
        }
        let existing = try await snapshots(ascAppID: ascAppID)
        var snap = existing.first { $0.locale == locale }
        if snap?.versionLocalizationID == nil {
            _ = try await call("POST", "/v1/appStoreVersionLocalizations", body: ["data": [
                "type": "appStoreVersionLocalizations", "attributes": ["locale": locale.rawValue],
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": version.id]]],
            ]])
        }
        if snap?.appInfoLocalizationID == nil, let info = try await editableAppInfo(ascAppID: ascAppID) {
            let safeName = name.isEmpty ? (existing.first?.fields.name ?? "App") : name
            _ = try await call("POST", "/v1/appInfoLocalizations", body: ["data": [
                "type": "appInfoLocalizations", "attributes": ["locale": locale.rawValue, "name": String(safeName.prefix(30))],
                "relationships": ["appInfo": ["data": ["type": "appInfos", "id": info.id]]],
            ]])
        }
        snap = try await snapshots(ascAppID: ascAppID).first { $0.locale == locale }
        guard let snap else { throw ASOError.conflict("Locale \(locale.rawValue) was created but is not visible on re-read.") }
        return snap
    }

    // MARK: Screenshots

    public struct ScreenshotCopyReport: Sendable { public var sets = 0; public var copied = 0; public var skipped = 0; public var errors: [String] = [] }

    private let assets = HTTPClient(serviceName: "App Store assets", allowedHosts: [], allowedHostSuffixes: [".mzstatic.com", ".apple.com"])

    /// Copies every screenshot set of one version localization to another (download the rendered original, upload it
    /// again: Apple has no copy call). Existing sets on the target are left alone.
    public func copyScreenshots(fromLocalization source: String, toLocalization target: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> ScreenshotCopyReport {
        var report = ScreenshotCopyReport()
        let sourceSets = try await list("/v1/appStoreVersionLocalizations/\(source)/appScreenshotSets?limit=50")
        let targetSets = try await list("/v1/appStoreVersionLocalizations/\(target)/appScreenshotSets?limit=50")
        for set in sourceSets {
            guard let type = set.attributes["screenshotDisplayType"] as? String else { continue }
            let shots = try await list("/v1/appScreenshotSets/\(set.id)/appScreenshots?limit=50")
            guard !shots.isEmpty else { continue }
            if let existing = targetSets.first(where: { ($0.attributes["screenshotDisplayType"] as? String) == type }) {
                let already = try await list("/v1/appScreenshotSets/\(existing.id)/appScreenshots?limit=50")
                if !already.isEmpty { report.skipped += shots.count; continue }
            }
            report.sets += 1
            let targetSetID: String
            if let existing = targetSets.first(where: { ($0.attributes["screenshotDisplayType"] as? String) == type }) { targetSetID = existing.id } else {
                let created = try await call("POST", "/v1/appScreenshotSets", body: ["data": [
                    "type": "appScreenshotSets", "attributes": ["screenshotDisplayType": type],
                    "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": target]]],
                ]])
                guard let id = (created["data"] as? [String: Any])?["id"] as? String else { throw ASOError.decoding(service: "App Store Connect", detail: "No screenshot set id.") }
                targetSetID = id
            }
            for (i, shot) in shots.enumerated() {
                progress?("\(type) \(i + 1)/\(shots.count)")
                do {
                    guard let asset = shot.attributes["imageAsset"] as? [String: Any], let template = asset["templateUrl"] as? String,
                          let w = asset["width"] as? Int, let h = asset["height"] as? Int else { report.errors.append("\(type) #\(i + 1): not yet processed by Apple"); continue }
                    let urlString = template.replacingOccurrences(of: "{w}", with: String(w)).replacingOccurrences(of: "{h}", with: String(h)).replacingOccurrences(of: "{f}", with: "png")
                    guard let url = URL(string: urlString) else { continue }
                    let image = try await assets.send(HTTPClient.request(url))
                    try assets.check(image)
                    let fileName = (shot.attributes["fileName"] as? String).map { $0.hasSuffix(".png") ? $0 : $0 + ".png" } ?? "screenshot-\(i + 1).png"
                    try await upload(imageData: image.data, fileName: fileName, toSet: targetSetID)
                    report.copied += 1
                } catch {
                    report.errors.append("\(type) #\(i + 1): \(error.localizedDescription)")
                }
            }
        }
        return report
    }

    private func upload(imageData: Data, fileName: String, toSet setID: String) async throws {
        let reserved = try await call("POST", "/v1/appScreenshots", body: ["data": [
            "type": "appScreenshots", "attributes": ["fileName": fileName, "fileSize": imageData.count],
            "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": setID]]],
        ]])
        guard let data = reserved["data"] as? [String: Any], let id = data["id"] as? String,
              let ops = (data["attributes"] as? [String: Any])?["uploadOperations"] as? [[String: Any]] else {
            throw ASOError.decoding(service: "App Store Connect", detail: "No upload operations for \(fileName).")
        }
        for op in ops {
            guard let urlString = op["url"] as? String, let url = URL(string: urlString), let length = op["length"] as? Int, let offset = op["offset"] as? Int else { continue }
            var headers: [String: String] = [:]
            for h in op["requestHeaders"] as? [[String: Any]] ?? [] { if let n = h["name"] as? String, let v = h["value"] as? String { headers[n] = v } }
            let chunk = imageData.subdata(in: offset..<min(imageData.count, offset + length))
            let response = try await assets.send(HTTPClient.request(url, method: (op["method"] as? String) ?? "PUT", headers: headers, body: chunk, timeout: 120))
            try assets.check(response)
        }
        _ = try await call("PATCH", "/v1/appScreenshots/\(id)", body: ["data": [
            "type": "appScreenshots", "id": id, "attributes": ["uploaded": true, "sourceFileChecksum": ASCMetadataProvider.md5Hex(imageData)],
        ]])
    }

    nonisolated static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func editableAppInfo(ascAppID: String) async throws -> Resource? {
        let infos = try await list("/v1/apps/\(ascAppID)/appInfos?limit=10")
        return infos.first { !Self.frozenInfoStates.contains(($0.attributes["appStoreState"] as? String) ?? ($0.attributes["state"] as? String) ?? "") } ?? infos.first
    }

    public func snapshots(ascAppID: String) async throws -> [MetadataSnapshot] {
        let version = try await editableVersion(ascAppID: ascAppID)
        let info = try await editableAppInfo(ascAppID: ascAppID)
        var versionLocs: [Resource] = []
        if let version { versionLocs = try await list("/v1/appStoreVersions/\(version.id)/appStoreVersionLocalizations?limit=200") }
        var infoLocs: [Resource] = []
        if let info { infoLocs = try await list("/v1/appInfos/\(info.id)/appInfoLocalizations?limit=200") }
        return Self.merge(versionLocs: versionLocs, infoLocs: infoLocs, version: version)
    }

    static func merge(versionLocs: [Resource], infoLocs: [Resource], version: Resource?) -> [MetadataSnapshot] {
        var byLocale: [String: (v: Resource?, i: Resource?)] = [:]
        for v in versionLocs { if let l = v.attributes["locale"] as? String { byLocale[l, default: (nil, nil)].v = v } }
        for i in infoLocs { if let l = i.attributes["locale"] as? String { byLocale[l, default: (nil, nil)].i = i } }
        let now = Date()
        return byLocale.compactMap { localeRaw, pair in
            guard let locale = AppLocale.parse(localeRaw) else { return nil }
            let fields = MetadataFields(
                name: pair.i?.attributes["name"] as? String ?? "",
                subtitle: pair.i?.attributes["subtitle"] as? String ?? "",
                keywords: pair.v?.attributes["keywords"] as? String ?? "",
                promotionalText: pair.v?.attributes["promotionalText"] as? String ?? "",
                description: pair.v?.attributes["description"] as? String ?? "",
                whatsNew: pair.v?.attributes["whatsNew"] as? String ?? "")
            return MetadataSnapshot(locale: locale, fields: fields, appInfoLocalizationID: pair.i?.id, versionLocalizationID: pair.v?.id,
                                    versionString: version?.attributes["versionString"] as? String,
                                    versionState: (version?.attributes["appStoreState"] as? String) ?? (version?.attributes["appVersionState"] as? String),
                                    fetchedAt: now)
        }.sorted { $0.locale.rawValue < $1.locale.rawValue }
    }

    // MARK: Writes

    public func apply(ascAppID: String, snapshot: MetadataSnapshot, changes: [MetadataField: String]) async throws -> MetadataSnapshot {
        guard !changes.isEmpty else { return snapshot }

        let versionAttrs = changes.filter { $0.key.resource == .appStoreVersionLocalization }
        let infoAttrs = changes.filter { $0.key.resource == .appInfoLocalization }

        if !versionAttrs.isEmpty {
            guard let id = snapshot.versionLocalizationID else {
                throw ASOError.unsupported("Locale \(snapshot.locale.rawValue) has no version localization yet. Create it in App Store Connect first; this version does not create localizations.")
            }
            let attrs = Dictionary(uniqueKeysWithValues: versionAttrs.map { ($0.key.rawValue, $0.value) })
            _ = try await call("PATCH", "/v1/appStoreVersionLocalizations/\(id)",
                               body: ["data": ["type": "appStoreVersionLocalizations", "id": id, "attributes": attrs]])
        }
        if !infoAttrs.isEmpty {
            guard let id = snapshot.appInfoLocalizationID else {
                throw ASOError.unsupported("Locale \(snapshot.locale.rawValue) has no app info localization yet. Create it in App Store Connect first.")
            }
            let attrs = Dictionary(uniqueKeysWithValues: infoAttrs.map { ($0.key.rawValue, $0.value) })
            _ = try await call("PATCH", "/v1/appInfoLocalizations/\(id)",
                               body: ["data": ["type": "appInfoLocalizations", "id": id, "attributes": attrs]])
        }

        // Re-read what Apple holds now; that is the truth, not our request body.
        let fresh = try await snapshots(ascAppID: ascAppID)
        guard let updated = fresh.first(where: { $0.locale == snapshot.locale }) else {
            throw ASOError.conflict("Applied, but locale \(snapshot.locale.rawValue) was not found on re-read.")
        }
        return updated
    }
}
