import Foundation

/// A CoreML tree-ensemble pipeline (the popularity models CreateML trains: one-hot encoders and a feature vectorizer in
/// front of boosted trees), read straight from the `.mlmodel` file and evaluated without CoreML, so the same model files
/// serve every platform. Only the parts of the CoreML specification those pipelines use are read; anything else is an
/// error rather than a silent wrong answer.
public struct TreeModel: Sendable {
    public enum ModelError: Error, LocalizedError, Equatable {
        case malformed(String)
        case unsupported(String)
        case unknownCategory(feature: String, value: String)
        case missingFeature(String)

        public var errorDescription: String? {
            switch self {
            case .malformed(let detail): "The model file cannot be read: \(detail)."
            case .unsupported(let detail): "The model uses something this reader does not support: \(detail)."
            case .unknownCategory(let feature, let value): "The model has no category \"\(value)\" for \(feature)."
            case .missingFeature(let name): "The model needs the input \(name)."
            }
        }
    }

    /// A value for one input or intermediate feature.
    public enum Value: Sendable {
        case number(Double)
        case text(String)
        case vector([Double])
    }

    enum Stage: Sendable {
        /// One input category to a vector with a 1 at its position; unknown categories give zeros or an error.
        case oneHot(input: String, output: String, categories: [String], ignoreUnknown: Bool)
        /// Scalars and vectors concatenated in order.
        case vectorize(inputs: [(name: String, dimensions: Int)], output: String)
        case trees(input: String, ensemble: TreeEnsemble, transform: Transform, labels: [String])
    }

    enum Transform: Int, Sendable {
        case none = 0, softMax = 1, logistic = 2, softMaxWithZeroClassReference = 3
    }

    let stages: [Stage]

    /// Reads a `.mlmodel` file.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        var stages: [Stage] = []
        try Self.collect(model: ProtoMessage(data), into: &stages)
        guard case .trees = stages.last else { throw ModelError.unsupported("a pipeline that does not end in a tree ensemble") }
        self.stages = stages
    }

    /// The model's prediction for the inputs: the regressor's value, or the classifier's probability per class label.
    public func predict(_ inputs: [String: Value]) throws -> (value: Double, probabilities: [String: Double]) {
        var features = inputs
        for stage in stages {
            switch stage {
            case let .oneHot(input, output, categories, ignoreUnknown):
                guard case .text(let category)? = features[input] else { throw ModelError.missingFeature(input) }
                var vector = [Double](repeating: 0, count: categories.count)
                if let index = categories.firstIndex(of: category) {
                    vector[index] = 1
                } else if !ignoreUnknown {
                    throw ModelError.unknownCategory(feature: input, value: category)
                }
                features[output] = .vector(vector)
            case let .vectorize(columns, output):
                var vector: [Double] = []
                for column in columns {
                    switch features[column.name] {
                    case .number(let v)?: vector.append(v)
                    case .vector(let v)?: vector += v
                    default: throw ModelError.missingFeature(column.name)
                    }
                }
                features[output] = .vector(vector)
            case let .trees(input, ensemble, transform, labels):
                guard case .vector(let vector)? = features[input] else { throw ModelError.missingFeature(input) }
                let raw = ensemble.evaluate(vector)
                switch transform {
                case .none:
                    return (raw.first ?? 0, [:])
                case .logistic:
                    let p = 1 / (1 + exp(-(raw.first ?? 0)))
                    // A binary classifier keeps one score: the probability of the second label.
                    guard labels.count == 2 else { return (p, [:]) }
                    return (p, [labels[0]: 1 - p, labels[1]: p])
                case .softMax, .softMaxWithZeroClassReference:
                    let scores = transform == .softMax ? raw : [0] + raw
                    let peak = scores.max() ?? 0
                    let exps = scores.map { exp($0 - peak) }
                    let sum = exps.reduce(0, +)
                    let probabilities = Dictionary(zip(labels, exps.map { $0 / sum }), uniquingKeysWith: { a, _ in a })
                    return (probabilities.values.max() ?? 0, probabilities)
                }
            }
        }
        throw ModelError.unsupported("a pipeline without a tree ensemble")
    }

    // MARK: Reading the specification

    /// Model fields (CoreML Model.proto): description 2; pipelineClassifier 200, pipelineRegressor 201, pipeline 202;
    /// treeEnsembleRegressor 302, treeEnsembleClassifier 402; oneHotEncoder 600, featureVectorizer 602.
    private static func collect(model: ProtoMessage, into stages: inout [Stage]) throws {
        let description = try model.message(2).map(Description.init) ?? Description()
        if let pipeline = try model.message(200) ?? model.message(201) {
            guard let inner = try pipeline.message(1) else { throw ModelError.malformed("an empty pipeline") }
            for stage in try inner.messages(1) { try collect(model: stage, into: &stages) }
        } else if let pipeline = try model.message(202) {
            for stage in try pipeline.messages(1) { try collect(model: stage, into: &stages) }
        } else if let encoder = try model.message(600) {
            guard let input = description.inputs.first, let output = description.outputs.first else { throw ModelError.malformed("a one-hot encoder without features") }
            guard let categories = try encoder.message(1) else { throw ModelError.unsupported("a one-hot encoder over numbers") }
            stages.append(.oneHot(input: input, output: output, categories: try categories.strings(1),
                                  ignoreUnknown: try encoder.varint(11) == 1))
        } else if let vectorizer = try model.message(602) {
            guard let output = description.outputs.first else { throw ModelError.malformed("a feature vectorizer without output") }
            let columns = try vectorizer.messages(1).map { column in
                (name: try column.string(1) ?? "", dimensions: Int(try column.varint(2) ?? 1))
            }
            stages.append(.vectorize(inputs: columns, output: output))
        } else if let regressor = try model.message(302) {
            guard let input = description.inputs.first else { throw ModelError.malformed("a tree ensemble without input") }
            stages.append(.trees(input: input, ensemble: try TreeEnsemble(try regressor.message(1) ?? ProtoMessage(Data())),
                                 transform: try transform(regressor), labels: []))
        } else if let classifier = try model.message(402) {
            guard let input = description.inputs.first else { throw ModelError.malformed("a tree ensemble without input") }
            guard let labels = try classifier.message(100) else { throw ModelError.unsupported("a tree classifier with numeric labels") }
            stages.append(.trees(input: input, ensemble: try TreeEnsemble(try classifier.message(1) ?? ProtoMessage(Data())),
                                 transform: try transform(classifier), labels: try labels.strings(1)))
        } else {
            throw ModelError.unsupported("a model stage other than one-hot encoding, vectorizing or trees")
        }
    }

    private static func transform(_ message: ProtoMessage) throws -> Transform {
        let raw = Int(try message.varint(2) ?? 0)
        guard let transform = Transform(rawValue: raw) else { throw ModelError.unsupported("post-evaluation transform \(raw)") }
        return transform
    }

    /// ModelDescription: input 1 and output 10, each a FeatureDescription whose name is field 1.
    struct Description {
        var inputs: [String] = []
        var outputs: [String] = []

        init() {}

        init(_ message: ProtoMessage) throws {
            inputs = try message.messages(1).compactMap { try $0.string(1) }
            outputs = try message.messages(10).compactMap { try $0.string(1) }
        }
    }
}

