import Foundation
import ASOCore
import ASOProviders

/// The advertiser's own Apple Ads campaigns and keyword reports (Campaign Management API), behind a protocol so the
/// sync is tested without the network.
public protocol AdsCampaignSource: Sendable {
    var isConfigured: Bool { get async }
    func campaigns() async throws -> [AppleAdsCampaignProvider.Campaign]
    func keywordReport(campaignID: Int, start: Date, end: Date) async throws -> [AppleAdsCampaignProvider.KeywordStat]
}

extension AppleAdsCampaignProvider: AdsCampaignSource {}

/// A keyword's own campaign results in one storefront, summed over campaigns and match types.
public struct AdsTotals: Sendable, Codable, Equatable {
    public let impressions: Int
    public let taps: Int
    public let installs: Int
    public let spend: Double
    public let currency: String

    init?(_ rows: [AdsKeywordStatRecord]) {
        guard !rows.isEmpty else { return nil }
        impressions = rows.reduce(0) { $0 + $1.impressions }
        taps = rows.reduce(0) { $0 + $1.taps }
        installs = rows.reduce(0) { $0 + $1.installs }
        spend = rows.reduce(0) { $0 + $1.spend }
        currency = rows.first?.currency ?? ""
    }
}

extension Engine {
    public struct AdsSync: Sendable, Codable, Equatable {
        /// Campaigns in the account, and those that promote a tracked app.
        public let campaigns: Int
        public let matched: Int
        /// Keyword × storefront rows stored.
        public let rows: Int
        public let periodStart: Date
        public let periodEnd: Date
    }

    /// One storefront of the app's campaigns, as the macOS app's Apple Ads card shows it.
    public struct AdsStorefront: Sendable, Codable, Equatable {
        public let country: String
        public let countryName: String
        public let impressions: Int
        public let taps: Int
        public let installs: Int
        public let spend: Double
        public let currency: String
        public let costPerInstall: Double?
        public let tapToInstall: Double?
    }

    public struct AdsReport: Sendable, Codable, Equatable {
        /// When the rows were read and the window they cover; absent before the first sync.
        public let syncedAt: Date?
        public let periodStart: Date?
        public let periodEnd: Date?
        /// Biggest spend first.
        public let storefronts: [AdsStorefront]
        public let keywords: [AdsKeywordStatRecord]
    }

    /// Reads the last `days` of every campaign that promotes a tracked app and replaces that campaign's stored rows, as
    /// the macOS app's "Sync last 30 days" does. Campaigns for other apps are left alone. Needs the Apple Ads keys.
    public func syncAds(days: Int = 30, now: Date = Date()) async throws -> AdsSync {
        guard let ads, await ads.isConfigured else { throw EngineError.invalidArgument(Self.adsNotConnected) }
        guard (1...90).contains(days) else { throw EngineError.invalidArgument("Sync 1 to 90 days, not \(days).") }
        let start = now.addingTimeInterval(-Double(days) * 86_400)
        let tracked = Set(try await store.apps().map(\.trackID))
        let campaigns = try await ads.campaigns()
        var matched = 0, rows = 0
        for campaign in campaigns {
            guard let appID = campaign.adamID, tracked.contains(appID) else { continue }
            matched += 1
            let stats = try await ads.keywordReport(campaignID: campaign.id, start: start, end: now).map { s in
                AdsKeywordStatRecord(campaignID: campaign.id, campaignName: campaign.name, adGroupName: s.adGroupName, keywordID: s.keywordID,
                                     keyword: s.keyword, matchType: s.matchType, status: s.status, country: s.country.uppercased(), bid: s.bid,
                                     currency: s.currency, impressions: s.impressions, taps: s.taps, installs: s.installs, spend: s.spend, ttr: s.ttr,
                                     conversionRate: s.conversionRate, avgCPT: s.avgCPT, avgCPI: s.avgCPI, periodStart: start, periodEnd: now,
                                     fetchedAt: now)
            }
            try await store.replaceAdsStats(stats, campaignID: campaign.id, appID: appID)
            rows += stats.count
        }
        return AdsSync(campaigns: campaigns.count, matched: matched, rows: rows, periodStart: start, periodEnd: now)
    }

    /// The app's stored campaign results: per storefront, and every keyword row.
    public func adsReport(appID: Int) async throws -> AdsReport {
        _ = try await app(appID)
        let rows = try await store.adsStats(appID: appID)
        let storefronts = Dictionary(grouping: rows, by: \.country).compactMap { country, list -> AdsStorefront? in
            guard let totals = AdsTotals(list) else { return nil }
            return AdsStorefront(country: country, countryName: StorefrontRegistry.lookup(country)?.name ?? country, impressions: totals.impressions,
                                 taps: totals.taps, installs: totals.installs, spend: totals.spend, currency: totals.currency,
                                 costPerInstall: totals.installs > 0 ? totals.spend / Double(totals.installs) : nil,
                                 tapToInstall: totals.taps > 0 ? Double(totals.installs) / Double(totals.taps) : nil)
        }.sorted { ($0.spend, $1.country) > ($1.spend, $0.country) }
        let latest = rows.max { $0.fetchedAt < $1.fetchedAt }
        return AdsReport(syncedAt: latest?.fetchedAt, periodStart: latest?.periodStart, periodEnd: latest?.periodEnd, storefronts: storefronts,
                         keywords: rows)
    }

    /// Each tracked keyword's totals by "<normalized>|<country>", for the keyword report.
    func adsTotals(appID: Int) async throws -> [String: AdsTotals] {
        let rows = try await store.adsStats(appID: appID)
        return Dictionary(grouping: rows) { "\(KeywordText.normalize($0.keyword))|\($0.country)" }.compactMapValues(AdsTotals.init)
    }
}
