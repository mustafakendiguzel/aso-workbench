import Foundation

/// The AI metadata writer: three proposals from the app's evidence and the house rules, a "make better" pass over a
/// draft, and release notes in other languages. Every proposal is repaired and scored by the rule engine; the model only
/// drafts. Shared by the macOS app and the engine, which gather the inputs.
public enum MetadataWriter {
    public enum BrandStrategy: String, Sendable, CaseIterable, Codable {
        case featureFirst, brandFirst
    }

    /// One tracked keyword as the model sees it.
    public struct Evidence: Sendable, Equatable {
        public let term: String
        public let popularity: Int?
        public let popularitySource: String?
        /// Apple publishes nothing for the term; it is below this score.
        public let below: Int?
        public let rank: String?
        public let difficulty: Int?

        public init(term: String, popularity: Int?, popularitySource: String?, below: Int?, rank: String?, difficulty: Int?) {
            self.term = term
            self.popularity = popularity
            self.popularitySource = popularitySource
            self.below = below
            self.rank = rank
            self.difficulty = difficulty
        }
    }

    /// The legal footer appended to every written description.
    public struct LegalLinks: Sendable, Equatable {
        public let eulaURL: String
        public let privacyURL: String
        public let note: String

        public init(eulaURL: String, privacyURL: String, note: String) {
            self.eulaURL = eulaURL
            self.privacyURL = privacyURL
            self.note = note
        }
    }

    /// Everything one locale's writing needs.
    public struct Context: Sendable {
        public let appName: String
        public let sellerName: String
        public let category: String?
        public let brand: String
        public let locale: AppLocale
        /// The tracked market whose store speaks the locale ("US" without one).
        public let storefront: String
        public let current: MetadataFields
        /// The app's other drafts; only those indexed on the same storefront are used.
        public let siblings: [(AppLocale, MetadataFields)]
        public let plan: KeywordPlan
        public let evidence: [Evidence]
        public let competitors: [String]
        /// What the app does, from its store description.
        public let description: String
        public let legal: LegalLinks?

        public init(appName: String, sellerName: String, category: String?, brand: String, locale: AppLocale, storefront: String,
                    current: MetadataFields, siblings: [(AppLocale, MetadataFields)], plan: KeywordPlan, evidence: [Evidence],
                    competitors: [String], description: String, legal: LegalLinks?) {
            self.appName = appName
            self.sellerName = sellerName
            self.category = category
            self.brand = brand
            self.locale = locale
            self.storefront = storefront
            self.current = current
            self.siblings = siblings
            self.plan = plan
            self.evidence = evidence
            self.competitors = competitors
            self.description = description
            self.legal = legal
        }

        /// Siblings indexed on this storefront: only they compete with this locale for words.
        public var indexedSiblings: [(AppLocale, MetadataFields)] {
            let indexedHere = StorefrontIndexing.indexedLocales(countryCode: storefront, fallbackPrimary: locale)
            return siblings.filter { indexedHere.contains($0.0) }
        }
    }

    public struct Proposal: Sendable, Hashable {
        public var label: String
        public var fields: MetadataFields
        public var rationale: String
        public var review: ASORules.Report
        public var issues: [ValidationIssue]
        public var repairs: [String]
        /// Priority phrases (from the keyword plan) this proposal covers, and the ones it misses.
        public var coveredPhrases: [String]
        public var missedPhrases: [String]
    }

    public enum WriterError: Error, LocalizedError, Equatable {
        case unexpectedOutput
        /// The improved version scored lower than the draft; the draft is kept.
        case notBetter(String)

        public var errorDescription: String? {
            switch self {
            case .unexpectedOutput: "The model did not return the expected JSON."
            case .notBetter(let detail): detail
            }
        }
    }

