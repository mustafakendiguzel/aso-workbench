import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Apps and markets")
struct AppsAndMarketsTests {
    @Test("A data file from schema 1 gains the genre column and keeps its apps")
    func migrationFromSchemaOne() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            try db.execute(Store.migrations[0])
            try db.setUserVersion(1)
            try db.execute("INSERT INTO apps (track_id, name, seller_name, created_at) VALUES (42, 'Old App', 'Old Seller', 0)")
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
        let app = try #require(try await store.app(trackID: 42))
        #expect(app.name == "Old App")
        #expect(app.adsGenre == nil)
    }

    @Test("A new app gets the Apple Ads genre of its App Store category; a chosen genre survives a refresh")
    func genre() async throws {
        let engine = try makeEngine()
        let app = try await engine.addApp(reference: String(ownApp.trackID))
        #expect(app.adsGenre == AppleAdsGenre.productivityUtilities.rawValue)

        _ = try await engine.setAdsGenre(appID: ownApp.trackID, genre: .education)
        let refreshed = try await engine.addApp(reference: String(ownApp.trackID))
        #expect(refreshed.adsGenre == AppleAdsGenre.education.rawValue)
        #expect(try await engine.setAdsGenre(appID: ownApp.trackID, genre: nil).adsGenre == nil)
        await #expect(throws: EngineError.self) { try await engine.setAdsGenre(appID: 1, genre: .games) }
    }

    @Test("Finding apps: a link looks the app up, a name searches")
    func find() async throws {
        let other = makeApp(77, "Budget Buddy")
        let engine = try makeEngine(search: FakeSearch(apps: [ownApp.trackID: ownApp, 77: other]))
        #expect(try await engine.findApps(query: "https://apps.apple.com/de/app/x/id\(ownApp.trackID)", countryCode: "US").map(\.trackID) == [ownApp.trackID])
        #expect(try await engine.findApps(query: "budget", countryCode: "US").map(\.trackID) == [77])
        #expect(try await engine.findApps(query: "nothing like it", countryCode: "US").isEmpty)
        await #expect(throws: EngineError.self) { try await engine.findApps(query: "  ", countryCode: "US") }
        await #expect(throws: EngineError.self) { try await engine.findApps(query: "budget", countryCode: "ZZ") }
        #expect(try await engine.store.apps().isEmpty)
    }

    @Test("Adding an app in several markets creates each once; summaries count keywords and the last measurement")
    func markets() async throws {
        let engine = try makeEngine()
        _ = try await engine.addApp(reference: String(ownApp.trackID), lookupCountry: nil, markets: ["us", "DE"], device: .iPad)
        _ = try await engine.addApp(reference: String(ownApp.trackID), lookupCountry: nil, markets: ["US"], device: .iPad)
        _ = try await engine.addKeywords(["notes", "journal"], appID: ownApp.trackID, countryCode: "US", device: .iPad)
        _ = try await engine.measure(appID: ownApp.trackID, countryCode: "US")

        let markets = try await engine.markets(appID: ownApp.trackID)
        #expect(markets.map { "\($0.country) \($0.device) \($0.keywords)" } == ["DE ipad 0", "US ipad 2"])
        #expect(markets[0].countryName == "Germany")
        #expect(markets[0].lastMeasuredAt == nil)
        #expect(markets[1].lastMeasuredAt != nil)

        let added = try await engine.addMarket(appID: ownApp.trackID, countryCode: "tr", device: .iPhone)
        #expect((added.country, added.device, added.keywords) == ("TR", "iphone", 0))

        try await engine.removeMarket(appID: ownApp.trackID, countryCode: "US", device: .iPad)
        #expect(try await engine.markets(appID: ownApp.trackID).map(\.country) == ["DE", "TR"])
        #expect(try await engine.keywordReport(appID: ownApp.trackID).isEmpty)
        await #expect(throws: EngineError.self) { try await engine.removeMarket(appID: ownApp.trackID, countryCode: "US", device: .iPad) }
        await #expect(throws: EngineError.self) {
            _ = try await engine.addApp(reference: String(ownApp.trackID), lookupCountry: nil, markets: ["XX"], device: .iPhone)
        }
    }

    @Test("The command line: search, add with markets, genre, market list and remove, storefronts and genres")
    func commands() async throws {
        let harness = try Harness(search: FakeSearch(apps: [ownApp.trackID: ownApp]))
        let id = String(ownApp.trackID)

        let search = await harness.run(["app", "search", "acme", "notes"])
        #expect(search.console.output.contains("Acme Notes"))

        let added = await harness.run(["app", "add", id, "--markets", "us,tr", "--device", "ipad"])
        #expect(added.console.output == "Tracking Acme Notes (\(id)) by Acme Inc. Markets: US, TR.")

        let list = await harness.run(["market", "list", id, "--json"])
        #expect(list.console.output.contains("\"countryName\" : \"Türkiye\""))

        #expect(await harness.run(["app", "genre", id, "games"]).console.output == "Apple Ads genre: Games.")
        #expect(await harness.run(["app", "genre", id, "any"]).console.output == "Apple Ads genre: any (every genre is searched).")
        #expect(await harness.run(["app", "genre", id, "cooking"]).code == CommandRunner.ExitCode.usage)

        #expect(await harness.run(["market", "add", id, "--country", "GB"]).console.output
                == "Market GB · iphone (United Kingdom) is ready for keywords.")
        #expect(await harness.run(["market", "remove", id, "--country", "tr", "--device", "ipad"]).code == 0)
        #expect(await harness.run(["market", "remove", id, "--country", "tr", "--device", "ipad"]).code == CommandRunner.ExitCode.failure)

        let storefronts = await harness.run(["storefronts", "--json"])
        #expect(storefronts.console.output.components(separatedBy: "\"code\"").count - 1 == StorefrontRegistry.all.count)
        let genres = await harness.run(["genres", "--json"])
        #expect(genres.console.output.components(separatedBy: "\"id\"").count - 1 == AppleAdsGenre.allCases.count)
    }
}
