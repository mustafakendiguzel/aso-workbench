import Foundation
import Testing
@testable import ASOCore
#if canImport(CoreML)
import CoreML
#endif

@Suite("Tree models")
struct TreeModelTests {
    static let models = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources").appendingPathComponent("models")
    static var regressorURL: URL { models.appendingPathComponent("popularity-regressor.mlmodel") }
    static var classifierURL: URL { models.appendingPathComponent("popularity-published.mlmodel") }

    /// Varied inputs across the feature space: terms of different shapes, with and without hints and results, and Jev's answers
    /// collected or not (the genre is always one the models know: they reject unknown categories, as CoreML does).
    static func samples() -> [(features: PublicFeatures, jev: JevFeatures?, storefront: String)] {
        var out: [(PublicFeatures, JevFeatures?, String)] = []
        let terms = ["notes", "budget planner", "habit tracker for kids", "ai photo editor", "uhr", "çeviri"]
        let storefronts = ["US", "DE", "GB", "TR", "FR"]
        for (i, term) in terms.enumerated() {
            for (k, storefront) in storefronts.enumerated() {
                var f = PublicFeatures(term: term)
                if (i + k) % 3 != 0 {
                    f.ownHintCount = (i * 3 + k) % 9
                    f.ownSelfPosition = (i + k) % 4
                    f.firstWordHintCount = (i + 2 * k) % 10
                    f.firstWordPosition = k % 3
                    f.prefixHintCount = (3 * i + k) % 11
                    f.prefixPosition = (i * k) % 5
                }
                if (i + k) % 2 == 0 {
                    f.resultCount = 200 - 17 * k
                    f.top10MedianRatings = 40 * (i + 1) * (k + 1)
                    f.leaderRatings = 1_000 * (i + 1) + 77 * k
                    f.titleMatchesTop10 = (i + k) % 10
                    f.distinctSellersTop10 = 10 - (i % 4)
                    f.difficulty = Double((13 * i + 7 * k) % 90)
                    f.resultRelevance = Double((i + k) % 10) / 10
                }
                var j = JevFeatures()
                j.genre = ["PRODUCTIVITY_UTILITIES", "PHOTO_VIDEO", "FINANCE", "GAMES"][(i + k) % 4]
                if (i + 2 * k) % 4 != 0 {
                    j.brand = Double((i + k) % 10) / 10
                    j.naturalQuery = 0.9 - Double(k) / 10
                    j.languageFit = 0.5 + Double(i % 5) / 10
                    j.headTerm = Double((i + k) % 5)
                    j.demand = Double((2 * i + k) % 5)
                    j.demandProbabilities = [0.1, 0.2, 0.4, 0.2, 0.1]
                    j.intentProbabilities = ["brand": 0.1, "category": 0.2, "feature": 0.4, "longtail": 0.2, "other": 0.1]
                }
                out.append((f, j, storefront))
            }
        }
        return out
    }

    static func inputs(_ sample: (features: PublicFeatures, jev: JevFeatures?, storefront: String)) -> [String: TreeModel.Value] {
        var inputs: [String: TreeModel.Value] = [:]
        let numeric = FeatureColumns.numeric(sample.features, jev: sample.jev)
        for (i, name) in FeatureColumns.numericNames.enumerated() { inputs[name] = .number(numeric[i]) }
        let categorical = FeatureColumns.categorical(sample.storefront, jev: sample.jev)
        for (i, name) in FeatureColumns.categoricalNames.enumerated() { inputs[name] = .text(categorical[i]) }
        return inputs
    }

    @Test("The bundled models read as one-hot encoders, a vectorizer and boosted trees, and predict in range")
    func bundled() throws {
        let regressor = try TreeModel(contentsOf: Self.regressorURL)
        let classifier = try TreeModel(contentsOf: Self.classifierURL)
        #expect(regressor.stages.count == 4)
        if case let .trees(_, ensemble, transform, _) = regressor.stages.last {
            #expect(ensemble.trees.count == 400)
            #expect(transform == .none)
        } else {
            Issue.record("The regressor does not end in trees")
        }
        if case let .trees(_, ensemble, transform, labels) = classifier.stages.last {
            #expect(ensemble.trees.count == 300)
            #expect(transform == .logistic)
            #expect(Set(labels) == ["yes", "no"])
        } else {
            Issue.record("The classifier does not end in trees")
        }
        for sample in Self.samples() {
            let value = try regressor.predict(Self.inputs(sample)).value
            #expect(value > -20 && value < 140)
            let probabilities = try classifier.predict(Self.inputs(sample)).probabilities
            #expect(abs((probabilities["yes"] ?? 0) + (probabilities["no"] ?? 0) - 1) < 1e-9)
        }
        var missing = Self.inputs(Self.samples()[0])
        missing["word_count"] = nil
        #expect(throws: TreeModel.ModelError.self) { try regressor.predict(missing) }
        // Storefronts and genres the models were not trained on are refused, not guessed.
        var japan = Self.inputs(Self.samples()[0])
        japan["storefront"] = .text("JP")
        #expect(throws: TreeModel.ModelError.unknownCategory(feature: "storefront", value: "JP")) { try classifier.predict(japan) }
        var noGenre = Self.inputs(Self.samples()[0])
        noGenre["jev_genre"] = .text("unknown")
        #expect(throws: TreeModel.ModelError.self) { try regressor.predict(noGenre) }
        #expect(throws: TreeModel.ModelError.self) { try TreeModel(data: Data([0xFF, 0xFF])) }
    }

    #if canImport(CoreML)
    @Test("The reader agrees with CoreML on the bundled models")
    func matchesCoreML() throws {
        let regressor = try TreeModel(contentsOf: Self.regressorURL)
        let classifier = try TreeModel(contentsOf: Self.classifierURL)
        let coreRegressor = try MLModel(contentsOf: MLModel.compileModel(at: Self.regressorURL))
        let coreClassifier = try MLModel(contentsOf: MLModel.compileModel(at: Self.classifierURL))
        for sample in Self.samples() {
            var dictionary: [String: Any] = [:]
            for (name, value) in Self.inputs(sample) {
                switch value {
                case .number(let v): dictionary[name] = v
                case .text(let s): dictionary[name] = s
                case .vector: break
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: dictionary)
            let label = try #require(try coreRegressor.prediction(from: provider).featureValue(for: "label")?.doubleValue)
            #expect(abs(try regressor.predict(Self.inputs(sample)).value - label) < 1e-3)
            let probabilities = try #require(try coreClassifier.prediction(from: provider).featureValue(for: "publishedProbability")?.dictionaryValue)
            let yes = try #require(probabilities["yes"]?.doubleValue)
            #expect(abs((try classifier.predict(Self.inputs(sample)).probabilities["yes"] ?? -1) - yes) < 1e-4)
        }
        // CoreML refuses an unknown storefront too.
        var japan: [String: Any] = [:]
        for (name, value) in Self.inputs(Self.samples()[0]) {
            if case .number(let v) = value { japan[name] = v }
            if case .text(let s) = value { japan[name] = s }
        }
        japan["storefront"] = "JP"
        #expect(throws: (any Error).self) { try coreClassifier.prediction(from: MLDictionaryFeatureProvider(dictionary: japan)) }
    }
    #endif
}
