import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Apple Ads popularity")
struct PopularityTests {
    /// 2027-01-15: the scores describe December 2026, the last full month.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let december = Date(timeIntervalSince1970: 1_796_083_200)   // 2026-12-01T00:00:00Z

    /// The Productivity & Utilities list: "notes" and "journal" on it, 31 its lowest score.
    var productivity: FakePopularity {
        FakePopularity(lists: [.productivityUtilities: ["notes": 62, "journal": 45, "calendar": 90, "memo pad": 31]], now: now)
    }

    func tracked(_ keywords: [String], popularity: FakePopularity?, search: FakeSearch = FakeSearch(apps: [ownApp.trackID: ownApp])) async throws -> Engine {
        let engine = try makeEngine(search: search, popularity: popularity)
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(keywords, appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        return engine
    }

    @Test("A data file from schema 4 gains popularity readings and keeps its keywords")
    func migrationFromSchemaFour() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(4) { try db.execute(step) }
            try db.setUserVersion(4)
            try db.execute("INSERT INTO apps (track_id, name, seller_name, created_at) VALUES (42, 'Old App', 'Old Seller', 0)")
            try db.execute("INSERT INTO markets (app_id, country_code, device, created_at) VALUES (42, 'US', 'iphone', 0)")
            try db.execute("INSERT INTO keywords (market_id, text, normalized, created_at) VALUES (1, 'Notes', 'notes', 0)")
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
        let keyword = try #require(try await store.keyword("notes", marketID: 1))
        #expect(try await store.latestPopularity(keywordID: keyword.id) == nil)
    }

