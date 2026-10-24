import Foundation
import Observation
import SwiftData
import ASOCore
import ASOProviders

/// Writes listing proposals with Claude (via OpenRouter) from the app's real data and the house rules,
/// then scores every proposal with the rule engine. Nothing is written to Apple from here.
@Observable
final class ASOAssistant {
    struct Proposal: Identifiable, Hashable {
        let id = UUID()
        var label: String
        var fields: MetadataFields
        var rationale: String
        var review: ASORules.Report
        var issues: [ValidationIssue]
        var repairs: [String] = []
        /// Priority phrases (from the keyword plan) this proposal covers, and the ones it misses.
        var coveredPhrases: [String] = []
        var missedPhrases: [String] = []
    }

    /// The evidence-ranked plan the writer must follow: which tracked phrases to cover, which to avoid.
    typealias KeywordPlan = ASOCore.KeywordPlan

    /// The market's tracked keywords ranked by `KeywordPlan.make`, with the model's estimate under Apple's published floor.
    static func plan(market: TrackedMarket?, easyDifficulty: Int = 35, maxDifficulty: Int = 55) -> KeywordPlan {
        let inputs = (market?.sortedKeywords ?? []).map { k in
            let p = k.latestPopularity
            return KeywordPlan.Input(term: k.text, popularity: p?.popularity1to100, estimate: p?.subFloorEstimate, popularitySource: p?.scope ?? "none",
                                     difficulty: k.difficultyScore?.score, fit: k.fitProbability, brandLike: k.isBrandLike,
                                     observedCount: k.latestMeasured?.observedCount, rank: k.latestMeasured?.position)
        }
        return KeywordPlan.make(inputs, easyDifficulty: easyDifficulty, maxDifficulty: maxDifficulty, publishedFloor: ModelTrainer.publishedThreshold)
    }

    enum BrandStrategy: String, CaseIterable, Identifiable {
        case featureFirst, brandFirst
        var id: String { rawValue }
        var title: String { self == .brandFirst ? "Brand + feature (demand comes from the brand)" : "Feature + brand (demand comes from search)" }
    }

