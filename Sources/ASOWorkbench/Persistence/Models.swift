import Foundation
import SwiftData
import ASOCore
import ASOProviders

// SwiftData records. Domain logic never touches these directly; services convert
// to and from the ASOCore value types.

@Model
final class TrackedApp {
    @Attribute(.unique) var trackID: Int
    var bundleID: String?
    var name: String
    var sellerName: String
    var iconURLString: String?
    var primaryGenre: String?
    /// App Store Connect resource id, resolved once the ASC key can see the app.
    var ascAppID: String?
    /// Apple Ads genre used for official popularity lookups (user-chosen).
    var adsGenreRaw: String?
    /// The App Store description (public, from the lookup API); the reference for keyword fit. Empty string = looked up, none published.
    var storeDescription: String?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TrackedMarket.app) var markets: [TrackedMarket] = []
    @Relationship(deleteRule: .cascade, inverse: \MetadataSnapshotRecord.app) var snapshots: [MetadataSnapshotRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \MetadataDraftRecord.app) var drafts: [MetadataDraftRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ChangeLogEntry.app) var changes: [ChangeLogEntry] = []
    @Relationship(deleteRule: .cascade, inverse: \ReleaseMarker.app) var releases: [ReleaseMarker] = []
    @Relationship(deleteRule: .cascade, inverse: \RatingObservation.app) var ratings: [RatingObservation] = []
    @Relationship(deleteRule: .cascade, inverse: \ReviewRecord.app) var reviews: [ReviewRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \AdsKeywordStat.app) var adsStats: [AdsKeywordStat] = []
    /// Version last seen on the App Store (lookup API); a different one means a release happened.
    var storeVersion: String?
    /// Legal footer appended to every locale's description (Terms of Use / Privacy Policy links, optional note).
    var eulaURL: String = ""
    var privacyURL: String = ""
    var legalNote: String = ""
    var legalFooterEnabled: Bool = true
    /// Apple's standard EULA unless a custom one is set.
    var effectiveEULA: String { eulaURL.trimmingCharacters(in: .whitespaces).isEmpty ? LegalFooter.appleStandardEULA : eulaURL.trimmingCharacters(in: .whitespaces) }
    var hasLegalFooter: Bool { legalFooterEnabled }

    /// Every point in time a comparison makes sense around: App Store releases, notes, and applied metadata changes.
    var markers: [Marker] {
        let r = releases.map { Marker(date: $0.createdAt, title: $0.title, kind: $0.kind) }
        let c = changes.filter { $0.status != "failed" }.map { Marker(date: $0.createdAt, title: MetadataPublishing.markerTitle(fields: $0.changes.map(\.field), locale: $0.localeRaw), kind: "change") }
        return (r + c).sorted { $0.date < $1.date }
    }

    init(trackID: Int, bundleID: String?, name: String, sellerName: String, iconURLString: String?, primaryGenre: String?) {
        self.trackID = trackID
        self.bundleID = bundleID
        self.name = name
        self.sellerName = sellerName
        self.iconURLString = iconURLString
        self.primaryGenre = primaryGenre
        self.createdAt = .now
    }

    var iconURL: URL? { iconURLString.flatMap(URL.init(string:)) }
    var adsGenre: AppleAdsGenre? {
        get { adsGenreRaw.flatMap(AppleAdsGenre.init(rawValue:)) }
        set { adsGenreRaw = newValue?.rawValue }
    }
    var sortedMarkets: [TrackedMarket] { markets.sorted { $0.countryCode < $1.countryCode } }
}

