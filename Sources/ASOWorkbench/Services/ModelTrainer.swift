import Foundation
import Observation
import CreateML
import CoreML
import SwiftData
import ASOCore

/// Trains the popularity model in-process with CreateML and evaluates it on held-out rows.
/// Two models: a boosted-tree regressor for the value and a boosted-tree classifier for the band (gives confidence).
@Observable
final class ModelTrainer {
    struct Report: Codable, Sendable {
        var trainedAt: Date
        var rowsTrain: Int
        var rowsTest: Int
        var storefronts: [String]
        var featureGroups: [String]
        var random: EvaluationReport
        var crossStorefront: EvaluationReport?
        /// Holdout drawn only from rows that carry autocomplete features, the shape every row has at inference time.
        var inferenceLike: EvaluationReport?
        /// Train without one Apple genre's terms, test on them: how well the rule transfers to an unseen topic.
        var crossGenre: [EvaluationReport] = []
        var featureImportance: [String: Double]
        /// Stage 1 (is the term in Apple's published range, ≥35?) on the random holdout.
        var publishedAccuracy: Double = 0
        var publishedPrecision: Double = 0
        var publishedRecall: Double = 0
        /// 23 breakpoints of P(published) among holdout rows Apple leaves at the floor. A new term's probability lands in one
        /// of 24 slots → shown as 6–29: its demand rank among floor terms, never an Apple value.
        var floorQuantiles: [Double] = []
    }

    private(set) var isTraining = false
    private(set) var report: Report?
    private(set) var lastError: String?

    nonisolated static var modelDirectory: URL {
        let dir = PersistenceController.storeURL.deletingLastPathComponent().appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Labels are {5} ∪ [35, 100]: nothing in between exists in Apple's data, so the model is two-stage.
    nonisolated static let publishedThreshold = 30
    nonisolated static var regressorURL: URL { modelDirectory.appendingPathComponent("popularity-regressor.mlmodel") }
    nonisolated static var classifierURL: URL { modelDirectory.appendingPathComponent("popularity-published.mlmodel") }
    nonisolated static var reportURL: URL { modelDirectory.appendingPathComponent("report.json") }

    init() {
        if let data = try? Data(contentsOf: Self.reportURL) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            report = try? d.decode(Report.self, from: data)
        }
    }

    nonisolated struct Example: Sendable {
        let numeric: [Double]
        let categorical: [String]
        let label: Int
        let storefront: String
        /// Apple genre when the term came from a genre list; "" otherwise.
        let genre: String
        /// Autocomplete was measured for this row (inference rows always have it).
        var hasHints: Bool { numeric.count > FeatureColumns.hasHintsIndex && numeric[FeatureColumns.hasHintsIndex] > 0.5 }
    }

    /// Rows with autocomplete features are few (~7%) but match inference; repeating them lets the trees lean on those columns.
    nonisolated static let hintOversample = 3

    nonisolated static func weighted(_ examples: [Example]) -> [Example] {
        var out = examples
        out.reserveCapacity(examples.count * 2)
        for ex in examples where ex.hasHints { for _ in 1..<hintOversample { out.append(ex) } }
        return out
    }

    func train(rows: [TrainingRow]) async {
        let examples = rows.compactMap { r -> Example? in
            guard let label = r.label else { return nil }
            let genre = r.source.hasPrefix("genre_list:") ? String(r.source.dropFirst("genre_list:".count)) : ""
            return Example(numeric: FeatureColumns.numeric(r.features, jev: r.jev), categorical: FeatureColumns.categorical(r.storefront, jev: r.jev), label: label, storefront: r.storefront, genre: genre)
        }
        guard examples.count >= 60 else { lastError = "Need at least 60 labelled rows (have \(examples.count))."; return }
        isTraining = true
        lastError = nil
        let groups = ["lexical", "autocomplete"] + (rows.contains { $0.resultsCollected } ? ["search results"] : []) + (rows.contains { $0.jev?.isCollected == true } ? ["jev"] : [])
        do {
            let result = try await Task.detached(priority: .userInitiated) { try Self.trainDetached(examples, groups: groups) }.value
            report = result
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted
            try? (try e.encode(result)).write(to: Self.reportURL)
        } catch {
            lastError = error.localizedDescription
        }
        isTraining = false
    }

    enum Target { case value, published, none }

