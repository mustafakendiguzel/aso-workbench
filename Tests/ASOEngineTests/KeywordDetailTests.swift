import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Keyword detail, notes, selective measuring and CSV")
struct KeywordDetailTests {
    func trackedEngine(results: [String: [SearchResultApp]]) async throws -> Engine {
        var search = FakeSearch(apps: [ownApp.trackID: ownApp])
        search.results = results
        let engine = try makeEngine(search: search)
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addKeywords(Array(results.keys), appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        return engine
    }

    @Test("Measuring only chosen keywords, and refusing ones that are not tracked")
    func selective() async throws {
        let engine = try await trackedEngine(results: ["notes": [ownApp], "journal": [ownApp], "diary": [ownApp]])
        let steps = Steps()
        let summary = try await engine.measure(appID: ownApp.trackID, keywords: ["Notes", "diary"]) { steps.append($0) }
        #expect(summary.measured == 2)
        #expect(Set(steps.all.map(\.keyword)) == ["notes", "diary"])
        await #expect(throws: EngineError.notFound("\"planner\" is not tracked in the chosen market(s).")) {
            try await engine.measure(appID: ownApp.trackID, keywords: ["notes", "planner"])
        }
    }

    @Test("The detail has the history, the best rank, the latest top ten with our app marked, and the difficulty")
    func detail() async throws {
        let rivals = (1...12).map { makeApp($0, "Notes Rival \($0)", ratings: 1_000 * $0) }
        let engine = try await trackedEngine(results: ["notes": Array(rivals.prefix(6)) + [ownApp] + Array(rivals.dropFirst(6))])
        _ = try await engine.measure(appID: ownApp.trackID)
        let deeper = Engine(store: engine.store, search: FakeSearch(results: ["notes": rivals]), suggestions: FakeSuggestions(), reviews: FakeReviews())
        _ = try await deeper.measure(appID: ownApp.trackID)

        let detail = try await engine.keywordDetail("NOTES", appID: ownApp.trackID, countryCode: "us", device: .iPhone)
        #expect(detail.observations.map(\.status) == ["found", "outside"])
        #expect(detail.observations.map(\.label) == ["#7", "> 12"])
        #expect(detail.summary == .init(latest: nil, best: 7, measurements: 2, outside: 1))
        #expect(detail.topResults.count == 10)
        #expect(detail.topResults.allSatisfy { !$0.isOwnApp })   // the latest top ten no longer has our app
        #expect(detail.row.titleMatchesTop10 == 10)
        #expect(detail.row.ratingMass != nil)
        #expect(detail.difficulty?.components.count == 7)

        let first = try await engine.keywordDetail("notes", appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        #expect(first.row.provider == "fake-search")
        await #expect(throws: EngineError.self) { try await engine.keywordDetail("planner", appID: ownApp.trackID, countryCode: "US", device: .iPhone) }
        await #expect(throws: EngineError.self) { try await engine.keywordDetail("notes", appID: ownApp.trackID, countryCode: "DE", device: .iPhone) }
    }

    @Test("Our own app is starred in the top results")
    func ownAppMarked() async throws {
        let engine = try await trackedEngine(results: ["notes": [makeApp(5, "Rival"), ownApp]])
        _ = try await engine.measure(appID: ownApp.trackID)
        let detail = try await engine.keywordDetail("notes", appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        #expect(detail.topResults.map(\.isOwnApp) == [false, true])
        #expect(detail.summary.latest == 2)
    }

    @Test("Notes are saved trimmed, shown in reports and cleared by an empty note")
    func notes() async throws {
        let engine = try await trackedEngine(results: ["notes": []])
        try await engine.setNote("  Push in the subtitle  ", keyword: "Notes", appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        #expect(try await engine.keywordReport(appID: ownApp.trackID).first?.note == "Push in the subtitle")
        try await engine.setNote("", keyword: "notes", appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        #expect(try await engine.keywordReport(appID: ownApp.trackID).first?.note == "")
        await #expect(throws: EngineError.self) {
            try await engine.setNote("x", keyword: "planner", appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        }
    }

    @Test("CSV keeps the macOS columns and escapes fields")
    func csv() async throws {
        #expect(KeywordCSV.escape("plain") == "plain")
        #expect(KeywordCSV.escape("a,b") == "\"a,b\"")
        #expect(KeywordCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(KeywordCSV.escape("two\nlines") == "\"two\nlines\"")

        let engine = try await trackedEngine(results: ["notes, quick": [makeApp(5, "Rival"), ownApp]])
        _ = try await engine.measure(appID: ownApp.trackID)
        let csv = KeywordCSV.render(try await engine.keywordReport(appID: ownApp.trackID))
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == KeywordCSV.header)
        #expect(lines[0].split(separator: ",").count == 16)
        #expect(lines[1].hasPrefix("\"notes, quick\",US,iphone,2,2,,,unavailable,,"))
        #expect(lines[1].hasSuffix(",fake-search"))
    }

    @Test("The command line: show, note, measure --keywords and list --csv")
    func commands() async throws {
        var search = FakeSearch(apps: [ownApp.trackID: ownApp])
        search.results = ["notes": [makeApp(5, "Rival"), ownApp], "journal": []]
        let harness = try Harness(search: search)
        let id = String(ownApp.trackID)
        _ = await harness.run(["app", "add", id])
        _ = await harness.run(["keywords", "add", id, "notes", "journal", "--country", "US"])

        let measured = await harness.run(["measure", id, "--keywords", "notes"])
        #expect(measured.console.output == "Measured 1: 1 ranked, 0 outside the results, 0 failed.")
        #expect(await harness.run(["measure", id, "--keywords", " , "]).code == CommandRunner.ExitCode.usage)

        #expect(await harness.run(["keywords", "note", id, "notes", "--country", "US", "--text", "check -subtitle"]).console.output == "Saved the note.")
        #expect(await harness.run(["keywords", "note", id, "notes", "--country", "US"]).code == CommandRunner.ExitCode.usage)

        let show = await harness.run(["keywords", "show", id, "notes", "--country", "US"])
        #expect(show.console.output.contains("Latest #2"))
        #expect(show.console.output.contains("Note: check -subtitle"))
        #expect(show.console.output.contains("★ Acme Notes"))
        let json = await harness.run(["keywords", "show", id, "notes", "--country", "US", "--json"])
        #expect(json.console.output.contains("\"topResults\""))

        let csv = await harness.run(["keywords", "list", id, "--csv"])
        #expect(csv.console.output.hasPrefix(KeywordCSV.header))
        #expect(await harness.run(["keywords", "list", id, "--csv", "--json"]).code == CommandRunner.ExitCode.usage)
    }
}
