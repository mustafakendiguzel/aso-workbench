import Testing
@testable import ASOCore

@Suite("Keyword phrases")
struct KeywordPhrasesTests {
    @Test("Words and pairs from a title, most frequent first, ties alphabetical")
    func title() {
        #expect(KeywordPhrases.from("Inkwave: Manga Webtoon Maker")
                == ["inkwave", "maker", "manga", "webtoon", "inkwave manga", "manga webtoon", "webtoon maker"])
    }

    @Test("Filler, short words and numbers are dropped before pairing; limits apply to each list")
    func filtering() {
        let text = "The best free notes app for 2026. Notes for work, notes for school, and AI notes."
        #expect(KeywordPhrases.from(text, maxUnigrams: 2, maxBigrams: 1) == ["notes", "school", "notes notes"])
        #expect(KeywordPhrases.from("", maxUnigrams: 5, maxBigrams: 5).isEmpty)
    }
}
