import Foundation

/// What the popularity model says about a term Apple publishes nothing for: a value in Apple's published range, or below
/// it, each with the classifier's probability. The rules are the macOS app's; any model that gives the two numbers fits.
public enum PopularityEstimate: Sendable, Equatable {
    case published(value: Int, probability: Double)
    /// `probability` that the term is below the published range.
    case below(probability: Double)

    /// A value is shown only when the classifier is fairly sure; floor terms were the main false positives in evaluation.
    public static let publishedGate = 0.65

    /// Apple publishes 5 or 30 and up; the regressor is trained on the published values only.
    public static let publishedFloor = KeywordPlan.publishedFloor

    /// Autocomplete answered (not failed) with nothing for the term, its first word and its prefix: Apple surfaces
    /// suggestions for any word people actually type, so this is below the published range without a model.
    public static func hasNoHints(_ f: PublicFeatures) -> Bool {
        f.ownHintCount == 0 && f.firstWordHintCount == 0 && f.prefixHintCount == 0
    }

    /// The estimate from the classifier's probability that the term is published and, only when that passes the gate,
    /// the regressor's value (clamped to 30–100).
    public static func decide(publishedProbability p: Double, value: () throws -> Double?) rethrows -> PopularityEstimate? {
        if p < publishedGate { return .below(probability: 1 - p) }
        guard let v = try value() else { return nil }
        return .published(value: Int(min(100, max(Double(publishedFloor), v)).rounded()), probability: p)
    }

    public var publishedProbability: Double {
        switch self {
        case .published(_, let p): p
        case .below(let p): 1 - p
        }
    }

    /// 6–29 for a term Apple leaves at the floor: which of 24 probability slots it falls in among floor terms. An ordering
    /// aid, not a popularity value; nil without the report's 23 breakpoints.
    public static func subFloor(publishedProbability p: Double, quantiles: [Double]) -> Int? {
        guard quantiles.count == 23 else { return nil }
        return 6 + quantiles.filter { $0 < p }.count
    }

    /// A term off Apple's list this month sits below the list's lowest score, even when the model says higher.
    public static func capped(_ value: Int, belowListFloor floor: Int?) -> Int {
        max(publishedFloor, floor.map { min($0 - 1, value) } ?? value)
    }
}

/// The popularity models (classifier and regressor) and their training report, evaluated without CoreML.
public struct PopularityModel: Sendable {
    public static let regressorFile = "popularity-regressor.mlmodel"
    public static let classifierFile = "popularity-published.mlmodel"
    public static let reportFiles = ["popularity-report.json", "report.json"]

    let regressor: TreeModel
    let classifier: TreeModel
    /// Breakpoints of P(published) among floor terms in the holdout, for the sub-floor rank.
    public let floorQuantiles: [Double]

    public init(regressor: TreeModel, classifier: TreeModel, floorQuantiles: [Double]) {
        self.regressor = regressor
        self.classifier = classifier
        self.floorQuantiles = floorQuantiles
    }

    /// The models in a folder (`models/` as the macOS app trains them, or the bundled ones), with the report beside them.
    public init(directory: URL) throws {
        let report = Self.reportFiles.lazy.map { directory.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        struct Report: Decodable { let floorQuantiles: [Double]? }
        let quantiles = report.flatMap { try? JSONDecoder().decode(Report.self, from: Data(contentsOf: $0)) }?.floorQuantiles ?? []
        self.init(regressor: try TreeModel(contentsOf: directory.appendingPathComponent(Self.regressorFile)),
                  classifier: try TreeModel(contentsOf: directory.appendingPathComponent(Self.classifierFile)), floorQuantiles: quantiles)
    }

    /// The estimate for one term. Nil when the models cannot take the input (a storefront or Jev genre they were not
    /// trained on), as CoreML refuses it.
    public func estimate(features: PublicFeatures, jev: JevFeatures?, storefront: String) -> PopularityEstimate? {
        if PopularityEstimate.hasNoHints(features) { return .below(probability: 0.95) }
        var inputs: [String: TreeModel.Value] = [:]
        let numeric = FeatureColumns.numeric(features, jev: jev)
        for (i, name) in FeatureColumns.numericNames.enumerated() { inputs[name] = .number(numeric[i]) }
        let categorical = FeatureColumns.categorical(storefront, jev: jev)
        for (i, name) in FeatureColumns.categoricalNames.enumerated() { inputs[name] = .text(categorical[i]) }
        guard let p = try? classifier.predict(inputs).probabilities["yes"] else { return nil }
        return PopularityEstimate.decide(publishedProbability: p) { try? regressor.predict(inputs).value }
    }

    public func subFloor(_ estimate: PopularityEstimate) -> Int? {
        PopularityEstimate.subFloor(publishedProbability: estimate.publishedProbability, quantiles: floorQuantiles)
    }
}
