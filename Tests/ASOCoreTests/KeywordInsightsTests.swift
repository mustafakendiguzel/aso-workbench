import Foundation
import Testing
@testable import ASOCore

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_785_542_400)   // 2026-08-01 00:00 UTC

private func at(_ days: Double) -> Date { t0.addingTimeInterval(days * day) }

private func point(_ days: Double, _ outcome: RankOutcome, provider: ProviderID = .itunesSearch) -> RankPoint {
    RankPoint(fetchedAt: at(days), outcome: outcome, provider: provider)
}

private func app(_ id: Int, _ name: String, seller: String = "", ratings: Int? = nil) -> SearchResultApp {
    SearchResultApp(trackID: id, bundleID: nil, name: name, sellerName: seller.isEmpty ? "Seller \(id)" : seller, iconURL: nil,
                    averageRating: 4.5, ratingCount: ratings, primaryGenre: nil, releaseDate: nil, currentVersionReleaseDate: nil,
                    price: 0, version: nil)
}

@Suite("Keyword text")
struct KeywordTextTests {
    @Test("Trimmed, lowercased, inner whitespace collapsed")
    func normalize() {
        #expect(KeywordText.normalize("  Budget\t Planner \n") == "budget planner")
        #expect(KeywordText.normalize("Bütçe   PLAN") == "bütçe plan")
        #expect(KeywordText.normalize("") == "")
    }

    @Test("Opportunity discounts popularity quadratically by difficulty")
    func opportunity() {
        #expect(Opportunity.score(popularity: 60, difficulty: 0) == 60)
        #expect(Opportunity.score(popularity: 60, difficulty: 50) == 45)
        #expect(Opportunity.score(popularity: 60, difficulty: 100) == 0)
    }
}

@Suite("Rank history")
struct RankHistoryTests {
    @Test("Failed and unchecked measurements are not measurements")
    func latestIgnoresFailures() {
        let h = RankHistory([
            point(0, .found(position: 12, observedCount: 200)),
            point(1, .found(position: 8, observedCount: 200)),
            point(2, .requestFailed(reason: "timeout")),
            point(3, .notChecked),
        ])
        #expect(h.latestMeasured?.fetchedAt == at(1))
        #expect(h.previousMeasured?.fetchedAt == at(0))
        #expect(h.rankDelta == 4)
        #expect(h.successful.map(\.fetchedAt) == [at(0), at(1)])
    }

    @Test("The previous measurement comes from the same provider as the latest")
    func previousSameProvider() {
        let h = RankHistory([
            point(0, .found(position: 30, observedCount: 200)),
            point(1, .found(position: 5, observedCount: 50), provider: "other"),
            point(2, .found(position: 20, observedCount: 200)),
        ])
        #expect(h.previousMeasured?.fetchedAt == at(0))
        #expect(h.rankDelta == 10)
    }

    @Test("Absence has no delta against the previous measurement")
    func outsideHasNoPreviousDelta() {
        let h = RankHistory([point(0, .found(position: 3, observedCount: 200)), point(1, .outsideObservedRange(observedCount: 200))])
        #expect(h.rankDelta == nil)
        #expect(h.delta(reference: .previous, markers: []).delta == nil)
        // Against the first measurement "not in top 200" counts as 201.
        #expect(h.delta(reference: .first, markers: []).delta == 3 - 201)
    }

    @Test("Before/after picks the last measurement at or before the date and the latest after it")
    func beforeAfter() {
        let h = RankHistory([point(0, .found(position: 40, observedCount: 200)), point(2, .found(position: 30, observedCount: 200)),
                             point(5, .found(position: 10, observedCount: 200))])
        let pair = h.beforeAfter(at(2))
        #expect(pair?.before.fetchedAt == at(2))
        #expect(pair?.after.fetchedAt == at(5))
        #expect(h.beforeAfter(at(5)) == nil)
        #expect(h.beforeAfter(at(-1)) == nil)
    }

