import Foundation
import ASOCore

/// Apple Ads Campaign Management API (v5): the advertiser's own campaigns and keyword reports, spend, taps, installs,
/// conversion and bid recommendations per keyword and storefront. Same OAuth client as the Platform API.
public actor AppleAdsCampaignProvider {
    public struct Campaign: Sendable, Identifiable, Hashable {
        public let id: Int
        public let name: String
        public let status: String
        public let adamID: Int?
        public let countries: [String]

        public init(id: Int, name: String, status: String, adamID: Int?, countries: [String]) {
            self.id = id
            self.name = name
            self.status = status
            self.adamID = adamID
            self.countries = countries
        }
    }

    /// One keyword × storefront row of a keyword report (a date range summed up).
    public struct KeywordStat: Sendable, Hashable, Identifiable {
        public var id: String { "\(campaignID)|\(keywordID)|\(country)" }
        public let campaignID: Int
        public let adGroupName: String
        public let keywordID: Int
        public let keyword: String
        public let matchType: String
        public let status: String
        public let country: String
        public let bid: Double?
        public let currency: String
        public let impressions: Int
        public let taps: Int
        public let installs: Int
        public let spend: Double
        public let ttr: Double?
        public let conversionRate: Double?
        public let avgCPT: Double?
        public let avgCPI: Double?
        public let bidMin: Double?
        public let bidMax: Double?

        public init(campaignID: Int, adGroupName: String, keywordID: Int, keyword: String, matchType: String, status: String, country: String,
                    bid: Double?, currency: String, impressions: Int, taps: Int, installs: Int, spend: Double, ttr: Double?,
                    conversionRate: Double?, avgCPT: Double?, avgCPI: Double?, bidMin: Double?, bidMax: Double?) {
            self.campaignID = campaignID
            self.adGroupName = adGroupName
            self.keywordID = keywordID
            self.keyword = keyword
            self.matchType = matchType
            self.status = status
            self.country = country
            self.bid = bid
            self.currency = currency
            self.impressions = impressions
            self.taps = taps
            self.installs = installs
            self.spend = spend
            self.ttr = ttr
            self.conversionRate = conversionRate
            self.avgCPT = avgCPT
            self.avgCPI = avgCPI
            self.bidMin = bidMin
            self.bidMax = bidMax
        }
    }

    private let http = HTTPClient(serviceName: "Apple Ads campaigns", allowedHosts: ["appleid.apple.com", "api.searchads.apple.com"])
    private var credentials: AppleAdsCredentials?
    private var token: (value: String, expiresAt: Date)?

    public init(credentials: AppleAdsCredentials?) { self.credentials = credentials?.sanitized }
    public func update(credentials: AppleAdsCredentials?) { self.credentials = credentials?.sanitized; token = nil }
    public var isConfigured: Bool { credentials?.isComplete == true }

    private func accessToken() async throws -> String {
        guard let creds = credentials, creds.isComplete else { throw ASOError.notConfigured(service: "Apple Ads") }
        if let t = token, t.expiresAt > Date().addingTimeInterval(60) { return t.value }
        let signer = try ES256Signer(pem: creds.privateKeyPEM)
        let now = Int(Date().timeIntervalSince1970)
        let secret = try signer.sign(header: ["alg": "ES256", "kid": creds.keyID],
                                     payload: ["iss": creds.clientID, "sub": creds.clientID, "aud": "https://appleid.apple.com", "iat": now, "exp": now + 86_400])
        var form = URLComponents()
        form.queryItems = [.init(name: "grant_type", value: "client_credentials"), .init(name: "client_id", value: creds.clientID),
                           .init(name: "client_secret", value: secret), .init(name: "scope", value: "searchadsorg")]
        let request = HTTPClient.request(URL(string: "https://appleid.apple.com/auth/oauth2/token")!, method: "POST",
                                         headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data((form.percentEncodedQuery ?? "").utf8))
        let response = try await http.send(request)
        if response.status == 400, String(decoding: response.data, as: UTF8.self).contains("invalid_client") { throw ASOError.unauthorized(service: "Apple Ads") }
        try http.check(response)
        struct TokenBody: Decodable { let access_token: String; let expires_in: Int? }
        guard let parsed = try? JSONDecoder().decode(TokenBody.self, from: response.data) else { throw ASOError.decoding(service: "Apple Ads", detail: "Token response had no access_token.") }
        token = (parsed.access_token, Date().addingTimeInterval(TimeInterval(parsed.expires_in ?? 3600)))
        return parsed.access_token
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        let t = try await accessToken()
        guard let orgID = credentials?.orgID else { throw ASOError.notConfigured(service: "Apple Ads") }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let request = HTTPClient.request(URL(string: "https://api.searchads.apple.com/api/v5" + path)!, method: method, headers: [
            "Authorization": "Bearer \(t)", "X-AP-Context": "orgId=\(orgID)", "Content-Type": "application/json",
        ], body: data, timeout: 60)
        let response = try await http.send(request)
        if response.status == 401 { token = nil }
        try http.check(response)
        return response.data
    }

    public func campaigns() async throws -> [Campaign] {
        let data = try await send("GET", "/campaigns?limit=200")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? Int else { return nil }
            return Campaign(id: id, name: r["name"] as? String ?? "", status: r["status"] as? String ?? "", adamID: r["adamId"] as? Int,
                            countries: r["countriesOrRegions"] as? [String] ?? [])
        }
    }

    /// Keyword report for one campaign, grouped by storefront, summed over [start, end].
    public func keywordReport(campaignID: Int, start: Date, end: Date) async throws -> [KeywordStat] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        let body: [String: Any] = [
            "startTime": f.string(from: start), "endTime": f.string(from: end), "timeZone": "UTC",
            "groupBy": ["countryOrRegion"],
            "selector": ["orderBy": [["field": "localSpend", "sortOrder": "DESCENDING"]], "pagination": ["offset": 0, "limit": 1000]],
            "returnRowTotals": true, "returnGrandTotals": false, "returnRecordsWithNoMetrics": true,
        ]
        let data = try await send("POST", "/reports/campaigns/\(campaignID)/keywords", body: body)
        return Self.parseKeywordReport(data, campaignID: campaignID)
    }

    public static func parseKeywordReport(_ data: Data, campaignID: Int) -> [KeywordStat] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = ((json["data"] as? [String: Any])?["reportingDataResponse"] as? [String: Any]),
              let rows = report["row"] as? [[String: Any]] else { return [] }
        func money(_ v: Any?) -> Double? { ((v as? [String: Any])?["amount"] as? String).flatMap(Double.init) ?? (v as? Double) }
        func int(_ d: [String: Any], _ keys: [String]) -> Int { for k in keys { if let v = d[k] as? Int { return v }; if let v = d[k] as? Double { return Int(v) } }; return 0 }
        func dbl(_ d: [String: Any], _ keys: [String]) -> Double? { for k in keys { if let v = d[k] as? Double { return v }; if let v = d[k] as? Int { return Double(v) } }; return nil }
        return rows.compactMap { r in
            guard let meta = r["metadata"] as? [String: Any], let total = r["total"] as? [String: Any] else { return nil }
            let insights = (r["insights"] as? [String: Any])?["bidRecommendation"] as? [String: Any]
            let bid = meta["bidAmount"] as? [String: Any]
            return KeywordStat(campaignID: campaignID, adGroupName: meta["adGroupName"] as? String ?? "", keywordID: meta["keywordId"] as? Int ?? 0,
                               keyword: meta["keyword"] as? String ?? "", matchType: meta["matchType"] as? String ?? "", status: meta["keywordStatus"] as? String ?? "",
                               country: meta["countryOrRegion"] as? String ?? "", bid: money(bid), currency: bid?["currency"] as? String ?? "",
                               impressions: int(total, ["impressions"]), taps: int(total, ["taps"]),
                               installs: int(total, ["totalInstalls", "installs", "tapInstalls"]),
                               spend: money(total["localSpend"]) ?? 0, ttr: dbl(total, ["ttr"]),
                               conversionRate: dbl(total, ["tapInstallRate", "conversionRate"]),
                               avgCPT: money(total["avgCPT"]), avgCPI: money(total["totalAvgCPI"]) ?? money(total["avgCPA"]) ?? money(total["tapInstallCPI"]),
                               bidMin: money(insights?["bidMin"]), bidMax: money(insights?["bidMax"]))
        }
    }
}
