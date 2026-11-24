import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Keywords in other countries")
struct ExpansionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let id = ownApp.trackID

    /// "notes" ranks the app first; "notizen" (a German local form) has a weak field; "journal" has a strong leader.
    var search: FakeSearch {
        let leader = SearchResultApp(trackID: 9, bundleID: "com.example.9", name: "Day One Journal", sellerName: "Bloom", iconURL: nil, averageRating: 4.8,
                                     ratingCount: 900_000, primaryGenre: "Productivity", releaseDate: nil, currentVersionReleaseDate: nil, price: 0,
                                     version: "1.0")
        return FakeSearch(results: ["notes": [ownApp], "journal": [leader, ownApp], "notizen": [makeApp(5, "Zettel", ratings: 12)]],
                          apps: [ownApp.trackID: ownApp])
    }

    func engine(popularity: FakePopularity? = nil, writer: FakeWriter? = nil, judge: FakeJudge? = nil) async throws -> Engine {
        let engine = try makeEngine(search: search, popularity: popularity, judge: judge, writer: writer)
        _ = try await engine.addApp(reference: String(id))
        _ = try await engine.addKeywords(["notes", "journal"], appID: id, countryCode: "US", device: .iPhone)
        return engine
    }

    /// The model's local forms: German for "notes", nothing new for English storefronts.
    static let writer = FakeWriter { system, user in
        guard system.hasPrefix("You are an App Store search localization specialist") else { return nil }
        return user.contains("(DE)") ? #"{"terms":[{"source":"notes","candidates":[{"term":"Notizen","meaning":"notes"},{"term":"notes","meaning":"same"}]}]}"# : nil
    }

    @Test("The source market's keywords are tried in the other countries, with local forms where the store speaks another language")
    func tryKeywords() async throws {
        let lists: [AppleAdsGenre: [String: Int]] = [.productivityUtilities: ["notes": 60, "journal": 70, "notizen": 40, "memo pad": 31]]
        let workbench = try await engine(popularity: FakePopularity(lists: lists, now: now), writer: Self.writer)
        let report = try await workbench.tryInOtherCountries(appID: id, countries: ["GB", "DE"], now: now)

        #expect(report.keywords == 2)
        #expect(report.countries == ["GB", "DE"])
        #expect(Set(report.rows.map { "\($0.country) \($0.term)" }) == ["GB notes", "GB journal", "DE notes", "DE journal", "DE notizen"])
        let notizen = try #require(report.rows.first { $0.term == "notizen" })
        #expect(notizen.source == "notes")
        #expect(notizen.meaning == "notes")
        #expect(notizen.popularity == 40)
        #expect(notizen.popularitySource == "list")
        let notes = try #require(report.rows.first { $0.country == "GB" && $0.term == "notes" })
        #expect(notes.rank == 1)
        #expect(notes.candidate)
        let journal = try #require(report.rows.first { $0.country == "GB" && $0.term == "journal" })
        #expect(journal.rank == 2)
        #expect(journal.leader == "Day One Journal")
        // Best opportunity first.
        let values: [Double] = report.rows.map { $0.opportunity ?? -1 }
        #expect(values == values.sorted(by: >))
        #expect(report.localizationCost == ["DE $0.0020"])
        #expect(report.tracked == 0)
        #expect(try await workbench.markets(appID: id).map(\.country) == ["US"])
    }

    @Test("With --track every cell becomes a keyword with its measurement, popularity and, for a local form, a note")
    func track() async throws {
        let lists: [AppleAdsGenre: [String: Int]] = [.productivityUtilities: ["notes": 60, "memo pad": 31]]
        let workbench = try await engine(popularity: FakePopularity(lists: lists, now: now), writer: Self.writer)
        let report = try await workbench.tryInOtherCountries(appID: id, terms: ["notes", "journal", "Notes "], countries: ["DE"], track: true, now: now)
        #expect(report.tracked == 3)
        #expect(try await workbench.markets(appID: id).map(\.country).sorted() == ["DE", "US"])
        let rows = try await workbench.keywordReport(appID: id, countryCode: "DE", device: .iPhone)
        #expect(rows.map(\.keyword).sorted() == ["journal", "notes", "notizen"])
        let notizen = try #require(rows.first { $0.keyword == "notizen" })
        #expect(notizen.note == "local form of “notes” · notes")
        #expect(notizen.popularitySource == "belowRange")
        #expect(notizen.popularityBelow == 31)
        #expect(rows.first { $0.keyword == "notes" }?.rank == 1)
    }

    @Test("Without Apple Ads nothing has popularity and nothing is a candidate; without keywords there is nothing to try")
    func withoutKeys() async throws {
        let workbench = try await engine()
        let report = try await workbench.tryInOtherCountries(appID: id, countries: ["DE"], now: now)
        #expect(!report.appleAds)
        #expect(!report.languageChecked)
        #expect(report.rows.allSatisfy { $0.popularity == nil && $0.popularitySource == nil && !$0.candidate })
        // No writer: no local forms.
        #expect(report.rows.count == 2)
        await #expect(throws: EngineError.self) { try await workbench.tryInOtherCountries(appID: id, terms: [" "], countries: ["DE"]) }
        await #expect(throws: EngineError.self) { try await workbench.tryInOtherCountries(appID: id, countries: ["XX"]) }
    }

    @Test("The command prints the table and reports progress on stderr")
    func command() async throws {
        let harness = try Harness(search: search, popularity: FakePopularity(lists: [.productivityUtilities: ["notes": 60]], now: now))
        _ = try await harness.engine.addApp(reference: String(id))
        _ = try await harness.engine.addKeywords(["notes"], appID: id, countryCode: "US", device: .iPhone)
        let run = await harness.run(["expand", String(id), "--countries", "GB", "--no-local-forms"])
        #expect(run.code == 0)
        #expect(run.console.output.contains("★  GB       notes"))
        #expect(run.console.output.contains("1 keyword(s) × 1 storefront(s): 1 candidate(s)"))
        #expect(run.console.errors.contains("GB · “notes”"))
        #expect(await harness.run(["expand", String(id), "--countries", ""]).code == 64)
    }
}