    @Test("Delta references")
    func references() {
        let h = RankHistory([point(0, .found(position: 50, observedCount: 200)), point(3, .found(position: 40, observedCount: 200)),
                             point(10, .found(position: 25, observedCount: 200))])
        #expect(h.delta(reference: .first, markers: []).delta == 25)
        #expect(h.delta(reference: .week, markers: []).delta == 15)       // 7 days before day 10 → day 3
        #expect(h.delta(reference: .previous, markers: []).delta == 15)
        let release = Marker(date: at(1), title: "Release 2.0", kind: "release")
        let d = h.delta(reference: .lastMarker, markers: [release])
        #expect(d.delta == 25)                                              // day 0 (before) → day 10 (latest)
        #expect(d.against.hasPrefix("Release 2.0 · "))
        #expect(h.delta(reference: .lastMarker, markers: []).against == "first measurement (no release or change recorded)")
    }

    @Test("Edge cases say what is missing")
    func missing() {
        let none = RankHistory([RankPoint]()).delta(reference: .first, markers: [])
        #expect(none.delta == nil)
        #expect(none.against == "no measurement")
        let one = RankHistory([point(0, .found(position: 9, observedCount: 200))])
        #expect(one.delta(reference: .first, markers: []).delta == nil)
        #expect(one.delta(reference: .week, markers: []).against == "7 days ago")
        #expect(one.delta(reference: .lastMarker, markers: []).against == "no release or change yet")
        let late = Marker(date: at(-1), title: "Note", kind: "note")
        #expect(one.delta(reference: .lastMarker, markers: [late]).against == "no measurement before Note")
    }

    @Test("Works over any stored record type")
    func generic() {
        struct Stored { let id: Int; let day: Double; let rank: Int }
        let h = RankHistory([Stored(id: 1, day: 0, rank: 9), Stored(id: 2, day: 1, rank: 4)]) {
            point($0.day, .found(position: $0.rank, observedCount: 200))
        }
        #expect(h.latestMeasured?.id == 2)
        #expect(h.rankDelta == 5)
    }
}

@Suite("Keyword judgement")
struct KeywordJudgementTests {
    let own = KeywordJudgement.OwnApp(trackID: 1, name: "Acme Notes", sellerName: "Acme Inc")

    func judge(_ term: String, results: [SearchResultApp]?, brand: Double? = nil, navigational: Double? = nil, fit: Double? = nil,
               popularity: Int? = nil) -> KeywordJudgement {
        KeywordJudgement(term: term, ownApp: own, measurement: results.map { .init(results: $0, signals: nil) }, brandProbability: brand,
                         navigational: navigational, fitProbability: fit, popularity: popularity)
    }

    @Test("Our app leading or our own name is never someone else's brand")
    func ownTerms() {
        #expect(judge("quick notes", results: [app(1, "Acme Notes")]).ownAppLeads)
        #expect(judge("quick notes", results: [app(9, "Acme Journal", seller: "Acme Inc")]).ownAppLeads)
        #expect(judge("acme notes", results: nil).isOwnBrandTerm)
        #expect(!judge("acme notes", results: [app(2, "Acme Notes Pro", ratings: 90_000)], brand: 0.9).isBrandLike)
    }

    @Test("A leader that carries the term's name and has real ratings owns the term")
    func leaderOwnsTerm() {
        #expect(judge("koupon deals", results: [app(2, "Koupon: Real Deals", ratings: 300)]).leaderOwnsTerm)
        #expect(!judge("koupon deals", results: [app(2, "Koupon: Real Deals", ratings: 10)]).leaderOwnsTerm)
        #expect(!judge("koupon deals", results: []).leaderOwnsTerm)
        #expect(judge("koupon deals", results: [app(2, "Koupon: Real Deals", ratings: 300)]).isBrandLike)
    }

    @Test("Jev's brand and navigational signals make a term brand-like")
    func jevSignals() {
        #expect(judge("x tracker", results: [app(2, "Tracker")], brand: 0.5).isBrandLike)
        #expect(judge("x tracker", results: [app(2, "Tracker")], navigational: 0.6).isBrandLike)
        #expect(!judge("x tracker", results: [app(2, "Tracker")], brand: 0.49, navigational: 0.59).isBrandLike)
    }

