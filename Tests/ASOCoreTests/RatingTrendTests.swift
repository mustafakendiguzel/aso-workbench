import Foundation
import Testing
@testable import ASOCore

@Suite("Rating trends")
struct RatingTrendTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(_ country: String, _ count: Int, hours: Double, average: Double? = 4.5) -> RatingReading {
        RatingReading(countryCode: country, count: count, average: average, fetchedAt: t0.addingTimeInterval(hours * 3600))
    }

    @Test("Each storefront shows its latest count, the change since the previous reading and the last rise")
    func trends() {
        let trends = RatingTrend.trends([
            reading("US", 100, hours: 0), reading("US", 104, hours: 24), reading("US", 104, hours: 48),
            reading("DE", 10, hours: 0), reading("DE", 12, hours: 30),
            reading("FR", 7, hours: 5),
        ])
        #expect(trends.map(\.countryCode) == ["DE", "US", "FR"])   // the most recent new rating first; none sorts last
        let us = trends[1]
        #expect(us.count == 104)
        #expect(us.delta == 0)
        #expect(us.previousAt == t0.addingTimeInterval(24 * 3600))
        #expect(us.lastNewAt == t0.addingTimeInterval(24 * 3600))
        #expect(trends[0].delta == 2)
        #expect(trends[2].delta == nil)   // first reading
        #expect(trends[2].lastNewAt == nil)
    }

    @Test("Without new ratings the larger count sorts first, then the country code")
    func ties() {
        let trends = RatingTrend.trends([reading("JP", 5, hours: 0), reading("BR", 50, hours: 0), reading("AT", 5, hours: 0)])
        #expect(trends.map(\.countryCode) == ["BR", "AT", "JP"])
        #expect(RatingTrend.trends([]).isEmpty)
    }

    @Test("A repeated reading within the hour is skipped; a change, or the same reading an hour later, is kept")
    func recording() {
        let previous = reading("US", 100, hours: 0, average: 4.5)
        let soon = t0.addingTimeInterval(30 * 60)
        #expect(RatingTrend.shouldRecord(count: 100, average: 4.5, previous: nil, now: soon))
        #expect(!RatingTrend.shouldRecord(count: 100, average: 4.504, previous: previous, now: soon))
        #expect(RatingTrend.shouldRecord(count: 101, average: 4.5, previous: previous, now: soon))
        #expect(RatingTrend.shouldRecord(count: 100, average: 4.51, previous: previous, now: soon))
        #expect(RatingTrend.shouldRecord(count: 100, average: 4.5, previous: previous, now: t0.addingTimeInterval(2 * 3600)))
    }
}
