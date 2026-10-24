import Foundation
import Observation
import SwiftData
import ASOCore
import ASOProviders

/// Finds keyword candidates (from a competitor listing or around your own seeds), attaches Apple
/// popularity, Jev judgements and measured difficulty, and marks the "golden" ones.
@Observable
final class KeywordDiscovery {
    struct Candidate: Identifiable, Hashable {
        var id: String { normalized }
        let term: String
        let normalized: String
        var sources: Set<String>
        var popularity: Int?
        /// "list" · "index" · "bound"
        var popularityScope: String?
        var upperBound: Int?
        var genre: String?
        var jevBrand: Double?
        var jevNatural: Double?
        var jevIntent: String?
        /// Probability the searcher wants an app like this one (Jev, against the app's description).
        var jevFit: Double?
        var difficulty: DifficultyScore?
        var alreadyTracked = false

        var opportunity: Double? {
            guard let p = popularity, let d = difficulty else { return nil }
            return Double(p) * (1 - pow(d.score / 100, 2))
        }
        func passesNumbers(minPopularity: Int, maxDifficulty: Int) -> Bool {
            guard let p = popularity, p >= minPopularity, let d = difficulty, d.score <= Double(maxDifficulty) else { return false }
            return (jevBrand ?? 0) < 0.5
        }
        /// Golden for this app: numbers pass and the term fits what the app does.
        func golden(minPopularity: Int, maxDifficulty: Int) -> Bool {
            passesNumbers(minPopularity: minPopularity, maxDifficulty: maxDifficulty) && (jevFit ?? 1) >= 0.5
        }
        /// Numbers pass but the term is unrelated to this app, a lead for another app.
        func goldenLead(minPopularity: Int, maxDifficulty: Int) -> Bool {
            passesNumbers(minPopularity: minPopularity, maxDifficulty: maxDifficulty) && (jevFit ?? 1) < 0.5
        }
    }

    struct Progress: Equatable { var step = ""; var completed = 0; var total = 0; var isRunning = false }
    private(set) var progress = Progress()
    private(set) var lastMessage: String?

    private let search: ITunesSearchProvider
    private let hints: AppStoreHintsProvider
    private let popularity: AppleAdsPopularityProvider
    private let session: AppleAdsSessionService
    private let jev: JevClient
    private let settings: AppSettings

    init(search: ITunesSearchProvider, hints: AppStoreHintsProvider, popularity: AppleAdsPopularityProvider, session: AppleAdsSessionService, jev: JevClient, settings: AppSettings) {
        self.search = search
        self.hints = hints
        self.popularity = popularity
        self.session = session
        self.jev = jev
        self.settings = settings
    }

    // MARK: Candidate generation

    /// Words and two-word phrases from a listing text, filler removed (the rule lives in ASOCore).
    static func phrases(from text: String, maxUnigrams: Int = 60, maxBigrams: Int = 60) -> [String] {
        KeywordPhrases.from(text, maxUnigrams: maxUnigrams, maxBigrams: maxBigrams)
    }

