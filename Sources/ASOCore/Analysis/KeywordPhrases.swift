import Foundation

/// Keyword candidates from listing text: the most frequent words and two-word phrases, filler removed.
public enum KeywordPhrases {
    /// Words of three or more letters (not filler, not numbers) and the pairs they form, most frequent first, ties
    /// alphabetical. `Inkwave: Manga Webtoon Maker` → inkwave, maker, manga, webtoon, inkwave manga, manga webtoon, webtoon maker.
    public static func from(_ text: String, maxUnigrams: Int = 60, maxBigrams: Int = 60) -> [String] {
        let words = ASORules.words(text).filter { $0.count >= 3 && !ASORules.fillerWords.contains($0) && !$0.allSatisfy(\.isNumber) }
        var unigrams: [String: Int] = [:], bigrams: [String: Int] = [:]
        for (i, word) in words.enumerated() {
            unigrams[word, default: 0] += 1
            if i + 1 < words.count { bigrams["\(word) \(words[i + 1])", default: 0] += 1 }
        }
        return top(unigrams, maxUnigrams) + top(bigrams, maxBigrams)
    }

    private static func top(_ counts: [String: Int], _ limit: Int) -> [String] {
        counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(limit).map(\.key)
    }
}
