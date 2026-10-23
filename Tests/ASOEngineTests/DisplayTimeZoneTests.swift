import Foundation
import Testing
@testable import ASOCommands

@Suite("Display time zone")
struct DisplayTimeZoneTests {
    let gmt = TimeZone(secondsFromGMT: 0)!

    @Test("Plain GMT from Foundation gives way to the system's offset")
    func gmtFallsBackToSystemOffset() {
        #expect(DisplayTimeZone.resolve(foundation: gmt, systemOffsetSeconds: 3 * 3600).secondsFromGMT() == 3 * 3600)
        #expect(DisplayTimeZone.resolve(foundation: gmt, systemOffsetSeconds: -5 * 3600).secondsFromGMT() == -5 * 3600)
    }

    @Test("A real zone from Foundation, or no system offset, is kept")
    func foundationKept() throws {
        let plusOne = try #require(TimeZone(secondsFromGMT: 3600))
        #expect(DisplayTimeZone.resolve(foundation: plusOne, systemOffsetSeconds: 0) == plusOne)
        #expect(DisplayTimeZone.resolve(foundation: gmt, systemOffsetSeconds: nil) == gmt)
        #expect(DisplayTimeZone.resolve(foundation: gmt, systemOffsetSeconds: 0) == gmt)
    }

    @Test("Only Windows reads the offset from the system")
    func systemOffsetSource() {
        #if os(Windows)
        #expect(DisplayTimeZone.systemOffsetSeconds != nil)
        #else
        #expect(DisplayTimeZone.systemOffsetSeconds == nil)
        #endif
    }
}