/// The trees of an ensemble, each a flat array of nodes reached by id.
struct TreeEnsemble: Sendable {
    struct Node: Sendable {
        /// 0 ≤, 1 <, 2 ≥, 3 >, 4 ==, 5 ≠, 6 leaf.
        let behavior: Int
        let feature: Int
        let threshold: Double
        let trueChild: Int
        let falseChild: Int
        let missingGoesTrue: Bool
        let values: [(index: Int, value: Double)]
    }

    /// Per tree: its nodes by node id, and the root's id.
    let trees: [(nodes: [Int: Node], root: Int)]
    let dimensions: Int
    let base: [Double]

    /// TreeEnsembleParameters: nodes 1, numPredictionDimensions 2, basePredictionValue 3 (packed or not).
    /// TreeNode: treeId 1, nodeId 2, nodeBehavior 3, branchFeatureIndex 10, branchFeatureValue 11, trueChildNodeId 12,
    /// falseChildNodeId 13, missingValueTracksTrueChild 14, evaluationInfo 20 (evaluationIndex 1, evaluationValue 2).
    init(_ message: ProtoMessage) throws {
        var byTree: [Int: [Int: Node]] = [:]
        var children: [Int: Set<Int>] = [:]
        for raw in try message.messages(1) {
            let tree = Int(try raw.varint(1) ?? 0)
            let id = Int(try raw.varint(2) ?? 0)
            let node = Node(behavior: Int(try raw.varint(3) ?? 0), feature: Int(try raw.varint(10) ?? 0), threshold: try raw.double(11) ?? 0,
                            trueChild: Int(try raw.varint(12) ?? 0), falseChild: Int(try raw.varint(13) ?? 0),
                            missingGoesTrue: try raw.varint(14) == 1,
                            values: try raw.messages(20).map { (Int(try $0.varint(1) ?? 0), try $0.double(2) ?? 0) })
            byTree[tree, default: [:]][id] = node
            if node.behavior != 6 { children[tree, default: []].formUnion([node.trueChild, node.falseChild]) }
        }
        trees = try byTree.keys.sorted().map { tree in
            let nodes = byTree[tree] ?? [:]
            guard let root = nodes.keys.filter({ !(children[tree]?.contains($0) ?? false) }).min() else {
                throw TreeModel.ModelError.malformed("tree \(tree) has no root")
            }
            return (nodes, root)
        }
        dimensions = max(1, Int(try message.varint(2) ?? 1))
        base = try message.doubles(3)
    }