    nonisolated static func table(_ examples: [Example], target: Target) throws -> MLDataTable {
        var cols: [String: MLDataValueConvertible] = [:]
        for (i, name) in FeatureColumns.numericNames.enumerated() { cols[name] = examples.map { $0.numeric[i] } }
        for (i, name) in FeatureColumns.categoricalNames.enumerated() { cols[name] = examples.map { $0.categorical[i] } }
        switch target {
        case .value: cols["label"] = examples.map { Double($0.label) }
        case .published: cols["published"] = examples.map { $0.label >= publishedThreshold ? "yes" : "no" }
        case .none: break
        }
        return try MLDataTable(dictionary: cols)
    }

    nonisolated static func predictedValues(_ model: MLBoostedTreeRegressor, _ examples: [Example]) throws -> [Double] {
        let column = try model.predictions(from: try table(examples, target: .none))
        var out: [Double] = []
        out.reserveCapacity(examples.count)
        for i in 0..<examples.count { out.append(min(100, max(Double(publishedThreshold), column[i].doubleValue ?? 0))) }
        return out
    }

    /// Two-stage prediction: floor unless the classifier says the term is in the published range.
    nonisolated static func twoStage(classifier: MLBoostedTreeClassifier, regressor: MLBoostedTreeRegressor, _ examples: [Example]) throws -> (values: [Double], published: [Bool]) {
        guard !examples.isEmpty else { return ([], []) }
        let cls = try classifier.predictions(from: try table(examples, target: .none))
        let published = (0..<examples.count).map { cls[$0].stringValue == "yes" }
        let reg = try predictedValues(regressor, examples)
        return (zip(published, reg).map { $0 ? $1 : 5 }, published)
    }

