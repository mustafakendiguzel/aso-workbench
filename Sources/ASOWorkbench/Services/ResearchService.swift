import Foundation
import Observation
import SwiftData
import ASOCore
import ASOProviders

/// Keyword discovery: public autocomplete always; Apple Ads suggestions and
/// official popularity when the account is connected. Sources stay separate.
@Observable
final class ResearchService {
    private let hints: AppStoreHintsProvider
    private let popularity: AppleAdsPopularityProvider
    private let session: AppleAdsSessionService
    private let jev: JevClient
    let models: EstimatorHolder

    struct SuggestionSet {
        var publicHints: [KeywordSuggestion] = []
        var appleAds: [KeywordSuggestion] = []
        var appleAdsError: String?
        var publicError: String?
    }

    private(set) var isLoadingSuggestions = false
    private(set) var isLoadingPopularity = false
    /// Keywords whose popularity is being fetched right now (drives the per-cell spinner).
    private(set) var loadingKeywordIDs: Set<PersistentIdentifier> = []
    private(set) var popularityProgress: String?
    private(set) var lastPopularityMessage: String?

    private let search: ITunesSearchProvider

    init(search: ITunesSearchProvider, hints: AppStoreHintsProvider, popularity: AppleAdsPopularityProvider, session: AppleAdsSessionService, jev: JevClient, models: EstimatorHolder) {
        self.search = search
        self.hints = hints
        self.popularity = popularity
        self.session = session
        self.jev = jev
        self.models = models
    }

