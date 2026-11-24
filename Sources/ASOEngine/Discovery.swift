import Foundation
import ASOCore

/// One keyword candidate from discovery. Absent values were not looked up (no key, or not among the most promising).
public struct DiscoveryCandidate: Sendable, Codable, Equatable {
    public let keyword: String
    /// "competitor title" · "competitor description" · "autocomplete" · "ads suggestion"
    public internal(set) var sources: [String]
    /// Apple's 1–100 score from the country list.
    public internal(set) var popularity: Int?
    /// "list" · "belowRange" (not on Apple's list) · absent without Apple Ads.
    public internal(set) var popularitySource: String?
    public internal(set) var popularityGenre: String?
    /// Jev: probability the term is a brand, that a person would type it, and what kind of search it is.
    public internal(set) var brand: Double?
    public internal(set) var natural: Double?
    public internal(set) var intent: String?
    /// Jev: probability that someone searching it wants an app like this one.
    public internal(set) var fit: Double?
    public internal(set) var difficulty: Double?
    public internal(set) var difficultyTier: String?
    public internal(set) var opportunity: Double?
    /// Already tracked in the market.
    public internal(set) var tracked = false
    public internal(set) var golden = false
    /// The numbers pass but the term does not fit this app: a lead for another app, not a keyword for this one.
    public internal(set) var goldenLead = false

    init(keyword: String, source: String) {
        self.keyword = keyword
        sources = [source]
    }

    /// Demand, competition and brand checks pass (the macOS discovery's rule).
    func passesNumbers(_ thresholds: GoldenThresholds) -> Bool {
        guard let p = popularity, p >= thresholds.minPopularity, let d = difficulty, d <= Double(thresholds.maxDifficulty) else { return false }
        return (brand ?? 0) < 0.5
    }

    /// Worth a fit check and a difficulty search: not a brand, natural, and popular enough to become golden.
    func isPromising(_ thresholds: GoldenThresholds) -> Bool {
        (brand ?? 0) < 0.5 && (natural ?? 1) >= 0.4 && (popularity ?? 0) >= thresholds.minPopularity
    }
}

extension Engine {
    public struct DiscoveryReport: Sendable, Codable, Equatable {
        public let market: String
        /// The competitor whose listing was mined, when one was given.
        public let competitor: String?
        public let seeds: [String]
        /// Which keyed sources took part.
        public let appleAds: Bool
        public let jev: Bool
        public let withPopularity: Int
        public let measured: Int
        public let golden: Int
        /// Golden first, then by opportunity, then by popularity.
        public let candidates: [DiscoveryCandidate]
    }

    public struct DiscoveryProgress: Sendable, Equatable {
        public let step: String
        public let completed: Int
        public let total: Int
    }

