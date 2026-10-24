import Foundation
import ASOCore

/// Errors the engine reports to its callers. Each case reads as a sentence.
public enum EngineError: Error, LocalizedError, Sendable, Equatable {
    case database(String)
    case notFound(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .database(let detail): "Data file error: \(detail)"
        case .notFound(let detail): detail
        case .invalidArgument(let detail): detail
        }
    }
}

/// A tracked app.
public struct AppRecord: Sendable, Hashable, Codable {
    public let trackID: Int
    public var bundleID: String?
    public var name: String
    public var sellerName: String
    public var iconURL: String?
    public var primaryGenre: String?
    public var storeVersion: String?
    public var createdAt: Date
    /// Raw `AppleAdsGenre` used for popularity lookups; nil searches every genre.
    public var adsGenre: String?

    public init(trackID: Int, bundleID: String?, name: String, sellerName: String, iconURL: String?, primaryGenre: String?,
                storeVersion: String?, createdAt: Date, adsGenre: String? = nil) {
        self.trackID = trackID
        self.bundleID = bundleID
        self.name = name
        self.sellerName = sellerName
        self.iconURL = iconURL
        self.primaryGenre = primaryGenre
        self.storeVersion = storeVersion
        self.createdAt = createdAt
        self.adsGenre = adsGenre
    }

    /// A newly tracked app; its Apple Ads genre follows the App Store category when Apple has a counterpart, as in the
    /// macOS app.
    public init(_ app: SearchResultApp, createdAt: Date) {
        self.init(trackID: app.trackID, bundleID: app.bundleID, name: app.name, sellerName: app.sellerName,
                  iconURL: app.iconURL?.absoluteString, primaryGenre: app.primaryGenre, storeVersion: app.version, createdAt: createdAt,
                  adsGenre: AppleAdsGenre(appStoreGenre: app.primaryGenre)?.rawValue)
    }

    var ownApp: KeywordJudgement.OwnApp { .init(trackID: trackID, name: name, sellerName: sellerName) }
}

/// One storefront and device an app is tracked in.
public struct MarketRecord: Sendable, Hashable, Codable {
    public let id: Int
    public let appID: Int
    public let countryCode: String
    public let device: DeviceContext
    public let createdAt: Date
}

/// A keyword tracked in one market.
public struct KeywordRecord: Sendable, Hashable, Codable {
    public let id: Int
    public let marketID: Int
    public let text: String
    public let normalized: String
    public let createdAt: Date
    public var note: String
    public var brandProbability: Double?
    public var fitProbability: Double?
    public var navigational: Double?
}

/// One stored rank measurement. Results and signals stay encoded until they are needed.
public struct RankObservationRecord: Sendable, Hashable {
    public let id: Int
    public let keywordID: Int
    public let fetchedAt: Date
    public let provider: ProviderID
    public let device: DeviceContext
    public let outcome: RankOutcome
    let resultsData: Data
    let signalsData: Data?

    public var results: [SearchResultApp] { (try? JSONDecoder().decode([SearchResultApp].self, from: resultsData)) ?? [] }
    public var signals: CompetitionSignals? { signalsData.flatMap { try? JSONDecoder().decode(CompetitionSignals.self, from: $0) } }
    public var point: RankPoint { RankPoint(fetchedAt: fetchedAt, outcome: outcome, provider: provider) }
}

/// How outcomes are stored: a kind plus the numbers that kind carries (the same shape the macOS app uses).
enum StoredOutcome {
    static func columns(_ outcome: RankOutcome) -> (kind: String, position: Int?, observedCount: Int, failureReason: String?) {
        switch outcome {
        case .found(let p, let n): ("found", p, n, nil)
        case .outsideObservedRange(let n): ("outside", nil, n, nil)
        case .requestFailed(let reason): ("failed", nil, 0, reason)
        case .notChecked: ("notChecked", nil, 0, nil)
        }
    }

    static func outcome(kind: String, position: Int?, observedCount: Int, failureReason: String?) -> RankOutcome {
        switch kind {
        case "found": .found(position: position ?? 0, observedCount: observedCount)
        case "outside": .outsideObservedRange(observedCount: observedCount)
        case "failed": .requestFailed(reason: failureReason ?? "unknown")
        default: .notChecked
        }
    }
}

/// A written review, stored once per storefront and feed id, so "new since the previous check" is exact.
public struct StoredReview: Sendable, Codable, Equatable {
    /// "<country>|<feed id>", the macOS app's review key.
    public let id: String
    public let country: String
    public let title: String
    public let body: String
    public let rating: Int
    public let author: String
    public let version: String?
    public let date: Date?
    public let fetchedAt: Date
    /// First seen in the most recent check; the next check clears it.
    public let isNew: Bool

    static func key(_ review: CustomerReview) -> String { "\(review.countryCode)|\(review.id)" }
}