    /// Three proposals, best first (rule score plus coverage weighted by tier), and the cost of the main call.
    /// Promotional text and description are conversion copy, not index fields: written when empty or when asked.
    public static func propose(_ context: Context, strategy: BrandStrategy, notes: String, rewriteCopy: Bool = false,
                               model: any TextModel) async throws -> (proposals: [Proposal], cost: String?) {
        let current = context.current
        let locale = context.locale
        let plan = context.plan
        let writePromo = rewriteCopy || current.promotionalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let writeDescription = rewriteCopy || current.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let description = String(context.description.prefix(1500))
        func line(_ it: KeywordPlan.Item) -> String {
            "- \(it.term) (popularity \(it.popularity.map(String.init) ?? "?"), difficulty \(it.difficulty.map(String.init) ?? "?"), rank \(it.rank ?? "unmeasured")\(KeywordPlan.covers(current, phrase: it.term) ? ", already covered" : ""))"
        }
        var priorityText = ""
        if !plan.tierA.isEmpty { priorityText += "TIER A: winnable now (cover ALL of these; they come first in the keyword field and, where natural, in title or subtitle):\n" + plan.tierA.map(line).joined(separator: "\n") + "\n" }
        if !plan.tierB.isEmpty { priorityText += "TIER B: reachable (cover after tier A, as many as fit):\n" + plan.tierB.map(line).joined(separator: "\n") + "\n" }
        if !plan.tierC.isEmpty { priorityText += "TIER C: popular but hard (only if room remains after A and B):\n" + plan.tierC.map(line).joined(separator: "\n") + "\n" }
        let avoidText = plan.avoid.map { "\($0.term)" }.joined(separator: ", ")
        let siblings = context.indexedSiblings
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
        App: \(context.appName) by \(context.sellerName). Category: \(context.category ?? "unknown"). Brand to use: "\(context.brand)".
        Target locale: \(locale.rawValue) (\(locale.displayName)). Storefront: \(context.storefront).
        Brand strategy: \(strategy == .brandFirst ? "brand first, then feature words" : "feature words first, brand at the end or omitted").
        Current listing for this locale: title="\(current.name)" subtitle="\(current.subtitle)" keywords="\(current.keywords)".
        Other locales indexed on the same storefront (do not repeat their words):
        \(siblingsText.isEmpty ? "(none)" : siblingsText)
        PRIORITY PHRASES by tier (measured in this storefront). A phrase counts as covered when every one of its words appears somewhere across title, subtitle and keywords (word order does not matter; Apple combines fields). Tier A before B before C; inside a tier, higher popularity first:
        \(priorityText.isEmpty ? "(no tracked keywords with evidence yet)" : priorityText)
        AVOID these tracked terms: other brands or navigational names, unrelated to what this app does, or too hard to win; do not use their distinctive words: \(avoidText.isEmpty ? "(none)" : avoidText)
        Full keyword evidence (JSON): \(evidenceJSON(context.evidence))
        Competitors seen in tracked queries: \(context.competitors.isEmpty ? "(none measured yet)" : context.competitors.joined(separator: "; "))
        App description (for what the app really does): \(description.isEmpty ? "(unavailable)" : description)
        Extra notes from the ASO manager: \(notes.isEmpty ? "(none)" : notes)
        """
        let answer = try await model.complete(system: system, user: user, temperature: 0.4, maxTokens: 6000)
        guard let json = answer.jsonObject, let items = json["proposals"] as? [[String: Any]] else { throw WriterError.unexpectedOutput }
        let sharedDescription = (json["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Top-up words follow the plan: tier A phrases first, then B, then C, so missed priority phrases get packed in when room remains.
        let evidenceWords: [String] = plan.priority.flatMap { ASORules.words($0.term) }
        var proposals: [Proposal] = []
        for item in items {
            guard let title = item["title"] as? String else { continue }
            var f = MetadataFields(name: title, subtitle: item["subtitle"] as? String ?? "", keywords: item["keywords"] as? String ?? "")
            f.promotionalText = current.promotionalText
            f.description = current.description
            f.whatsNew = current.whatsNew
            if writePromo, let promo = item["promotional_text"] as? String, !promo.isEmpty { f.promotionalText = String(promo.trimmingCharacters(in: .whitespacesAndNewlines).prefix(170)) }
            if writeDescription, !sharedDescription.isEmpty { f.description = String(sharedDescription.prefix(4000)) }
            if let legal = context.legal {
                f.description = LegalFooter.apply(to: f.description, locale: locale, eulaURL: legal.eulaURL, privacyURL: legal.privacyURL, note: legal.note)
            }
            var repairs: [String] = []
            f = await fitTitleAndSubtitle(f, context: context, model: model, repairs: &repairs, detailed: true)
            f = await fillKeywords(f, context: context, evidenceWords: evidenceWords, model: model, repairs: &repairs,
                                   topUpNote: { "Keyword field topped up with \($0) extra search word(s) from the app's domain (evidence was thin)." })
            let review = ASORules.review(f, locale: locale, siblings: siblings, storefront: context.storefront)
            proposals.append(Proposal(label: item["label"] as? String ?? "?", fields: ASORules.plainPunctuation(f), rationale: item["rationale"] as? String ?? "",
                                      review: review, issues: MetadataValidator.validate(f), repairs: repairs,
                                      coveredPhrases: plan.priority.map(\.term).filter { KeywordPlan.covers(f, phrase: $0) },
                                      missedPhrases: plan.priority.map(\.term).filter { !KeywordPlan.covers(f, phrase: $0) }))
        }
        // Rule score, then coverage weighted by tier: a covered tier-A phrase is worth three tier-C ones.
        func weight(_ p: Proposal) -> Int {
            p.coveredPhrases.reduce(0) { acc, t in acc + (plan.tierA.contains { $0.term == t } ? 3 : plan.tierB.contains { $0.term == t } ? 2 : 1) }
        }
        return (proposals.sorted { ($0.review.score + weight($0)) > ($1.review.score + weight($1)) }, answer.cost)
    }

    /// One improved version of the current draft: the rule findings become instructions, the plan stays the priority.
    /// Throws `notBetter` when the result would score lower than the draft (rule score plus tier-weighted coverage).
    public static func improve(_ context: Context, model: any TextModel) async throws -> (proposal: Proposal, cost: String?) {
        let current = context.current
        let locale = context.locale
        let plan = context.plan
        let siblings = context.indexedSiblings
        let before = ASORules.review(current, locale: locale, siblings: siblings, storefront: context.storefront)
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
        Keep what already works: change as little as needed to resolve every finding below, keep the brand "\(context.brand)" verbatim in the title, keep the listing language (\(locale.displayName)).
        Title and subtitle: 26–30 characters each. Keywords: 14–18 single lower-case words, complete dictionary words, no word from title or subtitle, no plurals of used words, no "&" or filler.
        """
        let user = """
        App: \(context.appName). Storefront: \(context.storefront). Locale: \(locale.rawValue).
        Current listing: title="\(current.name)" subtitle="\(current.subtitle)" keywords="\(current.keywords)"
        Findings to resolve:
        \(findings.isEmpty ? "(none: just use the room and cover the missing phrases)" : findings)
        Priority phrases not covered yet (cover as many as fit, tier A first):
        \(missing.isEmpty ? "(all covered)" : missing)
        Words used by other locales indexed on this storefront (do not repeat): \(siblingWordsText)
        """
        let answer = try await model.complete(system: system, user: user, temperature: 0.3, maxTokens: 800)
        guard let json = answer.jsonObject, let title = json["title"] as? String else { throw WriterError.unexpectedOutput }
        var f = current
        f.name = title
        f.subtitle = json["subtitle"] as? String ?? current.subtitle
        f.keywords = json["keywords"] as? String ?? current.keywords
        var repairs: [String] = []
        f = await fitTitleAndSubtitle(f, context: context, model: model, repairs: &repairs, detailed: false)
        f = await fillKeywords(f, context: context, evidenceWords: plan.priority.flatMap { ASORules.words($0.term) }, model: model,
                               repairs: &repairs, topUpNote: { "Keyword field topped up with \($0) extra search word(s)." })
        let review = ASORules.review(f, locale: locale, siblings: siblings, storefront: context.storefront)
        // Never hand back something worse: rule score plus tier-weighted coverage must not drop.
        func quality(_ fields: MetadataFields, _ r: ASORules.Report) -> Int {
            r.score + plan.priority.reduce(0) { acc, it in acc + (KeywordPlan.covers(fields, phrase: it.term) ? (it.tier == "A" ? 3 : it.tier == "B" ? 2 : 1) : 0) }
        }
        if quality(f, review) < quality(current, before) {
            throw WriterError.notBetter("The model's version scored lower than your draft (rule \(review.score) vs \(before.score), coverage counted); kept your draft. Try again or pick a stronger writer model in Settings.")
        }
        f = ASORules.plainPunctuation(f)
        let proposal = Proposal(label: "Improved", fields: f, rationale: (json["rationale"] as? String ?? "") + " Rule score \(before.score) → \(review.score).",
                                review: review, issues: MetadataValidator.validate(f), repairs: repairs,
                                coveredPhrases: plan.priority.map(\.term).filter { KeywordPlan.covers(f, phrase: $0) },
                                missedPhrases: plan.priority.map(\.term).filter { !KeywordPlan.covers(f, phrase: $0) })
        return (proposal, answer.cost)
    }

