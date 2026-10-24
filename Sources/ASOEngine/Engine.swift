import Foundation
import ASOCore

/// The platform-neutral workbench: the jobs behind the command line (and later the Windows and Linux interface),
/// built on the same ASOCore rules and ASOProviders adapters as the macOS app.
public struct Engine: Sendable {
    public let store: Store
    public let search: any SearchRankProvider
    public let suggestions: any SuggestionProvider
    public let reviews: any CustomerReviewProvider
    /// Apple Ads popularity; nil when no keys are stored.
    public let popularity: (any PopularityProvider)?
    /// Jev through OpenRouter (brand, naturalness, fit); nil when no key is stored.
    public let judge: (any KeywordJudge)?
    /// The advertiser's own Apple Ads campaigns; nil when no keys are stored.
    public let ads: (any AdsCampaignSource)?

    public init(store: Store, search: any SearchRankProvider, suggestions: any SuggestionProvider, reviews: any CustomerReviewProvider,
                popularity: (any PopularityProvider)? = nil, judge: (any KeywordJudge)? = nil, ads: (any AdsCampaignSource)? = nil) {
        self.store = store
        self.search = search
        self.suggestions = suggestions
        self.reviews = reviews
        self.popularity = popularity
        self.judge = judge
        self.ads = ads
    }

    // MARK: Apps

    /// Starts tracking the app behind an App Store link or numeric ID, looked up in `countryCode` (else the link's
    /// country, else US). Adding an app that is already tracked refreshes its public details.
    public func addApp(reference: String, countryCode: String? = nil) async throws -> AppRecord {
        guard let link = AppStoreURL.parse(reference) else {
            throw EngineError.invalidArgument("\"\(reference)\" is not an App Store link or app ID.")
        }
        let storefront = try Self.storefront(countryCode ?? link.countryCode ?? "US")
        guard let found = try await search.lookup(trackID: link.trackID, storefront: storefront) else {
            throw EngineError.notFound("No app with ID \(link.trackID) in the \(storefront.name) App Store.")
        }
        let createdAt = try await store.app(trackID: found.trackID)?.createdAt ?? Date()
        try await store.upsertApp(AppRecord(found, createdAt: createdAt))
        // Return what was stored, so callers see the same values a later read gives them.
        return try await app(found.trackID)
    }