    private let llm: LLMClient
    private let search: ITunesSearchProvider
    private(set) var isBusy = false
    private(set) var lastError: String?
    private(set) var lastCost: String?
    /// "3/7 · de-DE" while `writeAll` runs.
    private(set) var batchProgress: String?
    /// Writer tier thresholds; nil falls back to 35/55.
    var settings: AppSettings?
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "assistantModel") }
    }

    init(llm: LLMClient, search: ITunesSearchProvider) {
        self.llm = llm
        self.search = search
        model = LLMClient.configuredModel
    }

    var isConfigured: Bool { get async { await llm.isConfigured } }

    struct BatchResult: Identifiable {
        let id = UUID()
        let locale: AppLocale
        let market: String
        let score: Int
        let covered: Int
        let total: Int
        let title: String
        let subtitle: String
        let keywords: String
        let error: String?
    }

    /// Writes each locale in turn and saves its best proposal as the draft. Primary locales go first so secondary
    /// locales on the same storefront can avoid their words; each call sees every draft saved before it.
    func writeAll(app: TrackedApp, locales: [AppLocale], marketFor: (AppLocale) -> TrackedMarket?, strategy: BrandStrategy, brandName: String, notes: String,
                  metadata: MetadataService, context: ModelContext, rewriteCopy: Bool = false) async -> [BatchResult] {
        let ordered = locales.sorted { a, b in
            let pa = marketFor(a)?.storefront?.defaultLocale == a, pb = marketFor(b)?.storefront?.defaultLocale == b
            if pa != pb { return pa }
            return a.rawValue < b.rawValue
        }
        var out: [BatchResult] = []
        for (i, locale) in ordered.enumerated() {
            batchProgress = "\(i + 1)/\(ordered.count) · \(locale.rawValue)"
            let market = marketFor(locale)
            let current = metadata.draftFields(for: app, locale: locale)
            let siblings: [(AppLocale, MetadataFields)] = app.drafts.compactMap { d in d.locale.flatMap { $0 == locale ? nil : ($0, d.fields) } }
            let proposals = await propose(app: app, market: market, locale: locale, strategy: strategy, brandName: brandName, siblings: siblings, current: current, notes: notes, rewriteCopy: rewriteCopy)
            if let best = proposals.first {
                let fields = best.fields
                metadata.saveDraft(fields, for: app, locale: locale, context: context)
                out.append(BatchResult(locale: locale, market: market?.countryCode ?? "—", score: best.review.score, covered: best.coveredPhrases.count,
                                       total: best.coveredPhrases.count + best.missedPhrases.count, title: fields.name, subtitle: fields.subtitle, keywords: fields.keywords, error: nil))
            } else {
                out.append(BatchResult(locale: locale, market: market?.countryCode ?? "—", score: 0, covered: 0, total: 0, title: "", subtitle: "", keywords: "", error: lastError ?? "No proposal"))
            }
        }
        batchProgress = nil
        AppLog.write("[assistant] wrote \(out.count) locale(s): " + out.map { "\($0.locale.rawValue)=\($0.error == nil ? "\($0.score)" : "error")" }.joined(separator: " "))
        return out
    }

    /// One improved version of the current draft: the rule findings become instructions, the plan stays the priority.
    /// Returns nil (with `lastError`) when the model gives nothing usable or nothing better.
    func improve(app: TrackedApp, market: TrackedMarket?, locale: AppLocale, current: MetadataFields, brandName: String, siblings: [(AppLocale, MetadataFields)]) async -> Proposal? {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        let context = writerContext(app: app, market: market, locale: locale, brandName: brandName, siblings: siblings, current: current,
                                    description: app.storeDescription ?? "")
        do {
            let (improved, cost) = try await MetadataWriter.improve(context, model: textModel)
            if let cost { lastCost = cost }
            let p = Proposal(improved)
            AppLog.write("[assistant] improve \(locale.rawValue): score \(p.review.score), covers \(p.coveredPhrases.count)/\(context.plan.priority.count), \(lastCost ?? "")")
            return p
        } catch {
            lastError = error.localizedDescription
            AppLog.write("[assistant] improve \(locale.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    /// One locale's release notes from a source text (same facts, native phrasing). The source language returns the source itself.
    func localizeWhatsNew(source: String, sourceLocale: AppLocale, locale: AppLocale, app: TrackedApp) async throws -> String {
        let (text, cost) = try await MetadataWriter.localizeWhatsNew(source: source, sourceLocale: sourceLocale, locale: locale, appName: app.name, model: textModel)
        if let cost { lastCost = cost }
        return text
    }

    /// Release notes for other locales from one source text: natural, same content, saved into each draft's What's New.
    func writeWhatsNew(app: TrackedApp, source: String, sourceLocale: AppLocale, locales: [AppLocale], metadata: MetadataService, context: ModelContext) async -> [(AppLocale, String)] {
        isBusy = true
        defer { isBusy = false; batchProgress = nil }
        var out: [(AppLocale, String)] = []
        var src = metadata.draftFields(for: app, locale: sourceLocale)
        src.whatsNew = String(source.prefix(4000))
        metadata.saveDraft(src, for: app, locale: sourceLocale, context: context)
        for (i, locale) in locales.enumerated() {
            batchProgress = "\(i + 1)/\(locales.count) · \(locale.rawValue)"
            do {
                let notes = try await localizeWhatsNew(source: source, sourceLocale: sourceLocale, locale: locale, app: app)
                var f = metadata.draftFields(for: app, locale: locale)
                f.whatsNew = notes
                metadata.saveDraft(f, for: app, locale: locale, context: context)
                out.append((locale, notes))
            } catch {
                out.append((locale, "Failed: \(error.localizedDescription)"))
            }
        }
        AppLog.write("[assistant] what's new written for \(out.count) locale(s)")
        return out
    }

    /// Builds the context the model needs (app facts, keyword evidence, competitors, existing locales) and asks for three proposals.
    func propose(app: TrackedApp, market: TrackedMarket?, locale: AppLocale, strategy: BrandStrategy, brandName: String,
                 siblings: [(AppLocale, MetadataFields)], current: MetadataFields, notes: String, rewriteCopy: Bool = false) async -> [Proposal] {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        var description = ""
        if let sf = market?.storefront ?? StorefrontRegistry.lookup("US"), let fresh = try? await search.lookup(trackID: app.trackID, storefront: sf) {
            description = fresh.storeDescription ?? ""
        }
        let context = writerContext(app: app, market: market, locale: locale, brandName: brandName, siblings: siblings, current: current, description: description)
        do {
            let (proposals, cost) = try await MetadataWriter.propose(context, strategy: MetadataWriter.BrandStrategy(rawValue: strategy.rawValue) ?? .featureFirst,
                                                                    notes: notes, rewriteCopy: rewriteCopy, model: textModel)
            if let cost { lastCost = cost }
            return proposals.map(Proposal.init)
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    private var textModel: OpenRouterTextModel { OpenRouterTextModel(client: llm, model: model) }

    /// The writer's inputs from the app's records: the market's plan and keyword evidence, competitors in its tracked
    /// queries, the legal footer.
    private func writerContext(app: TrackedApp, market: TrackedMarket?, locale: AppLocale, brandName: String, siblings: [(AppLocale, MetadataFields)],
                               current: MetadataFields, description: String) -> MetadataWriter.Context {
        let keywords = market?.sortedKeywords ?? []
        let evidence = keywords.map { k in
            let p = k.latestPopularity
            let bounded = p?.popularity1to100 == nil && (p?.scope == "bound" || p?.scope == "estimate")
            return MetadataWriter.Evidence(term: k.text, popularity: p?.popularity1to100, popularitySource: p?.scope, below: bounded ? (p?.upperBound ?? 40) : nil,
                                           rank: k.latestMeasured.map { m in m.position.map { "#\($0)" } ?? "not in top \(m.observedCount)" },
                                           difficulty: k.latestMeasured?.signals?.difficulty?.rounded)
        }
        let samples = keywords.compactMap { $0.latestMeasured?.asSample(keyword: $0.text, storefront: market?.countryCode ?? "US") }
        let competitors = CompetitorAggregation.aggregate(samples: samples, ownTrackID: app.trackID, depth: 10).prefix(6).map { "\($0.app.name) (in \($0.appearanceCount) tracked queries)" }
        let legal = app.hasLegalFooter ? MetadataWriter.LegalLinks(eulaURL: app.effectiveEULA, privacyURL: app.privacyURL, note: app.legalNote) : nil
        return MetadataWriter.Context(appName: app.name, sellerName: app.sellerName, category: app.primaryGenre, brand: brandName, locale: locale,
                                      storefront: market?.countryCode ?? "US", current: current, siblings: siblings,
                                      plan: Self.plan(market: market, easyDifficulty: settings?.writerEasyDifficulty ?? 35, maxDifficulty: settings?.writerMaxDifficulty ?? 55),
                                      evidence: evidence, competitors: Array(competitors), description: description, legal: legal)
    }
}

extension ASOAssistant.Proposal {
    init(_ written: MetadataWriter.Proposal) {
        self.init(label: written.label, fields: written.fields, rationale: written.rationale, review: written.review, issues: written.issues,
                  repairs: written.repairs, coveredPhrases: written.coveredPhrases, missedPhrases: written.missedPhrases)
    }
}
