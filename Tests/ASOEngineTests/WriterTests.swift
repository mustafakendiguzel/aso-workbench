import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Metadata writer")
struct WriterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let id = ownApp.trackID
    static let proposals = #"""
    {"proposals":[
      {"label":"A","title":"Acme Notes: Daily Journal","subtitle":"Diary, memos, planner","keywords":"ideas,thoughts,writing,record,mood,gratitude,habit,tracker","rationale":"Volume first.","promotional_text":"Capture every thought."},
      {"label":"B","title":"Acme Notes","subtitle":"Journal","keywords":"notes","rationale":"Short."}
    ],"description":"Acme Notes keeps your days.\n- Write notes"}
    """#

    /// The model: three kinds of answers, and a failure for anything about `failing`.
    static func model(failing: String? = nil) -> FakeWriter {
        FakeWriter { system, user in
            if let failing, user.contains(failing) { return nil }
            if system.hasPrefix("You are an App Store Optimization specialist. Follow") { return proposals }
            if system.hasPrefix("You are an App Store Optimization specialist fixing") {
                // Proposal A again: as good as a draft written from it, never worse.
                return #"{"title":"Acme Notes: Daily Journal","subtitle":"Diary, memos, planner","keywords":"ideas,thoughts,writing,record,mood,gratitude,habit,tracker","rationale":"Covers the journal."}"#
            }
            if system.hasPrefix("You localize") { return user.contains("German") ? "Fehlerbehebungen." : "Corrections." }
            return nil
        }
    }

    /// The app tracked in the US and Germany with its store description, two US keywords and the legal footer off.
    func harness(_ writer: FakeWriter?) async throws -> Harness {
        let described = SearchResultApp(trackID: ownApp.trackID, bundleID: ownApp.bundleID, name: "Acme Notes: Daily Journal", sellerName: "Acme Inc",
                                        iconURL: nil, averageRating: 4.5, ratingCount: 100, primaryGenre: "Productivity", releaseDate: nil,
                                        currentVersionReleaseDate: nil, price: 0, version: "1.0", storeDescription: "Write notes and keep a daily journal.")
        let harness = try Harness(search: FakeSearch(results: ["notes": [described]], apps: [id: described]), writer: writer)
        let engine = harness.engine
        _ = try await engine.addApp(reference: String(id))
        _ = try await engine.addMarket(appID: id, countryCode: "US", device: .iPhone)
        _ = try await engine.addMarket(appID: id, countryCode: "DE", device: .iPhone)
        _ = try await engine.addKeywords(["notes", "daily journal"], appID: id, countryCode: "US", device: .iPhone)
        _ = try await engine.measure(appID: id, countryCode: "US", device: .iPhone, keywords: ["notes"])
        _ = try await engine.setLegalFooter(appID: id, enabled: false)
        return harness
    }

    @Test("Without the OpenRouter key the writer says how to connect it")
    func notConnected() async throws {
        let engine = try await harness(nil).engine
        await #expect(throws: EngineError.invalidArgument(Engine.writerNotConnected)) { try await engine.writeMetadata(appID: id, locale: .enUS) }
    }

    @Test("Proposals use the market's plan, evidence and store description; only --save keeps the best as the draft")
    func write() async throws {
        let model = Self.model()
        let engine = try await harness(model).engine
        let result = try await engine.writeMetadata(appID: id, locale: .enUS, strategy: .brandFirst, notes: "Calm tone.", now: now)
        #expect(result.market == "US")
        #expect(result.cost == "$0.0020")
        #expect(!result.saved)
        #expect(result.proposals.first?.label == "A")
        #expect(result.proposals[0].covered.contains("daily journal"))
        #expect(result.proposals[0].fields.description.hasPrefix("Acme Notes keeps your days.\n• Write notes"))
        #expect(try await engine.metadata(appID: id, locale: .enUS).draftUpdatedAt == nil)

        let prompt = try #require(model.calls.first)
        #expect(prompt.user.contains("Brand to use: \"Acme Notes\"."))
        #expect(prompt.user.contains("- notes (popularity 0, difficulty"))
        #expect(prompt.user.contains("Target locale: en-US (English (U.S.)). Storefront: US."))
        #expect(prompt.user.contains("App description (for what the app really does): Write notes and keep a daily journal."))

        let saved = try await engine.writeMetadata(appID: id, locale: .enUS, save: true, now: now)
        #expect(saved.saved)
        #expect(try await engine.metadata(appID: id, locale: .enUS).draft.name == "Acme Notes: Daily Journal")
    }

    @Test("Make better is saved only when asked, and every locale is written in turn with failures reported")
    func improveAndWriteAll() async throws {
        let engine = try await harness(Self.model(failing: "Target locale: de-DE")).engine
        let improved = try await engine.improveMetadata(appID: id, locale: .enUS, save: false, now: now)
        #expect(improved.proposal.label == "Improved")
        #expect(improved.proposal.covered.contains("daily journal"))
        #expect(!improved.saved)
        #expect(try await engine.metadata(appID: id, locale: .enUS).draftUpdatedAt == nil)

        let batch = try await engine.writeAllMetadata(appID: id, now: now)
        #expect(batch.map(\.locale) == ["de-DE", "en-US"])
        #expect(batch[0].proposal == nil)
        #expect(batch[0].error != nil)
        #expect(batch[1].proposal?.fields.name == "Acme Notes: Daily Journal")
        #expect(try await engine.metadata(appID: id, locale: .enUS).draft.subtitle == "Diary, memos, planner")
        #expect(try await engine.metadata(appID: id, locale: .deDE).draftUpdatedAt == nil)
    }

    @Test("What's New is saved into the source and translated into the other locales; the same language gets the source")
    func whatsNew() async throws {
        let model = Self.model()
        let engine = try await harness(model).engine
        let lines = try await engine.writeWhatsNew(appID: id, source: "Bug fixes.", sourceLocale: .enUS, locales: [.deDE, .enGB, .frFR], now: now)
        #expect(lines.map(\.locale) == ["de-DE", "en-GB", "fr-FR"])
        #expect(lines.map(\.text) == ["Fehlerbehebungen.", "Bug fixes.", "Corrections."])
        #expect(model.calls.count == 2)
        #expect(try await engine.metadata(appID: id, locale: .enUS).draft.whatsNew == "Bug fixes.")
        #expect(try await engine.metadata(appID: id, locale: .deDE).draft.whatsNew == "Fehlerbehebungen.")
        await #expect(throws: EngineError.self) { try await engine.writeWhatsNew(appID: id, source: "  ", sourceLocale: .enUS) }
    }

    @Test("The commands print the proposals, save on request and read release notes from standard input")
    func commands() async throws {
        let h = try await harness(Self.model())
        let app = String(id)
        let written = await h.run(["metadata", "write", app, "--locale", "en-US"])
        #expect(written.code == 0)
        #expect(written.console.output.contains("A · rules "))
        #expect(written.console.output.contains("Nothing saved; add --save"))
        let json = await h.run(["--json", "metadata", "write", app, "--locale", "en-US", "--save"])
        #expect(json.console.output.contains("\"saved\" : true"))
        #expect(await h.run(["metadata", "improve", app, "--locale", "en-US"]).console.output.contains("Not saved; add --save"))
        let all = await h.run(["metadata", "write-all", app, "--locales", "en-US"])
        #expect(all.console.errors.contains("Writing en-US…"))
        #expect(all.console.output.contains("The best proposal of each locale was saved as its draft."))
        let notes = await h.run(["metadata", "whats-new", app, "--from", "en-US", "--stdin", "--locales", "de-DE"], input: "Bug fixes.")
        #expect(notes.console.output == "de-DE: Fehlerbehebungen.")

        #expect(await h.run(["metadata", "write", app]).code == 64)
        #expect(await h.run(["metadata", "write", app, "--locale", "en-US", "--strategy", "loud"]).code == 64)
        #expect(await h.run(["metadata", "whats-new", app, "--locales", "de-DE", "--text", "x"]).code == 64)
        #expect(await h.run(["metadata", "whats-new", app, "--from", "en-US", "--text", "x", "--stdin"]).code == 64)
    }
}
