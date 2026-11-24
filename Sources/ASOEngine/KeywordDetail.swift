import Foundation
import ASOCore

/// Difficulty with its components as the engine names and weighs them, so every front end shows the same breakdown.
public struct DifficultyReport: Sendable, Codable, Equatable {
    public struct Component: Sendable, Codable, Equatable {
        public let name: String
        public let weight: String
        public let value: Double
        public let explanation: String
    }

    public let score: Double
    public let tier: String
    public let sampleSize: Int
    public let components: [Component]

    public init(_ score: DifficultyScore) {
        self.score = score.score
        tier = score.tier
        sampleSize = score.sampleSize
        components = score.components.map { .init(name: $0.name, weight: $0.weight, value: $0.value, explanation: $0.explanation) }
    }
}

/// Everything the macOS keyword inspector shows for one keyword: the report row, the rank history, the latest top ten
/// with the competition signals and difficulty behind them, and the raw observation log.
public struct KeywordDetail: Sendable, Codable, Equatable {
    /// One measurement attempt. `rank` is set when found; `observedCount` tells how deep "not found" looked.
    public struct Observation: Sendable, Codable, Equatable {
        public let fetchedAt: Date
        public let status: String
        public let rank: Int?
        public let observedCount: Int
        public let label: String
        public let provider: String
        public let failure: String?
    }

    /// One of the latest top results; `isOwnApp` marks the tracked app (or another app from its seller).
    public struct Result: Sendable, Codable, Equatable {
        public let position: Int
        public let trackID: Int
        public let name: String
        public let sellerName: String
        public let ratingCount: Int?
        public let averageRating: Double?
        public let isOwnApp: Bool
    }

    public struct Summary: Sendable, Codable, Equatable {
        /// Latest successful rank, best rank ever found, how many measurements succeeded, how many were outside.
        public let latest: Int?
        public let best: Int?
        public let measurements: Int
        public let outside: Int
    }

    public let row: KeywordReportRow
    public let summary: Summary
    /// Every attempt, oldest first.
    public let observations: [Observation]
    public let topResults: [Result]
    public let difficulty: DifficultyReport?

    init(row: KeywordReportRow, app: AppRecord, observations records: [RankObservationRecord]) {
        self.row = row
        let ordered = records.sorted { ($0.fetchedAt, $0.id) < ($1.fetchedAt, $1.id) }
        observations = ordered.map { record in
            let columns = StoredOutcome.columns(record.outcome)
            return Observation(fetchedAt: record.fetchedAt, status: columns.kind, rank: columns.position, observedCount: columns.observedCount,
                               label: record.outcome.shortLabel, provider: record.provider.rawValue, failure: columns.failureReason)
        }
        let measured = ordered.filter { $0.point.isMeasured }
        summary = Summary(latest: measured.last?.outcome.position, best: measured.compactMap(\.outcome.position).min(), measurements: measured.count,
                          outside: measured.filter { $0.outcome.position == nil }.count)
        let latestResults = measured.last?.results ?? []
        topResults = latestResults.prefix(10).enumerated().map { index, result in
            Result(position: index + 1, trackID: result.trackID, name: result.name, sellerName: result.sellerName, ratingCount: result.ratingCount,
                   averageRating: result.averageRating,
                   isOwnApp: result.trackID == app.trackID || (!app.sellerName.isEmpty && result.sellerName == app.sellerName))
        }
        let score = measured.last.flatMap { KeywordJudgement.difficulty(signals: $0.signals, results: $0.results, term: row.keyword) }
        difficulty = score.map(DifficultyReport.init)
    }
}
