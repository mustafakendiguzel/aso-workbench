import Foundation
import ASOCore

/// One tracked keyword as reports show it. Absent values stay absent (left out of the JSON): "not measured" is not
/// rank 0, "outside the top N" is not rank N+1, and no popularity source means no popularity.
public struct KeywordReportRow: Sendable, Codable, Equatable {
    public let keyword: String
    public let country: String
    public let device: String
    /// Outcome of the latest attempt: "found" · "outside" · "failed" · "notChecked" · "notMeasured"
    public let status: String
    /// Rank in the latest *successful* measurement, so a failed retry does not hide the last known rank.
    public let rank: Int?
    /// Results observed in that measurement ("outside" means not among these).
    public let observedCount: Int?
    /// Short label of the latest attempt ("#12", "> 200", "Error").
    public let rankLabel: String
    /// Positive = moved up.
    public let delta: Int?
    public let deltaAgainst: String
    public let difficulty: Double?
    /// "Easy" … "Very hard", from the difficulty score.
    public let difficultyTier: String?
    public let popularity: Int?
    public let opportunity: Double?
    public let brandLike: Bool
    public let golden: Bool
    /// Probability (0–1) that someone searching this wants an app like this one; nil until checked.
    public let fit: Double?
    /// Median rating count of the top ten, and its band ("Low" … "Very high").
    public let medianRatingsTop10: Int?
    public let ratingMass: String?
    /// How many of the top ten name the term in their title, and how many sellers they come from.
    public let titleMatchesTop10: Int?
    public let distinctSellersTop10: Int?
    public let measuredAt: Date?
    /// The provider of the latest successful measurement (e.g. "itunes-search").
    public let provider: String?
    /// Why the latest request failed, when it did.
    public let failure: String?
    public let note: String

    init(keyword: KeywordRecord, market: MarketRecord, app: AppRecord, observations: [RankObservationRecord],
         deltaReference: DeltaReference, golden thresholds: GoldenThresholds) {
        let history = RankHistory(observations) { $0.point }
        let latest = observations.max { $0.fetchedAt < $1.fetchedAt }
        let measured = history.latestMeasured
        let signals = measured?.signals
        let judgement = KeywordJudgement(term: keyword.text, ownApp: app.ownApp,
                                         measurement: measured.map { .init(results: $0.results, signals: signals) },
                                         brandProbability: keyword.brandProbability, navigational: keyword.navigational,
                                         fitProbability: keyword.fitProbability, popularity: nil)
        let delta = history.delta(reference: deltaReference, markers: [])
        let difficulty = judgement.difficulty

        self.keyword = keyword.text
        country = market.countryCode
        device = market.device.rawValue
        status = latest.map { StoredOutcome.columns($0.outcome).kind } ?? "notMeasured"
        rank = measured?.outcome.position
        observedCount = measured?.point.observedCount
        rankLabel = latest?.outcome.shortLabel ?? "—"
        self.delta = delta.delta
        deltaAgainst = delta.against
        self.difficulty = difficulty?.score
        difficultyTier = difficulty?.tier
        popularity = judgement.popularity
        opportunity = judgement.opportunity
        brandLike = judgement.isBrandLike
        golden = judgement.isGolden(minPopularity: thresholds.minPopularity, maxDifficulty: thresholds.maxDifficulty)
        fit = keyword.fitProbability
        medianRatingsTop10 = signals?.medianRatingCountTop10
        ratingMass = signals.flatMap { $0.medianRatingCountTop10 == nil ? nil : $0.ratingMassBand }
        titleMatchesTop10 = signals?.titleMatchesTop10
        distinctSellersTop10 = signals?.distinctSellersTop10
        measuredAt = latest?.fetchedAt
        provider = measured?.provider.rawValue
        if case .requestFailed(let reason) = latest?.outcome { failure = reason } else { failure = nil }
        note = keyword.note
    }
}

/// The macOS app's CSV export, column for column, so spreadsheets built on it keep working. Values the engine does
/// not have yet (popularity) are empty, with the source "unavailable".
public enum KeywordCSV {
    public static let header = "keyword,storefront,device,rank,observed_count,delta,popularity_1_100,popularity_source,popularity_genre,fit_probability,difficulty,difficulty_tier,rating_mass_median_top10,title_matches_top10,measured_at,provider"

    public static func render(_ rows: [KeywordReportRow]) -> String {
        let lines = rows.map { r in
            [r.keyword, r.country, r.device, r.rank.map(String.init) ?? "", String(r.observedCount ?? 0), r.delta.map(String.init) ?? "",
             r.popularity.map(String.init) ?? "", r.popularity == nil ? "unavailable" : "", "",
             r.fit.map { String(format: "%.2f", $0) } ?? "", r.difficulty.map { String(Int($0.rounded())) } ?? "", r.difficultyTier ?? "",
             r.medianRatingsTop10.map(String.init) ?? "", r.titleMatchesTop10.map(String.init) ?? "",
             r.measuredAt?.ISO8601Format() ?? "", r.provider ?? ""]
                .map(escape).joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    /// RFC 4180: quote a field that contains a comma, quote or line break, doubling its quotes.
    public static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
