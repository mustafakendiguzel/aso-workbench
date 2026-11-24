import Foundation
import Testing
import ASOCore
import ASOProviders
@testable import ASOCommands
@testable import ASOEngine

@Suite("Apple Ads campaigns")
struct AdsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// One campaign for the tracked app (two match types of "notes" in the US, one German row) and one for another app.
    var account: FakeAds {
        FakeAds(list: [.init(id: 1, name: "Acme US", status: "ENABLED", adamID: ownApp.trackID, countries: ["US", "DE"]),
                       .init(id: 2, name: "Someone else", status: "ENABLED", adamID: 42, countries: ["US"])],
                reports: [1: [makeStat("Notes", "us", impressions: 900, taps: 60, installs: 20, spend: 30),
                              makeStat("notes", "US", match: "BROAD", impressions: 100, taps: 10, installs: 5, spend: 10),
                              makeStat("notizen", "DE", impressions: 50, taps: 0, installs: 0, spend: 1.25)],
                          2: [makeStat("other", "US", campaign: 2, impressions: 5, taps: 1, installs: 1, spend: 1)]])
    }

    @Test("A data file from schema 5 gains the campaign table and keeps its apps")
    func migrationFromSchemaFive() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(5) { try db.execute(step) }
            try db.setUserVersion(5)
            try db.execute("INSERT INTO apps (track_id, name, seller_name, created_at) VALUES (42, 'Old App', 'Old Seller', 0)")
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
        #expect(try await store.app(trackID: 42)?.name == "Old App")
        #expect(try await store.adsStats(appID: 42).isEmpty)
    }

    @Test("A sync stores the tracked app's campaigns, sums them per storefront and keyword, and replaces them next time")
    func sync() async throws {
        let engine = try makeEngine(ads: account)
        _ = try await engine.addApp(reference: String(ownApp.trackID), lookupCountry: nil, markets: ["US"], device: .iPhone)
        _ = try await engine.addKeywords(["notes", "journal"], appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        #expect(try await engine.adsReport(appID: ownApp.trackID).syncedAt == nil)

        let sync = try await engine.syncAds(days: 30, now: now)
        #expect(sync == Engine.AdsSync(campaigns: 2, matched: 1, rows: 3, periodStart: now.addingTimeInterval(-30 * 86_400), periodEnd: now))

        let report = try await engine.adsReport(appID: ownApp.trackID)
        #expect(report.syncedAt == now)
        #expect(report.storefronts.map(\.country) == ["US", "DE"])
        let us = report.storefronts[0]
        #expect((us.impressions, us.taps, us.installs, us.spend) == (1_000, 70, 25, 40))
        #expect(us.costPerInstall == 1.6)
        #expect(us.tapToInstall == 25.0 / 70.0)
        #expect(report.storefronts[1].tapToInstall == nil)   // no taps, no rate
        #expect(report.storefronts[1].countryName == "Germany")

        let rows = try await engine.keywordReport(appID: ownApp.trackID)
        #expect(rows.first { $0.keyword == "notes" }?.ads == AdsTotals.test(impressions: 1_000, taps: 70, installs: 25, spend: 40))
        #expect(rows.first { $0.keyword == "journal" }?.ads == nil)
        let detail = try await engine.keywordDetail("notes", appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        #expect(detail.row.ads?.installs == 25)

        // The next sync replaces the campaign's rows instead of adding to them.
        var smaller = account
        smaller.reports[1] = [makeStat("notes", "US", impressions: 10, taps: 1, installs: 0, spend: 0.5)]
        let next = Engine(store: engine.store, search: engine.search, suggestions: engine.suggestions, reviews: engine.reviews, ads: smaller)
        _ = try await next.syncAds(now: now.addingTimeInterval(86_400))
        #expect(try await engine.adsReport(appID: ownApp.trackID).keywords.count == 1)

        try await engine.store.removeApp(trackID: ownApp.trackID)
        #expect(try await engine.store.adsStats(appID: ownApp.trackID).isEmpty)
    }

    @Test("Syncing needs the Apple Ads keys and a window of 1 to 90 days")
    func refusals() async throws {
        let unconnected = try makeEngine()
        await #expect(throws: EngineError.self) { try await unconnected.syncAds() }
        let connected = try makeEngine(ads: account)
        await #expect(throws: EngineError.self) { try await connected.syncAds(days: 0) }
        await #expect(throws: EngineError.self) { try await connected.adsReport(appID: 99) }
    }

    @Test("The commands sync and list, and keywords show includes the keyword's results")
    func commands() async throws {
        let harness = try Harness(ads: account)
        let id = String(ownApp.trackID)
        #expect(await harness.run(["app", "add", id]).code == 0)
        #expect(await harness.run(["keywords", "add", id, "notes", "--country", "US"]).code == 0)
        #expect(await harness.run(["ads", "list", id]).console.output == "No campaign results stored for this app. Read them with: aso ads sync")

        let sync = await harness.run(["ads", "sync", "--days", "7"])
        #expect(sync.code == 0)
        #expect(sync.console.output.hasPrefix("2 campaign(s) in the account, 1 for tracked apps; 3 keyword × storefront row(s) for "))

        let list = await harness.run(["ads", "list", id])
        #expect(list.console.output.contains("United States (US)"))
        #expect(list.console.output.contains("40.00 USD"))
        #expect(list.console.output.contains("Acme US"))
        #expect(await harness.run(["--json", "ads", "list", id]).console.output.contains("\"costPerInstall\" : 1.6"))
        let show = await harness.run(["keywords", "show", id, "notes", "--country", "US"])
        #expect(show.console.output.contains("Your Apple Ads: 1000 impressions, 70 taps, 25 installs, 40.00 USD spent"))

        #expect(await harness.run(["ads", "sync", "--days", "120"]).code == 64)
        #expect(await harness.run(["ads", "list"]).code == 64)
        let unconnected = try Harness()
        #expect(await unconnected.run(["ads", "sync"]).console.errors.contains("aso connections set apple-ads"))
    }
}

extension AdsTotals {
    static func test(impressions: Int, taps: Int, installs: Int, spend: Double) -> AdsTotals? {
        AdsTotals([AdsKeywordStatRecord(campaignID: 1, campaignName: "", adGroupName: "", keywordID: 0, keyword: "", matchType: "", status: "",
                                        country: "", bid: nil, currency: "USD", impressions: impressions, taps: taps, installs: installs,
                                        spend: spend, ttr: nil, conversionRate: nil, avgCPT: nil, avgCPI: nil, periodStart: .distantPast,
                                        periodEnd: .distantPast, fetchedAt: .distantPast)])
    }
}
