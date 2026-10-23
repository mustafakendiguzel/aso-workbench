import Foundation
import ASOCore
import ASOEngine
import ASOProviders

/// Runs one `aso` invocation: parses the arguments, calls the engine and writes text or JSON.
/// Results go to `output`; progress, warnings and errors go to `errors`, so `--json` output stays parseable.
public struct CommandRunner: Sendable {
    public typealias EngineFactory = @Sendable (_ dataDirectory: URL) async throws -> Engine

    public enum ExitCode {
        public static let success: Int32 = 0
        public static let failure: Int32 = 1
        /// EX_USAGE from sysexits.h.
        public static let usage: Int32 = 64
    }

    let makeEngine: EngineFactory
    let environment: [String: String]
    let output: @Sendable (String) -> Void
    let errors: @Sendable (String) -> Void

    public init(environment: [String: String], output: @escaping @Sendable (String) -> Void, errors: @escaping @Sendable (String) -> Void,
                makeEngine: @escaping EngineFactory) {
        self.environment = environment
        self.output = output
        self.errors = errors
        self.makeEngine = makeEngine
    }

    /// The real thing: the data file under the data directory, public App Store search and autocomplete.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> CommandRunner {
        CommandRunner(environment: environment,
                      output: { print($0) },
                      errors: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                      makeEngine: { directory in
                          Engine(store: try Store(url: EngineEnvironment.storeURL(in: directory)),
                                 search: ITunesSearchProvider(), suggestions: AppStoreHintsProvider())
                      })
    }

    public func run(_ rawArguments: [String]) async -> Int32 {
        let arguments: Arguments
        do {
            arguments = try Arguments(rawArguments)
        } catch {
            errors("error: \(error)\n\n" + Self.usage)
            return ExitCode.usage
        }
        if arguments.flag("version") || arguments.positionals.first == "version" {
            output(arguments.flag("json") ? json(["version": EngineEnvironment.version]) : "aso \(EngineEnvironment.version)")
            return ExitCode.success
        }
        guard !arguments.flag("help"), let command = arguments.positionals.first, command != "help" else {
            output(Self.usage)
            return ExitCode.success
        }
        do {
            try await dispatch(command, arguments)
            return ExitCode.success
        } catch let error as UsageError {
            errors("error: \(error.message)\n\n" + Self.usage)
            return ExitCode.usage
        } catch {
            errors("error: \(error.localizedDescription)")
            return ExitCode.failure
        }
    }

    // MARK: Commands

    private func dispatch(_ command: String, _ args: Arguments) async throws {
        switch (command, args.positionals.dropFirst().first) {
        case ("app", "add"):
            try args.allow(["country"])
            let app = try await engine(args).addApp(reference: try args.positional(2, "App Store link or app ID"), countryCode: args.option("country"))
            write(args, app) { Self.sentence("Tracking \($0.name) (\($0.trackID)) by \($0.sellerName)") }
        case ("app", "list"):
            try args.allow([])
            let apps = try await engine(args).store.apps()
            write(args, apps) { apps in
                guard !apps.isEmpty else { return "No apps yet. Add one with: aso app add <App Store link>" }
                var table = TextTable([.init("ID", .right), .init("Name"), .init("Seller"), .init("Genre")])
                for app in apps { table.add([String(app.trackID), app.name, app.sellerName, app.primaryGenre ?? ""]) }
                return table.render()
            }
        case ("app", "remove"):
            try args.allow([])
            let id = try args.integer(2, "app ID")
            guard try await engine(args).store.removeApp(trackID: id) else { throw EngineError.notFound("App \(id) is not tracked.") }
            write(args, ["removed": id]) { _ in "Removed app \(id) with its keywords and measurements." }
        case ("keywords", "add"), ("keywords", "remove"):
            try args.allow(["country", "device"])
            let id = try args.integer(2, "app ID")
            let terms = Array(args.positionals.dropFirst(3))
            guard !terms.isEmpty else { throw UsageError("Missing keywords.") }
            let country = try required(args, "country")
            let device = try deviceOption(args) ?? .iPhone
            if args.positionals[1] == "add" {
                let result = try await engine(args).addKeywords(terms, appID: id, countryCode: country, device: device)
                write(args, result) {
                    "Added \($0.added.count) keyword(s) in \($0.market)."
                        + ($0.alreadyTracked.isEmpty ? "" : " Already tracked: \($0.alreadyTracked.joined(separator: ", ")).")
                }
            } else {
                let removed = try await engine(args).removeKeywords(terms, appID: id, countryCode: country, device: device)
                write(args, ["removed": removed]) { _ in "Removed \(removed) keyword(s)." }
            }
        case ("keywords", "list"):
            try args.allow(["country", "device", "delta"])
            let reference = try deltaOption(args)
            let rows = try await engine(args).keywordReport(appID: try args.integer(2, "app ID"), countryCode: args.option("country"),
                                                            device: try deviceOption(args), deltaReference: reference)
            write(args, rows) { Self.keywordTable($0, reference: reference) }
        case ("measure", _):
            try args.allow(["country", "device", "depth"])
            let id = try args.integer(1, "app ID")
            let depth = try args.integerOption("depth", default: 200, range: 1...200)
            let errors = self.errors
            let summary = try await engine(args).measure(appID: id, countryCode: args.option("country"), device: try deviceOption(args),
                                                         depth: depth) { step in
                errors("[\(step.completed)/\(step.total)] \(step.market)  \(step.keyword)  \(step.outcome.shortLabel)")
            }
            write(args, summary) {
                $0.measured == 0
                    ? "Nothing to measure. Add keywords with: aso keywords add \(id) <keyword>... --country US"
                    : "Measured \($0.measured): \($0.found) ranked, \($0.outside) outside the results, \($0.failed) failed."
            }
        case ("search", _):
            try args.allow(["country", "device", "limit"])
            let limit = try args.integerOption("limit", default: 25, range: 1...200)
            let results = try await engine(args).searchResults(term: try args.positional(1, "search term"), countryCode: try required(args, "country"),
                                                               device: try deviceOption(args) ?? .iPhone, limit: limit)
            write(args, results) { results in
                var table = TextTable([.init("#", .right), .init("App"), .init("Seller"), .init("Ratings", .right), .init("ID", .right)])
                for (i, app) in results.enumerated() {
                    table.add([String(i + 1), app.name, app.sellerName, app.ratingCount.map(String.init) ?? "", String(app.trackID)])
                }
                return table.render()
            }
        case ("hints", _):
            try args.allow(["country"])
            let hints = try await engine(args).hints(seed: try args.positional(1, "seed"), countryCode: try required(args, "country"))
            write(args, hints) { $0.isEmpty ? "No suggestions." : $0.joined(separator: "\n") }
        case ("difficulty", _):
            try args.allow(["country", "device"])
            let term = try args.positional(1, "search term")
            guard let score = try await engine(args).difficulty(term: term, countryCode: try required(args, "country"),
                                                                device: try deviceOption(args) ?? .iPhone) else {
                throw EngineError.notFound("The search for \"\(term)\" returned no apps, so there is nothing to compare against.")
            }
            write(args, score) { score in
                var table = TextTable([.init("Component"), .init("Weight", .right), .init("Score", .right)])
                for component in score.components { table.add([component.name, component.weight, String(Int(component.value.rounded()))]) }
                return "Difficulty \(Int(score.score.rounded())) of 100\n\n" + table.render()
            }
        case ("validate", _):
            try args.allow(["title", "subtitle", "keywords"])
            let fields = MetadataFields(name: args.option("title") ?? "", subtitle: args.option("subtitle") ?? "", keywords: args.option("keywords") ?? "")
            let issues = MetadataValidator.validate(fields)
            write(args, issues) { issues in
                issues.isEmpty ? "No issues." : issues.map { "\($0.severity)  \($0.field.title): \($0.message)" }.joined(separator: "\n")
            }
            if MetadataValidator.hasErrors(issues) { throw ValidationFailed() }
        default:
            throw UsageError("Unknown command \"\(args.positionals.prefix(2).joined(separator: " "))\".")
        }
    }

    /// Metadata that breaks a hard limit: the issues are already printed, the exit code says so.
    struct ValidationFailed: Error, LocalizedError {
        var errorDescription: String? { "The metadata has errors." }
    }

    // MARK: Helpers

    private func engine(_ args: Arguments) async throws -> Engine {
        let directory = args.option("data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? EngineEnvironment.dataDirectory(environment: environment)
        return try await makeEngine(directory)
    }

    private func required(_ args: Arguments, _ name: String) throws -> String {
        guard let value = args.option(name), !value.isEmpty else { throw UsageError("Missing --\(name).") }
        return value
    }

    private func deviceOption(_ args: Arguments) throws -> DeviceContext? {
        guard let raw = args.option("device") else { return nil }
        guard let device = DeviceContext(rawValue: raw.lowercased()) else {
            throw UsageError("--device must be one of: \(DeviceContext.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return device
    }

    private func deltaOption(_ args: Arguments) throws -> DeltaReference {
        guard let raw = args.option("delta") else { return .previous }
        let accepted: [DeltaReference] = [.previous, .first, .week]
        guard let reference = accepted.first(where: { $0.rawValue == raw.lowercased() }) else {
            throw UsageError("--delta must be one of: \(accepted.map(\.rawValue).joined(separator: ", ")).")
        }
        return reference
    }

    private func write<T: Encodable>(_ args: Arguments, _ value: T, text: (T) -> String) {
        output(args.flag("json") ? json(value) : text(value))
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Ends the text with one period, also when it already ends with one ("by Apple Inc.").
    static func sentence(_ text: String) -> String { text.hasSuffix(".") ? text : text + "." }

    static func keywordTable(_ rows: [KeywordReportRow], reference: DeltaReference) -> String {
        guard !rows.isEmpty else { return "No keywords yet. Add some with: aso keywords add <app ID> <keyword>... --country US" }
        var table = TextTable([.init("Keyword"), .init("Market"), .init("Rank", .right), .init("Δ", .right), .init("Difficulty", .right),
                               .init("Brand"), .init("Measured")])
        for row in rows {
            table.add([row.keyword, "\(row.country) \(row.device)", row.rankLabel, row.delta.map { $0 > 0 ? "+\($0)" : String($0) } ?? "",
                       row.difficulty.map { String(Int($0.rounded())) } ?? "", row.brandLike ? "yes" : "",
                       row.measuredAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"])
        }
        return table.render() + "\n\nΔ: \(reference.title); positive = moved up."
    }

    static let usage = """
        Usage: aso <command> [options]

        Track App Store ranks and check keywords from the command line. Every number says where it came from:
        "> 200" means not in the top 200 results, never rank 201.

        Apps
          app add <App Store link or ID> [--country CC]   Start tracking an app
          app list                                        Tracked apps
          app remove <app ID>                             Stop tracking an app and delete its data

        Keywords
          keywords add <app ID> <keyword>... --country CC [--device iphone|ipad|mac]
          keywords remove <app ID> <keyword>... --country CC [--device ...]
          keywords list <app ID> [--country CC] [--device ...] [--delta previous|first|week]
          measure <app ID> [--country CC] [--device ...] [--depth 1-200]
                                                          Fresh rank check for each keyword (about 3 s each)

        Research (nothing is stored)
          search <term> --country CC [--device ...] [--limit 1-200]
          hints <seed> --country CC                       App Store autocomplete
          difficulty <term> --country CC [--device ...]   0-100 from the top ten results, with every component
          validate [--title T] [--subtitle S] [--keywords K]
                                                          Check metadata against the App Store limits

        Options
          --json            Machine-readable output on stdout
          --data-dir PATH   Data folder (default: ASO_DATA_DIR, else the platform's app data folder)
          --help, --version

        Wrap keywords that start with "-" after "--": aso keywords add 123 --country US -- -keyword
        """
}
