import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Popularity estimates")
struct EstimateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let id = ownApp.trackID
    /// "notes" on Apple's list; the rest off it, under 31.
    let lists: [AppleAdsGenre: [String: Int]] = [.productivityUtilities: ["notes": 62, "memo pad": 31]]

    func engine(judge: FakeJudge?, models: URL? = bundledModels) async throws -> Engine {
        let hints = FakeSuggestions(hints: ["habit tracker": ["habit tracker", "habit tracker app", "habit tracker free"],
                                            "habit": ["habit tracker", "habit app", "habits"], "habi": ["habit tracker", "habit"]])
        let engine = try makeEngine(hints: hints, popularity: FakePopularity(lists: lists, now: now), judge: judge, models: models)
        _ = try await engine.addApp(reference: String(id))
        _ = try await engine.addKeywords(["notes", "habit tracker", "zqxv"], appID: id, countryCode: "US", device: .iPhone)
        return engine
    }

    @Test("Terms off Apple's list get the model's estimate: below the range without any suggestion, the model otherwise")
    func estimates() async throws {
        let workbench = try await engine(judge: FakeJudge())
        let refreshes = try await workbench.refreshPopularity(appID: id, now: now)
        #expect(refreshes.first?.onList == 1)
        #expect(refreshes.first?.estimated == 2)
        let rows = Dictionary(uniqueKeysWithValues: try await workbench.keywordReport(appID: id).map { ($0.keyword, $0) })

        #expect(rows["notes"]?.popularitySource == "list")
        // No suggestion for the term, its first word or its prefix: below the range without running the model.
        let rare = try #require(rows["zqxv"])
        #expect(rare.popularitySource == "estimate")
        #expect(rare.popularity == nil)
        #expect(rare.popularityProbability == 0.95)
        #expect(rare.popularityBelow == 31)
        #expect((6...29).contains(rare.popularitySubFloor ?? 0))

        let habit = try #require(rows["habit tracker"])
        #expect(habit.popularitySource == "estimate")
        #expect((0...1).contains(habit.popularityProbability ?? -1))
        if let value = habit.popularity {
            // A published estimate sits under the list's lowest score.
            #expect((30...30).contains(value))
        } else {
            #expect((6...29).contains(habit.popularitySubFloor ?? 0))
        }
        #expect(CommandRunner.popularityLabel(rare) == "~\(rare.popularitySubFloor ?? 0)")
        #expect(KeywordCSV.popularitySource(rare) == "model_6_29_rank")
    }

    @Test("Keywords tried in other countries get the estimate too, and keep it when tracked")
    func expansion() async throws {
        let workbench = try await engine(judge: FakeJudge())
        let report = try await workbench.tryInOtherCountries(appID: id, terms: ["notes", "zqxv"], countries: ["GB"], localize: false, track: true, now: now)
        let rare = try #require(report.rows.first { $0.term == "zqxv" })
        #expect(rare.popularitySource == "estimate")
        #expect(rare.popularityProbability == 0.95)
        #expect((6...29).contains(rare.popularitySubFloor ?? 0))
        #expect(report.rows.first { $0.term == "notes" }?.popularitySource == "list")
        let stored = try await workbench.keywordReport(appID: id, countryCode: "GB", device: .iPhone).first { $0.keyword == "zqxv" }
        #expect(stored?.popularitySource == "estimate")
        #expect(stored?.popularitySubFloor == rare.popularitySubFloor)
    }

    @Test("Without Jev or without the models the layer is skipped and terms stay below the range")
    func skipped() async throws {
        for workbench in [try await engine(judge: nil), try await engine(judge: FakeJudge(), models: nil),
                          try await engine(judge: FakeJudge(), models: URL(fileURLWithPath: "/nowhere"))] {
            let refreshes = try await workbench.refreshPopularity(appID: id, now: now)
            #expect(refreshes.first?.estimated == 0)
            let rows = try await workbench.keywordReport(appID: id)
            #expect(rows.filter { $0.popularitySource == "belowRange" }.count == 2)
        }
    }

    @Test("A data file from schema 9 gains the estimate columns")
    func migration() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(9) { try db.execute(step) }
            try db.setUserVersion(9)
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
    }

    @Test("The models are found in the data folder, an environment folder or a checkout")
    func modelFolder() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(EngineEnvironment.modelDirectory(environment: ["ASO_MODELS_DIR": bundledModels.path], dataDirectory: folder)?.path == bundledModels.path)
        let own = folder.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        for file in [PopularityModel.regressorFile, PopularityModel.classifierFile] {
            try FileManager.default.copyItem(at: bundledModels.appendingPathComponent(file), to: own.appendingPathComponent(file))
        }
        #expect(EngineEnvironment.modelDirectory(environment: [:], dataDirectory: folder)?.standardizedFileURL.path == own.standardizedFileURL.path)

        // Next to the executable, as the packages ship them, wherever aso is started from.
        let package = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.copyItem(at: own, to: package.appendingPathComponent("models"))
        let empty = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        let found = EngineEnvironment.modelDirectory(environment: [:], dataDirectory: empty, executable: package.appendingPathComponent("aso.exe"))
        #expect(found?.standardizedFileURL.path == package.appendingPathComponent("models").standardizedFileURL.path)
    }
}
