import Foundation
import Testing
@testable import ASOCore

/// A model without the network: answers by the kind of request (its system prompt, and the user prompt for small edits)
/// and records every call. No answer is an error, as a failed request would be.
final class ScriptedModel: TextModel, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(system: String, user: String)] = []
    let answer: @Sendable (_ system: String, _ user: String) -> String?

    init(_ answer: @escaping @Sendable (_ system: String, _ user: String) -> String?) { self.answer = answer }

    /// Answers by the start of the system prompt.
    convenience init(_ answers: [(prefix: String, text: String)]) {
        self.init { system, _ in answers.first { system.hasPrefix($0.prefix) }?.text }
    }

    var calls: [(system: String, user: String)] { lock.lock(); defer { lock.unlock() }; return log }

    private func record(_ system: String, _ user: String) {
        lock.lock(); defer { lock.unlock() }
        log.append((system, user))
    }

    func complete(system: String, user: String, temperature: Double, maxTokens: Int) async throws -> TextCompletion {
        record(system, user)
        guard let text = answer(system, user) else { throw ASOError.network("no scripted answer") }
        return TextCompletion(text: text, cost: "$0.0010")
    }
}

@Suite("Metadata writer")
struct MetadataWriterTests {
    static let proposeKind = "You are an App Store Optimization specialist. Follow"
    static let improveKind = "You are an App Store Optimization specialist fixing"
    static let moreKind = "You suggest App Store keyword-field words"
    static let shortenKind = "Rewrite App Store listing text to fit"
    static let extendKind = "Rewrite App Store listing text to use"
    static let localizeKind = "You localize App Store release notes"

    let current = MetadataFields(name: "Acme Notes", subtitle: "Journal", keywords: "notes", promotionalText: "", description: "",
                                 whatsNew: "Bug fixes.")

    func context(_ fields: MetadataFields? = nil, legal: MetadataWriter.LegalLinks? = nil) -> MetadataWriter.Context {
        let plan = KeywordPlan.make([
            KeywordPlan.Input(term: "daily journal", popularity: 55, popularitySource: "list", difficulty: 20, fit: 0.9, brandLike: false,
                              observedCount: 200, rank: 14),
            KeywordPlan.Input(term: "notes", popularity: 70, popularitySource: "list", difficulty: 50, fit: 0.9, brandLike: false,
                              observedCount: 200, rank: nil),
            KeywordPlan.Input(term: "rival", popularity: 80, popularitySource: "list", difficulty: 30, fit: 0.9, brandLike: true,
                              observedCount: nil, rank: nil),
        ])
        return MetadataWriter.Context(
            appName: "Acme Notes", sellerName: "Acme Inc", category: "Productivity", brand: "Acme Notes", locale: .enUS, storefront: "US",
            current: fields ?? current, siblings: [(.esMX, MetadataFields(name: "Acme Notas", subtitle: "Diario", keywords: "notas"))],
            plan: plan,
            evidence: [MetadataWriter.Evidence(term: "daily journal", popularity: 55, popularitySource: "list", below: nil, rank: "#14", difficulty: 20),
                       MetadataWriter.Evidence(term: "memo", popularity: nil, popularitySource: "belowRange", below: 30, rank: nil, difficulty: nil)],
            competitors: ["Rival Journal (in 2 tracked queries)"], description: "Write notes and keep a daily journal.", legal: legal)
    }

