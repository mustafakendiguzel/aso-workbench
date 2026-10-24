import Foundation

/// Whether a published search term is a gap a new app could fill: real demand, an app-shaped need, nobody's brand
/// (by Jev and by the results) and beatable results.
public struct IdeaGap: Sendable {
    public let term: String
    public let normalized: String
    public let difficulty: Double?
    /// Jev: brand probability.
    public let brand: Double?
    /// Jev: does the term sound like real demand.
    public let natural: Double?
    /// Jev: could a standalone iPhone app serve this search at all.
    public let appable: Double?
    /// Jev, shown the top results: probability the search is a way of finding one specific app.
    public let navigational: Double?
    /// From the results, see `resultFlags`. Nil = not derived yet.
    public let leaderOwnsTerm: Bool?
    public let nameCrowd: Bool?

    public init(term: String, normalized: String, difficulty: Double?, brand: Double?, natural: Double?, appable: Double?,
                navigational: Double?, leaderOwnsTerm: Bool?, nameCrowd: Bool?) {
        self.term = term
        self.normalized = normalized
        self.difficulty = difficulty
        self.brand = brand
        self.natural = natural
        self.appable = appable
        self.navigational = navigational
        self.leaderOwnsTerm = leaderOwnsTerm
        self.nameCrowd = nameCrowd
    }

    /// "free / gratis / kostenlos …": people who type it will not pay, so it is no lead for a new app.
    public static let freeWords: Set<String> = ["free", "gratis", "kostenlos", "gratuit", "gratuite", "gratuito", "gratuita", "бесплатно", "бесплатный", "бесплатные", "ücretsiz", "bedava", "無料", "免费", "免費", "darmowe", "darmowy", "zdarma", "ingyenes"]

    public static func wantsFree(normalized: String) -> Bool {
        normalized.split(separator: " ").contains { freeWords.contains(String($0)) } || normalized.contains("無料") || normalized.contains("免费")
    }

    public var wantsFree: Bool { Self.wantsFree(normalized: normalized) }

    public func isGap(maxDifficulty: Int) -> Bool {
        guard let d = difficulty, d <= Double(maxDifficulty) else { return false }
        return (brand ?? 0) < 0.5 && (natural ?? 1) >= 0.5 && (appable ?? 1) >= 0.5 && leaderOwnsTerm != true && nameCrowd != true && (navigational ?? 0) < 0.6 && !wantsFree
    }

    /// Flags derived from a measurement's top results.
    /// - `leaderOwnsTerm`: names align and either nobody else carries the name or the leader dwarfs the field: people want that app.
    /// - `nameCrowd`: a single word that eight or more small apps already carry in their names (a name, not a need).
    public static func resultFlags(term: String, normalized: String, leaderName: String, leaderRatings: Int?, medianRatings: Int?,
                                   titleMatches: Int?) -> (leaderOwnsTerm: Bool, nameCrowd: Bool) {
        let ratings = leaderRatings ?? 0
        let median = medianRatings ?? 0
        let leaderOwnsTerm = TitleMatch.namesAlign(leader: leaderName, term: term) && ((titleMatches ?? 0) <= 2 || ratings >= max(200, 5 * median))
        let singleWord = !normalized.contains(" ")
        let nameCrowd = singleWord && (titleMatches ?? 0) >= 8 && ratings < 1_000
        return (leaderOwnsTerm, nameCrowd)
    }
}
