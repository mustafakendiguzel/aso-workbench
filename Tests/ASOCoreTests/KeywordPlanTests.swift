import Testing
@testable import ASOCore

@Suite("Keyword plan")
struct KeywordPlanTests {
    func keyword(_ term: String, popularity: Int? = 60, estimate: Int? = nil, difficulty: Double? = 40, fit: Double? = 0.9, brand: Bool = false,
                 rank: Int? = nil, measured: Bool = true) -> KeywordPlan.Input {
        KeywordPlan.Input(term: term, popularity: popularity, estimate: estimate, popularitySource: "list", difficulty: difficulty, fit: fit,
                          brandLike: brand, observedCount: measured ? 200 : nil, rank: rank)
    }

    @Test("Winnable first, then reachable, then popular but hard; brands, unrelated and hard low-demand terms are avoided")
    func tiers() {
        let plan = KeywordPlan.make([
            keyword("hard popular", popularity: 80, difficulty: 70),
            keyword("reachable", popularity: 40, difficulty: 50),
            keyword("easy", popularity: 30, difficulty: 20),
            keyword("top ten", popularity: 50, difficulty: 90, rank: 4),
            keyword("rival brand", brand: true),
            keyword("unrelated", fit: 0.2),
            keyword("hard quiet", popularity: 40, difficulty: 80),
        ])
        #expect(plan.priority.map(\.term) == ["top ten", "easy", "reachable", "hard popular"])
        #expect(plan.priority.map(\.tier) == ["A", "A", "B", "C"])
        #expect(plan.avoid.map(\.term) == ["rival brand", "unrelated", "hard quiet"])
        #expect(plan.tierA.count == 2)
        #expect(plan.priority[0].rank == "#4")
        #expect(plan.priority[1].rank == "not in top 200")
    }

    @Test("Under Apple's published floor the estimate counts; unmeasured keywords have no rank; at most 14 phrases")
    func evidence() {
        let plan = KeywordPlan.make([
            keyword("estimated", popularity: 5, estimate: 22, difficulty: 30, measured: false),
            keyword("listed", popularity: 45, estimate: 10, difficulty: 30),
            keyword("unknown", popularity: nil, difficulty: nil),
        ])
        #expect(plan.priority.map(\.popularity) == [45, 22, 0])
        #expect(plan.priority[1].rank == nil)
        // No difficulty counts as 50: reachable.
        #expect(plan.priority[2].tier == "B")
        #expect(plan.priority[2].difficulty == nil)

        let many = KeywordPlan.make((1...20).map { (n: Int) in keyword("term \(n)", popularity: n, difficulty: 10) })
        #expect(many.priority.count == KeywordPlan.size)
        #expect(many.priority.first?.term == "term 20")
    }

    @Test("Easy and reachable follow the writer tiers")
    func thresholds() {
        let input = [keyword("mid", difficulty: 45)]
        #expect(KeywordPlan.make(input).priority.first?.tier == "B")
        #expect(KeywordPlan.make(input, easyDifficulty: 50, maxDifficulty: 60).priority.first?.tier == "A")
        #expect(KeywordPlan.make(input, easyDifficulty: 20, maxDifficulty: 40).priority.first?.tier == "C")
    }
}