@Model
final class TrackedMarket {
    var countryCode: String
    var deviceRaw: String
    var app: TrackedApp?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TrackedKeyword.market) var keywords: [TrackedKeyword] = []

    init(countryCode: String, device: DeviceContext) {
        self.countryCode = countryCode.uppercased()
        self.deviceRaw = device.rawValue
        self.createdAt = .now
    }

    var device: DeviceContext { DeviceContext(rawValue: deviceRaw) ?? .iPhone }
    var storefront: Storefront? { StorefrontRegistry.lookup(countryCode) }
    var title: String { "\(countryCode) · \(device.label)" }
    var sortedKeywords: [TrackedKeyword] { keywords.sorted { $0.normalized < $1.normalized } }

    var lastMeasuredAt: Date? {
        keywords.compactMap { $0.latestObservation?.fetchedAt }.max()
    }
}

@Model
final class TrackedKeyword {
    var text: String
    var normalized: String
    var createdAt: Date
    var note: String
    /// Jev judgements (filled during popularity refresh): is this a brand, and what kind of search is it.
    var brandProbability: Double?
    var intent: String?
    /// Jev: probability that someone searching this term wants an app like this one (0–1). Nil = not checked.
    var fitProbability: Double?
    /// Jev, shown the actual top results: probability the term is a way of finding one specific app ("solides" → Sólides).
    var navigational: Double?
    var market: TrackedMarket?

    @Relationship(deleteRule: .cascade, inverse: \RankObservation.keyword) var observations: [RankObservation] = []
    @Relationship(deleteRule: .cascade, inverse: \PopularityObservation.keyword) var popularity: [PopularityObservation] = []

    init(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed
        self.normalized = TrackedKeyword.normalize(trimmed)
        self.createdAt = .now
        self.note = ""
    }

    static func normalize(_ text: String) -> String { KeywordText.normalize(text) }

    var sortedObservations: [RankObservation] { observations.sorted { $0.fetchedAt < $1.fetchedAt } }
    var latestObservation: RankObservation? { observations.max { $0.fetchedAt < $1.fetchedAt } }

    /// Rank comparisons live in ASOCore so every platform computes them the same way.
    private var history: RankHistory<RankObservation> { RankHistory(observations) { $0.point } }

    /// Latest observation whose request actually succeeded (found or outside range).
    var latestMeasured: RankObservation? { history.latestMeasured }

    /// Previous successful observation from the *same provider* as the latest one.
    var previousMeasured: RankObservation? { history.previousMeasured }

    /// Rank delta vs previous measurement; positive means improved. Nil when not comparable.
    var rankDelta: Int? { history.rankDelta }

    var successfulObservations: [RankObservation] { history.successful }

    /// Last successful measurement at or before `date` and the latest one after it (nil when either side is missing).
    func beforeAfter(_ date: Date) -> (before: RankObservation, after: RankObservation)? { history.beforeAfter(date) }

    /// Rank movement against a chosen reference. "Not in top N" counts as N+1 so a keyword that entered or left the
    /// results still shows a number. Positive = moved up.
    func rankDelta(reference: DeltaReference, markers: [Marker]) -> (delta: Int?, against: String) {
        history.delta(reference: reference, markers: markers)
    }

    var latestPopularity: PopularityObservation? { popularity.max { $0.fetchedAt < $1.fetchedAt } }

    /// Brand, golden and lead verdicts, computed in ASOCore from what this record stores.
    var judgement: KeywordJudgement {
        let own = market?.app.map { KeywordJudgement.OwnApp(trackID: $0.trackID, name: $0.name, sellerName: $0.sellerName) }
        return KeywordJudgement(term: text, ownApp: own, measurement: latestMeasured.map { .init(results: $0.results, signals: $0.signals) },
                                brandProbability: brandProbability, navigational: navigational, fitProbability: fitProbability,
                                popularity: latestPopularity?.popularity1to100)
    }

    /// Read straight from the latest measurement so table cells do not decode its results when the signals suffice.
    var difficultyScore: DifficultyScore? {
        guard let m = latestMeasured else { return nil }
        return KeywordJudgement.difficulty(signals: m.signals, results: m.results, term: text)
    }

