import Foundation
#if os(Windows)
import WinSDK
#endif

/// The time zone dates are shown in. Foundation on Windows (seen with Swift 6.4.1) reports GMT whatever the system's
/// zone is; there the system's current offset from UTC is used instead, for as long as Foundation reports plain GMT.
enum DisplayTimeZone {
    static var current: TimeZone { resolve(foundation: .current, systemOffsetSeconds: systemOffsetSeconds) }

    /// Foundation's zone, unless it is plain GMT/UTC while the system reports a different offset.
    static func resolve(foundation: TimeZone, systemOffsetSeconds: Int?) -> TimeZone {
        guard let offset = systemOffsetSeconds, offset != foundation.secondsFromGMT(),
              ["GMT", "UTC"].contains(foundation.identifier) else { return foundation }
        return TimeZone(secondsFromGMT: offset) ?? foundation
    }

    /// The system's current offset from UTC in seconds, where Foundation cannot be trusted to read it; nil elsewhere.
    static var systemOffsetSeconds: Int? {
        #if os(Windows)
        var info = DYNAMIC_TIME_ZONE_INFORMATION()
        let state = GetDynamicTimeZoneInformation(&info)
        // Bias is in minutes and counts the other way (UTC = local time + bias).
        var bias = Int(info.Bias)
        switch state {
        case DWORD(TIME_ZONE_ID_STANDARD): bias += Int(info.StandardBias)
        case DWORD(TIME_ZONE_ID_DAYLIGHT): bias += Int(info.DaylightBias)
        case DWORD(TIME_ZONE_ID_UNKNOWN): break
        default: return nil
        }
        return -bias * 60
        #else
        return nil
        #endif
    }
}
