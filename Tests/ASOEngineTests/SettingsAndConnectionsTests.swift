import Foundation
import Testing
import ASOCore
import ASOProviders
@testable import ASOCommands
@testable import ASOEngine

// Throwaway key generated for the tests only.
private let testPEM = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----
"""
private let testFingerprint = "a40f0f2e2974dc76"

@Suite("Engine settings")
struct EngineSettingsTests {
    @Test("Defaults match the macOS app")
    func defaults() {
        let s = EngineSettings()
        #expect((s.resultDepth, s.pacingSeconds, s.staleHours, s.autoMeasureOnLaunch) == (200, 3.1, 20, false))
        #expect((s.goldenMinPopularity, s.goldenMaxDifficulty, s.writerEasyDifficulty, s.writerMaxDifficulty) == (30, 45, 35, 55))
        #expect(s.deltaReference == .lastMarker)
        #expect(s.golden == .standard)
    }

    @Test("Values are checked against the app's ranges")
    func ranges() throws {
        var s = EngineSettings()
        try s.set("resultDepth", to: "100")
        try s.set("PACINGSECONDS", to: "2.5")
        try s.set("deltaReference", to: "week")
        try s.set("autoMeasureOnLaunch", to: "TRUE")
        try s.set("adsReferenceAppID", to: "")
        #expect((s.resultDepth, s.pacingSeconds, s.deltaReference, s.autoMeasureOnLaunch) == (100, 2.5, .week, true))
        for (name, value) in [("resultDepth", "150"), ("pacingSeconds", "0.5"), ("staleHours", "100"), ("deltaReference", "yesterday"),
                              ("autoMeasureOnLaunch", "maybe"), ("adsReferenceAppID", "abc"), ("writerModel", "two words"), ("colour", "red")] {
            #expect(throws: EngineError.self, "\(name)=\(value)") { try s.set(name, to: value) }
        }
        #expect(s.resultDepth == 100)
    }

    @Test("A missing file gives the defaults; saved values come back; unknown or bad entries keep their defaults")
    func file() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try EngineSettings.load(from: folder) == EngineSettings())

        var s = EngineSettings()
        s.staleHours = 48
        try s.save(to: folder)
        #expect(try EngineSettings.load(from: folder).staleHours == 48)

        try Data(#"{"staleHours": 12, "resultDepth": "lots", "futureSetting": true}"#.utf8).write(to: EngineSettings.url(in: folder))
        let tolerant = try EngineSettings.load(from: folder)
        #expect(tolerant.staleHours == 12)
        #expect(tolerant.resultDepth == 200)

        try Data("not json".utf8).write(to: EngineSettings.url(in: folder))
        #expect(throws: EngineError.self) { try EngineSettings.load(from: folder) }
    }
}

@Suite("Credentials and connections")
struct ConnectionsTests {
    @Test("Keys round-trip in the macOS app's shape and unknown entries survive")
    func storeShape() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CredentialStore(directory: folder)
        try Data(#"{"ads-session-cookies": [{"Name": "myacinfo"}]}"#.utf8).write(to: store.fileURL)

        try Connections.saveAppleAds(clientID: " SEARCHADS.abc\n", keyID: "K1", orgID: "42", privateKeyPEM: testPEM, in: store)
        try Connections.saveOpenRouterKey("sk-or-v1-test\n", in: store)
        #expect(try Connections.saveRevenueCatKeys("sk_a\n\nsk_b, sk_a", in: store) == 2)

        // Through CredentialFile: on Windows the file on disk is encrypted.
        let json = try JSONSerialization.jsonObject(with: CredentialFile.read(store.fileURL)) as? [String: Any]
        #expect(json?["ads-session-cookies"] != nil)
        #expect((json?["apple-ads"] as? [String: Any])?["clientID"] as? String == "SEARCHADS.abc")
        #expect((json?["openrouter"] as? [String: Any])?["apiKey"] as? String == "sk-or-v1-test")
        #expect(try store.revenueCatKeys() == ["sk_a", "sk_b"])

        #expect(try store.remove(.openRouter))
        #expect(try store.remove(.openRouter) == false)
        #expect(try store.openRouterKey() == nil)
    }

    @Test("The key file is readable only by its owner")
    func permissions() throws {
        #if !os(Windows)
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CredentialStore(directory: folder.appendingPathComponent("data"))
        try Connections.saveOpenRouterKey("sk-or-v1-test", in: store)
        let file = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        let dir = try FileManager.default.attributesOfItem(atPath: store.fileURL.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(file == 0o600)
        #expect(dir == 0o700)
        #endif
    }

    @Test("On Windows the key file is encrypted for the user; older plain files still load and are encrypted on the next save")
    func windowsEncryption() throws {
        #if os(Windows)
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CredentialStore(directory: folder)
        try Data(#"{"openrouter": {"apiKey": "sk-or-v1-plain"}}"#.utf8).write(to: store.fileURL)
        #expect(try store.openRouterKey() == "sk-or-v1-plain")

        try Connections.saveOpenRouterKey("sk-or-v1-secret", in: store)
        let onDisk = try Data(contentsOf: store.fileURL)
        #expect(onDisk.starts(with: CredentialFile.protectedPrefix))
        #expect(!String(decoding: onDisk, as: UTF8.self).contains("sk-or-v1"))
        #expect(try store.openRouterKey() == "sk-or-v1-secret")

        var tampered = onDisk
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: store.fileURL)
        #expect(throws: EngineError.self) { try store.openRouterKey() }
        #endif
    }

    @Test("Status shows identifiers and the fingerprint, never a key")
    func status() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CredentialStore(directory: folder)
        #expect(try Connections.status(store).allSatisfy { !$0.configured })

        try Connections.saveAppleAds(clientID: "SEARCHADS.abc", keyID: "K1", orgID: "42", privateKeyPEM: testPEM, in: store)
        try Connections.saveAppStoreConnect(keyID: nil, issuerID: "issuer", privateKeyPEM: testPEM, keyFileName: "/keys/AuthKey_2X9R4HXF34.p8", in: store)
        try Connections.saveOpenRouterKey("sk-or-v1-secret", in: store)
        let all = try Connections.status(store)
        let ads = try #require(all.first { $0.service == "apple-ads" })
        #expect(ads.details == ["clientID": "SEARCHADS.abc", "keyID": "K1", "orgID": "42", "keyFingerprint": testFingerprint])
        let asc = try #require(all.first { $0.service == "asc" })
        #expect(asc.details["keyID"] == "2X9R4HXF34")
        let encoded = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE KEY"))
        #expect(!encoded.contains("sk-or-v1-secret"))
    }

    @Test("Incomplete or invalid keys are refused before anything is stored")
    func validation() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CredentialStore(directory: folder)
        #expect(throws: (any Error).self) {
            try Connections.saveAppleAds(clientID: "c", keyID: "k", orgID: "o", privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nbad\n-----END PRIVATE KEY-----", in: store)
        }
        #expect(throws: EngineError.self) { try Connections.saveAppleAds(clientID: "", keyID: "k", orgID: "o", privateKeyPEM: testPEM, in: store) }
        #expect(throws: EngineError.self) {
            try Connections.saveAppStoreConnect(keyID: nil, issuerID: "i", privateKeyPEM: testPEM, keyFileName: "key.p8", in: store)
        }
        #expect(throws: EngineError.self) { try Connections.saveOpenRouterKey("two words", in: store) }
        #expect(throws: EngineError.self) { _ = try Connections.saveRevenueCatKeys(" ,\n", in: store) }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(Connections.keyID(fromFileName: "/downloads/AuthKey_ABC123.p8") == "ABC123")
        #expect(Connections.keyID(fromFileName: "key.p8") == nil)
    }

    @Test("Verifying a service without keys says it is not connected")
    func verifyWithoutKeys() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for service in CredentialStore.Service.allCases {
            await #expect(throws: ASOError.notConfigured(service: service.title)) {
                try await Connections.verify(service, store: CredentialStore(directory: folder))
            }
        }
    }
}

@Suite("Stale markets")
struct StaleMarketTests {
    @Test("Only markets with keywords measured before the threshold, or never, are measured again")
    func staleOnly() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var search = FakeSearch(apps: [ownApp.trackID: ownApp])
        search.results = ["old": [ownApp], "never": [ownApp], "fresh": [ownApp]]
        let engine = try makeEngine(search: search)
        _ = try await engine.addApp(reference: String(ownApp.trackID))
        for (term, country) in [("old", "US"), ("never", "DE"), ("fresh", "GB")] {
            _ = try await engine.addKeywords([term], appID: ownApp.trackID, countryCode: country, device: .iPhone)
        }
        _ = try await engine.store.market(appID: ownApp.trackID, countryCode: "FR", device: .iPhone)   // no keywords: skipped
        func observe(_ term: String, _ country: String, hoursAgo: Double) async throws {
            let market = try await engine.store.market(appID: ownApp.trackID, countryCode: country, device: .iPhone)
            let keyword = try #require(try await engine.store.keywords(marketID: market.id).first)
            try await engine.store.addObservation(RankSample(keyword: term, storefront: country, device: .iPhone, provider: "fake-search",
                                                             outcome: .requestFailed(reason: "x"), fetchedAt: now.addingTimeInterval(-hoursAgo * 3600),
                                                             results: []), keywordID: keyword.id)
        }
        try await observe("old", "US", hoursAgo: 30)
        try await observe("fresh", "GB", hoursAgo: 2)

        let steps = Steps()
        let summary = try await engine.measureStale(staleHours: 20, now: now) { steps.append($0) }
        #expect(summary.measured == 2)
        #expect(Set(steps.all.map(\.keyword)) == ["old", "never"])
    }
}

@Suite("aso settings and connections")
struct SettingsCommandTests {
    /// Commands against one data folder (settings, keys) and one in-memory engine (apps, keywords).
    struct Session {
        let folder: URL
        let engine: Engine

        init() throws {
            folder = try temporaryDirectory()
            engine = try makeEngine()
        }

        func run(_ arguments: [String], stdin: String = "") async -> (code: Int32, console: Console) {
            let console = Console()
            let engine = self.engine
            let runner = CommandRunner(environment: ["ASO_DATA_DIR": folder.path], output: { console.write($0) },
                                       errors: { console.writeError($0) }, input: { stdin }) { _ in engine }
            return (await runner.run(arguments), console)
        }
    }

    @Test("settings shows, sets, rejects and resets")
    func settings() async throws {
        let session = try Session()
        let folder = session.folder
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ arguments: [String]) async -> (code: Int32, console: Console) { await session.run(arguments) }
        #expect(await run(["settings"]).console.output.contains("resultDepth"))
        #expect(await run(["settings", "set", "staleHours", "36"]).code == 0)
        #expect(try EngineSettings.load(from: folder).staleHours == 36)

        let bad = await run(["settings", "set", "staleHours", "1000"])
        #expect(bad.code == CommandRunner.ExitCode.usage)
        #expect(bad.console.errors.contains("staleHours must be 6 to 72"))

        let json = await run(["settings", "--json"])
        #expect(json.console.output.contains("\"staleHours\" : 36"))
        #expect(await run(["settings", "reset"]).code == 0)
        #expect(try EngineSettings.load(from: folder) == EngineSettings())
    }

    @Test("Keys come from stdin or a file, never from arguments, and are never printed")
    func connections() async throws {
        let session = try Session()
        let folder = session.folder
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ arguments: [String], stdin: String = "") async -> (code: Int32, console: Console) { await session.run(arguments, stdin: stdin) }
        let saved = await run(["connections", "set", "openrouter", "--key-stdin"], stdin: "sk-or-v1-secret\n")
        #expect(saved.code == 0)
        #expect(!saved.console.output.contains("sk-or-v1-secret"))

        let keyFile = folder.appendingPathComponent("AuthKey_ABC123.p8")
        try Data(testPEM.utf8).write(to: keyFile)
        let asc = await run(["connections", "set", "asc", "--issuer-id", "issuer", "--key-file", keyFile.path, "--json"])
        #expect(asc.code == 0)
        #expect(asc.console.output.contains("\"keyID\" : \"ABC123\""))
        #expect(asc.console.output.contains(testFingerprint))

        let missing = await run(["connections", "set", "apple-ads", "--client-id", "c", "--key-id", "k", "--org-id", "o"])
        #expect(missing.code == CommandRunner.ExitCode.usage)
        #expect(await run(["connections", "set", "apple-ads", "--key", "inline"]).code == CommandRunner.ExitCode.usage)

        let status = await run(["connections", "--json"])
        #expect(!status.console.output.contains("sk-or-v1-secret"))
        #expect(!status.console.output.contains("PRIVATE KEY"))

        let removed = await run(["connections", "remove", "openrouter"])
        #expect(removed.console.output == "Removed the OpenRouter keys.")
        #expect(await run(["connections", "verify", "nonsense"]).code == CommandRunner.ExitCode.usage)
        let verify = await run(["connections", "verify", "openrouter"])
        #expect(verify.code == CommandRunner.ExitCode.failure)
        #expect(verify.console.errors.contains("OpenRouter is not connected"))
    }

    @Test("keywords list uses the stored Δ reference unless --delta says otherwise")
    func deltaFromSettings() async throws {
        let session = try Session()
        defer { try? FileManager.default.removeItem(at: session.folder) }
        let id = String(ownApp.trackID)
        _ = await session.run(["settings", "set", "deltaReference", "week"])
        _ = await session.run(["app", "add", id])
        _ = await session.run(["keywords", "add", id, "notes", "--country", "US"])
        #expect(await session.run(["keywords", "list", id]).console.output.contains("vs 7 days ago"))
        #expect(await session.run(["keywords", "list", id, "--delta", "first"]).console.output.contains("since first measurement"))
    }
}