    /// popularity × (1 − (difficulty/100)²): demand, discounted quadratically by competition. Nil without both inputs.
    var opportunity: Double? {
        guard let p = latestPopularity?.popularity1to100, let d = difficultyScore else { return nil }
        return Opportunity.score(popularity: p, difficulty: d.score)
    }

    /// Our own app is the first result: the term is ours, whatever else the results say.
    var ownAppLeads: Bool { judgement.ownAppLeads }

    /// The term is our own name ("acme notes" for Acme Notes): a brand, but ours, always worth ranking for.
    var isOwnBrandTerm: Bool { judgement.isOwnBrandTerm }

    /// From the measured results: the top app carries the term's name and either nobody else does or it dwarfs the field.
    var leaderOwnsTerm: Bool { judgement.leaderOwnsTerm }

    /// Another company's name by any of three signals: Jev on the term, Jev on the term with the results in view, or the results themselves.
    var isBrandLike: Bool { judgement.isBrandLike }

    /// Demand, competition and brand checks pass, regardless of whether the term fits this app.
    func passesGoldenNumbers(minPopularity: Int, maxDifficulty: Int) -> Bool {
        judgement.passesGoldenNumbers(minPopularity: minPopularity, maxDifficulty: maxDifficulty)
    }

    /// The advertiser's own Apple Ads results for this term in this storefront (last synced window), summed over campaigns.
    var adsSummary: (impressions: Int, taps: Int, installs: Int, spend: Double, currency: String)? {
        guard let app = market?.app, let cc = market?.countryCode else { return nil }
        let rows = app.adsStats.filter { $0.normalized == normalized && $0.country == cc }
        guard !rows.isEmpty else { return nil }
        return (rows.reduce(0) { $0 + $1.impressions }, rows.reduce(0) { $0 + $1.taps }, rows.reduce(0) { $0 + $1.installs }, rows.reduce(0) { $0 + $1.spend }, rows.first?.currency ?? "")
    }

    /// Golden for this app: the numbers pass and the term is what this app does (fit ≥ 0.5; unchecked counts as related).
    func isGolden(minPopularity: Int, maxDifficulty: Int) -> Bool {
        judgement.isGolden(minPopularity: minPopularity, maxDifficulty: maxDifficulty)
    }

    /// The numbers pass but the term is not what this app does, a lead for a different app, not a keyword for this one.
    func isGoldenLead(minPopularity: Int, maxDifficulty: Int) -> Bool {
        judgement.isGoldenLead(minPopularity: minPopularity, maxDifficulty: maxDifficulty)
    }
}

@Model
final class RankObservation {
    var fetchedAt: Date
    var providerRaw: String
    var deviceRaw: String
    var outcomeKind: String
    var position: Int?
    var observedCount: Int
    var failureReason: String?
    /// Top results as JSON `[SearchResultApp]` (bounded to keep the store small).
    var resultsData: Data
    var signalsData: Data?
    var keyword: TrackedKeyword?

    init(sample: RankSample, keepResults: Int = 50) {
        fetchedAt = sample.fetchedAt
        providerRaw = sample.provider.rawValue
        deviceRaw = sample.device.rawValue
        switch sample.outcome {
        case .found(let p, let n): outcomeKind = "found"; position = p; observedCount = n
        case .outsideObservedRange(let n): outcomeKind = "outside"; position = nil; observedCount = n
        case .requestFailed(let r): outcomeKind = "failed"; position = nil; observedCount = 0; failureReason = r
        case .notChecked: outcomeKind = "notChecked"; position = nil; observedCount = 0
        }
        resultsData = (try? JSONEncoder().encode(Array(sample.results.prefix(keepResults)))) ?? Data()
        if !sample.results.isEmpty {
            signalsData = try? JSONEncoder().encode(CompetitionSignals(results: sample.results, term: sample.keyword))
        }
    }

