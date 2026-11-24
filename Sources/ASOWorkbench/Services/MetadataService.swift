import Foundation
import Observation
import SwiftData
import ASOCore
import ASOProviders

/// Snapshot → draft → validate → diff → apply → re-read. Apply refuses to run
/// when the stored baseline no longer matches what Apple holds.
@Observable
final class MetadataService {
    private let provider: ASCMetadataProvider
    private(set) var isBusy = false
    private(set) var lastMessage: String?

    init(provider: ASCMetadataProvider) {
        self.provider = provider
    }

    var isConfigured: Bool {
        get async { await provider.isConfigured }
    }

    // MARK: Snapshots

    /// Pulls every locale from App Store Connect and replaces the stored baselines.
    func pullSnapshots(for app: TrackedApp, context: ModelContext) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let ascID = try await resolveASCID(app)
            let snapshots = try await provider.snapshots(ascAppID: ascID)
            if app.privacyURL.trimmingCharacters(in: .whitespaces).isEmpty, let url = try? await provider.privacyPolicyURL(ascAppID: ascID) {
                app.privacyURL = url
                AppLog.write("[asc] \(app.name): privacy policy URL taken from App Store Connect for the legal footer")
            }
            for old in app.snapshots where old.source == "asc" { context.delete(old) }
            for s in snapshots {
                let rec = MetadataSnapshotRecord(snapshot: s, source: "asc")
                rec.app = app
                context.insert(rec)
            }
            try? context.save()
            lastMessage = "Pulled \(snapshots.count) locale(s) from App Store Connect (version \(snapshots.first?.versionString ?? "?"), state \(snapshots.first?.versionState ?? "?"))."
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    /// Records a baseline typed or pasted by the user (no ASC connection needed).
    func setManualBaseline(for app: TrackedApp, locale: AppLocale, fields: MetadataFields, context: ModelContext) {
        for old in app.snapshots where old.localeRaw == locale.rawValue { context.delete(old) }
        let snapshot = MetadataSnapshot(locale: locale, fields: fields, appInfoLocalizationID: nil, versionLocalizationID: nil, versionString: nil, versionState: nil, fetchedAt: .now)
        let rec = MetadataSnapshotRecord(snapshot: snapshot, source: "manual")
        rec.app = app
        context.insert(rec)
        try? context.save()
    }

    /// The fields the editor should start from: an existing draft, else the baseline, else empty.
    func draftFields(for app: TrackedApp, locale: AppLocale) -> MetadataFields {
        if let existing = app.drafts.first(where: { $0.localeRaw == locale.rawValue }) { return existing.fields }
        return app.snapshots.first { $0.localeRaw == locale.rawValue }?.fields ?? .empty
    }

    /// Persists the draft, creating the record on first edit only (browsing locales leaves no trace).
    func saveDraft(_ fields: MetadataFields, for app: TrackedApp, locale: AppLocale, context: ModelContext) {
        if let existing = app.drafts.first(where: { $0.localeRaw == locale.rawValue }) {
            guard existing.fields != fields else { return }
            existing.fields = fields
        } else {
            let draft = MetadataDraftRecord(locale: locale, fields: fields)
            draft.app = app
            context.insert(draft)
        }
        try? context.save()
    }

    // MARK: Apply

    enum ApplyResult { case applied(MetadataSnapshot), refused(String), failed(String) }

    struct ApplyOptions {
        /// Create the locale on App Store Connect when it does not exist yet (version localization + app info localization).
        var createMissingLocalization = false
        /// After creating a localization, copy this locale's screenshots into it (Apple has no copy call; download + upload).
        var copyScreenshotsFrom: AppLocale? = nil
    }
    private(set) var batchProgress: String?

    func versions(app: TrackedApp) async throws -> [ASCMetadataProvider.VersionInfo] {
        try await provider.versions(ascAppID: try await resolveASCID(app))
    }

