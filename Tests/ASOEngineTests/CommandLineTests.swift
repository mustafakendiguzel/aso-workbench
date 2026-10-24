import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

/// Captures what a command wrote to stdout and stderr.
final class Console: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    func write(_ s: String) { lock.lock(); out.append(s); lock.unlock() }
    func writeError(_ s: String) { lock.lock(); err.append(s); lock.unlock() }
    var output: String { lock.lock(); defer { lock.unlock() }; return out.joined(separator: "\n") }
    var errors: String { lock.lock(); defer { lock.unlock() }; return err.joined(separator: "\n") }
}

/// Runs commands against one shared in-memory engine, as consecutive invocations would against one data file.
struct Harness {
    let engine: Engine
    let directories = Directories()

    init(search: FakeSearch = FakeSearch(apps: [ownApp.trackID: ownApp]), reviews: FakeReviews = FakeReviews(),
         popularity: FakePopularity? = nil, hints: FakeSuggestions = FakeSuggestions(), judge: FakeJudge? = nil, ads: FakeAds? = nil,
         revenue: FakeRevenue? = nil) throws {
        engine = try makeEngine(search: search, hints: hints, reviews: reviews, popularity: popularity, judge: judge, ads: ads, revenue: revenue)
    }

    func run(_ arguments: [String], environment: [String: String] = [:]) async -> (code: Int32, console: Console) {
        let console = Console()
        let engine = self.engine
        let directories = self.directories
        let runner = CommandRunner(environment: environment, output: { console.write($0) }, errors: { console.writeError($0) }) { directory in
            directories.append(directory)
            return engine
        }
        return (await runner.run(arguments), console)
    }

    final class Directories: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var last: URL? { lock.lock(); defer { lock.unlock() }; return urls.last }
    }
}

@Suite("Command line arguments")
struct ArgumentsTests {
    @Test("Options take a value as the next argument or after =, flags take none")
    func parsing() throws {
        let args = try Arguments(["keywords", "add", "123", "budget planner", "--country", "US", "--device=ipad", "--json"])
        #expect(args.positionals == ["keywords", "add", "123", "budget planner"])
        #expect(args.option("country") == "US")
        #expect(args.option("device") == "ipad")
        #expect(args.flag("json"))
        #expect(!args.flag("help"))
    }

    @Test("Everything after -- is positional")
    func doubleDash() throws {
        let args = try Arguments(["keywords", "add", "1", "--country", "US", "--", "-dash", "--json"])
        #expect(args.positionals == ["keywords", "add", "1", "-dash", "--json"])
        #expect(!args.flag("json"))
    }

    @Test("Mistakes are usage errors")
    func mistakes() {
        #expect(throws: UsageError("--country needs a value.")) { try Arguments(["search", "x", "--country"]) }
        #expect(throws: UsageError("--json does not take a value.")) { try Arguments(["--json=yes"]) }
        #expect(throws: UsageError.self) { try Arguments(["-x"]) }
    }

    @Test("Commands reject options they do not know, numbers are checked")
    func validation() throws {
        let args = try Arguments(["app", "list", "--country", "US", "--limit", "x"])
        #expect(throws: UsageError("Unknown option --country for this command.")) { try args.allow(["limit"]) }
        #expect(throws: UsageError.self) { try args.integerOption("limit", default: 5, range: 1...10) }
        #expect(throws: UsageError("Missing app ID.")) { try args.positional(2, "app ID") }
        #expect(try Arguments(["-h"]).flag("help"))
    }
}

@Suite("aso command")
struct CommandRunnerTests {
    @Test("Help and version need no data file")
    func helpAndVersion() async throws {
        let harness = try Harness()
        let help = await harness.run([])
        #expect(help.code == 0)
        #expect(help.console.output.contains("Usage: aso <command>"))
        let version = await harness.run(["--version", "--json"])
        #expect(version.console.output.contains("\"version\" : \"\(EngineEnvironment.version)\""))
        #expect(version.console.output.contains("\"dataDirectory\" : "))
        #expect(harness.directories.last == nil)
    }

    @Test("Usage errors exit with 64 and print the usage on stderr")
    func usageErrors() async throws {
        let harness = try Harness()
        for arguments in [["fly"], ["app", "add"], ["search", "notes"], ["keywords", "add", "x", "notes", "--country", "US"],
                          ["app", "list", "--country", "US"], ["keywords", "list", "1", "--delta", "never"]] {
            let result = await harness.run(arguments)
            #expect(result.code == CommandRunner.ExitCode.usage, "\(arguments)")
            #expect(result.console.errors.hasPrefix("error: "), "\(arguments)")
            #expect(result.console.output.isEmpty, "\(arguments)")
        }
    }

    @Test("Runtime failures exit with 1 and a sentence on stderr")
    func failures() async throws {
        let result = await (try Harness()).run(["keywords", "list", "42"])
        #expect(result.code == CommandRunner.ExitCode.failure)
        #expect(result.console.errors == "error: App 42 is not tracked. Add it first.")
    }

