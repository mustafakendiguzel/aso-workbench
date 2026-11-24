import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("RevenueCat")
struct RevenueTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The tracked app's project (by bundle ID) and an unrelated one.
    func account(mrr: Double = 120) -> FakeRevenue {
        FakeRevenue(result: RevenueRead(projects: [makeProject("p1", "Acme", bundles: [ownApp.bundleID!], apps: ["Acme Notes"], mrr: mrr),
                                                   makeProject("p2", "Other", bundles: ["com.other"], mrr: 9)],
                                        failures: []))
    }

    func engine(_ revenue: FakeRevenue?, store: Store? = nil) async throws -> Engine {
        let engine = Engine(store: try store ?? Store.inMemory(), search: FakeSearch(apps: [ownApp.trackID: ownApp]), suggestions: FakeSuggestions(),
                            reviews: FakeReviews(), revenue: revenue)
        if try await engine.store.app(trackID: ownApp.trackID) == nil { _ = try await engine.addApp(reference: String(ownApp.trackID)) }
        return engine
    }

    @Test("A data file from schema 6 gains revenue snapshots")
    func migrationFromSchemaSix() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(6) { try db.execute(step) }
            try db.setUserVersion(6)
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
        #expect(try await store.revenueSnapshots().isEmpty)
    }

    @Test("One snapshot per project and day; the app's project is found by bundle ID, with the MRR change since the previous day")
    func refreshAndReport() async throws {
        let first = try await engine(account(mrr: 100))
        #expect(try await first.revenueReport(appID: ownApp.trackID).latest == nil)
        #expect(try await first.refreshRevenue(now: now, calendar: utc) == Engine.RevenueRefresh(projects: 2, failures: []))
        // Later the same day: replaced, not added.
        let again = try await engine(account(mrr: 110), store: first.store)
        _ = try await again.refreshRevenue(now: now.addingTimeInterval(3600), calendar: utc)
        #expect(try await first.store.revenueSnapshots().count == 2)

        let nextDay = try await engine(account(mrr: 130), store: first.store)
        _ = try await nextDay.refreshRevenue(now: now.addingTimeInterval(86_400), calendar: utc)
        let report = try await first.revenueReport(appID: ownApp.trackID)
        #expect(report.match == "bundleID")
        #expect(report.latest?.projectName == "Acme")
        #expect(report.latest?.mrr == 130)
        #expect(report.mrrChange == 20)
        #expect(report.history.map(\.mrr) == [130, 110])
        #expect(report.latest?.appNames == ["Acme Notes"])
    }

    @Test("Without a bundle match the name decides; no match, no keys and failing keys are said plainly")
    func matchingAndFailures() async throws {
        let byName = try await engine(FakeRevenue(result: RevenueRead(projects: [makeProject("p3", "Acme Notes Inc", bundles: [], mrr: 5)], failures: [])))
        _ = try await byName.refreshRevenue(now: now, calendar: utc)
        #expect(try await byName.revenueReport(appID: ownApp.trackID).match == "name")

        let unrelated = try await engine(FakeRevenue(result: RevenueRead(projects: [makeProject("p4", "Weather", bundles: ["com.w"], mrr: 5)], failures: [])))
        _ = try await unrelated.refreshRevenue(now: now, calendar: utc)
        #expect(try await unrelated.revenueReport(appID: ownApp.trackID) == Engine.RevenueReport(match: nil, latest: nil, mrrChange: nil, history: []))

        let partly = try await engine(FakeRevenue(result: RevenueRead(projects: [makeProject("p1", "Acme", bundles: [], mrr: 1)], failures: ["401"])))
        #expect(try await partly.refreshRevenue(now: now, calendar: utc).failures == ["401"])
        let failing = try await engine(FakeRevenue(result: RevenueRead(projects: [], failures: ["RevenueCat rejected the credentials (401/403)."])))
        await #expect(throws: EngineError.self) { try await failing.refreshRevenue(now: now, calendar: utc) }
        let unconnected = try await engine(nil)
        await #expect(throws: EngineError.self) { try await unconnected.refreshRevenue() }
    }

    @Test("The commands read and show revenue")
    func commands() async throws {
        let harness = try Harness(revenue: account())
        let id = String(ownApp.trackID)
        #expect(await harness.run(["app", "add", id]).code == 0)
        #expect(await harness.run(["revenue", "show", id]).console.output.hasPrefix("No RevenueCat project matches this app."))
        #expect(await harness.run(["revenue", "refresh"]).console.output == "2 RevenueCat project(s) read.")
        let show = await harness.run(["revenue", "show", id])
        #expect(show.console.output.contains("Acme · read "))
        #expect(show.console.output.contains("MRR $120  ·  active subscriptions 10  ·  revenue 28 days $108"))
        #expect(await harness.run(["--json", "revenue", "show", id]).console.output.contains("\"match\" : \"bundleID\""))
        #expect(await harness.run(["revenue", "show"]).code == 64)
        let unconnected = try Harness()
        #expect(await unconnected.run(["revenue", "refresh"]).console.errors.contains("aso connections set revenuecat"))
    }
}
