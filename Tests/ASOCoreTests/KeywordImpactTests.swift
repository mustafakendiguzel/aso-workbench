import Testing
@testable import ASOCore

@Suite("Keyword impact")
struct KeywordImpactTests {
    @Test("Visibility follows the App Store curve and is 0 outside the results")
    func visibility() {
        let ranks: [Int?] = [1, 2, 3, 4, 5, 6, 10, 11, 20, 21, 50, 51, 100, 101, nil, 0]
        let expected: [Double] = [100, 90, 80, 65, 65, 50, 50, 25, 25, 8, 8, 2, 2, 0.5, 0, 0]
        #expect(ranks.map(KeywordImpact.visibility) == expected)
    }

    @Test("Value is popularity × beatable difficulty × fit, and nothing for brands, unrelated terms or no popularity")
    func value() {
        #expect(KeywordImpact.value(popularity: 60, difficulty: 50, isBrandLike: false, fit: 0.9) == 45)
        #expect(KeywordImpact.value(popularity: 60, difficulty: 50, isBrandLike: false, fit: nil) == 36)   // unchecked fit counts 0.8
        #expect(KeywordImpact.value(popularity: 60, difficulty: nil, isBrandLike: false, fit: 0.9) == 45)  // unmeasured difficulty counts 50
        #expect(KeywordImpact.value(popularity: 60, difficulty: 100, isBrandLike: false, fit: 0.9) == 0)
        #expect(KeywordImpact.value(popularity: 60, difficulty: 20, isBrandLike: true, fit: 0.9) == 0)
        #expect(KeywordImpact.value(popularity: 60, difficulty: 20, isBrandLike: false, fit: 0.4) == 0)
        #expect(KeywordImpact.value(popularity: nil, difficulty: 20, isBrandLike: false, fit: 0.9) == 0)
    }

    @Test("Gain is the visibility change weighted by value; a worthless keyword moves nothing")
    func gain() {
        #expect(KeywordImpact.gain(before: 12, after: 3, value: 40) == 22)       // 25 → 80
        #expect(KeywordImpact.gain(before: 3, after: nil, value: 40) == -32)     // 80 → out
        #expect(KeywordImpact.gain(before: 150, after: 1, value: 0) == 0)
    }

    @Test("Tiers: high from 40, medium from 15, low above 0")
    func tiers() {
        #expect(KeywordImpact.tier(40) == .high)
        #expect(KeywordImpact.tier(39.9) == .medium)
        #expect(KeywordImpact.tier(15) == .medium)
        #expect(KeywordImpact.tier(14.9) == .low)
        #expect(KeywordImpact.tier(0.001) == .low)
        #expect(KeywordImpact.tier(0) == KeywordImpact.Tier.none)
        #expect(KeywordImpact.Tier.allCases.map(\.rawValue) == ["High", "Medium", "Low", "None"])
    }
}