    /// Creates a new "Prepare for Submission" version so metadata can be edited while the live one stays untouched.
    func createVersion(app: TrackedApp, versionString: String) async -> String {
        isBusy = true
        defer { isBusy = false }
        do {
            let v = try await provider.createVersion(ascAppID: try await resolveASCID(app), versionString: versionString)
            lastMessage = "Created version \(v.versionString) (\(v.state)). Upload the build from Xcode when ready; metadata can be edited now."
            AppLog.write("[asc] \(app.name): created version \(v.versionString)")
        } catch {
            lastMessage = "Could not create version \(versionString): \(error.localizedDescription)"
        }
        return lastMessage ?? ""
    }

    /// Applies each locale in turn; returns one line per locale.
    func applyAll(app: TrackedApp, locales: [AppLocale], options: ApplyOptions, context: ModelContext) async -> [(AppLocale, String)] {
        var out: [(AppLocale, String)] = []
        for (i, locale) in locales.enumerated() {
            batchProgress = "\(i + 1)/\(locales.count) · \(locale.rawValue)"
            let draft = draftFields(for: app, locale: locale)
            let result = await apply(app: app, locale: locale, draft: draft, context: context, options: options)
            switch result {
            case .applied: out.append((locale, lastMessage ?? "Applied."))
            case .refused(let why): out.append((locale, "Refused: \(why)"))
            case .failed(let why): out.append((locale, "Failed: \(why)"))
            }
        }
        batchProgress = nil
        return out
    }

    /// Set by the environment: localizes release notes for a locale (nil when no writer model is configured).
    var whatsNewLocalizer: (@MainActor (_ source: String, _ sourceLocale: AppLocale, _ locale: AppLocale, _ app: TrackedApp) async throws -> String)?

    /// Fills an empty What's New: from another locale's notes (localized) or the default note in the locale's language.
    /// Returns a description of what happened, or nil when the field already had text.
    func ensureWhatsNew(_ fields: inout MetadataFields, app: TrackedApp, locale: AppLocale) async -> String? {
        guard fields.whatsNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let drafts = app.drafts.compactMap { d -> (AppLocale, String)? in
            guard let l = d.locale, l != locale else { return nil }
            let t = d.fields.whatsNew.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : (l, t)
        }
        if let (srcLocale, src) = drafts.first(where: { $0.0 == .enUS }) ?? drafts.first {
            if let localizer = whatsNewLocalizer, let text = try? await localizer(src, srcLocale, locale, app), !text.isEmpty {
                fields.whatsNew = text
                return "What's New localized from \(srcLocale.rawValue)."
            }
        }
        fields.whatsNew = ReleaseNotesDefaults.text(for: locale)
        return "What's New was empty; the default note in \(locale.displayName) was used (write real notes via Write ▸ What's New)."
    }

    /// Appends the app's legal footer to the description when configured; returns true when the text changed.
    @discardableResult
    func ensureLegalFooter(_ fields: inout MetadataFields, app: TrackedApp, locale: AppLocale) -> Bool {
        guard app.hasLegalFooter else { return false }
        let withFooter = LegalFooter.apply(to: fields.description, locale: locale, eulaURL: app.effectiveEULA, privacyURL: app.privacyURL, note: app.legalNote)
        guard withFooter != fields.description else { return false }
        fields.description = withFooter
        return true
    }