    var outcome: RankOutcome {
        switch outcomeKind {
        case "found": .found(position: position ?? 0, observedCount: observedCount)
        case "outside": .outsideObservedRange(observedCount: observedCount)
        case "failed": .requestFailed(reason: failureReason ?? "unknown")
        default: .notChecked
        }
    }

    var provider: ProviderID { ProviderID(rawValue: providerRaw) }
    var results: [SearchResultApp] { (try? JSONDecoder().decode([SearchResultApp].self, from: resultsData)) ?? [] }
    var signals: CompetitionSignals? { signalsData.flatMap { try? JSONDecoder().decode(CompetitionSignals.self, from: $0) } }
    var point: RankPoint { RankPoint(fetchedAt: fetchedAt, outcome: outcome, provider: provider) }

    func asSample(keyword: String, storefront: String) -> RankSample {
        RankSample(keyword: keyword, storefront: storefront, device: DeviceContext(rawValue: deviceRaw) ?? .iPhone,
                   provider: provider, outcome: outcome, fetchedAt: fetchedAt, results: results)
    }
}

@Model
final class PopularityObservation {
    var fetchedAt: Date
    var countryCode: String
    var genreRaw: String
    var periodStart: Date
    var periodEnd: Date
    var popularity1to100: Int?
    var popularity1to5: Int?
    var popularityInGenre: Int?
    var rankInGenre: Int?
    /// True when the query ran but Apple had no record for this term, stored so
    /// "no data" is a first-class observation rather than an absence.
    var noRecord: Bool
    /// True when all genres were searched (so "no record" means absent from every dataset).
    var anyGenre: Bool = false
    /// "country" (official country list) · "global" (Apple suggestion score, cross-country) · "bound" (below the published range).
    var scope: String = "country"
    /// For scope "bound": the lowest score Apple published in the checked list this month; the term is below it.
    var upperBound: Int?
    var keyword: TrackedKeyword?

    init(record: PopularityRecord) {
        fetchedAt = record.fetchedAt
        countryCode = record.countryCode
        genreRaw = record.genre.rawValue
        periodStart = record.periodStart
        periodEnd = record.periodEnd
        popularity1to100 = record.popularity1to100
        popularity1to5 = record.popularity1to5
        popularityInGenre = record.popularityInGenre
        rankInGenre = record.rankInGenre
        noRecord = false
    }

    init(noRecordFor countryCode: String, genre: AppleAdsGenre, periodStart: Date, periodEnd: Date, upperBound: Int?) {
        fetchedAt = .now
        self.countryCode = countryCode
        genreRaw = genre.rawValue
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        noRecord = true
        scope = "bound"
        self.upperBound = upperBound
    }

    /// Confidence 0–1 for scope "estimate" (peak probability of the predicted band).
    var estimateConfidence: Double?
    /// For terms Apple leaves at the floor (index 5 or "below range"): the model's 6–29 demand rank among floor terms.
    /// Ordering only: Apple publishes nothing between 6 and 31.
    var subFloorEstimate: Int?
    var subFloorProbability: Double?

    /// Model estimate (public signals + Jev), only used when Apple has no number. `value` nil = "below the published range".
    init(estimate value: Int?, confidence: Double, upperBound: Int?, countryCode: String, periodStart: Date, periodEnd: Date) {
        fetchedAt = .now
        self.countryCode = countryCode
        genreRaw = ""
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        popularity1to100 = value
        noRecord = value == nil
        scope = "estimate"
        self.upperBound = upperBound
        estimateConfidence = confidence
    }

    /// Apple Ads dashboard popularity index for the exact term in this storefront (5 = floor).
    init(dashboardIndex value: Int, countryCode: String, periodStart: Date, periodEnd: Date) {
        fetchedAt = .now
        self.countryCode = countryCode
        genreRaw = ""
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        popularity1to100 = value
        noRecord = false
        scope = "index"
    }

    var genre: AppleAdsGenre? { AppleAdsGenre(rawValue: genreRaw) }
}

