import Foundation

/// Trying an app's keywords in other storefronts: how locals search for the same need (local search phrasing, asked of a
/// model, then measured), and which cells are worth a market.
public enum KeywordExpansion {
    /// The storefronts tried by default, without the home market.
    public static let defaultCountries = ["GB", "DE", "FR", "ES", "IT", "BR", "JP", "KR"]

    /// A local-language search phrase for a source keyword, with what it means in English.
    public struct LocalForm: Sendable, Equatable {
        public let term: String
        public let source: String
        public let meaning: String

        public init(term: String, source: String, meaning: String) {
            self.term = term
            self.source = source
            self.meaning = meaning
        }
    }

    /// Popularity weighted by how winnable the results are: `popularity × (1 − (difficulty/100)²)`.
    public static func opportunity(popularity: Int?, difficulty: Double?) -> Double? {
        guard let popularity, let difficulty else { return nil }
        return Double(popularity) * (1 - pow(difficulty / 100, 2))
    }

    /// Worth a market: Apple-level demand (30 or more) and either a foothold (top 30) or beatable results (difficulty 45 or
    /// less), in a language people search there. Unknown values count against the cell, an unchecked language for it.
    public static func isCandidate(popularity: Int?, rank: Int?, difficulty: Double?, languageFit: Double?) -> Bool {
        (popularity ?? 0) >= 30 && ((rank ?? 999) <= 30 || (difficulty ?? 100) <= 45) && (languageFit ?? 1) >= 0.4
    }

    /// The language without its region ("de" for de-DE), to tell whether a storefront speaks another language.
    public static func language(of locale: AppLocale) -> String {
        String(locale.rawValue.split(separator: "-").first ?? "")
    }

    /// How people in the storefront actually search for what each term means: local search phrasing, not dictionary
    /// translation, with the app's description as context so the meaning survives. One call per storefront; up to three
    /// forms per term, none repeating a source term or another form.
    public static func localForms(of terms: [String], appName: String, description: String, storefront: Storefront,
                                  model: any TextModel) async throws -> (forms: [LocalForm], cost: String?) {
        let system = """
        You are an App Store search localization specialist. For each source keyword, give how people in the target country actually type that need into App Store search, in the store language: 1 to 3 short phrases, lower-case, no punctuation, at most 4 words, real search phrasing (what a person types, not marketing copy). Preserve the meaning of the source keyword, same need, same intent. If locals commonly search this need with the English words, say so by returning the English phrase as one candidate. Never invent brand names.
        Output strict JSON only: {"terms":[{"source":"…","candidates":[{"term":"…","meaning":"short gloss in English"}]}]}
        """
        let user = """
        App: \(appName). What it does: \(String(description.prefix(900)))
        Target: \(storefront.name) (\(storefront.countryCode)) App Store, store language \(storefront.defaultLocale.displayName).
        Source keywords (English or the app's home market): \(terms.joined(separator: ", "))
        """
        let answer = try await model.complete(system: system, user: user, temperature: 0.3, maxTokens: 2500)
        guard let items = answer.jsonObject?["terms"] as? [[String: Any]] else { return ([], answer.cost) }
        var out: [LocalForm] = []
        var seen = Set(terms.map(KeywordText.normalize))
        for item in items {
            guard let source = item["source"] as? String, let candidates = item["candidates"] as? [[String: Any]] else { continue }
            for candidate in candidates.prefix(3) {
                guard let text = candidate["term"] as? String else { continue }
                let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.count >= 2, seen.insert(KeywordText.normalize(clean)).inserted else { continue }
                out.append(LocalForm(term: clean, source: source, meaning: candidate["meaning"] as? String ?? ""))
            }
        }
        return (out, answer.cost)
    }
}