    @Test("The app's genre list scores the terms on it; the rest are below its lowest score")
    func refreshWithGenre() async throws {
        let engine = try await tracked(["Notes", "journal", "rare idea"], popularity: productivity)
        let refreshes = try await engine.refreshPopularity(appID: ownApp.trackID, now: now)
        #expect(refreshes == [Engine.PopularityRefresh(country: "US", genre: "PRODUCTIVITY_UTILITIES", periodStart: december,
                                                       periodEnd: december.addingTimeInterval(30 * 86_400), keywords: 3, onList: 2,
                                                       belowRange: 1, floor: 31, genresFound: [])])

        let rows = Dictionary(uniqueKeysWithValues: try await engine.keywordReport(appID: ownApp.trackID).map { ($0.keyword, $0) })
        let notes = try #require(rows["Notes"])
        #expect(notes.popularity == 62)
        #expect(notes.popularitySource == "list")
        #expect(notes.popularityGenre == "PRODUCTIVITY_UTILITIES")
        #expect(notes.popularityMonth == december)
        let rare = try #require(rows["rare idea"])
        #expect(rare.popularity == nil)
        #expect(rare.popularitySource == "belowRange")
        #expect(rare.popularityBelow == 31)

        let csv = KeywordCSV.render(try await engine.keywordReport(appID: ownApp.trackID))
        #expect(csv.contains("Notes,US,iphone,,0,,62,apple_ads_country_list,PRODUCTIVITY_UTILITIES,"))
        #expect(csv.contains("rare idea,US,iphone,,0,,,below_published_range_lt_31,,"))
    }

    @Test("Without a genre every list is read and each term keeps its highest score")
    func refreshAcrossGenres() async throws {
        let lists: [AppleAdsGenre: [String: Int]] = [.business: ["notes": 40, "invoice": 70], .education: ["notes": 55, "journal": 33]]
        let engine = try await tracked(["notes", "journal", "rare idea"], popularity: FakePopularity(lists: lists, now: now))
        _ = try await engine.setAdsGenre(appID: ownApp.trackID, genre: nil)
        let steps = Lines()
        let refresh = try #require(try await engine.refreshPopularity(appID: ownApp.trackID, now: now) { steps.add($0) }.first)
        #expect(refresh.genre == nil)
        #expect(refresh.onList == 2)
        #expect(refresh.genresFound == ["Education"])
        #expect(refresh.floor == 33)   // the floor comes from the genre most terms were found in
        #expect(steps.all.first == "US: the Business list (1 of 15)")

        let notes = try #require(try await engine.keywordReport(appID: ownApp.trackID).first { $0.keyword == "notes" })
        #expect(notes.popularity == 55)
        #expect(notes.popularityGenre == "EDUCATION")
    }

    @Test("Popularity feeds golden, opportunity and the value in impact; earlier readings are kept")
    func popularityFeedsVerdicts() async throws {
        let rivals = (1...10).map { makeApp($0, "Rival \($0)", ratings: 10) }
        let engine = try await tracked(["notes"], popularity: productivity, search: FakeSearch(results: ["notes": rivals], apps: [ownApp.trackID: ownApp]))
        _ = try await engine.refreshPopularity(appID: ownApp.trackID, now: now)
        let marker = try await engine.addNote(appID: ownApp.trackID, title: "Keywords updated", date: now, now: now.addingTimeInterval(7200))
        let market = try await engine.store.market(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let id = try #require(try await engine.store.keyword("notes", marketID: market.id)).id
        for (offset, position) in [(-3600.0, 30), (3600.0, 4)] {
            try await engine.store.addObservation(RankSample(keyword: "notes", storefront: "US", device: .iPhone, provider: .itunesSearch,
                                                             outcome: .found(position: position, observedCount: 200),
                                                             fetchedAt: now.addingTimeInterval(offset), results: rivals), keywordID: id)
        }

        let row = try #require(try await engine.keywordReport(appID: ownApp.trackID).first)
        #expect(row.popularity == 62)
        #expect(row.opportunity != nil)
        #expect(row.golden == ((row.difficulty ?? 100) <= 45))
        let impact = try await engine.impact(appID: ownApp.trackID, markerID: marker.id)
        #expect(impact.rows.first?.value ?? 0 > 0)
        #expect(impact.net > 0)

        // A later month where the term fell off the list: the newest reading wins.
        let later = FakePopularity(lists: [.productivityUtilities: ["calendar": 88, "memo pad": 35]], now: now)
        let next = Engine(store: engine.store, search: engine.search, suggestions: engine.suggestions, reviews: engine.reviews, popularity: later)
        _ = try await next.refreshPopularity(appID: ownApp.trackID, now: now.addingTimeInterval(60))
        let fallen = try #require(try await engine.keywordReport(appID: ownApp.trackID).first)
        #expect(fallen.popularity == nil)
        #expect(fallen.popularityBelow == 35)
    }

    @Test("Measuring refreshes the measured keywords' popularity when Apple Ads is connected")
    func measureRefreshes() async throws {
        let connected = try await tracked(["notes", "journal"], popularity: productivity)
        let summary = try await connected.measure(appID: ownApp.trackID, keywords: ["notes"])
        #expect(summary.measured == 1)
        #expect(summary.popularity?.first?.keywords == 1)
        let rows = try await connected.keywordReport(appID: ownApp.trackID)
        #expect(rows.first { $0.keyword == "notes" }?.popularity == 62)
        #expect(rows.first { $0.keyword == "journal" }?.popularitySource == nil)

        var down = productivity
        down.failing = true
        let failing = try await tracked(["notes"], popularity: down)
        let kept = try await failing.measure(appID: ownApp.trackID)
        #expect(kept.measured == 1)
        #expect(kept.popularity == nil)
        #expect(kept.popularityError != nil)

        let unconnected = try await tracked(["notes"], popularity: nil)
        #expect(try await unconnected.measure(appID: ownApp.trackID).popularity == nil)
        await #expect(throws: EngineError.self) { try await unconnected.refreshPopularity(appID: ownApp.trackID) }
        await #expect(throws: EngineError.self) { try await connected.refreshPopularity(appID: ownApp.trackID, keywords: ["unknown"]) }
    }

    @Test("The command reads popularity, the keyword list shows it, and without keys it says how to connect")
    func commands() async throws {
        let harness = try Harness(popularity: productivity)
        let id = String(ownApp.trackID)
        #expect(await harness.run(["app", "add", id]).code == 0)
        #expect(await harness.run(["keywords", "add", id, "notes", "rare idea", "--country", "US"]).code == 0)

        let text = await harness.run(["popularity", id])
        #expect(text.code == 0)
        #expect(text.console.output.hasPrefix("US: 1 of 2 keyword(s) on Apple's list (Productivity & Utilities, "))
        #expect(text.console.output.hasSuffix("; 1 below the published range (under 31)."))
        #expect(text.console.errors.contains("Reading US: the Productivity & Utilities list"))

        let json = await harness.run(["--json", "popularity", id, "--keywords", "notes"])
        #expect(json.console.output.contains("\"onList\" : 1"))
        #expect(json.console.errors.isEmpty)

        let list = await harness.run(["keywords", "list", id])
        #expect(list.console.output.contains("< 31"))
        #expect(list.console.output.contains("62"))
        #expect(await harness.run(["popularity"]).code == 64)

        let unconnected = try Harness()
        #expect(await unconnected.run(["app", "add", id]).code == 0)
        let refused = await unconnected.run(["popularity", id])
        #expect(refused.code == 1)
        #expect(refused.console.errors.contains("aso connections set apple-ads"))
    }
}

/// Progress lines collected from a @Sendable callback.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
