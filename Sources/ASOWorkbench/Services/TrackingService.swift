import Foundation
import Observation
import SwiftData
import ASOCore
import ASOProviders

/// Runs rank measurements sequentially with pacing and persists one observation
/// per keyword, including failures. Cache is never consulted: every observation is a fresh request.
@Observable
final class TrackingService {
    struct Progress: Equatable {
        var isRunning = false
        var completed = 0
        var total = 0
        var currentKeyword = ""
        var failures = 0
        var lastError: String?
    }

    private(set) var progress = Progress()
    /// Keywords covered by the most recent run (used to refresh popularity for just those).
    private(set) var lastRunKeywordIDs: Set<PersistentIdentifier> = []
    private let provider: any SearchRankProvider
    private let settings: AppSettings
    private var task: Task<Void, Never>?

    init(provider: any SearchRankProvider, settings: AppSettings) {
        self.provider = provider
        self.settings = settings
    }

    /// Measures the given keywords (all belonging to `market`). Returns when done or cancelled.
    func measure(_ keywords: [TrackedKeyword], in market: TrackedMarket, context: ModelContext) {
        guard !progress.isRunning, let storefront = market.storefront, let app = market.app else { return }
        let device = market.device
        let ownTrackID = app.trackID
        let depth = settings.resultDepth
        let ids = keywords.map(\.persistentModelID)

        lastRunKeywordIDs = Set(ids)
        progress = Progress(isRunning: true, completed: 0, total: ids.count)
        task = Task {
            defer { progress.isRunning = false; task = nil }
            for id in ids {
                if Task.isCancelled { break }
                guard let keyword = context.model(for: id) as? TrackedKeyword else { continue }
                progress.currentKeyword = keyword.text
                let sample = await Self.observe(keyword: keyword.text, storefront: storefront, device: device, ownTrackID: ownTrackID, depth: depth, provider: provider)
                if sample.outcome.isFailure {
                    progress.failures += 1
                    if case .requestFailed(let reason) = sample.outcome { progress.lastError = reason }
                }
                let record = RankObservation(sample: sample)
                record.keyword = keyword
                context.insert(record)
                try? context.save()
                progress.completed += 1
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Waits for the current run (if any) to finish.
    func waitUntilIdle() async {
        await task?.value
    }

    /// Measures several markets one after another (used by the launch-time refresh).
    func measureAll(_ markets: [TrackedMarket], context: ModelContext) async {
        for market in markets {
            await waitUntilIdle()
            measure(market.sortedKeywords, in: market, context: context)
            await waitUntilIdle()
        }
    }

    static func observe(keyword: String, storefront: Storefront, device: DeviceContext, ownTrackID: Int, depth: Int, provider: any SearchRankProvider) async -> RankSample {
        await RankSample.measure(keyword: keyword, storefront: storefront, device: device, ownTrackID: ownTrackID, depth: depth, provider: provider)
    }

    /// Markets whose newest observation is older than `staleHours` (or never measured).
    static func staleMarkets(in apps: [TrackedApp], staleHours: Int) -> [TrackedMarket] {
        let threshold = Date().addingTimeInterval(-Double(staleHours) * 3600)
        return apps.flatMap(\.markets).filter { market in
            guard !market.keywords.isEmpty else { return false }
            guard let last = market.lastMeasuredAt else { return true }
            return last < threshold
        }
    }
}
