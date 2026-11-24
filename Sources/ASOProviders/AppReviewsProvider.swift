import Foundation
import ASOCore

/// Public customer-reviews feed (`itunes.apple.com/<cc>/rss/customerreviews/…`). No authentication; newest 50 per
/// storefront per page. Only written reviews appear here, ratings without text are counted by the lookup API instead.
public struct AppReviewsProvider: CustomerReviewProvider {
    private let http = HTTPClient(serviceName: "App Store reviews", allowedHosts: ["itunes.apple.com"])
    private let pacer: RequestPacer

    public init(pacer: RequestPacer = RequestPacer(minimumInterval: 1.0)) {
        self.pacer = pacer
    }

    public func reviews(trackID: Int, storefront: Storefront, page: Int = 1) async throws -> [CustomerReview] {
        await pacer.wait()
        let cc = storefront.countryCode.lowercased()
        let url = URL(string: "https://itunes.apple.com/\(cc)/rss/customerreviews/page=\(max(1, min(10, page)))/id=\(trackID)/sortby=mostrecent/json")!
        let response = try await http.send(HTTPClient.request(url))
        // The feed answers 200 with an empty body for storefronts without reviews; anything else is an error.
        if response.data.isEmpty { return [] }
        try http.check(response)
        return Self.parse(response.data, countryCode: storefront.countryCode)
    }

    public static func parse(_ data: Data, countryCode: String) -> [CustomerReview] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let feed = json["feed"] as? [String: Any] else { return [] }
        let raw = feed["entry"]
        let entries: [[String: Any]] = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func label(_ v: Any?) -> String { ((v as? [String: Any])?["label"] as? String) ?? "" }
        return entries.compactMap { e in
            guard let rating = Int(label(e["im:rating"])), rating >= 1 else { return nil }   // the app's own entry has no rating
            let id = label(e["id"])
            guard !id.isEmpty else { return nil }
            let author = ((e["author"] as? [String: Any])?["name"] as? [String: Any])?["label"] as? String ?? ""
            let version = label(e["im:version"])
            return CustomerReview(id: id, countryCode: countryCode, title: label(e["title"]), body: label(e["content"]), rating: rating, author: author,
                                  version: version.isEmpty ? nil : version, date: iso.date(from: label(e["updated"])))
        }
    }
}
