import Foundation

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

    /// The engine's own data file. It sits next to the macOS app's store but never shares its format.
    public static func storeURL(in directory: URL) -> URL {
        directory.appendingPathComponent("engine.sqlite")
    }
}
