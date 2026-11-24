import Foundation
import ASOCore
import ASOProviders

/// The macOS app's "Try keywords in other countries": the app's keywords, and how locals search for the same need, tried
/// in other storefronts in one pass, so promising markets are tracked with their measurements instead of keyword by keyword.
extension Engine {
    /// One keyword in one storefront.
    public struct ExpansionRow: Sendable, Codable, Equatable {
        public let country: String
        public let term: String
        /// For a local-language form: the keyword it was derived from, and what it means.
        public let source: String?
        public let meaning: String?
        /// Position among `observed` results; absent when outside them or the search failed.
        public let rank: Int?
        public let observed: Int
        public let popularity: Int?
        /// "list" (Apple's country list) · "belowRange" (not on it, under `popularityBelow`) · "estimate" (the popularity model);
        /// absent without Apple Ads.
        public let popularitySource: String?
        public let popularityBelow: Int?
        /// For an estimate below the range: the model's 6–29 rank among floor terms; and its probability.
        public let popularitySubFloor: Int?
        public let popularityProbability: Double?
        public let difficulty: Double?
        public let titleMatches: Int?
        public let leader: String?
        public let leaderRatings: Int?
        /// Jev: probability that the phrase is in a language people search in that storefront.
        public let languageFit: Double?
        public let failed: Bool
        public let opportunity: Double?
        public let candidate: Bool
        /// Stored as a tracked keyword with its measurement.
        public let tracked: Bool
    }

    public struct ExpansionReport: Sendable, Codable, Equatable {
        /// Best opportunity first.
        public let rows: [ExpansionRow]
        public let countries: [String]
        public let keywords: Int
        public let candidates: Int
        public let tracked: Int
        /// What asking for local forms cost, summed per storefront.
        public let localizationCost: [String]
        /// Whether popularity (Apple Ads) and the language check (OpenRouter) could be read.
        public let appleAds: Bool
        public let languageChecked: Bool
    }

    /// One step: the country and what is being done there.
    public struct ExpansionStep: Sendable, Codable, Equatable {
        public let country: String
        public let step: String
        public let completed: Int
        public let total: Int
    }

