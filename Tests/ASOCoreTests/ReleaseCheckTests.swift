import Foundation
import Testing
@testable import ASOCore

@Suite("Release check")
struct ReleaseCheckTests {
    static let json = Data(#"""
    {"tag_name":"v1.2.0","name":"ASO Workbench 1.2.0","body":"### Added\n- Windows and Linux.","html_url":"https://github.com/acme/aso/releases/tag/v1.2.0",
     "published_at":"2026-11-20T10:00:00Z","assets":[
      {"name":"ASO-Workbench-1.2.0.zip","browser_download_url":"https://github.com/acme/aso/releases/download/v1.2.0/ASO-Workbench-1.2.0.zip"},
      {"name":"ASO-Workbench-1.2.0.dmg","browser_download_url":"https://github.com/acme/aso/releases/download/v1.2.0/ASO-Workbench-1.2.0.dmg"},
      {"name":"aso-windows-x86_64.zip","browser_download_url":"https://github.com/acme/aso/releases/download/v1.2.0/aso-windows-x86_64.zip"},
      {"name":"aso-workbench-windows-x86_64.zip","browser_download_url":"https://github.com/acme/aso/releases/download/v1.2.0/aso-workbench-windows-x86_64.zip"},
      {"name":"aso-linux-x86_64.tar.gz","browser_download_url":"https://github.com/acme/aso/releases/download/v1.2.0/aso-linux-x86_64.tar.gz"},
      {"name":"evil.zip","browser_download_url":"https://example.com/evil.zip"}]}
    """#.utf8)

    @Test("The release, its notes and the package for each platform are read")
    func parse() throws {
        let mac = try ReleaseCheck.parse(Self.json, repository: "acme/aso", platform: .macOS)
        #expect(mac.version == "1.2.0")
        #expect(mac.title == "ASO Workbench 1.2.0")
        #expect(mac.notes.hasPrefix("### Added"))
        #expect(mac.downloadURL?.hasSuffix(".dmg") == true)
        #expect(mac.publishedAt == ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z"))
        #expect(try ReleaseCheck.parse(Self.json, repository: "acme/aso", platform: .windows).downloadURL?.hasSuffix("/aso-workbench-windows-x86_64.zip") == true)
        // Without the window's package, the command line's.
        #expect(try ReleaseCheck.parse(Self.json, repository: "acme/aso", platform: .linux).downloadURL?.hasSuffix("/aso-linux-x86_64.tar.gz") == true)
        #expect(throws: ASOError.self) { try ReleaseCheck.parse(Data("{}".utf8), repository: "acme/aso") }
    }

    @Test("Only newer releases are offered, and a skipped one only when asked for")
    func offer() throws {
        let release = try ReleaseCheck.parse(Self.json, repository: "acme/aso")
        #expect(ReleaseCheck.shouldOffer(release, current: "1.0.0", skipped: nil, userInitiated: false))
        #expect(!ReleaseCheck.shouldOffer(release, current: "1.2.0", skipped: nil, userInitiated: true))
        #expect(!ReleaseCheck.shouldOffer(release, current: "1.0.0", skipped: "1.2.0", userInitiated: false))
        #expect(ReleaseCheck.shouldOffer(release, current: "1.0.0", skipped: "1.2.0", userInitiated: true))
    }

    @Test("Only GitHub addresses are opened")
    func gitHubOnly() {
        #expect(ReleaseCheck.isGitHub("https://github.com/acme/aso/releases"))
        #expect(ReleaseCheck.isGitHub("https://objects.githubusercontent.com/file"))
        #expect(!ReleaseCheck.isGitHub("http://github.com/acme"))
        #expect(!ReleaseCheck.isGitHub("https://github.com.example.com/x"))
        #expect(!ReleaseCheck.isGitHub("https://example.com/evil.zip"))
    }
}
