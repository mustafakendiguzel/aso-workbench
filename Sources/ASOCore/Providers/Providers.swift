import Foundation

// Provider contracts. Implementations live in ASOProviders; the app only talks to these.

/// Public search ranking: which apps come back for a query in a storefront.
public protocol SearchRankProvider: Sendable {
    var id: ProviderID { get }
    /// Returns up to `limit` results in Apple's order. Throws on transport failure.
    func search(term: String, storefront: Storefront, device: DeviceContext, limit: Int) async throws -> [SearchResultApp]
    /// Looks up apps by name (for the "Add app" flow).
    func lookup(term: String, storefront: Storefront, limit: Int) async throws -> [SearchResultApp]
    /// Looks up a single app by its numeric App Store ID.
    func lookup(trackID: Int, storefront: Storefront) async throws -> SearchResultApp?
}

/// Autocomplete-style keyword suggestions.
public protocol SuggestionProvider: Sendable {
    var id: ProviderID { get }
    func suggestions(seed: String, storefront: Storefront) async throws -> [KeywordSuggestion]
}

/// Written customer reviews of one app in one storefront, newest first.
public protocol CustomerReviewProvider: Sendable {
    func reviews(trackID: Int, storefront: Storefront, page: Int) async throws -> [CustomerReview]
}

/// Official popularity data (Apple Ads Platform API v1).
public protocol PopularityProvider: Sendable {
    var id: ProviderID { get }
    var isConfigured: Bool { get async }
    /// The genre dataset for a country and period; the primary, campaign-free path.
    func genreDataset(country: String, genre: AppleAdsGenre, monthsBack: Int) async throws -> [PopularityRecord]
    /// Term-filtered query. Adapters validate whether Apple accepts the filter and record it in capabilities.
    func popularity(terms: [String], country: String, genre: AppleAdsGenre, monthsBack: Int) async throws -> [PopularityRecord]
    /// App-seeded keyword suggestions (country filter is not honoured by Apple; results are labelled cross-country).
    func keywordSuggestions(appID: Int, seeds: [String], country: String) async throws -> [KeywordSuggestion]
    func capabilities() async -> ProviderCapabilities
}

/// App Store Connect metadata read/write.
public protocol MetadataProvider: Sendable {
    var id: ProviderID { get }
    var isConfigured: Bool { get async }
    /// Resolves the ASC app resource id for a bundle id.
    func resolveAppID(bundleID: String) async throws -> String
    /// Reads current metadata for all locales of the editable version.
    func snapshots(ascAppID: String) async throws -> [MetadataSnapshot]
    /// Applies changed fields for one locale. Returns the re-read snapshot.
    func apply(ascAppID: String, snapshot: MetadataSnapshot, changes: [MetadataField: String]) async throws -> MetadataSnapshot
    /// Cheap authenticated call used by "Test connection".
    func verify() async throws -> String
}
