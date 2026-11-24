import Foundation
import ASOCore
@testable import ASOEngine

/// App Store search without the network: canned results per term, terms that fail, apps by ID.
struct FakeSearch: SearchRankProvider {
    let id: ProviderID = "fake-search"
    var results: [String: [SearchResultApp]] = [:]
    var failing: Set<String> = []
    var apps: [Int: SearchResultApp] = [:]

    func search(term: String, storefront: Storefront, device: DeviceContext, limit: Int) async throws -> [SearchResultApp] {
        if failing.contains(term) { throw ASOError.network("offline") }
        return Array((results[term] ?? []).prefix(limit))
    }

    func lookup(term: String, storefront: Storefront, limit: Int) async throws -> [SearchResultApp] {
        Array(apps.values.filter { $0.name.localizedCaseInsensitiveContains(term) }.prefix(limit))
    }

    func lookup(trackID: Int, storefront: Storefront) async throws -> SearchResultApp? { apps[trackID] }
}

struct FakeSuggestions: SuggestionProvider {
    let id: ProviderID = "fake-hints"
    var hints: [String: [String]] = [:]

    func suggestions(seed: String, storefront: Storefront) async throws -> [KeywordSuggestion] {
        (hints[seed] ?? []).enumerated().map {
            KeywordSuggestion(text: $1, provider: id, origin: .publicSearchObserved, popularity: nil, position: $0 + 1, fetchedAt: Date())
        }
    }
}

func makeApp(_ id: Int, _ name: String, seller: String? = nil, ratings: Int? = 100) -> SearchResultApp {
    SearchResultApp(trackID: id, bundleID: "com.example.\(id)", name: name, sellerName: seller ?? "Seller \(id)", iconURL: nil,
                    averageRating: 4.5, ratingCount: ratings, primaryGenre: "Productivity", releaseDate: nil, currentVersionReleaseDate: nil,
                    price: 0, version: "1.0")
}

let ownApp = makeApp(1_000_001, "Acme Notes", seller: "Acme Inc")

func makeEngine(search: FakeSearch = FakeSearch(apps: [ownApp.trackID: ownApp]), hints: FakeSuggestions = FakeSuggestions()) throws -> Engine {
    Engine(store: try Store.inMemory(), search: search, suggestions: hints)
}

/// A fresh folder under the system temporary directory, removed by the caller.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aso-engine-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
