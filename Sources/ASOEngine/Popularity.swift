import Foundation
import ASOCore
import ASOProviders

extension Engine {
    /// What one popularity refresh found in one country.
    public struct PopularityRefresh: Sendable, Codable, Equatable {
        public let country: String
        /// Raw Apple Ads genre whose list was read; absent when every genre was searched.
        public let genre: String?
        /// The month the scores describe (Apple publishes them with a delay, so it is the last full month).
        public let periodStart: Date
        public let periodEnd: Date
        public let keywords: Int
        /// Keywords on Apple's list, with a 1–100 score.
        public let onList: Int
        /// Keywords not on it: below the published range.
        public let belowRange: Int
        /// The lowest score on the list that month, which the terms below the range are under; absent when it could not be read.
        public let floor: Int?
        /// The genres whose lists had the terms, when every genre was searched.
        public let genresFound: [String]
    }

    static let adsNotConnected = "Apple Ads is not connected. Add its keys with: aso connections set apple-ads (or in the window: Settings → Connections)."

    /// Popularity from Apple Ads for the app's keywords (optionally one country, device or a few keywords), as the
    /// macOS app reads it: Apple's country list for the app's genre (or every genre, keeping each term's highest score),
    /// and for the terms that are not on it, "below the published range" under the list's lowest score. Markets of
    /// the same country share one lookup. Every reading is stored; earlier ones are kept.
    public func refreshPopularity(appID: Int, countryCode: String? = nil, device: DeviceContext? = nil, keywords: [String]? = nil,
                                  now: Date = Date(), progress: @Sendable (String) -> Void = { _ in }) async throws -> [PopularityRefresh] {
        let app = try await app(appID)
        guard let popularity, await popularity.isConfigured else { throw EngineError.invalidArgument(Self.adsNotConnected) }
        let markets = try await selectedMarkets(appID: appID, countryCode: countryCode, device: device)
        let only = try await keywordFilter(keywords, in: markets)
        var countries: [String] = []
        var tracked: [String: [KeywordRecord]] = [:]
        for market in markets {
            for keyword in try await store.keywords(marketID: market.id) where only?.contains(keyword.normalized) ?? true {
                if tracked[market.countryCode] == nil { countries.append(market.countryCode) }
                tracked[market.countryCode, default: []].append(keyword)
            }
        }
        let genre = app.adsGenre.flatMap(AppleAdsGenre.init(rawValue:))
        let (start, end) = AppleAdsPopularityProvider.lastFullMonth(monthsBack: 1, now: now)
        var refreshes: [PopularityRefresh] = []
        for country in countries {
            let keywords = tracked[country] ?? []
            let terms = Array(Set(keywords.map(\.normalized))).sorted()
            let records: [PopularityRecord]
            if let genre {
                progress("\(country): the \(genre.displayName) list")
                records = try await popularity.popularity(terms: terms, country: country, genre: genre, monthsBack: 1)
            } else {
                records = try await Self.acrossGenres(terms: terms, country: country, provider: popularity, progress: progress)
            }
            let byTerm = Dictionary(records.map { (KeywordText.normalize($0.searchTerm), $0) }, uniquingKeysWith: Self.higher)
            var floor: Int?
            if keywords.contains(where: { byTerm[$0.normalized] == nil }) {
                let floorGenre = genre ?? Self.mostCommon(records.map(\.genre)) ?? .entertainment
                progress("\(country): the published range (\(floorGenre.displayName))")
                // Without the floor the terms are still below the range, only without a number to be under.
                floor = (try? await popularity.genreDataset(country: country, genre: floorGenre, monthsBack: 1))?.compactMap(\.popularity1to100).min()
            }
            var onList = 0
            for keyword in keywords {
                let reading: PopularityReading
                if let record = byTerm[keyword.normalized] {
                    reading = PopularityReading(fetchedAt: now, country: country, genre: record.genre.rawValue, periodStart: record.periodStart,
                                                periodEnd: record.periodEnd, popularity: record.popularity1to100, popularity1to5: record.popularity1to5,
                                                popularityInGenre: record.popularityInGenre, rankInGenre: record.rankInGenre, source: "list",
                                                upperBound: nil, anyGenre: genre == nil)
                    onList += 1
                } else {
                    reading = PopularityReading(fetchedAt: now, country: country, genre: genre?.rawValue, periodStart: start, periodEnd: end,
                                                popularity: nil, popularity1to5: nil, popularityInGenre: nil, rankInGenre: nil, source: "belowRange",
                                                upperBound: floor, anyGenre: genre == nil)
                }
                try await store.addPopularity(reading, keywordID: keyword.id)
            }
            let found = Set(byTerm.values.map(\.genre.displayName)).sorted()
            refreshes.append(PopularityRefresh(country: country, genre: genre?.rawValue, periodStart: start, periodEnd: end, keywords: keywords.count,
                                               onList: onList, belowRange: keywords.count - onList, floor: floor,
                                               genresFound: genre == nil ? found : []))
        }
        return refreshes
    }

    /// Every genre's list, keeping each term's highest score (Apple has no genre for some App Store categories).
    static func acrossGenres(terms: [String], country: String, provider: any PopularityProvider,
                             progress: @Sendable (String) -> Void) async throws -> [PopularityRecord] {
        var best: [String: PopularityRecord] = [:]
        for (index, genre) in AppleAdsGenre.allCases.enumerated() {
            progress("\(country): the \(genre.displayName) list (\(index + 1) of \(AppleAdsGenre.allCases.count))")
            for record in try await provider.popularity(terms: terms, country: country, genre: genre, monthsBack: 1) {
                let key = KeywordText.normalize(record.searchTerm)
                best[key] = best[key].map { higher($0, record) } ?? record
            }
        }
        return Array(best.values)
    }

    /// The record with the higher 1–100 score; the first on a tie.
    static func higher(_ a: PopularityRecord, _ b: PopularityRecord) -> PopularityRecord {
        (a.popularity1to100 ?? -1) >= (b.popularity1to100 ?? -1) ? a : b
    }

    /// The genre most terms were found in; ties go to the first in Apple's order (`max(by:)` keeps the first maximum).
    static func mostCommon(_ genres: [AppleAdsGenre]) -> AppleAdsGenre? {
        let counts = Dictionary(genres.map { ($0, 1) }, uniquingKeysWith: +)
        return AppleAdsGenre.allCases.filter { counts[$0] != nil }.max { counts[$0, default: 0] < counts[$1, default: 0] }
    }
}
