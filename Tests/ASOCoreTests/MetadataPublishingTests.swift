import Testing
@testable import ASOCore

@Suite("Metadata publishing")
struct MetadataPublishingTests {
    let fields = MetadataFields(name: "Acme Notes", subtitle: "Journal", keywords: "notes,memo", promotionalText: "", description: "Write.",
                                whatsNew: "Fixes.")

    @Test("Only versions still being prepared or sent back can take a new listing")
    func editableStates() {
        #expect(MetadataPublishing.isEditable(versionState: "PREPARE_FOR_SUBMISSION"))
        #expect(MetadataPublishing.isEditable(versionState: "METADATA_REJECTED"))
        #expect(!MetadataPublishing.isEditable(versionState: "READY_FOR_SALE"))
        #expect(!MetadataPublishing.isEditable(versionState: nil))
    }

    @Test("A listing counts as changed since the pull only when there was a pull and the text differs")
    func changedSincePull() {
        var edited = fields
        edited.subtitle = "Diary"
        #expect(!MetadataPublishing.changedSincePull(baseline: nil, live: edited))
        #expect(!MetadataPublishing.changedSincePull(baseline: fields, live: fields))
        #expect(MetadataPublishing.changedSincePull(baseline: fields, live: edited))
    }

    @Test("The payload carries each change's new text, and the re-read decides applied or partial")
    func payloadAndOutcome() {
        var draft = fields
        draft.keywords = "notes,journal"
        draft.promotionalText = "New."
        let changes = MetadataDiff.changes(baseline: fields, draft: draft)
        #expect(MetadataPublishing.payload(changes) == [.keywords: "notes,journal", .promotionalText: "New."])

        #expect(MetadataPublishing.outcome(draft: draft, reread: draft).status == "applied")
        var reread = draft
        reread.promotionalText = ""
        let partial = MetadataPublishing.outcome(draft: draft, reread: reread)
        #expect(partial.status == "partial")
        #expect(partial.differing == [.promotionalText])
        #expect(partial.note == "Re-read differs from the draft for: Promotional Text.")
    }

    @Test("Timeline titles and screenshot notes read as the macOS app writes them")
    func wording() {
        #expect(MetadataPublishing.markerTitle(fields: [.subtitle, .keywords], locale: "de-DE") == "Applied Subtitle, Keywords (de-DE)")
        #expect(MetadataPublishing.screenshotNote(sets: 2, copied: 5, skipped: 0, errors: []) == " Screenshots: 5 copied in 2 set(s).")
        #expect(MetadataPublishing.screenshotNote(sets: 1, copied: 1, skipped: 3, errors: ["APP_IPHONE_67 #2: not yet processed by Apple"])
                == " Screenshots: 1 copied in 1 set(s), 3 already present, 1 failed (APP_IPHONE_67 #2: not yet processed by Apple).")
    }
}