    @Test("Proposals are repaired, scored and ranked; copy is written when empty and the legal footer appended")
    func propose() async throws {
        let json = """
        Here you go: {"proposals":[
          {"label":"A","title":"Acme Notes — Daily Journal and Planner","subtitle":"Journal","keywords":"notes,diary","rationale":"Volume.","promotional_text":"Capture every thought."},
          {"label":"B","title":"Acme Notes: Daily Journal","subtitle":"Diary, memos, planner, ideas","keywords":"memo,ideas,thoughts,writing,record,log,entries,mood,gratitude,reflection,habit,tracker,private,secure","rationale":"Balanced."}
        ],"description":"Acme Notes keeps your days.\\n- Write notes\\n- Keep a journal"}
        """
        let model = ScriptedModel { system, user in
            if system.hasPrefix(Self.proposeKind) { return json }
            if system.hasPrefix(Self.shortenKind) { return "Acme Notes: Journal" }
            if system.hasPrefix(Self.extendKind) { return user.hasPrefix("Field: Name") ? "\"Acme Notes: Daily Journal\"" : "Diary, memos, planner" }
            if system.hasPrefix(Self.moreKind) { return "diary, planner, memo\nnotes, two words" }
            return nil
        }
        let legal = MetadataWriter.LegalLinks(eulaURL: LegalFooter.appleStandardEULA, privacyURL: "https://acme.example/privacy", note: "")
        let (proposals, cost) = try await MetadataWriter.propose(context(legal: legal), strategy: .brandFirst, notes: "Calm tone.", model: model)

        #expect(cost == "$0.0010")
        #expect(Set(proposals.map(\.label)) == ["A", "B"])
        let a = try #require(proposals.first { $0.label == "A" })
        #expect(a.fields.name == "Acme Notes: Daily Journal")
        #expect(a.fields.subtitle == "Diary, memos, planner")
        #expect(a.repairs.starts(with: ["Name shortened from 38 to 19 characters.", "Name extended from 19 to 25 characters.",
                                        "Subtitle extended from 7 to 21 characters."]))
        #expect(a.coveredPhrases.contains("daily journal"))
        #expect(a.repairs.contains { $0.hasPrefix("Keyword field topped up with") })
        #expect(a.fields.promotionalText == "Capture every thought.")
        #expect(a.fields.description.hasPrefix("Acme Notes keeps your days.\n• Write notes"))
        #expect(a.fields.description.contains("Privacy Policy: https://acme.example/privacy"))
        // Release notes are not the writer's: the draft's stay.
        #expect(a.fields.whatsNew == "Bug fixes.")
        #expect(!a.fields.keywords.contains("two words"))

        let prompt = try #require(model.calls.first { $0.system.hasPrefix(Self.proposeKind) })
        #expect(prompt.system.contains("\"promotional_text\""))
        #expect(prompt.system.contains(",\"description\":"))
        #expect(prompt.user.contains("TIER A: winnable now"))
        #expect(prompt.user.contains("- notes (popularity 70, difficulty 50, rank not in top 200, already covered)"))
        #expect(prompt.user.contains("AVOID these tracked terms: other brands or navigational names, unrelated to what this app does, or too hard to win; do not use their distinctive words: rival"))
        #expect(prompt.user.contains(#""popularity":"below 30""#))
        #expect(prompt.user.contains("Brand strategy: brand first, then feature words."))
        #expect(prompt.user.contains("es-MX: title=\"Acme Notas\""))
        #expect(prompt.user.contains("Extra notes from the ASO manager: Calm tone."))
    }

    @Test("Copy that is already written stays unless asked; output that is not the expected JSON is an error")
    func copyAndBadOutput() async throws {
        var written = current
        written.promotionalText = "Already written."
        written.description = "Already described."
        let json = #"{"proposals":[{"label":"A","title":"Acme Notes: Daily Journal","subtitle":"Diary, memos and planner","keywords":"notes,diary","promotional_text":"New."}]}"#
        let model = ScriptedModel([(Self.proposeKind, json), (Self.moreKind, "")])
        let (proposals, _) = try await MetadataWriter.propose(context(written), strategy: .featureFirst, notes: "", model: model)
        #expect(proposals[0].fields.promotionalText == "Already written.")
        #expect(proposals[0].fields.description == "Already described.")
        #expect(!model.calls[0].system.contains("\"promotional_text\""))

        let broken = ScriptedModel([(Self.proposeKind, "Sorry, I cannot help with that.")])
        await #expect(throws: MetadataWriter.WriterError.unexpectedOutput) {
            try await MetadataWriter.propose(context(), strategy: .featureFirst, notes: "", model: broken)
        }
    }

    @Test("Make better keeps what works, and refuses a version that scores lower")
    func improve() async throws {
        let better = #"{"title":"Acme Notes: Daily Journal","subtitle":"Diary, memos, planner","keywords":"ideas,thoughts,writing,record,mood,gratitude,habit,tracker,private,entries,reflection,log","rationale":"Covers the tier A phrase."}"#
        let model = ScriptedModel([(Self.improveKind, better), (Self.moreKind, "")])
        let (proposal, _) = try await MetadataWriter.improve(context(), model: model)
        #expect(proposal.label == "Improved")
        #expect(proposal.coveredPhrases.contains("daily journal"))
        #expect(proposal.rationale.contains("Rule score"))
        #expect(proposal.fields.whatsNew == "Bug fixes.")
        #expect(model.calls[0].user.contains("A: daily journal (pop 55, diff 20)"))

        let worse = ScriptedModel([(Self.improveKind, #"{"title":"Notes","subtitle":"","keywords":""}"#), (Self.extendKind, "Notes"), (Self.moreKind, "")])
        let strong = MetadataFields(name: "Acme Notes: Daily Journal", subtitle: "Diary, memos, planner", keywords: "ideas,thoughts,writing,record,mood")
        await #expect(throws: MetadataWriter.WriterError.self) { try await MetadataWriter.improve(context(strong), model: worse) }
    }

    @Test("Release notes keep their facts in another language; the source's language gets the source itself")
    func whatsNew() async throws {
        let model = ScriptedModel([(Self.localizeKind, "Fehlerbehebungen — und mehr Tempo.\n")])
        let (german, cost) = try await MetadataWriter.localizeWhatsNew(source: " Bug fixes. ", sourceLocale: .enUS, locale: .deDE, appName: "Acme", model: model)
        #expect(german == "Fehlerbehebungen, und mehr Tempo.")
        #expect(cost == "$0.0010")
        #expect(model.calls[0].user.hasSuffix("Release notes:\nBug fixes."))

        let (british, none) = try await MetadataWriter.localizeWhatsNew(source: "Bug fixes.", sourceLocale: .enUS, locale: .enGB, appName: "Acme", model: model)
        #expect(british == "Bug fixes.")
        #expect(none == nil)
        #expect(model.calls.count == 1)
        #expect(MetadataWriter.sameLanguage(.zhHans, .zhHans))
        #expect(!MetadataWriter.sameLanguage(.zhHans, .zhHant))
        #expect(MetadataWriter.sameLanguage(.frFR, .frCA))
    }

    @Test("The first JSON object is found inside prose or code fences")
    func jsonInText() {
        #expect(TextCompletion.jsonObject(in: "```json\n{\"a\":1}\n```")?["a"] as? Int == 1)
        #expect(TextCompletion.jsonObject(in: "no json") == nil)
    }
}
