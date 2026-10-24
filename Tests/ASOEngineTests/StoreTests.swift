import Foundation
import Testing
import ASOCore
@testable import ASOEngine

@Suite("Engine store")
struct StoreTests {
    func sample(_ term: String, _ outcome: RankOutcome, results: [SearchResultApp] = [], at date: Date = Date()) -> RankSample {
        RankSample(keyword: term, storefront: "US", device: .iPhone, provider: .itunesSearch, outcome: outcome, fetchedAt: date, results: results)
    }

    @Test("A new data file gets the whole schema; reopening keeps the data and runs nothing twice")
    func schemaAndReopen() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("nested/engine.sqlite")

        let first = try Store(url: url)
        #expect(try await first.schemaVersion == Store.migrations.count)
        try await first.upsertApp(AppRecord(ownApp, createdAt: Date(timeIntervalSince1970: 100)))

        let reopened = try Store(url: url)
        #expect(try await reopened.schemaVersion == Store.migrations.count)
        #expect(try await reopened.apps().map(\.trackID) == [ownApp.trackID])
    }

    @Test("A data file from a newer version is refused, not rewritten")
    func newerSchemaRefused() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            try db.setUserVersion(Store.migrations.count + 1)
        }
        #expect(throws: EngineError.self) { try Store(url: url) }
    }

    @Test("Upserting an app refreshes its details and keeps when it was added")
    func upsertKeepsCreation() async throws {
        let store = try Store.inMemory()
        try await store.upsertApp(AppRecord(ownApp, createdAt: Date(timeIntervalSince1970: 100)))
        var renamed = AppRecord(ownApp, createdAt: Date(timeIntervalSince1970: 999))
        renamed.name = "Acme Notes 2"
        try await store.upsertApp(renamed)
        let app = try #require(try await store.app(trackID: ownApp.trackID))
        #expect(app.name == "Acme Notes 2")
        #expect(app.createdAt == Date(timeIntervalSince1970: 100))
    }

    @Test("Markets are created once per app, country and device")
    func markets() async throws {
        let store = try Store.inMemory()
        try await store.upsertApp(AppRecord(ownApp, createdAt: Date()))
        let a = try await store.market(appID: ownApp.trackID, countryCode: "us", device: .iPhone)
        let b = try await store.market(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let c = try await store.market(appID: ownApp.trackID, countryCode: "US", device: .iPad)
        #expect(a == b)
        #expect(a.countryCode == "US")
        #expect(a.id != c.id)
        #expect(try await store.markets(appID: ownApp.trackID).count == 2)
    }

    @Test("Keywords are deduplicated by their normalized form and blanks are skipped")
    func keywords() async throws {
        let store = try Store.inMemory()
        try await store.upsertApp(AppRecord(ownApp, createdAt: Date()))
        let market = try await store.market(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let first = try await store.addKeywords(["Budget  Planner", "budget planner", " ", "expense tracker"], marketID: market.id)
        #expect(first.added.map(\.text) == ["Budget  Planner", "expense tracker"])
        #expect(first.added.map(\.normalized) == ["budget planner", "expense tracker"])
        let second = try await store.addKeywords(["BUDGET planner", "savings"], marketID: market.id)
        #expect(second.added.map(\.text) == ["savings"])
        #expect(second.existing == ["BUDGET planner"])
        #expect(try await store.removeKeywords(["Expense Tracker", "unknown"], marketID: market.id) == 1)
        #expect(try await store.keywords(marketID: market.id).map(\.normalized) == ["budget planner", "savings"])
    }

    @Test("Every outcome round-trips, failures included; results are capped and signals use all of them")
    func observations() async throws {
        let store = try Store.inMemory()
        try await store.upsertApp(AppRecord(ownApp, createdAt: Date()))
        let market = try await store.market(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let keyword = try #require(try await store.addKeywords(["notes"], marketID: market.id).added.first)
        let results = (1...60).map { makeApp($0, "Notes \($0)") }
        let outcomes: [RankOutcome] = [.found(position: 7, observedCount: 60), .outsideObservedRange(observedCount: 200),
                                       .requestFailed(reason: "timeout"), .notChecked]
        for (i, outcome) in outcomes.enumerated() {
            try await store.addObservation(sample("notes", outcome, results: i == 0 ? results : [], at: Date(timeIntervalSince1970: Double(i))),
                                           keywordID: keyword.id)
        }
        let stored = try await store.observations(keywordID: keyword.id)
        #expect(stored.map(\.outcome) == outcomes)
        #expect(stored[0].results.count == 50)
        #expect(stored[0].signals?.observedCount == 60)
        #expect(stored[1].results.isEmpty)
        #expect(stored[1].signals == nil)
        #expect(stored[0].provider == .itunesSearch)
    }

    @Test("Removing an app removes its markets, keywords and measurements")
    func cascade() async throws {
        let store = try Store.inMemory()
        try await store.upsertApp(AppRecord(ownApp, createdAt: Date()))
        let market = try await store.market(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        let keyword = try #require(try await store.addKeywords(["notes"], marketID: market.id).added.first)
        try await store.addObservation(sample("notes", .notChecked), keywordID: keyword.id)
        #expect(try await store.removeApp(trackID: ownApp.trackID))
        #expect(try await store.removeApp(trackID: ownApp.trackID) == false)
        #expect(try await store.markets(appID: ownApp.trackID).isEmpty)
        #expect(try await store.keywords(marketID: market.id).isEmpty)
        #expect(try await store.observations(keywordID: keyword.id).isEmpty)
    }
}
