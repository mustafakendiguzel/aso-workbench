import Foundation

/// Which RevenueCat project holds a tracked app: the one listing its bundle ID, else one whose project or app names
/// contain the app's name before any colon ("Acme Notes: Journal" → "acmenotes"), compared without case or spaces.
public enum RevenueMatch {
    public enum Kind: String, Sendable, Codable { case bundleID, name }

    public static func byBundleID(_ bundleID: String?, projectBundleIDs: [String]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return projectBundleIDs.contains(bundleID)
    }

    public static func byName(_ appName: String, projectName: String, appNames: [String]) -> Bool {
        let key = squashed(appName.split(separator: ":").first.map(String.init) ?? "")
        guard !key.isEmpty else { return false }
        return squashed(projectName).contains(key) || appNames.contains { squashed($0).contains(key) }
    }

    /// The bundle-ID matches when there are any, else the name matches; with how they matched.
    public static func select<T>(_ projects: [T], bundleID: String?, appName: String, bundleIDs: (T) -> [String], projectName: (T) -> String,
                                 appNames: (T) -> [String]) -> (matches: [T], kind: Kind?) {
        let byBundle = projects.filter { byBundleID(bundleID, projectBundleIDs: bundleIDs($0)) }
        if !byBundle.isEmpty { return (byBundle, .bundleID) }
        let byName = projects.filter { byName(appName, projectName: projectName($0), appNames: appNames($0)) }
        return (byName, byName.isEmpty ? nil : .name)
    }

    private static func squashed(_ text: String) -> String { text.lowercased().replacingOccurrences(of: " ", with: "") }
}
