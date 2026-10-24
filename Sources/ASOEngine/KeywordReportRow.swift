import Foundation
import ASOCore

/// One tracked keyword as reports show it. Absent values stay absent (`nil` in JSON): "not measured" is not rank 0,
/// "outside the top N" is not rank N+1, and no popularity source means no popularity.
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
    public let popularity: Int?
    public let opportunity: Double?
    public let brandLike: Bool
    public let golden: Bool
    public let measuredAt: Date?
    /// Why the latest request failed, when it did.
    public let failure: String?

    init(keyword: KeywordRecord, market: MarketRecord, app: AppRecord, observations: [RankObservationRecord],
         deltaReference: DeltaReference, golden thresholds: GoldenThresholds) {
        let history = RankHistory(observations) { $0.point }
        let latest = observations.max { $0.fetchedAt < $1.fetchedAt }
        let measured = history.latestMeasured
        let judgement = KeywordJudgement(term: keyword.text, ownApp: app.ownApp,
                                         measurement: measured.map { .init(results: $0.results, signals: $0.signals) },
                                         brandProbability: keyword.brandProbability, navigational: keyword.navigational,
                                         fitProbability: keyword.fitProbability, popularity: nil)
        let delta = history.delta(reference: deltaReference, markers: [])

        self.keyword = keyword.text
        country = market.countryCode
        device = market.device.rawValue
        status = latest.map { StoredOutcome.columns($0.outcome).kind } ?? "notMeasured"
        rank = measured?.outcome.position
        observedCount = measured?.point.observedCount
        rankLabel = latest?.outcome.shortLabel ?? "—"
        self.delta = delta.delta
        deltaAgainst = delta.against
        difficulty = judgement.difficulty?.score
        popularity = judgement.popularity
        opportunity = judgement.opportunity
        brandLike = judgement.isBrandLike
        golden = judgement.isGolden(minPopularity: thresholds.minPopularity, maxDifficulty: thresholds.maxDifficulty)
        measuredAt = latest?.fetchedAt
        if case .requestFailed(let reason) = latest?.outcome { failure = reason } else { failure = nil }
    }
}
