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

/// RevenueCat without the network: one canned read.
struct FakeRevenue: RevenueSource {
    var result: RevenueRead
    func read() async -> RevenueRead { result }
}

func makeProject(_ id: String, _ name: String, bundles: [String], apps: [String] = [], mrr: Double, subscriptions: Int = 10) -> RevenueRead.Project {
    RevenueRead.Project(id: id, name: name, bundleIDs: bundles, appNames: apps,
                        overview: .init(mrr: mrr, activeSubscriptions: subscriptions, revenue28d: mrr * 0.9, newCustomers28d: 4, activeTrials: 2,
                                        activeUsers28d: 50))
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
                ads: FakeAds? = nil, revenue: FakeRevenue? = nil, publisher: FakePublisher? = nil) throws -> Engine {
    Engine(store: try Store.inMemory(), search: search, suggestions: hints, reviews: reviews, popularity: popularity, judge: judge, ads: ads,
           revenue: revenue, publisher: publisher)
}

/// App Store Connect without the network: one app's listing per locale and its versions. Writes change the listing and
/// are recorded; Apple can be made to keep some fields as they were, or to fail.
final class FakePublisher: MetadataPublisher, @unchecked Sendable {
    private let lock = NSLock()
    private var listing: [AppLocale: MetadataFields]
    private var versionList: [Engine.ASCVersion]
    private var log: [String] = []
    let privacyURL: String?
    /// Fields Apple keeps unchanged on a write.
    let ignored: Set<MetadataField>
    let failing: Bool

    init(listing: [AppLocale: MetadataFields], versions: [Engine.ASCVersion] = [Engine.ASCVersion(id: "v2", version: "2.0", state: "PREPARE_FOR_SUBMISSION")],
         privacyURL: String? = nil, ignored: Set<MetadataField> = [], failing: Bool = false) {
        self.listing = listing
        versionList = versions
        self.privacyURL = privacyURL
        self.ignored = ignored
        self.failing = failing
    }

    /// Every write, e.g. "apply de-DE keywords,subtitle".
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return log }

    /// Someone else edits the listing on App Store Connect.
    func edit(_ locale: AppLocale, _ change: (inout MetadataFields) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&listing[locale, default: .empty])
    }

    private func record(_ write: String) {
        lock.lock(); defer { lock.unlock() }
        log.append(write)
    }

    private func current() -> ([AppLocale: MetadataFields], Engine.ASCVersion?) {
        lock.lock(); defer { lock.unlock() }
        return (listing, versionList.first(where: \.editable) ?? versionList.first)
    }

    func resolveAppID(bundleID: String) async throws -> String { "asc-\(bundleID)" }

    func snapshots(ascAppID: String) async throws -> [MetadataSnapshot] {
        let (listing, version) = current()
        return listing.keys.sorted { $0.rawValue < $1.rawValue }.map { locale in
            MetadataSnapshot(locale: locale, fields: listing[locale] ?? .empty, appInfoLocalizationID: "info-\(locale.rawValue)",
                             versionLocalizationID: "version-\(locale.rawValue)", versionString: version?.version, versionState: version?.state,
                             fetchedAt: Date(timeIntervalSince1970: 0))
        }
    }

    func privacyPolicyURL(ascAppID: String) async throws -> String? { privacyURL }

    /// Synchronous, so the lock is never held across a suspension point.
    private func listVersions(adding version: Engine.ASCVersion? = nil) -> [Engine.ASCVersion] {
        lock.lock(); defer { lock.unlock() }
        if let version { versionList.insert(version, at: 0) }
        return versionList
    }

    func versions(ascAppID: String) async throws -> [Engine.ASCVersion] { listVersions() }

    func createVersion(ascAppID: String, versionString: String) async throws -> Engine.ASCVersion {
        record("create-version \(versionString)")
        let version = Engine.ASCVersion(id: "v-\(versionString)", version: versionString, state: "PREPARE_FOR_SUBMISSION")
        _ = listVersions(adding: version)
        return version
    }

    func ensureLocalizations(ascAppID: String, locale: AppLocale, name: String) async throws -> MetadataSnapshot {
        record("create \(locale.rawValue)")
        edit(locale) { $0.name = String(name.prefix(30)) }
        return try await snapshots(ascAppID: ascAppID).first { $0.locale == locale }!
    }

    func copyScreenshots(fromLocalization source: String, toLocalization target: String) async throws -> Engine.ScreenshotCopy {
        record("screenshots \(source) → \(target)")
        return Engine.ScreenshotCopy(sets: 2, copied: 6, skipped: 0, errors: [])
    }

    func apply(ascAppID: String, snapshot: MetadataSnapshot, changes: [MetadataField: String]) async throws -> MetadataSnapshot {
        if failing { throw ASOError.conflict("App Store Connect rejected the change (409): STATE_ERROR") }
        record("apply \(snapshot.locale.rawValue) \(changes.keys.map(\.rawValue).sorted().joined(separator: ","))")
        edit(snapshot.locale) { fields in
            for (field, text) in changes where !ignored.contains(field) { fields[field] = text }
        }
        return try await snapshots(ascAppID: ascAppID).first { $0.locale == snapshot.locale }!
    }
}

/// A fresh folder under the system temporary directory, removed by the caller.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aso-engine-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
