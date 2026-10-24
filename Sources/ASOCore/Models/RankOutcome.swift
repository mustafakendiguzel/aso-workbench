import Foundation

/// The result of one rank check. Absence from the observed range is *not* rank 201.
public enum RankOutcome: Sendable, Hashable, Codable {
    /// The app appeared at `position` (1-based) among `observedCount` results.
    case found(position: Int, observedCount: Int)
    /// The provider returned `observedCount` results and the app was not among them.
    case outsideObservedRange(observedCount: Int)
    /// The request failed; nothing can be said about the rank.
    case requestFailed(reason: String)
    /// Not measured (e.g. skipped by the user or machine was asleep).
    case notChecked

    public var position: Int? {
        if case .found(let p, _) = self { return p }
        return nil
    }

    public var isFailure: Bool {
        if case .requestFailed = self { return true }
        return false
    }

    /// Short label suitable for a table cell.
    public var shortLabel: String {
        switch self {
        case .found(let p, _): "#\(p)"
        case .outsideObservedRange(let n): "> \(n)"
        case .requestFailed: "Error"
        case .notChecked: "—"
        }
    }

    /// Longer explanation for inspectors and tooltips.
    public var explanation: String {
        switch self {
        case .found(let p, let n): "Ranked #\(p) among \(n) observed results."
        case .outsideObservedRange(let n): "Not among the first \(n) results. This is not a rank of \(n + 1)."
        case .requestFailed(let reason): "Request failed: \(reason)"
        case .notChecked: "Not checked."
        }
    }
}

/// One rank measurement, tagged with everything needed to interpret it later.
public struct RankSample: Sendable, Hashable, Codable {
    public let keyword: String
    public let storefront: String
    public let device: DeviceContext
    public let provider: ProviderID
    public let outcome: RankOutcome
    /// When the provider actually answered (never a cache-served time).
    public let fetchedAt: Date
    /// The competing apps observed for this query (top N), in order.
    public let results: [SearchResultApp]

    public init(keyword: String, storefront: String, device: DeviceContext, provider: ProviderID,
                outcome: RankOutcome, fetchedAt: Date, results: [SearchResultApp]) {
        self.keyword = keyword
        self.storefront = storefront
        self.device = device
        self.provider = provider
        self.outcome = outcome
        self.fetchedAt = fetchedAt
        self.results = results
    }
}
