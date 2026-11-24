import SwiftUI
import SwiftData
import ASOCore

/// Ratings per storefront over time: where the latest rating came from, and how counts moved since the previous check.
struct RatingsCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    let app: TrackedApp

    nonisolated struct Row: Identifiable, Sendable {
        let id: String
        let country: String
        let name: String
        let count: Int
        let average: Double?
        let delta: Int?
        let since: Date?
        let checkedAt: Date
        let lastNewAt: Date?
    }

    private var rows: [Row] {
        let readings = app.ratings.map { RatingReading(countryCode: $0.countryCode, count: $0.count, average: $0.average, fetchedAt: $0.fetchedAt) }
        return RatingTrend.trends(readings).map { t in
            Row(id: t.countryCode, country: t.countryCode, name: StorefrontRegistry.lookup(t.countryCode)?.name ?? t.countryCode, count: t.count,
                average: t.average, delta: t.delta, since: t.previousAt, checkedAt: t.checkedAt, lastNewAt: t.lastNewAt)
        }
    }

    var body: some View {
        let rows = rows
        let total = rows.reduce(0) { $0 + $1.count }
        let latestNew = rows.compactMap { r in r.lastNewAt.map { (r, $0) } }.max { $0.1 < $1.1 }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let (r, when) = latestNew {
                        Label("Last new rating: \(r.name) · \(when.relativeLabel)", systemImage: "star.fill").foregroundStyle(.yellow)
                    } else if rows.isEmpty {
                        Text("No ratings recorded yet. Ratings are read from the App Store for every tracked storefront when you measure; press Check to read them now.").foregroundStyle(.secondary)
                    } else {
                        Text("No new rating seen between checks yet (\(rows.count) storefront(s), \(total) ratings in total).").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if env.catalog.isCheckingRatings {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check tracked storefronts") { Task { await env.catalog.recordRatings(app: app, storefronts: app.sortedMarkets.compactMap(\.storefront), context: context) } }
                            .controlSize(.small)
                        Button("Check all 50") { Task { await env.catalog.recordRatings(app: app, storefronts: StorefrontRegistry.sortedByName, context: context) } }
                            .controlSize(.small)
                            .help("One public request per storefront (~50); takes about a minute")
                    }
                }
                if let latest = app.reviews.sorted(by: { ($0.date ?? $0.fetchedAt) > ($1.date ?? $1.fetchedAt) }).first {
                    Text("Latest written review: \(StorefrontRegistry.lookup(latest.countryCode)?.name ?? latest.countryCode) · \(latest.rating)★ “\(latest.title)” · \((latest.date ?? latest.fetchedAt).relativeLabel): \(app.reviews.count) stored, see Reviews.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if !rows.isEmpty {
                    Table(rows) {
                        TableColumn("Storefront") { r in Text("\(r.name) (\(r.country))").lineLimit(1) }
                        TableColumn("Ratings") { r in Text("\(r.count)").monospacedDigit() }.width(min: 60, ideal: 70)
                        TableColumn("Average") { r in Text(r.average.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit() }.width(min: 60, ideal: 70)
                        TableColumn("Since last check") { r in
                            if let d = r.delta { Text(d == 0 ? "—" : String(format: "%+d", d)).monospacedDigit().foregroundStyle(d > 0 ? Color.green : d < 0 ? Color.red : Color.secondary).help(r.since.map { "previous check \($0.relativeLabel)" } ?? "") }
                            else { Text("first check").font(.caption).foregroundStyle(.tertiary) }
                        }
                        .width(min: 100, ideal: 120)
                        TableColumn("Last new rating") { r in Text(r.lastNewAt.map(\.relativeLabel) ?? "—").font(.caption).foregroundStyle(.secondary) }.width(min: 110, ideal: 130)
                        TableColumn("Checked") { r in Text(r.checkedAt.relativeLabel).font(.caption).foregroundStyle(.tertiary) }.width(min: 90, ideal: 110)
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Ratings by storefront")
        }
    }
}
