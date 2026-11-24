import Foundation
import ASOCore
import ASOProviders

/// App Store Connect behind a protocol, so publishing is tested without the network; the live one holds the stored key.
public protocol MetadataPublisher: Sendable {
    func resolveAppID(bundleID: String) async throws -> String
    /// Every locale of the editable version (else the newest) and of the editable app info.
    func snapshots(ascAppID: String) async throws -> [MetadataSnapshot]
    func privacyPolicyURL(ascAppID: String) async throws -> String?
    /// Newest first.
    func versions(ascAppID: String) async throws -> [Engine.ASCVersion]
    func createVersion(ascAppID: String, versionString: String) async throws -> Engine.ASCVersion
    /// Creates the locale on the editable version and the app info where it is missing, then re-reads it.
    func ensureLocalizations(ascAppID: String, locale: AppLocale, name: String) async throws -> MetadataSnapshot
    func copyScreenshots(fromLocalization source: String, toLocalization target: String) async throws -> Engine.ScreenshotCopy
    /// Writes the changed fields, then re-reads the locale and returns what Apple holds.
    func apply(ascAppID: String, snapshot: MetadataSnapshot, changes: [MetadataField: String]) async throws -> MetadataSnapshot
}

/// The macOS app's App Store Connect client with the stored key.
public struct AppStoreConnectPublisher: MetadataPublisher {
    let provider: ASCMetadataProvider

    public init(credentials: ASCCredentials) {
        provider = ASCMetadataProvider(credentials: credentials)
    }

    public func resolveAppID(bundleID: String) async throws -> String { try await provider.resolveAppID(bundleID: bundleID) }
    public func snapshots(ascAppID: String) async throws -> [MetadataSnapshot] { try await provider.snapshots(ascAppID: ascAppID) }
    public func privacyPolicyURL(ascAppID: String) async throws -> String? { try await provider.privacyPolicyURL(ascAppID: ascAppID) }

    public func versions(ascAppID: String) async throws -> [Engine.ASCVersion] {
        try await provider.versions(ascAppID: ascAppID).map(Engine.ASCVersion.init)
    }

    public func createVersion(ascAppID: String, versionString: String) async throws -> Engine.ASCVersion {
        Engine.ASCVersion(try await provider.createVersion(ascAppID: ascAppID, versionString: versionString))
    }

    public func ensureLocalizations(ascAppID: String, locale: AppLocale, name: String) async throws -> MetadataSnapshot {
        try await provider.ensureLocalizations(ascAppID: ascAppID, locale: locale, name: name)
    }

    public func copyScreenshots(fromLocalization source: String, toLocalization target: String) async throws -> Engine.ScreenshotCopy {
        let report = try await provider.copyScreenshots(fromLocalization: source, toLocalization: target)
        return Engine.ScreenshotCopy(sets: report.sets, copied: report.copied, skipped: report.skipped, errors: report.errors)
    }

    public func apply(ascAppID: String, snapshot: MetadataSnapshot, changes: [MetadataField: String]) async throws -> MetadataSnapshot {
        try await provider.apply(ascAppID: ascAppID, snapshot: snapshot, changes: changes)
    }
}

/// Pull → draft → plan → apply → re-read, as the macOS app's Metadata editor publishes. An apply refuses to write when
/// the stored baseline no longer matches what Apple holds, and every write is followed by a re-read.
extension Engine {
    public struct ASCVersion: Sendable, Codable, Equatable {
        public let id: String
        public let version: String
        public let state: String
        /// Its metadata can still be edited.
        public let editable: Bool

        public init(id: String, version: String, state: String) {
            self.id = id
            self.version = version
            self.state = state
            editable = MetadataPublishing.isEditable(versionState: state)
        }

        init(_ info: ASCMetadataProvider.VersionInfo) {
            self.init(id: info.id, version: info.versionString, state: info.state)
        }
    }

    public struct ScreenshotCopy: Sendable, Codable, Equatable {
        public let sets: Int
        public let copied: Int
        /// Screenshots left alone because the target set already had some.
        public let skipped: Int
        public let errors: [String]

        public init(sets: Int, copied: Int, skipped: Int, errors: [String]) {
            self.sets = sets
            self.copied = copied
            self.skipped = skipped
            self.errors = errors
        }
    }

    public struct MetadataPull: Sendable, Codable, Equatable {
        public let locales: [String]
        public let version: String?
        public let versionState: String?
        public let editable: Bool
        /// The privacy policy address taken from App Store Connect for the legal footer, when none was set.
        public let privacyURL: String?
    }