    @Test("Golden needs demand, beatable results, no brand, and fit; unchecked fit counts as related")
    func golden() throws {
        let easy = (2...9).map { app($0, "Random Tool \($0)", ratings: 30) }
        let j = judge("habit tracker", results: easy, popularity: 40)
        let d = try #require(j.difficulty)
        #expect(d.score <= 45)
        #expect(j.opportunity == Opportunity.score(popularity: 40, difficulty: d.score))
        #expect(j.isGolden(minPopularity: 30, maxDifficulty: 45))
        #expect(!j.isGoldenLead(minPopularity: 30, maxDifficulty: 45))
        #expect(!judge("habit tracker", results: easy, popularity: 29).isGolden(minPopularity: 30, maxDifficulty: 45))
        #expect(!judge("habit tracker", results: easy, brand: 0.8, popularity: 40).isGolden(minPopularity: 30, maxDifficulty: 45))
        let lead = judge("habit tracker", results: easy, fit: 0.2, popularity: 40)
        #expect(!lead.isGolden(minPopularity: 30, maxDifficulty: 45))
        #expect(lead.isGoldenLead(minPopularity: 30, maxDifficulty: 45))
        #expect(!judge("habit tracker", results: nil, popularity: 40).isGolden(minPopularity: 30, maxDifficulty: 45))
    }

    @Test("Stored difficulty wins; results are only read without it")
    func storedDifficulty() {
        let results = (2...9).map { app($0, "Habit Tracker \($0)", ratings: 50_000) }
        let signals = CompetitionSignals(results: results, term: "habit tracker")
        var reads = 0
        let d = KeywordJudgement.difficulty(signals: signals, results: { reads += 1; return results }(), term: "habit tracker")
        #expect(d == signals.difficulty)
        #expect(reads == 0)
        #expect(KeywordJudgement.difficulty(signals: nil, results: [], term: "x") == nil)
    }
}

@Suite("Idea gaps")
struct IdeaGapTests {
    func gap(_ term: String, difficulty: Double? = 20, brand: Double? = nil, natural: Double? = nil, appable: Double? = nil,
             navigational: Double? = nil, leaderOwnsTerm: Bool? = nil, nameCrowd: Bool? = nil) -> IdeaGap {
        IdeaGap(term: term, normalized: KeywordText.normalize(term), difficulty: difficulty, brand: brand, natural: natural, appable: appable,
                navigational: navigational, leaderOwnsTerm: leaderOwnsTerm, nameCrowd: nameCrowd)
    }

    @Test("Free-seekers are no lead in any language")
    func free() {
        #expect(gap("pdf editor free").wantsFree)
        #expect(gap("ücretsiz pdf").wantsFree)
        #expect(gap("無料漫画").wantsFree)
        #expect(!gap("freelance invoice").wantsFree)
    }

    @Test("Each signal can rule a gap out; unknowns do not")
    func rules() {
        #expect(gap("plant care").isGap(maxDifficulty: 45))
        #expect(!gap("plant care", difficulty: nil).isGap(maxDifficulty: 45))
        #expect(!gap("plant care", difficulty: 46).isGap(maxDifficulty: 45))
        #expect(!gap("plant care", brand: 0.5).isGap(maxDifficulty: 45))
        #expect(!gap("plant care", natural: 0.4).isGap(maxDifficulty: 45))
        #expect(!gap("plant care", appable: 0.4).isGap(maxDifficulty: 45))
        #expect(!gap("plant care", navigational: 0.6).isGap(maxDifficulty: 45))
        #expect(!gap("plant care", leaderOwnsTerm: true).isGap(maxDifficulty: 45))
        #expect(!gap("plant care", nameCrowd: true).isGap(maxDifficulty: 45))
        #expect(!gap("plant care free").isGap(maxDifficulty: 45))
    }

    @Test("Result flags: a dominant namesake owns the term, a crowded single word is a name")
    func flags() {
        let owned = IdeaGap.resultFlags(term: "koupon", normalized: "koupon", leaderName: "Koupon: Real Deals", leaderRatings: 50,
                                        medianRatings: 10, titleMatches: 1)
        #expect(owned.leaderOwnsTerm)
        let crowded = IdeaGap.resultFlags(term: "notes", normalized: "notes", leaderName: "Bear", leaderRatings: 900, medianRatings: 100,
                                          titleMatches: 9)
        #expect(!crowded.leaderOwnsTerm)
        #expect(crowded.nameCrowd)
        #expect(!IdeaGap.resultFlags(term: "sticky notes", normalized: "sticky notes", leaderName: "Bear", leaderRatings: 900,
                                     medianRatings: 100, titleMatches: 9).nameCrowd)
    }
}