    func apply(app: TrackedApp, locale: AppLocale, draft original: MetadataFields, context: ModelContext, options: ApplyOptions = ApplyOptions()) async -> ApplyResult {
        isBusy = true
        defer { isBusy = false }
        var draft = original
        var autoNotes: [String] = []
        if ensureLegalFooter(&draft, app: app, locale: locale) { autoNotes.append("Legal footer appended.") }
        if let n = await ensureWhatsNew(&draft, app: app, locale: locale) { autoNotes.append(n) }
        if !autoNotes.isEmpty { saveDraft(draft, for: app, locale: locale, context: context) }
        let issues = MetadataValidator.validate(draft)
        if MetadataValidator.hasErrors(issues) {
            return .refused(MetadataPublishing.hasErrors)
        }
        var screenshotNote = ""
        do {
            let ascID = try await resolveASCID(app)
            // The baseline is what Apple holds now: the stored one when it still matches, or a fresh read / a newly created locale.
            let stored = app.snapshots.first { $0.localeRaw == locale.rawValue && $0.source == "asc" }?.snapshot
            let live = try await provider.snapshots(ascAppID: ascID)
            var current: MetadataSnapshot
            if let c = live.first(where: { $0.locale == locale }) {
                if MetadataPublishing.changedSincePull(baseline: stored?.fields, live: c.fields) {
                    replaceSnapshot(app: app, with: c, context: context)
                    return .refused(MetadataPublishing.changedRemotely)
                }
                current = c
            } else {
                guard options.createMissingLocalization else {
                    return .refused("Locale \(locale.rawValue) does not exist on App Store Connect yet. Use “Apply all locales” (it creates missing localizations) or add the language in App Store Connect.")
                }
                batchProgress = "\(locale.rawValue) · creating localization"
                current = try await provider.ensureLocalizations(ascAppID: ascID, locale: locale, name: draft.name)
                if let from = options.copyScreenshotsFrom, let source = live.first(where: { $0.locale == from })?.versionLocalizationID, let target = current.versionLocalizationID {
                    batchProgress = "\(locale.rawValue) · copying screenshots from \(from.rawValue)"
                    let report = try await provider.copyScreenshots(fromLocalization: source, toLocalization: target) { [weak self] step in
                        Task { @MainActor in self?.batchProgress = "\(locale.rawValue) · screenshots \(step)" }
                    }
                    screenshotNote = MetadataPublishing.screenshotNote(sets: report.sets, copied: report.copied, skipped: report.skipped, errors: report.errors)
                }
                replaceSnapshot(app: app, with: current, context: context)
            }
            let baseline = current
            let changes = MetadataDiff.changes(baseline: baseline.fields, draft: draft)
            guard !changes.isEmpty else { return .refused(MetadataPublishing.nothingToApply(screenshotNote)) }
            let updated = try await provider.apply(ascAppID: ascID, snapshot: current, changes: MetadataPublishing.payload(changes))
            replaceSnapshot(app: app, with: updated, context: context)

            let outcome = MetadataPublishing.outcome(draft: draft, reread: updated.fields)
            let note = outcome.note
            let entry = ChangeLogEntry(locale: locale, status: outcome.status, changes: changes, note: note, baselineHash: baseline.contentHash, resultHash: updated.contentHash)
            entry.app = app
            context.insert(entry)
            try? context.save()
            lastMessage = "Applied \(changes.count) field(s) to \(locale.rawValue). \(note)\(screenshotNote)" + (autoNotes.isEmpty ? "" : " " + autoNotes.joined(separator: " "))
            return .applied(updated)
        } catch {
            let entry = ChangeLogEntry(locale: locale, status: "failed", changes: [], note: error.localizedDescription, baselineHash: "", resultHash: nil)
            entry.app = app
            context.insert(entry)
            try? context.save()
            lastMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    private func replaceSnapshot(app: TrackedApp, with snapshot: MetadataSnapshot, context: ModelContext) {
        for old in app.snapshots where old.localeRaw == snapshot.locale.rawValue { context.delete(old) }
        let rec = MetadataSnapshotRecord(snapshot: snapshot, source: "asc")
        rec.app = app
        context.insert(rec)
        try? context.save()
    }

    private func resolveASCID(_ app: TrackedApp) async throws -> String {
        if let id = app.ascAppID { return id }
        guard let bundle = app.bundleID else { throw ASOError.invalidInput("The app has no bundle id; cannot resolve it on App Store Connect.") }
        let id = try await provider.resolveAppID(bundleID: bundle)
        app.ascAppID = id
        return id
    }
}