    public struct PublishOptions: Sendable, Equatable {
        /// Create the locale on App Store Connect when it does not exist yet.
        public var createMissing: Bool
        /// After creating a locale, copy this locale's screenshots into it.
        public var copyScreenshotsFrom: AppLocale?

        public init(createMissing: Bool = false, copyScreenshotsFrom: AppLocale? = nil) {
            self.createMissing = createMissing
            self.copyScreenshotsFrom = copyScreenshotsFrom
        }
    }

    /// What applying a locale would do, read from App Store Connect without writing anything: the confirm step.
    public struct PublishPlan: Sendable, Codable, Equatable {
        public let locale: String
        public let name: String
        /// The locale exists on App Store Connect; otherwise applying creates it.
        public let exists: Bool
        public let version: String?
        public let versionState: String?
        public let editable: Bool
        /// The draft as it would be sent, after the automatic steps.
        public let draft: MetadataFields
        /// Against what Apple holds now (every filled field for a new locale).
        public let changes: [FieldChange]
        /// Automatic steps applied to the draft before sending, e.g. the legal footer.
        public let automatic: [String]
        public let errors: [ValidationIssue]
        /// Why applying would be refused; absent when it would write.
        public let blocked: String?
    }

    public struct PublishResult: Sendable, Codable, Equatable {
        public let locale: String
        /// "applied" · "partial" (Apple's re-read differs from the draft) · "refused" (nothing written) · "failed"
        public let status: String
        public let message: String
        public let changes: [FieldChange]
        public let screenshots: ScreenshotCopy?
    }

    static let ascNotConnected =
        "App Store Connect is not connected. Add its key with: aso connections set asc (or in the window: Settings → Connections)."

    /// Reads every locale from App Store Connect and replaces the pulled baselines; typed-in ones for other locales stay.
    /// Fills the legal footer's privacy policy address from Apple when none is set. Nothing is written to Apple.
    public func pullMetadata(appID: Int, now: Date = Date()) async throws -> MetadataPull {
        let (publisher, ascID) = try await connectedApp(appID)
        let live = try await publisher.snapshots(ascAppID: ascID)
        try await store.removePulledBaselines(appID: appID)
        for snapshot in live { try await store.replaceBaseline(Self.baseline(snapshot, now: now), appID: appID) }
        var filled: String?
        var legal = try await store.legalFooter(appID: appID) ?? LegalFooterSettings()
        if legal.privacyURL.trimmingCharacters(in: .whitespaces).isEmpty,
           let url = try? await publisher.privacyPolicyURL(ascAppID: ascID), url.hasPrefix("http") {
            legal.privacyURL = url
            try await store.setLegalFooter(legal, appID: appID)
            filled = url
        }
        let state = live.first?.versionState
        return MetadataPull(locales: live.map(\.locale.rawValue), version: live.first?.versionString, versionState: state,
                            editable: MetadataPublishing.isEditable(versionState: state), privacyURL: filled)
    }

    public func ascVersions(appID: Int) async throws -> [ASCVersion] {
        let (publisher, ascID) = try await connectedApp(appID)
        return try await publisher.versions(ascAppID: ascID)
    }

    /// Creates the next iOS version in "Prepare for Submission", so its listing can be edited while the live one stays
    /// untouched. The build is uploaded separately (from Xcode).
    public func createVersion(appID: Int, version: String) async throws -> ASCVersion {
        let version = version.trimmingCharacters(in: .whitespaces)
        guard version.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil else {
            throw EngineError.invalidArgument("A version is one to three numbers separated by periods, e.g. 2.4 or 2.4.1; not \"\(version)\".")
        }
        let (publisher, ascID) = try await connectedApp(appID)
        if let editable = try await publisher.versions(ascAppID: ascID).first(where: \.editable) {
            throw EngineError.invalidArgument("Version \(editable.version) can still be edited (\(editable.state)); write the listing there.")
        }
        return try await publisher.createVersion(ascAppID: ascID, versionString: version)
    }

    /// The confirm step: what applying the locale's draft would send, against what Apple holds now.
    public func publishPlan(appID: Int, locale: AppLocale, options: PublishOptions = PublishOptions()) async throws -> PublishPlan {
        let (publisher, ascID) = try await connectedApp(appID)
        let state = try await metadataState(appID)
        return try await plan(state, locale: locale, options: options, live: publisher.snapshots(ascAppID: ascID),
                              versions: { try await publisher.versions(ascAppID: ascID) }).plan
    }

