import Foundation

/// The checks around writing a listing to App Store Connect, shared by every front end: when to refuse, what to send,
/// and whether Apple's re-read matches what was sent.
public enum MetadataPublishing {
    /// App Store version states whose metadata can still be edited.
    public static let editableVersionStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY",
    ]

    public static func isEditable(versionState: String?) -> Bool {
        versionState.map(editableVersionStates.contains) ?? false
    }

    /// True when Apple's listing moved since the baseline was pulled: applying would overwrite what someone else wrote.
    public static func changedSincePull(baseline: MetadataFields?, live: MetadataFields) -> Bool {
        guard let baseline else { return false }
        return MetadataHasher.hash(baseline) != MetadataHasher.hash(live)
    }

    /// The fields to send: each change's new text.
    public static func payload(_ changes: [FieldChange]) -> [MetadataField: String] {
        Dictionary(changes.map { ($0.field, $0.after) }, uniquingKeysWith: { _, last in last })
    }

    public struct Outcome: Sendable, Equatable {
        /// "applied" when the re-read matches the draft, else "partial".
        public let status: String
        public let note: String
        /// Fields Apple holds differently from the draft after the write.
        public let differing: [MetadataField]
    }

    /// Compares the draft with what Apple holds after the write.
    public static func outcome(draft: MetadataFields, reread: MetadataFields) -> Outcome {
        let differing = MetadataDiff.changes(baseline: draft, draft: reread).map(\.field)
        guard !differing.isEmpty else { return Outcome(status: "applied", note: "Re-read matches the draft.", differing: []) }
        return Outcome(status: "partial", note: "Re-read differs from the draft for: \(differing.map(\.title).joined(separator: ", ")).",
                       differing: differing)
    }

    /// The timeline title of an applied change, e.g. "Applied Keywords, Subtitle (de-DE)".
    public static func markerTitle(fields: [MetadataField], locale: String) -> String {
        "Applied \(fields.map(\.title).joined(separator: ", ")) (\(locale))"
    }

    public static let changedRemotely =
        "The listing changed on App Store Connect since the baseline was pulled. The baseline was refreshed; review the diff again."
    public static let hasErrors = "The draft has validation errors. Fix them before applying."

    public static func nothingToApply(_ suffix: String = "") -> String {
        "Nothing to apply: the draft equals what App Store Connect holds.\(suffix)"
    }

    /// One line about copied screenshots, e.g. " Screenshots: 5 copied in 2 set(s), 1 failed (…)."
    public static func screenshotNote(sets: Int, copied: Int, skipped: Int, errors: [String]) -> String {
        " Screenshots: \(copied) copied in \(sets) set(s)\(skipped > 0 ? ", \(skipped) already present" : "")"
            + "\(errors.isEmpty ? "" : ", \(errors.count) failed (\(errors.first ?? ""))")."
    }
}
