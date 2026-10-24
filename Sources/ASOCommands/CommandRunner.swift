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
    /// Standard input, read whole; keys arrive here (`--key-stdin`), never as arguments, which other users can see.
    let input: @Sendable () -> String

    public init(environment: [String: String], output: @escaping @Sendable (String) -> Void, errors: @escaping @Sendable (String) -> Void,
                input: @escaping @Sendable () -> String = { "" }, makeEngine: @escaping EngineFactory) {
        self.environment = environment
        self.output = output
        self.errors = errors
        self.input = input
        self.makeEngine = makeEngine
    }

    /// The real thing: the data file under the data directory, public App Store search and autocomplete.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> CommandRunner {
        CommandRunner(environment: environment,
                      output: { print($0) },
                      errors: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                      input: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) },
                      makeEngine: { directory in
                          let settings = try EngineSettings.load(from: directory)
                          return Engine(store: try Store(url: EngineEnvironment.storeURL(in: directory)),
                                        search: ITunesSearchProvider(pacer: RequestPacer(minimumInterval: settings.pacingSeconds)),
                                        suggestions: AppStoreHintsProvider())
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
            output(arguments.flag("json")
                ? Self.json(["version": EngineEnvironment.version, "dataDirectory": dataDirectory(arguments).path])
                : "aso \(EngineEnvironment.version)")
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
        case ("app", "search"):
            try args.allow(["country"])
            let query = Array(args.positionals.dropFirst(2)).joined(separator: " ")
            guard !query.isEmpty else { throw UsageError("Missing app name, App Store link or ID.") }
            let apps = try await engine(args).findApps(query: query, countryCode: args.option("country") ?? "US")
            write(args, apps) { apps in
                guard !apps.isEmpty else { return "No apps found." }
                var table = TextTable([.init("ID", .right), .init("App"), .init("Seller"), .init("Genre"), .init("Ratings", .right)])
                for app in apps { table.add([String(app.trackID), app.name, app.sellerName, app.primaryGenre ?? "", app.ratingCount.map(String.init) ?? ""]) }
                return table.render()
            }
        case ("app", "add"):
            try args.allow(["country", "markets", "device"])
            let reference = try args.positional(2, "App Store link or app ID")
            let markets = (args.option("markets") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let app = try await engine(args).addApp(reference: reference, lookupCountry: args.option("country"), markets: markets,
                                                    device: try deviceOption(args) ?? .iPhone)
            write(args, app) { app in
                Self.sentence("Tracking \(app.name) (\(app.trackID)) by \(app.sellerName)")
                    + (markets.isEmpty ? "" : " Markets: \(markets.map { $0.uppercased() }.joined(separator: ", ")).")
            }
        case ("app", "genre"):
            try args.allow([])
            let id = try args.integer(2, "app ID")
            let raw = try args.positional(3, "Apple Ads genre or \"any\"")
            let genre: AppleAdsGenre?
            if raw.lowercased() == "any" {
                genre = nil
            } else if let match = AppleAdsGenre.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) {
                genre = match
            } else {
                throw UsageError("Unknown genre \"\(raw)\". Genres: any, \(AppleAdsGenre.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let app = try await engine(args).setAdsGenre(appID: id, genre: genre)
            write(args, app) { _ in "Apple Ads genre: \(genre?.displayName ?? "any (every genre is searched)")." }
        case ("market", "add"):
            try args.allow(["country", "device"])
            let summary = try await engine(args).addMarket(appID: try args.integer(2, "app ID"), countryCode: try required(args, "country"),
                                                           device: try deviceOption(args) ?? .iPhone)
            write(args, summary) { "Market \($0.country) · \($0.device) (\($0.countryName)) is ready for keywords." }
        case ("market", "list"):
            try args.allow([])
            let markets = try await engine(args).markets(appID: try args.integer(2, "app ID"))
            write(args, markets) { markets in
                guard !markets.isEmpty else { return "No markets yet. Add one with: aso market add <app ID> --country US" }
                var table = TextTable([.init("Market"), .init("Country"), .init("Keywords", .right), .init("Measured")])
                for m in markets {
                    table.add(["\(m.country) \(m.device)", m.countryName, String(m.keywords),
                               m.lastMeasuredAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"])
                }
                return table.render()
            }
        case ("market", "remove"):
            try args.allow(["country", "device"])
            let id = try args.integer(2, "app ID")
            let country = try required(args, "country")
            let device = try deviceOption(args) ?? .iPhone
            try await engine(args).removeMarket(appID: id, countryCode: country, device: device)
            write(args, ["removed": "\(country.uppercased()) \(device.rawValue)"]) { _ in
                "Removed the \(country.uppercased()) · \(device.rawValue) market with its keywords and measurements."
            }
        case ("storefronts", _):
            try args.allow([])
            let storefronts = StorefrontRegistry.sortedByName.map { StorefrontInfo(code: $0.countryCode, name: $0.name, language: $0.defaultLocale.rawValue) }
            write(args, storefronts) { list in list.map { "\($0.code)  \($0.name)" }.joined(separator: "\n") }
        case ("genres", _):
            try args.allow([])
            let genres = AppleAdsGenre.allCases.map { GenreInfo(id: $0.rawValue, name: $0.displayName) }
            write(args, genres) { list in list.map { "\($0.id)  \($0.name)" }.joined(separator: "\n") }
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
            let settings = try settings(args)
            let reference = try deltaOption(args) ?? settings.deltaReference
            let rows = try await engine(args).keywordReport(appID: try args.integer(2, "app ID"), countryCode: args.option("country"),
                                                            device: try deviceOption(args), deltaReference: reference,
                                                            golden: settings.golden)
            write(args, rows) { Self.keywordTable($0, reference: reference) }
        case ("measure", _):
            let settings = try settings(args)
            let depth = try args.integerOption("depth", default: settings.resultDepth, range: 1...200)
            let errors = self.errors
            let jsonProgress = args.flag("json")
            let report: @Sendable (Engine.MeasureProgress) -> Void = { step in
                // With --json, progress is one JSON object per line (JSON Lines) so front ends need not parse prose.
                errors(jsonProgress ? Self.json(MeasureProgressLine(step), pretty: false)
                                    : "[\(step.completed)/\(step.total)] \(step.market)  \(step.keyword)  \(step.outcome.shortLabel)")
            }
            let summary: Engine.MeasureSummary
            let nothing: String
            if args.flag("stale") {
                try args.allow(["depth", "stale", "stale-hours"])
                guard args.positionals.count == 1 else { throw UsageError("measure --stale covers every app; leave out the app ID.") }
                let hours = try args.integerOption("stale-hours", default: settings.staleHours, range: 1...720)
                summary = try await engine(args).measureStale(staleHours: hours, depth: depth, progress: report)
                nothing = "Every market with keywords was measured in the last \(hours) hours."
            } else {
                try args.allow(["country", "device", "depth"])
                let id = try args.integer(1, "app ID")
                summary = try await engine(args).measure(appID: id, countryCode: args.option("country"), device: try deviceOption(args),
                                                         depth: depth, progress: report)
                nothing = "Nothing to measure. Add keywords with: aso keywords add \(id) <keyword>... --country US"
            }
            write(args, summary) {
                $0.measured == 0 ? nothing
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
            write(args, DifficultyReport(score)) { report in
                var table = TextTable([.init("Component"), .init("Weight", .right), .init("Score", .right)])
                for component in report.components { table.add([component.name, component.weight, String(Int(component.value.rounded()))]) }
                return "Difficulty \(Int(report.score.rounded())) of 100\n\n" + table.render()
            }
        case ("validate", _):
            try args.allow(["title", "subtitle", "keywords"])
            let fields = MetadataFields(name: args.option("title") ?? "", subtitle: args.option("subtitle") ?? "", keywords: args.option("keywords") ?? "")
            let issues = MetadataValidator.validate(fields)
            write(args, issues) { issues in
                issues.isEmpty ? "No issues." : issues.map { "\($0.severity)  \($0.field.title): \($0.message)" }.joined(separator: "\n")
            }
            if MetadataValidator.hasErrors(issues) { throw ValidationFailed() }
        case ("settings", nil), ("settings", "show"):
            try args.allow([])
            write(args, try settings(args)) { Self.settingsTable($0) }
        case ("settings", "set"):
            try args.allow([])
            let directory = dataDirectory(args)
            var settings = try EngineSettings.load(from: directory)
            let name = try args.positional(2, "setting name")
            do {
                try settings.set(name, to: try args.positional(3, "value"))
            } catch let error as EngineError {
                throw UsageError(error.localizedDescription)
            }
            try settings.save(to: directory)
            write(args, settings) { _ in "Saved." }
        case ("settings", "reset"):
            try args.allow([])
            let directory = dataDirectory(args)
            try EngineSettings().save(to: directory)
            write(args, EngineSettings()) { _ in "Settings are back to their defaults." }
        case ("connections", nil), ("connections", "status"):
            try args.allow([])
            write(args, try Connections.status(credentials(args))) { Self.connectionsTable($0) }
        case ("connections", "set"):
            try saveConnection(args)
        case ("connections", "verify"):
            try args.allow([])
            let service = try serviceArgument(args)
            let answer = try await Connections.verify(service, store: credentials(args))
            write(args, ["service": service.rawValue, "result": answer]) { _ in "\(service.title): \(answer)" }
        case ("connections", "remove"):
            try args.allow([])
            let service = try serviceArgument(args)
            let removed = try credentials(args).remove(service)
            write(args, ["service": service.rawValue, "removed": removed ? "true" : "false"]) { _ in
                removed ? "Removed the \(service.title) keys." : "No \(service.title) keys were stored."
            }
        default:
            throw UsageError("Unknown command \"\(args.positionals.prefix(2).joined(separator: " "))\".")
        }
    }

    /// `connections set <service> …`: identifiers as options, secrets from a file or standard input only.
    private func saveConnection(_ args: Arguments) throws {
        let service = try serviceArgument(args)
        let store = try credentials(args)
        func secret(fileOption: String, stdinFlag: String) throws -> (text: String, fileName: String?) {
            if args.flag(stdinFlag) { return (input(), nil) }
            guard let path = args.option(fileOption) else { throw UsageError("Give the key with --\(fileOption) PATH or --\(stdinFlag).") }
            do {
                return (try String(contentsOfFile: path, encoding: .utf8), path)
            } catch {
                throw EngineError.invalidArgument("Cannot read \(path): \(error.localizedDescription)")
            }
        }
        switch service {
        case .appleAds:
            try args.allow(["client-id", "key-id", "org-id", "key-file", "key-stdin"])
            let key = try secret(fileOption: "key-file", stdinFlag: "key-stdin")
            try Connections.saveAppleAds(clientID: try required(args, "client-id"), keyID: try required(args, "key-id"),
                                         orgID: try required(args, "org-id"), privateKeyPEM: key.text, in: store)
        case .appStoreConnect:
            try args.allow(["key-id", "issuer-id", "key-file", "key-stdin"])
            let key = try secret(fileOption: "key-file", stdinFlag: "key-stdin")
            try Connections.saveAppStoreConnect(keyID: args.option("key-id"), issuerID: try required(args, "issuer-id"),
                                                privateKeyPEM: key.text, keyFileName: key.fileName, in: store)
        case .openRouter:
            try args.allow(["key-file", "key-stdin"])
            try Connections.saveOpenRouterKey(try secret(fileOption: "key-file", stdinFlag: "key-stdin").text, in: store)
        case .revenueCat:
            try args.allow(["keys-file", "keys-stdin"])
            _ = try Connections.saveRevenueCatKeys(try secret(fileOption: "keys-file", stdinFlag: "keys-stdin").text, in: store)
        }
        let status = try Connections.status(store).first { $0.service == service.rawValue }
        write(args, status) { _ in "Saved the \(service.title) keys. Check them with: aso connections verify \(service.rawValue)" }
    }

    /// Metadata that breaks a hard limit: the issues are already printed, the exit code says so.
    struct ValidationFailed: Error, LocalizedError {
        var errorDescription: String? { "The metadata has errors." }
    }

    /// A storefront as pickers list it.
    struct StorefrontInfo: Encodable {
        let code: String
        let name: String
        /// The language the storefront's store uses by default (e.g. "tr", "en-US").
        let language: String
    }

    struct GenreInfo: Encodable {
        let id: String
        let name: String
    }

    /// One measured keyword as `measure --json` reports it on stderr.
    struct MeasureProgressLine: Encodable {
        let completed: Int
        let total: Int
        let market: String
        let keyword: String
        /// The same short label as text output: "#12", "> 200", "Error".
        let outcome: String
        let status: String

        init(_ step: Engine.MeasureProgress) {
            completed = step.completed
            total = step.total
            market = step.market
            keyword = step.keyword
            outcome = step.outcome.shortLabel
            switch step.outcome {
            case .found: status = "found"
            case .outsideObservedRange: status = "outside"
            case .requestFailed: status = "failed"
            case .notChecked: status = "notChecked"
            }
        }
    }

    /// Difficulty with its components as the engine names and weighs them, so front ends show the same breakdown.
    struct DifficultyReport: Encodable {
        struct Component: Encodable {
            let name: String
            let weight: String
            let value: Double
            let explanation: String
        }

        let score: Double
        let tier: String
        let sampleSize: Int
        let components: [Component]

        init(_ score: DifficultyScore) {
            self.score = score.score
            tier = score.tier
            sampleSize = score.sampleSize
            components = score.components.map { .init(name: $0.name, weight: $0.weight, value: $0.value, explanation: $0.explanation) }
        }
    }

    // MARK: Helpers

    private func engine(_ args: Arguments) async throws -> Engine {
        try await makeEngine(dataDirectory(args))
    }

    private func dataDirectory(_ args: Arguments) -> URL {
        args.option("data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? EngineEnvironment.dataDirectory(environment: environment)
    }

    private func settings(_ args: Arguments) throws -> EngineSettings {
        try EngineSettings.load(from: dataDirectory(args))
    }

    private func credentials(_ args: Arguments) throws -> CredentialStore {
        CredentialStore(directory: dataDirectory(args))
    }

    private func serviceArgument(_ args: Arguments) throws -> CredentialStore.Service {
        let raw = try args.positional(2, "service")
        guard let service = CredentialStore.Service(rawValue: raw.lowercased()) else {
            throw UsageError("Unknown service \"\(raw)\". Services: \(CredentialStore.Service.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return service
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

    /// The --delta option, or nil to use the setting.
    private func deltaOption(_ args: Arguments) throws -> DeltaReference? {
        guard let raw = args.option("delta") else { return nil }
        guard let reference = DeltaReference.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
            throw UsageError("--delta must be one of: \(DeltaReference.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return reference
    }

    private func write<T: Encodable>(_ args: Arguments, _ value: T, text: (T) -> String) {
        output(args.flag("json") ? Self.json(value) : text(value))
    }

    /// Sorted keys, ISO 8601 dates; `pretty: false` keeps the object on one line (for JSON Lines).
    static func json<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func settingsTable(_ settings: EngineSettings) -> String {
        let values = Mirror(reflecting: settings).children.reduce(into: [String: String]()) { all, child in
            guard let name = child.label else { return }
            all[name] = (child.value as? DeltaReference)?.rawValue ?? "\(child.value)"
        }
        var table = TextTable([.init("Setting"), .init("Value"), .init("Accepted")])
        for field in EngineSettings.fields { table.add([field.name, values[field.name] ?? "", field.accepted]) }
        return table.render() + "\n\nChange one with: aso settings set <setting> <value>"
    }

    static func connectionsTable(_ statuses: [ConnectionStatus]) -> String {
        var table = TextTable([.init("Service"), .init("Name"), .init("Status"), .init("Details")])
        for status in statuses {
            let details = status.details.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            table.add([status.service, status.title, status.configured ? "stored" : "not set", details])
        }
        return table.render() + "\n\nKeys stay in credentials.json in the data folder and go only to their own service."
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

        Apps and markets
          app search <name, link or ID> [--country CC]    Find an app (nothing is stored)
          app add <App Store link or ID> [--country CC] [--markets US,DE,…] [--device iphone|ipad|mac]
                                                          Start tracking an app, optionally in several markets
          app list                                        Tracked apps
          app genre <app ID> <GENRE|any>                  Apple Ads genre used for popularity (see: aso genres)
          app remove <app ID>                             Stop tracking an app and delete its data
          market add <app ID> --country CC [--device ...]
          market list <app ID>                            Markets with their keyword count and last measurement
          market remove <app ID> --country CC [--device ...]
          storefronts  ·  genres                          The 50 App Store countries; the Apple Ads genres

        Keywords
          keywords add <app ID> <keyword>... --country CC [--device iphone|ipad|mac]
          keywords remove <app ID> <keyword>... --country CC [--device ...]
          keywords list <app ID> [--country CC] [--device ...] [--delta previous|first|week]
          measure <app ID> [--country CC] [--device ...] [--depth 1-200]
                                                          Fresh rank check for each keyword (about 3 s each)
          measure --stale [--stale-hours N]               Every market not measured in the last N hours (setting staleHours)

        Research (nothing is stored)
          search <term> --country CC [--device ...] [--limit 1-200]
          hints <seed> --country CC                       App Store autocomplete
          difficulty <term> --country CC [--device ...]   0-100 from the top ten results, with every component
          validate [--title T] [--subtitle S] [--keywords K]
                                                          Check metadata against the App Store limits

        Settings and connections
          settings [show]                                 Preferences: result depth, pacing, golden thresholds, Δ, auto measure
          settings set <setting> <value>  ·  settings reset
          connections [status]                            Which keys are stored (never the keys themselves)
          connections set apple-ads --client-id ID --key-id ID --org-id ID (--key-file PEM | --key-stdin)
          connections set asc --issuer-id ID [--key-id ID] (--key-file AuthKey_ID.p8 | --key-stdin)
          connections set openrouter (--key-file PATH | --key-stdin)
          connections set revenuecat (--keys-file PATH | --keys-stdin)    one key per line
          connections verify <service>  ·  connections remove <service>

        Options
          --json            Machine-readable output on stdout
          --data-dir PATH   Data folder (default: ASO_DATA_DIR, else the platform's app data folder)
          --help, --version

        Wrap keywords that start with "-" after "--": aso keywords add 123 --country US -- -keyword
        """
}
