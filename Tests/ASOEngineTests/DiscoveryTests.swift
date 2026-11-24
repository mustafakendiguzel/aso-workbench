import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Keyword discovery")
struct DiscoveryTests {
    let hints = FakeSuggestions(hints: ["notes": ["notes app", "notes widget", "notion", "notes", "ok"], "acme": ["acme notes"]])
    /// Weak rivals, so the measured terms come out easy.
    let rivals = (1...10).map { makeApp(2_000 + $0, "Rival \($0)", ratings: 5) }

    var search: FakeSearch {
        FakeSearch(results: ["notes app": rivals, "notes widget": rivals, "sticky notes": rivals], apps: [ownApp.trackID: ownApp])
    }

    var popularity: FakePopularity {
        FakePopularity(lists: [.productivityUtilities: ["notes app": 55, "notes widget": 40, "notion": 80, "sticky notes": 35, "notes": 62]],
                       suggestions: ["notes": ["sticky notes", "Notes App"]])
    }

    func tracked(popularity: FakePopularity? = nil, judge: FakeJudge? = nil, search: FakeSearch? = nil) async throws -> Engine {
        let engine = try makeEngine(search: search ?? self.search, hints: hints, popularity: popularity, judge: judge)
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(["notes"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        return engine
    }

    @Test("Without keys: autocomplete around the tracked keywords and title words, nothing judged or measured")
    func withoutKeys() async throws {
        let engine = try await tracked()
        let report = try await engine.discover(appID: ownApp.trackID, countryCode: "us")
        #expect(report.market == "US · iphone")
        #expect(report.seeds == ["notes", "acme", "acme notes"])
        #expect((report.appleAds, report.jev) == (false, false))
        #expect(report.candidates.map(\.keyword).sorted() == ["acme notes", "notes", "notes app", "notes widget", "notion"])   // "ok" is too short
        #expect(report.candidates.first { $0.keyword == "notes" }?.tracked == true)
        #expect(report.candidates.allSatisfy { $0.popularity == nil && $0.popularitySource == nil && $0.difficulty == nil && !$0.golden })
        #expect(report.measured == 0)
        #expect(try await engine.store.keywords(marketID: 1).count == 1)   // nothing is stored
    }

    @Test("With Apple Ads and Jev: brands are dropped, fit decides golden or lead, difficulty goes to the most popular")
    func withKeys() async throws {
        let judge = FakeJudge(brands: ["notion"], unfit: ["notes widget"])
        let engine = try await tracked(popularity: popularity, judge: judge)
        let steps = Lines()
        let report = try await engine.discover(appID: ownApp.trackID, countryCode: "US", difficultyLimit: 2) { steps.add($0.step) }
        #expect((report.appleAds, report.jev) == (true, true))
        let byKeyword = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.keyword, $0) })

        let sticky = try #require(byKeyword["sticky notes"])
        #expect(sticky.sources == ["ads suggestion"])
        #expect(sticky.difficulty == nil)   // third by popularity, the limit is two
        #expect(byKeyword["notes app"]?.sources == ["autocomplete", "ads suggestion"])
        #expect(byKeyword["notion"]?.brand == 0.9)
        #expect(byKeyword["notion"]?.difficulty == nil)   // brands are never golden, so never measured
        #expect(byKeyword["acme notes"]?.popularitySource == "belowRange")
        #expect(byKeyword["notes"]?.difficulty == nil)    // already tracked
        #expect(judge.fitChecks == ["notes", "notes app", "notes widget", "sticky notes"])

        let app = try #require(byKeyword["notes app"])
        let widget = try #require(byKeyword["notes widget"])
        let easy = try #require(app.difficulty)
        #expect(easy <= 45)
        #expect(app.golden)
        #expect(!widget.golden && widget.goldenLead)
        #expect(app.opportunity == Opportunity.score(popularity: 55, difficulty: easy))
        #expect(report.candidates.first?.keyword == "notes app")
        #expect(report.measured == 2)
        #expect(report.golden == 1)
        #expect(report.withPopularity == 5)
        #expect(steps.all.contains("Jev: fit against the app (4)"))
    }

    @Test("A competitor's title and description are mined, and its title words become the seeds")
    func competitor() async throws {
        let rival = SearchResultApp(trackID: 3_000_001, bundleID: nil, name: "Rival Journal Diary", sellerName: "Rival Co", iconURL: nil, averageRating: 4,
                                    ratingCount: 900, primaryGenre: "Productivity", releaseDate: nil, currentVersionReleaseDate: nil, price: 0,
                                    version: "1.0", storeDescription: "Write your daily journal. Journal prompts and a private diary.")
        let engine = try await tracked(search: FakeSearch(apps: [ownApp.trackID: ownApp, rival.trackID: rival]))
        let report = try await engine.discover(appID: ownApp.trackID, countryCode: "US", competitorID: rival.trackID)
        #expect(report.competitor == "Rival Journal Diary")
        #expect(report.seeds == ["diary", "journal", "rival", "journal diary", "rival journal"])
        let journal = try #require(report.candidates.first { $0.keyword == "journal" })
        #expect(journal.sources == ["competitor title", "competitor description"])
        #expect(report.candidates.contains { $0.keyword == "journal prompts" && $0.sources == ["competitor description"] })

        await #expect(throws: EngineError.self) { try await engine.discover(appID: ownApp.trackID, countryCode: "US", competitorID: 42) }
        await #expect(throws: EngineError.self) { try await engine.discover(appID: ownApp.trackID, countryCode: "DE") }   // no such market
        await #expect(throws: EngineError.self) { try await engine.discover(appID: ownApp.trackID, countryCode: "US", seeds: [" "]) }
    }

    @Test("The command prints the candidates, JSON for front ends with JSON Lines progress, and checks its options")
    func commands() async throws {
        let harness = try Harness(hints: hints)
        let id = String(ownApp.trackID)
        #expect(await harness.run(["app", "add", id]).code == 0)
        #expect(await harness.run(["keywords", "add", id, "notes", "--country", "US"]).code == 0)

        let text = await harness.run(["discover", id, "--country", "US"])
        #expect(text.code == 0)
        #expect(text.console.output.hasPrefix("Discovery in US · iphone · seeds: notes, acme, acme notes\n5 candidate(s)"))
        #expect(text.console.output.contains("Apple Ads is not connected"))
        #expect(text.console.output.contains("OpenRouter is not connected"))
        #expect(text.console.errors.contains("[1/3] Autocomplete \"notes\""))

        let json = await harness.run(["--json", "discover", id, "--country", "US", "--seeds", "acme"])
        #expect(json.console.output.contains("\"seeds\" : [\n    \"acme\"\n  ]"))
        #expect(json.console.errors.contains("{\"completed\":0,\"step\":\"Autocomplete \\\"acme\\\"\",\"total\":1}"))

        #expect(await harness.run(["discover", id]).code == 64)
        #expect(await harness.run(["discover", id, "--country", "US", "--competitor", "not a link"]).code == 64)
        #expect(await harness.run(["discover", id, "--country", "US", "--difficulty", "99"]).code == 64)
    }
}
