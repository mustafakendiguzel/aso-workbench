import Foundation
import ASOCore
import ASOProviders
@testable import ASOEngine

/// App Store search without the network: canned results per term, terms that fail, apps by ID.
struct FakeSearch: SearchRankProvider {
    let id: ProviderID = "fake-search"
    var results: [String: [SearchResultApp]] = [:]
    var failing: Set<String> = []
    var apps: [Int: SearchResultApp] = [:]

    func search(term: String, storefront: Storefront, device: DeviceContext, limit: Int) async throws -> [SearchResultApp] {
        if failing.contains(term) { throw ASOError.network("offline") }
        return Array((results[term] ?? []).prefix(limit))
    }

    func lookup(term: String, storefront: Storefront, limit: Int) async throws -> [SearchResultApp] {
        Array(apps.values.filter { $0.name.localizedCaseInsensitiveContains(term) }.prefix(limit))
    }

    func lookup(trackID: Int, storefront: Storefront) async throws -> SearchResultApp? { apps[trackID] }
}

struct FakeSuggestions: SuggestionProvider {
    let id: ProviderID = "fake-hints"
    var hints: [String: [String]] = [:]

    func suggestions(seed: String, storefront: Storefront) async throws -> [KeywordSuggestion] {
        (hints[seed] ?? []).enumerated().map {
            KeywordSuggestion(text: $1, provider: id, origin: .publicSearchObserved, popularity: nil, position: $0 + 1, fetchedAt: Date())
        }
    }
}

/// The reviews feed without the network: canned reviews per country, countries that fail.
struct FakeReviews: CustomerReviewProvider {
    var byCountry: [String: [CustomerReview]] = [:]
    var failing: Set<String> = []

    func reviews(trackID: Int, storefront: Storefront, page: Int) async throws -> [CustomerReview] {
        if failing.contains(storefront.countryCode) { throw ASOError.network("offline") }
        return byCountry[storefront.countryCode] ?? []
    }
}

/// Apple Ads popularity without the network: each genre's list as term → 1–100 score, for the month before `now`.
struct FakePopularity: PopularityProvider {
    let id: ProviderID = .appleAdsPopularity
    var lists: [AppleAdsGenre: [String: Int]] = [:]
    var failing = false
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    var isConfigured: Bool { true }

    func genreDataset(country: String, genre: AppleAdsGenre, monthsBack: Int) async throws -> [PopularityRecord] {
        if failing { throw ASOError.network("offline") }
        let (start, end) = AppleAdsPopularityProvider.lastFullMonth(monthsBack: monthsBack, now: now)
        return (lists[genre] ?? [:]).sorted { $0.key < $1.key }.map { term, score in
            PopularityRecord(searchTerm: term, countryCode: country, genre: genre, popularity1to100: score, popularity1to5: nil,
                             popularityInGenre: nil, rankInGenre: nil, periodStart: start, periodEnd: end, fetchedAt: now)
        }
    }

    func popularity(terms: [String], country: String, genre: AppleAdsGenre, monthsBack: Int) async throws -> [PopularityRecord] {
        let wanted = Set(terms.map { $0.lowercased() })
        return try await genreDataset(country: country, genre: genre, monthsBack: monthsBack).filter { wanted.contains($0.searchTerm) }
    }

    /// Apple Ads keyword suggestions per seed.
    var suggestions: [String: [String]] = [:]

    func keywordSuggestions(appID: Int, seeds: [String], country: String) async throws -> [KeywordSuggestion] {
        seeds.flatMap { suggestions[$0] ?? [] }.enumerated().map {
            KeywordSuggestion(text: $1, provider: .appleAdsSuggestions, origin: .officialObserved, popularity: nil, position: $0 + 1, fetchedAt: now)
        }
    }

    func capabilities() async -> ProviderCapabilities { ProviderCapabilities(maxPageSize: 200) }
}

/// Apple Ads campaigns without the network: the account's campaigns and each one's keyword report.
struct FakeAds: AdsCampaignSource {
    var list: [AppleAdsCampaignProvider.Campaign] = []
    var reports: [Int: [AppleAdsCampaignProvider.KeywordStat]] = [:]

