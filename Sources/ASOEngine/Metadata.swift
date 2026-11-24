import Foundation
import ASOCore

/// The listing per locale, as the macOS app's Metadata editor keeps it: what Apple holds (the baseline), the draft being
/// written, the checks the draft must pass and how it differs. Nothing here talks to Apple.
extension Engine {
    /// One locale worth writing, with where its draft stands.
    public struct MetadataLocale: Sendable, Codable, Equatable {
        public let locale: String
        public let name: String
        /// The tracked market whose store speaks this locale.
        public let market: String?
        /// "asc" or "manual"; absent without a baseline.
        public let baseline: String?
        public let hasDraft: Bool
        /// Fields that differ from the baseline.
        public let changes: Int
        public let errors: Int
    }

    public struct RulesSummary: Sendable, Codable, Equatable {
        /// 0–100.
        public let score: Int
        /// Of the 160 indexed characters (title, subtitle and keywords).
        public let charactersUsed: Int
        public let indexedWords: [String]
        /// Errors, warnings and notes; what already follows the rules is left out.
        public let findings: [ASORules.Finding]
    }

    public struct KeywordChange: Sendable, Codable, Equatable {
        public let kept: [String]
        public let added: [String]
        public let removed: [String]
    }

    public struct LegalState: Sendable, Codable, Equatable {
        public let settings: LegalFooterSettings
        public let effectiveEULA: String
        /// The draft's description already ends with the footer.
        public let inDescription: Bool
    }

    public struct MetadataReport: Sendable, Codable, Equatable {
        public let locale: String
        public let name: String
        /// The country the rules are read for: the tracked market speaking this locale, else the first one.
        public let market: String?
        public let baseline: MetadataBaselineRecord?
        /// The saved draft, else the baseline, else empty fields.
        public let draft: MetadataFields
        /// When the draft was last saved; absent while the editor still shows the baseline.
        public let draftUpdatedAt: Date?
        public let issues: [ValidationIssue]
        public let rules: RulesSummary
        public let changes: [FieldChange]
        /// Keywords kept, added and removed, when the keyword field changed.
        public let keywordChange: KeywordChange?
        public let legal: LegalState
    }

    public struct MetadataBatch: Sendable, Codable, Equatable {
        /// Locales whose draft changed.
        public let changed: [String]
        public let locales: Int
    }

    /// Locales worth writing: every tracked market's store language, plus those with a baseline or a draft. Market
    /// languages come first in market order, the rest alphabetically; en-US when there is nothing yet.
    public func metadataLocales(appID: Int) async throws -> [MetadataLocale] {
        let state = try await metadataState(appID)
        return state.locales.map { locale in
            let baseline = state.baselines[locale.rawValue]
            let draft = state.draft(locale)
            return MetadataLocale(locale: locale.rawValue, name: locale.displayName, market: state.market(for: locale),
                                  baseline: baseline?.source, hasDraft: state.drafts[locale.rawValue] != nil,
                                  changes: baseline.map { MetadataDiff.changes(baseline: $0.fields, draft: draft).count } ?? 0,
                                  errors: MetadataValidator.validate(draft).filter { $0.severity == .error }.count)
        }
    }

    /// The draft of one locale with its checks and its difference from the baseline.
    public func metadata(appID: Int, locale: AppLocale) async throws -> MetadataReport {
        try await metadataState(appID).report(locale)
    }

    /// Saves the draft of one locale. A draft is only created once it differs from what the editor starts from, so
    /// looking at a locale leaves no trace.
    public func saveDraft(appID: Int, locale: AppLocale, fields: MetadataFields, now: Date = Date()) async throws -> MetadataReport {
        var state = try await metadataState(appID)
        if fields != state.draft(locale) {
            let draft = MetadataDraftRecord(locale: locale.rawValue, fields: fields, updatedAt: now)
            try await store.replaceDraft(draft, appID: appID)
            state.drafts[locale.rawValue] = draft
        }
        return state.report(locale)
    }

