import Foundation
import Testing
@testable import ASOCore

@Suite("Keyword expansion")
struct KeywordExpansionTests {
    @Test("Opportunity weighs popularity by difficulty; a candidate needs demand, a foothold or beatable results, and the language")
    func verdicts() {
        #expect(KeywordExpansion.opportunity(popularity: 60, difficulty: 50) == 45)
        #expect(KeywordExpansion.opportunity(popularity: nil, difficulty: 50) == nil)
        #expect(KeywordExpansion.isCandidate(popularity: 40, rank: 12, difficulty: 80, languageFit: nil))
        #expect(KeywordExpansion.isCandidate(popularity: 40, rank: nil, difficulty: 40, languageFit: 0.9))
        #expect(!KeywordExpansion.isCandidate(popularity: 29, rank: 1, difficulty: 10, languageFit: 0.9))
        #expect(!KeywordExpansion.isCandidate(popularity: 40, rank: 50, difficulty: 60, languageFit: 0.9))
        #expect(!KeywordExpansion.isCandidate(popularity: 40, rank: 1, difficulty: 10, languageFit: 0.2))
        #expect(KeywordExpansion.language(of: .deDE) == "de")
    }

    @Test("Local forms keep the meaning, up to three per keyword, never repeating a source keyword or another form")
    func localForms() async throws {
        let json = #"""
        Sure: {"terms":[
          {"source":"notes","candidates":[{"term":"Notizen","meaning":"notes"},{"term":"notes","meaning":"same"},{"term":"notiz app","meaning":"note app"},
                                          {"term":"x","meaning":"too short"},{"term":"notizbuch","meaning":"notebook"},{"term":"memo","meaning":"fourth"}]},
          {"source":"journal","candidates":[{"term":"tagebuch","meaning":"diary"},{"term":"NOTIZEN","meaning":"again"}]}]}
        """#
        let model = ScriptedModel([("You are an App Store search localization specialist", json)])
        let germany = try #require(StorefrontRegistry.lookup("DE"))
        let (forms, cost) = try await KeywordExpansion.localForms(of: ["notes", "journal"], appName: "Acme Notes", description: "Write notes.",
                                                                  storefront: germany, model: model)
        #expect(forms.map(\.term) == ["notizen", "notiz app", "tagebuch"])
        #expect(forms[0] == KeywordExpansion.LocalForm(term: "notizen", source: "notes", meaning: "notes"))
        #expect(cost == "$0.0010")
        #expect(model.calls[0].user.contains("Target: Germany (DE) App Store, store language German."))
        #expect(model.calls[0].user.contains("Source keywords (English or the app's home market): notes, journal"))

        let silent = ScriptedModel([("You are an App Store search localization specialist", "No idea.")])
        #expect(try await KeywordExpansion.localForms(of: ["notes"], appName: "A", description: "", storefront: germany, model: silent).forms.isEmpty)
    }
}
