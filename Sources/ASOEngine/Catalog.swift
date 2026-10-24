import Foundation
import ASOCore

/// What the App Store says about the tracked app itself (ratings, written reviews) and who it competes with in the
/// tracked searches.
extension Engine {
    /// Every storefront the engine knows, for checks across all of them.
    public static var allCountries: [String] { StorefrontRegistry.sortedByName.map(\.countryCode) }

    // MARK: Ratings

    public struct RatingsCheck: Sendable, Codable, Equatable {
        public var storefronts = 0
        /// Readings stored; a reading that repeats the previous one within the hour is not.
        public var recorded = 0
        /// Ratings that arrived since the previous reading, across the storefronts.
        public var newRatings = 0
        /// Storefronts whose request failed, and ones where the App Store has no rating count for the app.
        public var failed: [String] = []
        public var unavailable: [String] = []
    }

    /// Reads the rating count and average in each storefront (one public request each): the app's markets, or the
    /// countries given.
    public func checkRatings(appID: Int, countries: [String]? = nil, clock: @Sendable () -> Date = { Date() }) async throws -> RatingsCheck {
        _ = try await app(appID)
        let storefronts = try await catalogStorefronts(appID: appID, countries: countries)
        var check = RatingsCheck(storefronts: storefronts.count)
        for storefront in storefronts {
            try Task.checkCancellation()
            let info: SearchResultApp?
            do {
                info = try await search.lookup(trackID: appID, storefront: storefront)
            } catch {
                try Task.checkCancellation()
                check.failed.append(storefront.countryCode)
                continue
            }
            guard let info, info.ratingCount != nil else {
                check.unavailable.append(storefront.countryCode)
                continue
            }
            if let new = try await recordRating(of: info, appID: appID, countryCode: storefront.countryCode, at: clock()) {
                check.recorded += 1
                check.newRatings += new
            }
        }
        return check
    }

    /// Stores the reading `info` carries unless it repeats the previous one within the hour. Returns the ratings that
    /// arrived since the previous reading, or nil when nothing was stored.
    @discardableResult
    func recordRating(of info: SearchResultApp, appID: Int, countryCode: String, at now: Date) async throws -> Int? {
        guard let count = info.ratingCount else { return nil }
        let previous = try await store.latestRating(appID: appID, countryCode: countryCode)
        guard RatingTrend.shouldRecord(count: count, average: info.averageRating, previous: previous, now: now) else { return nil }
        try await store.addRating(RatingReading(countryCode: countryCode, count: count, average: info.averageRating, fetchedAt: now), appID: appID)
        return max(0, count - (previous?.count ?? count))
    }

    /// Ratings in one storefront as the Overview shows them.
    public struct RatingRow: Sendable, Codable, Equatable {
        public let country: String
        public let countryName: String
        public let count: Int
        public let average: Double?
        /// Count change since the previous reading; absent on the first.
        public let delta: Int?
        public let previousAt: Date?
        public let checkedAt: Date
        /// When a new rating was last seen between two readings.
        public let lastNewAt: Date?
    }

    /// One row per storefront with readings, the most recent new rating first.
    public func ratings(appID: Int) async throws -> [RatingRow] {
        _ = try await app(appID)
        return RatingTrend.trends(try await store.ratings(appID: appID)).map { t in
            RatingRow(country: t.countryCode, countryName: StorefrontRegistry.lookup(t.countryCode)?.name ?? t.countryCode, count: t.count,
                      average: t.average, delta: t.delta, previousAt: t.previousAt, checkedAt: t.checkedAt, lastNewAt: t.lastNewAt)
        }
    }

    // MARK: Reviews

    public struct ReviewsCheck: Sendable, Codable, Equatable {
        public let storefronts: Int
        /// Reviews not seen before; they are marked new (except on the app's first check).
        public let added: Int
        public let stored: Int
        public let failed: [String]
    }

    /// Reads the newest written reviews in each storefront (one public request each) and stores the ones not seen
    /// before. When no storefront answers, nothing changes, so the previous check's new reviews stay marked.
    public func checkReviews(appID: Int, countries: [String]? = nil, clock: @Sendable () -> Date = { Date() }) async throws -> ReviewsCheck {
        _ = try await app(appID)
        let storefronts = try await catalogStorefronts(appID: appID, countries: countries)
        var fetched: [CustomerReview] = []
        var failed: [String] = []
        for storefront in storefronts {
            try Task.checkCancellation()
            do {
                fetched += try await reviews.reviews(trackID: appID, storefront: storefront, page: 1)
            } catch {
                try Task.checkCancellation()
                failed.append(storefront.countryCode)
            }
        }
        guard failed.count < storefronts.count else {
            throw EngineError.notFound("The App Store reviews feed did not answer for \(failed.joined(separator: ", ")); nothing was changed.")
        }
        let added = try await store.recordReviews(fetched, appID: appID, fetchedAt: clock())
        return ReviewsCheck(storefronts: storefronts.count, added: added, stored: try await store.reviews(appID: appID).count, failed: failed)
    }

    public struct ReviewFilter: Sendable, Equatable {
        public var country: String?
        public var minRating: Int
        public var onlyNew: Bool
        public var search: String?

        public init(country: String? = nil, minRating: Int = 1, onlyNew: Bool = false, search: String? = nil) {
            self.country = country
            self.minRating = minRating
            self.onlyNew = onlyNew
            self.search = search
        }