    /// Drops the draft so the editor shows the baseline again.
    public func resetDraft(appID: Int, locale: AppLocale) async throws -> MetadataReport {
        var state = try await metadataState(appID)
        try await store.removeDraft(appID: appID, locale: locale.rawValue)
        state.drafts[locale.rawValue] = nil
        return state.report(locale)
    }

    /// Records what is live on the App Store today, typed or pasted, to diff drafts against without App Store Connect.
    public func setManualBaseline(appID: Int, locale: AppLocale, fields: MetadataFields, now: Date = Date()) async throws -> MetadataReport {
        var state = try await metadataState(appID)
        let baseline = MetadataBaselineRecord(locale: locale.rawValue, fields: fields, source: "manual", fetchedAt: now)
        try await store.replaceBaseline(baseline, appID: appID)
        state.baselines[locale.rawValue] = baseline
        return state.report(locale)
    }

    /// Changes the legal footer settings; nil leaves a setting as it is.
    public func setLegalFooter(appID: Int, enabled: Bool? = nil, eulaURL: String? = nil, privacyURL: String? = nil,
                               note: String? = nil) async throws -> LegalFooterSettings {
        var settings = try await metadataState(appID).legal
        if let enabled { settings.enabled = enabled }
        if let eulaURL { settings.eulaURL = try Self.webAddress(eulaURL, "Terms of Use") }
        if let privacyURL { settings.privacyURL = try Self.webAddress(privacyURL, "Privacy Policy") }
        if let note { settings.note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
        try await store.setLegalFooter(settings, appID: appID)
        return settings
    }

    /// Appends the legal footer, labelled in each locale's language, to the drafts of the given locales (every locale
    /// worth writing when nil). The block is re-generated, never duplicated.
    public func insertLegalFooter(appID: Int, locales: [AppLocale]? = nil, now: Date = Date()) async throws -> MetadataBatch {
        let state = try await metadataState(appID)
        guard state.legal.enabled else {
            throw EngineError.invalidArgument("The legal footer is off for this app. Turn it on with: aso metadata legal \(appID) --on")
        }
        return try await rewriteDrafts(state, locales: locales ?? state.locales, now: now) { fields, locale in
            fields.description = LegalFooter.apply(to: fields.description, locale: locale, eulaURL: state.legal.effectiveEULA,
                                                   privacyURL: state.legal.privacyURL, note: state.legal.note)
        }
    }

    /// Gives every locale without release notes the default note in its language: Apple refuses to save a version
    /// with an empty What's New.
    public func fillEmptyWhatsNew(appID: Int, now: Date = Date()) async throws -> MetadataBatch {
        let state = try await metadataState(appID)
        return try await rewriteDrafts(state, locales: state.locales, now: now) { fields, locale in
            if fields.whatsNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.whatsNew = ReleaseNotesDefaults.text(for: locale) }
        }
    }

    private func rewriteDrafts(_ state: MetadataState, locales: [AppLocale], now: Date,
                               _ change: (inout MetadataFields, AppLocale) -> Void) async throws -> MetadataBatch {
        var changed: [String] = []
        for locale in locales {
            var fields = state.draft(locale)
            change(&fields, locale)
            guard fields != state.draft(locale) else { continue }
            try await store.replaceDraft(MetadataDraftRecord(locale: locale.rawValue, fields: fields, updatedAt: now), appID: state.appID)
            changed.append(locale.rawValue)
        }
        return MetadataBatch(changed: changed, locales: locales.count)
    }

    static func webAddress(_ text: String, _ what: String) throws -> String {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty || address.hasPrefix("https://") || address.hasPrefix("http://") else {
            throw EngineError.invalidArgument("The \(what) address must start with https:// (or be empty).")
        }
        return address
    }

