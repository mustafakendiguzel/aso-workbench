import Foundation
import Observation

/// Small, UserDefaults-backed preferences. Nothing secret lives here.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    /// How many public search results to inspect per keyword (Apple caps at 200).
    var resultDepth: Int {
        didSet { defaults.set(resultDepth, forKey: "resultDepth") }
    }
    /// Minimum seconds between public search requests.
    var pacingSeconds: Double {
        didSet { defaults.set(pacingSeconds, forKey: "pacingSeconds") }
    }
    /// Measure every market on launch when the last measurement is older than `staleHours`.
    var autoMeasureOnLaunch: Bool {
        didSet { defaults.set(autoMeasureOnLaunch, forKey: "autoMeasureOnLaunch") }
    }
    var staleHours: Int {
        didSet { defaults.set(staleHours, forKey: "staleHours") }
    }
    /// Developer-only Lab section (model training). Off for normal users.
    /// Developer-only Lab (model training, `asoworkbench://lab/…` URL commands). Never a user setting: enabled only when
    /// the app is launched with `ASO_LAB=1` in the environment or the `--lab` argument (see docs/POPULARITY.md).
    var showLab: Bool { LabMode.isEnabled }
    /// A "golden" keyword: Apple popularity at least this…
    var goldenMinPopularity: Int {
        didSet { defaults.set(goldenMinPopularity, forKey: "goldenMinPopularity") }
    }
    /// …and difficulty at most this.
    var goldenMaxDifficulty: Int {
        didSet { defaults.set(goldenMaxDifficulty, forKey: "goldenMaxDifficulty") }
    }

    /// Writer tiers: difficulty up to `writerEasyDifficulty` is "winnable now" (tier A), up to `writerMaxDifficulty` is "reachable" (tier B).
    var writerEasyDifficulty: Int {
        didSet { defaults.set(writerEasyDifficulty, forKey: "writerEasyDifficulty") }
    }
    var writerMaxDifficulty: Int {
        didSet { defaults.set(writerMaxDifficulty, forKey: "writerMaxDifficulty") }
    }

    /// What the Keywords Δ column compares against.
    var deltaReference: DeltaReference {
        didSet { defaults.set(deltaReference.rawValue, forKey: "deltaReference") }
    }

    init() {
        let d = UserDefaults.standard
        deltaReference = DeltaReference(rawValue: d.string(forKey: "deltaReference") ?? "") ?? .lastMarker
        writerEasyDifficulty = d.object(forKey: "writerEasyDifficulty") as? Int ?? 35
        writerMaxDifficulty = d.object(forKey: "writerMaxDifficulty") as? Int ?? 55
        resultDepth = d.object(forKey: "resultDepth") as? Int ?? 200
        pacingSeconds = d.object(forKey: "pacingSeconds") as? Double ?? 3.1
        autoMeasureOnLaunch = d.object(forKey: "autoMeasureOnLaunch") as? Bool ?? false
        staleHours = d.object(forKey: "staleHours") as? Int ?? 20
        goldenMinPopularity = d.object(forKey: "goldenMinPopularity") as? Int ?? 30
        goldenMaxDifficulty = d.object(forKey: "goldenMaxDifficulty") as? Int ?? 45
    }
}

enum LabMode {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["ASO_LAB"] == "1" || CommandLine.arguments.contains("--lab")
}

/// Features that ship in the code but are not part of this release. They appear only in a Lab session.
enum Feature {
    /// Market-wide gap scan ("App ideas"): hidden in 1.0 while it matures.
    static var appIdeas: Bool { LabMode.isEnabled }
}