    /// Plans for several locales from one read of App Store Connect; the drafts' locales when nil.
    public func publishPlans(appID: Int, locales: [AppLocale]? = nil, options: PublishOptions = PublishOptions()) async throws -> [PublishPlan] {
        let (publisher, ascID) = try await connectedApp(appID)
        let state = try await metadataState(appID)
        let live = try await publisher.snapshots(ascAppID: ascID)
        var plans: [PublishPlan] = []
        for locale in locales ?? state.draftLocales {
            plans.append(try await plan(state, locale: locale, options: options, live: live,
                                        versions: { try await publisher.versions(ascAppID: ascID) }).plan)
        }
        return plans
    }

    /// Writes one locale's draft to App Store Connect after the same checks as the plan, then re-reads it. The re-read
    /// becomes the baseline, and the attempt goes into the change log (an applied one onto the timeline as well).
    public func publish(appID: Int, locale: AppLocale, options: PublishOptions = PublishOptions(), now: Date = Date()) async throws -> PublishResult {
        let (publisher, ascID) = try await connectedApp(appID)
        let state = try await metadataState(appID)
        do {
            let live = try await publisher.snapshots(ascAppID: ascID)
            let planned = try await plan(state, locale: locale, options: options, live: live, versions: { try await publisher.versions(ascAppID: ascID) })
            if !planned.plan.automatic.isEmpty {
                try await store.replaceDraft(MetadataDraftRecord(locale: locale.rawValue, fields: planned.plan.draft, updatedAt: now), appID: appID)
            }
            if let blocked = planned.plan.blocked {
                if blocked == MetadataPublishing.changedRemotely, let current = planned.current {
                    try await store.replaceBaseline(Self.baseline(current, now: now), appID: appID)
                }
                return PublishResult(locale: locale.rawValue, status: "refused", message: blocked, changes: [], screenshots: nil)
            }
            let draft = planned.plan.draft
            var current: MetadataSnapshot
            var screenshots: ScreenshotCopy?
            if let existing = planned.current {
                current = existing
            } else {
                current = try await publisher.ensureLocalizations(ascAppID: ascID, locale: locale, name: draft.name)
                if let from = options.copyScreenshotsFrom, let source = live.first(where: { $0.locale == from })?.versionLocalizationID,
                   let target = current.versionLocalizationID {
                    screenshots = try await publisher.copyScreenshots(fromLocalization: source, toLocalization: target)
                }
                try await store.replaceBaseline(Self.baseline(current, now: now), appID: appID)
            }
            let screenshotNote = screenshots.map {
                MetadataPublishing.screenshotNote(sets: $0.sets, copied: $0.copied, skipped: $0.skipped, errors: $0.errors)
            } ?? ""
            let changes = MetadataDiff.changes(baseline: current.fields, draft: draft)
            guard !changes.isEmpty else {
                return PublishResult(locale: locale.rawValue, status: "refused", message: MetadataPublishing.nothingToApply(screenshotNote), changes: [],
                                     screenshots: screenshots)
            }
            let updated = try await publisher.apply(ascAppID: ascID, snapshot: current, changes: MetadataPublishing.payload(changes))
            try await store.replaceBaseline(Self.baseline(updated, now: now), appID: appID)
            let outcome = MetadataPublishing.outcome(draft: draft, reread: updated.fields)
            try await store.addChange(ChangeLogRecord(createdAt: now, locale: locale.rawValue, status: outcome.status, changes: changes,
                                                      note: outcome.note, baselineHash: current.contentHash, resultHash: updated.contentHash),
                                      appID: appID)
            try await store.addMarker(appID: appID, date: now, kind: "change",
                                      title: MetadataPublishing.markerTitle(fields: changes.map(\.field), locale: locale.rawValue))
            let automatic = planned.plan.automatic.isEmpty ? "" : " " + planned.plan.automatic.joined(separator: " ")
            return PublishResult(locale: locale.rawValue, status: outcome.status,
                                 message: "Applied \(changes.count) field(s) to \(locale.rawValue). \(outcome.note)\(screenshotNote)\(automatic)",
                                 changes: changes, screenshots: screenshots)
        } catch {
            let message = error.localizedDescription
            try await store.addChange(ChangeLogRecord(createdAt: now, locale: locale.rawValue, status: "failed", changes: [], note: message,
                                                      baselineHash: "", resultHash: nil), appID: appID)
            return PublishResult(locale: locale.rawValue, status: "failed", message: message, changes: [], screenshots: nil)
        }
    }

    /// Applies each locale in turn (the drafts' locales when nil), creating the ones App Store Connect does not have.
    public func publishAll(appID: Int, locales: [AppLocale]? = nil, copyScreenshotsFrom: AppLocale? = nil, now: Date = Date()) async throws -> [PublishResult] {
        _ = try await connectedApp(appID)
        var targets = locales ?? []
        if locales == nil { targets = try await metadataState(appID).draftLocales }
        var results: [PublishResult] = []
        for locale in targets {
            results.append(try await publish(appID: appID, locale: locale,
                                             options: PublishOptions(createMissing: true, copyScreenshotsFrom: copyScreenshotsFrom), now: now))
        }
        return results
    }

