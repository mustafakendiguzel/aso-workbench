import Foundation
import Testing
import ASOCore
@testable import ASOCommands
@testable import ASOEngine

/// GitHub without the network: one canned latest release, or none.
struct FakeReleases: ReleaseSource {
    var release: ReleaseCheck.Release?

    func latest(repository: String, currentVersion: String, platform: ReleaseCheck.Platform) async throws -> ReleaseCheck.Release? { release }
}

@Suite("Updates and backups")
struct UpdatesTests {
    static let newer = ReleaseCheck.Release(version: "1.2.0", title: "ASO Workbench 1.2.0", notes: "### Added\n- Windows.",
                                            pageURL: "https://github.com/acme/aso/releases/tag/v1.2.0",
                                            downloadURL: "https://github.com/acme/aso/releases/download/v1.2.0/aso-workbench-windows-x86_64.zip",
                                            publishedAt: nil)

    @Test("A newer release is offered; a skipped one only when the user asks; none published is current")
    func check() async throws {
        let source = FakeReleases(release: Self.newer)
        let asked = try await Engine.checkForUpdate(source: source, current: "1.0.0", skipped: "1.2.0", userInitiated: true)
        #expect(asked.available)
        #expect(asked.release?.version == "1.2.0")
        let automatic = try await Engine.checkForUpdate(source: source, current: "1.0.0", skipped: "1.2.0", userInitiated: false)
        #expect(!automatic.available)
        #expect(automatic.skipped)
        let current = try await Engine.checkForUpdate(source: source, current: "1.2.0")
        #expect(!current.available && current.release == nil && current.latest == "1.2.0")
        let none = try await Engine.checkForUpdate(source: FakeReleases(release: nil), current: "1.0.0")
        #expect(none.latest == nil && !none.available)
    }

    @Test("The commands check, skip a version and respect automatic checks being off")
    func commands() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let console = Console()
        let runner = CommandRunner(environment: ["ASO_DATA_DIR": folder.path], output: { console.write($0) }, errors: { console.writeError($0) },
                                   releases: FakeReleases(release: Self.newer)) { _ in try makeEngine() }
        #expect(await runner.run(["update", "check"]) == 0)
        #expect(console.output.contains("Version 1.2.0 is available (you have \(EngineEnvironment.version)): ASO Workbench 1.2.0"))
        #expect(console.output.contains("Download: https://github.com/acme/aso/releases/download/v1.2.0/aso-workbench-windows-x86_64.zip"))
        #expect(await runner.run(["update", "skip", "1.2.0"]) == 0)
        #expect(try EngineSettings.load(from: folder).skippedVersion == "1.2.0")
        #expect(await runner.run(["update", "check", "--automatic"]) == 0)
        #expect(console.output.contains("you chose to skip it"))
        #expect(await runner.run(["settings", "set", "checkForUpdates", "false"]) == 0)
        #expect(await runner.run(["--json", "update", "check", "--automatic"]) == 0)
        #expect(console.output.contains("\"available\" : false"))
        #expect(await runner.run(["update", "skip", "soon"]) == 64)
    }

    @Test("A data file from an older schema is copied to Backups before it is migrated; the newest five are kept")
    func backup() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("engine.sqlite")
        do {
            let db = try Database(path: url.path)
            for step in Store.migrations.prefix(8) { try db.execute(step) }
            try db.setUserVersion(8)
            try db.query("INSERT INTO apps (track_id, name, seller_name, created_at) VALUES (1, 'Acme', 'Acme Inc', 0)")
        }
        _ = try Store(url: url)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Backups").path)
        #expect(backups.count == 1)
        #expect(backups[0].hasSuffix("schema-8.sqlite"))
        let copy = try Database(path: folder.appendingPathComponent("Backups").appendingPathComponent(backups[0]).path)
        #expect(try copy.userVersion == 8)

        // An up-to-date file is opened without a copy.
        _ = try Store(url: url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Backups").path).count == 1)

        let db = try Database(path: url.path)
        for day in 1...7 {
            try Store.backUp(db, schema: 9, next: folder.appendingPathComponent("Backups"), now: Date(timeIntervalSince1970: Double(day) * 86_400))
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Backups").path).sorted()
        // Today's copy and the four latest of the seven: the oldest go.
        #expect(kept.count == 5)
        #expect(kept.contains { $0.hasPrefix("engine 1970-01-08") })
        #expect(!kept.contains { $0.hasPrefix("engine 1970-01-04") })
    }
}
