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

/// One popularity reading for a keyword, as the macOS app stores it: Apple's 1–100 score from the country list
/// ("list"), or "below the published range" ("belowRange") when the term is not on the list, with the list's lowest
/// score that month as the bound when it could be read. The score is relative within the country.
public struct PopularityReading: Sendable, Codable, Equatable {
    public let fetchedAt: Date
    public let country: String
    /// Raw `AppleAdsGenre` of the list; for "belowRange", the app's genre (nil when every genre was searched).
    public let genre: String?
    /// The month the reading describes.
    public let periodStart: Date
    public let periodEnd: Date
    public let popularity: Int?
    public let popularity1to5: Int?
    public let popularityInGenre: Int?
    public let rankInGenre: Int?
    /// "list" · "belowRange"
    public let source: String
    public let upperBound: Int?
    /// Every genre was searched, so "belowRange" means the term is on none of the lists.
    public let anyGenre: Bool
}

/// One keyword × storefront row of the advertiser's own Apple Ads report, for one campaign and the synced window
/// (the macOS app's AdsKeywordStat).
public struct AdsKeywordStatRecord: Sendable, Codable, Equatable {
    public let campaignID: Int
    public let campaignName: String
    public let adGroupName: String
    public let keywordID: Int
    public let keyword: String
    public let matchType: String
    public let status: String
    public let country: String
    public let bid: Double?
    public let currency: String
    public let impressions: Int
    public let taps: Int
    public let installs: Int
    public let spend: Double
    public let ttr: Double?
    public let conversionRate: Double?
    public let avgCPT: Double?
    public let avgCPI: Double?
    public let periodStart: Date
    public let periodEnd: Date
    public let fetchedAt: Date
}

/// One reading of a RevenueCat project's overview metrics (the macOS app's RevenueSnapshot). Revenue and new customers
/// cover the last 28 days; MRR is the normalized monthly revenue of active subscriptions.
public struct RevenueSnapshotRecord: Sendable, Codable, Equatable {
    public let projectID: String
    public let projectName: String
    /// The project's App Store apps, which tracked apps are matched against.
    public let bundleIDs: [String]
    public let appNames: [String]
    public let mrr: Double
    public let activeSubscriptions: Int
    public let revenue28d: Double
    public let newCustomers28d: Int
    public let activeTrials: Int
    public let activeUsers28d: Int
    public let fetchedAt: Date
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

/// A point in time ranks are compared around: an App Store release seen by a lookup, or a note pinned to a date.
public struct MarkerRecord: Sendable, Codable, Equatable {
    public let id: Int
    public let date: Date
    /// "release" · "note" · "change" (a listing applied to App Store Connect)
    public let kind: String
    public let title: String
    /// For a release: its version and the storefront it was seen in.
    public let version: String?
    public let country: String?

    public var marker: Marker { Marker(date: date, title: title, kind: kind) }
}

/// What Apple holds for one locale of an app: pulled from App Store Connect ("asc") or typed in ("manual"). Drafts are
/// diffed against it, and an apply refuses to write when Apple no longer holds it.
public struct MetadataBaselineRecord: Sendable, Codable, Equatable {
    public let locale: String
    public let fields: MetadataFields
    public let source: String
    public let appInfoLocalizationID: String?
    public let versionLocalizationID: String?
    public let versionString: String?
    public let versionState: String?
    public let fetchedAt: Date

    public init(locale: String, fields: MetadataFields, source: String, appInfoLocalizationID: String? = nil, versionLocalizationID: String? = nil,
                versionString: String? = nil, versionState: String? = nil, fetchedAt: Date) {
        self.locale = locale
        self.fields = fields
        self.source = source
        self.appInfoLocalizationID = appInfoLocalizationID
        self.versionLocalizationID = versionLocalizationID
        self.versionString = versionString
        self.versionState = versionState
        self.fetchedAt = fetchedAt
    }
}

/// One attempt to write a locale's listing to App Store Connect, as the macOS app logs it.
public struct ChangeLogRecord: Sendable, Codable, Equatable {
    public let id: Int
    public let createdAt: Date
    public let locale: String
    /// "applied" · "partial" (Apple's re-read differs from the draft) · "failed"
    public let status: String
    /// What was sent: each field's text before and after. Empty when the write failed.
    public let changes: [FieldChange]
    public let note: String
    /// Content hashes of the listing before and after the write; the result is absent when it failed.
    public let baselineHash: String
    public let resultHash: String?

    public init(id: Int = 0, createdAt: Date, locale: String, status: String, changes: [FieldChange], note: String, baselineHash: String,
                resultHash: String?) {
        self.id = id
        self.createdAt = createdAt
        self.locale = locale
        self.status = status
        self.changes = changes
        self.note = note
        self.baselineHash = baselineHash
        self.resultHash = resultHash
    }
}

/// The listing being written for one locale; stays on this computer until it is applied.
public struct MetadataDraftRecord: Sendable, Codable, Equatable {
    public let locale: String
    public let fields: MetadataFields
    public let updatedAt: Date
}

/// The Terms of Use and Privacy Policy links appended to every locale's description, as the macOS app keeps them per app.
public struct LegalFooterSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    /// A custom Terms of Use URL; empty uses Apple's standard EULA.
    public var eulaURL: String
    public var privacyURL: String
    /// An optional line above the links, one language for every locale.
    public var note: String

    public init(enabled: Bool = true, eulaURL: String = "", privacyURL: String = "", note: String = "") {
        self.enabled = enabled
        self.eulaURL = eulaURL
        self.privacyURL = privacyURL
        self.note = note
    }

    public var effectiveEULA: String {
        let custom = eulaURL.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? LegalFooter.appleStandardEULA : custom
    }
}