    /// Tries `terms` (by default the source market's first 20 tracked keywords) in each of `countries` (by default the
    /// usual eight, without the source market's country). With `localize`, a storefront that speaks another language also
    /// gets the model's local search forms, which are measured like the rest. Each cell is searched (rank, difficulty),
    /// looked up in Apple's list (popularity) and checked for language fit. With `track`, every measured cell becomes a
    /// tracked keyword in its storefront (the market is created when missing) with the measurement and popularity stored,
    /// so nothing is measured twice.
    public func tryInOtherCountries(appID: Int, terms: [String]? = nil, sourceCountry: String? = nil, countries: [String]? = nil,
                                    device: DeviceContext = .iPhone, localize: Bool = true, track: Bool = false, depth: Int = 200,
                                    now: Date = Date(), progress: @Sendable (ExpansionStep) -> Void = { _ in }) async throws -> ExpansionReport {
        let app = try await app(appID)
        let existing = try await store.markets(appID: appID)
        let source = try sourceCountry.map { try Self.storefront($0).countryCode } ?? existing.first?.countryCode
        var words = terms ?? []
        if terms == nil, let source, let market = existing.first(where: { $0.countryCode == source }) {
            words = try await store.keywords(marketID: market.id).map(\.text).sorted().prefix(20).map { $0 }
        }
        words = Self.uniqueTerms(words)
        guard !words.isEmpty else {
            throw EngineError.invalidArgument("Give the keywords to try with --keywords, or track some in the source market first.")
        }
        let targets = try (countries ?? KeywordExpansion.defaultCountries.filter { $0 != source }).map { try Self.storefront($0) }
        guard !targets.isEmpty else { throw EngineError.invalidArgument("Give at least one other country.") }
        let sourceLanguage = source.flatMap(StorefrontRegistry.lookup).map { KeywordExpansion.language(of: $0.defaultLocale) } ?? "en"
        let adsOK = await popularity?.isConfigured ?? false
        let judgeOK = await judge?.isConfigured ?? false
        var estimateOK = false
        if adsOK { estimateOK = await canEstimate }
        var description = ""
        if localize, writer != nil {
            description = (try? await search.lookup(trackID: appID, storefront: try Self.storefront(source ?? "US")))?.storeDescription ?? ""
        }
        let genre = app.adsGenre.flatMap(AppleAdsGenre.init(rawValue:))
        let (start, end) = AppleAdsPopularityProvider.lastFullMonth(monthsBack: 1, now: now)

        var rows: [ExpansionRow] = []
        var costs: [String] = []
        var completed = 0
        var total = words.count * targets.count
        for storefront in targets {
            try Task.checkCancellation()
            let country = storefront.countryCode
            var cells = words.map { (term: $0, form: KeywordExpansion.LocalForm?.none) }
            // Local-language forms when the store speaks another language: the model proposes, the measurements decide.
            if localize, let writer, KeywordExpansion.language(of: storefront.defaultLocale) != sourceLanguage {
                progress(ExpansionStep(country: country, step: "local search forms (AI)", completed: completed, total: total))
                if let local = try? await KeywordExpansion.localForms(of: words, appName: app.name, description: description,
                                                                     storefront: storefront, model: writer) {
                    cells += local.forms.map { (term: $0.term, form: Optional($0)) }
                    total += local.forms.count
                    if let cost = local.cost { costs.append("\(country) \(cost)") }
                }
            }
            var listed: [String: PopularityRecord] = [:]
            var floor: Int?
            if adsOK, let popularity {
                progress(ExpansionStep(country: country, step: "Apple Ads lists", completed: completed, total: total))
                let terms = cells.map { KeywordText.normalize($0.term) }
                var records: [PopularityRecord] = []
                if let genre {
                    records = (try? await popularity.popularity(terms: terms, country: country, genre: genre, monthsBack: 1)) ?? []
                } else {
                    records = (try? await Self.acrossGenres(terms: terms, country: country, provider: popularity, progress: { _ in })) ?? []
                }
                listed = Dictionary(records.map { (KeywordText.normalize($0.searchTerm), $0) }, uniquingKeysWith: Self.higher)
                if terms.contains(where: { listed[$0] == nil }) {
                    let floorGenre = genre ?? Self.mostCommon(records.map(\.genre)) ?? .entertainment
                    floor = (try? await popularity.genreDataset(country: country, genre: floorGenre, monthsBack: 1))?.compactMap(\.popularity1to100).min()
                }
            }
            for cell in cells {
                try Task.checkCancellation()
                progress(ExpansionStep(country: country, step: "“\(cell.term)”", completed: completed, total: total))
                let sample = await RankSample.measure(keyword: cell.term, storefront: storefront, device: device, ownTrackID: appID, depth: depth, provider: search)
                let record = listed[KeywordText.normalize(cell.term)]
                var fit: Double?
                if judgeOK, let judged = try? await judge?.classify(term: cell.term, storefront: country, storeLanguage: storefront.defaultLocale.displayName),
                   judged.languageFit >= 0 {
                    fit = judged.languageFit
                }
                let failed: Bool
                if case .requestFailed = sample.outcome { failed = true } else { failed = false }
                let signals = failed ? nil : CompetitionSignals(results: Array(sample.results.prefix(50)), term: cell.term)
                // Popularity: Apple's list, else the model's estimate (with these results), else below the range.
                var reading: PopularityReading?
                if adsOK {
                    if let r = record {
                        reading = PopularityReading(fetchedAt: now, country: country, genre: r.genre.rawValue, periodStart: r.periodStart, periodEnd: r.periodEnd,
                                                    popularity: r.popularity1to100, popularity1to5: r.popularity1to5, popularityInGenre: r.popularityInGenre,
                                                    rankInGenre: r.rankInGenre, source: "list", upperBound: nil, anyGenre: genre == nil)
                    } else if estimateOK,
                              let estimate = try await estimates([EstimateRequest(term: cell.term, results: failed ? nil : sample.results)],
                                                                 storefront: storefront)[KeywordText.normalize(cell.term)] {
                        reading = estimateReading(estimate, country: country, genre: genre?.rawValue, start: start, end: end, floor: floor,
                                                  anyGenre: genre == nil, now: now)
                    } else {
                        reading = PopularityReading(fetchedAt: now, country: country, genre: genre?.rawValue, periodStart: start, periodEnd: end, popularity: nil,
                                                    popularity1to5: nil, popularityInGenre: nil, rankInGenre: nil, source: "belowRange", upperBound: floor,
                                                    anyGenre: genre == nil)
                    }
                }
                var tracked = false
                if track, !failed {
                    let market = try await store.market(appID: appID, countryCode: country, device: device)
                    _ = try await store.addKeywords([cell.term], marketID: market.id)
                    if let keyword = try await store.keyword(cell.term, marketID: market.id) {
                        try await store.addObservation(sample, keywordID: keyword.id)
                        if let form = cell.form, keyword.note.isEmpty {
                            _ = try await store.setNote("local form of “\(form.source)”" + (form.meaning.isEmpty ? "" : " · \(form.meaning)"), keywordID: keyword.id)
                        }
                        if let reading { try await store.addPopularity(reading, keywordID: keyword.id) }
                        tracked = true
                    }
                }
                let difficulty = signals?.difficulty?.score
                let value = reading?.popularity
                rows.append(ExpansionRow(country: country, term: cell.term, source: cell.form?.source, meaning: cell.form?.meaning, rank: sample.outcome.position,
                                         observed: sample.results.count, popularity: value, popularitySource: reading?.source,
                                         popularityBelow: reading?.upperBound, popularitySubFloor: reading?.subFloor,
                                         popularityProbability: reading?.probability, difficulty: difficulty, titleMatches: signals?.titleMatchesTop10,
                                         leader: sample.results.first?.name, leaderRatings: sample.results.first?.ratingCount, languageFit: fit, failed: failed,
                                         opportunity: KeywordExpansion.opportunity(popularity: value, difficulty: difficulty),
                                         candidate: KeywordExpansion.isCandidate(popularity: value, rank: sample.outcome.position, difficulty: difficulty,
                                                                                 languageFit: fit),
                                         tracked: tracked))
                completed += 1
            }
        }
        let ordered = rows.sorted { ($0.opportunity ?? -1) > ($1.opportunity ?? -1) }
        return ExpansionReport(rows: ordered, countries: targets.map(\.countryCode), keywords: words.count, candidates: rows.filter(\.candidate).count,
                               tracked: rows.filter(\.tracked).count, localizationCost: costs, appleAds: adsOK, languageChecked: judgeOK)
    }

    /// Trimmed, without empties or repeats (by normalized text), in the given order.
    static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert(KeywordText.normalize($0)).inserted }
    }
}
