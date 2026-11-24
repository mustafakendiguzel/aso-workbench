import Foundation

/// What a rank movement around a release or change is worth: each keyword is weighted by its value (popularity ×
/// beatable difficulty × fit), and a move counts by how much visibility it gains or loses on a rough App Store curve.
/// A jump on a worthless term counts for nothing; a few places on a valuable one counts a lot.
public enum KeywordImpact {
    public enum Tier: String, Sendable, Codable, CaseIterable {
        case high = "High", medium = "Medium", low = "Low", none = "None"

        /// The lowest value in the tier.
        public var threshold: Double {
            switch self {
            case .high: 40
            case .medium: 15
            case .low: 0.01
            case .none: 0
            }
        }
    }

    /// Share of searchers (0–100) who see a result at this position; 0 when the app was not in the results.
    public static func visibility(_ rank: Int?) -> Double {
        guard let r = rank, r >= 1 else { return 0 }
        switch r {
        case 1: return 100
        case 2: return 90
        case 3: return 80
        case 4...5: return 65
        case 6...10: return 50
        case 11...20: return 25
        case 21...50: return 8
        case 51...100: return 2
        default: return 0.5
        }
    }

    /// 0–100: how much ranking for the term is worth. 0 for brands, unrelated terms (fit below one half) and terms
    /// without popularity. An unmeasured difficulty counts as 50 and an unchecked fit as 0.8.
    public static func value(popularity: Int?, difficulty: Double?, isBrandLike: Bool, fit: Double?) -> Double {
        let fitFactor: Double = isBrandLike ? 0 : (fit.map { $0 >= 0.5 ? 1 : 0 } ?? 0.8)
        let d = difficulty ?? 50
        return Double(popularity ?? 0) * (1 - (d / 100) * (d / 100)) * fitFactor
    }

    /// Value gained (positive) or lost by moving from `before` to `after` (nil: not in the results).
    public static func gain(before: Int?, after: Int?, value: Double) -> Double {
        (visibility(after) - visibility(before)) * value / 100
    }

    public static func tier(_ value: Double) -> Tier {
        value >= Tier.high.threshold ? .high : value >= Tier.medium.threshold ? .medium : value > 0 ? .low : .none
    }
}
