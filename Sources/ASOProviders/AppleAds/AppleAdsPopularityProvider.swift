import Foundation
import ASOCore

/// Apple Ads Platform API v1 adapter.
///
/// Behaviour verified live on 2026-08-16:
///  * `sorting` must not be sent to the popularity insight (400 REQUEST_UNRECOGNIZED_PROPERTY).
///  * `genre` is a fixed upper-case set; values in filters are arrays.
///  * The last ~2 weeks are empty, so the default period is the last completed month.
///  * Keyword suggestions ignore the country filter; results are labelled cross-country.
///
/// The `searchTerm IN` filter is documented but rejected in
/// other community code; we probe it once and record the outcome in `capabilities`.
public actor AppleAdsPopularityProvider: PopularityProvider {
    public nonisolated let id: ProviderID = .appleAdsPopularity

    private let http = HTTPClient(serviceName: "Apple Ads", allowedHosts: ["api.ads.apple.com", "appleid.apple.com"])
    private var credentials: AppleAdsCredentials?
    private var token: (value: String, expiresAt: Date)?
    private var caps = ProviderCapabilities(maxPageSize: 200)

    public init(credentials: AppleAdsCredentials?) {
        self.credentials = credentials
    }

    public func update(credentials: AppleAdsCredentials?) {
        self.credentials = credentials
        token = nil
        caps = ProviderCapabilities(maxPageSize: 200)
    }

    public var isConfigured: Bool { credentials?.isComplete == true }

    public func capabilities() -> ProviderCapabilities { caps }

    // MARK: Auth

    private func accessToken() async throws -> String {
        guard let creds = credentials, creds.isComplete else { throw ASOError.notConfigured(service: "Apple Ads") }
        if let t = token, t.expiresAt > Date().addingTimeInterval(60) { return t.value }

        let signer = try ES256Signer(pem: creds.privateKeyPEM)
        let now = Int(Date().timeIntervalSince1970)
        let secret = try signer.sign(
            header: ["alg": "ES256", "kid": creds.keyID],
            payload: ["iss": creds.clientID, "sub": creds.clientID, "aud": "https://appleid.apple.com", "iat": now, "exp": now + 86_400])

        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "client_credentials"),
            .init(name: "client_id", value: creds.clientID),
            .init(name: "client_secret", value: secret),
            .init(name: "scope", value: "searchadsorg"),
        ]
        let body = Data((form.percentEncodedQuery ?? "").utf8)
        let request = HTTPClient.request(URL(string: "https://appleid.apple.com/auth/oauth2/token")!, method: "POST",
                                         headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
        let response = try await http.send(request)
        if response.status == 400, String(decoding: response.data, as: UTF8.self).contains("invalid_client") {
            throw ASOError.unauthorized(service: "Apple Ads")
        }
        try http.check(response)
        struct TokenBody: Decodable { let access_token: String; let expires_in: Int? }
        guard let parsed = try? JSONDecoder().decode(TokenBody.self, from: response.data) else {
            throw ASOError.decoding(service: "Apple Ads", detail: "Token response had no access_token.")
        }
        token = (parsed.access_token, Date().addingTimeInterval(TimeInterval(parsed.expires_in ?? 3600)))
        return parsed.access_token
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        let t = try await accessToken()
        guard let orgID = credentials?.orgID else { throw ASOError.notConfigured(service: "Apple Ads") }
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = HTTPClient.request(URL(string: "https://api.ads.apple.com/v1" + path)!, method: "POST", headers: [
            "Authorization": "Bearer \(t)",
            "X-Ap-Context": "orgId=\(orgID)",
            "Content-Type": "application/json",
        ], body: data, timeout: 60)
        let response = try await http.send(request)
        if response.status == 401 { token = nil }
        try http.check(response)
        return response.data
    }

    public func verify() async throws -> String {
        _ = try await accessToken()
        let data = try await post("/insights/apps/search-term-popularity/query", body: Self.popularityBody(country: "US", genre: .productivityUtilities, monthsBack: 1, terms: nil, pageSize: 1))
        let rows = try Self.parseRows(data)
        return rows.isEmpty ? "Token OK; no rows in the sample query (data is published with delay)." : "Token OK; sample query returned data."
    }

    // MARK: Popularity

    public func genreDataset(country: String, genre: AppleAdsGenre, monthsBack: Int) async throws -> [PopularityRecord] {
        var all: [PopularityRecord] = []
        var offset = 0
        let (start, end) = Self.lastFullMonth(monthsBack: monthsBack)
        while true {
            var body = Self.popularityBody(country: country, genre: genre, monthsBack: monthsBack, terms: nil, pageSize: caps.maxPageSize)
            body["pagination"] = ["offset": offset, "pageSize": caps.maxPageSize]
            let data = try await post("/insights/apps/search-term-popularity/query", body: body)
            let rows = try Self.parseRows(data)
            all += rows.map { Self.record($0, country: country, genre: genre, start: start, end: end) }
            if rows.count < caps.maxPageSize || all.count >= 2000 { break }
            offset += caps.maxPageSize
        }
        return all
    }

    /// Verified live on 2026-09-18: Apple accepts `searchTerm IN` resolved). Terms are sent in chunks of 50.
    public func popularity(terms: [String], country: String, genre: AppleAdsGenre, monthsBack: Int) async throws -> [PopularityRecord] {
        let (start, end) = Self.lastFullMonth(monthsBack: monthsBack)
        let cleanTerms = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !cleanTerms.isEmpty else { return [] }
        if caps.supportsTermFilter != false {
            var out: [PopularityRecord] = []
            do {
                for chunk in stride(from: 0, to: cleanTerms.count, by: 50).map({ Array(cleanTerms[$0..<min($0 + 50, cleanTerms.count)]) }) {
                    let body = Self.popularityBody(country: country, genre: genre, monthsBack: monthsBack, terms: chunk, pageSize: caps.maxPageSize)
                    let data = try await post("/insights/apps/search-term-popularity/query", body: body)
                    out += try Self.parseRows(data).map { Self.record($0, country: country, genre: genre, start: start, end: end) }
                }
                caps.supportsTermFilter = true
                caps.lastValidatedAt = Date()
                caps.lastError = nil
                return out
            } catch ASOError.http(_, let status, let message) where status == 400 {
                // Apple rejected the filter: remember it, fall back to the genre dataset.
                caps.supportsTermFilter = false
                caps.lastValidatedAt = Date()
                caps.lastError = "searchTerm filter rejected: \(message.prefix(160))"
            }
        }
        let wanted = Set(cleanTerms.map { $0.lowercased() })
        return try await genreDataset(country: country, genre: genre, monthsBack: monthsBack).filter { wanted.contains($0.searchTerm.lowercased()) }
    }

    /// Looks the terms up in every genre dataset (Apple has no genre for some App Store categories,
    /// e.g. Graphics & Design). Returns one record per term: the highest country-level score, with its genre.
    public func popularityAcrossGenres(terms: [String], country: String, monthsBack: Int, progress: (@Sendable (AppleAdsGenre) -> Void)? = nil) async throws -> [PopularityRecord] {
        var best: [String: PopularityRecord] = [:]
        for genre in AppleAdsGenre.allCases {
            progress?(genre)
            let rows = try await popularity(terms: terms, country: country, genre: genre, monthsBack: monthsBack)
            for r in rows {
                let key = r.searchTerm.lowercased()
                if let existing = best[key], (existing.popularity1to100 ?? -1) >= (r.popularity1to100 ?? -1) { continue }
                best[key] = r
            }
        }
        return Array(best.values)
    }

    public func keywordSuggestions(appID: Int, seeds: [String], country: String) async throws -> [KeywordSuggestion] {
        try await keywordSuggestions(appID: appID, seeds: seeds, country: country, pageSize: 100)
    }

    public func keywordSuggestions(appID: Int, seeds: [String], country: String, pageSize: Int) async throws -> [KeywordSuggestion] {
        var filters: [[String: Any]] = [
            ["field": "promotedObjectId", "operator": "EQUALS", "value": [String(appID)]],
            ["field": "promotedObjectType", "operator": "EQUALS", "value": ["APPSTORE_APP"]],
            ["field": "countriesOrRegions", "operator": "IN", "value": [country]],
        ]
        let cleanSeeds = seeds.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleanSeeds.isEmpty { filters.append(["field": "terms", "operator": "IN", "value": cleanSeeds]) }
        let data = try await post("/suggestions/keywords/query", body: ["filters": filters, "pagination": ["offset": 0, "pageSize": pageSize]])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["result"] as? [[String: Any]] else {
            throw ASOError.decoding(service: "Apple Ads", detail: "Suggestions response had no result array.")
        }
        let now = Date()
        return rows.enumerated().compactMap { index, row in
            guard let text = (row["text"] as? String) ?? (row["keyword"] as? String) else { return nil }
            let pop = (row["popularity"] as? Int) ?? (row["popularity"] as? Double).map(Int.init)
            return KeywordSuggestion(text: text, provider: .appleAdsSuggestions, origin: .officialObserved, popularity: pop, position: index + 1, fetchedAt: now)
        }
    }

    // MARK: Helpers

    public static func lastFullMonth(monthsBack: Int, now: Date = Date()) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let firstOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let start = cal.date(byAdding: .month, value: -max(1, monthsBack), to: firstOfThisMonth)!
        let end = cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .month, value: 1, to: start)!)!
        return (start, end)
    }

    static func popularityBody(country: String, genre: AppleAdsGenre, monthsBack: Int, terms: [String]?, pageSize: Int) -> [String: Any] {
        let (start, end) = lastFullMonth(monthsBack: monthsBack)
        var filters: [[String: Any]] = [
            ["field": "countryOrRegion", "operator": "EQUALS", "value": country.uppercased()],
            ["field": "genre", "operator": "EQUALS", "value": genre.rawValue],
        ]
        if let terms, !terms.isEmpty {
            filters.append(["field": "searchTerm", "operator": "IN", "value": terms])
        }
        return [
            "fields": ["rankInGenre", "searchPopularityInGenre", "searchPopularity1to100", "searchPopularity1to5"],
            "filters": filters,
            "timeRange": ["start": APIDay.string(from: start), "end": APIDay.string(from: end), "granularity": "MONTHLY"],
            "pagination": ["offset": 0, "pageSize": pageSize],
        ]
    }

    struct Row: Decodable {
        let searchTerm: String
        let rankInGenre: Int?
        let searchPopularityInGenre: Int?
        let searchPopularity1to100: Int?
        let searchPopularity1to5: Int?
    }

    static func parseRows(_ data: Data) throws -> [Row] {
        struct Envelope: Decodable { let result: Result?; struct Result: Decodable { let rows: [Row]? } }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).result?.rows ?? []
        } catch {
            throw ASOError.decoding(service: "Apple Ads", detail: String(describing: error))
        }
    }

    static func record(_ row: Row, country: String, genre: AppleAdsGenre, start: Date, end: Date) -> PopularityRecord {
        PopularityRecord(searchTerm: row.searchTerm, countryCode: country.uppercased(), genre: genre,
                         popularity1to100: row.searchPopularity1to100, popularity1to5: row.searchPopularity1to5,
                         popularityInGenre: row.searchPopularityInGenre, rankInGenre: row.rankInGenre,
                         periodStart: start, periodEnd: end, fetchedAt: Date())
    }
}