    var isConfigured: Bool { true }
    func campaigns() async throws -> [AppleAdsCampaignProvider.Campaign] { list }
    func keywordReport(campaignID: Int, start: Date, end: Date) async throws -> [AppleAdsCampaignProvider.KeywordStat] { reports[campaignID] ?? [] }
}

func makeStat(_ keyword: String, _ country: String, campaign: Int = 1, match: String = "EXACT", impressions: Int, taps: Int, installs: Int,
              spend: Double) -> AppleAdsCampaignProvider.KeywordStat {
    AppleAdsCampaignProvider.KeywordStat(campaignID: campaign, adGroupName: "Group", keywordID: impressions, keyword: keyword, matchType: match,
                                         status: "ACTIVE", country: country, bid: 1.5, currency: "USD", impressions: impressions, taps: taps,
                                         installs: installs, spend: spend, ttr: nil, conversionRate: nil, avgCPT: nil, avgCPI: nil, bidMin: nil,
                                         bidMax: nil)
}

/// Jev without the network: brands, unnatural phrases and terms that do not fit the app, by name; every call counted.
final class FakeJudge: KeywordJudge, @unchecked Sendable {
    let brands: Set<String>
    let unnatural: Set<String>
    let unfit: Set<String>
    private let lock = NSLock()
    private var classified: [String] = []
    private var fitted: [String] = []

    init(brands: Set<String> = [], unnatural: Set<String> = [], unfit: Set<String> = []) {
        self.brands = brands
        self.unnatural = unnatural
        self.unfit = unfit
    }

    var isConfigured: Bool { true }
    var fitChecks: [String] { lock.lock(); defer { lock.unlock() }; return fitted.sorted() }

    /// Synchronous, so the lock is never held across a suspension point.
    private func note(_ term: String, fit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if fit { fitted.append(term) } else { classified.append(term) }
    }

    func classify(term: String, storefront: String, storeLanguage: String) async throws -> JevFeatures {
        note(term, fit: false)
        var features = JevFeatures()
        features.brand = brands.contains(term) ? 0.9 : 0.05
        features.naturalQuery = unnatural.contains(term) ? 0.1 : 0.9
        features.intent = brands.contains(term) ? "brand" : "feature"
        return features
    }

    func fit(term: String, appName: String, appDescription: String, storefront: String, storeLanguage: String) async throws -> Double {
        note(term, fit: true)
        return unfit.contains(term) ? 0.1 : 0.9
    }
}

func makeReview(_ id: String, _ country: String = "US", rating: Int = 5, title: String? = nil, body: String = "Works well.",
                date: Date? = nil) -> CustomerReview {
    CustomerReview(id: id, countryCode: country, title: title ?? "Review \(id)", body: body, rating: rating, author: "Reader \(id)", version: "2.0",
                   date: date)
}

func makeApp(_ id: Int, _ name: String, seller: String? = nil, ratings: Int? = 100) -> SearchResultApp {
    SearchResultApp(trackID: id, bundleID: "com.example.\(id)", name: name, sellerName: seller ?? "Seller \(id)", iconURL: nil,
                    averageRating: 4.5, ratingCount: ratings, primaryGenre: "Productivity", releaseDate: nil, currentVersionReleaseDate: nil,
                    price: 0, version: "1.0")
}

let ownApp = makeApp(1_000_001, "Acme Notes", seller: "Acme Inc")

func makeEngine(search: FakeSearch = FakeSearch(apps: [ownApp.trackID: ownApp]), hints: FakeSuggestions = FakeSuggestions(),
                reviews: FakeReviews = FakeReviews(), popularity: FakePopularity? = nil, judge: FakeJudge? = nil,
                ads: FakeAds? = nil) throws -> Engine {
    Engine(store: try Store.inMemory(), search: search, suggestions: hints, reviews: reviews, popularity: popularity, judge: judge, ads: ads)
}

/// A fresh folder under the system temporary directory, removed by the caller.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aso-engine-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
