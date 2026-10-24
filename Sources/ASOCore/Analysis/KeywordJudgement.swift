import Foundation

/// Keyword text as it is stored and compared: trimmed, lowercased, inner whitespace collapsed to one space.
public enum KeywordText {
    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

public enum Opportunity {
    /// popularity × (1 − (difficulty/100)²): demand, discounted quadratically by competition.
    public static func score(popularity: Int, difficulty: Double) -> Double {
        Double(popularity) * (1 - pow(difficulty / 100, 2))
    }
}

/// Every verdict about one tracked keyword (brand, golden, lead), drawn from what was measured and what Jev said.
/// Absent inputs stay absent: no measurement means no brand-by-results verdict, unchecked fit counts as related.
public struct KeywordJudgement: Sendable {
    /// The app the keyword is tracked for.
    public struct OwnApp: Sendable, Hashable {
        public let trackID: Int
        public let name: String
        public let sellerName: String

        public init(trackID: Int, name: String, sellerName: String) {
            self.trackID = trackID
            self.name = name
            self.sellerName = sellerName
        }
    }

    /// The latest successful measurement: the results in order and the signals stored with them.
    public struct Measurement: Sendable {
        public let results: [SearchResultApp]
        public let signals: CompetitionSignals?

        public init(results: [SearchResultApp], signals: CompetitionSignals?) {
            self.results = results
            self.signals = signals
        }
    }

    public let term: String
    public let ownApp: OwnApp?
    public let measurement: Measurement?
    /// Jev: probability the term is a brand.
    public let brandProbability: Double?
    /// Jev, shown the actual top results: probability the term is a way of finding one specific app.
    public let navigational: Double?
    /// Jev: probability that someone searching this term wants an app like this one. Nil = not checked.
    public let fitProbability: Double?
    /// Latest popularity (5–100) when one is known.
    public let popularity: Int?

    public init(term: String, ownApp: OwnApp?, measurement: Measurement?, brandProbability: Double?, navigational: Double?,
                fitProbability: Double?, popularity: Int?) {
        self.term = term
        self.ownApp = ownApp
        self.measurement = measurement
        self.brandProbability = brandProbability
        self.navigational = navigational
        self.fitProbability = fitProbability
        self.popularity = popularity
    }

    /// Difficulty of the latest measurement: the stored one, else recomputed from the stored results.
    public var difficulty: DifficultyScore? {
        guard let m = measurement else { return nil }
        return Self.difficulty(signals: m.signals, results: m.results, term: term)
    }

    /// The stored difficulty when the signals carry one; the results are only read (and decoded by the caller) when they do not.
    public static func difficulty(signals: CompetitionSignals?, results: @autoclosure () -> [SearchResultApp], term: String) -> DifficultyScore? {
        signals?.difficulty ?? DifficultyScore(results: results(), term: term)
    }

    /// popularity × (1 − (difficulty/100)²). Nil without both inputs.
    public var opportunity: Double? {
        guard let p = popularity, let d = difficulty else { return nil }
        return Opportunity.score(popularity: p, difficulty: d.score)
    }

    /// Our own app is the first result: the term is ours, whatever else the results say.
    public var ownAppLeads: Bool {
        guard let leader = measurement?.results.first, let own = ownApp else { return false }
        return leader.trackID == own.trackID || (!own.sellerName.isEmpty && leader.sellerName == own.sellerName)
    }

    /// The term is our own name ("acme notes" for Acme Notes): a brand, but ours, always worth ranking for.
    public var isOwnBrandTerm: Bool {
        guard let own = ownApp else { return false }
        return TitleMatch.namesAlign(leader: own.name, term: term)
    }

    /// From the measured results: the top app carries the term's name and either nobody else does or it dwarfs the field.
    public var leaderOwnsTerm: Bool {
        guard let m = measurement, let leader = m.results.first, !ownAppLeads, !isOwnBrandTerm else { return false }
        let ratings = leader.ratingCount ?? 0
        let median = m.signals?.medianRatingCountTop10 ?? 0
        let titles = m.signals?.titleMatchesTop10 ?? 0
        // A nobody with our words in its name is not a destination; the leader must have real ratings to "own" a term.
        return TitleMatch.namesAlign(leader: leader.name, term: term) && ((titles <= 2 && ratings >= 50) || ratings >= max(200, 5 * median))
    }

    /// Another company's name by any of three signals: Jev on the term, Jev on the term with the results in view, or the results themselves.
    public var isBrandLike: Bool {
        if isOwnBrandTerm || ownAppLeads { return false }
        return (brandProbability ?? 0) >= 0.5 || (navigational ?? 0) >= 0.6 || leaderOwnsTerm
    }

    /// Demand, competition and brand checks pass, regardless of whether the term fits this app.
    public func passesGoldenNumbers(minPopularity: Int, maxDifficulty: Int) -> Bool {
        guard let p = popularity, p >= minPopularity, let d = difficulty, d.score <= Double(maxDifficulty) else { return false }
        return !isBrandLike
    }

    /// Golden for this app: the numbers pass and the term is what this app does (fit ≥ 0.5; unchecked counts as related).
    public func isGolden(minPopularity: Int, maxDifficulty: Int) -> Bool {
        passesGoldenNumbers(minPopularity: minPopularity, maxDifficulty: maxDifficulty) && (fitProbability ?? 1) >= 0.5
    }

    /// The numbers pass but the term is not what this app does, a lead for a different app, not a keyword for this one.
    public func isGoldenLead(minPopularity: Int, maxDifficulty: Int) -> Bool {
        passesGoldenNumbers(minPopularity: minPopularity, maxDifficulty: maxDifficulty) && (fitProbability ?? 1) < 0.5
    }
}
