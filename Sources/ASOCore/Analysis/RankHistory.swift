import Foundation

/// One stored rank measurement, reduced to what history comparisons need.
public struct RankPoint: Sendable, Hashable {
    public let fetchedAt: Date
    public let outcome: RankOutcome
    public let provider: ProviderID

    public init(fetchedAt: Date, outcome: RankOutcome, provider: ProviderID) {
        self.fetchedAt = fetchedAt
        self.outcome = outcome
        self.provider = provider
    }

    /// The request went through and the app was looked for (found or outside the observed range).
    public var isMeasured: Bool {
        switch outcome {
        case .found, .outsideObservedRange: true
        case .requestFailed, .notChecked: false
        }
    }

    /// How many results the provider returned; 0 when nothing was observed.
    public var observedCount: Int {
        switch outcome {
        case .found(_, let n), .outsideObservedRange(let n): n
        case .requestFailed, .notChecked: 0
        }
    }

    /// Position for comparisons: "not in top N" counts as N + 1, so entering or leaving the results still moves the number.
    public var comparablePosition: Int { outcome.position ?? observedCount + 1 }
}

/// A dated point to compare ranks around.
public struct Marker: Hashable, Sendable {
    public let date: Date
    public let title: String
    /// "release" · "note" · "change"
    public let kind: String

    public init(date: Date, title: String, kind: String) {
        self.date = date
        self.title = title
        self.kind = kind
    }
}

/// What the Δ column compares the latest rank against.
public enum DeltaReference: String, CaseIterable, Identifiable, Sendable {
    case lastMarker, previous, first, week
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lastMarker: "since last release or change"
        case .previous: "vs previous measurement"
        case .first: "since first measurement"
        case .week: "vs 7 days ago"
        }
    }
}

/// Rank history of one keyword in one market. Generic over the stored record so the app's persistence types and plain
/// values share one implementation; `point` reads what the comparisons need from each record.
public struct RankHistory<Element> {
    private let entries: [(element: Element, point: RankPoint)]

    public init(_ elements: [Element], point: (Element) -> RankPoint) {
        entries = elements.map { ($0, point($0)) }
    }

    /// Measurements whose request succeeded, oldest first.
    public var successful: [Element] { successfulEntries.map(\.element) }

    /// Latest measurement whose request actually succeeded (found or outside range).
    public var latestMeasured: Element? { latestMeasuredEntry?.element }

    /// Previous non-failed measurement from the *same provider* as the latest one.
    public var previousMeasured: Element? { previousMeasuredEntry?.element }

    /// Rank delta vs the previous measurement; positive means improved. Nil when not comparable.
    public var rankDelta: Int? {
        guard let a = latestMeasuredEntry?.point.outcome.position, let b = previousMeasuredEntry?.point.outcome.position else { return nil }
        return b - a
    }

    /// Last successful measurement at or before `date` and the latest one after it (nil when either side is missing).
    public func beforeAfter(_ date: Date) -> (before: Element, after: Element)? {
        beforeAfterEntries(date).map { ($0.before.element, $0.after.element) }
    }

    /// Rank movement against a chosen reference, with a description of what it was compared against. Positive = moved up.
    public func delta(reference: DeltaReference, markers: [Marker]) -> (delta: Int?, against: String) {
        let all = successfulEntries.map(\.point)
        guard let latest = all.last else { return (nil, "no measurement") }
        switch reference {
        case .previous:
            guard let delta = rankDelta else { return (nil, "previous measurement") }
            return (delta, "previous measurement")
        case .first:
            guard let first = all.first, first.fetchedAt < latest.fetchedAt else { return (nil, "first measurement") }
            return (first.comparablePosition - latest.comparablePosition, "first measurement \(Self.day(first.fetchedAt))")
        case .week:
            let cutoff = latest.fetchedAt.addingTimeInterval(-7 * 86_400)
            guard let ref = all.last(where: { $0.fetchedAt <= cutoff }) else { return (nil, "7 days ago") }
            return (ref.comparablePosition - latest.comparablePosition, "7 days ago (\(Self.day(ref.fetchedAt)))")
        case .lastMarker:
            guard let marker = markers.last(where: { $0.date < latest.fetchedAt }) else {
                guard let first = all.first, first.fetchedAt < latest.fetchedAt else { return (nil, "no release or change yet") }
                return (first.comparablePosition - latest.comparablePosition, "first measurement (no release or change recorded)")
            }
            guard let pair = beforeAfterEntries(marker.date) else { return (nil, "no measurement before \(marker.title)") }
            return (pair.before.point.comparablePosition - pair.after.point.comparablePosition, "\(marker.title) · \(Self.day(marker.date))")
        }
    }

    private var successfulEntries: [(element: Element, point: RankPoint)] {
        entries.filter { $0.point.isMeasured }.sorted { $0.point.fetchedAt < $1.point.fetchedAt }
    }

    private var latestMeasuredEntry: (element: Element, point: RankPoint)? {
        entries.filter { $0.point.isMeasured }.max { $0.point.fetchedAt < $1.point.fetchedAt }
    }

    private var previousMeasuredEntry: (element: Element, point: RankPoint)? {
        guard let latest = latestMeasuredEntry?.point else { return nil }
        return entries
            .filter { !$0.point.outcome.isFailure && $0.point.provider == latest.provider && $0.point.fetchedAt < latest.fetchedAt }
            .max { $0.point.fetchedAt < $1.point.fetchedAt }
    }

    private func beforeAfterEntries(_ date: Date) -> (before: (element: Element, point: RankPoint), after: (element: Element, point: RankPoint))? {
        let all = successfulEntries
        guard let before = all.last(where: { $0.point.fetchedAt <= date }), let after = all.last, after.point.fetchedAt > date else { return nil }
        return (before, after)
    }

    private static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
}

extension RankHistory where Element == RankPoint {
    public init(_ points: [RankPoint]) { self.init(points) { $0 } }
}

extension RankHistory: Sendable where Element: Sendable {}
