import Foundation
import ASOCore

/// Where the engine keeps its data and which version it is.
public enum EngineEnvironment {
    /// Matches the repository's VERSION file (a test keeps the two in step).
    public static let version = "1.0.0"

    /// `ASO_DATA_DIR` when set, else the platform's application-support folder: `~/Library/Application Support` on macOS,
    /// `$XDG_DATA_HOME` or `~/.local/share` on Linux, the user's AppData folder on Windows.
    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["ASO_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ASO Workbench", isDirectory: true)
    }

    /// Where the popularity models are: `ASO_MODELS_DIR`; else the data folder's `models/` (where the macOS app keeps models
    /// trained in its Lab); else `models/` next to the executable, or `share/aso-workbench/models` beside its folder (how
    /// packages ship them); else `Resources/models` under the current folder (a checkout). Nil when none has both files.
    public static func modelDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, dataDirectory: URL,
                                      executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")) -> URL? {
        let folder = executable.deletingLastPathComponent()
        var candidates: [URL] = []
        if let custom = environment["ASO_MODELS_DIR"], !custom.isEmpty { candidates.append(URL(fileURLWithPath: custom, isDirectory: true)) }
        candidates += [
            dataDirectory.appendingPathComponent("models", isDirectory: true),
            folder.appendingPathComponent("models", isDirectory: true),
            folder.deletingLastPathComponent().appendingPathComponent("share/aso-workbench/models", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/models", isDirectory: true),
        ]
        return candidates.first { url in
            [PopularityModel.regressorFile, PopularityModel.classifierFile].allSatisfy {
                FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
            }
        }
    }

    /// The engine's own data file. It sits next to the macOS app's store but never shares its format.
    public static func storeURL(in directory: URL) -> URL {
        directory.appendingPathComponent("engine.sqlite")
    }
}
