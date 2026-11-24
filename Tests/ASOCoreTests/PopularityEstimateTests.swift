import Foundation
import Testing
@testable import ASOCore

@Suite("Popularity estimate")
struct PopularityEstimateTests {
    @Test("A value only above the gate, clamped to 30–100; below it the probability of being below the range")
    func decide() {
        func decide(_ p: Double, _ value: Double?) -> PopularityEstimate? { PopularityEstimate.decide(publishedProbability: p) { value } }
        let unsure: PopularityEstimate? = .below(probability: 1 - 0.6)
        #expect(decide(0.6, 50) == unsure)
        #expect(decide(0.8, 12.4) == PopularityEstimate.published(value: 30, probability: 0.8))
        #expect(decide(0.8, 142) == PopularityEstimate.published(value: 100, probability: 0.8))
        #expect(decide(0.8, 55.6) == PopularityEstimate.published(value: 56, probability: 0.8))
        #expect(decide(0.9, nil) == nil)
        #expect(PopularityEstimate.published(value: 40, probability: 0.8).publishedProbability == 0.8)
        #expect(abs(PopularityEstimate.below(probability: 0.7).publishedProbability - 0.3) < 1e-12)
    }

    @Test("The sub-floor rank counts the breakpoints below the probability; a value off the list stays under its floor")
    func ranksAndCaps() {
        let quantiles = (1...23).map { Double($0) / 24 }
        #expect(PopularityEstimate.subFloor(publishedProbability: 0, quantiles: quantiles) == 6)
        #expect(PopularityEstimate.subFloor(publishedProbability: 1, quantiles: quantiles) == 29)
        #expect(PopularityEstimate.subFloor(publishedProbability: 0.5, quantiles: [0.1]) == nil)
        #expect(PopularityEstimate.capped(55, belowListFloor: 41) == 40)
        #expect(PopularityEstimate.capped(55, belowListFloor: nil) == 55)
        #expect(PopularityEstimate.capped(55, belowListFloor: 20) == 30)
    }

    @Test("The bundled models load with their report and estimate; no suggestions at all is below the range")
    func bundled() throws {
        let model = try PopularityModel(directory: TreeModelTests.models)
        #expect(model.floorQuantiles.count == 23)
        var silent = PublicFeatures(term: "zqxv")
        silent.ownHintCount = 0
        silent.firstWordHintCount = 0
        silent.prefixHintCount = 0
        #expect(model.estimate(features: silent, jev: nil, storefront: "US") == .below(probability: 0.95))
        let sample = TreeModelTests.samples()[1]
        #expect(model.estimate(features: sample.features, jev: sample.jev, storefront: sample.storefront) != nil)
        // A storefront the models were not trained on: no estimate, as with CoreML.
        #expect(model.estimate(features: sample.features, jev: sample.jev, storefront: "JP") == nil)
    }
}