@Model
final class MetadataSnapshotRecord {
    var localeRaw: String
    var fetchedAt: Date
    var fieldsData: Data
    var appInfoLocalizationID: String?
    var versionLocalizationID: String?
    var versionString: String?
    var versionState: String?
    var contentHash: String
    /// "asc" when pulled from App Store Connect, "manual" when the user pasted it.
    var source: String
    var app: TrackedApp?

    init(snapshot: MetadataSnapshot, source: String) {
        localeRaw = snapshot.locale.rawValue
        fetchedAt = snapshot.fetchedAt
        fieldsData = (try? JSONEncoder().encode(snapshot.fields)) ?? Data()
        appInfoLocalizationID = snapshot.appInfoLocalizationID
        versionLocalizationID = snapshot.versionLocalizationID
        versionString = snapshot.versionString
        versionState = snapshot.versionState
        contentHash = snapshot.contentHash
        self.source = source
    }

    var locale: AppLocale? { AppLocale.parse(localeRaw) }
    var fields: MetadataFields { (try? JSONDecoder().decode(MetadataFields.self, from: fieldsData)) ?? .empty }

    var snapshot: MetadataSnapshot? {
        guard let locale else { return nil }
        return MetadataSnapshot(locale: locale, fields: fields, appInfoLocalizationID: appInfoLocalizationID,
                                versionLocalizationID: versionLocalizationID, versionString: versionString, versionState: versionState, fetchedAt: fetchedAt)
    }
}

@Model
final class MetadataDraftRecord {
    var localeRaw: String
    var updatedAt: Date
    var fieldsData: Data
    var app: TrackedApp?

    init(locale: AppLocale, fields: MetadataFields) {
        localeRaw = locale.rawValue
        updatedAt = .now
        fieldsData = (try? JSONEncoder().encode(fields)) ?? Data()
    }

    var locale: AppLocale? { AppLocale.parse(localeRaw) }
    var fields: MetadataFields {
        get { (try? JSONDecoder().decode(MetadataFields.self, from: fieldsData)) ?? .empty }
        set { fieldsData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }
}

@Model
final class ChangeLogEntry {
    var createdAt: Date
    var localeRaw: String
    /// applied · partial · failed
    var status: String
    var changesData: Data
    var note: String
    var baselineHash: String
    var resultHash: String?
    var app: TrackedApp?

    init(locale: AppLocale, status: String, changes: [FieldChange], note: String, baselineHash: String, resultHash: String?) {
        createdAt = .now
        localeRaw = locale.rawValue
        self.status = status
        changesData = (try? JSONEncoder().encode(changes)) ?? Data()
        self.note = note
        self.baselineHash = baselineHash
        self.resultHash = resultHash
    }

    var changes: [FieldChange] { (try? JSONDecoder().decode([FieldChange].self, from: changesData)) ?? [] }
    var locale: AppLocale? { AppLocale.parse(localeRaw) }
}

/// One term in the popularity training set. Unique per (normalized, storefront).
@Model
final class TrainingRow {
    var term: String
    var normalized: String
    var storefront: String
    /// genre_list:<GENRE> · hints:<seed> · suggestions:<appID> · tracked
    var source: String
    /// Popularity label 5–100: the country-list score when the term is on a list, else the dashboard index.
    var label: Int?
    /// "list" · "index" · ""
    var labelSource: String = ""
    var labelMissing: Bool = false
    var labeledAt: Date?
    /// Score from Apple's monthly country list when the term came from there (for comparison only; never a feature).
    var listScore: Int?
    var featuresData: Data?
    var jevData: Data?
    var hintsCollected: Bool = false
    var resultsCollected: Bool = false
    var jevCollected: Bool = false
    var createdAt: Date

    init(term: String, storefront: String, source: String, listScore: Int? = nil) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.term = trimmed
        normalized = TrackedKeyword.normalize(trimmed)
        self.storefront = storefront.uppercased()
        self.source = source
        self.listScore = listScore
        createdAt = .now
    }

