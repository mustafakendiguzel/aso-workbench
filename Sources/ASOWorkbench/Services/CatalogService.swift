import Foundation
import Observation
import SwiftData
import ASOCore
import ASOProviders

/// Adding apps, markets and keywords.
@Observable
final class CatalogService {
    private let search: ITunesSearchProvider
    private(set) var isSearching = false

    init(search: ITunesSearchProvider) {
        self.search = search
    }

    func findApps(query: String, storefront: Storefront) async throws -> [SearchResultApp] {
        isSearching = true
        defer { isSearching = false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = AppStoreURL.parse(trimmed) {
            let sf = parsed.countryCode.flatMap(StorefrontRegistry.lookup) ?? storefront
            return try await search.lookup(trackID: parsed.trackID, storefront: sf).map { [$0] } ?? []
        }
        return try await search.lookup(term: trimmed, storefront: storefront, limit: 25)
    }

    @discardableResult
    func addApp(_ result: SearchResultApp, markets: [Storefront], device: DeviceContext, context: ModelContext) -> TrackedApp {
        let existing = try? context.fetch(FetchDescriptor<TrackedApp>(predicate: #Predicate { $0.trackID == result.trackID })).first
        let app = existing ?? TrackedApp(trackID: result.trackID, bundleID: result.bundleID, name: result.name, sellerName: result.sellerName,
                                         iconURLString: result.iconURL?.absoluteString, primaryGenre: result.primaryGenre)
        if existing == nil {
            // Apple Ads genre follows the App Store category when Apple has a counterpart; otherwise all genres are searched.
            app.adsGenre = AppleAdsGenre(appStoreGenre: result.primaryGenre)
            context.insert(app)
        }
        for sf in markets where !app.markets.contains(where: { $0.countryCode == sf.countryCode && $0.device == device }) {
            let market = TrackedMarket(countryCode: sf.countryCode, device: device)
            market.app = app
            context.insert(market)
        }
        try? context.save()
        return app
    }

    func addMarket(to app: TrackedApp, storefront: Storefront, device: DeviceContext, context: ModelContext) {
        guard !app.markets.contains(where: { $0.countryCode == storefront.countryCode && $0.device == device }) else { return }
        let market = TrackedMarket(countryCode: storefront.countryCode, device: device)
        market.app = app
        context.insert(market)
        try? context.save()
    }

    /// Adds keywords (one per line or comma separated), de-duplicated against existing ones. Returns the count added.
    @discardableResult
    func addKeywords(_ raw: String, to market: TrackedMarket, context: ModelContext) -> Int {
        let existing = Set(market.keywords.map(\.normalized))
        var seen = existing
        var added = 0
        for piece in raw.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let norm = TrackedKeyword.normalize(text)
            guard seen.insert(norm).inserted else { continue }
            let keyword = TrackedKeyword(text: text)
            keyword.market = market
            context.insert(keyword)
            added += 1
        }
        try? context.save()
        return added
    }

    /// Looks the app up on the App Store and records a release marker when the version changed since the last look
    /// (or on the first look, dated with Apple's own release date). Cheap: one public request.
    private(set) var isCheckingRatings = false
    private(set) var isCheckingReviews = false
    private let reviewsProvider = AppReviewsProvider()

    /// Reads the newest written reviews for each storefront and stores the ones not seen before.
    func recordReviews(app: TrackedApp, storefronts: [Storefront], context: ModelContext) async {
        guard !isCheckingReviews else { return }
        isCheckingReviews = true
        defer { isCheckingReviews = false }
        for r in app.reviews where r.isNew { r.isNew = false }
        let known = Set(app.reviews.map(\.reviewID))
        var added = 0
        for sf in storefronts {
            guard let fetched = try? await reviewsProvider.reviews(trackID: app.trackID, storefront: sf) else { continue }
            for r in fetched where !known.contains("\(r.countryCode)|\(r.id)") {
                let rec = ReviewRecord(r)
                rec.isNew = !known.isEmpty   // the very first check is history, not news
                rec.app = app
                context.insert(rec)
                added += 1
            }
        }
        try? context.save()
        AppLog.write("[reviews] \(app.name): checked \(storefronts.count) storefront(s), \(added) review(s) stored (\(app.reviews.count) total)")
    }

    /// Stores the rating count/average the App Store reports in each storefront (one public request each).
    func recordRatings(app: TrackedApp, storefronts: [Storefront], context: ModelContext) async {
        guard !isCheckingRatings else { return }
        isCheckingRatings = true
        defer { isCheckingRatings = false }
        var newRatings = 0
        for sf in storefronts {
            guard let info = try? await search.lookup(trackID: app.trackID, storefront: sf) else { continue }
            record(ratingsOf: info, app: app, storefront: sf, context: context, newRatings: &newRatings)
        }
        try? context.save()
        AppLog.write("[ratings] \(app.name): checked \(storefronts.count) storefront(s), \(newRatings) new rating(s) since the previous check")
    }

    private func record(ratingsOf info: SearchResultApp, app: TrackedApp, storefront sf: Storefront, context: ModelContext, newRatings: inout Int) {
        guard let count = info.ratingCount else { return }
        let previous = app.ratings.filter { $0.countryCode == sf.countryCode }.max { $0.fetchedAt < $1.fetchedAt }
        let reading = previous.map { RatingReading(countryCode: $0.countryCode, count: $0.count, average: $0.average, fetchedAt: $0.fetchedAt) }
        guard RatingTrend.shouldRecord(count: count, average: info.averageRating, previous: reading, now: .now) else { return }
        let o = RatingObservation(countryCode: sf.countryCode, count: count, average: info.averageRating)
        o.app = app
        context.insert(o)
        if let previous, count > previous.count { newRatings += count - previous.count }
    }

    @discardableResult
    func recordReleaseIfNew(app: TrackedApp, storefront: Storefront, context: ModelContext) async -> ReleaseMarker? {
        guard let info = try? await search.lookup(trackID: app.trackID, storefront: storefront), let version = info.version, !version.isEmpty else { return nil }
        if app.storeDescription == nil { app.storeDescription = info.storeDescription ?? "" }
        var newRatings = 0
        record(ratingsOf: info, app: app, storefront: storefront, context: context, newRatings: &newRatings)
        guard app.storeVersion != version else { return nil }
        app.storeVersion = version
        if app.releases.contains(where: { $0.versionString == version }) { try? context.save(); return nil }
        let marker = ReleaseMarker(date: info.currentVersionReleaseDate ?? .now, kind: "release", title: "v\(version)", versionString: version, storefront: storefront.countryCode)
        marker.app = app
        context.insert(marker)
        try? context.save()
        AppLog.write("[release] \(app.name): v\(version) released \((info.currentVersionReleaseDate ?? .now).formatted(date: .abbreviated, time: .omitted)) (seen in \(storefront.countryCode))")
        return marker
    }

}
