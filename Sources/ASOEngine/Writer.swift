import Foundation
import ASOCore

/// The AI metadata writer with the app's own evidence, as the macOS app's Write menu runs it: three proposals for a
/// locale, Make better, every locale in turn, and What's New in other languages. The model only drafts; `ASOCore`'s
/// writer repairs and scores every proposal. Drafts stay on this computer.
extension Engine {
    /// A proposal as reports show it.
    public struct WrittenProposal: Sendable, Codable, Equatable {
        public let label: String
        public let fields: MetadataFields
        public let rationale: String
        /// The ASO rules score (0–100) and indexed characters of the 160.
        public let score: Int
        public let charactersUsed: Int
        /// Errors, warnings and notes; what already follows the rules is left out.
        public let findings: [ASORules.Finding]
        public let issues: [ValidationIssue]
        /// What the writer fixed after the model (shortened, extended, keywords packed or topped up).
        public let repairs: [String]
        /// Priority phrases of the keyword plan it covers and misses.
        public let covered: [String]
        public let missed: [String]

        init(_ p: MetadataWriter.Proposal) {
            label = p.label
            fields = p.fields
            rationale = p.rationale
            score = p.review.score
            charactersUsed = p.review.charactersUsed
            findings = p.review.findings.filter { $0.kind != .good }
            issues = p.issues
            repairs = p.repairs
            covered = p.coveredPhrases
            missed = p.missedPhrases
        }
    }

    public struct WriteResult: Sendable, Codable, Equatable {
        public let locale: String
        /// The tracked market whose evidence was used.
        public let market: String?
        /// Best first.
        public let proposals: [WrittenProposal]
        /// The best proposal was saved as the locale's draft.
        public let saved: Bool
        public let cost: String?
    }

    public struct ImproveResult: Sendable, Codable, Equatable {
        public let locale: String
        /// The draft's rules score before.
        public let before: Int
        public let proposal: WrittenProposal
        public let saved: Bool
        public let cost: String?
    }

    /// One locale of a batch: the saved proposal, or why there is none.
    public struct BatchWrite: Sendable, Codable, Equatable {
        public let locale: String
        public let market: String?
        public let proposal: WrittenProposal?
        public let error: String?
        public let cost: String?
    }

    public struct WhatsNewWrite: Sendable, Codable, Equatable {
        public let locale: String
        public let text: String?
        public let error: String?
    }

    static let writerNotConnected =
        "OpenRouter is not connected. Add its key with: aso connections set openrouter (or in the window: Settings → Connections)."

    /// Three proposals for one locale from the market's evidence, best first. With `save`, the best becomes the draft.
    public func writeMetadata(appID: Int, locale: AppLocale, strategy: MetadataWriter.BrandStrategy = .featureFirst, brand: String? = nil,
                              notes: String = "", rewriteCopy: Bool = false, save: Bool = false, tiers: WriterTiers = .standard,
                              now: Date = Date()) async throws -> WriteResult {
        let model = try writerModel()
        let (context, market) = try await writerContext(appID: appID, locale: locale, brand: brand, tiers: tiers, liveDescription: true)
        let (proposals, cost) = try await MetadataWriter.propose(context, strategy: strategy, notes: notes, rewriteCopy: rewriteCopy, model: model)
        if save, let best = proposals.first {
            _ = try await saveDraft(appID: appID, locale: locale, fields: best.fields, tiers: tiers, now: now)
        }
        return WriteResult(locale: locale.rawValue, market: market, proposals: proposals.map(WrittenProposal.init), saved: save && !proposals.isEmpty,
                           cost: cost)
    }

    /// One improved version of the draft: the rule findings become instructions. Refused when it would score lower; with
    /// `save` (the default) it becomes the draft.
    public func improveMetadata(appID: Int, locale: AppLocale, brand: String? = nil, save: Bool = true, tiers: WriterTiers = .standard,
                                now: Date = Date()) async throws -> ImproveResult {
        let model = try writerModel()
        let (context, _) = try await writerContext(appID: appID, locale: locale, brand: brand, tiers: tiers, liveDescription: true)
        let before = ASORules.review(context.current, locale: locale, siblings: context.indexedSiblings, storefront: context.storefront).score
        let (proposal, cost) = try await MetadataWriter.improve(context, model: model)
        if save { _ = try await saveDraft(appID: appID, locale: locale, fields: proposal.fields, tiers: tiers, now: now) }
        return ImproveResult(locale: locale.rawValue, before: before, proposal: WrittenProposal(proposal), saved: save, cost: cost)
    }

    /// Writes each locale in turn (every locale worth writing when nil) and saves its best proposal as the draft. Locales
    /// that are a market's store language go first, so the others on the same storefront avoid their words; each sees the
    /// drafts saved before it.
    public func writeAllMetadata(appID: Int, locales: [AppLocale]? = nil, strategy: MetadataWriter.BrandStrategy = .featureFirst, brand: String? = nil,
                                 notes: String = "", tiers: WriterTiers = .standard, now: Date = Date(),
                                 progress: @Sendable (String) -> Void = { _ in }) async throws -> [BatchWrite] {
        let model = try writerModel()
        let state = try await metadataState(appID)
        let primary = Set(state.markets.compactMap { StorefrontRegistry.lookup($0)?.defaultLocale })
        let ordered = (locales ?? state.locales).sorted { a, b in
            if primary.contains(a) != primary.contains(b) { return primary.contains(a) }
            return a.rawValue < b.rawValue
        }
        let description = try await storeDescription(appID: appID, country: state.markets.first)
        var out: [BatchWrite] = []
        for locale in ordered {
            progress(locale.rawValue)
            do {
                let (context, market) = try await writerContext(appID: appID, locale: locale, brand: brand, tiers: tiers, description: description)
                let (proposals, cost) = try await MetadataWriter.propose(context, strategy: strategy, notes: notes, model: model)
                guard let best = proposals.first else {
                    out.append(BatchWrite(locale: locale.rawValue, market: market, proposal: nil, error: "No proposal", cost: cost))
                    continue
                }
                _ = try await saveDraft(appID: appID, locale: locale, fields: best.fields, tiers: tiers, now: now)
                out.append(BatchWrite(locale: locale.rawValue, market: market, proposal: WrittenProposal(best), error: nil, cost: cost))
            } catch {
                out.append(BatchWrite(locale: locale.rawValue, market: state.market(for: locale), proposal: nil, error: error.localizedDescription, cost: nil))
            }
        }
        return out
    }