    /// Every attempt to write the listing, newest first.
    public func changeLog(appID: Int) async throws -> [ChangeLogRecord] {
        _ = try await app(appID)
        return try await store.changeLog(appID: appID)
    }

    // MARK: Helpers

    /// The plan, and the locale as Apple holds it now (nil when it does not exist yet).
    private func plan(_ state: MetadataState, locale: AppLocale, options: PublishOptions, live: [MetadataSnapshot],
                      versions: () async throws -> [ASCVersion]) async throws -> (plan: PublishPlan, current: MetadataSnapshot?) {
        var draft = state.draft(locale)
        var automatic: [String] = []
        if state.legal.enabled {
            let withFooter = LegalFooter.apply(to: draft.description, locale: locale, eulaURL: state.legal.effectiveEULA,
                                               privacyURL: state.legal.privacyURL, note: state.legal.note)
            if withFooter != draft.description {
                draft.description = withFooter
                automatic.append("Legal footer appended.")
            }
        }
        if draft.whatsNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.whatsNew = ReleaseNotesDefaults.text(for: locale)
            automatic.append("What's New was empty; the default note in \(locale.displayName) was used.")
        }
        let current = live.first { $0.locale == locale }
        // Every locale comes from the same version; with none on Apple yet, the version list says what can be edited.
        var versionString = live.first?.versionString
        var versionState = live.first?.versionState
        if live.isEmpty {
            let listed = try await versions()
            let newest = listed.first(where: \.editable) ?? listed.first
            versionString = newest?.version
            versionState = newest?.state
        }
        let editable = MetadataPublishing.isEditable(versionState: versionState)
        let errors = MetadataValidator.validate(draft).filter { $0.severity == .error }
        let changes = MetadataDiff.changes(baseline: current?.fields ?? .empty, draft: draft)
        let pulled = state.baselines[locale.rawValue].flatMap { $0.source == "asc" ? $0.fields : nil }

        let blocked: String?
        if !errors.isEmpty {
            blocked = MetadataPublishing.hasErrors
        } else if let current, MetadataPublishing.changedSincePull(baseline: pulled, live: current.fields) {
            blocked = MetadataPublishing.changedRemotely
        } else if !editable {
            blocked = "No editable version: the live version cannot take new metadata. Create the next version first (aso metadata create-version)."
        } else if current == nil, !options.createMissing {
            blocked = "Locale \(locale.rawValue) does not exist on App Store Connect yet. Apply it with --create-missing, or add the language in App Store Connect."
        } else if current == nil, let from = options.copyScreenshotsFrom, live.first(where: { $0.locale == from })?.versionLocalizationID == nil {
            blocked = "Locale \(from.rawValue) has no listing on App Store Connect to copy screenshots from."
        } else if current != nil, changes.isEmpty {
            blocked = MetadataPublishing.nothingToApply()
        } else {
            blocked = nil
        }
        let plan = PublishPlan(locale: locale.rawValue, name: locale.displayName, exists: current != nil, version: versionString,
                               versionState: versionState, editable: editable, draft: draft, changes: changes, automatic: automatic,
                               errors: errors, blocked: blocked)
        return (plan, current)
    }

    private func connectedApp(_ appID: Int) async throws -> (any MetadataPublisher, String) {
        let app = try await app(appID)
        guard let publisher else { throw EngineError.invalidArgument(Self.ascNotConnected) }
        if let known = try await store.ascAppID(appID: appID) { return (publisher, known) }
        guard let bundleID = app.bundleID, !bundleID.isEmpty else {
            throw EngineError.invalidArgument("\(app.name) has no bundle ID, so it cannot be found on App Store Connect.")
        }
        let ascID = try await publisher.resolveAppID(bundleID: bundleID)
        try await store.setASCAppID(ascID, appID: appID)
        return (publisher, ascID)
    }

    static func baseline(_ snapshot: MetadataSnapshot, now: Date) -> MetadataBaselineRecord {
        MetadataBaselineRecord(locale: snapshot.locale.rawValue, fields: snapshot.fields, source: "asc",
                               appInfoLocalizationID: snapshot.appInfoLocalizationID, versionLocalizationID: snapshot.versionLocalizationID,
                               versionString: snapshot.versionString, versionState: snapshot.versionState, fetchedAt: now)
    }
}

extension MetadataState {
    /// Locales with a saved draft, in the editor's order.
    var draftLocales: [AppLocale] { locales.filter { drafts[$0.rawValue] != nil } }
}