        func accepts(_ review: StoredReview) -> Bool {
            guard country.map({ $0.uppercased() == review.country }) ?? true, review.rating >= minRating, !onlyNew || review.isNew else { return false }
            guard let search, !search.isEmpty else { return true }
            return review.title.range(of: search, options: .caseInsensitive) != nil || review.body.range(of: search, options: .caseInsensitive) != nil
        }
    }

    /// The stored reviews with totals over all of them, and the ones the filter keeps, newest first.
    public struct ReviewsReport: Sendable, Codable, Equatable {
        public let stored: Int
        public let new: Int
        public let average: Double?
        /// Stored reviews with one to five stars, in that order.
        public let stars: [Int]
        /// Storefronts with stored reviews.
        public let countries: [String]
        public let reviews: [StoredReview]
    }

    public func reviewsReport(appID: Int, filter: ReviewFilter = ReviewFilter()) async throws -> ReviewsReport {
        _ = try await app(appID)
        let all = try await store.reviews(appID: appID)
        let average = all.isEmpty ? nil : Double(all.map(\.rating).reduce(0, +)) / Double(all.count)
        return ReviewsReport(stored: all.count, new: all.filter(\.isNew).count, average: average,
                             stars: (1...5).map { stars in all.filter { $0.rating == stars }.count },
                             countries: Array(Set(all.map(\.country))).sorted(), reviews: all.filter(filter.accepts))
    }

    // MARK: Competitors

    /// Apps seen in the latest results of the market's tracked keywords. Only tracked searches count: this is not a
    /// competitor's full keyword set.
    public struct CompetitorsReport: Sendable, Codable, Equatable {
        public struct Appearance: Sendable, Codable, Equatable {
            public let keyword: String
            public let position: Int
        }

        public struct Competitor: Sendable, Codable, Equatable {
            public let trackID: Int
            public let name: String
            public let sellerName: String
            public let bundleID: String?
            public let iconURL: String?
            public let primaryGenre: String?
            public let ratingCount: Int?
            public let averageRating: Double?
            public let currentVersionReleaseDate: Date?
            /// Tracked keywords it appears in, how many of those in the top ten, and its average position in them.
            public let keywords: Int
            public let top10: Int
            public let averagePosition: Double
            /// Best position first.
            public let appearances: [Appearance]
        }

        public let market: String
        public let depth: Int
        /// Keywords with a successful measurement, the samples the list is built from.
        public let keywordsMeasured: Int
        public let competitors: [Competitor]
    }

    /// `depth`: how deep in each result list to look (up to the 50 results stored per measurement).
    public func competitors(appID: Int, countryCode: String, device: DeviceContext, depth: Int = 10) async throws -> CompetitorsReport {
        guard (1...50).contains(depth) else { throw EngineError.invalidArgument("The depth must be from 1 to 50 (the results stored per measurement).") }
        _ = try await app(appID)
        let market = try await existingMarket(appID: appID, countryCode: countryCode, device: device)
        var samples: [RankSample] = []
        for keyword in try await store.keywords(marketID: market.id) {
            let history = RankHistory(try await store.observations(keywordID: keyword.id)) { $0.point }
            guard let latest = history.latestMeasured else { continue }
            samples.append(RankSample(keyword: keyword.text, storefront: market.countryCode, device: market.device, provider: latest.provider,
                                      outcome: latest.outcome, fetchedAt: latest.fetchedAt, results: latest.results))
        }
        let competitors = CompetitorAggregation.aggregate(samples: samples, ownTrackID: appID, depth: depth).map { c in
            CompetitorsReport.Competitor(trackID: c.app.trackID, name: c.app.name, sellerName: c.app.sellerName, bundleID: c.app.bundleID,
                                         iconURL: c.app.iconURL?.absoluteString, primaryGenre: c.app.primaryGenre, ratingCount: c.app.ratingCount,
                                         averageRating: c.app.averageRating, currentVersionReleaseDate: c.app.currentVersionReleaseDate,
                                         keywords: c.appearanceCount, top10: c.top10Count, averagePosition: c.averagePosition,
                                         appearances: c.appearances.sorted { ($0.position, $0.keyword) < ($1.position, $1.keyword) }
                                             .map { .init(keyword: $0.keyword, position: $0.position) })
        }
        return CompetitorsReport(market: Self.title(market), depth: depth, keywordsMeasured: samples.count, competitors: competitors)
    }

    // MARK: Helpers

    /// Ratings and new reviews before a measurement. Best effort: a failed read never stops the measurement.
    func readCatalogQuietly(appID: Int, storefronts: [Storefront]) async {
        let countries = storefronts.map(\.countryCode)
        _ = try? await checkRatings(appID: appID, countries: countries)
        _ = try? await checkReviews(appID: appID, countries: countries)
    }

    /// The countries given (validated), else the app's market countries.
    private func catalogStorefronts(appID: Int, countries: [String]?) async throws -> [Storefront] {
        if let countries {
            guard !countries.isEmpty else { throw EngineError.invalidArgument("Give at least one country.") }
            return Self.unique(try countries.map(Self.storefront))
        }
        let markets = try await store.markets(appID: appID)
        guard !markets.isEmpty else {
            throw EngineError.invalidArgument("App \(appID) has no markets yet; add one, or name the countries to check.")
        }
        return Self.unique(try markets.map { try Self.storefront($0.countryCode) })
    }

    static func unique(_ storefronts: [Storefront]) -> [Storefront] {
        var seen = Set<String>()
        return storefronts.filter { seen.insert($0.countryCode).inserted }
    }
}