    func metadataState(_ appID: Int) async throws -> MetadataState {
        _ = try await app(appID)
        let markets = try await store.markets(appID: appID)
        let baselines = try await store.baselines(appID: appID)
        let drafts = try await store.drafts(appID: appID)
        return MetadataState(appID: appID, markets: markets.map(\.countryCode),
                             baselines: Dictionary(baselines.map { ($0.locale, $0) }, uniquingKeysWith: { a, _ in a }),
                             drafts: Dictionary(drafts.map { ($0.locale, $0) }, uniquingKeysWith: { a, _ in a }),
                             legal: try await store.legalFooter(appID: appID) ?? LegalFooterSettings())
    }
}

/// An app's stored metadata, read once per request.
struct MetadataState {
    let appID: Int
    /// Country codes of the tracked markets, in market order, without repeats for other devices.
    let markets: [String]
    var baselines: [String: MetadataBaselineRecord]
    var drafts: [String: MetadataDraftRecord]
    let legal: LegalFooterSettings

    init(appID: Int, markets: [String], baselines: [String: MetadataBaselineRecord], drafts: [String: MetadataDraftRecord], legal: LegalFooterSettings) {
        self.appID = appID
        var seen = Set<String>()
        self.markets = markets.filter { seen.insert($0).inserted }
        self.baselines = baselines
        self.drafts = drafts
        self.legal = legal
    }

    var locales: [AppLocale] {
        let primary = markets.compactMap { StorefrontRegistry.lookup($0)?.defaultLocale }
        let stored = (Array(baselines.keys) + Array(drafts.keys)).compactMap(AppLocale.parse)
        var out: [AppLocale] = []
        for locale in primary where !out.contains(locale) { out.append(locale) }
        for locale in stored.sorted(by: { $0.rawValue < $1.rawValue }) where !out.contains(locale) { out.append(locale) }
        return out.isEmpty ? [.enUS] : out
    }

    /// The tracked market whose store speaks the locale (de-DE → DE), else the one named by its region, else the first.
    func market(for locale: AppLocale) -> String? {
        let region = locale.rawValue.split(separator: "-").last.map { String($0).uppercased() }
        return markets.first { StorefrontRegistry.lookup($0)?.defaultLocale == locale } ?? markets.first { $0 == region } ?? markets.first
    }

    func draft(_ locale: AppLocale) -> MetadataFields {
        drafts[locale.rawValue]?.fields ?? baselines[locale.rawValue]?.fields ?? .empty
    }

    func report(_ locale: AppLocale) -> Engine.MetadataReport {
        let fields = draft(locale)
        let baseline = baselines[locale.rawValue]
        let siblings: [(AppLocale, MetadataFields)] = drafts.values.compactMap { d in
            guard let l = AppLocale.parse(d.locale), l != locale else { return nil }
            return (l, d.fields)
        }
        let storefront = market(for: locale)
        let review = ASORules.review(fields, locale: locale, siblings: siblings, storefront: storefront)
        let changes = baseline.map { MetadataDiff.changes(baseline: $0.fields, draft: fields) } ?? []
        let keywordChange = changes.first { $0.field == .keywords }.map { c -> Engine.KeywordChange in
            let delta = MetadataDiff.keywordDelta(before: c.before, after: c.after)
            return Engine.KeywordChange(kept: delta.kept, added: delta.added, removed: delta.removed)
        }
        let present = LegalFooter.contains(fields.description, eulaURL: legal.effectiveEULA, privacyURL: legal.privacyURL)
        return Engine.MetadataReport(
            locale: locale.rawValue, name: locale.displayName, market: storefront, baseline: baseline, draft: fields,
            draftUpdatedAt: drafts[locale.rawValue]?.updatedAt, issues: MetadataValidator.validate(fields),
            rules: Engine.RulesSummary(score: review.score, charactersUsed: review.charactersUsed, indexedWords: review.indexedWords,
                                       findings: review.findings.filter { $0.kind != .good }),
            changes: changes, keywordChange: keywordChange,
            legal: Engine.LegalState(settings: legal, effectiveEULA: legal.effectiveEULA, inDescription: present))
    }
}