    /// One locale's release notes from a source text (same facts, native phrasing). A locale of the source's language gets the
    /// source itself, without a model call.
    public static func localizeWhatsNew(source: String, sourceLocale: AppLocale, locale: AppLocale, appName: String,
                                        model: any TextModel) async throws -> (text: String, cost: String?) {
        let trimmed = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        if locale == sourceLocale || sameLanguage(locale, sourceLocale) { return (trimmed, nil) }
        let answer = try await model.complete(
            system: "You localize App Store release notes (\"What's New\"). Output only the localized notes, nothing else: same facts and order, natural phrasing a native speaker would write, keep the line structure (one item per line, list lines start with a bullet •), never use em or en dashes as punctuation, plain text, at most 4000 characters. Do not add features that are not in the source.",
            user: "App: \(appName). Source language: \(sourceLocale.displayName). Target: \(locale.displayName) (\(locale.rawValue)).\n\nRelease notes:\n\(trimmed)",
            temperature: 0.2, maxTokens: 1200)
        return (String(ASORules.plainPunctuation(answer.text.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(4000)), answer.cost)
    }

    /// en-US and en-GB share release notes; so do es-ES/es-MX, pt-BR/pt-PT, fr-FR/fr-CA, Apple treats them as exchangeable.
    public static func sameLanguage(_ a: AppLocale, _ b: AppLocale) -> Bool {
        func lang(_ l: AppLocale) -> String { l.rawValue.hasPrefix("zh-") ? l.rawValue : String(l.rawValue.split(separator: "-").first ?? "") }
        return lang(a) == lang(b)
    }

    // MARK: Repair steps

    /// Title or subtitle over 30 characters: one small rewrite call each. Under 24: one extension call with the missing
    /// priority words.
    static func fitTitleAndSubtitle(_ fields: MetadataFields, context: Context, model: any TextModel, repairs: inout [String],
                                    detailed: Bool) async -> MetadataFields {
        var f = fields
        for field in [MetadataField.name, .subtitle] where f[field].count > 30 {
            if let shorter = try? await shorten(f[field], limit: 30, field: field, brand: context.brand, model: model), shorter.count <= 30 {
                repairs.append(detailed ? "\(field.title) shortened from \(f[field].count) to \(shorter.count) characters." : "\(field.title) shortened.")
                f[field] = shorter
            }
        }
        for field in [MetadataField.name, .subtitle] where f[field].count < 24 {
            let missing = context.plan.priority.map(\.term).filter { !KeywordPlan.covers(f, phrase: $0) }.prefix(4)
            if let longer = try? await extend(f[field], field: field, brand: context.brand, locale: context.locale, candidates: Array(missing), model: model),
               longer.count <= 30, longer.count > f[field].count {
                repairs.append("\(field.title) extended from \(f[field].count) to \(longer.count) characters.")
                f[field] = longer
            }
        }
        return f
    }

    /// The rule engine's repair, then extra search words from the model when the keyword field stays under 88 characters.
    static func fillKeywords(_ fields: MetadataFields, context: Context, evidenceWords: [String], model: any TextModel, repairs: inout [String],
                             topUpNote: (Int) -> String) async -> MetadataFields {
        var repaired = ASORules.repair(fields, topUpWith: evidenceWords)
        var f = repaired.fields
        repairs += repaired.notes
        guard f.keywords.count < 88 else { return f }
        let used = Set(ASORules.words(f.name) + ASORules.words(f.subtitle) + ASORules.words(f.keywords))
        if let extra = try? await moreKeywords(context: context, used: Array(used).sorted(), needed: 10, model: model), !extra.isEmpty {
            f.keywords = (f.keywords.split(separator: ",").map(String.init) + extra).joined(separator: ",")
            repaired = ASORules.repair(f, topUpWith: evidenceWords)
            f = repaired.fields
            repairs.append(topUpNote(extra.count))
        }
        return f
    }

    /// Extra single search words for the keyword field when tracked evidence cannot fill it (cheap, ~200 tokens).
    static func moreKeywords(context: Context, used: [String], needed: Int, model: any TextModel) async throws -> [String] {
        let answer = try await model.complete(
            system: "You suggest App Store keyword-field words. Output only a comma-separated list of lower-case single words, nothing else. No brand names of other companies, no filler words, no plurals of words already used, no word already used.",
            user: "App: \(context.appName). Category: \(context.category ?? "unknown"). Locale: \(context.locale.rawValue): write in that language. What the app does: \(String(context.description.prefix(700))). Already used words: \(used.joined(separator: ", ")). Give \(needed) more words people type when looking for this kind of app, most searched first.",
            temperature: 0.3, maxTokens: 120)
        return answer.text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.contains(" ") && !used.contains($0) }
    }