    /// Release notes for other locales from one source text, saved into each draft's What's New (the source into its own
    /// locale first). Every locale worth writing except the source when `locales` is nil; locales of the source's language
    /// get the source itself.
    public func writeWhatsNew(appID: Int, source: String, sourceLocale: AppLocale, locales: [AppLocale]? = nil, tiers: WriterTiers = .standard,
                              now: Date = Date()) async throws -> [WhatsNewWrite] {
        let model = try writerModel()
        let text = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !text.isEmpty else { throw EngineError.invalidArgument("Give the release notes to translate.") }
        let app = try await app(appID)
        var state = try await metadataState(appID)
        var fields = state.draft(sourceLocale)
        fields.whatsNew = text
        _ = try await saveDraft(appID: appID, locale: sourceLocale, fields: fields, tiers: tiers, now: now)
        var out: [WhatsNewWrite] = []
        for locale in (locales ?? state.locales).filter({ $0 != sourceLocale }) {
            do {
                let (notes, _) = try await MetadataWriter.localizeWhatsNew(source: text, sourceLocale: sourceLocale, locale: locale, appName: app.name, model: model)
                state = try await metadataState(appID)
                var draft = state.draft(locale)
                draft.whatsNew = notes
                _ = try await saveDraft(appID: appID, locale: locale, fields: draft, tiers: tiers, now: now)
                out.append(WhatsNewWrite(locale: locale.rawValue, text: notes, error: nil))
            } catch {
                out.append(WhatsNewWrite(locale: locale.rawValue, text: nil, error: error.localizedDescription))
            }
        }
        return out
    }

    // MARK: Inputs

    private func writerModel() throws -> any TextModel {
        guard let writer else { throw EngineError.invalidArgument(Self.writerNotConnected) }
        return writer
    }

    /// The writer's inputs for one locale, read fresh so each locale of a batch sees the drafts saved before it.
    private func writerContext(appID: Int, locale: AppLocale, brand: String?, tiers: WriterTiers, liveDescription: Bool = false,
                               description known: String? = nil) async throws -> (MetadataWriter.Context, String?) {
        let app = try await app(appID)
        let state = try await metadataState(appID)
        let planned = try await keywordPlan(state, locale, tiers: tiers)
        var evidence: [MetadataWriter.Evidence] = []
        var rivals: [String] = []
        if let market = planned?.market {
            evidence = try await keywordReport(appID: appID, countryCode: market.countryCode, device: market.device).map { row in
                MetadataWriter.Evidence(term: row.keyword, popularity: row.popularity, popularitySource: row.popularitySource,
                                        below: row.popularityBelow, rank: row.observedCount.map { count in row.rank.map { "#\($0)" } ?? "not in top \(count)" },
                                        difficulty: row.difficulty.map { Int($0.rounded()) })
            }
            rivals = try await competitors(appID: appID, countryCode: market.countryCode, device: market.device, depth: 10).competitors
                .prefix(6).map { "\($0.name) (in \($0.keywords) tracked queries)" }
        }
        var description = known ?? ""
        if liveDescription { description = try await storeDescription(appID: appID, country: planned?.market.countryCode) }
        let siblings: [(AppLocale, MetadataFields)] = state.drafts.values.compactMap { d in
            guard let other = AppLocale.parse(d.locale), other != locale else { return nil }
            return (other, d.fields)
        }.sorted { $0.0.rawValue < $1.0.rawValue }
        let legal = state.legal.enabled
            ? MetadataWriter.LegalLinks(eulaURL: state.legal.effectiveEULA, privacyURL: state.legal.privacyURL, note: state.legal.note) : nil
        let context = MetadataWriter.Context(appName: app.name, sellerName: app.sellerName, category: app.primaryGenre,
                                             brand: brand ?? Self.brand(of: app.name), locale: locale, storefront: planned?.market.countryCode ?? "US",
                                             current: state.draft(locale), siblings: siblings, plan: planned?.plan ?? KeywordPlan(), evidence: evidence,
                                             competitors: rivals, description: description, legal: legal)
        return (context, planned?.market.countryCode)
    }

    /// What the app does, from its App Store description (empty when the lookup fails).
    private func storeDescription(appID: Int, country: String?) async throws -> String {
        let storefront = try Self.storefront(country ?? "US")
        return (try? await search.lookup(trackID: appID, storefront: storefront))?.storeDescription ?? ""
    }

    /// The name up to the first colon, as the macOS writer takes the brand: "Acme Notes: Daily Journal" → "Acme Notes".
    static func brand(of name: String) -> String {
        String(name.split(separator: ":", maxSplits: 1).first ?? Substring(name)).trimmingCharacters(in: .whitespaces)
    }
}
