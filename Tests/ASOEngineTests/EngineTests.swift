import Foundation
import Testing
import ASOCore
@testable import ASOEngine

@Suite("Engine")
struct EngineTests {
    @Test("Adding an app resolves an App Store link or a bare ID")
    func addApp() async throws {
        let engine = try makeEngine()
        let byLink = try await engine.addApp(reference: "https://apps.apple.com/tr/app/acme-notes/id\(ownApp.trackID)?l=en")
        #expect(byLink.name == "Acme Notes")
        let byID = try await engine.addApp(reference: String(ownApp.trackID), countryCode: "DE")
        #expect(byID.createdAt == byLink.createdAt)
        #expect(try await engine.store.apps().count == 1)
    }

    @Test("Bad input and unknown apps are reported, not stored")
    func addAppErrors() async throws {
        let engine = try makeEngine()
        await #expect(throws: EngineError.self) { try await engine.addApp(reference: "notes app") }
        await #expect(throws: EngineError.notFound("No app with ID 999999999 in the United States App Store.")) {
            try await engine.addApp(reference: "999999999")
        }
        await #expect(throws: EngineError.self) { try await engine.addApp(reference: String(ownApp.trackID), countryCode: "XX") }
        #expect(try await engine.store.apps().isEmpty)
    }

    @Test("Keywords need a tracked app and a known country")
    func keywordPreconditions() async throws {
        let engine = try makeEngine()
        await #expect(throws: EngineError.self) {
            try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        }
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        await #expect(throws: EngineError.self) {
            try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "ZZ", device: .iPhone)
        }
        let added = try await engine.addKeywords(["notes", "Notes", "journal"], appID: ownApp.trackID, countryCode: "us", device: .iPhone)
        #expect(added == .init(market: "US · iphone", added: ["notes", "journal"], alreadyTracked: []))
    }

    @Test("Measuring stores found, outside and failed outcomes and reports progress")
    func measure() async throws {
        let rivals = (1...30).map { makeApp($0, "Rival \($0)") }
        var search = FakeSearch(apps: [ownApp.trackID: ownApp])
        search.results["notes"] = Array(rivals.prefix(4)) + [ownApp] + Array(rivals.dropFirst(4))
        search.results["journal"] = rivals
        search.failing = ["diary"]
        let engine = try makeEngine(search: search)
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(["notes", "journal", "diary"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)

        let steps = Steps()
        let summary = try await engine.measure(appID: ownApp.trackID) { steps.append($0) }
        #expect(summary == .init(measured: 3, found: 1, outside: 1, failed: 1))
        #expect(steps.all.map(\.completed) == [1, 2, 3])
        #expect(steps.all.allSatisfy { $0.total == 3 && $0.market == "US · iphone" })

        let rows = try await engine.keywordReport(appID: ownApp.trackID)
        let notes = try #require(rows.first { $0.keyword == "notes" })
        #expect(notes.status == "found")
        #expect(notes.rank == 5)
        #expect(notes.rankLabel == "#5")
        #expect(notes.observedCount == 31)
        #expect(notes.difficulty != nil)
        #expect(notes.popularity == nil)       // no popularity source yet: absent, never guessed
        #expect(notes.golden == false)
        let journal = try #require(rows.first { $0.keyword == "journal" })
        #expect(journal.status == "outside")
        #expect(journal.rank == nil)
        #expect(journal.rankLabel == "> 30")
        let diary = try #require(rows.first { $0.keyword == "diary" })
        #expect(diary.status == "failed")
        #expect(diary.failure != nil)
        #expect(diary.difficulty == nil)
    }

    @Test("Δ compares measurements; a failed retry keeps the last known rank")
    func deltaAndRetry() async throws {
        var search = FakeSearch(apps: [ownApp.trackID: ownApp])
        let rivals = (1...20).map { makeApp($0, "Rival \($0)") }
        search.results["notes"] = Array(rivals.prefix(9)) + [ownApp]
        let engine = try makeEngine(search: search)
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        _ = try await engine.measure(appID: ownApp.trackID)

        let climbing = try makeEngineSharing(engine, results: ["notes": Array(rivals.prefix(2)) + [ownApp]])
        _ = try await climbing.measure(appID: ownApp.trackID)
        var row = try #require(try await engine.keywordReport(appID: ownApp.trackID).first)
        #expect(row.rank == 3)
        #expect(row.delta == 7)

        let offline = Engine(store: engine.store, search: FakeSearch(failing: ["notes"]), suggestions: FakeSuggestions(), reviews: FakeReviews())
        _ = try await offline.measure(appID: ownApp.trackID)
        row = try #require(try await engine.keywordReport(appID: ownApp.trackID).first)
        #expect(row.status == "failed")
        #expect(row.rankLabel == "Error")
        #expect(row.rank == 3)
        #expect(row.delta == 7)
    }

    @Test("Filters pick markets by country and device")
    func filters() async throws {
        let engine = try makeEngine()
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        _ = try await engine.addKeywords(["notizen"], appID: ownApp.trackID, countryCode: "DE", device: .iPhone)
        _ = try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPad)
        #expect(try await engine.keywordReport(appID: ownApp.trackID).count == 3)
        #expect(try await engine.keywordReport(appID: ownApp.trackID, countryCode: "de").map(\.keyword) == ["notizen"])
        #expect(try await engine.keywordReport(appID: ownApp.trackID, device: .iPad).map(\.device) == ["ipad"])
        #expect(try await engine.keywordReport(appID: ownApp.trackID).first?.status == "notMeasured")
    }

    @Test("Ad-hoc lookups store nothing")
    func adHoc() async throws {
        var search = FakeSearch()
        search.results["habit tracker"] = (1...12).map { makeApp($0, "Habit Tracker \($0)", ratings: 50_000) }
        let engine = try makeEngine(search: search, hints: FakeSuggestions(hints: ["hab": ["habit tracker", "habit"]]))
        #expect(try await engine.searchResults(term: "habit tracker", countryCode: "US", device: .iPhone, limit: 5).count == 5)
        #expect(try await engine.hints(seed: "hab", countryCode: "US") == ["habit tracker", "habit"])
        let score = try #require(try await engine.difficulty(term: "habit tracker", countryCode: "US", device: .iPhone))
        #expect(score.score > 0)
        #expect(try await engine.difficulty(term: "nothing", countryCode: "US", device: .iPhone) == nil)
        #expect(try await engine.store.apps().isEmpty)
    }

    func makeEngineSharing(_ engine: Engine, results: [String: [SearchResultApp]]) throws -> Engine {
        Engine(store: engine.store, search: FakeSearch(results: results, apps: [ownApp.trackID: ownApp]), suggestions: FakeSuggestions(), reviews: FakeReviews())
    }
}

/// Collects progress steps from the engine's `@Sendable` callback.
final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Engine.MeasureProgress] = []
    func append(_ step: Engine.MeasureProgress) { lock.lock(); steps.append(step); lock.unlock() }
    var all: [Engine.MeasureProgress] { lock.lock(); defer { lock.unlock() }; return steps }
}