    func suggestions(seed: String, storefront: Storefront, app: TrackedApp?) async -> SuggestionSet {
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }
        var set = SuggestionSet()
        do {
            set.publicHints = try await hints.suggestions(seed: seed, storefront: storefront)
        } catch {
            set.publicError = error.localizedDescription
        }
        if await popularity.isConfigured, let app {
            do {
                set.appleAds = try await popularity.keywordSuggestions(appID: app.trackID, seeds: [seed], country: storefront.countryCode)
            } catch {
                set.appleAdsError = error.localizedDescription
            }
        }
        return set
    }

    /// Refreshes official popularity for every keyword of a market. Terms Apple has no
    /// record for get an explicit "no record" observation.
    /// Session cache of the lowest published score per country/genre/month (the "published range" floor).
    private var floorCache: [String: Int] = [:]

    /// Loads the app's public store description once (the reference text for keyword fit).
    func ensureDescription(app: TrackedApp, storefront: Storefront) async {
        guard app.storeDescription == nil else { return }
        if let a = try? await search.lookup(trackID: app.trackID, storefront: storefront) { app.storeDescription = a.storeDescription ?? "" }
    }

    /// Jev brand/intent and app fit for tracked keywords that lack them (cheap; both feed the golden rule).
    func classifyKeywords(_ keywords: [TrackedKeyword], app: TrackedApp, storefront: Storefront, context: ModelContext, forceFit: Bool = false) async {
        guard await jev.isConfigured else { return }
        let lang = storefront.defaultLocale.displayName
        let country = storefront.countryCode
        let todo = keywords.filter { $0.brandProbability == nil }
        if !todo.isEmpty {
            popularityProgress = "Jev · brand check for \(todo.count) keyword(s)"
            for batch in stride(from: 0, to: todo.count, by: 8).map({ Array(todo[$0..<min($0 + 8, todo.count)]) }) {
                let inputs = batch.map(\.text)
                let results: [JevFeatures?] = await withTaskGroup(of: (Int, JevFeatures?).self) { g in
                    for (i, term) in inputs.enumerated() { g.addTask { [jev] in (i, try? await jev.classify(term: term, storefront: country, storeLanguage: lang)) } }
                    var out = Array(repeating: JevFeatures?.none, count: inputs.count)
                    for await (i, f) in g { out[i] = f }
                    return out
                }
                for (k, f) in zip(batch, results) { if let f { k.brandProbability = f.brand; k.intent = f.intent } }
            }
        }
        // Names Jev does not know ("solides" → Sólides) are caught by showing it the actual top results.
        let navTodo = keywords.filter { ($0.navigational == nil || forceFit) && !($0.latestMeasured?.results.isEmpty ?? true) }
        if !navTodo.isEmpty {
            popularityProgress = "Jev · navigational check for \(navTodo.count) keyword(s)"
            for batch in stride(from: 0, to: navTodo.count, by: 8).map({ Array(navTodo[$0..<min($0 + 8, navTodo.count)]) }) {
                let inputs = batch.map { ($0.text, $0.latestMeasured?.results.prefix(5).map(\.name) ?? []) }
                let results: [Double?] = await withTaskGroup(of: (Int, Double?).self) { g in
                    for (i, input) in inputs.enumerated() { g.addTask { [jev] in (i, try? await jev.navigational(term: input.0, topResults: input.1, storefront: country, storeLanguage: lang)) } }
                    var out = Array(repeating: Double?.none, count: inputs.count)
                    for await (i, f) in g { out[i] = f }
                    return out
                }
                for (k, f) in zip(batch, results) { if let f { k.navigational = f } }
            }
        }
        let fitTodo = keywords.filter { forceFit || $0.fitProbability == nil }
        if !fitTodo.isEmpty {
            await ensureDescription(app: app, storefront: storefront)
            let name = app.name
            let description = (app.storeDescription?.isEmpty == false ? app.storeDescription! : "\(app.name). \(app.primaryGenre ?? "")")
            popularityProgress = "Jev · fit check for \(fitTodo.count) keyword(s)"
            for batch in stride(from: 0, to: fitTodo.count, by: 8).map({ Array(fitTodo[$0..<min($0 + 8, fitTodo.count)]) }) {
                let inputs = batch.map(\.text)
                let results: [Double?] = await withTaskGroup(of: (Int, Double?).self) { g in
                    for (i, term) in inputs.enumerated() { g.addTask { [jev] in (i, try? await jev.fit(term: term, appName: name, appDescription: description, storefront: country, storeLanguage: lang)) } }
                    var out = Array(repeating: Double?.none, count: inputs.count)
                    for await (i, f) in g { out[i] = f }
                    return out
                }
                for (k, f) in zip(batch, results) { if let f { k.fitProbability = f } }
            }
        }
        try? context.save()
    }

    /// Popularity in three layers, all from Apple data:
    ///  1. the country list (search-term-popularity insight; genre set on the app, or all 15),
    ///  2. the Apple Ads dashboard index for the exact term (5–100, per storefront) when the browser session is signed in,
    ///  3. otherwise the term is below the published range: stored as an upper bound (the list's lowest score).
    /// Keyword-suggestion scores are deliberately not used here: the same term gets different values depending on the seed.
    func refreshPopularity(for market: TrackedMarket, only subset: Set<PersistentIdentifier>? = nil, context: ModelContext) async {
        guard let app = market.app else { return }
        guard await popularity.isConfigured else {
            lastPopularityMessage = "Apple Ads is not connected (sidebar → Connections)."
            return
        }
        let keywords = market.keywords.filter { subset?.contains($0.persistentModelID) ?? true }
        guard !isLoadingPopularity, !keywords.isEmpty else { return }
        isLoadingPopularity = true
        loadingKeywordIDs = Set(keywords.map(\.persistentModelID))
        defer { isLoadingPopularity = false; loadingKeywordIDs = []; popularityProgress = nil }
        let terms = keywords.map(\.text)
        let genre = app.adsGenre
        let (start, end) = AppleAdsPopularityProvider.lastFullMonth(monthsBack: 1)
        if let sf = market.storefront { await classifyKeywords(keywords, app: app, storefront: sf, context: context) }
        do {
            // Layer 1: country lists.
            let records: [PopularityRecord]
            if let genre {
                popularityProgress = "Apple Ads · \(genre.displayName) list"
                records = try await popularity.popularity(terms: terms, country: market.countryCode, genre: genre, monthsBack: 1)
            } else {
                records = try await popularity.popularityAcrossGenres(terms: terms, country: market.countryCode, monthsBack: 1) { g in
                    Task { @MainActor in self.popularityProgress = "Apple Ads · \(g.displayName) list" }
                }
            }
            let byTerm = Dictionary(grouping: records, by: { $0.searchTerm.lowercased() })
            let missing = keywords.filter { byTerm[$0.normalized] == nil }

            // Layer 2: dashboard index (browser session) for the misses.
            var index: [String: Int] = [:]
            var suggestionNote = ""
            if !missing.isEmpty, session.state.isSignedIn || session.state == .unknown {
                popularityProgress = "Apple Ads dashboard · exact-term index"
                if session.referenceAdamID.isEmpty { session.referenceAdamID = String(app.trackID) }
                do {
                    index = try await session.popularity(terms: missing.map(\.text), storefront: market.countryCode)
                } catch ASOError.notConfigured {
                    // Not signed in: fall through to the bound.
                } catch {
                    suggestionNote = " Dashboard index unavailable (\(error.localizedDescription.prefix(140)))."
                }
            }

            // Layer 3: the published-range floor for everything still missing.
            let stillMissing = missing.filter { index[$0.normalized] == nil }
            var floor: Int?
            if !stillMissing.isEmpty {
                let floorGenre = genre ?? records.map(\.genre).mostCommon ?? .entertainment
                floor = await publishedFloor(country: market.countryCode, genre: floorGenre, start: start)
            }

            // Layer 4: model estimate for what is still missing, plus a sub-floor rank for terms Apple leaves at the
            // floor (index below the published range), so 5s can be ordered against each other.
            var estimates: [String: PopularityEstimator.Estimate] = [:]
            let floorTerms = missing.filter { (index[$0.normalized] ?? ModelTrainer.publishedThreshold) < ModelTrainer.publishedThreshold }
            let toEstimate = stillMissing + floorTerms
            // The model was trained with Jev features on every row; without an OpenRouter key its input would be out of
            // distribution, so the estimate layer is skipped and terms keep the honest "below the published range" bound.
            if !toEstimate.isEmpty, let model = models.estimator, let sf = market.storefront, await jev.isConfigured {
                for (i, k) in toEstimate.enumerated() {
                    try Task.checkCancellation()
                    popularityProgress = "Estimating from public signals (\(i + 1)/\(toEstimate.count) · “\(k.text)”)"
                    let (f, j) = await publicFeatures(term: k.text, normalized: k.normalized, results: k.latestMeasured?.results, storefront: sf, countryCode: market.countryCode)
                    if let e = model.estimate(features: f, jev: j, storefront: market.countryCode) { estimates[k.normalized] = e }
                }
            }
            var subFloored = 0

            var countryHits = 0, globalHits = 0, bounded = 0, estimated = 0
            var genresHit = Set<String>()
            for keyword in keywords {
                if let rec = byTerm[keyword.normalized]?.first {
                    let obs = PopularityObservation(record: rec)
                    obs.keyword = keyword
                    context.insert(obs)
                    countryHits += 1
                    genresHit.insert(rec.genre.displayName)
                } else if let v = index[keyword.normalized] {
                    let obs = PopularityObservation(dashboardIndex: v, countryCode: market.countryCode, periodStart: start, periodEnd: end)
                    if v < ModelTrainer.publishedThreshold, let e = estimates[keyword.normalized], let model = models.estimator {
                        let p = PopularityEstimator.publishedProbability(of: e)
                        obs.subFloorEstimate = model.subFloorEstimate(publishedProbability: p)
                        obs.subFloorProbability = p
                        if obs.subFloorEstimate != nil { subFloored += 1 }
                    }
                    obs.keyword = keyword
                    context.insert(obs)
                    globalHits += 1
                } else if let e = estimates[keyword.normalized] {
                    let obs: PopularityObservation
                    switch e {
                    case .published(let value, let p):
                        // Not on Apple's list this month, so it sits below the list floor even if the model says higher.
                        obs = PopularityObservation(estimate: PopularityEstimate.capped(value, belowListFloor: floor), confidence: p, upperBound: floor, countryCode: market.countryCode, periodStart: start, periodEnd: end)
                    case .below(let p):
                        obs = PopularityObservation(estimate: nil, confidence: p, upperBound: floor, countryCode: market.countryCode, periodStart: start, periodEnd: end)
                        if let model = models.estimator {
                            obs.subFloorEstimate = model.subFloorEstimate(publishedProbability: 1 - p)
                            obs.subFloorProbability = 1 - p
                            if obs.subFloorEstimate != nil { subFloored += 1 }
                        }
                    }
                    obs.keyword = keyword
                    context.insert(obs)
                    estimated += 1
                } else {
                    let obs = PopularityObservation(noRecordFor: market.countryCode, genre: genre ?? .entertainment, periodStart: start, periodEnd: end, upperBound: floor)
                    obs.anyGenre = genre == nil
                    obs.keyword = keyword
                    context.insert(obs)
                    bounded += 1
                }
            }
            try? context.save()
            let scope = genre.map { $0.displayName } ?? "all 15 genres"
            var parts: [String] = ["\(countryHits) of \(keywords.count) keyword(s) are on Apple's \(market.countryCode) lists (\(scope), \(start.formatted(.dateTime.month(.wide).year())))\(genresHit.isEmpty ? "" : ", \(genresHit.sorted().joined(separator: ", "))")."]
            if globalHits > 0 { parts.append("\(globalHits) have the exact-term index from the Apple Ads dashboard.") }
            if estimated > 0 { parts.append("\(estimated) are model estimates (public signals; shown as “est.”).") }
            if subFloored > 0 { parts.append("\(subFloored) floor term(s) carry an est. 6–29 demand rank (ordering among floor terms only; Apple publishes nothing between 6 and 31).") }
            if bounded > 0 { parts.append("\(bounded) are below the published range\(floor.map { " (< \($0))" } ?? "")\(session.state.isSignedIn ? "" : ", sign in to the Apple Ads dashboard (Connections) for exact values").") }
            lastPopularityMessage = parts.joined(separator: " ") + suggestionNote
        } catch {
            lastPopularityMessage = error.localizedDescription
        }
    }

    /// Lowest 1–100 score Apple published for a country/genre this month (its lists stop around the top 500 terms).
    private func publishedFloor(country: String, genre: AppleAdsGenre, start: Date) async -> Int? {
        let key = "\(country)|\(genre.rawValue)|\(Int(start.timeIntervalSince1970))"
        if let cached = floorCache[key] { return cached }
        popularityProgress = "Apple Ads · published range (\(genre.displayName))"
        guard let rows = try? await popularity.genreDataset(country: country, genre: genre, monthsBack: 1) else { return nil }
        guard let min = rows.compactMap(\.popularity1to100).min() else { return nil }
        floorCache[key] = min
        return min
    }

    func clearPopularityMessage() { lastPopularityMessage = nil }

    func genreDataset(country: String, genre: AppleAdsGenre) async throws -> [PopularityRecord] {
        try await popularity.genreDataset(country: country, genre: genre, monthsBack: 1)
    }

    /// The public-signal features the estimator was trained on: autocomplete (own term, first word, 4-letter prefix), the
    /// latest measured results when there are any, and Jev's classification when OpenRouter is configured.
    func publicFeatures(term: String, normalized: String, results: [SearchResultApp]?, storefront sf: Storefront, countryCode: String) async -> (PublicFeatures, JevFeatures?) {
        var f = PublicFeatures(term: normalized)
        if let results { f.apply(results: results, term: term) }
        // A failed request (429 after a burst) is "not measured" (-1), never an empty answer (0).
        let own = (try? await hints.suggestions(seed: term, storefront: sf))?.map { TrackedKeyword.normalize($0.text) }
        f.ownHintCount = own?.count ?? -1
        f.ownSelfPosition = (own?.firstIndex(of: normalized)).map { $0 + 1 } ?? 0
        let first = normalized.split(separator: " ").first.map(String.init) ?? normalized
        let fw = (try? await hints.suggestions(seed: first, storefront: sf))?.map { TrackedKeyword.normalize($0.text) }
        f.firstWordHintCount = fw?.count ?? -1
        f.firstWordPosition = (fw?.firstIndex(of: normalized)).map { $0 + 1 } ?? 0
        let prefix = String(normalized.prefix(4))
        let pf = prefix == first ? fw : (try? await hints.suggestions(seed: prefix, storefront: sf))?.map { TrackedKeyword.normalize($0.text) }
        f.prefixHintCount = pf?.count ?? -1
        f.prefixPosition = (pf?.firstIndex(of: normalized)).map { $0 + 1 } ?? 0
        var j: JevFeatures?
        if await jev.isConfigured { j = try? await jev.classify(term: term, storefront: countryCode, storeLanguage: sf.defaultLocale.displayName) }
        return (f, j)
    }

    /// Runs the estimate layer alone for ad-hoc terms (Lab diagnostics); nil per term when no model is loaded.
    func estimate(terms: [String], storefront sf: Storefront) async -> [(term: String, estimate: PopularityEstimator.Estimate?, features: PublicFeatures, jev: JevFeatures?)] {
        var out: [(term: String, estimate: PopularityEstimator.Estimate?, features: PublicFeatures, jev: JevFeatures?)] = []
        guard await jev.isConfigured else { return terms.map { ($0, nil, PublicFeatures(term: TrackedKeyword.normalize($0)), nil) } }
        for t in terms {
            let n = TrackedKeyword.normalize(t)
            let (f, j) = await publicFeatures(term: t, normalized: n, results: nil, storefront: sf, countryCode: sf.countryCode)
            out.append((t, models.estimator?.estimate(features: f, jev: j, storefront: sf.countryCode), f, j))
        }
        return out
    }
}

extension Array where Element: Hashable {
    var mostCommon: Element? {
        Dictionary(grouping: self, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}
