import Foundation
import ASOCore

/// Preferences the engine applies, with the macOS app's defaults. Stored as `settings.json` in the data folder;
/// nothing secret lives here (keys are in `credentials.json`, see `CredentialStore`).
public struct EngineSettings: Sendable, Equatable, Codable {
    /// Public search results inspected per keyword (Apple returns at most 200).
    public var resultDepth = 200
    /// Minimum seconds between public search requests.
    public var pacingSeconds = 3.1
    /// A golden keyword has popularity at least this and difficulty at most `goldenMaxDifficulty`.
    public var goldenMinPopularity = 30
    public var goldenMaxDifficulty = 45
    /// Writer tiers: difficulty up to `writerEasyDifficulty` is winnable now (A), up to `writerMaxDifficulty` reachable (B).
    public var writerEasyDifficulty = 35
    public var writerMaxDifficulty = 55
    /// What Δ compares the latest rank against when a command does not say.
    public var deltaReference = DeltaReference.lastMarker
    /// Measure markets whose newest measurement is older than `staleHours` when a front end starts.
    public var autoMeasureOnLaunch = false
    public var staleHours = 20
    /// OpenRouter model for the writer.
    public var writerModel = "deepseek/deepseek-v4-pro"
    /// App ID of any app in the user's Apple Ads account, used by the website session.
    public var adsReferenceAppID = ""

    public init() {}

    public var golden: GoldenThresholds { GoldenThresholds(minPopularity: goldenMinPopularity, maxDifficulty: goldenMaxDifficulty) }

    /// One setting as `settings set` takes it: its name, the values it accepts and how to apply text to it.
    public struct Field: Sendable {
        public let name: String
        public let accepted: String
        let apply: @Sendable (inout EngineSettings, String) -> Bool
    }

    /// Every setting that can be changed, with the macOS app's ranges.
    public static let fields: [Field] = [
        .init(name: "resultDepth", accepted: "50, 100 or 200") { s, v in assign(&s.resultDepth, Int(v), where: { [50, 100, 200].contains($0) }) },
        .init(name: "pacingSeconds", accepted: "1 to 6") { s, v in assign(&s.pacingSeconds, Double(v), where: { (1...6).contains($0) }) },
        .init(name: "goldenMinPopularity", accepted: "5 to 100") { s, v in assign(&s.goldenMinPopularity, Int(v), where: { (5...100).contains($0) }) },
        .init(name: "goldenMaxDifficulty", accepted: "5 to 100") { s, v in assign(&s.goldenMaxDifficulty, Int(v), where: { (5...100).contains($0) }) },
        .init(name: "writerEasyDifficulty", accepted: "5 to 100") { s, v in assign(&s.writerEasyDifficulty, Int(v), where: { (5...100).contains($0) }) },
        .init(name: "writerMaxDifficulty", accepted: "5 to 100") { s, v in assign(&s.writerMaxDifficulty, Int(v), where: { (5...100).contains($0) }) },
        .init(name: "deltaReference", accepted: DeltaReference.allCases.map(\.rawValue).joined(separator: ", ")) { s, v in
            assign(&s.deltaReference, DeltaReference(rawValue: v), where: { _ in true })
        },
        .init(name: "autoMeasureOnLaunch", accepted: "true or false") { s, v in assign(&s.autoMeasureOnLaunch, Bool(v.lowercased()), where: { _ in true }) },
        .init(name: "staleHours", accepted: "6 to 72") { s, v in assign(&s.staleHours, Int(v), where: { (6...72).contains($0) }) },
        .init(name: "writerModel", accepted: "an OpenRouter model ID") { s, v in
            let id = v.trimmingCharacters(in: .whitespaces)
            return assign(&s.writerModel, id.isEmpty ? nil : id, where: { !$0.contains(" ") })
        },
        .init(name: "adsReferenceAppID", accepted: "a numeric App ID, or empty") { s, v in
            let id = v.trimmingCharacters(in: .whitespaces)
            return assign(&s.adsReferenceAppID, id, where: { $0.isEmpty || Int($0) != nil })
        },
    ]

    /// Applies text to the named setting. Throws when the name is unknown or the value is outside its range.
    public mutating func set(_ name: String, to value: String) throws {
        guard let field = Self.fields.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw EngineError.invalidArgument("Unknown setting \"\(name)\". Settings: \(Self.fields.map(\.name).joined(separator: ", ")).")
        }
        guard field.apply(&self, value) else {
            throw EngineError.invalidArgument("\(field.name) must be \(field.accepted); got \"\(value)\".")
        }
    }

    private static func assign<T>(_ target: inout T, _ value: T?, where valid: (T) -> Bool) -> Bool {
        guard let value, valid(value) else { return false }
        target = value
        return true
    }

    // Tolerant decoding: a missing or unreadable value keeps its default, so older and newer files both load.
    private enum CodingKeys: String, CodingKey {
        case resultDepth, pacingSeconds, goldenMinPopularity, goldenMaxDifficulty, writerEasyDifficulty, writerMaxDifficulty,
             deltaReference, autoMeasureOnLaunch, staleHours, writerModel, adsReferenceAppID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        let d = EngineSettings()
        resultDepth = value(.resultDepth, d.resultDepth)
        pacingSeconds = value(.pacingSeconds, d.pacingSeconds)
        goldenMinPopularity = value(.goldenMinPopularity, d.goldenMinPopularity)
        goldenMaxDifficulty = value(.goldenMaxDifficulty, d.goldenMaxDifficulty)
        writerEasyDifficulty = value(.writerEasyDifficulty, d.writerEasyDifficulty)
        writerMaxDifficulty = value(.writerMaxDifficulty, d.writerMaxDifficulty)
        deltaReference = DeltaReference(rawValue: value(.deltaReference, d.deltaReference.rawValue)) ?? d.deltaReference
        autoMeasureOnLaunch = value(.autoMeasureOnLaunch, d.autoMeasureOnLaunch)
        staleHours = value(.staleHours, d.staleHours)
        writerModel = value(.writerModel, d.writerModel)
        adsReferenceAppID = value(.adsReferenceAppID, d.adsReferenceAppID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resultDepth, forKey: .resultDepth)
        try c.encode(pacingSeconds, forKey: .pacingSeconds)
        try c.encode(goldenMinPopularity, forKey: .goldenMinPopularity)
        try c.encode(goldenMaxDifficulty, forKey: .goldenMaxDifficulty)
        try c.encode(writerEasyDifficulty, forKey: .writerEasyDifficulty)
        try c.encode(writerMaxDifficulty, forKey: .writerMaxDifficulty)
        try c.encode(deltaReference.rawValue, forKey: .deltaReference)
        try c.encode(autoMeasureOnLaunch, forKey: .autoMeasureOnLaunch)
        try c.encode(staleHours, forKey: .staleHours)
        try c.encode(writerModel, forKey: .writerModel)
        try c.encode(adsReferenceAppID, forKey: .adsReferenceAppID)
    }

    // MARK: File

    public static func url(in directory: URL) -> URL { directory.appendingPathComponent("settings.json") }

    /// The stored settings, or the defaults when there is no file yet. An unreadable file is an error, not a silent reset.
    public static func load(from directory: URL) throws -> EngineSettings {
        let url = url(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return EngineSettings() }
        do {
            return try JSONDecoder().decode(EngineSettings.self, from: Data(contentsOf: url))
        } catch {
            throw EngineError.database("The settings file \(url.lastPathComponent) cannot be read: \(error.localizedDescription)")
        }
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }
}
