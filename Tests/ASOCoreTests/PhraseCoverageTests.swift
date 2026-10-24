import Testing
import ASOCore

@Suite("Phrase coverage (same rule the writer and the Metadata panel use)")
struct PhraseCoverageTests {
    func covers(_ f: MetadataFields, _ phrase: String) -> Bool { KeywordPlan.covers(f, phrase: phrase) }

    @Test func wordsAcrossFieldsCount() {
        let f = MetadataFields(name: "Inkwave: Manga Comic Maker", subtitle: "Selfie to Webtoon Hero", keywords: "avatar,manhwa,generator")
        #expect(covers(f, "comic maker"))
        #expect(covers(f, "manga generator"))      // words from two different fields
        #expect(covers(f, "comics"))               // plural twin of a title word
        #expect(!covers(f, "comic reader"))        // "reader" nowhere
    }
}

@Suite("House punctuation")
struct PlainPunctuationTests {
    @Test func dashesBecomeCommasAndBullets() {
        let text = "Plan every meal — from purées to finger food.\n- Weekly plan\n- 150+ guides\nFrom 6–24 months."
        let out = ASORules.plainPunctuation(text)
        #expect(!out.contains("—"))
        #expect(out.contains("Plan every meal, from purées"))
        #expect(out.contains("\n• Weekly plan\n• 150+ guides"))
        #expect(out.contains("6–24 months"))     // numeric ranges stay
    }
}