    /// Apps for the Add App search: an App Store link or ID looks up that app (in the link's country when it has one),
    /// anything else searches app names in `countryCode`. Nothing is stored.
    public func findApps(query: String, countryCode: String) async throws -> [SearchResultApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.invalidArgument("Type an app name, App Store link or app ID.") }
        if let link = AppStoreURL.parse(trimmed) {
            let storefront = try Self.storefront(link.countryCode ?? countryCode)
            return try await search.lookup(trackID: link.trackID, storefront: storefront).map { [$0] } ?? []
        }
        return try await search.lookup(term: trimmed, storefront: try Self.storefront(countryCode), limit: 25)
    }

    /// Tracks the app and creates a market per country for `device`, skipping markets that already exist.
    public func addApp(reference: String, lookupCountry: String?, markets countries: [String], device: DeviceContext) async throws -> AppRecord {
        let storefronts = try countries.map(Self.storefront)
        let app = try await addApp(reference: reference, countryCode: lookupCountry)
        for storefront in storefronts {
            _ = try await store.market(appID: app.trackID, countryCode: storefront.countryCode, device: device)
        }
        return app
    }

    /// Sets the Apple Ads genre used for popularity (nil: search every genre).
    public func setAdsGenre(appID: Int, genre: AppleAdsGenre?) async throws -> AppRecord {
        _ = try await app(appID)
        try await store.setAdsGenre(trackID: appID, genre: genre?.rawValue)
        return try await app(appID)
    }

    // MARK: Markets

    /// A market as lists show it.
    public struct MarketSummary: Sendable, Codable, Equatable {
        public let country: String
        public let countryName: String
        public let device: String
        public let keywords: Int
        public let lastMeasuredAt: Date?
    }

    public func addMarket(appID: Int, countryCode: String, device: DeviceContext) async throws -> MarketSummary {
        _ = try await app(appID)
        let market = try await store.market(appID: appID, countryCode: try Self.storefront(countryCode).countryCode, device: device)
        guard let summary = try await markets(appID: appID).first(where: { $0.country == market.countryCode && $0.device == market.device.rawValue }) else {
            throw EngineError.database("The market \(Self.title(market)) could not be read back.")
        }
        return summary
    }

    public func markets(appID: Int) async throws -> [MarketSummary] {
        _ = try await app(appID)
        return try await store.marketSummaries(appID: appID).map { row in
            MarketSummary(country: row.market.countryCode, countryName: StorefrontRegistry.lookup(row.market.countryCode)?.name ?? row.market.countryCode,
                          device: row.market.device.rawValue, keywords: row.keywords, lastMeasuredAt: row.lastMeasuredAt)
        }
    }

    /// Removes the market with its keywords and measurements.
    public func removeMarket(appID: Int, countryCode: String, device: DeviceContext) async throws {
        let country = try Self.storefront(countryCode).countryCode
        guard try await store.removeMarket(appID: appID, countryCode: country, device: device) else {
            throw EngineError.notFound("App \(appID) has no \(country) · \(device.rawValue) market.")
        }
    }

    public func app(_ trackID: Int) async throws -> AppRecord {
        guard let app = try await store.app(trackID: trackID) else {
            throw EngineError.notFound("App \(trackID) is not tracked. Add it first.")
        }
        return app
    }

    // MARK: Keywords

    public struct AddedKeywords: Sendable, Codable, Equatable {
        public let market: String
        public let added: [String]
        public let alreadyTracked: [String]
    }

    public func addKeywords(_ terms: [String], appID: Int, countryCode: String, device: DeviceContext) async throws -> AddedKeywords {
        _ = try await app(appID)
        let storefront = try Self.storefront(countryCode)
        let market = try await store.market(appID: appID, countryCode: storefront.countryCode, device: device)
        let result = try await store.addKeywords(terms, marketID: market.id)
        return AddedKeywords(market: Self.title(market), added: result.added.map(\.text), alreadyTracked: result.existing)
    }

    public func removeKeywords(_ terms: [String], appID: Int, countryCode: String, device: DeviceContext) async throws -> Int {
        let market = try await store.market(appID: appID, countryCode: try Self.storefront(countryCode).countryCode, device: device)
        return try await store.removeKeywords(terms, marketID: market.id)
    }

    // MARK: Measuring

    public struct MeasureProgress: Sendable, Equatable {
        public let market: String
        public let keyword: String
        public let completed: Int
        public let total: Int
        public let outcome: RankOutcome
    }

    public struct MeasureSummary: Sendable, Codable, Equatable {
        public var measured = 0
        public var found = 0
        public var outside = 0
        public var failed = 0
        /// The popularity refresh that follows a measurement when Apple Ads is connected, or why it failed.
        public var popularity: [PopularityRefresh]?
        public var popularityError: String?
    }

    /// Measures every keyword of the app's markets (optionally one country or device) with fresh searches, one after
    /// another; the provider paces requests. Every outcome is stored, failures included.
    /// `keywords`, when given, limits the run to those keywords (compared normalized); unknown ones are an error, so a
    /// typo never passes for "nothing to measure".
    /// With Apple Ads connected, the measured keywords' popularity is refreshed afterwards, as in the macOS app; a failed
    /// refresh is reported in the summary and does not undo the measurement.
    public func measure(appID: Int, countryCode: String? = nil, device: DeviceContext? = nil, depth: Int = 200, keywords: [String]? = nil,
                        progress: @Sendable (MeasureProgress) -> Void = { _ in }) async throws -> MeasureSummary {
        _ = try await app(appID)
        let markets = try await selectedMarkets(appID: appID, countryCode: countryCode, device: device)
        let only = try await keywordFilter(keywords, in: markets)
        var summary = try await measure(markets: markets, depth: depth, only: only, readCatalog: true, progress: progress)
        if summary.measured > 0, let popularity, await popularity.isConfigured {
            do {
                summary.popularity = try await refreshPopularity(appID: appID, countryCode: countryCode, device: device, keywords: keywords)
            } catch {
                summary.popularityError = error.localizedDescription
            }
        }
        return summary
    }

    /// The normalized keywords to limit a job to, or nil for all of them; a keyword the markets do not track is an error.
    func keywordFilter(_ keywords: [String]?, in markets: [MarketRecord]) async throws -> Set<String>? {
        guard let keywords else { return nil }
        let wanted = Set(keywords.map(KeywordText.normalize).filter { !$0.isEmpty })
        var known = Set<String>()
        for market in markets { known.formUnion(try await store.keywords(marketID: market.id).map(\.normalized)) }
        if let missing = wanted.subtracting(known).sorted().first {
            throw EngineError.notFound("\"\(missing)\" is not tracked in the chosen market(s).")
        }
        return wanted
    }

    // MARK: Keyword detail and notes

    /// The market's keyword, or a not-found error naming it.
    private func trackedKeyword(_ text: String, appID: Int, countryCode: String, device: DeviceContext) async throws -> (MarketRecord, KeywordRecord) {
        let market = try await existingMarket(appID: appID, countryCode: countryCode, device: device)
        guard let keyword = try await store.keyword(text, marketID: market.id) else {
            throw EngineError.notFound("\"\(text)\" is not tracked in \(Self.title(market)).")
        }
        return (market, keyword)
    }

    /// Everything the inspector shows for one keyword.
    public func keywordDetail(_ text: String, appID: Int, countryCode: String, device: DeviceContext,
                              deltaReference: DeltaReference = .previous, golden: GoldenThresholds = .standard) async throws -> KeywordDetail {
        let app = try await app(appID)
        let (market, keyword) = try await trackedKeyword(text, appID: appID, countryCode: countryCode, device: device)
        let observations = try await store.observations(keywordID: keyword.id)
        let ads = try await adsTotals(appID: appID)["\(keyword.normalized)|\(market.countryCode)"]
        let row = KeywordReportRow(keyword: keyword, market: market, app: app, observations: observations,
                                   popularity: try await store.latestPopularity(keywordID: keyword.id), deltaReference: deltaReference, golden: golden,
                                   markers: try await rankMarkers(appID: appID), ads: ads)
        return KeywordDetail(row: row, app: app, observations: observations)
    }

    /// Replaces the keyword's note; an empty note clears it.
    public func setNote(_ note: String, keyword text: String, appID: Int, countryCode: String, device: DeviceContext) async throws {
        _ = try await app(appID)
        let (_, keyword) = try await trackedKeyword(text, appID: appID, countryCode: countryCode, device: device)
        try await store.setNote(note.trimmingCharacters(in: .whitespacesAndNewlines), keywordID: keyword.id)
    }

    func existingMarket(appID: Int, countryCode: String, device: DeviceContext) async throws -> MarketRecord {
        let country = try Self.storefront(countryCode).countryCode
        guard let market = try await store.markets(appID: appID).first(where: { $0.countryCode == country && $0.device == device }) else {
            throw EngineError.notFound("App \(appID) has no \(country) · \(device.rawValue) market.")
        }
        return market
    }

    /// Measures every market, across all apps, whose newest measurement is older than `staleHours` or that was never
    /// measured (markets without keywords are skipped), as the macOS app does when it opens.
    public func measureStale(staleHours: Int, depth: Int = 200, now: Date = Date(),
                             progress: @Sendable (MeasureProgress) -> Void = { _ in }) async throws -> MeasureSummary {
        let threshold = now.addingTimeInterval(-Double(staleHours) * 3600)
        let stale = try await store.marketsWithKeywords().filter { ($0.lastMeasuredAt ?? .distantPast) < threshold }.map(\.market)
        return try await measure(markets: stale, depth: depth, progress: progress)
    }

    /// `readCatalog`: first read the app's ratings and new reviews in the measured storefronts, as the macOS app does
    /// before a measurement it is asked for (not before the start-up refresh).
    private func measure(markets: [MarketRecord], depth: Int, only: Set<String>? = nil, readCatalog: Bool = false,
                         progress: @Sendable (MeasureProgress) -> Void) async throws -> MeasureSummary {
        var work: [(MarketRecord, Storefront, Int, KeywordRecord)] = []
        for market in markets {
            let storefront = try Self.storefront(market.countryCode)
            for keyword in try await store.keywords(marketID: market.id) where only?.contains(keyword.normalized) ?? true {
                work.append((market, storefront, market.appID, keyword))
            }
        }
        if readCatalog, let appID = work.first?.2 {
            await readCatalogQuietly(appID: appID, storefronts: Self.unique(work.map(\.1)))
        }
        var summary = MeasureSummary()
        for (market, storefront, ownTrackID, keyword) in work {
            try Task.checkCancellation()
            let sample = await RankSample.measure(keyword: keyword.text, storefront: storefront, device: market.device,
                                                  ownTrackID: ownTrackID, depth: depth, provider: search)
            try await store.addObservation(sample, keywordID: keyword.id)
            summary.measured += 1
            switch sample.outcome {
            case .found: summary.found += 1
            case .outsideObservedRange: summary.outside += 1
            case .requestFailed, .notChecked: summary.failed += 1
            }
            progress(MeasureProgress(market: Self.title(market), keyword: keyword.text, completed: summary.measured, total: work.count,
                                     outcome: sample.outcome))
        }
        return summary
    }

    // MARK: Reports

    /// One row per tracked keyword with the latest rank, Δ, difficulty and the brand/golden verdicts.
    public func keywordReport(appID: Int, countryCode: String? = nil, device: DeviceContext? = nil,
                              deltaReference: DeltaReference = .previous, golden: GoldenThresholds = .standard) async throws -> [KeywordReportRow] {
        let app = try await app(appID)
        let markers = try await rankMarkers(appID: appID)
        let ads = try await adsTotals(appID: appID)
        var rows: [KeywordReportRow] = []
        for market in try await selectedMarkets(appID: appID, countryCode: countryCode, device: device) {
            for keyword in try await store.keywords(marketID: market.id) {
                let observations = try await store.observations(keywordID: keyword.id)
                let popularity = try await store.latestPopularity(keywordID: keyword.id)
                rows.append(KeywordReportRow(keyword: keyword, market: market, app: app, observations: observations, popularity: popularity,
                                             deltaReference: deltaReference, golden: golden, markers: markers,
                                             ads: ads["\(keyword.normalized)|\(market.countryCode)"]))
            }
        }
        return rows
    }

    // MARK: Ad-hoc lookups (nothing stored)

    public func searchResults(term: String, countryCode: String, device: DeviceContext, limit: Int) async throws -> [SearchResultApp] {
        try await search.search(term: term, storefront: try Self.storefront(countryCode), device: device, limit: limit)
    }

    public func hints(seed: String, countryCode: String) async throws -> [String] {
        try await suggestions.suggestions(seed: seed, storefront: try Self.storefront(countryCode)).map(\.text)
    }

    /// Difficulty of a term right now, from a fresh search (the top ten count, as everywhere else).
    public func difficulty(term: String, countryCode: String, device: DeviceContext) async throws -> DifficultyScore? {
        let results = try await searchResults(term: term, countryCode: countryCode, device: device, limit: 50)
        return DifficultyScore(results: results, term: term)
    }

    // MARK: Helpers

    static func storefront(_ code: String) throws -> Storefront {
        guard let storefront = StorefrontRegistry.lookup(code.uppercased()) else {
            throw EngineError.invalidArgument("\"\(code)\" is not a supported App Store country code.")
        }
        return storefront
    }

    static func title(_ market: MarketRecord) -> String { "\(market.countryCode) · \(market.device.rawValue)" }

    func selectedMarkets(appID: Int, countryCode: String?, device: DeviceContext?) async throws -> [MarketRecord] {
        let country = try countryCode.map { try Self.storefront($0).countryCode }
        return try await store.markets(appID: appID).filter {
            (country == nil || $0.countryCode == country) && (device == nil || $0.device == device)
        }
    }
}

/// The golden-keyword thresholds (the macOS app's defaults).
public struct GoldenThresholds: Sendable, Equatable {
    public var minPopularity: Int
    public var maxDifficulty: Int

    public init(minPopularity: Int, maxDifficulty: Int) {
        self.minPopularity = minPopularity
        self.maxDifficulty = maxDifficulty
    }

    public static let standard = GoldenThresholds(minPopularity: 30, maxDifficulty: 45)
}