    @Test("Track an app, add keywords, measure and list, in text and JSON")
    func workflow() async throws {
        var search = FakeSearch(apps: [ownApp.trackID: ownApp])
        search.results["notes"] = [makeApp(5, "Rival"), ownApp]
        let harness = try Harness(search: search)
        let id = String(ownApp.trackID)

        let added = await harness.run(["app", "add", "https://apps.apple.com/us/app/acme/id\(id)"])
        #expect(added.code == 0)
        #expect(added.console.output == "Tracking Acme Notes (\(id)) by Acme Inc.")
        #expect(CommandRunner.sentence("by Apple Inc.") == "by Apple Inc.")
        #expect(CommandRunner.sentence("Done") == "Done.")

        let list = await harness.run(["app", "list", "--json"])
        let apps = try JSONDecoder.iso.decode([AppRecord].self, from: Data(list.console.output.utf8))
        #expect(apps.map(\.trackID) == [ownApp.trackID])

        let keywords = await harness.run(["keywords", "add", id, "notes", "journal", "--country", "us"])
        #expect(keywords.console.output == "Added 2 keyword(s) in US · iphone.")

        let measured = await harness.run(["measure", id])
        #expect(measured.code == 0)
        #expect(measured.console.output == "Measured 2: 1 ranked, 1 outside the results, 0 failed.")
        #expect(measured.console.errors.contains("[1/2] US · iphone  journal  > 0"))
        #expect(measured.console.errors.contains("[2/2] US · iphone  notes  #2"))

        let text = await harness.run(["keywords", "list", id])
        #expect(text.console.output.hasPrefix("Keyword"))
        #expect(text.console.output.contains("notes    US iphone    #2"))

        let json = await harness.run(["keywords", "list", id, "--json"])
        let rows = try JSONDecoder.iso.decode([KeywordReportRow].self, from: Data(json.console.output.utf8))
        #expect(rows.map(\.keyword) == ["journal", "notes"])
        #expect(rows.last?.rank == 2)

        let removed = await harness.run(["app", "remove", id])
        #expect(removed.console.output.hasPrefix("Removed app"))
        #expect(await harness.run(["app", "remove", id]).code == CommandRunner.ExitCode.failure)
    }

    @Test("measure --json reports progress as one JSON object per stderr line")
    func measureJSONProgress() async throws {
        var search = FakeSearch(apps: [ownApp.trackID: ownApp])
        search.results["notes"] = [makeApp(5, "Rival"), ownApp]
        search.failing = ["journal"]
        let harness = try Harness(search: search)
        let id = String(ownApp.trackID)
        _ = await harness.run(["app", "add", id])
        _ = await harness.run(["keywords", "add", id, "notes", "journal", "--country", "US"])

        let result = await harness.run(["measure", id, "--json"])
        #expect(result.code == 0)
        struct Line: Decodable, Equatable { let completed: Int; let total: Int; let market: String; let keyword: String; let outcome: String; let status: String }
        let lines = try result.console.errors.split(separator: "\n").map { try JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
        #expect(lines == [.init(completed: 1, total: 2, market: "US · iphone", keyword: "journal", outcome: "Error", status: "failed"),
                          .init(completed: 2, total: 2, market: "US · iphone", keyword: "notes", outcome: "#2", status: "found")])
        let summary = try JSONDecoder().decode(Engine.MeasureSummary.self, from: Data(result.console.output.utf8))
        #expect(summary == .init(measured: 2, found: 1, outside: 0, failed: 1))
    }

    @Test("difficulty --json carries the components as the engine names and weighs them")
    func difficultyJSON() async throws {
        var search = FakeSearch()
        search.results["habit tracker"] = (1...12).map { makeApp($0, "Habit Tracker \($0)", ratings: 50_000) }
        let result = await (try Harness(search: search)).run(["difficulty", "habit tracker", "--country", "US", "--json"])
        #expect(result.code == 0)
        struct Report: Decodable { struct Component: Decodable { let name: String; let weight: String; let value: Double; let explanation: String }
                                   let score: Double; let tier: String; let sampleSize: Int; let components: [Component] }
        let report = try JSONDecoder().decode(Report.self, from: Data(result.console.output.utf8))
        let expected = try #require(DifficultyScore(results: search.results["habit tracker"]!, term: "habit tracker"))
        #expect(report.score == expected.score)
        #expect(report.sampleSize == expected.sampleSize)
        #expect(report.components.map(\.name) == expected.components.map(\.name))
        #expect(report.components.map(\.weight) == expected.components.map(\.weight))
        #expect(report.components.allSatisfy { !$0.explanation.isEmpty })
    }

    @Test("Metadata validation exits with 1 when a hard limit is broken")
    func validate() async throws {
        let harness = try Harness()
        let ok = await harness.run(["validate", "--title", "Acme Notes", "--subtitle", "Quick notes", "--keywords", "notes,journal"])
        #expect(ok.code == 0)
        let tooLong = await harness.run(["validate", "--title", String(repeating: "A", count: 31), "--json"])
        #expect(tooLong.code == CommandRunner.ExitCode.failure)
        #expect(tooLong.console.output.contains("\"severity\" : 2"))
    }

    @Test("--data-dir wins over ASO_DATA_DIR, which wins over the platform folder")
    func dataDirectory() async throws {
        let harness = try Harness()
        _ = await harness.run(["app", "list"], environment: ["ASO_DATA_DIR": "/tmp/from-env"])
        #expect(harness.directories.last?.lastPathComponent == "from-env")
        _ = await harness.run(["app", "list", "--data-dir", "/tmp/from-flag"], environment: ["ASO_DATA_DIR": "/tmp/from-env"])
        #expect(harness.directories.last?.lastPathComponent == "from-flag")
        #expect(EngineEnvironment.dataDirectory(environment: [:]).lastPathComponent == "ASO Workbench")
    }
}

@Suite("Engine environment")
struct EngineEnvironmentTests {
    @Test("The engine version matches the repository's VERSION file")
    func version() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(EngineEnvironment.version == version)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