    /// The macOS app's keyword discovery, nothing stored: candidates from a competitor's title and description (when
    /// `competitorID` is given) and from App Store autocomplete and Apple Ads suggestions around the seeds; Apple
    /// popularity from the country lists; Jev drops other brands and unnatural phrases and judges the fit; the most
    /// promising `difficultyLimit` are searched for difficulty (about 3 seconds each). Seeds default to the market's
    /// most popular tracked keywords and the app's title words, or the competitor's title words. Apple Ads and Jev
    /// are skipped when their keys are not stored, and a failed lookup leaves its values out.
    public func discover(appID: Int, countryCode: String, device: DeviceContext = .iPhone, competitorID: Int? = nil, seeds: [String]? = nil,
                         difficultyLimit: Int = 25, golden thresholds: GoldenThresholds = .standard,
                         progress: @Sendable (DiscoveryProgress) -> Void = { _ in }) async throws -> DiscoveryReport {
        let app = try await app(appID)
        let market = try await existingMarket(appID: appID, countryCode: countryCode, device: device)
        let storefront = try Self.storefront(market.countryCode)
        var competitor: SearchResultApp?
        if let competitorID {
            guard let found = try await search.lookup(trackID: competitorID, storefront: storefront) else {
                throw EngineError.notFound("No app with ID \(competitorID) in the \(storefront.name) App Store.")
            }
            competitor = found
        }
        let seedList = try await discoverySeeds(seeds, competitor: competitor, app: app, market: market)
        let adsOn = await popularity?.isConfigured ?? false
        let jevOn = await judge?.isConfigured ?? false

        var candidates = Candidates()
        // 1. The competitor's listing text.
        if let competitor {
            for phrase in KeywordPhrases.from(competitor.name, maxUnigrams: 12, maxBigrams: 12) { candidates.add(phrase, "competitor title") }
            for phrase in KeywordPhrases.from(competitor.storeDescription ?? "", maxUnigrams: 40, maxBigrams: 40) {
                candidates.add(phrase, "competitor description")
            }
        }
        // 2. Autocomplete around the seeds (public, paced).
        for (i, seed) in seedList.enumerated() {
            try Task.checkCancellation()
            progress(DiscoveryProgress(step: "Autocomplete \"\(seed)\"", completed: i, total: seedList.count))
            for hint in (try? await suggestions.suggestions(seed: seed, storefront: storefront)) ?? [] { candidates.add(hint.text, "autocomplete") }
        }
        // 3. Apple Ads suggestions for the first six seeds.
        if adsOn, let popularity {
            for seed in seedList.prefix(6) {
                progress(DiscoveryProgress(step: "Apple Ads suggestions \"\(seed)\"", completed: 0, total: 0))
                let rows = (try? await popularity.keywordSuggestions(appID: app.trackID, seeds: [seed], country: market.countryCode)) ?? []
                for row in rows { candidates.add(row.text, "ads suggestion") }
            }
        }
        let tracked = Set(try await store.keywords(marketID: market.id).map(\.normalized))
        var list = candidates.all
        for i in list.indices { list[i].tracked = tracked.contains(list[i].keyword) }

        // 4. Popularity from the country lists; a term not on them is below the published range.
        if adsOn, let popularity, !list.isEmpty {
            progress(DiscoveryProgress(step: "Apple popularity lists", completed: 0, total: 0))
            let terms = list.map(\.keyword)
            let records: [PopularityRecord]
            if let genre = app.adsGenre.flatMap(AppleAdsGenre.init(rawValue:)) {
                records = (try? await popularity.popularity(terms: terms, country: market.countryCode, genre: genre, monthsBack: 1)) ?? []
            } else {
                records = (try? await Self.acrossGenres(terms: terms, country: market.countryCode, provider: popularity) { _ in }) ?? []
            }
            let byTerm = Dictionary(records.map { (KeywordText.normalize($0.searchTerm), $0) }, uniquingKeysWith: Self.higher)
            for i in list.indices {
                if let record = byTerm[list[i].keyword] {
                    list[i].popularity = record.popularity1to100
                    list[i].popularitySource = "list"
                    list[i].popularityGenre = record.genre.rawValue
                } else {
                    list[i].popularitySource = "belowRange"
                }
            }
        }

        // 5. Jev: brand and naturalness for every candidate, then the fit of the promising ones.
        if jevOn, let judge {
            let country = market.countryCode
            let language = storefront.defaultLocale.displayName
            progress(DiscoveryProgress(step: "Jev: brand and naturalness", completed: 0, total: list.count))
            let features = await Self.concurrently(list.map(\.keyword)) { term in
                try? await judge.classify(term: term, storefront: country, storeLanguage: language)
            }
            for i in list.indices {
                guard let f = features[i] else { continue }
                list[i].brand = f.brand >= 0 ? f.brand : nil
                list[i].natural = f.naturalQuery >= 0 ? f.naturalQuery : nil
                list[i].intent = f.intent.isEmpty ? nil : f.intent
            }
            let promising = list.indices.filter { list[$0].isPromising(thresholds) }
            if !promising.isEmpty {
                let own = try? await search.lookup(trackID: app.trackID, storefront: storefront)
                let description = own?.storeDescription.flatMap { $0.isEmpty ? nil : $0 } ?? "\(app.name). \(app.primaryGenre ?? "")"
                let name = app.name
                progress(DiscoveryProgress(step: "Jev: fit against the app (\(promising.count))", completed: 0, total: promising.count))
                let fits = await Self.concurrently(promising.map { list[$0].keyword }) { term in
                    try? await judge.fit(term: term, appName: name, appDescription: description, storefront: country, storeLanguage: language)
                }
                for (i, fit) in zip(promising, fits) { list[i].fit = fit }
            }
        }

        // 6. Difficulty for the most promising untracked ones (public search, paced).
        let toMeasure = list.indices.filter { !list[$0].tracked && list[$0].isPromising(thresholds) }
            .sorted { (list[$0].popularity ?? -1) > (list[$1].popularity ?? -1) }.prefix(max(0, difficultyLimit))
        var measured = 0
        for (step, i) in toMeasure.enumerated() {
            try Task.checkCancellation()
            progress(DiscoveryProgress(step: "Difficulty \"\(list[i].keyword)\"", completed: step, total: toMeasure.count))
            guard let results = try? await search.search(term: list[i].keyword, storefront: storefront, device: market.device, limit: 50),
                  let score = DifficultyScore(results: results, term: list[i].keyword) else { continue }
            list[i].difficulty = score.score
            list[i].difficultyTier = score.tier
            measured += 1
        }
        for i in list.indices {
            if let p = list[i].popularity, let d = list[i].difficulty { list[i].opportunity = Opportunity.score(popularity: p, difficulty: d) }
            let passes = list[i].passesNumbers(thresholds)
            list[i].golden = passes && (list[i].fit ?? 1) >= 0.5
            list[i].goldenLead = passes && (list[i].fit ?? 1) < 0.5
        }
        list.sort(by: Self.discoveryOrder)
        return DiscoveryReport(market: Self.title(market), competitor: competitor?.name, seeds: seedList, appleAds: adsOn, jev: jevOn,
                               withPopularity: list.filter { $0.popularity != nil }.count, measured: measured,
                               golden: list.filter(\.golden).count, candidates: list)
    }

