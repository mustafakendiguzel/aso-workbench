import Foundation
import ASOCore
import ASOProviders

/// What one read of every RevenueCat project reachable with the stored keys returned.
public struct RevenueRead: Sendable, Equatable {
    public struct Project: Sendable, Equatable {
        public let id: String
        public let name: String
        public let bundleIDs: [String]
        public let appNames: [String]
        public let overview: RevenueCatProvider.Overview

        public init(id: String, name: String, bundleIDs: [String], appNames: [String], overview: RevenueCatProvider.Overview) {
            self.id = id
            self.name = name
            self.bundleIDs = bundleIDs
            self.appNames = appNames
            self.overview = overview
        }
    }

    public let projects: [Project]
    /// Why a key failed, one entry per key.
    public let failures: [String]

    public init(projects: [Project], failures: [String]) {
        self.projects = projects
        self.failures = failures
    }
}

/// RevenueCat behind a protocol, so the refresh is tested without the network; the live one holds the stored keys.
public protocol RevenueSource: Sendable {
    func read() async -> RevenueRead
}

/// Every project of every stored key, as the macOS app reads them: its App Store apps and its overview metrics.
public struct RevenueCatAccounts: RevenueSource {
    let keys: [String]
    let provider = RevenueCatProvider()

    public init(keys: [String]) { self.keys = keys }

    public func read() async -> RevenueRead {
        var projects: [RevenueRead.Project] = [], failures: [String] = []
        for key in keys {
            do {
                for project in try await provider.projects(key: key) {
                    let apps = (try? await provider.apps(key: key, project: project.id)) ?? []
                    let overview = try await provider.overview(key: key, project: project.id)
                    projects.append(.init(id: project.id, name: project.name, bundleIDs: apps.compactMap(\.bundleID),
                                          appNames: apps.filter { $0.type == "app_store" }.map(\.name), overview: overview))
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return RevenueRead(projects: projects, failures: failures)
    }
}

extension Engine {
    public struct RevenueRefresh: Sendable, Codable, Equatable {
        public let projects: Int
        public let failures: [String]
    }

    public struct RevenueReport: Sendable, Codable, Equatable {
        /// "bundleID" or "name": how the app's project was found; absent when none matches.
        public let match: String?
        public let latest: RevenueSnapshotRecord?
        /// MRR change against the newest snapshot at least 20 hours older.
        public let mrrChange: Double?
        /// The project's snapshots, newest first (at most 14).
        public let history: [RevenueSnapshotRecord]
    }

    static let revenueNotConnected = "RevenueCat is not connected. Add a secret API key with: aso connections set revenuecat (or in the window: Settings → Connections)."

    /// Reads every RevenueCat project and stores one snapshot each, replacing one already stored that day (in
    /// `calendar`'s time zone), as the macOS app does on demand and at launch.
    public func refreshRevenue(now: Date = Date(), calendar: Calendar = .current) async throws -> RevenueRefresh {
        guard let revenue else { throw EngineError.invalidArgument(Self.revenueNotConnected) }
        let read = await revenue.read()
        let dayStart = calendar.startOfDay(for: now)
        for p in read.projects {
            let o = p.overview
            try await store.replaceRevenueSnapshot(
                RevenueSnapshotRecord(projectID: p.id, projectName: p.name, bundleIDs: p.bundleIDs, appNames: p.appNames, mrr: o.mrr,
                                      activeSubscriptions: o.activeSubscriptions, revenue28d: o.revenue28d, newCustomers28d: o.newCustomers28d,
                                      activeTrials: o.activeTrials, activeUsers28d: o.activeUsers28d, fetchedAt: now),
                since: dayStart)
        }
        if read.projects.isEmpty, let failure = read.failures.first { throw EngineError.invalidArgument("RevenueCat: \(failure)") }
        return RevenueRefresh(projects: read.projects.count, failures: read.failures)
    }

    /// The stored snapshots of the project that holds the app: matched by bundle ID, then by name.
    public func revenueReport(appID: Int) async throws -> RevenueReport {
        let app = try await app(appID)
        let all = try await store.revenueSnapshots()
        let (matches, kind) = RevenueMatch.select(all, bundleID: app.bundleID, appName: app.name, bundleIDs: \.bundleIDs,
                                                  projectName: \.projectName, appNames: \.appNames)
        // Several matching projects: the one read most recently, with its own history.
        guard let latest = matches.first else { return RevenueReport(match: nil, latest: nil, mrrChange: nil, history: []) }
        let history = matches.filter { $0.projectID == latest.projectID }
        let previous = history.dropFirst().first { $0.fetchedAt < latest.fetchedAt.addingTimeInterval(-20 * 3600) }
        return RevenueReport(match: kind?.rawValue, latest: latest, mrrChange: previous.map { latest.mrr - $0.mrr }, history: Array(history.prefix(14)))
    }
}
