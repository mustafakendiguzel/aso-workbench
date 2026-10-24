import Foundation
import ASOCore

/// The platform-neutral workbench: the jobs behind the command line (and later the Windows and Linux interface),
/// built on the same ASOCore rules and ASOProviders adapters as the macOS app.
public struct Engine: Sendable {
    public let store: Store
    public let search: any SearchRankProvider
    public let suggestions: any SuggestionProvider

    public init(store: Store, search: any SearchRankProvider, suggestions: any SuggestionProvider) {
        self.store = store
        self.search = search
        self.suggestions = suggestions
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
    }

    /// Measures every keyword of the app's markets (optionally one country or device) with fresh searches, one after
    /// another; the provider paces requests. Every outcome is stored, failures included.
    public func measure(appID: Int, countryCode: String? = nil, device: DeviceContext? = nil, depth: Int = 200,
                        progress: @Sendable (MeasureProgress) -> Void = { _ in }) async throws -> MeasureSummary {
        let app = try await app(appID)
        let markets = try await selectedMarkets(appID: appID, countryCode: countryCode, device: device)
        var work: [(MarketRecord, Storefront, KeywordRecord)] = []
        for market in markets {
            let storefront = try Self.storefront(market.countryCode)
            for keyword in try await store.keywords(marketID: market.id) { work.append((market, storefront, keyword)) }
        }
        var summary = MeasureSummary()
        for (market, storefront, keyword) in work {
            try Task.checkCancellation()
            let sample = await RankSample.measure(keyword: keyword.text, storefront: storefront, device: market.device,
                                                  ownTrackID: app.trackID, depth: depth, provider: search)
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
        var rows: [KeywordReportRow] = []
        for market in try await selectedMarkets(appID: appID, countryCode: countryCode, device: device) {
            for keyword in try await store.keywords(marketID: market.id) {
                let observations = try await store.observations(keywordID: keyword.id)
                rows.append(KeywordReportRow(keyword: keyword, market: market, app: app, observations: observations,
                                             deltaReference: deltaReference, golden: golden))
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

    private func selectedMarkets(appID: Int, countryCode: String?, device: DeviceContext?) async throws -> [MarketRecord] {
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
