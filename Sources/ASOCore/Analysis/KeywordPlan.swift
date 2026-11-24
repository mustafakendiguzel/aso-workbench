import Foundation

/// The evidence-ranked plan the writer follows and the Metadata editor shows as keyword coverage: which tracked phrases to
/// cover, which to avoid.
public struct KeywordPlan: Sendable, Codable, Equatable {
    /// One tracked keyword with its evidence.
    public struct Input: Sendable, Equatable {
        public let term: String
        /// Apple's 1–100 score; nil without one.
        public let popularity: Int?
        /// The model's estimate, used under Apple's published floor.
        public let estimate: Int?
        public let popularitySource: String
        public let difficulty: Double?
        public let fit: Double?
        public let brandLike: Bool
        /// Results looked at in the latest measurement (nil: never measured) and the app's position in them.
        public let observedCount: Int?
        public let rank: Int?

        public init(term: String, popularity: Int?, estimate: Int? = nil, popularitySource: String, difficulty: Double?, fit: Double?,
                    brandLike: Bool, observedCount: Int?, rank: Int?) {
            self.term = term
            self.popularity = popularity
            self.estimate = estimate
            self.popularitySource = popularitySource
            self.difficulty = difficulty
            self.fit = fit
            self.brandLike = brandLike
            self.observedCount = observedCount
            self.rank = rank
        }
    }

    public struct Item: Sendable, Codable, Equatable, Identifiable {
        public var id: String { term }
        public let term: String
        public let popularity: Int?
        public let popularitySource: String
        public let difficulty: Int?
        public let fit: Double?
        /// "#4", "not in top 200", or nil when never measured.
        public let rank: String?
        public let score: Double
        /// "A" winnable now · "B" reachable · "C" popular but hard · "X" avoided (brand, unrelated, too hard)
        public let tier: String

        public init(term: String, popularity: Int?, popularitySource: String, difficulty: Int?, fit: Double?, rank: String?, score: Double, tier: String) {
            self.term = term
            self.popularity = popularity
            self.popularitySource = popularitySource
            self.difficulty = difficulty
            self.fit = fit
            self.rank = rank
            self.score = score
            self.tier = tier
        }
    }

    public var priority: [Item] = []
    public var avoid: [Item] = []

    public init(priority: [Item] = [], avoid: [Item] = []) {
        self.priority = priority
        self.avoid = avoid
    }

    public var tierA: [Item] { priority.filter { $0.tier == "A" } }
    public var tierB: [Item] { priority.filter { $0.tier == "B" } }
    public var tierC: [Item] { priority.filter { $0.tier == "C" } }

    /// Apple publishes popularity from this score up; below it the model's estimate stands in.
    public static let publishedFloor = 30

    /// At most this many phrases to cover.
    public static let size = 14

    /// A phrase counts as covered when every one of its words (or its plural twin) appears across the indexed fields.
    public static func covers(_ fields: MetadataFields, phrase: String) -> Bool {
        let words = Set(ASORules.words(fields.name) + ASORules.words(fields.subtitle) + ASORules.words(fields.keywords))
        return ASORules.words(phrase).allSatisfy { w in words.contains(w) || words.contains(w + "s") || (w.hasSuffix("s") && words.contains(String(w.dropLast()))) }
    }

    /// Ranks the market's tracked keywords the way a small app wins: tier A = winnable now (difficulty ≤ easy, or already
    /// top 10), tier B = reachable, tier C = popular but hard. Within a tier, popularity first, then lower difficulty.
    /// Brands, unrelated terms and hard low-demand terms go to `avoid`.
    public static func make(_ keywords: [Input], easyDifficulty: Int = 35, maxDifficulty: Int = 55, publishedFloor: Int = publishedFloor) -> KeywordPlan {
        var plan = KeywordPlan()
        for k in keywords {
            let apple = k.popularity
            let value = ((apple ?? 0) < publishedFloor ? (k.estimate ?? apple) : apple) ?? 0
            let d = k.difficulty ?? 50
            var tier: String
            if k.brandLike || (k.fit ?? 1) < 0.5 { tier = "X" }
            else if let r = k.rank, r <= 10 { tier = "A" }
            else if d <= Double(easyDifficulty) { tier = "A" }
            else if d <= Double(maxDifficulty) { tier = "B" }
            else if value >= 50 { tier = "C" }
            else { tier = "X" }
            let score = Double(value) * (1 - pow(d / 100, 3))
            let rank = k.observedCount.map { count in k.rank.map { "#\($0)" } ?? "not in top \(count)" }
            let item = Item(term: k.term, popularity: value, popularitySource: k.popularitySource, difficulty: k.difficulty.map { Int($0.rounded()) },
                            fit: k.fit, rank: rank, score: score, tier: tier)
            if tier == "X" { plan.avoid.append(item) } else { plan.priority.append(item) }
        }
        let order = ["A": 0, "B": 1, "C": 2]
        plan.priority.sort {
            if order[$0.tier]! != order[$1.tier]! { return order[$0.tier]! < order[$1.tier]! }
            if ($0.popularity ?? 0) != ($1.popularity ?? 0) { return ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            return ($0.difficulty ?? 50) < ($1.difficulty ?? 50)
        }
        plan.priority = Array(plan.priority.prefix(size))
        return plan
    }
}