    var features: PublicFeatures {
        get { featuresData.flatMap { try? JSONDecoder().decode(PublicFeatures.self, from: $0) } ?? PublicFeatures(term: normalized) }
        set { featuresData = try? JSONEncoder().encode(newValue) }
    }
    var jev: JevFeatures? {
        get { jevData.flatMap { try? JSONDecoder().decode(JevFeatures.self, from: $0) } }
        set { jevData = newValue.flatMap { try? JSONEncoder().encode($0) }; jevCollected = newValue?.isCollected == true }
    }
    var band: PopularityBand? { label.map(PopularityBand.init(index:)) }
}

/// A published search term in one storefront, scored as a potential app gap (independent of any tracked app).
@Model
final class IdeaCandidate {
    var countryCode: String
    var term: String
    var normalized: String
    var genreRaw: String
    var popularity: Int
    var rankInGenre: Int?
    var brand: Double?
    var natural: Double?
    var intent: String?
    /// Jev: could a standalone iPhone app serve this search at all?
    var appable: Double?
    var difficulty: Double?
    var leaderName: String?
    var leaderRatings: Int?
    var medianRatings: Int?
    var titleMatches: Int?
    var resultCount: Int?
    var measuredAt: Date?
    var updatedAt: Date
    var note: String = ""
    /// From the results: the top app carries the term's name and dominates, a navigational search for that app.
    var leaderOwnsTerm: Bool?
    /// From the results: a single word that eight or more small apps already carry in their names (a name, not a need).
    var nameCrowd: Bool?
    /// Jev, shown the top results: probability the search is a way of finding one specific app.
    var navigational: Double?
    /// Names of the first five results at measurement time ("a | b | c"), the context for the navigational check.
    var topNames: String?

    init(countryCode: String, term: String, normalized: String, genreRaw: String, popularity: Int) {
        self.countryCode = countryCode
        self.term = term
        self.normalized = normalized
        self.genreRaw = genreRaw
        self.popularity = popularity
        updatedAt = .now
    }

    var opportunity: Double? { difficulty.map { Opportunity.score(popularity: popularity, difficulty: $0) } }

    /// The gap verdict, computed in ASOCore from what this record stores.
    var gap: IdeaGap {
        IdeaGap(term: term, normalized: normalized, difficulty: difficulty, brand: brand, natural: natural, appable: appable,
                navigational: navigational, leaderOwnsTerm: leaderOwnsTerm, nameCrowd: nameCrowd)
    }

    /// "free / gratis / kostenlos …": people who type it will not pay, so it is no lead for a new app.
    var wantsFree: Bool { IdeaGap.wantsFree(normalized: normalized) }

    /// Real demand, an app-shaped need, nobody's brand (by Jev and by the results), and beatable results.
    func isGap(maxDifficulty: Int) -> Bool { gap.isGap(maxDifficulty: maxDifficulty) }

    /// Derives the results-based flags from what a measurement stored.
    func updateResultFlags() {
        guard measuredAt != nil, let leader = leaderName else { return }
        let flags = IdeaGap.resultFlags(term: term, normalized: normalized, leaderName: leader, leaderRatings: leaderRatings,
                                        medianRatings: medianRatings, titleMatches: titleMatches)
        leaderOwnsTerm = flags.leaderOwnsTerm
        nameCrowd = flags.nameCrowd
    }
}

/// An App Store release (seen through the lookup API) or a note the user pins to a date.
@Model
final class ReleaseMarker {
    var createdAt: Date
    /// "release" · "note"
    var kind: String
    var title: String
    var versionString: String?
    var storefront: String?
    var note: String = ""
    var app: TrackedApp?

    init(date: Date, kind: String, title: String, versionString: String? = nil, storefront: String? = nil, note: String = "") {
        createdAt = date
        self.kind = kind
        self.title = title
        self.versionString = versionString
        self.storefront = storefront
        self.note = note
    }
}

