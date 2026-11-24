import Testing
@testable import ASOCore

@Suite("RevenueCat project matching")
struct RevenueMatchTests {
    struct Project { let name: String; let bundles: [String]; let apps: [String] }

    let projects = [
        Project(name: "Acme", bundles: ["com.acme.notes", "com.acme.diary"], apps: ["Acme Notes", "Acme Diary"]),
        Project(name: "Side Projects", bundles: ["com.other.app"], apps: ["Notes Pro"]),
    ]

    func select(bundle: String?, name: String) -> ([String], RevenueMatch.Kind?) {
        let result = RevenueMatch.select(projects, bundleID: bundle, appName: name, bundleIDs: \.bundles, projectName: \.name, appNames: \.apps)
        return (result.matches.map(\.name), result.kind)
    }

    @Test("The bundle ID wins over names")
    func bundleFirst() {
        #expect(select(bundle: "com.acme.notes", name: "Notes Pro") == (["Acme"], .bundleID))
    }

    @Test("Without a bundle match, the name before the colon is looked for in project and app names, ignoring case and spaces")
    func nameNext() {
        #expect(select(bundle: "com.unknown", name: "NotesPro: Quick Notes") == (["Side Projects"], .name))
        #expect(select(bundle: nil, name: "acme diary") == (["Acme"], .name))
        #expect(select(bundle: "", name: "Weather") == ([], nil))
        #expect(select(bundle: nil, name: ": no name") == ([], nil))
    }
}
