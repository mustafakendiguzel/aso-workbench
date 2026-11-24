import Foundation
import ASOCore

/// TypeSafe Jev through OpenRouter's Decisions API. Jev answers typed questions with calibrated
/// probabilities; it never generates text. We ask narrow semantic questions about a keyword and
/// keep every number in code (Jev's documented weakness is arithmetic).
public actor JevClient: KeywordJudge {
    public static let model = "typesafe/jev-1.13"
    private let http = HTTPClient(serviceName: "OpenRouter", allowedHosts: ["openrouter.ai"])
    private var apiKey: String?

    public init(apiKey: String?) {
        self.apiKey = apiKey
    }

    public func update(apiKey: String?) { self.apiKey = apiKey }
    public var isConfigured: Bool { !(apiKey ?? "").isEmpty }

    /// Cheap authenticated call used by "Test connection".
    public func verify() async throws -> String {
        let f = try await classify(term: "photo editor", storefront: "US", storeLanguage: "English")
        return "Jev answered (demand \(String(format: "%.2f", f.demand))/4, intent \(f.intent))."
    }

    /// One Decisions request; returns the `answers` object.
    private func ask(key: String, state: [String: Any], questions: [String: Any]) async throws -> [String: Any] {
        let body: [String: Any] = ["model": Self.model, "state": state, "questions": questions]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = HTTPClient.request(URL(string: "https://openrouter.ai/api/alpha/decisions")!, method: "POST", headers: [
            "Authorization": "Bearer \(key)", "Content-Type": "application/json",
            "HTTP-Referer": AppInfo.repositoryURL.absoluteString, "X-OpenRouter-Title": "ASO Workbench",
        ], body: data, timeout: 60)
        var response = try await http.send(request)
        if response.status == 429 || response.status == 529 {
            try? await Task.sleep(for: .seconds(2))
            response = try await http.send(request)
        }
        try http.check(response)
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], let answers = json["answers"] as? [String: Any] else {
            throw ASOError.decoding(service: "OpenRouter", detail: "No answers in response.")
        }
        return answers
    }

    /// Probability that someone searching `term` wants an app like this one. Judged against the app's own store
    /// description, so "musik erkennen" (identify a song) scores low for a cover-generator app despite the word overlap.
    public func fit(term: String, appName: String, appDescription: String, storefront: String, storeLanguage: String) async throws -> Double {
        guard let key = apiKey, !key.isEmpty else { throw ASOError.notConfigured(service: "OpenRouter") }
        let state: [String: Any] = [
            "search_term": term,
            "app_name": appName,
            "app_description": String(appDescription.prefix(1500)),
            "app_store_country": storefront.uppercased(),
            "store_language": storeLanguage,
            "context": "A person typed the search term into App Store search on an iPhone in this country. Decide whether this app is what they are looking for.",
        ]
        let questions: [String: Any] = [
            "fit": ["type": "noul", "instructions": "Would a person who searched `search_term` be looking for an app like `app_name` (see `app_description`)?",
                    "criteria": ["true": "The term names what this app does, a feature it has, or a need it serves; the searcher would consider installing it.",
                                 "false": "The searcher wants something this app does not do, a different function, another company's product, or an unrelated topic, even if some words overlap."]],
        ]
        let answers = try await ask(key: key, state: state, questions: questions)
        guard let v = (answers["fit"] as? [String: Any])?["noul"] as? Double else { throw ASOError.decoding(service: "OpenRouter", detail: "No fit answer.") }
        return v
    }

    /// Probability that a standalone iPhone app could serve what the term asks for (vs a brand, a setting, a person, content).
    public func appable(term: String, storefront: String, storeLanguage: String) async throws -> Double {
        guard let key = apiKey, !key.isEmpty else { throw ASOError.notConfigured(service: "OpenRouter") }
        let state: [String: Any] = [
            "search_term": term, "app_store_country": storefront.uppercased(), "store_language": storeLanguage,
            "context": "The search term is typed into App Store search on an iPhone in this country. We are looking for needs a new app could be built for.",
        ]
        let questions: [String: Any] = [
            "appable": ["type": "noul", "instructions": "Could a standalone iPhone app be built to serve what `search_term` asks for?",
                        "criteria": ["true": "A need, task, tool, content type or activity an app can deliver (e.g. 'sleep sounds', 'invoice maker', 'manga reader', 'learn spanish').",
                                     "false": "A specific company's product or account, a device or system setting, a person or place, an event, or something that is not an app at all (e.g. 'apple account', 'verizon', 'settings', 'taylor swift')."]],
        ]
        let answers = try await ask(key: key, state: state, questions: questions)
        guard let v = (answers["appable"] as? [String: Any])?["noul"] as? Double else { throw ASOError.decoding(service: "OpenRouter", detail: "No appable answer.") }
        return v
    }

    /// Probability that `term` is a way of finding one specific app, judged with the actual top results in view.
    public func navigational(term: String, topResults: [String], storefront: String, storeLanguage: String) async throws -> Double {
        guard let key = apiKey, !key.isEmpty else { throw ASOError.notConfigured(service: "OpenRouter") }
        let state: [String: Any] = [
            "search_term": term, "top_results": Array(topResults.prefix(5)), "app_store_country": storefront.uppercased(), "store_language": storeLanguage,
            "context": "The search term is typed into App Store search on an iPhone. `top_results` are the names of the apps Apple ranks first for it.",
        ]
        let questions: [String: Any] = [
            "navigational": ["type": "noul", "instructions": "Is `search_term` a way of finding one specific existing app or company product (see `top_results`), rather than a generic need any app could serve?",
                             "criteria": ["true": "The term is, contains, or misspells the name of a specific app, company or product, e.g. 'koupon app amazon' (Koupon), 'when i work' (When I Work), 'my chart app' (MyChart).",
                                          "false": "A generic description of a need, task or content type, e.g. 'calorie tracker', 'white noise', 'invoice maker', even if the top result happens to carry those words."]],
        ]
        let answers = try await ask(key: key, state: state, questions: questions)
        guard let v = (answers["navigational"] as? [String: Any])?["noul"] as? Double else { throw ASOError.decoding(service: "OpenRouter", detail: "No navigational answer.") }
        return v
    }

    public func classify(term: String, storefront: String, storeLanguage: String) async throws -> JevFeatures {
        guard let key = apiKey, !key.isEmpty else { throw ASOError.notConfigured(service: "OpenRouter") }
        let state: [String: Any] = [
            "search_term": term,
            "app_store_country": storefront.uppercased(),
            "store_language": storeLanguage,
            "context": "The search term is typed by a person into the App Store search box on an iPhone in this country.",
        ]
        let genres = AppleAdsGenre.allCases.map(\.rawValue)
        let questions: [String: Any] = [
            "brand": ["type": "noul", "instructions": "Is `search_term` primarily the name of a specific app, company or brand rather than a generic description?",
                      "criteria": ["true": "A proper name people type to find one specific product (e.g. 'spotify', 'suno ai', 'duolingo').", "false": "A generic phrase describing a need or category (e.g. 'budget planner', 'ai music generator')."]],
            "natural": ["type": "noul", "instructions": "Is `search_term` something a real person would plausibly type into App Store search?",
                        "criteria": ["true": "Short, natural search phrasing a user would type (e.g. 'comic reader', 'photo editor').", "false": "Marketing copy, a full app title with punctuation, or an unnatural word pile (e.g. 'vocalme music: ai-cover & musik')."]],
            "language_fit": ["type": "noul", "instructions": "Is `search_term` written in a language that users in `app_store_country` commonly use for App Store searches?",
                             "criteria": ["true": "Local language, or English where English search is common in that country.", "false": "A language users in that country would rarely search in."]],
            "intent": ["type": "choice", "instructions": "What kind of search is `search_term`?",
                       "criteria": ["brand": "A specific app or company name.", "category": "A broad category or head term (one or two generic words, e.g. 'comics', 'photo editor').",
                                    "feature": "A specific feature or capability (e.g. 'comic book value scanner', 'remove background').",
                                    "longtail": "A long descriptive phrase with three or more words, narrow intent (e.g. 'ai cover generator for songs').",
                                    "other": "Not a plausible App Store search at all."]],
            "head_term": ["type": "score", "instructions": "How much is `search_term` a broad head term versus a narrow long-tail phrase?",
                          "criteria": ["Very narrow long-tail phrase", "Narrow", "Moderately specific", "Broad", "Very broad head term or single common word"]],
            "demand": ["type": "score", "instructions": "How many people per month would type exactly `search_term` into App Store search in `app_store_country`? Judge by how common and natural the phrase is, not by how good the idea is.",
                       "criteria": ["Practically nobody searches this exact phrase", "A few searches", "A moderate number", "Many searches", "One of the most common searches in its category"]],
            "genre": ["type": "choice", "instructions": "Which Apple Ads genre do apps for `search_term` most likely belong to?",
                      "criteria": Dictionary(uniqueKeysWithValues: genres.map { ($0, $0.replacingOccurrences(of: "_", with: " ").lowercased() + " apps") })],
        ]
        let answers = try await ask(key: key, state: state, questions: questions)
        var f = JevFeatures()
        func noul(_ k: String) -> Double { ((answers[k] as? [String: Any])?["noul"] as? Double) ?? -1 }
        f.brand = noul("brand")
        f.naturalQuery = noul("natural")
        f.languageFit = noul("language_fit")
        if let h = answers["head_term"] as? [String: Any] { f.headTerm = (h["score"] as? Double) ?? -1 }
        if let d = answers["demand"] as? [String: Any] {
            f.demand = (d["score"] as? Double) ?? -1
            if let p = d["probabilities"] as? [String: Double] { f.demandProbabilities = (0..<5).map { p[String($0)] ?? 0 } }
        }
        if let i = answers["intent"] as? [String: Any] {
            f.intent = (i["choice"] as? String) ?? ""
            if let p = i["probabilities"] as? [String: Double] { f.intentProbabilities = p }
        }
        if let g = answers["genre"] as? [String: Any] {
            f.genre = (g["choice"] as? String) ?? ""
            f.genreConfidence = (g["confidence"] as? Double) ?? -1
        }
        return f
    }
}