    /// P(published) per example from a CreateML classifier (compiled through a temporary CoreML model).
    nonisolated static func publishedProbabilities(_ classifier: MLBoostedTreeClassifier, _ examples: [Example]) throws -> [Double] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aso-quantiles-\(UUID().uuidString).mlmodel")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try classifier.write(to: tmp)
        let compiled = try MLModel.compileModel(at: tmp)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let model = try MLModel(contentsOf: compiled)
        var out: [Double] = []
        out.reserveCapacity(examples.count)
        for ex in examples {
            var dict: [String: Any] = [:]
            for (i, name) in FeatureColumns.numericNames.enumerated() { dict[name] = ex.numeric[i] }
            for (i, name) in FeatureColumns.categoricalNames.enumerated() { dict[name] = ex.categorical[i] }
            let pred = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: dict))
            out.append(pred.featureValue(for: "publishedProbability")?.dictionaryValue["yes"]?.doubleValue ?? 0.5)
        }
        return out
    }

    nonisolated static func fit(_ examples: [Example]) throws -> (MLBoostedTreeClassifier, MLBoostedTreeRegressor) {
        var cparams = MLBoostedTreeClassifier.ModelParameters()
        cparams.maxIterations = 300
        cparams.maxDepth = 6
        let examples = weighted(examples)
        let classifier = try MLBoostedTreeClassifier(trainingData: try table(examples, target: .published), targetColumn: "published", parameters: cparams)
        var params = MLBoostedTreeRegressor.ModelParameters()
        params.maxIterations = 400
        params.maxDepth = 6
        let inRange = examples.filter { $0.label >= publishedThreshold }
        let regressor = try MLBoostedTreeRegressor(trainingData: try table(inRange.count >= 30 ? inRange : examples, target: .value), targetColumn: "label", parameters: params)
        return (classifier, regressor)
    }

    nonisolated static func trainDetached(_ examples: [Example], groups: [String]) throws -> Report {
        var rng = SystemRandomNumberGenerator()
        let shuffled = examples.shuffled(using: &rng)
        let cut = Int(Double(shuffled.count) * 0.8)
        let trainSet = Array(shuffled[..<cut]), testSet = Array(shuffled[cut...])

        let (classifier, regressor) = try fit(trainSet)
        let (predicted, published) = try twoStage(classifier: classifier, regressor: regressor, testSet)
        let random = EvaluationReport(name: "Random 80/20 holdout", actual: testSet.map(\.label), predicted: predicted)
        var tp = 0, fp = 0, fn = 0, correct = 0
        for (ex, p) in zip(testSet, published) {
            let a = ex.label >= publishedThreshold
            if a == p { correct += 1 }
            if p && a { tp += 1 } else if p && !a { fp += 1 } else if !p && a { fn += 1 }
        }
        // Floor-term quantiles: where holdout floor terms' probabilities fall, in 24 equal slots.
        var floorQuantiles: [Double] = []
        let floorRows = testSet.filter { $0.label < publishedThreshold }
        if floorRows.count >= 120 {
            let ps = try publishedProbabilities(classifier, floorRows).sorted()
            floorQuantiles = (1...23).map { ps[min(ps.count - 1, ps.count * $0 / 24)] }
        }
        let accuracy = Double(correct) / Double(max(1, testSet.count))
        let precision = tp + fp == 0 ? 0 : Double(tp) / Double(tp + fp)
        let recall = tp + fn == 0 ? 0 : Double(tp) / Double(tp + fn)

        // Inference-like: hold out a fifth of the rows that carry autocomplete features and train on everything else.
        var inferenceLike: EvaluationReport?
        let hinted = examples.filter(\.hasHints).shuffled(using: &rng)
        if hinted.count >= 200 {
            let heldCount = hinted.count / 5
            let held = Array(hinted[..<heldCount])
            var rest = examples.filter { !$0.hasHints }
            rest.append(contentsOf: hinted[heldCount...])
            let (c, r) = try fit(rest)
            let (pv, pp) = try twoStage(classifier: c, regressor: r, held)
            var ok = 0
            for (ex, p) in zip(held, pp) where (ex.label >= publishedThreshold) == p { ok += 1 }
            var rep = EvaluationReport(name: "Rows with autocomplete features (\(held.count) held out)", actual: held.map(\.label), predicted: pv)
            rep.name += String(format: " · stage1 acc %.2f", Double(ok) / Double(max(1, held.count)))
            inferenceLike = rep
        }

        // Cross-storefront: train on all but the smallest storefront, test on it (a market never seen).
        var cross: EvaluationReport?
        let bySF = Dictionary(grouping: examples, by: \.storefront)
        if bySF.count >= 2, let held = bySF.min(by: { $0.value.count < $1.value.count }), held.value.count >= 30 {
            let (c, r) = try fit(examples.filter { $0.storefront != held.key })
            cross = EvaluationReport(name: "Held-out storefront \(held.key)", actual: held.value.map(\.label), predicted: try twoStage(classifier: c, regressor: r, held.value).values)
        }

        // Cross-genre: hold out a whole topic, the genre's list terms plus every other term Jev assigns to that
        // genre: so the held-out set spans the full range (list terms alone are all ≥40 and would flatter nothing).
        var crossGenre: [EvaluationReport] = []
        let topicOf: (Example) -> String = { $0.genre.isEmpty ? ($0.categorical.count > 1 ? $0.categorical[1] : "") : $0.genre }
        let byTopic = Dictionary(grouping: examples.filter { !topicOf($0).isEmpty && topicOf($0) != "unknown" }, by: topicOf)
        for (genre, held) in byTopic.sorted(by: { $0.value.count > $1.value.count }).prefix(3) where held.count >= 80 {
            let (c, r) = try fit(examples.filter { topicOf($0) != genre })
            crossGenre.append(EvaluationReport(name: "Held-out topic \(genre)", actual: held.map(\.label), predicted: try twoStage(classifier: c, regressor: r, held).values))
        }

        // Final models on everything.
        let (finalClassifier, finalRegressor) = try fit(examples)
        // CreateML defaults the author to the macOS account name; shipped models must not carry it.
        let meta = MLModelMetadata(author: "ASO Workbench authors.", shortDescription: "ASO Workbench popularity estimator (see docs/POPULARITY.md)", license: "AGPL-3.0", version: "1")
        try finalRegressor.write(to: regressorURL, metadata: meta)
        try finalClassifier.write(to: classifierURL, metadata: meta)

        // Permutation importance on the holdout (MAE increase when a column is shuffled).
        var importance: [String: Double] = [:]
        if !testSet.isEmpty {
            let actual = testSet.map { Double($0.label) }
            for (i, name) in FeatureColumns.numericNames.enumerated() {
                let values = testSet.map { $0.numeric[i] }.shuffled(using: &rng)
                var permuted: [Example] = []
                permuted.reserveCapacity(testSet.count)
                for (k, ex) in testSet.enumerated() {
                    var n = ex.numeric
                    n[i] = values[k]
                    permuted.append(Example(numeric: n, categorical: ex.categorical, label: ex.label, storefront: ex.storefront, genre: ex.genre))
                }
                let pp = try twoStage(classifier: classifier, regressor: regressor, permuted).values
                var errSum = 0.0
                for k in 0..<pp.count { errSum += abs(actual[k] - pp[k]) }
                importance[name] = max(0, errSum / Double(testSet.count) - random.mae)
            }
        }
        return Report(trainedAt: .now, rowsTrain: trainSet.count, rowsTest: testSet.count, storefronts: Array(bySF.keys).sorted(), featureGroups: groups,
                      random: random, crossStorefront: cross, inferenceLike: inferenceLike, crossGenre: crossGenre, featureImportance: importance,
                      publishedAccuracy: accuracy, publishedPrecision: precision, publishedRecall: recall, floorQuantiles: floorQuantiles)
    }
}

