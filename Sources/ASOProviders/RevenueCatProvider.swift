import Foundation
import ASOCore

/// RevenueCat REST API v2: projects, their App Store apps and the overview metrics (MRR, active subscriptions, 28-day
/// revenue, new customers, trials). Read-only; one secret key per project.
public actor RevenueCatProvider {
    public struct Project: Sendable, Hashable { public let id: String; public let name: String }
    public struct App: Sendable, Hashable { public let id: String; public let name: String; public let type: String; public let bundleID: String? }
    public struct Overview: Sendable, Hashable {
        public let mrr: Double
        public let activeSubscriptions: Int
        public let revenue28d: Double
        public let newCustomers28d: Int
        public let activeTrials: Int
        public let activeUsers28d: Int

        public init(mrr: Double, activeSubscriptions: Int, revenue28d: Double, newCustomers28d: Int, activeTrials: Int, activeUsers28d: Int) {
            self.mrr = mrr
            self.activeSubscriptions = activeSubscriptions
            self.revenue28d = revenue28d
            self.newCustomers28d = newCustomers28d
            self.activeTrials = activeTrials
            self.activeUsers28d = activeUsers28d
        }
    }

    private let http = HTTPClient(serviceName: "RevenueCat", allowedHosts: ["api.revenuecat.com"])

    public init() {}

    private func get(_ path: String, key: String) async throws -> [String: Any] {
        let request = HTTPClient.request(URL(string: "https://api.revenuecat.com/v2" + path)!, headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
        let response = try await http.send(request)
        try http.check(response)
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw ASOError.decoding(service: "RevenueCat", detail: "Expected a JSON object.") }
        return json
    }

    public func projects(key: String) async throws -> [Project] {
        ((try await get("/projects?limit=50", key: key))["items"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return Project(id: id, name: p["name"] as? String ?? id)
        }
    }

    public func apps(key: String, project: String) async throws -> [App] {
        ((try await get("/projects/\(project)/apps?limit=50", key: key))["items"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            return App(id: id, name: a["name"] as? String ?? id, type: a["type"] as? String ?? "", bundleID: (a["app_store"] as? [String: Any])?["bundle_id"] as? String)
        }
    }

    public func overview(key: String, project: String) async throws -> Overview {
        let json = try await get("/projects/\(project)/metrics/overview", key: key)
        var v: [String: Double] = [:]
        for m in json["metrics"] as? [[String: Any]] ?? [] {
            if let id = m["id"] as? String { v[id] = (m["value"] as? Double) ?? (m["value"] as? Int).map(Double.init) ?? 0 }
        }
        return Overview(mrr: v["mrr"] ?? 0, activeSubscriptions: Int(v["active_subscriptions"] ?? 0), revenue28d: v["revenue"] ?? 0,
                        newCustomers28d: Int(v["new_customers"] ?? 0), activeTrials: Int(v["active_trials"] ?? 0), activeUsers28d: Int(v["active_users"] ?? 0))
    }
}