    /// The seeds given, else the competitor's title words, else the market's most popular tracked keywords and the
    /// app's title words; at most eight, normalized, without repeats.
    private func discoverySeeds(_ given: [String]?, competitor: SearchResultApp?, app: AppRecord, market: MarketRecord) async throws -> [String] {
        var raw: [String]
        if let given {
            raw = given
        } else if let competitor {
            raw = KeywordPhrases.from(competitor.name, maxUnigrams: 4, maxBigrams: 2)
        } else {
            var scored: [(String, Int)] = []
            for keyword in try await store.keywords(marketID: market.id) {
                scored.append((keyword.text, try await store.latestPopularity(keywordID: keyword.id)?.popularity ?? -1))
            }
            raw = scored.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
                + KeywordPhrases.from(app.name, maxUnigrams: 4, maxBigrams: 2)
        }
        var seen = Set<String>()
        let seeds = raw.map(KeywordText.normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !seeds.isEmpty else { throw EngineError.invalidArgument("Give at least one seed keyword.") }
        return Array(seeds.prefix(8))
    }

    /// Golden first, then the higher opportunity (known before unknown), then the higher popularity, then alphabetical.
    static func discoveryOrder(_ a: DiscoveryCandidate, _ b: DiscoveryCandidate) -> Bool {
        if a.golden != b.golden { return a.golden }
        switch (a.opportunity, b.opportunity) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if (a.popularity ?? -1) != (b.popularity ?? -1) { return (a.popularity ?? -1) > (b.popularity ?? -1) }
        return a.keyword < b.keyword
    }

    /// Runs `work` for every term, eight at a time, keeping the order of `terms`.
    static func concurrently<T: Sendable>(_ terms: [String], _ work: @escaping @Sendable (String) async -> T?) async -> [T?] {
        var out = [T?](repeating: nil, count: terms.count)
        for start in stride(from: 0, to: terms.count, by: 8) {
            let batch = Array(start..<min(start + 8, terms.count))
            await withTaskGroup(of: (Int, T?).self) { group in
                for i in batch { group.addTask { (i, await work(terms[i])) } }
                for await (i, value) in group { out[i] = value }
            }
        }
        return out
    }
}

/// Candidates by normalized text, in the order they were first found, each with every source that produced it.
private struct Candidates {
    private var order: [String] = []
    private var byKey: [String: DiscoveryCandidate] = [:]

    /// Three to forty characters, as in the macOS app.
    mutating func add(_ term: String, _ source: String) {
        let key = KeywordText.normalize(term)
        guard (3...40).contains(key.count) else { return }
        if var existing = byKey[key] {
            if !existing.sources.contains(source) { existing.sources.append(source) }
            byKey[key] = existing
        } else {
            order.append(key)
            byKey[key] = DiscoveryCandidate(keyword: key, source: source)
        }
    }

    var all: [DiscoveryCandidate] { order.compactMap { byKey[$0] } }
}
