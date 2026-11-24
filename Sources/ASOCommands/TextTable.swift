import Foundation

/// A plain-text table with aligned columns for terminal output.
struct TextTable {
    enum Alignment { case left, right }

    struct Column {
        let title: String
        let alignment: Alignment
        init(_ title: String, _ alignment: Alignment = .left) {
            self.title = title
            self.alignment = alignment
        }
    }

    let columns: [Column]
    var rows: [[String]] = []

    init(_ columns: [Column]) { self.columns = columns }

    mutating func add(_ cells: [String]) { rows.append(cells) }

    /// Columns are separated by two spaces; trailing spaces are trimmed.
    func render() -> String {
        let widths = columns.indices.map { i in ([columns[i].title] + rows.map { i < $0.count ? $0[i] : "" }).map(\.count).max() ?? 0 }
        func line(_ cells: [String]) -> String {
            columns.indices.map { i in
                let cell = i < cells.count ? cells[i] : ""
                let pad = String(repeating: " ", count: widths[i] - cell.count)
                return columns[i].alignment == .right ? pad + cell : cell + pad
            }
            .joined(separator: "  ")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        return ([line(columns.map(\.title))] + rows.map(line)).joined(separator: "\n")
    }
}