/// Rating count and average as the App Store reported them for one storefront at one moment.
@Model
final class RatingObservation {
    var countryCode: String
    var count: Int
    var average: Double?
    var fetchedAt: Date
    var app: TrackedApp?

    init(countryCode: String, count: Int, average: Double?, fetchedAt: Date = .now) {
        self.countryCode = countryCode
        self.count = count
        self.average = average
        self.fetchedAt = fetchedAt
    }
}

/// A written review, stored once by its feed id so "new since the previous check" is exact.
@Model
final class ReviewRecord {
    @Attribute(.unique) var reviewID: String
    var countryCode: String
    var title: String
    var body: String
    var rating: Int
    var author: String
    var version: String?
    var date: Date?
    var fetchedAt: Date
    /// True for reviews first seen in the most recent check; cleared by the next check.
    var isNew: Bool = false
    var app: TrackedApp?

    init(_ r: CustomerReview) {
        reviewID = "\(r.countryCode)|\(r.id)"
        countryCode = r.countryCode
        title = r.title
        body = r.body
        rating = r.rating
        author = r.author
        version = r.version
        date = r.date
        fetchedAt = .now
    }
}

/// One keyword × storefront row of the advertiser's own Apple Ads report, for one campaign and one date window.
@Model
final class AdsKeywordStat {
    var campaignID: Int
    var campaignName: String
    var adGroupName: String
    var keywordID: Int
    var keyword: String
    var normalized: String
    var matchType: String
    var status: String
    var country: String
    var bid: Double?
    var currency: String
    var impressions: Int
    var taps: Int
    var installs: Int
    var spend: Double
    var ttr: Double?
    var conversionRate: Double?
    var avgCPT: Double?
    var avgCPI: Double?
    var periodStart: Date
    var periodEnd: Date
    var fetchedAt: Date
    var app: TrackedApp?

    init(_ s: AppleAdsCampaignProvider.KeywordStat, campaignName: String, periodStart: Date, periodEnd: Date) {
        campaignID = s.campaignID
        self.campaignName = campaignName
        adGroupName = s.adGroupName
        keywordID = s.keywordID
        keyword = s.keyword
        normalized = TrackedKeyword.normalize(s.keyword)
        matchType = s.matchType
        status = s.status
        country = s.country
        bid = s.bid
        currency = s.currency
        impressions = s.impressions
        taps = s.taps
        installs = s.installs
        spend = s.spend
        ttr = s.ttr
        conversionRate = s.conversionRate
        avgCPT = s.avgCPT
        avgCPI = s.avgCPI
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        fetchedAt = .now
    }
}

/// One read of a RevenueCat project's overview metrics.
@Model
final class RevenueSnapshot {
    var projectID: String
    var projectName: String
    /// Bundle ids of the project's App Store apps, "|"-joined.
    var bundleIDs: String
    var appNames: String
    var mrr: Double
    var activeSubscriptions: Int
    var revenue28d: Double
    var newCustomers28d: Int
    var activeTrials: Int
    var activeUsers28d: Int
    var fetchedAt: Date

    init(projectID: String, projectName: String, bundleIDs: [String], appNames: [String], mrr: Double, activeSubscriptions: Int, revenue28d: Double,
         newCustomers28d: Int, activeTrials: Int, activeUsers28d: Int) {
        self.projectID = projectID
        self.projectName = projectName
        self.bundleIDs = bundleIDs.joined(separator: "|")
        self.appNames = appNames.joined(separator: "|")
        self.mrr = mrr
        self.activeSubscriptions = activeSubscriptions
        self.revenue28d = revenue28d
        self.newCustomers28d = newCustomers28d
        self.activeTrials = activeTrials
        self.activeUsers28d = activeUsers28d
        fetchedAt = .now
    }
}
