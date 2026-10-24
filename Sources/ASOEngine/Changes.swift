import Foundation
import ASOCore

/// Releases and notes on the app's timeline, and what the ranks did around each one.
extension Engine {
    // MARK: Markers

    /// The app's markers, newest first.
    public func markers(appID: Int) async throws -> [MarkerRecord] {
        _ = try await app(appID)
        return try await store.markers(appID: appID).reversed()
    }

    /// Pins a note to a date (now by default) to compare ranks around, e.g. "keywords changed" or "new screenshots".
    public func addNote(appID: Int, title: String, date: Date? = nil, now: Date = Date()) async throws -> MarkerRecord {
        _ = try await app(appID)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw EngineError.invalidArgument("Give the note a title, e.g. \"keywords updated\".") }
        let date = date ?? now
        guard date <= now else { throw EngineError.invalidArgument("A note marks something that already happened; its date cannot be in the future.") }
        return try await store.addMarker(appID: appID, date: date, kind: "note", title: title)
    }

    /// Removes a release or note marker.
    public func removeMarker(appID: Int, id: Int) async throws {
        _ = try await app(appID)
        guard try await store.removeMarker(id: id, appID: appID) else { throw EngineError.notFound("App \(appID) has no marker \(id).") }
    }

    /// Records a release marker when the App Store shows a version not looked at before (on the first look, the current
    /// release), dated with Apple's release date.
    @discardableResult
    func recordReleaseIfNew(_ info: SearchResultApp, appID: Int, countryCode: String, now: Date) async throws -> MarkerRecord? {
        guard let version = info.version, !version.isEmpty else { return nil }
        return try await store.recordRelease(version: version, date: info.currentVersionReleaseDate ?? now, countryCode: countryCode, appID: appID)
    }

    /// Markers in the shape rank comparisons take, oldest first.
    func rankMarkers(appID: Int) async throws -> [Marker] {
        try await store.markers(appID: appID).map(\.marker)
    }

    // MARK: Impact

    /// One keyword's rank before and after a marker, weighted by what the keyword is worth.
    public struct ImpactRow: Sendable, Codable, Equatable {
        public let keyword: String
        public let country: String
        public let device: String
        /// Last successful measurement at or before the marker, and the latest one after it. Absent: not in the results.
        public let before: Int?
        public let beforeAt: Date
        public let after: Int?
        public let afterAt: Date
        /// Results observed; "not in the results" counts as depth + 1 in the delta.
        public let depth: Int
        /// Positive = moved up.
        public let delta: Int
        public let popularity: Int?
        public let difficulty: Double?
        public let fit: Double?
        public let brandLike: Bool
        /// 0–100, see `KeywordImpact.value`.
        public let value: Double
        /// Value gained (positive) or lost on the visibility curve.
        public let gain: Double
        public let tier: String
    }

    public struct ImpactReport: Sendable, Codable, Equatable {
        public let marker: MarkerRecord
        public let improved: Int
        public let worsened: Int
        public let same: Int
        public let gained: Double
        public let lost: Double
        public let net: Double
        /// Biggest gain or loss first, then the biggest move.
        public let rows: [ImpactRow]
    }

    /// Every keyword measured both before and after the marker, in all of the app's markets.
    public func impact(appID: Int, markerID: Int) async throws -> ImpactReport {
        let app = try await app(appID)
        guard let marker = try await store.markers(appID: appID).first(where: { $0.id == markerID }) else {
            throw EngineError.notFound("App \(appID) has no marker \(markerID).")
        }
        var rows: [ImpactRow] = []
        for market in try await store.markets(appID: appID) {
            for keyword in try await store.keywords(marketID: market.id) {
                let observations = try await store.observations(keywordID: keyword.id)
                guard let pair = RankHistory(observations, point: { $0.point }).beforeAfter(marker.date) else { continue }
                let report = KeywordReportRow(keyword: keyword, market: market, app: app, observations: observations,
                                              deltaReference: .previous, golden: .standard)
                rows.append(Self.impactRow(report, before: pair.before.point, after: pair.after.point))
            }
        }
        rows.sort { a, b in
            if abs(a.gain) != abs(b.gain) { return abs(a.gain) > abs(b.gain) }
            if abs(a.delta) != abs(b.delta) { return abs(a.delta) > abs(b.delta) }
            return (a.keyword, a.country) < (b.keyword, b.country)
        }
        let gained = rows.filter { $0.delta > 0 }.reduce(0.0) { $0 + $1.gain }
        let lost = rows.filter { $0.delta < 0 }.reduce(0.0) { $0 + $1.gain }
        let improved = rows.filter { $0.delta > 0 }.count
        let worsened = rows.filter { $0.delta < 0 }.count
        return ImpactReport(marker: marker, improved: improved, worsened: worsened, same: rows.count - improved - worsened,
                            gained: gained, lost: lost, net: gained + lost, rows: rows)
    }

    private static func impactRow(_ report: KeywordReportRow, before: RankPoint, after: RankPoint) -> ImpactRow {
        let depth = max(before.observedCount, after.observedCount)
        let from = before.outcome.position
        let to = after.outcome.position
        let value = KeywordImpact.value(popularity: report.popularity, difficulty: report.difficulty, isBrandLike: report.brandLike, fit: report.fit)
        return ImpactRow(keyword: report.keyword, country: report.country, device: report.device, before: from, beforeAt: before.fetchedAt,
                         after: to, afterAt: after.fetchedAt, depth: depth, delta: (from ?? depth + 1) - (to ?? depth + 1),
                         popularity: report.popularity, difficulty: report.difficulty, fit: report.fit, brandLike: report.brandLike,
                         value: value, gain: KeywordImpact.gain(before: from, after: to, value: value), tier: KeywordImpact.tier(value).rawValue)
    }
}
