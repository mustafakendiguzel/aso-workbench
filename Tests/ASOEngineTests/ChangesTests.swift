import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Release markers and impact")
struct ChangesTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func release(_ version: String, on date: Date?) -> SearchResultApp {
        SearchResultApp(trackID: ownApp.trackID, bundleID: ownApp.bundleID, name: ownApp.name, sellerName: ownApp.sellerName, iconURL: nil,
                        averageRating: 4.5, ratingCount: 100, primaryGenre: "Productivity", releaseDate: nil, currentVersionReleaseDate: date,
                        price: 0, version: version)
    }

    func engine(showing app: SearchResultApp, on store: Store) -> Engine {
        Engine(store: store, search: FakeSearch(apps: [app.trackID: app]), suggestions: FakeSuggestions(), reviews: FakeReviews())
    }

    /// Stores a measurement of `keyword` in the US iPhone market at `date`: found at `position`, else outside the top `depth`.
    func observe(_ keyword: String, _ position: Int?, at date: Date, engine: Engine, depth: Int = 200) async throws {
        let market = try await engine.store.market(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let id = try #require(try await engine.store.keyword(keyword, marketID: market.id)).id
        let outcome: RankOutcome = position.map { .found(position: $0, observedCount: depth) } ?? .outsideObservedRange(observedCount: depth)
        try await engine.store.addObservation(RankSample(keyword: keyword, storefront: "US", device: .iPhone, provider: .itunesSearch,
                                                         outcome: outcome, fetchedAt: date, results: []), keywordID: id)
    }

    @Test("A data file from schema 3 gains markers and keeps its apps")
    func migrationFromSchemaThree() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(3) { try db.execute(step) }
            try db.setUserVersion(3)
            try db.execute("INSERT INTO apps (track_id, name, seller_name, store_version, created_at) VALUES (42, 'Old App', 'Old Seller', '3.1', 0)")
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == 4)
        #expect(try await store.app(trackID: 42)?.storeVersion == "3.1")
        // The first look records the current release even though the app already knew its version.
        #expect(try await store.recordRelease(version: "3.1", date: start, countryCode: "US", appID: 42)?.title == "v3.1")
        try await store.removeApp(trackID: 42)
        #expect(try await store.markers(appID: 42).isEmpty)
    }

    @Test("The first look records the current release; a new version records another; a removed one stays removed")
    func releases() async throws {
        let base = try makeEngine()
        _ = try await base.addApp(reference: String(ownApp.trackID), lookupCountry: nil, markets: ["US"], device: .iPhone)
        let shipped = start.addingTimeInterval(-86_400)

        let first = try await engine(showing: release("1.0", on: shipped), on: base.store).checkRatings(appID: ownApp.trackID)
        #expect(first.newRelease?.title == "v1.0")
        #expect(first.newRelease?.date == shipped)
        #expect(first.newRelease?.country == "US")
        #expect(try await engine(showing: release("1.0", on: shipped), on: base.store).checkRatings(appID: ownApp.trackID).newRelease == nil)

        // No release date from Apple: the check's time stands in.
        let second = try await engine(showing: release("1.1", on: nil), on: base.store).checkRatings(appID: ownApp.trackID) { start }
        #expect(second.newRelease?.title == "v1.1")
        #expect(second.newRelease?.date == start)
        #expect(try await base.app(ownApp.trackID).storeVersion == "1.1")

        let markers = try await base.markers(appID: ownApp.trackID)
        #expect(markers.map(\.title) == ["v1.1", "v1.0"])
        try await base.removeMarker(appID: ownApp.trackID, id: markers[0].id)
        #expect(try await engine(showing: release("1.1", on: nil), on: base.store).checkRatings(appID: ownApp.trackID).newRelease == nil)
        #expect(try await base.markers(appID: ownApp.trackID).map(\.title) == ["v1.0"])

        // Measuring looks first, so its measurements land after the marker.
        let measuring = engine(showing: release("1.2", on: start), on: base.store)
        _ = try await measuring.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        _ = try await measuring.measure(appID: ownApp.trackID)
        #expect(try await base.markers(appID: ownApp.trackID).map(\.title) == ["v1.2", "v1.0"])
    }

    @Test("Notes need a title and a date that has passed; removing checks the app")
    func notes() async throws {
        let engine = try makeEngine()
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        let note = try await engine.addNote(appID: ownApp.trackID, title: "  New screenshots ", date: start, now: start)
        #expect(note.title == "New screenshots")
        #expect(note.kind == "note")
        #expect(note.version == nil)
        let later = try await engine.addNote(appID: ownApp.trackID, title: "Keywords updated", now: start.addingTimeInterval(60))
        #expect(later.date == start.addingTimeInterval(60))
        #expect(try await engine.markers(appID: ownApp.trackID).map(\.title) == ["Keywords updated", "New screenshots"])

        await #expect(throws: EngineError.self) { try await engine.addNote(appID: ownApp.trackID, title: "  ", now: start) }
        await #expect(throws: EngineError.self) {
            try await engine.addNote(appID: ownApp.trackID, title: "Tomorrow", date: start.addingTimeInterval(3600), now: start)
        }
        await #expect(throws: EngineError.self) { try await engine.addNote(appID: 99, title: "Other app", now: start) }
        await #expect(throws: EngineError.self) { try await engine.removeMarker(appID: ownApp.trackID, id: 999) }
        await #expect(throws: EngineError.self) { try await engine.removeMarker(appID: 99, id: note.id) }
        try await engine.removeMarker(appID: ownApp.trackID, id: note.id)
        #expect(try await engine.markers(appID: ownApp.trackID).map(\.title) == ["Keywords updated"])
    }

    @Test("Δ since the last marker compares the last rank before it with the latest after it")
    func deltaSinceLastMarker() async throws {
        let engine = try makeEngine()
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        try await observe("notes", 30, at: start, engine: engine)
        try await observe("notes", 20, at: start.addingTimeInterval(3600), engine: engine)
        try await observe("notes", 12, at: start.addingTimeInterval(7200), engine: engine)

        let none = try await engine.keywordReport(appID: ownApp.trackID, deltaReference: .lastMarker)[0]
        #expect(none.delta == 18)
        #expect(none.deltaAgainst == "first measurement (no release or change recorded)")

        _ = try await engine.addNote(appID: ownApp.trackID, title: "Keywords updated", date: start.addingTimeInterval(5400), now: start.addingTimeInterval(9000))
        let row = try await engine.keywordReport(appID: ownApp.trackID, deltaReference: .lastMarker)[0]
        #expect(row.delta == 8)
        #expect(row.deltaAgainst.hasPrefix("Keywords updated"))
        let detail = try await engine.keywordDetail("notes", appID: ownApp.trackID, countryCode: "US", device: .iPhone, deltaReference: .lastMarker)
        #expect(detail.row.delta == 8)
    }

    @Test("Impact compares each keyword around the marker; without popularity every keyword is worth nothing")
    func impact() async throws {
        let engine = try makeEngine()
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(["notes", "journal", "diary", "planner"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let marker = try await engine.addNote(appID: ownApp.trackID, title: "Release", date: start, now: start.addingTimeInterval(86_400))
        let before = start.addingTimeInterval(-3600)
        let after = start.addingTimeInterval(3600)
        try await observe("notes", 40, at: before, engine: engine)
        try await observe("notes", 9, at: after, engine: engine)
        try await observe("journal", 5, at: before, engine: engine)
        try await observe("journal", nil, at: after, engine: engine)
        try await observe("diary", 7, at: before, engine: engine)
        try await observe("diary", 7, at: after, engine: engine)
        try await observe("planner", 3, at: after, engine: engine)   // nothing before the marker: not compared

        let report = try await engine.impact(appID: ownApp.trackID, markerID: marker.id)
        #expect(report.marker == marker)
        #expect(report.rows.map(\.keyword) == ["journal", "notes", "diary"])   // biggest move first when nothing has value
        #expect(report.improved == 1)
        #expect(report.worsened == 1)
        #expect(report.same == 1)
        #expect(report.net == 0)
        let journal = report.rows[0]
        #expect(journal.before == 5)
        #expect(journal.after == nil)
        #expect(journal.delta == -196)   // outside the top 200 counts as 201
        #expect(journal.beforeAt == before)
        #expect(journal.afterAt == after)
        #expect(journal.value == 0)
        #expect(journal.tier == "None")
        #expect(report.rows[1].delta == 31)

        await #expect(throws: EngineError.self) { try await engine.impact(appID: ownApp.trackID, markerID: 999) }
    }

    @Test("The commands add, list, remove and compare, with JSON for front ends")
    func commands() async throws {
        let harness = try Harness()
        let id = String(ownApp.trackID)
        #expect(await harness.run(["app", "add", id]).code == 0)
        #expect(await harness.run(["markers", "list", id]).console.output.hasPrefix("Nothing on the timeline yet."))

        let added = await harness.run(["--json", "markers", "add", id, "--title", "Keywords updated", "--date", "2025-10-20"])
        #expect(added.code == 0)
        #expect(added.console.output.contains("\"date\" : \"2025-10-20T00:00:00Z\""))
        #expect(added.console.output.contains("\"kind\" : \"note\""))
        #expect(await harness.run(["markers", "add", id, "--title", "Later", "--date", "2025-10-20T14:30:00+02:00"]).code == 0)
        #expect(await harness.run(["markers", "add", id, "--title", "Bad", "--date", "20.10.2026"]).code == 64)
        #expect(await harness.run(["markers", "add", id]).code == 64)

        let list = await harness.run(["markers", "list", id])
        #expect(list.console.output.contains("Keywords updated"))
        #expect(list.console.output.contains("aso impact \(id) <marker ID>"))

        let impact = await harness.run(["impact", id, "1"])
        #expect(impact.code == 0)
        #expect(impact.console.output.contains("No keyword has a measurement both before and after it."))
        #expect(await harness.run(["--json", "impact", id, "1"]).console.output.contains("\"improved\" : 0"))
        #expect(await harness.run(["impact", id, "9"]).code == 1)
        #expect(await harness.run(["impact", id]).code == 64)

        #expect(await harness.run(["markers", "remove", id, "1"]).console.output == "Removed marker 1.")
        #expect(await harness.run(["markers", "remove", id, "1"]).code == 1)
    }
}