    /// A longer version of a short field that adds one or two of the given search words (cheap, ~200 tokens).
    static func extend(_ text: String, field: MetadataField, brand: String, locale: AppLocale, candidates: [String], model: any TextModel) async throws -> String {
        let answer = try await model.complete(
            system: "Rewrite App Store listing text to use 26–30 characters. Output only the rewritten text, nothing else. Keep every existing word, add one or two of the candidate search words that fit naturally, in the locale language. No \"&\", no filler words (and, to, your, with, for, the, a).",
            user: "Field: \(field.title). Locale: \(locale.rawValue). \(field == .name ? "Keep the brand \"\(brand)\" verbatim. " : "")Candidate words: \(candidates.isEmpty ? "(none: extend with a relevant search word)" : candidates.joined(separator: ", ")). Text: \(text)",
            temperature: 0.2, maxTokens: 60)
        return answer.text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }

    /// A shorter version of one field (cheap, ~200 tokens).
    static func shorten(_ text: String, limit: Int, field: MetadataField, brand: String, model: any TextModel) async throws -> String {
        let answer = try await model.complete(
            system: "Rewrite App Store listing text to fit a character limit. Output only the rewritten text, nothing else. No \"&\", no filler words.",
            user: "Field: \(field.title). Limit: \(limit) characters. \(field == .name ? "Keep the brand \"\(brand)\" verbatim. " : "")Text: \(text)",
            temperature: 0.2, maxTokens: 60)
        return answer.text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }

    /// The keyword table the model gets: Apple popularity (or "below N"), the latest rank and difficulty.
    static func evidenceJSON(_ rows: [Evidence]) -> String {
        let objects: [[String: Any]] = rows.map { e in
            var row: [String: Any] = ["term": e.term]
            if let p = e.popularity { row["popularity"] = p; row["popularity_source"] = e.popularitySource ?? "country" }
            else if let below = e.below { row["popularity"] = "below \(below)" }
            if let rank = e.rank { row["rank"] = rank }
            if let d = e.difficulty { row["difficulty"] = d }
            return row
        }
        return (try? String(decoding: JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]), as: UTF8.self)) ?? "[]"
    }
}