    func evaluate(_ x: [Double]) -> [Double] {
        var out = base.count == dimensions ? base : [Double](repeating: base.first ?? 0, count: dimensions)
        for tree in trees {
            var id = tree.root
            while let node = tree.nodes[id] {
                if node.behavior == 6 {
                    for (index, value) in node.values where index < out.count { out[index] += value }
                    break
                }
                let v = node.feature < x.count ? x[node.feature] : .nan
                let goesTrue: Bool
                if v.isNaN {
                    goesTrue = node.missingGoesTrue
                } else {
                    switch node.behavior {
                    case 0: goesTrue = v <= node.threshold
                    case 1: goesTrue = v < node.threshold
                    case 2: goesTrue = v >= node.threshold
                    case 3: goesTrue = v > node.threshold
                    case 4: goesTrue = v == node.threshold
                    default: goesTrue = v != node.threshold
                    }
                }
                id = goesTrue ? node.trueChild : node.falseChild
            }
        }
        return out
    }
}

/// The fields of one protobuf message, read lazily from its bytes (wire types: 0 varint, 1 64-bit, 2 length-delimited, 5 32-bit).
struct ProtoMessage: Sendable {
    private let fields: [(number: Int, wire: Int, varint: UInt64, bytes: Data)]

    init(_ data: Data) throws {
        var fields: [(Int, Int, UInt64, Data)] = []
        let bytes = [UInt8](data)
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < bytes.count, shift < 64 else { throw TreeModel.ModelError.malformed("a varint runs past the end") }
                let b = bytes[i]
                i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }
        while i < bytes.count {
            let key = try varint()
            let number = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                fields.append((number, wire, try varint(), Data()))
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                guard i + size <= bytes.count else { throw TreeModel.ModelError.malformed("a fixed field runs past the end") }
                fields.append((number, wire, 0, Data(bytes[i..<i + size])))
                i += size
            case 2:
                let length = Int(try varint())
                guard length >= 0, i + length <= bytes.count else { throw TreeModel.ModelError.malformed("a field runs past the end") }
                fields.append((number, wire, 0, Data(bytes[i..<i + length])))
                i += length
            default:
                throw TreeModel.ModelError.malformed("wire type \(wire)")
            }
        }
        self.fields = fields
    }

    func messages(_ number: Int) throws -> [ProtoMessage] {
        try fields.filter { $0.number == number && $0.wire == 2 }.map { try ProtoMessage($0.bytes) }
    }

    func message(_ number: Int) throws -> ProtoMessage? { try messages(number).last }

    func varint(_ number: Int) throws -> UInt64? { fields.last { $0.number == number && $0.wire == 0 }?.varint }

    func string(_ number: Int) throws -> String? {
        fields.last { $0.number == number && $0.wire == 2 }.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    func strings(_ number: Int) throws -> [String] {
        fields.filter { $0.number == number && $0.wire == 2 }.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    func double(_ number: Int) throws -> Double? {
        fields.last { $0.number == number && $0.wire == 1 }.map { Self.double($0.bytes) }
    }

    /// A repeated double, packed (one length-delimited field) or not.
    func doubles(_ number: Int) throws -> [Double] {
        var out: [Double] = []
        for field in fields where field.number == number {
            if field.wire == 1 {
                out.append(Self.double(field.bytes))
            } else if field.wire == 2 {
                var offset = 0
                while offset + 8 <= field.bytes.count {
                    out.append(Self.double(field.bytes.subdata(in: field.bytes.startIndex + offset..<field.bytes.startIndex + offset + 8)))
                    offset += 8
                }
            }
        }
        return out
    }

    private static func double(_ bytes: Data) -> Double {
        var bits: UInt64 = 0
        for (shift, byte) in bytes.prefix(8).enumerated() { bits |= UInt64(byte) << (8 * UInt64(shift)) }
        return Double(bitPattern: bits)
    }
}
