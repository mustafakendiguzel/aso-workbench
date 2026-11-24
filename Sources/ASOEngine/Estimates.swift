import Foundation
import ASOCore

/// The popularity models of one folder, read once (each file takes a moment to parse) and only when an estimate is needed.
final class ModelShelf: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var loaded: Result<PopularityModel, any Error>?

    init(_ directory: URL) { self.directory = directory }

    var model: PopularityModel? {
        lock.lock(); defer { lock.unlock() }
        if loaded == nil { loaded = Result { try PopularityModel(directory: directory) } }
        return try? loaded?.get()
    }
}

/// The macOS app's fourth popularity layer: for terms Apple publishes nothing for, the bundled model's estimate from public
/// signals (autocomplete, search results) and Jev. Without the OpenRouter key the layer is skipped, as in the app: the
/// model was trained with Jev's answers on every row, so without them its input would be out of distribution.
extension Engine {
    /// One term to estimate, with the results of its latest measurement when there are any.
    struct EstimateRequest {
        let term: String
        let results: [SearchResultApp]?
    }

    /// Whether estimates can be made: a model on disk and Jev.
    var canEstimate: Bool {
        get async { await judge?.isConfigured == true && models?.model != nil }
    }

    /// Estimates by normalized term; terms the model cannot take (a storefront or genre it was not trained on) are left out.
    func estimates(_ requests: [EstimateRequest], storefront: Storefront,
                   progress: @Sendable (String) -> Void = { _ in }) async throws -> [String: PopularityEstimate] {
        guard let judge, await judge.isConfigured, let model = models?.model else { return [:] }
        var out: [String: PopularityEstimate] = [:]
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            progress("\(storefront.countryCode): estimating “\(request.term)” (\(index + 1) of \(requests.count))")
            let (features, jev) = await publicFeatures(term: request.term, results: request.results, storefront: storefront, judge: judge)
            if let estimate = model.estimate(features: features, jev: jev, storefront: storefront.countryCode) {
                out[KeywordText.normalize(request.term)] = estimate
            }
        }
        return out
    }

    /// The reading an estimate becomes: a value capped under the list's lowest score, or below the range with the
    /// model's 6–29 rank among floor terms.
    func estimateReading(_ estimate: PopularityEstimate, country: String, genre: String?, start: Date, end: Date, floor: Int?, anyGenre: Bool,
                         now: Date) -> PopularityReading {
        var reading: PopularityReading
        switch estimate {
        case let .published(value, probability):
            reading = PopularityReading(fetchedAt: now, country: country, genre: genre, periodStart: start, periodEnd: end,
                                        popularity: PopularityEstimate.capped(value, belowListFloor: floor), popularity1to5: nil, popularityInGenre: nil,
                                        rankInGenre: nil, source: "estimate", upperBound: floor, anyGenre: anyGenre)
            reading.probability = probability
        case let .below(probability):
            reading = PopularityReading(fetchedAt: now, country: country, genre: genre, periodStart: start, periodEnd: end, popularity: nil,
                                        popularity1to5: nil, popularityInGenre: nil, rankInGenre: nil, source: "estimate", upperBound: floor,
                                        anyGenre: anyGenre)
            reading.probability = probability
            reading.subFloor = models?.model?.subFloor(estimate)
        }
        return reading
    }

    /// The public-signal features the model was trained on: autocomplete for the term, its first word and its 4-letter
    /// prefix, the latest results when there are any, and Jev's classification.
    func publicFeatures(term: String, results: [SearchResultApp]?, storefront: Storefront,
                        judge: any KeywordJudge) async -> (PublicFeatures, JevFeatures?) {
        let normalized = KeywordText.normalize(term)
        var f = PublicFeatures(term: normalized)
        if let results { f.apply(results: results, term: term) }
        // A failed request is "not collected" (-1), never an empty answer (0).
        func hints(_ seed: String) async -> [String]? {
            (try? await suggestions.suggestions(seed: seed, storefront: storefront))?.map { KeywordText.normalize($0.text) }
        }
        let own = await hints(term)
        f.ownHintCount = own?.count ?? -1
        f.ownSelfPosition = (own?.firstIndex(of: normalized)).map { $0 + 1 } ?? 0
        let first = normalized.split(separator: " ").first.map(String.init) ?? normalized
        let firstWord = await hints(first)
        f.firstWordHintCount = firstWord?.count ?? -1
        f.firstWordPosition = (firstWord?.firstIndex(of: normalized)).map { $0 + 1 } ?? 0
        let prefix = String(normalized.prefix(4))
        var byPrefix = firstWord
        if prefix != first { byPrefix = await hints(prefix) }
        f.prefixHintCount = byPrefix?.count ?? -1
        f.prefixPosition = (byPrefix?.firstIndex(of: normalized)).map { $0 + 1 } ?? 0
        let jev = try? await judge.classify(term: term, storefront: storefront.countryCode, storeLanguage: storefront.defaultLocale.displayName)
        return (f, jev)
    }
}
