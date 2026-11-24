import SwiftUI
import SwiftData
import ASOCore

/// Before/after ranks around one marker, weighted by what each keyword is worth: popularity × beatable difficulty × fit.
/// A jump on a worthless term counts for nothing; a few places on a valuable one counts a lot.
struct ImpactView: View {
    let app: TrackedApp
    let marker: Marker

    enum Mode: String, CaseIterable, Identifiable { case improved = "Improved", worsened = "Worsened", all = "All"; var id: String { rawValue } }
    @State private var mode: Mode = .improved
    @State private var market = ""
    @State private var minTier = 0          // 0 any · 1 low+ · 2 medium+ · 3 high
    @State private var search = ""

    nonisolated struct Row: Identifiable, Sendable {
        let id: String
        let market: String
        let keyword: String
        let before: Int?
        let beforeDate: Date
        let after: Int?
        let afterDate: Date
        let depth: Int
        let popularity: Int?
        let difficulty: Int?
        let fit: Double?
        /// 0–100: how much ranking for this term is worth (0 for brands / unrelated / no demand).
        let value: Double
        var delta: Int { (before ?? depth + 1) - (after ?? depth + 1) }
        /// Value gained (positive) or lost with this movement, on the visibility curve.
        var gain: Double { KeywordImpact.gain(before: before, after: after, value: value) }
        var tier: String { KeywordImpact.tier(value).rawValue }
    }

    private var rows: [Row] {
        var out: [Row] = []
        for market in app.sortedMarkets {
            for k in market.sortedKeywords {
                guard let pair = k.beforeAfter(marker.date) else { continue }
                let p = k.latestPopularity
                let apple = p?.popularity1to100
                let pop = ((apple ?? 0) < ModelTrainer.publishedThreshold ? (p?.subFloorEstimate ?? apple) : apple)
                let fit = k.fitProbability
                let value = KeywordImpact.value(popularity: pop, difficulty: k.difficultyScore?.score, isBrandLike: k.isBrandLike, fit: fit)
                out.append(Row(id: "\(market.countryCode)|\(k.normalized)", market: market.title, keyword: k.text, before: pair.before.position, beforeDate: pair.before.fetchedAt,
                               after: pair.after.position, afterDate: pair.after.fetchedAt, depth: max(pair.before.observedCount, pair.after.observedCount),
                               popularity: pop, difficulty: k.difficultyScore?.rounded, fit: fit, value: value))
            }
        }
        return out
    }

    var body: some View {
        let all = rows
        let improved = all.filter { $0.delta > 0 }
        let worsened = all.filter { $0.delta < 0 }
        let same = all.count - improved.count - worsened.count
        let gained = improved.reduce(0.0) { $0 + $1.gain }
        let lost = worsened.reduce(0.0) { $0 + $1.gain }
        let net = gained + lost
        let markets = Array(Set(all.map(\.market))).sorted()
        let shown: [Row] = {
            var list: [Row]
            switch mode {
            case .improved: list = improved.sorted { $0.gain > $1.gain }
            case .worsened: list = worsened.sorted { $0.gain < $1.gain }
            case .all: list = all.sorted { abs($0.gain) > abs($1.gain) }
            }
            if !market.isEmpty { list = list.filter { $0.market == market } }
            if minTier > 0 {
                let threshold = (minTier == 3 ? KeywordImpact.Tier.high : minTier == 2 ? .medium : .low).threshold
                list = list.filter { $0.value >= threshold }
            }
            if !search.isEmpty { list = list.filter { $0.keyword.localizedCaseInsensitiveContains(search) } }
            return list
        }()
        VStack(alignment: .leading, spacing: 10) {
            Text("Effect of \(marker.title) · \(marker.date.shortLabel)").font(.headline)
            if all.isEmpty {
                Text("No keyword has a measurement both before and after \(marker.date.shortLabel). Measure before a change and keep measuring after it; the comparison appears here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    StatCard(title: "Net value change") {
                        Text(String(format: "%+.1f", net)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(net > 0.5 ? Color.green : net < -0.5 ? Color.red : Color.secondary)
                    }
                    StatCard(title: "Value gained") { Text(String(format: "+%.1f", gained)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Color.green) }
                    StatCard(title: "Value lost") { Text(String(format: "%.1f", lost)).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Color.red) }
                    StatCard(title: "Improved · worsened · same") { Text("\(improved.count) · \(worsened.count) · \(same)").font(.title3.weight(.semibold)).monospacedDigit() }
                }
                HStack(spacing: 12) {
                    Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Picker("Market", selection: $market) {
                        Text("All markets").tag("")
                        ForEach(markets, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 220)
                    Picker("Value", selection: $minTier) {
                        Text("Any value").tag(0); Text("Low and above").tag(1); Text("Medium and above").tag(2); Text("High only").tag(3)
                    }
                    .frame(maxWidth: 200)
                    TextField("Filter keywords", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Spacer()
                    Text("\(shown.count) of \(all.count)").font(.caption).foregroundStyle(.secondary)
                }
                table(shown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Value = popularity × (1 − (difficulty/100)²) × fit, 0 for brands and unrelated terms. Visibility = share of searchers who see a position (#1 100 … #10 50 … #50 8). Gain = visibility change × value; keywords with no value move the totals by nothing.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func table(_ rows: [Row]) -> some View {
        Table(rows) {
            TableColumn("Keyword") { r in Text(r.keyword).lineLimit(1).textSelection(.enabled) }
            TableColumn("Market") { r in Text(r.market).font(.caption).foregroundStyle(.secondary) }.width(min: 90, ideal: 110)
            TableColumn("Before") { r in Text(r.before.map { "#\($0)" } ?? "> \(r.depth)").monospacedDigit().help(r.beforeDate.formatted(date: .abbreviated, time: .shortened)) }.width(min: 60, ideal: 70)
            TableColumn("After") { r in Text(r.after.map { "#\($0)" } ?? "> \(r.depth)").monospacedDigit().help(r.afterDate.formatted(date: .abbreviated, time: .shortened)) }.width(min: 60, ideal: 70)
            TableColumn("Δ") { r in DeltaLabel(delta: r.delta) }.width(min: 60, ideal: 70)
            TableColumn("Value") { r in
                HStack(spacing: 4) {
                    Text(r.tier).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background((r.tier == "High" ? Color.green : r.tier == "Medium" ? Color.blue : r.tier == "Low" ? Color.orange : Color.gray).opacity(0.18), in: Capsule())
                    Text("pop \(r.popularity.map(String.init) ?? "?") · diff \(r.difficulty.map(String.init) ?? "?")\(r.fit.map { String(format: " · fit %.0f%%", $0 * 100) } ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help("Value \(Int(r.value.rounded()))/100: popularity \(r.popularity.map(String.init) ?? "?"), difficulty \(r.difficulty.map(String.init) ?? "unmeasured (50 assumed)"), fit \(r.fit.map { String(format: "%.0f%%", $0 * 100) } ?? "unchecked").")
            }
            .width(min: 200, ideal: 260)
            TableColumn("Gain") { r in
                if r.value == 0 {
                    Text("0 · no value").font(.caption).foregroundStyle(.tertiary).help("This keyword has no value (brand, unrelated or no demand), so its move changes nothing.")
                } else {
                    Text(String(format: "%+.2f", r.gain)).monospacedDigit().foregroundStyle(r.gain > 0 ? Color.green : r.gain < 0 ? Color.red : Color.secondary)
                }
            }
            .width(min: 80, ideal: 95)
        }
    }
}
