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
    /// Returns nil (with `lastError`) when the model gives nothing usable.
    func improve(app: TrackedApp, market: TrackedMarket?, locale: AppLocale, current: MetadataFields, brandName: String, siblings: [(AppLocale, MetadataFields)]) async -> Proposal? {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        let storefrontCode = market?.countryCode ?? "US"
        let indexedHere = StorefrontIndexing.indexedLocales(countryCode: storefrontCode, fallbackPrimary: locale)
        let siblings = siblings.filter { indexedHere.contains($0.0) }
        let before = ASORules.review(current, locale: locale, siblings: siblings, storefront: storefrontCode)
        let plan = Self.plan(market: market, easyDifficulty: settings?.writerEasyDifficulty ?? 35, maxDifficulty: settings?.writerMaxDifficulty ?? 55)
        let findings = before.findings.filter { $0.kind != .good }.map { "- \($0.message)" }.joined(separator: "\n")
        let missing = plan.priority.filter { !KeywordPlan.covers(current, phrase: $0.term) }.map { "\($0.tier): \($0.term) (pop \($0.popularity.map(String.init) ?? "?"), diff \($0.difficulty.map(String.init) ?? "?"))" }.joined(separator: "\n")
        let siblingWordsText = siblings.isEmpty ? "(none)" : siblings.map { pair -> String in
            let words = ASORules.words(pair.1.name) + ASORules.words(pair.1.subtitle) + pair.1.keywordList
            return pair.0.rawValue + ": " + words.joined(separator: " ")
        }.joined(separator: " | ")
        let system = """
        You are an App Store Optimization specialist fixing one listing. Follow these house rules exactly:
        \(ASORules.summary)
        Output strict JSON only: {"title":"…","subtitle":"…","keywords":"w1,w2,…","rationale":"one sentence"}
        Keep what already works: change as little as needed to resolve every finding below, keep the brand "\(brandName)" verbatim in the title, keep the listing language (\(locale.displayName)).
        Title and subtitle: 26–30 characters each. Keywords: 14–18 single lower-case words, complete dictionary words, no word from title or subtitle, no plurals of used words, no "&" or filler.
        """
        let user = """
        App: \(app.name). Storefront: \(storefrontCode). Locale: \(locale.rawValue).
        Current listing: title="\(current.name)" subtitle="\(current.subtitle)" keywords="\(current.keywords)"
        Findings to resolve:
        \(findings.isEmpty ? "(none: just use the room and cover the missing phrases)" : findings)
        Priority phrases not covered yet (cover as many as fit, tier A first):
        \(missing.isEmpty ? "(all covered)" : missing)
        Words used by other locales indexed on this storefront (do not repeat): \(siblingWordsText)
        """
        do {
            let (text, usage) = try await llm.complete(model: model, system: system, user: user, temperature: 0.3, maxTokens: 800)
            if let u = usage { lastCost = u.cost.map { String(format: "$%.4f", $0) } ?? "\(u.inputTokens)+\(u.outputTokens) tokens" }
            guard let json = LLMClient.extractJSONObject(text), let title = json["title"] as? String else { lastError = "The model did not return the expected JSON."; return nil }
            var f = current
            f.name = title
            f.subtitle = json["subtitle"] as? String ?? current.subtitle
            f.keywords = json["keywords"] as? String ?? current.keywords
            var repairs: [String] = []
            for field in [MetadataField.name, .subtitle] where f[field].count > 30 {
                if let shorter = try? await shorten(f[field], limit: 30, field: field, brand: brandName), shorter.count <= 30 { f[field] = shorter; repairs.append("\(field.title) shortened.") }
            }
            for field in [MetadataField.name, .subtitle] where f[field].count < 24 {
                let missingTerms = plan.priority.map(\.term).filter { !KeywordPlan.covers(f, phrase: $0) }.prefix(4)
                if let longer = try? await extend(f[field], field: field, brand: brandName, locale: locale, candidates: Array(missingTerms)), longer.count <= 30, longer.count > f[field].count {
                    repairs.append("\(field.title) extended from \(f[field].count) to \(longer.count) characters.")
                    f[field] = longer
                }
            }
            let evidenceWords = plan.priority.flatMap { ASORules.words($0.term) }
            var repaired = ASORules.repair(f, topUpWith: evidenceWords)
            f = repaired.fields
            repairs += repaired.notes
            if f.keywords.count < 88 {
                let used = Set(ASORules.words(f.name) + ASORules.words(f.subtitle) + ASORules.words(f.keywords))
                let description = app.storeDescription ?? ""
                if let extra = try? await moreKeywords(app: app, locale: locale, description: description, used: Array(used).sorted(), needed: 10), !extra.isEmpty {
                    f.keywords = (f.keywords.split(separator: ",").map(String.init) + extra).joined(separator: ",")
                    repaired = ASORules.repair(f, topUpWith: evidenceWords)
                    f = repaired.fields
                    repairs.append("Keyword field topped up with \(extra.count) extra search word(s).")
                }
            }
            let review = ASORules.review(f, locale: locale, siblings: siblings, storefront: storefrontCode)
            // Never hand back something worse: rule score plus tier-weighted coverage must not drop.
            func quality(_ fields: MetadataFields, _ r: ASORules.Report) -> Int {
                r.score + plan.priority.reduce(0) { acc, it in acc + (KeywordPlan.covers(fields, phrase: it.term) ? (it.tier == "A" ? 3 : it.tier == "B" ? 2 : 1) : 0) }
            }
            if quality(f, review) < quality(current, before) {
                lastError = "The model's version scored lower than your draft (rule \(review.score) vs \(before.score), coverage counted); kept your draft. Try again or pick a stronger writer model in Settings."
                AppLog.write("[assistant] improve \(locale.rawValue): rejected, quality \(quality(f, review)) < \(quality(current, before))")
                return nil
            }
            f = ASORules.plainPunctuation(f)
            var p = Proposal(label: "Improved", fields: f, rationale: (json["rationale"] as? String ?? "") + " Rule score \(before.score) → \(review.score).", review: review, issues: MetadataValidator.validate(f), repairs: repairs)
            p.coveredPhrases = plan.priority.map(\.term).filter { KeywordPlan.covers(f, phrase: $0) }
            p.missedPhrases = plan.priority.map(\.term).filter { !KeywordPlan.covers(f, phrase: $0) }
            AppLog.write("[assistant] improve \(locale.rawValue): score \(before.score) → \(review.score), covers \(p.coveredPhrases.count)/\(plan.priority.count), \(lastCost ?? "")")
            return p
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// One locale's release notes from a source text (same facts, native phrasing). The source language returns the source itself.
    func localizeWhatsNew(source: String, sourceLocale: AppLocale, locale: AppLocale, app: TrackedApp) async throws -> String {
        let trimmed = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        if locale == sourceLocale || LegalFooterLanguage.same(locale, sourceLocale) { return trimmed }
        let (text, usage) = try await llm.complete(model: model,
            system: "You localize App Store release notes (\"What's New\"). Output only the localized notes, nothing else: same facts and order, natural phrasing a native speaker would write, keep the line structure (one item per line, list lines start with a bullet •), never use em or en dashes as punctuation, plain text, at most 4000 characters. Do not add features that are not in the source.",
            user: "App: \(app.name). Source language: \(sourceLocale.displayName). Target: \(locale.displayName) (\(locale.rawValue)).\n\nRelease notes:\n\(trimmed)",
            temperature: 0.2, maxTokens: 1200)
        if let u = usage { lastCost = u.cost.map { String(format: "$%.4f", $0) } ?? "\(u.inputTokens)+\(u.outputTokens) tokens" }
        return String(ASORules.plainPunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(4000))
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

    /// Builds the context the model needs: app facts, keyword evidence, competitors, existing locales.
    func propose(app: TrackedApp, market: TrackedMarket?, locale: AppLocale, strategy: BrandStrategy, brandName: String,
                 siblings: [(AppLocale, MetadataFields)], current: MetadataFields, notes: String, rewriteCopy: Bool = false) async -> [Proposal] {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        // Promotional text and description are conversion copy, not index fields: written when empty or when asked.
        let writePromo = rewriteCopy || current.promotionalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let writeDescription = rewriteCopy || current.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var description = ""
        if let sf = market?.storefront ?? StorefrontRegistry.lookup("US"), let fresh = try? await search.lookup(trackID: app.trackID, storefront: sf) {
            description = String((fresh.storeDescription ?? "").prefix(1500))
        }
        let keywordRows: [[String: Any]] = (market?.sortedKeywords ?? []).map { k in
            var row: [String: Any] = ["term": k.text]
            if let p = k.latestPopularity {
                if let v = p.popularity1to100 { row["popularity"] = v; row["popularity_source"] = p.scope }
                else if p.scope == "bound" || p.scope == "estimate" { row["popularity"] = "below \(p.upperBound ?? 40)" }
            }
            if let m = k.latestMeasured {
                row["rank"] = m.position.map { "#\($0)" } ?? "not in top \(m.observedCount)"
                if let d = m.signals?.difficulty { row["difficulty"] = d.rounded }
            }
            return row
        }
        let samples = (market?.sortedKeywords ?? []).compactMap { $0.latestMeasured?.asSample(keyword: $0.text, storefront: market?.countryCode ?? "US") }
        let competitors = CompetitorAggregation.aggregate(samples: samples, ownTrackID: app.trackID, depth: 10).prefix(6).map { "\($0.app.name) (in \($0.appearanceCount) tracked queries)" }

        let plan = Self.plan(market: market, easyDifficulty: settings?.writerEasyDifficulty ?? 35, maxDifficulty: settings?.writerMaxDifficulty ?? 55)
        func line(_ it: KeywordPlan.Item) -> String {
            "- \(it.term) (popularity \(it.popularity.map(String.init) ?? "?"), difficulty \(it.difficulty.map(String.init) ?? "?"), rank \(it.rank ?? "unmeasured")\(KeywordPlan.covers(current, phrase: it.term) ? ", already covered" : ""))"
        }
        var priorityText = ""
        if !plan.tierA.isEmpty { priorityText += "TIER A: winnable now (cover ALL of these; they come first in the keyword field and, where natural, in title or subtitle):\n" + plan.tierA.map(line).joined(separator: "\n") + "\n" }
        if !plan.tierB.isEmpty { priorityText += "TIER B: reachable (cover after tier A, as many as fit):\n" + plan.tierB.map(line).joined(separator: "\n") + "\n" }
        if !plan.tierC.isEmpty { priorityText += "TIER C: popular but hard (only if room remains after A and B):\n" + plan.tierC.map(line).joined(separator: "\n") + "\n" }
        let avoidText = plan.avoid.map { "\($0.term)" }.joined(separator: ", ")
        // Only locales indexed on this storefront compete with this one; other drafts are irrelevant to word choice here.
        let storefrontCode = market?.countryCode ?? "US"
        let indexedHere = StorefrontIndexing.indexedLocales(countryCode: storefrontCode, fallbackPrimary: locale)
        let siblings = siblings.filter { indexedHere.contains($0.0) }
        let siblingsText = siblings.map { "\($0.0.rawValue): title=\"\($0.1.name)\" subtitle=\"\($0.1.subtitle)\" keywords=\"\($0.1.keywords)\"" }.joined(separator: "\n")
        let system = """
        You are an App Store Optimization specialist. Follow these house rules exactly; they are non-negotiable:
        \(ASORules.summary)
        Output strict JSON only, no prose, with this shape:
        {"proposals":[{"label":"A","title":"…","subtitle":"…","keywords":"w1,w2,…","rationale":"…"\(writePromo ? ",\"promotional_text\":\"…\"" : "")}, …]\(writeDescription ? ",\"description\":\"…\"" : "")}
        \(writePromo ? "promotional_text: at most 170 characters, one or two sentences of conversion copy in the locale language (what the user gets), no keyword stuffing, no emoji; it is not indexed." : "")
        \(writeDescription ? "description: 700–1500 characters in the locale language, shared by all proposals: an opening line on what the app does for the user, a short list of the key features from the app description (one per line, each starting with a bullet •), a closing line; plain text, no markdown headings, no claims the app description does not support. It is not indexed by App Store search, write it for conversion." : "")
        Give exactly 3 proposals with different emphasis (search-volume first, differentiation first, balanced).
        Hard limits you must count: title at most 30 characters, subtitle at most 30 characters, keywords at most 14 single words (code packs them to 100 characters, so quality matters more than count).
        Use the room: aim for 26–30 characters in the title and 26–30 in the subtitle; every unused character is a lost ranking chance. Add a real search word rather than leaving space.
        The keyword field must come out at 90–100 characters after packing: give 14–18 single search words (the priority phrases' words first, then other words people type for this kind of app, drawn from the app description and category), the code packs them and drops what does not fit.
        Never use the em dash (—) or en dash (–) as punctuation in any field; use a comma, colon or period instead. List lines start with "• ".
        Never use "&", "and", "to", "your", "with", "for", "the", "a" or any other filler in any field. Never repeat a word across the three fields, and never write both a word and its plural. Keywords are lower-case single words with no spaces.
        The brand string must appear verbatim in the title.
        Every keyword must be a complete, correctly spelled dictionary word or proper name, never abbreviate or truncate a word to save characters (write "calendar", not "calend"); drop a word instead.
        Prefer words with evidence: the keyword table gives Apple popularity (1–100, higher is more searched; "below N" means Apple publishes nothing for it) and difficulty (0–100, lower is easier). Keep only words the app genuinely delivers.
        Write the listing in the language of the target locale. For a secondary locale (e.g. es-MX shown in the US storefront) write English words that do not overlap with the sibling listings.
        """
        let user = """
        App: \(app.name) by \(app.sellerName). Category: \(app.primaryGenre ?? "unknown"). Brand to use: "\(brandName)".
        Target locale: \(locale.rawValue) (\(locale.displayName)). Storefront: \(market?.countryCode ?? "US").
        Brand strategy: \(strategy == .brandFirst ? "brand first, then feature words" : "feature words first, brand at the end or omitted").
        Current listing for this locale: title="\(current.name)" subtitle="\(current.subtitle)" keywords="\(current.keywords)".
        Other locales indexed on the same storefront (do not repeat their words):
        \(siblingsText.isEmpty ? "(none)" : siblingsText)
        PRIORITY PHRASES by tier (measured in this storefront). A phrase counts as covered when every one of its words appears somewhere across title, subtitle and keywords (word order does not matter; Apple combines fields). Tier A before B before C; inside a tier, higher popularity first:
        \(priorityText.isEmpty ? "(no tracked keywords with evidence yet)" : priorityText)
        AVOID these tracked terms: other brands or navigational names, unrelated to what this app does, or too hard to win; do not use their distinctive words: \(avoidText.isEmpty ? "(none)" : avoidText)
        Full keyword evidence (JSON): \((try? String(decoding: JSONSerialization.data(withJSONObject: keywordRows, options: []), as: UTF8.self)) ?? "[]")
        Competitors seen in tracked queries: \(competitors.isEmpty ? "(none measured yet)" : competitors.joined(separator: "; "))
        App description (for what the app really does): \(description.isEmpty ? "(unavailable)" : description)
        Extra notes from the ASO manager: \(notes.isEmpty ? "(none)" : notes)
        """
        do {
            let (text, usage) = try await llm.complete(model: model, system: system, user: user)
            if let u = usage { lastCost = u.cost.map { String(format: "$%.4f", $0) } ?? "\(u.inputTokens)+\(u.outputTokens) tokens" }
            guard let json = LLMClient.extractJSONObject(text), let items = json["proposals"] as? [[String: Any]] else {
                lastError = "The model did not return the expected JSON."
                return []
            }
            let sharedDescription = (json["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Evidence-ranked single words used to top up the keyword field: best tracked keywords first.
            // Only keywords Apple publishes a value for (≥ published floor) qualify; low-signal terms would pad the field with noise.
            // Top-up words follow the plan: tier A phrases first, then B, then C, so missed priority phrases get packed in when room remains.
            let evidenceWords: [String] = plan.priority.flatMap { ASORules.words($0.term) }
            var proposals: [Proposal] = []
            for item in items {
                guard let title = item["title"] as? String else { continue }
                var f = MetadataFields(name: title, subtitle: item["subtitle"] as? String ?? "", keywords: item["keywords"] as? String ?? "")
                f.promotionalText = current.promotionalText
                f.description = current.description
                if writePromo, let promo = item["promotional_text"] as? String, !promo.isEmpty { f.promotionalText = String(promo.trimmingCharacters(in: .whitespacesAndNewlines).prefix(170)) }
                if writeDescription, !sharedDescription.isEmpty { f.description = String(sharedDescription.prefix(4000)) }
                if app.hasLegalFooter { f.description = LegalFooter.apply(to: f.description, locale: locale, eulaURL: app.effectiveEULA, privacyURL: app.privacyURL, note: app.legalNote) }
                var repairs: [String] = []
                // Title/subtitle over the limit: one small rewrite call per field.
                for field in [MetadataField.name, .subtitle] where f[field].count > 30 {
                    if let shorter = try? await shorten(f[field], limit: 30, field: field, brand: brandName), shorter.count <= 30 {
                        repairs.append("\(field.title) shortened from \(f[field].count) to \(shorter.count) characters.")
                        f[field] = shorter
                    }
                }
                // Short title/subtitle: one cheap extension call per field with the still-missing priority words.
                for field in [MetadataField.name, .subtitle] where f[field].count < 24 {
                    let missing = plan.priority.map(\.term).filter { !KeywordPlan.covers(f, phrase: $0) }.prefix(4)
                    if let longer = try? await extend(f[field], field: field, brand: brandName, locale: locale, candidates: Array(missing)), longer.count <= 30, longer.count > f[field].count {
                        repairs.append("\(field.title) extended from \(f[field].count) to \(longer.count) characters.")
                        f[field] = longer
                    }
                }
                var repaired = ASORules.repair(f, topUpWith: evidenceWords)
                f = repaired.fields
                repairs += repaired.notes
                if f.keywords.count < 88 {
                    let used = Set(ASORules.words(f.name) + ASORules.words(f.subtitle) + ASORules.words(f.keywords))
                    if let extra = try? await moreKeywords(app: app, locale: locale, description: description, used: Array(used).sorted(), needed: 10), !extra.isEmpty {
                        f.keywords = (f.keywords.split(separator: ",").map(String.init) + extra).joined(separator: ",")
                        repaired = ASORules.repair(f, topUpWith: evidenceWords)
                        f = repaired.fields
                        repairs.append("Keyword field topped up with \(extra.count) extra search word(s) from the app's domain (evidence was thin).")
                    }
                }
                let review = ASORules.review(f, locale: locale, siblings: siblings, storefront: storefrontCode)
                var proposal = Proposal(label: item["label"] as? String ?? "?", fields: f, rationale: item["rationale"] as? String ?? "", review: review, issues: MetadataValidator.validate(f), repairs: repairs)
                proposal.coveredPhrases = plan.priority.map(\.term).filter { KeywordPlan.covers(f, phrase: $0) }
                proposal.missedPhrases = plan.priority.map(\.term).filter { !KeywordPlan.covers(f, phrase: $0) }
                proposal.fields = ASORules.plainPunctuation(proposal.fields)
                proposals.append(proposal)
            }
            // Rule score, then coverage weighted by tier: a covered tier-A phrase is worth three tier-C ones.
            func weight(_ p: Proposal) -> Int {
                p.coveredPhrases.reduce(0) { acc, t in acc + (plan.tierA.contains { $0.term == t } ? 3 : plan.tierB.contains { $0.term == t } ? 2 : 1) }
            }
            return proposals.sorted { ($0.review.score + weight($0)) > ($1.review.score + weight($1)) }
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// Asks for a shorter version of one field (cheap, ~200 tokens).
    /// Extra single search words for the keyword field when tracked evidence cannot fill it (cheap, ~200 tokens).
    private func moreKeywords(app: TrackedApp, locale: AppLocale, description: String, used: [String], needed: Int) async throws -> [String] {
        let (out, _) = try await llm.complete(model: model,
            system: "You suggest App Store keyword-field words. Output only a comma-separated list of lower-case single words, nothing else. No brand names of other companies, no filler words, no plurals of words already used, no word already used.",
            user: "App: \(app.name). Category: \(app.primaryGenre ?? "unknown"). Locale: \(locale.rawValue): write in that language. What the app does: \(String(description.prefix(700))). Already used words: \(used.joined(separator: ", ")). Give \(needed) more words people type when looking for this kind of app, most searched first.",
            temperature: 0.3, maxTokens: 120)
        return out.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.contains(" ") && !used.contains($0) }
    }

    /// Asks for a longer version of a short field that adds one or two of the given search words (cheap, ~200 tokens).
    private func extend(_ text: String, field: MetadataField, brand: String, locale: AppLocale, candidates: [String]) async throws -> String {
        let (out, _) = try await llm.complete(model: model,
            system: "Rewrite App Store listing text to use 26–30 characters. Output only the rewritten text, nothing else. Keep every existing word, add one or two of the candidate search words that fit naturally, in the locale language. No \"&\", no filler words (and, to, your, with, for, the, a).",
            user: "Field: \(field.title). Locale: \(locale.rawValue). \(field == .name ? "Keep the brand \"\(brand)\" verbatim. " : "")Candidate words: \(candidates.isEmpty ? "(none: extend with a relevant search word)" : candidates.joined(separator: ", ")). Text: \(text)",
            temperature: 0.2, maxTokens: 60)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }

    private func shorten(_ text: String, limit: Int, field: MetadataField, brand: String) async throws -> String {
        let (out, _) = try await llm.complete(model: model,
            system: "Rewrite App Store listing text to fit a character limit. Output only the rewritten text, nothing else. No \"&\", no filler words.",
            user: "Field: \(field.title). Limit: \(limit) characters. \(field == .name ? "Keep the brand \"\(brand)\" verbatim. " : "")Text: \(text)",
            temperature: 0.2, maxTokens: 60)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }
}

/// en-US and en-GB share release notes; so do es-ES/es-MX, pt-BR/pt-PT, fr-FR/fr-CA, Apple treats them as exchangeable.
enum LegalFooterLanguage {
    static func same(_ a: AppLocale, _ b: AppLocale) -> Bool {
        func lang(_ l: AppLocale) -> String { l.rawValue.hasPrefix("zh-") ? l.rawValue : String(l.rawValue.split(separator: "-").first ?? "") }
        return lang(a) == lang(b)
    }
}
