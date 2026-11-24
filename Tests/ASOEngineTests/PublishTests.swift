import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

@Suite("Publishing to App Store Connect")
struct PublishTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let id = ownApp.trackID
    let english = MetadataFields(name: "Acme Notes", subtitle: "Journal and diary", keywords: "notes,planner,memo", promotionalText: "",
                                 description: "Write it down.", whatsNew: "Bug fixes.")

    /// The app tracked in the United States and Germany, with the legal footer off unless a test turns it on.
    func engine(_ publisher: FakePublisher) async throws -> Engine {
        let engine = try makeEngine(publisher: publisher)
        _ = try await engine.addApp(reference: String(id))
        _ = try await engine.addMarket(appID: id, countryCode: "US", device: .iPhone)
        _ = try await engine.addMarket(appID: id, countryCode: "DE", device: .iPhone)
        _ = try await engine.setLegalFooter(appID: id, enabled: false)
        return engine
    }

    @Test("A data file from schema 8 gains the App Store Connect ID and the change log")
    func migrationFromSchemaEight() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(8) { try db.execute(step) }
            try db.setUserVersion(8)
            try db.query("INSERT INTO apps (track_id, name, seller_name, created_at) VALUES (1, 'Acme', 'Acme Inc', 0)")
        }
        let store = try Store(url: url)
        #expect(try await store.schemaVersion == Store.migrations.count)
        #expect(try await store.ascAppID(appID: 1) == nil)
        #expect(try await store.changeLog(appID: 1).isEmpty)
    }

    @Test("Without the App Store Connect key, publishing says how to connect it")
    func notConnected() async throws {
        let engine = try makeEngine()
        _ = try await engine.addApp(reference: String(id))
        await #expect(throws: EngineError.invalidArgument(Engine.ascNotConnected)) { try await engine.pullMetadata(appID: id) }
    }

    @Test("A pull keeps every locale as the baseline, finds the app by bundle ID once and fills the privacy policy address")
    func pull() async throws {
        let publisher = FakePublisher(listing: [.enUS: english], privacyURL: "https://example.com/privacy")
        let workbench = try await engine(publisher)
        let typed = MetadataFields(name: "Acme Notizen", subtitle: "", keywords: "", promotionalText: "", description: "", whatsNew: "")
        _ = try await workbench.setManualBaseline(appID: id, locale: .deDE, fields: typed, now: now)

        let pull = try await workbench.pullMetadata(appID: id, now: now)
        #expect(pull.locales == ["en-US"])
        #expect(pull.version == "2.0")
        #expect(pull.editable)
        #expect(pull.privacyURL == "https://example.com/privacy")
        #expect(try await workbench.store.ascAppID(appID: id) == "asc-\(ownApp.bundleID!)")

        let baselines = try await workbench.store.baselines(appID: id)
        #expect(baselines.map(\.locale) == ["de-DE", "en-US"])
        #expect(baselines.map(\.source) == ["manual", "asc"])
        #expect(baselines[1].versionLocalizationID == "version-en-US")
        // A second pull keeps the address already set.
        #expect(try await workbench.pullMetadata(appID: id, now: now).privacyURL == nil)
        #expect(publisher.writes.isEmpty)
    }

    @Test("The plan shows what would be sent, with the automatic legal footer and release notes, and writes nothing")
    func plan() async throws {
        let publisher = FakePublisher(listing: [.enUS: english])
        let workbench = try await engine(publisher)
        _ = try await workbench.pullMetadata(appID: id, now: now)
        _ = try await workbench.setLegalFooter(appID: id, enabled: true, privacyURL: "https://example.com/privacy")
        var draft = english
        draft.keywords = "notes,planner,journal"
        draft.whatsNew = ""
        _ = try await workbench.saveDraft(appID: id, locale: .enUS, fields: draft, now: now)

        let plan = try await workbench.publishPlan(appID: id, locale: .enUS)
        #expect(plan.exists)
        #expect(plan.blocked == nil)
        #expect(plan.automatic.count == 2)
        #expect(plan.changes.map(\.field) == [.keywords, .description, .whatsNew])
        #expect(plan.draft.description.contains("Privacy Policy: https://example.com/privacy"))
        #expect(plan.draft.whatsNew == ReleaseNotesDefaults.text(for: .enUS))
        #expect(publisher.writes.isEmpty)
        #expect(try await workbench.metadata(appID: id, locale: .enUS).draft == draft)
    }

    @Test("Applying writes the changed fields, re-reads them as the baseline, logs the change and marks the timeline")
    func apply() async throws {
        let publisher = FakePublisher(listing: [.enUS: english])
        let workbench = try await engine(publisher)
        _ = try await workbench.pullMetadata(appID: id, now: now)
        var draft = english
        draft.subtitle = "Journal, diary and memos"
        draft.keywords = "notes,planner,journal"
        _ = try await workbench.saveDraft(appID: id, locale: .enUS, fields: draft, now: now)

        let result = try await workbench.publish(appID: id, locale: .enUS, now: now)
        #expect(result.status == "applied")
        #expect(result.changes.map(\.field) == [.subtitle, .keywords])
        #expect(publisher.writes == ["apply en-US keywords,subtitle"])

        let report = try await workbench.metadata(appID: id, locale: .enUS)
        #expect(report.baseline?.fields == draft)
        #expect(report.changes.isEmpty)
        let log = try await workbench.changeLog(appID: id)
        #expect(log.map(\.status) == ["applied"])
        #expect(log[0].resultHash == MetadataHasher.hash(draft))
        let markers = try await workbench.markers(appID: id)
        #expect(markers.map(\.kind) == ["change"])
        #expect(markers[0].title == "Applied Subtitle, Keywords (en-US)")

        let again = try await workbench.publish(appID: id, locale: .enUS, now: now)
        #expect(again.status == "refused")
        #expect(publisher.writes.count == 1)
    }

    @Test("A listing edited on App Store Connect since the pull is not overwritten; the baseline is refreshed instead")
    func changedSincePull() async throws {
        let publisher = FakePublisher(listing: [.enUS: english])
        let workbench = try await engine(publisher)
        _ = try await workbench.pullMetadata(appID: id, now: now)
        var draft = english
        draft.keywords = "notes,planner,journal"
        _ = try await workbench.saveDraft(appID: id, locale: .enUS, fields: draft, now: now)
        publisher.edit(.enUS) { $0.subtitle = "Edited by a teammate" }

        #expect(try await workbench.publishPlan(appID: id, locale: .enUS).blocked == MetadataPublishing.changedRemotely)
        let result = try await workbench.publish(appID: id, locale: .enUS, now: now)
        #expect(result.status == "refused")
        #expect(publisher.writes.isEmpty)
        #expect(try await workbench.metadata(appID: id, locale: .enUS).baseline?.fields.subtitle == "Edited by a teammate")
        // Reviewed against the new baseline, the draft can go.
        #expect(try await workbench.publish(appID: id, locale: .enUS, now: now).status == "applied")
    }

    @Test("A locale Apple does not have is only created when asked, with screenshots copied from another locale")
    func missingLocale() async throws {
        let publisher = FakePublisher(listing: [.enUS: english])
        let workbench = try await engine(publisher)
        let german = MetadataFields(name: "Acme Notizen", subtitle: "Tagebuch", keywords: "notizen,planer", promotionalText: "",
                                    description: "Schreib es auf.", whatsNew: "Fehlerbehebungen.")
        _ = try await workbench.saveDraft(appID: id, locale: .deDE, fields: german, now: now)

        let refused = try await workbench.publish(appID: id, locale: .deDE, now: now)
        #expect(refused.status == "refused")
        #expect(refused.message.contains("does not exist"))
        #expect(publisher.writes.isEmpty)

        let results = try await workbench.publishAll(appID: id, copyScreenshotsFrom: .enUS, now: now)
        #expect(results.map(\.locale) == ["de-DE"])
        #expect(results[0].status == "applied")
        #expect(results[0].screenshots?.copied == 6)
        #expect(publisher.writes == ["create de-DE", "screenshots version-en-US → version-de-DE",
                                     "apply de-DE description,keywords,subtitle,whatsNew"])
        #expect(try await workbench.metadata(appID: id, locale: .deDE).baseline?.fields == german)
    }

    @Test("A re-read that differs is partial, a rejected write is logged as failed, and a live version is not written")
    func partialFailedAndFrozen() async throws {
        var draft = english
        draft.keywords = "notes,planner,journal"
        draft.promotionalText = "Now with folders."

        let stubborn = FakePublisher(listing: [.enUS: english], ignored: [.promotionalText])
        let partial = try await engine(stubborn)
        _ = try await partial.saveDraft(appID: id, locale: .enUS, fields: draft, now: now)
        let result = try await partial.publish(appID: id, locale: .enUS, now: now)
        #expect(result.status == "partial")
        #expect(result.message.contains("Promotional Text"))

        let rejecting = FakePublisher(listing: [.enUS: english], failing: true)
        let failed = try await engine(rejecting)
        _ = try await failed.saveDraft(appID: id, locale: .enUS, fields: draft, now: now)
        #expect(try await failed.publish(appID: id, locale: .enUS, now: now).status == "failed")
        let log = try await failed.changeLog(appID: id)
        #expect(log.map(\.status) == ["failed"])
        #expect(log[0].note.contains("409"))
        #expect(try await failed.markers(appID: id).isEmpty)

        let live = FakePublisher(listing: [.enUS: english], versions: [Engine.ASCVersion(id: "v1", version: "1.0", state: "READY_FOR_SALE")])
        let frozen = try await engine(live)
        _ = try await frozen.saveDraft(appID: id, locale: .enUS, fields: draft, now: now)
        let plan = try await frozen.publishPlan(appID: id, locale: .enUS)
        #expect(!plan.editable)
        #expect(plan.blocked?.contains("No editable version") == true)
        #expect(try await frozen.publish(appID: id, locale: .enUS, now: now).status == "refused")
        #expect(live.writes.isEmpty)
    }

    @Test("The next version is created only when none can be edited and the number looks like a version")
    func createVersion() async throws {
        let open = FakePublisher(listing: [.enUS: english])
        let editable = try await engine(open)
        await #expect(throws: EngineError.self) { try await editable.createVersion(appID: id, version: "2.1") }

        let live = FakePublisher(listing: [.enUS: english], versions: [Engine.ASCVersion(id: "v1", version: "1.0", state: "READY_FOR_SALE")])
        let workbench = try await engine(live)
        await #expect(throws: EngineError.self) { try await workbench.createVersion(appID: id, version: "two") }
        let created = try await workbench.createVersion(appID: id, version: "1.1")
        #expect(created.editable)
        #expect(live.writes == ["create-version 1.1"])
        #expect(try await workbench.ascVersions(appID: id).map(\.version) == ["1.1", "1.0"])
    }

    @Test("The command line shows the plan and sends nothing without --yes")
    func commands() async throws {
        let publisher = FakePublisher(listing: [.enUS: english])
        let harness = try Harness(publisher: publisher)
        _ = try await harness.engine.addApp(reference: String(id))
        _ = try await harness.engine.addMarket(appID: id, countryCode: "US", device: .iPhone)
        _ = try await harness.engine.setLegalFooter(appID: id, enabled: false)
        let app = String(id)

        #expect(await harness.run(["metadata", "pull", app]).code == 0)
        #expect(await harness.run(["metadata", "draft", app, "--locale", "en-US", "--keywords", "notes,planner,journal"]).code == 0)

        let unconfirmed = await harness.run(["metadata", "apply", app, "--locale", "en-US"])
        #expect(unconfirmed.code == 1)
        #expect(unconfirmed.console.output.contains("Keywords: \"notes,planner,memo\" → \"notes,planner,journal\""))
        #expect(unconfirmed.console.errors.contains("Nothing was sent"))
        #expect(publisher.writes.isEmpty)

        let applied = await harness.run(["metadata", "apply", app, "--locale", "en-US", "--yes", "--json"])
        #expect(applied.code == 0)
        #expect(applied.console.output.contains("\"status\" : \"applied\""))
        #expect(publisher.writes.count == 1)

        let log = await harness.run(["metadata", "log", app])
        #expect(log.console.output.contains("applied"))
        #expect(await harness.run(["metadata", "create-version", app, "2.1"]).code == 1)
        #expect(await harness.run(["metadata", "apply", app, "--locale", "en-US", "--copy-screenshots-from", "de-DE", "--yes"]).code == 64)
        #expect(publisher.writes.count == 1)
    }
}