    /// Runs the whole discovery. `competitor` adds its title/description phrases; `seeds` are expanded with autocomplete and Apple Ads suggestions.
    func discover(competitor: SearchResultApp?, seeds: [String], app: TrackedApp, market: TrackedMarket, hintSeedLimit: Int, difficultyLimit: Int) async -> [Candidate] {
        guard let sf = market.storefront else { return [] }
        progress = Progress(step: "Collecting candidates", isRunning: true)
        defer { progress.isRunning = false }
        var byKey: [String: Candidate] = [:]
        func add(_ term: String, _ source: String) {
            let n = TrackedKeyword.normalize(term)
            guard n.count >= 3, n.count <= 40 else { return }
            if byKey[n] == nil { byKey[n] = Candidate(term: n, normalized: n, sources: [source]) } else { byKey[n]!.sources.insert(source) }
        }

        // 1. Competitor listing text.
        if let c = competitor {
            for p in Self.phrases(from: c.name, maxUnigrams: 12, maxBigrams: 12) { add(p, "competitor title") }
            var description = c.storeDescription
            if description == nil, let fresh = try? await search.lookup(trackID: c.trackID, storefront: sf) { description = fresh.storeDescription }
            for p in Self.phrases(from: description ?? "", maxUnigrams: 40, maxBigrams: 40) { add(p, "competitor description") }
        }
        // 2. Autocomplete around the seeds (public, paced).
        let seedList = Array(Set(seeds.map { TrackedKeyword.normalize($0) }).filter { !$0.isEmpty }).prefix(hintSeedLimit)
        progress.total = seedList.count
        for (i, seed) in seedList.enumerated() {
            progress.step = "Autocomplete “\(seed)”"; progress.completed = i
            if let s = try? await hints.suggestions(seed: seed, storefront: sf) { for h in s { add(h.text, "autocomplete") } }
        }
        // 3. Apple Ads suggestions seeded with the same words (needs the API; skipped when not connected).
        if await popularity.isConfigured {
            for seed in seedList.prefix(6) {
                progress.step = "Apple Ads suggestions “\(seed)”"
                if let rows = try? await popularity.keywordSuggestions(appID: app.trackID, seeds: [seed], country: market.countryCode, pageSize: 100) {
                    for r in rows { add(r.text, "ads suggestion") }
                }
            }
        }
        let tracked = Set(market.keywords.map(\.normalized))
        for k in byKey.keys { byKey[k]!.alreadyTracked = tracked.contains(k) }

        // 4. Popularity: country lists (term filter), then the dashboard index when signed in.
        var candidates = Array(byKey.values)
        if await popularity.isConfigured, !candidates.isEmpty {
            progress.step = "Apple popularity lists"
            let terms = candidates.map(\.term)
            let records: [PopularityRecord]
            if let g = app.adsGenre { records = (try? await popularity.popularity(terms: terms, country: market.countryCode, genre: g, monthsBack: 1)) ?? [] }
            else { records = (try? await popularity.popularityAcrossGenres(terms: terms, country: market.countryCode, monthsBack: 1)) ?? [] }
            let byTerm = Dictionary(grouping: records, by: { $0.searchTerm.lowercased() })
            for i in candidates.indices {
                if let r = byTerm[candidates[i].normalized]?.first { candidates[i].popularity = r.popularity1to100; candidates[i].popularityScope = "list"; candidates[i].genre = r.genre.displayName }
            }
        }
        if session.state.isSignedIn {
            let missing = candidates.filter { $0.popularity == nil }.map(\.term)
            if !missing.isEmpty {
                progress.step = "Apple Ads dashboard index"
                if session.referenceAdamID.isEmpty { session.referenceAdamID = String(app.trackID) }
                let index = (try? await session.popularity(terms: missing, storefront: market.countryCode)) ?? [:]
                for i in candidates.indices where candidates[i].popularity == nil {
                    if let v = index[candidates[i].normalized] { candidates[i].popularity = v; candidates[i].popularityScope = "index" }
                }
            }
        }
        for i in candidates.indices where candidates[i].popularity == nil { candidates[i].popularityScope = "bound"; candidates[i].upperBound = 40 }

        // 5. Jev: drop other brands and unnatural phrases (cheap, concurrent).
        if await jev.isConfigured {
            progress.step = "Jev: brand and naturalness"
            let lang = sf.defaultLocale.displayName
            let country = market.countryCode
            for batch in stride(from: 0, to: candidates.count, by: 8).map({ Array($0..<min($0 + 8, candidates.count)) }) {
                let results: [(Int, JevFeatures?)] = await withTaskGroup(of: (Int, JevFeatures?).self) { g in
                    for i in batch {
                        let term = candidates[i].term
                        g.addTask { [jev] in (i, try? await jev.classify(term: term, storefront: country, storeLanguage: lang)) }
                    }
                    var out: [(Int, JevFeatures?)] = []
                    for await r in g { out.append(r) }
                    return out
                }
                for (i, f) in results { if let f { candidates[i].jevBrand = f.brand; candidates[i].jevNatural = f.naturalQuery; candidates[i].jevIntent = f.intent } }
            }
        }

        // 5b. Fit against the app's own description, for every candidate that could still become golden.
        if await jev.isConfigured {
            if app.storeDescription == nil, let a = try? await search.lookup(trackID: app.trackID, storefront: sf) { app.storeDescription = a.storeDescription ?? "" }
            let name = app.name
            let description = (app.storeDescription?.isEmpty == false ? app.storeDescription! : "\(app.name). \(app.primaryGenre ?? "")")
            let lang = sf.defaultLocale.displayName
            let country = market.countryCode
            let fitIdx = candidates.indices.filter { ($0 < candidates.count) && (candidates[$0].jevBrand ?? 0) < 0.5 && (candidates[$0].jevNatural ?? 1) >= 0.4 && (candidates[$0].popularity ?? 0) >= settings.goldenMinPopularity }
            progress.step = "Jev: fit against the app (\(fitIdx.count))"
            for batch in stride(from: 0, to: fitIdx.count, by: 8).map({ Array(fitIdx[$0..<min($0 + 8, fitIdx.count)]) }) {
                let results: [(Int, Double?)] = await withTaskGroup(of: (Int, Double?).self) { g in
                    for i in batch {
                        let term = candidates[i].term
                        g.addTask { [jev] in (i, try? await jev.fit(term: term, appName: name, appDescription: description, storefront: country, storeLanguage: lang)) }
                    }
                    var out: [(Int, Double?)] = []
                    for await r in g { out.append(r) }
                    return out
                }
                for (i, f) in results { candidates[i].jevFit = f }
            }
        }

        // 6. Difficulty for the most promising ones (public search, 3 s each).
        let ranked = candidates.sorted { ($0.popularity ?? -1) > ($1.popularity ?? -1) }
        // Brands and unnatural phrases are never golden, so the 3-second difficulty budget goes to real candidates.
        let toMeasure = ranked.filter { !$0.alreadyTracked && ($0.jevBrand ?? 0) < 0.5 && ($0.jevNatural ?? 1) >= 0.4 && ($0.popularity ?? 0) >= settings.goldenMinPopularity }.prefix(difficultyLimit)
        progress.total = toMeasure.count
        var difficulty: [String: DifficultyScore] = [:]
        for (i, c) in toMeasure.enumerated() {
            progress.step = "Difficulty “\(c.term)”"; progress.completed = i
            if let results = try? await search.search(term: c.term, storefront: sf, device: market.device, limit: 50), let d = DifficultyScore(results: results, term: c.term) {
                difficulty[c.normalized] = d
            }
        }
        for i in candidates.indices { candidates[i].difficulty = difficulty[candidates[i].normalized] }
        let golden = candidates.filter { $0.golden(minPopularity: settings.goldenMinPopularity, maxDifficulty: settings.goldenMaxDifficulty) }.count
        lastMessage = "\(candidates.count) candidates · \(candidates.filter { $0.popularity != nil }.count) with an Apple popularity value · \(difficulty.count) measured for difficulty · \(golden) golden."
        return candidates.sorted {
            let g0 = $0.golden(minPopularity: settings.goldenMinPopularity, maxDifficulty: settings.goldenMaxDifficulty)
            let g1 = $1.golden(minPopularity: settings.goldenMinPopularity, maxDifficulty: settings.goldenMaxDifficulty)
            if g0 != g1 { return g0 }
            if let o0 = $0.opportunity, let o1 = $1.opportunity, o0 != o1 { return o0 > o1 }
            if ($0.opportunity == nil) != ($1.opportunity == nil) { return $0.opportunity != nil }
            return ($0.popularity ?? -1) > ($1.popularity ?? -1)
        }
    }
}
