import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Metadata drafts")
struct MetadataTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let live = MetadataFields(name: "Acme Notes", subtitle: "Journal and diary", keywords: "notes,planner,memo", promotionalText: "",
                              description: "Write it down.", whatsNew: "")

    /// The app tracked in Germany and the United States.
    func engine() async throws -> Engine {
        let engine = try makeEngine()
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        _ = try await engine.addMarket(appID: ownApp.trackID, countryCode: "US", device: .iPhone)
        _ = try await engine.addMarket(appID: ownApp.trackID, countryCode: "DE", device: .iPhone)
        _ = try await engine.addMarket(appID: ownApp.trackID, countryCode: "DE", device: .iPad)
        return engine
    }

    @Test("A data file from schema 7 gains drafts, baselines and the legal footer, which starts on")
    func migrationFromSchemaSeven() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(7) { try db.execute(step) }
            try db.setUserVersion(7)
            try db.query("INSERT INTO apps (track_id, name, seller_name, created_at) VALUES (1, 'Acme', 'Acme Inc', 0)")
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
        #expect(try await store.legalFooter(appID: 1) == LegalFooterSettings())
        #expect(try await store.drafts(appID: 1).isEmpty)
    }

    @Test("Locales follow the tracked markets' store languages, then stored ones; en-US when there is nothing")
    func locales() async throws {
        let bare = try makeEngine()
        _ = try await bare.addApp(reference: String(ownApp.trackID))
        #expect(try await bare.metadataLocales(appID: ownApp.trackID).map(\.locale) == ["en-US"])

        let workbench = try await engine()
        _ = try await workbench.setManualBaseline(appID: ownApp.trackID, locale: .frFR, fields: live, now: now)
        let locales = try await workbench.metadataLocales(appID: ownApp.trackID)
        #expect(locales.map(\.locale) == ["de-DE", "en-US", "fr-FR"])
        #expect(locales.map(\.market) == ["DE", "US", "DE"])
        #expect(locales[2].baseline == "manual")
        // An empty listing has no name, which Apple refuses.
        #expect(locales[0].errors == 1)
    }

    @Test("A draft starts from the baseline, is saved only once it differs, and shows what changed")
    func draftsAndChanges() async throws {
        let workbench = try await engine()
        let id = ownApp.trackID
        let fresh = try await workbench.metadata(appID: id, locale: .enUS)
        #expect(fresh.draft == .empty)
        #expect(fresh.baseline == nil)
        #expect(fresh.issues.contains { $0.message == "Name is required." })

        _ = try await workbench.setManualBaseline(appID: id, locale: .enUS, fields: live, now: now)
        let unchanged = try await workbench.saveDraft(appID: id, locale: .enUS, fields: live, now: now)
        #expect(unchanged.draftUpdatedAt == nil)
        #expect(unchanged.changes.isEmpty)
        #expect(try await workbench.store.drafts(appID: id).isEmpty)

        var edited = live
        edited.keywords = "notes,journal,diary"
        let report = try await workbench.saveDraft(appID: id, locale: .enUS, fields: edited, now: now)
        #expect(report.draftUpdatedAt == now)
        #expect(report.changes == [FieldChange(field: .keywords, before: "notes,planner,memo", after: "notes,journal,diary")])
        #expect(report.keywordChange == Engine.KeywordChange(kept: ["notes"], added: ["journal", "diary"], removed: ["planner", "memo"]))
        #expect(report.market == "US")
        #expect(report.rules.charactersUsed == edited.name.count + edited.subtitle.count + edited.keywords.count)
        #expect(!report.rules.findings.contains { $0.kind == .good })
        #expect(try await workbench.metadataLocales(appID: id).first { $0.locale == "en-US" }?.changes == 1)

        let reset = try await workbench.resetDraft(appID: id, locale: .enUS)
        #expect(reset.draft == live)
        #expect(reset.draftUpdatedAt == nil)
    }

    @Test("The legal footer is labelled per language, never duplicated, and checked addresses")
    func legalFooter() async throws {
        let workbench = try await engine()
        let id = ownApp.trackID
        await #expect(throws: EngineError.self) { try await workbench.setLegalFooter(appID: id, privacyURL: "ftp://acme.example/privacy") }
        let settings = try await workbench.setLegalFooter(appID: id, privacyURL: " https://acme.example/privacy ", note: "Subscriptions renew monthly. ")
        #expect(settings.privacyURL == "https://acme.example/privacy")
        #expect(settings.effectiveEULA == LegalFooter.appleStandardEULA)

        _ = try await workbench.saveDraft(appID: id, locale: .deDE, fields: MetadataFields(name: "Acme Notizen", description: "Schreib es auf."), now: now)
        let first = try await workbench.insertLegalFooter(appID: id, now: now)
        #expect(first == Engine.MetadataBatch(changed: ["de-DE", "en-US"], locales: 2))
        let german = try await workbench.metadata(appID: id, locale: .deDE)
        #expect(german.draft.description.hasPrefix("Schreib es auf.\n\n"))
        #expect(german.draft.description.contains("Datenschutzrichtlinie: https://acme.example/privacy"))
        #expect(german.draft.description.contains("Subscriptions renew monthly."))
        #expect(german.legal.inDescription)
        #expect(try await workbench.insertLegalFooter(appID: id, now: now).changed.isEmpty)

        _ = try await workbench.setLegalFooter(appID: id, enabled: false)
        await #expect(throws: EngineError.self) { try await workbench.insertLegalFooter(appID: id) }
    }

    @Test("Empty release notes get the default note in each locale's language")
    func whatsNew() async throws {
        let workbench = try await engine()
        let id = ownApp.trackID
        _ = try await workbench.saveDraft(appID: id, locale: .enUS, fields: MetadataFields(name: "Acme Notes", whatsNew: "New export."), now: now)
        let filled = try await workbench.fillEmptyWhatsNew(appID: id, now: now)
        #expect(filled.changed == ["de-DE"])
        #expect(try await workbench.metadata(appID: id, locale: .deDE).draft.whatsNew == ReleaseNotesDefaults.text(for: .deDE))
        #expect(try await workbench.metadata(appID: id, locale: .enUS).draft.whatsNew == "New export.")
    }

    @Test("The commands save drafts from options or JSON, set baselines and say what is wrong")
    func commands() async throws {
        let harness = try Harness()
        let id = String(ownApp.trackID)
        #expect(await harness.run(["app", "add", id]).code == 0)
        #expect(await harness.run(["metadata", "baseline", id, "--locale", "en-US", "--name", "Acme Notes", "--keywords", "notes,memo"]).code == 0)
        let draft = await harness.run(["metadata", "draft", id, "--locale", "en-US", "--keywords", "notes,diary"])
        #expect(draft.code == 0)
        #expect(draft.console.output.contains("Keywords: + diary · − memo · 1 kept"))
        #expect(draft.console.output.contains("Name (10/30):\n  Acme Notes"))

        let json = #"{"name":"Acme Notes","subtitle":"Daily journal","keywords":"notes","promotionalText":"","description":"Hi","whatsNew":""}"#
        #expect(await harness.run(["metadata", "draft", id, "--locale", "en-US", "--stdin"], input: json).code == 0)
        let shown = await harness.run(["--json", "metadata", "show", id])
        #expect(shown.console.output.contains("\"subtitle\" : \"Daily journal\""))
        let locales = await harness.run(["metadata", "locales", id])
        #expect(locales.console.output.contains("en-US"))
        #expect(locales.console.output.contains("manual"))

        #expect(await harness.run(["metadata", "draft", id, "--keywords", "x"]).code == 64)
        #expect(await harness.run(["metadata", "draft", id, "--locale", "xx-XX", "--keywords", "x"]).code == 64)
        #expect(await harness.run(["metadata", "draft", id, "--locale", "en-US"]).code == 64)
        #expect(await harness.run(["metadata", "draft", id, "--locale", "en-US", "--stdin", "--name", "x"], input: json).code == 64)
        #expect(await harness.run(["metadata", "draft", id, "--locale", "en-US", "--stdin"], input: "not json").code == 64)
        #expect(await harness.run(["metadata", "legal", id, "--on", "--off"]).code == 64)
        let legal = await harness.run(["metadata", "legal", id, "--privacy", "https://acme.example/privacy"])
        #expect(legal.console.output.hasPrefix("Legal footer on · Terms of Use \(LegalFooter.appleStandardEULA) (Apple's standard EULA)"))
        #expect(await harness.run(["metadata", "footer", id]).console.output == "Legal footer added to 1 of 1 draft(s): en-US.")
        #expect(await harness.run(["metadata", "fill-whats-new", id]).console.output
                == "What's New filled with the default note in 1 of 1 locale(s): en-US.")
        let all = await harness.run(["locales"]).console.output.split(separator: "\n")
        #expect(all.count == AppLocale.allCases.count)
        #expect(all.contains { $0.hasPrefix("de-DE  ") })
    }
}
