import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

/// A clock the test moves forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(hours: Double) { lock.lock(); current = current.addingTimeInterval(hours * 3600); lock.unlock() }
}

@Suite("Ratings, reviews and competitors")
struct CatalogTests {
    func rated(_ count: Int, average: Double = 4.5) -> SearchResultApp {
        SearchResultApp(trackID: ownApp.trackID, bundleID: ownApp.bundleID, name: ownApp.name, sellerName: ownApp.sellerName, iconURL: nil,
                        averageRating: average, ratingCount: count, primaryGenre: "Productivity", releaseDate: nil, currentVersionReleaseDate: nil,
                        price: 0, version: "1.0")
    }

    func tracked(markets: [String] = ["US"], reviews: FakeReviews = FakeReviews()) async throws -> Engine {
        let engine = try makeEngine(reviews: reviews)
        _ = try await engine.addApp(reference: String(ownApp.trackID), lookupCountry: nil, markets: markets, device: .iPhone)
        return engine
    }

    func withApp(_ app: SearchResultApp, on engine: Engine, reviews: FakeReviews = FakeReviews()) -> Engine {
        Engine(store: engine.store, search: FakeSearch(apps: [app.trackID: app]), suggestions: FakeSuggestions(), reviews: reviews)
    }

    @Test("A data file from schema 2 gains the ratings and reviews tables and keeps its apps")
    func migrationFromSchemaTwo() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            try db.execute(Store.migrations[0])
            try db.execute(Store.migrations[1])
            try db.setUserVersion(2)
            try db.execute("INSERT INTO apps (track_id, name, seller_name, created_at) VALUES (42, 'Old App', 'Old Seller', 0)")
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
        #expect(try await store.app(trackID: 42)?.name == "Old App")
        try await store.addRating(RatingReading(countryCode: "US", count: 3, average: 4, fetchedAt: Date()), appID: 42)
        #expect(try await store.ratings(appID: 42).count == 1)
        #expect(try await store.recordReviews([makeReview("1")], appID: 42, fetchedAt: Date()) == 1)
        try await store.removeApp(trackID: 42)
        #expect(try await store.ratings(appID: 42).isEmpty)   // removing the app removes its ratings and reviews
        #expect(try await store.reviews(appID: 42).isEmpty)
    }

    @Test("Ratings are read per market, a repeat within the hour is skipped, and new ratings are counted")
    func ratings() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let engine = try await tracked(markets: ["US", "DE"])
        let first = try await withApp(rated(100), on: engine).checkRatings(appID: ownApp.trackID) { clock.now }
        #expect(first.storefronts == 2)
        #expect(first.recorded == 2)
        #expect(first.newRatings == 0)
        #expect(first.failed.isEmpty && first.unavailable.isEmpty)

        clock.advance(hours: 0.5)
        let repeated = try await withApp(rated(100), on: engine).checkRatings(appID: ownApp.trackID, countries: ["us"]) { clock.now }
        #expect(repeated.recorded == 0)

        clock.advance(hours: 1)
        let rose = try await withApp(rated(103), on: engine).checkRatings(appID: ownApp.trackID, countries: ["US"]) { clock.now }
        #expect(rose.recorded == 1)
        #expect(rose.newRatings == 3)

        let rows = try await engine.ratings(appID: ownApp.trackID)
        #expect(rows.map(\.country) == ["US", "DE"])
        #expect(rows[0].count == 103)
        #expect(rows[0].delta == 3)
        #expect(rows[0].lastNewAt == clock.now)
        #expect(rows[0].countryName == "United States")
        #expect(rows[1].delta == nil)
    }

    @Test("Storefronts without the app, failed requests and bad countries are reported")
    func ratingsProblems() async throws {
        let engine = try await tracked()
        let missing = try await engine.withoutApps.checkRatings(appID: ownApp.trackID, countries: ["US", "DE"])
        #expect(missing.unavailable == ["US", "DE"])
        await #expect(throws: EngineError.self) { try await engine.checkRatings(appID: ownApp.trackID, countries: ["XX"]) }
        await #expect(throws: EngineError.self) { try await engine.checkRatings(appID: 7) }

        let noMarkets = try makeEngine()
        _ = try await noMarkets.addApp(reference: String(ownApp.trackID))
        await #expect(throws: EngineError.self) { try await noMarkets.checkRatings(appID: ownApp.trackID) }
    }

    @Test("The first review check is history; later checks mark only unseen reviews new and clear the previous marks")
    func reviews() async throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = try await tracked(markets: ["US", "DE"])
        var feed = FakeReviews(byCountry: ["US": [makeReview("1", date: day)], "DE": [makeReview("1", "DE", rating: 2, date: day)]])
        let first = try await withApp(ownApp, on: engine, reviews: feed).checkReviews(appID: ownApp.trackID)
        #expect(first == .init(storefronts: 2, added: 2, stored: 2, failed: []))
        #expect(try await engine.reviewsReport(appID: ownApp.trackID).new == 0)

        feed.byCountry["US"] = [makeReview("2", rating: 1, title: "Crashes", date: day.addingTimeInterval(3600)), makeReview("1", date: day)]
        let second = try await withApp(ownApp, on: engine, reviews: feed).checkReviews(appID: ownApp.trackID)
        #expect(second.added == 1)
        var report = try await engine.reviewsReport(appID: ownApp.trackID)
        #expect(report.reviews.map(\.id) == ["US|2", "DE|1", "US|1"])
        #expect(report.reviews.map(\.isNew) == [true, false, false])
        #expect(report.stars == [1, 1, 0, 0, 1])
        #expect(report.average == 8.0 / 3)
        #expect(report.countries == ["DE", "US"])

        _ = try await withApp(ownApp, on: engine, reviews: feed).checkReviews(appID: ownApp.trackID)
        report = try await engine.reviewsReport(appID: ownApp.trackID)
        #expect(report.new == 0)   // nothing unseen: the previous marks are cleared
    }

    @Test("A check where every storefront fails changes nothing; a partial failure is reported")
    func reviewFailures() async throws {
        let engine = try await tracked(markets: ["US", "DE"])
        _ = try await withApp(ownApp, on: engine, reviews: FakeReviews(byCountry: ["US": [makeReview("1")]])).checkReviews(appID: ownApp.trackID)
        _ = try await withApp(ownApp, on: engine, reviews: FakeReviews(byCountry: ["US": [makeReview("2"), makeReview("1")]]))
            .checkReviews(appID: ownApp.trackID)
        #expect(try await engine.reviewsReport(appID: ownApp.trackID).new == 1)

        let offline = withApp(ownApp, on: engine, reviews: FakeReviews(failing: ["US", "DE"]))
        await #expect(throws: EngineError.self) { try await offline.checkReviews(appID: ownApp.trackID) }
        #expect(try await engine.reviewsReport(appID: ownApp.trackID).new == 1)   // still marked

        let partial = try await withApp(ownApp, on: engine, reviews: FakeReviews(failing: ["DE"])).checkReviews(appID: ownApp.trackID)
        #expect(partial.failed == ["DE"])
    }

    @Test("Filters keep a storefront, a minimum rating, new reviews or a text in the title or body")
    func reviewFilters() async throws {
        let engine = try await tracked(markets: ["US", "DE"])
        _ = try await withApp(ownApp, on: engine, reviews: FakeReviews(byCountry: ["US": [makeReview("1", rating: 5)]])).checkReviews(appID: ownApp.trackID)
        let feed = FakeReviews(byCountry: ["US": [makeReview("1", rating: 5), makeReview("2", rating: 2, body: "Sync is SLOW")],
                                           "DE": [makeReview("3", "DE", rating: 4, title: "Gut")]])
        _ = try await withApp(ownApp, on: engine, reviews: feed).checkReviews(appID: ownApp.trackID)

        func ids(_ filter: Engine.ReviewFilter) async throws -> Set<String> {
            Set(try await engine.reviewsReport(appID: ownApp.trackID, filter: filter).reviews.map(\.id))
        }
        #expect(try await ids(.init(country: "de")) == ["DE|3"])
        #expect(try await ids(.init(minRating: 4)) == ["US|1", "DE|3"])
        #expect(try await ids(.init(onlyNew: true)) == ["US|2", "DE|3"])
        #expect(try await ids(.init(search: "slow")) == ["US|2"])
        #expect(try await ids(.init(search: "gut")) == ["DE|3"])
        #expect(try await engine.reviewsReport(appID: ownApp.trackID, filter: .init(search: "slow")).stored == 3)   // totals cover everything
    }

    @Test("Measuring first reads ratings and reviews in the measured storefronts")
    func measureReadsTheCatalog() async throws {
        let feed = FakeReviews(byCountry: ["US": [makeReview("1")]])
        let engine = try await tracked(markets: ["US", "DE"], reviews: feed)
        _ = try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        _ = try await engine.measure(appID: ownApp.trackID)
        #expect(try await engine.ratings(appID: ownApp.trackID).map(\.country) == ["US"])   // DE has no keywords, so it is not measured
        #expect(try await engine.reviewsReport(appID: ownApp.trackID).stored == 1)
    }

    @Test("Competitors come from the latest measured results, without our app, by appearances then position")
    func competitors() async throws {
        let rival = makeApp(7, "Rival Notes", ratings: 900)
        let other = makeApp(8, "Other Notes")
        let results = ["notes": [rival, ownApp, other], "journal": [other, rival], "diary": [rival]]
        let engine = try makeEngine(search: FakeSearch(results: results, apps: [ownApp.trackID: ownApp]))
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(Array(results.keys), appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let empty = try await engine.competitors(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        #expect(empty.keywordsMeasured == 0)
        #expect(empty.competitors.isEmpty)

        _ = try await engine.measure(appID: ownApp.trackID)
        let failing = Engine(store: engine.store, search: FakeSearch(failing: ["diary"]), suggestions: FakeSuggestions(), reviews: FakeReviews())
        _ = try await failing.measure(appID: ownApp.trackID, keywords: ["diary"])   // a failed retry keeps the last results

        let report = try await engine.competitors(appID: ownApp.trackID, countryCode: "us", device: .iPhone)
        #expect(report.market == "US · iphone")
        #expect(report.keywordsMeasured == 3)
        #expect(report.competitors.map(\.trackID) == [7, 8])
        let first = report.competitors[0]
        #expect(first.keywords == 3)
        #expect(first.top10 == 3)
        #expect(first.averagePosition == 4.0 / 3)
        #expect(first.appearances.map(\.keyword) == ["diary", "notes", "journal"])
        #expect(first.ratingCount == 900)

        let shallow = try await engine.competitors(appID: ownApp.trackID, countryCode: "US", device: .iPhone, depth: 1)
        #expect(shallow.competitors.map(\.trackID) == [7, 8])
        #expect(shallow.competitors.map(\.keywords) == [2, 1])
        await #expect(throws: EngineError.self) { try await engine.competitors(appID: ownApp.trackID, countryCode: "US", device: .iPhone, depth: 60) }
        await #expect(throws: EngineError.self) { try await engine.competitors(appID: ownApp.trackID, countryCode: "DE", device: .iPhone) }
    }

    @Test("The commands check, list and filter, with JSON for front ends")
    func commands() async throws {
        let feed = FakeReviews(byCountry: ["US": [makeReview("1", rating: 4, title: "Handy")]])
        let harness = try Harness(reviews: feed)
        let id = String(ownApp.trackID)
        #expect(await harness.run(["app", "add", id, "--markets", "US"]).code == 0)

        let check = await harness.run(["ratings", "check", id])
        #expect(check.code == 0)
        #expect(check.console.output == "Checked 1 storefront(s): 1 reading(s) stored, 0 new rating(s) since the previous check.")
        let list = await harness.run(["--json", "ratings", "list", id])
        #expect(list.console.output.contains("\"countryName\" : \"United States\""))
        #expect(await harness.run(["ratings", "check", id, "--all", "--country", "US"]).code == 64)

        #expect(await harness.run(["reviews", "check", id]).console.output == "Checked 1 storefront(s): 1 new review(s), 1 stored.")
        let reviews = await harness.run(["reviews", "list", id, "--min-rating", "4"])
        #expect(reviews.console.output.contains("★★★★☆  Handy"))
        #expect(await harness.run(["reviews", "list", id, "--search", "missing"]).console.output.hasSuffix("No reviews match."))
        #expect(await harness.run(["reviews", "list", id, "--country", "XX"]).code == 64)
        #expect(await harness.run(["reviews", "list", id, "--min-rating", "6"]).code == 64)

        let competitors = await harness.run(["competitors", id, "--country", "US"])
        #expect(competitors.code == 0)
        #expect(competitors.console.output.hasPrefix("No measurements yet in US · iphone."))
        #expect(await harness.run(["competitors", id]).code == 64)
        #expect(await harness.run(["--json", "competitors", id, "--country", "US", "--depth", "20"]).console.output.contains("\"depth\" : 20"))
    }
}

extension Engine {
    /// The same data with a search that knows no apps.
    var withoutApps: Engine { Engine(store: store, search: FakeSearch(), suggestions: FakeSuggestions(), reviews: FakeReviews()) }
}
