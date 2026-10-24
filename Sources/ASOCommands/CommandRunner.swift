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
                          // Keys that cannot be read leave Apple Ads unconnected; `aso connections` says why.
                          let credentials = CredentialStore(directory: directory)
                          let ads = (try? credentials.appleAds()).flatMap { $0 }
                          let openRouter = (try? credentials.openRouterKey()).flatMap { $0 }
                          let revenueKeys = (try? credentials.revenueCatKeys()) ?? []
                          let asc = (try? credentials.appStoreConnect()).flatMap { $0 }.flatMap { $0.isComplete ? $0 : nil }
                          return Engine(store: try Store(url: EngineEnvironment.storeURL(in: directory)),
                                        search: ITunesSearchProvider(pacer: RequestPacer(minimumInterval: settings.pacingSeconds)),
                                        suggestions: AppStoreHintsProvider(), reviews: AppReviewsProvider(),
                                        popularity: ads.map { AppleAdsPopularityProvider(credentials: $0) },
                                        judge: openRouter.map { JevClient(apiKey: $0) },
                                        ads: ads.map { AppleAdsCampaignProvider(credentials: $0) },
                                        revenue: revenueKeys.isEmpty ? nil : RevenueCatAccounts(keys: revenueKeys),
                                        publisher: asc.map { AppStoreConnectPublisher(credentials: $0) })
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
                               m.lastMeasuredAt.map(Self.shortDate) ?? "never"])
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
        case ("locales", _):
            try args.allow([])
            let locales = AppLocale.allCases.map { GenreInfo(id: $0.rawValue, name: $0.displayName) }
            write(args, locales) { list in list.map { "\($0.id)  \($0.name)" }.joined(separator: "\n") }
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
            try args.allow(["country", "device", "delta", "csv"])
            let settings = try settings(args)
            let reference = try deltaOption(args) ?? settings.deltaReference
            let rows = try await engine(args).keywordReport(appID: try args.integer(2, "app ID"), countryCode: args.option("country"),
                                                            device: try deviceOption(args), deltaReference: reference,
                                                            golden: settings.golden)
            if args.flag("csv") {
                guard !args.flag("json") else { throw UsageError("Choose --csv or --json, not both.") }
                output(KeywordCSV.render(rows))
            } else {
                write(args, rows) { Self.keywordTable($0, reference: reference) }
            }
        case ("keywords", "show"):
            try args.allow(["country", "device", "delta"])
            let settings = try settings(args)
            let detail = try await engine(args).keywordDetail(try args.positional(3, "keyword"), appID: try args.integer(2, "app ID"),
                                                              countryCode: try required(args, "country"), device: try deviceOption(args) ?? .iPhone,
                                                              deltaReference: try deltaOption(args) ?? settings.deltaReference,
                                                              golden: settings.golden)
            write(args, detail) { Self.detailText($0) }
        case ("keywords", "note"):
            try args.allow(["country", "device", "text"])
            let keyword = try args.positional(3, "keyword")
            guard let text = args.option("text") else { throw UsageError("Missing --text (an empty text clears the note).") }
            try await engine(args).setNote(text, keyword: keyword, appID: try args.integer(2, "app ID"), countryCode: try required(args, "country"),
                                           device: try deviceOption(args) ?? .iPhone)
            write(args, ["keyword": keyword, "note": text]) { _ in text.isEmpty ? "Cleared the note." : "Saved the note." }
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
                try args.allow(["country", "device", "depth", "keywords"])
                let id = try args.integer(1, "app ID")
                let only = args.option("keywords").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                if only?.isEmpty == true { throw UsageError("--keywords needs at least one keyword.") }
                summary = try await engine(args).measure(appID: id, countryCode: args.option("country"), device: try deviceOption(args),
                                                         depth: depth, keywords: only, progress: report)
                nothing = "Nothing to measure. Add keywords with: aso keywords add \(id) <keyword>... --country US"
            }
            write(args, summary) { s in
                guard s.measured > 0 else { return nothing }
                var text = "Measured \(s.measured): \(s.found) ranked, \(s.outside) outside the results, \(s.failed) failed."
                if let refreshes = s.popularity { text += "\n" + Self.popularityText(refreshes) }
                if let error = s.popularityError { text += "\nPopularity was not refreshed: \(error)" }
                return text
            }
        case ("popularity", _):
            try args.allow(["country", "device", "keywords"])
            let id = try args.integer(1, "app ID")
            let only = args.option("keywords").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            if only?.isEmpty == true { throw UsageError("--keywords needs at least one keyword.") }
            let errors = self.errors
            let quiet = args.flag("json")
            let refreshes = try await engine(args).refreshPopularity(appID: id, countryCode: args.option("country"), device: try deviceOption(args),
                                                                     keywords: only) { step in if !quiet { errors("Reading \(step)") } }
            write(args, refreshes) { $0.isEmpty ? "No keywords yet. Add some with: aso keywords add \(id) <keyword>... --country US" : Self.popularityText($0) }
        case ("discover", _):
            try args.allow(["country", "device", "competitor", "seeds", "difficulty"])
            let id = try args.integer(1, "app ID")
            let seeds = args.option("seeds").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            if seeds?.isEmpty == true { throw UsageError("--seeds needs at least one keyword.") }
            var competitor: Int?
            if let raw = args.option("competitor") {
                guard let parsed = AppStoreURL.parse(raw) else { throw UsageError("--competitor must be an App Store link or app ID, got \"\(raw)\".") }
                competitor = parsed.trackID
            }
            let errors = self.errors
            let jsonProgress = args.flag("json")
            let report = try await engine(args).discover(appID: id, countryCode: try required(args, "country"), device: try deviceOption(args) ?? .iPhone,
                                                         competitorID: competitor, seeds: seeds,
                                                         difficultyLimit: try args.integerOption("difficulty", default: 25, range: 0...60),
                                                         golden: try settings(args).golden) { step in
                errors(jsonProgress ? Self.json(DiscoveryProgressLine(step), pretty: false)
                                    : (step.total > 0 ? "[\(step.completed + 1)/\(step.total)] " : "") + step.step)
            }
            write(args, report) { Self.discoveryText($0, appID: id) }
        case ("ads", "sync"):
            try args.allow(["days"])
            let sync = try await engine(args).syncAds(days: try args.integerOption("days", default: 30, range: 1...90))
            write(args, sync) { s in
                "\(s.campaigns) campaign(s) in the account, \(s.matched) for tracked apps; \(s.rows) keyword × storefront row(s) for "
                    + "\(Self.day(s.periodStart)) to \(Self.day(s.periodEnd))."
            }
        case ("ads", "list"):
            try args.allow([])
            let id = try args.integer(2, "app ID")
            write(args, try await engine(args).adsReport(appID: id)) { Self.adsText($0) }
        case ("revenue", "refresh"):
            try args.allow([])
            let refresh = try await engine(args).refreshRevenue()
            write(args, refresh) { r in
                "\(r.projects) RevenueCat project(s) read." + (r.failures.isEmpty ? "" : " \(r.failures.count) key(s) failed: \(r.failures[0])")
            }
        case ("revenue", "show"):
            try args.allow([])
            let id = try args.integer(2, "app ID")
            write(args, try await engine(args).revenueReport(appID: id)) { Self.revenueText($0) }
        case ("metadata", "locales"):
            try args.allow([])
            write(args, try await engine(args).metadataLocales(appID: try args.integer(2, "app ID"))) { Self.metadataLocalesTable($0) }
        case ("metadata", "show"):
            try args.allow(["locale"])
            let id = try args.integer(2, "app ID")
            let workbench = try await engine(args)
            let locale = try await metadataLocale(args, engine: workbench, appID: id)
            write(args, try await workbench.metadata(appID: id, locale: locale)) { Self.metadataText($0) }
        case ("metadata", "draft"), ("metadata", "baseline"):
            try args.allow(Set(["locale", "stdin"] + MetadataField.allCases.map(Self.optionName)))
            let id = try args.integer(2, "app ID")
            let workbench = try await engine(args)
            let locale = try await metadataLocale(args, engine: workbench, appID: id, required: true)
            let start = try await workbench.metadata(appID: id, locale: locale)
            let isDraft = args.positionals[1] == "draft"
            let fields = try metadataFields(args, startingFrom: isDraft ? start.draft : start.baseline?.fields ?? .empty)
            let report = isDraft ? try await workbench.saveDraft(appID: id, locale: locale, fields: fields)
                                               : try await workbench.setManualBaseline(appID: id, locale: locale, fields: fields)
            write(args, report) { Self.metadataText($0) }
        case ("metadata", "reset"):
            try args.allow(["locale"])
            let id = try args.integer(2, "app ID")
            let workbench = try await engine(args)
            let locale = try await metadataLocale(args, engine: workbench, appID: id, required: true)
            write(args, try await workbench.resetDraft(appID: id, locale: locale)) { Self.metadataText($0) }
        case ("metadata", "legal"):
            try args.allow(["on", "off", "eula", "privacy", "note"])
            guard !(args.flag("on") && args.flag("off")) else { throw UsageError("Give --on or --off, not both.") }
            let enabled: Bool? = args.flag("on") ? true : args.flag("off") ? false : nil
            let settings = try await engine(args).setLegalFooter(appID: try args.integer(2, "app ID"), enabled: enabled, eulaURL: args.option("eula"),
                                                                 privacyURL: args.option("privacy"), note: args.option("note"))
            write(args, settings) { s in
                "Legal footer \(s.enabled ? "on" : "off") · Terms of Use \(s.effectiveEULA)\(s.eulaURL.isEmpty ? " (Apple's standard EULA)" : "")"
                    + " · Privacy Policy \(s.privacyURL.isEmpty ? "not set" : s.privacyURL)" + (s.note.isEmpty ? "" : " · note: \(s.note)")
            }
        case ("metadata", "footer"):
            try args.allow(["locale"])
            let id = try args.integer(2, "app ID")
            let workbench = try await engine(args)
            let locales = try args.option("locale").map { [try Self.locale($0)] }
            let batch = try await workbench.insertLegalFooter(appID: id, locales: locales)
            write(args, batch) { b in
                "Legal footer added to \(b.changed.count) of \(b.locales) draft(s)" + (b.changed.isEmpty ? "; every one already had it." : ": \(b.changed.joined(separator: ", ")).")
            }
        case ("metadata", "fill-whats-new"):
            try args.allow([])
            let batch = try await engine(args).fillEmptyWhatsNew(appID: try args.integer(2, "app ID"))
            write(args, batch) { b in
                "What's New filled with the default note in \(b.changed.count) of \(b.locales) locale(s)"
                    + (b.changed.isEmpty ? "; every one already had notes." : ": \(b.changed.joined(separator: ", ")).")
            }
        case ("metadata", "pull"):
            try args.allow([])
            write(args, try await engine(args).pullMetadata(appID: try args.integer(2, "app ID"))) { p in
                "Pulled \(p.locales.count) locale(s) from App Store Connect" + (p.locales.isEmpty ? "." : ": \(p.locales.joined(separator: ", ")).")
                    + " Version \(p.version ?? "?") (\(p.versionState ?? "?")), \(p.editable ? "editable" : "not editable: create the next version to write")."
                    + (p.privacyURL.map { " Privacy Policy for the legal footer: \($0)." } ?? "")
            }
        case ("metadata", "versions"):
            try args.allow([])
            write(args, try await engine(args).ascVersions(appID: try args.integer(2, "app ID"))) { versions in
                var table = TextTable([.init("Version"), .init("State"), .init("Editable")])
                for v in versions { table.add([v.version, v.state, v.editable ? "yes" : "no"]) }
                return versions.isEmpty ? "No iOS versions on App Store Connect." : table.render()
            }
        case ("metadata", "create-version"):
            try args.allow(["yes"])
            let id = try args.integer(2, "app ID")
            let version = try args.positional(3, "version")
            guard args.flag("yes") else {
                throw NotSent("This creates version \(version) on App Store Connect. Run again with --yes to create it.")
            }
            write(args, try await engine(args).createVersion(appID: id, version: version)) { v in
                "Created version \(v.version) (\(v.state)). Its listing can be written now; upload the build from Xcode when it is ready."
            }
        case ("metadata", "plan"):
            try args.allow(["locale", "create-missing", "copy-screenshots-from", "all"])
            let id = try args.integer(2, "app ID")
            let workbench = try await engine(args)
            let options = try publishOptions(args, createMissing: args.flag("create-missing") || args.flag("all"))
            if args.flag("all") {
                guard args.option("locale") == nil else { throw UsageError("Choose --locale or --all, not both.") }
                write(args, try await workbench.publishPlans(appID: id, options: options)) { Self.plansText($0) }
            } else {
                let locale = try await metadataLocale(args, engine: workbench, appID: id, required: true)
                write(args, try await workbench.publishPlan(appID: id, locale: locale, options: options)) { Self.planText($0) }
            }
        case ("metadata", "apply"):
            try args.allow(["locale", "create-missing", "copy-screenshots-from", "yes"])
            let id = try args.integer(2, "app ID")
            let workbench = try await engine(args)
            let locale = try await metadataLocale(args, engine: workbench, appID: id, required: true)
            let options = try publishOptions(args, createMissing: args.flag("create-missing"))
            guard args.flag("yes") else {
                write(args, try await workbench.publishPlan(appID: id, locale: locale, options: options)) { Self.planText($0) }
                throw NotSent("Nothing was sent to App Store Connect. Review the plan, then run again with --yes to apply it.")
            }
            let result = try await workbench.publish(appID: id, locale: locale, options: options)
            write(args, result) { Self.publishText($0) }
            guard ["applied", "partial"].contains(result.status) else { throw NotSent("\(locale.rawValue) was not applied.") }
        case ("metadata", "apply-all"):
            try args.allow(["locales", "copy-screenshots-from", "yes"])
            let id = try args.integer(2, "app ID")
            let workbench = try await engine(args)
            let locales = try args.option("locales").map { raw in
                try raw.split(separator: ",").map { try Self.locale($0.trimmingCharacters(in: .whitespaces)) }
            }
            let options = try publishOptions(args, createMissing: true)
            guard args.flag("yes") else {
                write(args, try await workbench.publishPlans(appID: id, locales: locales, options: options)) { Self.plansText($0) }
                throw NotSent("Nothing was sent to App Store Connect. Review the plans, then run again with --yes to apply them.")
            }
            let results = try await workbench.publishAll(appID: id, locales: locales, copyScreenshotsFrom: options.copyScreenshotsFrom)
            write(args, results) { $0.isEmpty ? "No locale has a draft to apply." : $0.map(Self.publishText).joined(separator: "\n") }
            let missed = results.filter { !["applied", "partial"].contains($0.status) }.map(\.locale)
            guard missed.isEmpty else { throw NotSent("Not applied: \(missed.joined(separator: ", ")).") }
        case ("metadata", "log"):
            try args.allow([])
            write(args, try await engine(args).changeLog(appID: try args.integer(2, "app ID"))) { log in
                var table = TextTable([.init("When"), .init("Locale"), .init("Status"), .init("Fields"), .init("Note")])
                for e in log { table.add([Self.shortDate(e.createdAt), e.locale, e.status, e.changes.map(\.field.title).joined(separator: ", "), e.note]) }
                return log.isEmpty ? "Nothing has been applied to App Store Connect yet." : table.render()
            }
        case ("ratings", "check"):
            try args.allow(["country", "all"])
            let check = try await engine(args).checkRatings(appID: try args.integer(2, "app ID"), countries: try countriesOption(args))
            write(args, check) { c in
                "Checked \(c.storefronts) storefront(s): \(c.recorded) reading(s) stored, \(c.newRatings) new rating(s) since the previous check."
                    + (c.unavailable.isEmpty ? "" : " No ratings in \(c.unavailable.joined(separator: ", ")).")
                    + (c.failed.isEmpty ? "" : " Failed: \(c.failed.joined(separator: ", ")).")
                    + (c.newRelease.map { " New release marker: \($0.title), \(Self.shortDate($0.date))." } ?? "")
            }
        case ("ratings", "list"):
            try args.allow([])
            let id = try args.integer(2, "app ID")
            write(args, try await engine(args).ratings(appID: id)) { Self.ratingsTable($0, appID: id) }
        case ("reviews", "check"):
            try args.allow(["country", "all"])
            let check = try await engine(args).checkReviews(appID: try args.integer(2, "app ID"), countries: try countriesOption(args))
            write(args, check) { c in
                "Checked \(c.storefronts) storefront(s): \(c.added) new review(s), \(c.stored) stored."
                    + (c.failed.isEmpty ? "" : " Failed: \(c.failed.joined(separator: ", ")).")
            }
        case ("reviews", "list"):
            try args.allow(["country", "min-rating", "new", "search"])
            let id = try args.integer(2, "app ID")
            if let country = args.option("country"), StorefrontRegistry.lookup(country.uppercased()) == nil {
                throw UsageError("\"\(country)\" is not a supported App Store country code.")
            }
            let filter = Engine.ReviewFilter(country: args.option("country"), minRating: try args.integerOption("min-rating", default: 1, range: 1...5),
                                             onlyNew: args.flag("new"), search: args.option("search"))
            write(args, try await engine(args).reviewsReport(appID: id, filter: filter)) { Self.reviewsText($0, appID: id) }
        case ("competitors", _):
            try args.allow(["country", "device", "depth"])
            let id = try args.integer(1, "app ID")
            let report = try await engine(args).competitors(appID: id, countryCode: try required(args, "country"), device: try deviceOption(args) ?? .iPhone,
                                                            depth: try args.integerOption("depth", default: 10, range: 1...50))
            write(args, report) { Self.competitorsText($0, appID: id) }
        case ("markers", "list"):
            try args.allow([])
            let id = try args.integer(2, "app ID")
            write(args, try await engine(args).markers(appID: id)) { Self.markersTable($0, appID: id) }
        case ("markers", "add"):
            try args.allow(["title", "date"])
            let marker = try await engine(args).addNote(appID: try args.integer(2, "app ID"), title: try required(args, "title"),
                                                        date: try dateOption(args, "date"))
            write(args, marker) { "Added note \($0.id): \($0.title), \(Self.shortDate($0.date))." }
        case ("markers", "remove"):
            try args.allow([])
            let markerID = try args.integer(3, "marker ID")
            try await engine(args).removeMarker(appID: try args.integer(2, "app ID"), id: markerID)
            write(args, ["removed": markerID]) { _ in "Removed marker \(markerID)." }
        case ("impact", _):
            try args.allow([])
            let report = try await engine(args).impact(appID: try args.integer(1, "app ID"), markerID: try args.integer(2, "marker ID"))
            write(args, report) { Self.impactText($0) }
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

    /// A write to App Store Connect that did not happen: unconfirmed, refused or failed. What was planned or tried is
    /// already printed; the exit code says so.
    struct NotSent: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// --copy-screenshots-from, which only applies to locales that are created.
    private func publishOptions(_ args: Arguments, createMissing: Bool) throws -> Engine.PublishOptions {
        let from = try args.option("copy-screenshots-from").map(Self.locale)
        guard from == nil || createMissing else {
            throw UsageError("--copy-screenshots-from fills a locale that is created; add --create-missing.")
        }
        return Engine.PublishOptions(createMissing: createMissing, copyScreenshotsFrom: from)
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

    /// One discovery step as `discover --json` reports it on stderr.
    struct DiscoveryProgressLine: Encodable {
        let step: String
        let completed: Int
        let total: Int

        init(_ progress: Engine.DiscoveryProgress) {
            step = progress.step
            completed = progress.completed
            total = progress.total
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

    static func optionName(_ field: MetadataField) -> String {
        switch field {
        case .name: "name"
        case .subtitle: "subtitle"
        case .keywords: "keywords"
        case .promotionalText: "promotional-text"
        case .description: "description"
        case .whatsNew: "whats-new"
        }
    }

    static func locale(_ raw: String) throws -> AppLocale {
        guard let locale = AppLocale.parse(raw) else {
            throw UsageError("\"\(raw)\" is not an App Store locale. Locales: \(AppLocale.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return locale
    }

    /// --locale, or the first locale worth writing when the command can do without it.
    private func metadataLocale(_ args: Arguments, engine: Engine, appID: Int, required: Bool = false) async throws -> AppLocale {
        if let raw = args.option("locale") { return try Self.locale(raw) }
        guard !required else { throw UsageError("Give the locale with --locale, e.g. --locale en-US.") }
        let first = try await engine.metadataLocales(appID: appID).first?.locale ?? AppLocale.enUS.rawValue
        return try Self.locale(first)
    }

    /// Every field from standard input as JSON (--stdin), or the given field options over `start`.
    private func metadataFields(_ args: Arguments, startingFrom start: MetadataFields) throws -> MetadataFields {
        if args.flag("stdin") {
            guard args.names.isDisjoint(with: MetadataField.allCases.map(Self.optionName)) else {
                throw UsageError("Give the fields either as JSON on standard input (--stdin) or as options, not both.")
            }
            do {
                return try JSONDecoder().decode(MetadataFields.self, from: Data(input().utf8))
            } catch {
                throw UsageError("Standard input must be a JSON object with name, subtitle, keywords, promotionalText, description and whatsNew.")
            }
        }
        var fields = start
        var given = 0
        for field in MetadataField.allCases {
            guard let value = args.option(Self.optionName(field)) else { continue }
            fields[field] = value
            given += 1
        }
        guard given > 0 else {
            throw UsageError("Give at least one field: --name, --subtitle, --keywords, --promotional-text, --description, --whats-new (or --stdin).")
        }
        return fields
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

    /// `--country CC[,CC…]` or `--all`; nil means the app's market countries.
    private func countriesOption(_ args: Arguments) throws -> [String]? {
        if args.flag("all") {
            guard args.option("country") == nil else { throw UsageError("Choose --country or --all, not both.") }
            return Engine.allCountries
        }
        guard let raw = args.option("country") else { return nil }
        let countries = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !countries.isEmpty else { throw UsageError("--country needs at least one country code.") }
        return countries
    }

    /// The --delta option, or nil to use the setting.
    private func deltaOption(_ args: Arguments) throws -> DeltaReference? {
        guard let raw = args.option("delta") else { return nil }
        guard let reference = DeltaReference.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
            throw UsageError("--delta must be one of: \(DeltaReference.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return reference
    }

    /// An ISO 8601 date and time ("2026-10-20T14:30:00Z", or with an offset), or a day ("2026-10-20", midnight UTC).
    private func dateOption(_ args: Arguments, _ name: String) throws -> Date? {
        guard let raw = args.option(name) else { return nil }
        let full = ISO8601DateFormatter()
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        guard let date = full.date(from: raw) ?? day.date(from: raw) else {
            throw UsageError("--\(name) must be a date like 2026-10-20 or 2026-10-20T14:30:00Z, got \"\(raw)\".")
        }
        return date
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

    /// Date and time for tables.
    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The inspector in text: summary, difficulty, the latest top ten and the last attempts.
    static func detailText(_ detail: KeywordDetail) -> String {
        let row = detail.row
        let s = detail.summary
        var text = "\(row.keyword) · \(row.country) \(row.device)\n"
        text += "Latest \(row.rankLabel)  ·  best \(s.best.map { "#\($0)" } ?? "—")  ·  \(s.measurements) measurement(s), \(s.outside) outside the results"
        if let d = row.delta { text += "  ·  Δ \(d > 0 ? "+\(d)" : String(d)) (\(row.deltaAgainst))" }
        if !row.note.isEmpty { text += "\nNote: \(row.note)" }
        if let month = row.popularityMonth {
            let label = popularityLabel(row)
            let genre: AppleAdsGenre? = row.popularityGenre.flatMap(AppleAdsGenre.init(rawValue:))
            var source = ", not on the list"
            if row.popularitySource == "list" { source = genre.map { ", \($0.displayName) list" } ?? "" }
            text += "\nPopularity \(label.isEmpty ? "—" : label) (Apple Ads, \(Self.month(month))\(source))"
            if let opportunity = row.opportunity { text += String(format: "  ·  opportunity %.0f", opportunity) }
            if row.golden { text += "  ·  golden" }
        }
        if let ads = row.ads {
            text += "\nYour Apple Ads: \(ads.impressions) impressions, \(ads.taps) taps, \(ads.installs) installs, "
                + String(format: "%.2f %@ spent", ads.spend, ads.currency)
        }
        if let difficulty = detail.difficulty {
            text += "\n\nDifficulty \(Int(difficulty.score.rounded())) of 100 (\(difficulty.tier))"
            if let mass = row.ratingMass { text += "  ·  rating mass \(mass)" }
            if let titles = row.titleMatchesTop10 { text += "  ·  \(titles) of the top 10 name the term" }
        }
        if !detail.topResults.isEmpty {
            var table = TextTable([.init("#", .right), .init("App"), .init("Seller"), .init("Ratings", .right)])
            for r in detail.topResults {
                table.add([String(r.position), (r.isOwnApp ? "★ " : "") + r.name, r.sellerName, r.ratingCount.map(String.init) ?? ""])
            }
            text += "\n\nTop results\n" + table.render()
        }
        if !detail.observations.isEmpty {
            var table = TextTable([.init("Measured"), .init("Rank", .right), .init("Provider")])
            for o in detail.observations.suffix(10).reversed() {
                table.add([Self.shortDate(o.fetchedAt), o.label, o.provider])
            }
            text += "\n\nLast measurements\n" + table.render()
        }
        return text
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
        var table = TextTable([.init("Keyword"), .init("Market"), .init("Rank", .right), .init("Δ", .right), .init("Popularity", .right),
                               .init("Difficulty", .right), .init("Brand"), .init("Measured")])
        for row in rows {
            let delta: String = row.delta.map { $0 > 0 ? "+\($0)" : String($0) } ?? ""
            let difficulty: String = row.difficulty.map { String(Int($0.rounded())) } ?? ""
            table.add([row.keyword, "\(row.country) \(row.device)", row.rankLabel, delta, Self.popularityLabel(row), difficulty,
                       row.brandLike ? "yes" : "", row.measuredAt.map(Self.shortDate) ?? "never"])
        }
        var text = table.render() + "\n\nΔ: \(reference.title); positive = moved up."
        if rows.contains(where: { $0.popularitySource == "belowRange" }) {
            text += "\nPopularity \"< N\": not on Apple's list that month, so below its lowest published score N."
        }
        return text
    }

    /// "62", "< 31" below the published range, "< list" when the list's lowest score was not read, "" before the first refresh.
    static func popularityLabel(_ row: KeywordReportRow) -> String {
        if let value = row.popularity { return String(value) }
        guard row.popularitySource == "belowRange" else { return "" }
        return row.popularityBelow.map { "< \($0)" } ?? "< list"
    }

    static func ratingsTable(_ rows: [Engine.RatingRow], appID: Int) -> String {
        guard !rows.isEmpty else { return "No ratings recorded yet. Read them with: aso ratings check \(appID)" }
        var table = TextTable([.init("Storefront"), .init("Ratings", .right), .init("Average", .right), .init("Since last check", .right),
                               .init("Last new rating"), .init("Checked")])
        for r in rows {
            table.add(["\(r.countryName) (\(r.country))", String(r.count), r.average.map { String(format: "%.2f", $0) } ?? "—",
                       r.delta.map { $0 == 0 ? "—" : String(format: "%+d", $0) } ?? "first check",
                       r.lastNewAt.map(Self.shortDate) ?? "—", Self.shortDate(r.checkedAt)])
        }
        return table.render()
    }

    static func reviewsText(_ report: Engine.ReviewsReport, appID: Int) -> String {
        guard report.stored > 0 else { return "No written reviews stored yet. Read them with: aso reviews check \(appID)" }
        let stars = (1...5).reversed().map { "\($0)★ \(report.stars[$0 - 1])" }.joined(separator: "  ")
        var text = "\(report.stored) stored · \(report.new) new · " + (report.average.map { String(format: "average %.1f", $0) } ?? "") + "  ·  \(stars)"
        guard !report.reviews.isEmpty else { return text + "\n\nNo reviews match." }
        for r in report.reviews {
            text += "\n\n" + String(repeating: "★", count: r.rating) + String(repeating: "☆", count: max(0, 5 - r.rating)) + "  \(r.title)"
                + (r.isNew ? "  [new]" : "")
            if !r.body.isEmpty { text += "\n" + r.body }
            var byline: [String] = r.author.isEmpty ? [] : [r.author]
            if let version = r.version { byline.append("v\(version)") }
            byline.append(r.country)
            byline.append(Self.shortDate(r.date ?? r.fetchedAt))
            text += "\n" + byline.joined(separator: " · ")
        }
        return text
    }

    static func competitorsText(_ report: Engine.CompetitorsReport, appID: Int) -> String {
        guard report.keywordsMeasured > 0 else {
            return "No measurements yet in \(report.market). Competitors are the apps in those search results; measure first: aso measure \(appID)"
        }
        var table = TextTable([.init("App"), .init("Seller"), .init("Keywords", .right), .init("Top 10", .right), .init("Avg. position", .right),
                               .init("Ratings", .right), .init("ID", .right)])
        for c in report.competitors {
            table.add([c.name, c.sellerName, String(c.keywords), String(c.top10), String(format: "%.1f", c.averagePosition),
                       c.ratingCount.map(String.init) ?? "", String(c.trackID)])
        }
        return "Apps in the top \(report.depth) of \(report.keywordsMeasured) measured keyword(s) in \(report.market)\n\n" + table.render()
            + "\n\nOnly tracked searches count; this is not a competitor's full keyword set."
    }

    static func markersTable(_ markers: [MarkerRecord], appID: Int) -> String {
        guard !markers.isEmpty else {
            return "Nothing on the timeline yet. Releases are recorded when you measure or check ratings; pin a note with: aso markers add \(appID) --title TEXT"
        }
        var table = TextTable([.init("ID", .right), .init("Date"), .init("Kind"), .init("Title"), .init("Seen in")])
        for m in markers { table.add([String(m.id), Self.shortDate(m.date), m.kind, m.title, m.country ?? ""]) }
        return table.render() + "\n\nThe effect of one: aso impact \(appID) <marker ID>"
    }

    /// "September 2026", in UTC: the period starts at midnight UTC, which is the previous day west of Greenwich.
    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }

    /// "2026-10-24", in UTC.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func revenueText(_ report: Engine.RevenueReport) -> String {
        guard let s = report.latest else {
            return "No RevenueCat project matches this app. Read them with: aso revenue refresh (projects are matched by bundle ID, then by name)."
        }
        let change: String = report.mrrChange.map { String(format: " (%+.0f since the previous day)", $0) } ?? ""
        var text = "\(s.projectName) · read \(Self.shortDate(s.fetchedAt))" + (s.appNames.count > 1 ? " · holds \(s.appNames.joined(separator: ", "))" : "")
        text += String(format: "\nMRR $%.0f", s.mrr) + change
        text += "  ·  active subscriptions \(s.activeSubscriptions)"
        text += String(format: "  ·  revenue 28 days $%.0f", s.revenue28d)
        text += "  ·  new customers 28 days \(s.newCustomers28d)  ·  active trials \(s.activeTrials)"
        if report.history.count > 1 {
            var table = TextTable([.init("Read"), .init("MRR", .right), .init("Active subs", .right), .init("Revenue 28d", .right),
                                   .init("New customers", .right), .init("Trials", .right)])
            for h in report.history {
                table.add([Self.shortDate(h.fetchedAt), String(format: "$%.0f", h.mrr), String(h.activeSubscriptions),
                           String(format: "$%.0f", h.revenue28d), String(h.newCustomers28d), String(h.activeTrials)])
            }
            text += "\n\n" + table.render()
        }
        return text
    }

    static func metadataLocalesTable(_ locales: [Engine.MetadataLocale]) -> String {
        var table = TextTable([.init("Locale"), .init("Language"), .init("Market"), .init("Baseline"), .init("Draft"), .init("Changed", .right),
                               .init("Errors", .right)])
        for l in locales {
            table.add([l.locale, l.name, l.market ?? "", l.baseline.map { $0 == "asc" ? "App Store Connect" : "manual" } ?? "none",
                       l.hasDraft ? "saved" : "", l.baseline == nil ? "" : String(l.changes), l.errors == 0 ? "" : String(l.errors)])
        }
        return table.render()
    }

    static func metadataText(_ report: Engine.MetadataReport) -> String {
        var lines = ["\(report.locale) · \(report.name)" + (report.market.map { " · rules read for \($0)" } ?? "")]
        if let b = report.baseline {
            lines.append("Baseline: " + (b.source == "asc" ? "App Store Connect" : "entered manually")
                         + (b.versionString.map { " · version \($0)\(b.versionState.map { " (\($0))" } ?? "")" } ?? "") + " · \(shortDate(b.fetchedAt))")
        } else {
            lines.append("No baseline: set one with aso metadata baseline to see what changes.")
        }
        lines.append(report.draftUpdatedAt.map { "Draft saved \(shortDate($0))." } ?? "No draft yet; the fields below are the baseline.")
        lines.append("")
        for field in MetadataField.allCases {
            let value = report.draft[field]
            let m = TextMeasure(value)
            let bytes = m.isMultiByte || field == .keywords ? ", \(m.utf8Bytes) bytes" : ""
            lines.append("\(field.title) (\(m.codePoints)/\(field.limit)\(bytes)):")
            lines.append(value.isEmpty ? "  (empty)" : value.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
        }
        lines.append("")
        lines.append("ASO rules: \(report.rules.score)/100 · \(report.rules.charactersUsed)/160 indexed characters")
        for f in report.rules.findings { lines.append("  \(f.kind.rawValue)  \(f.message)") }
        for i in report.issues { lines.append("  \(i.severity)  \(i.field.title): \(i.message)") }
        lines.append("Legal footer: " + (!report.legal.settings.enabled ? "off" : report.legal.inDescription ? "in the description" : "not in the description yet"))
        if report.baseline != nil {
            lines.append("")
            lines.append(report.changes.isEmpty ? "The draft equals the baseline." : "Changes against the baseline:")
            for c in report.changes {
                if c.field == .keywords, let k = report.keywordChange {
                    lines.append("  Keywords: + \(k.added.joined(separator: ", ")) · − \(k.removed.joined(separator: ", ")) · \(k.kept.count) kept")
                } else {
                    lines.append("  \(c.field.title): \"\(c.before)\" → \"\(c.after)\"")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func planText(_ plan: Engine.PublishPlan) -> String {
        var lines = ["\(plan.locale) · \(plan.name) · " + (plan.exists ? "on App Store Connect" : "new on App Store Connect")
                     + " · version \(plan.version ?? "?") (\(plan.versionState ?? "?"))"]
        for note in plan.automatic { lines.append("  Automatic: \(note)") }
        for issue in plan.errors { lines.append("  error  \(issue.field.title): \(issue.message)") }
        for c in plan.changes {
            lines.append(plan.exists ? "  \(c.field.title): \"\(c.before)\" → \"\(c.after)\"" : "  \(c.field.title): \"\(c.after)\"")
        }
        lines.append(plan.blocked.map { "Would be refused: \($0)" } ?? "Ready: \(plan.changes.count) field(s) would be sent.")
        return lines.joined(separator: "\n")
    }

    static func plansText(_ plans: [Engine.PublishPlan]) -> String {
        plans.isEmpty ? "No locale has a draft to apply." : plans.map(planText).joined(separator: "\n\n")
    }

    static func publishText(_ result: Engine.PublishResult) -> String {
        switch result.status {
        case "applied", "partial": result.message
        case "refused": "\(result.locale): refused. \(result.message)"
        default: "\(result.locale): failed. \(result.message)"
        }
    }

    static func adsText(_ report: Engine.AdsReport) -> String {
        guard let synced = report.syncedAt, let start = report.periodStart, let end = report.periodEnd else {
            return "No campaign results stored for this app. Read them with: aso ads sync"
        }
        var text = "Your Apple Ads results, \(Self.day(start)) to \(Self.day(end)) (synced \(Self.shortDate(synced)))\n\n"
        var storefronts = TextTable([.init("Storefront"), .init("Impressions", .right), .init("Taps", .right), .init("Installs", .right),
                                     .init("Spend", .right), .init("Cost / install", .right), .init("Tap → install", .right)])
        for s in report.storefronts {
            let cpi: String = s.costPerInstall.map { String(format: "%.2f", $0) } ?? "—"
            let rate: String = s.tapToInstall.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            storefronts.add(["\(s.countryName) (\(s.country))", String(s.impressions), String(s.taps), String(s.installs),
                             String(format: "%.2f %@", s.spend, s.currency), cpi, rate])
        }
        text += storefronts.render()
        var keywords = TextTable([.init("Keyword"), .init("Storefront"), .init("Match"), .init("Impressions", .right), .init("Taps", .right),
                                  .init("Installs", .right), .init("Spend", .right), .init("Campaign")])
        for k in report.keywords.prefix(30) {
            keywords.add([k.keyword, k.country, k.matchType.lowercased(), String(k.impressions), String(k.taps), String(k.installs),
                          String(format: "%.2f %@", k.spend, k.currency), k.campaignName])
        }
        text += "\n\nKeywords by spend" + (report.keywords.count > 30 ? " (top 30 of \(report.keywords.count))" : "") + "\n" + keywords.render()
        return text
    }

    static func popularityText(_ refreshes: [Engine.PopularityRefresh]) -> String {
        refreshes.map { r in
            let list = r.genre.flatMap(AppleAdsGenre.init(rawValue:))?.displayName ?? "all \(AppleAdsGenre.allCases.count) genres"
            var text = "\(r.country): \(r.onList) of \(r.keywords) keyword(s) on Apple's list (\(list), \(Self.month(r.periodStart)))"
            if !r.genresFound.isEmpty { text += ", found in \(r.genresFound.joined(separator: ", "))" }
            if r.belowRange > 0 { text += "; \(r.belowRange) below the published range" + (r.floor.map { " (under \($0))" } ?? "") }
            return text + "."
        }.joined(separator: "\n")
    }

    static func discoveryText(_ report: Engine.DiscoveryReport, appID: Int) -> String {
        var text = "Discovery in \(report.market)" + (report.competitor.map { " from \($0)" } ?? "")
        text += " · seeds: \(report.seeds.joined(separator: ", "))\n"
        text += "\(report.candidates.count) candidate(s) · \(report.withPopularity) with an Apple popularity value · "
        text += "\(report.measured) measured for difficulty · \(report.golden) golden"
        guard !report.candidates.isEmpty else { return text + "\n\nNo candidates. Try other seeds with --seeds." }
        var table = TextTable([.init(""), .init("Keyword"), .init("Popularity", .right), .init("Difficulty", .right), .init("Opportunity", .right),
                               .init("Fit", .right), .init("Brand", .right), .init("Sources"), .init("Tracked")])
        for c in report.candidates {
            let mark = c.golden ? "★" : c.goldenLead ? "lead" : ""
            let popularity: String = c.popularity.map(String.init) ?? (c.popularitySource == "belowRange" ? "< list" : "")
            let difficulty: String = c.difficulty.map { String(Int($0.rounded())) } ?? ""
            let opportunity: String = c.opportunity.map { String(Int($0.rounded())) } ?? ""
            let fit: String = c.fit.map { String(format: "%.2f", $0) } ?? ""
            let brand: String = c.brand.map { String(format: "%.2f", $0) } ?? ""
            table.add([mark, c.keyword, popularity, difficulty, opportunity, fit, brand, c.sources.joined(separator: ", "), c.tracked ? "yes" : ""])
        }
        text += "\n\n" + table.render()
        if !report.appleAds { text += "\n\nApple Ads is not connected: no popularity, so no candidate can be golden or is measured for difficulty." }
        if !report.jev { text += "\nOpenRouter is not connected: other brands and unrelated terms are not filtered out." }
        let market = report.market.split(separator: " ").first.map(String.init) ?? "US"
        text += "\n\n★ golden · lead: the numbers pass but the term does not fit this app. Track some with: aso keywords add \(appID) <keyword>... --country \(market)"
        return text
    }

    static func impactText(_ report: Engine.ImpactReport) -> String {
        let head = "Effect of \(report.marker.title) · \(Self.shortDate(report.marker.date))"
        guard !report.rows.isEmpty else {
            return head + "\n\nNo keyword has a measurement both before and after it. Measure before a change and keep measuring after it."
        }
        var text = head + String(format: "\nNet value change %+.1f  ·  gained %+.1f  ·  lost %.1f", report.net, report.gained, report.lost)
        text += "  ·  improved \(report.improved), worsened \(report.worsened), same \(report.same)\n\n"
        var table = TextTable([.init("Keyword"), .init("Market"), .init("Before", .right), .init("After", .right), .init("Δ", .right),
                               .init("Value"), .init("Gain", .right)])
        for r in report.rows {
            let outside = "> \(r.depth)"
            let before: String = r.before.map { "#\($0)" } ?? outside
            let after: String = r.after.map { "#\($0)" } ?? outside
            let delta: String = r.delta > 0 ? "+\(r.delta)" : String(r.delta)
            let gain: String = r.value == 0 ? "0" : String(format: "%+.2f", r.gain)
            table.add([r.keyword, "\(r.country) \(r.device)", before, after, delta, r.tier, gain])
        }
        text += table.render()
        text += "\n\nValue = popularity × (1 − (difficulty/100)²) × fit, 0 for brands, unrelated terms and terms without popularity."
        text += " Gain = visibility change (#1 100 … #10 50 … #50 8) × value / 100."
        return text
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
          storefronts  ·  genres  ·  locales              The App Store countries, the Apple Ads genres, the listing languages

        Keywords
          keywords add <app ID> <keyword>... --country CC [--device iphone|ipad|mac]
          keywords remove <app ID> <keyword>... --country CC [--device ...]
          keywords list <app ID> [--country CC] [--device ...] [--delta lastMarker|previous|first|week] [--csv]
          keywords show <app ID> <keyword> --country CC [--device ...]
                                                          History, top ten, difficulty and the measurement log
          keywords note <app ID> <keyword> --country CC [--device ...] --text TEXT    (empty TEXT clears it)
          measure <app ID> [--country CC] [--device ...] [--depth 1-200] [--keywords a,b,…]
                                                          Fresh rank check for each keyword (about 3 s each)
          measure --stale [--stale-hours N]               Every market not measured in the last N hours (setting staleHours)
          popularity <app ID> [--country CC] [--device ...] [--keywords a,b,…]
                                                          Apple Ads popularity (needs the Apple Ads keys); measure refreshes it too

        Ratings, reviews and competitors
          ratings check <app ID> [--country CC,… | --all]  Rating count and average per storefront (default: the app's markets)
          ratings list <app ID>                           Per storefront: latest count, change since the last check, last new rating
          reviews check <app ID> [--country CC,… | --all]  Read the newest written reviews; ones not seen before are marked new
          reviews list <app ID> [--country CC] [--min-rating 1-5] [--new] [--search TEXT]
          competitors <app ID> --country CC [--device ...] [--depth 1-50]
                                                          Apps in the latest results of your tracked keywords (default top 10)
          measure reads ratings and new reviews in the measured storefronts first.

        Apple Ads campaigns (your own results, same keys as popularity)
          ads sync [--days 1-90]                          Read the last N days (30) of every campaign for a tracked app
          ads list <app ID>                               Impressions, taps, installs and spend per storefront and keyword

        Revenue (RevenueCat, read-only)
          revenue refresh                                 Read every project's MRR, subscriptions, 28-day revenue, customers, trials
          revenue show <app ID>                           The app's project (by bundle ID, then name) and its daily history

        Metadata (drafts stay on this computer)
          metadata locales <app ID>                       Locales worth writing: baseline, draft, changes and errors
          metadata show <app ID> [--locale L]             The draft, its counters, ASO rules and changes against the baseline
          metadata draft <app ID> --locale L (--name T | --subtitle T | --keywords K | --promotional-text T | --description T | --whats-new T | --stdin)
                                                          Save fields of the draft; --stdin reads every field as JSON
          metadata baseline <app ID> --locale L (field options | --stdin)
                                                          What is live on the App Store today, typed in, to diff against
          metadata reset <app ID> --locale L              Drop the draft and start again from the baseline
          metadata legal <app ID> [--on | --off] [--eula URL] [--privacy URL] [--note TEXT]
                                                          Terms of Use and Privacy Policy links for every description
          metadata footer <app ID> [--locale L]           Append those links to the drafts (each in its own language)
          metadata fill-whats-new <app ID>                Give drafts without release notes the default note in their language

        Publishing (App Store Connect key; writes need --yes)
          metadata pull <app ID>                          Read every locale from App Store Connect as the baseline
          metadata versions <app ID>                      The app's iOS versions and whether their listing can be edited
          metadata create-version <app ID> <version> --yes
                                                          Create the next version in Prepare for Submission
          metadata plan <app ID> (--locale L | --all) [--create-missing] [--copy-screenshots-from L]
                                                          What applying would send, read from App Store Connect; writes nothing
          metadata apply <app ID> --locale L [--create-missing] [--copy-screenshots-from L] --yes
                                                          Write the draft, then re-read it (without --yes: the plan only)
          metadata apply-all <app ID> [--locales a,b] [--copy-screenshots-from L] --yes
                                                          Apply every draft, creating missing locales
          metadata log <app ID>                           Every attempt to write the listing

        Releases and changes
          markers list <app ID>                           Releases (seen when measuring or checking ratings) and notes
          markers add <app ID> --title TEXT [--date 2026-10-20|2026-10-20T14:30:00Z]
                                                          Pin a note (e.g. "keywords updated") to compare ranks around
          markers remove <app ID> <marker ID>
          impact <app ID> <marker ID>                     Ranks before and after it, weighted by what each keyword is worth

        Research (nothing is stored)
          discover <app ID> --country CC [--device ...] [--competitor LINK|ID] [--seeds a,b,…] [--difficulty 0-60]
                                                          Golden keyword candidates: autocomplete, Apple Ads and Jev
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