/// Shared handle so services see the estimator reloaded after training.
@Observable
final class EstimatorHolder {
    var estimator: PopularityEstimator?
    init() { estimator = PopularityEstimator() }
    func reload() { estimator = PopularityEstimator() }
}

/// Runs the trained models for one keyword. Nil when no model has been trained yet.
final class PopularityEstimator {
    private let regressor: MLModel
    private let classifier: MLModel
    /// Where the models came from: "trained" (Application Support, from the Lab) or "bundled" (shipped inside the app).
    let origin: String
    /// Breakpoints from the training report (see `ModelTrainer.Report.floorQuantiles`); empty when the report lacks them.
    let floorQuantiles: [Double]

    static func loadQuantiles(trained: Bool) -> [Double] {
        let url = trained ? ModelTrainer.reportURL : Bundle.main.url(forResource: "popularity-report", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode(ModelTrainer.Report.self, from: data))?.floorQuantiles ?? []
    }

    /// 6–29 for a term Apple leaves at the floor: which of 24 probability slots it falls in among floor terms.
    /// An ordering aid, not a popularity value, nil when the report carries no quantiles.
    func subFloorEstimate(publishedProbability p: Double) -> Int? {
        PopularityEstimate.subFloor(publishedProbability: p, quantiles: floorQuantiles)
    }

    static func publishedProbability(of e: Estimate) -> Double { e.publishedProbability }

    init?() {
        if FileManager.default.fileExists(atPath: ModelTrainer.regressorURL.path), FileManager.default.fileExists(atPath: ModelTrainer.classifierURL.path),
           let r = try? MLModel.compileModel(at: ModelTrainer.regressorURL), let c = try? MLModel.compileModel(at: ModelTrainer.classifierURL),
           let rm = try? MLModel(contentsOf: r), let cm = try? MLModel(contentsOf: c) {
            regressor = rm
            classifier = cm
            origin = "trained"
            floorQuantiles = Self.loadQuantiles(trained: true)
            return
        }
        if let r = Bundle.main.url(forResource: "popularity-regressor", withExtension: "mlmodelc"),
           let c = Bundle.main.url(forResource: "popularity-published", withExtension: "mlmodelc"),
           let rm = try? MLModel(contentsOf: r), let cm = try? MLModel(contentsOf: c) {
            regressor = rm
            classifier = cm
            origin = "bundled"
            floorQuantiles = Self.loadQuantiles(trained: false)
            return
        }
        return nil
    }

    /// Either a value in Apple's published range or "below it", each with the classifier's probability.
    typealias Estimate = PopularityEstimate

    func estimate(features: PublicFeatures, jev: JevFeatures?, storefront: String) -> Estimate? {
        if PopularityEstimate.hasNoHints(features) { return .below(probability: 0.95) }
        var dict: [String: Any] = [:]
        let numeric = FeatureColumns.numeric(features, jev: jev)
        for (i, name) in FeatureColumns.numericNames.enumerated() { dict[name] = numeric[i] }
        let categorical = FeatureColumns.categorical(storefront, jev: jev)
        for (i, name) in FeatureColumns.categoricalNames.enumerated() { dict[name] = categorical[i] }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: dict),
              let c = try? classifier.prediction(from: provider) else { return nil }
        var pYes = 0.5
        if let probs = c.featureValue(for: "publishedProbability")?.dictionaryValue, let v = probs["yes"]?.doubleValue { pYes = v }
        return PopularityEstimate.decide(publishedProbability: pYes) {
            (try? regressor.prediction(from: provider))?.featureValue(for: "label")?.doubleValue
        }
    }
}
