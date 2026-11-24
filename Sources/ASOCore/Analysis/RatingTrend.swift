import Foundation

/// The rating count and average the App Store reported for an app in one storefront at one moment.
public struct RatingReading: Sendable, Hashable, Codable {
    public let countryCode: String
    public let count: Int
    public let average: Double?
    public let fetchedAt: Date

    public init(countryCode: String, count: Int, average: Double?, fetchedAt: Date) {
        self.countryCode = countryCode
        self.count = count
        self.average = average
        self.fetchedAt = fetchedAt
    }
}

/// Ratings in one storefront over time: the latest reading, how the count moved since the previous one, and when a new
/// rating was last seen.
public struct RatingTrend: Sendable, Hashable {
    public let countryCode: String
    public let count: Int
    public let average: Double?
    /// Count change since the previous reading; nil on the first reading.
    public let delta: Int?
    public let previousAt: Date?
    public let checkedAt: Date
    /// The most recent reading whose count rose over the reading before it.
    public let lastNewAt: Date?

    /// One trend per storefront: the storefront with the most recent new rating first, then the larger count.
    public static func trends(_ readings: [RatingReading]) -> [RatingTrend] {
        Dictionary(grouping: readings, by: \.countryCode).compactMap { country, readings -> RatingTrend? in
            let sorted = readings.sorted { $0.fetchedAt < $1.fetchedAt }
            guard let latest = sorted.last else { return nil }
            let previous = sorted.dropLast().last
            var lastNew: Date?
            for (a, b) in zip(sorted, sorted.dropFirst()) where b.count > a.count { lastNew = b.fetchedAt }
            return RatingTrend(countryCode: country, count: latest.count, average: latest.average, delta: previous.map { latest.count - $0.count },
                               previousAt: previous?.fetchedAt, checkedAt: latest.fetchedAt, lastNewAt: lastNew)
        }
        .sorted {
            let a = $0.lastNewAt ?? .distantPast, b = $1.lastNewAt ?? .distantPast
            if a != b { return a > b }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.countryCode < $1.countryCode
        }
    }

    /// Whether a fresh reading is worth storing. A reading that repeats the previous one (same count, average within
    /// 0.005) less than an hour later adds nothing and is skipped; after an hour it is kept as proof of "no change".
    public static func shouldRecord(count: Int, average: Double?, previous: RatingReading?, now: Date) -> Bool {
        guard let previous else { return true }
        let same = previous.count == count && abs((previous.average ?? 0) - (average ?? 0)) < 0.005
        return !(same && previous.fetchedAt > now.addingTimeInterval(-3600))
    }
}
