import Foundation

public enum ReleasePlanRules {
    public static let maximumTitleLength = 120

    /// Validates a new or edited plan against the project's other plans and returns it normalized.
    /// - At most one active plan (planned, draft created, or needs reconciliation) per project.
    /// - No two non-cancelled plans with the same version (semantic versions compare by precedence).
    public static func validated(_ plan: ReleasePlan, existing: [ReleasePlan]) throws(ValidationError) -> ReleasePlan {
        let version = try ReleaseVersion(parsing: plan.version)
        let others = existing.filter { $0.id != plan.id && $0.projectID == plan.projectID }

        if plan.status.isActive, let active = others.first(where: \.status.isActive) {
            throw .activeReleasePlanExists(version: active.version)
        }
        let clash = others.contains { other in
            other.status != .cancelled && (try? ReleaseVersion(parsing: other.version)) == version
        }
        if clash { throw .duplicateVersion(version.description) }

        var normalized = plan
        normalized.version = plan.version.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.title = plan.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let title = normalized.title, title.count > maximumTitleLength {
            throw .titleTooLong(maximum: maximumTitleLength)
        }
        normalized.details = plan.details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        normalized.targetBranch = plan.targetBranch?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        normalized.tagName = plan.tagName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let tag = normalized.tagName, !GitRefName.isValidTag(tag) { throw .invalidTagName(tag) }
        normalized.compareBaseTag = plan.compareBaseTag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        normalized.targetCommitSHA =
            plan.targetCommitSHA?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().nilIfEmpty
        if let sha = normalized.targetCommitSHA, !GitRefName.isFullCommitSHA(sha) { throw .invalidCommitSHA(sha) }
        if plan.changelogMarkdown.count > ReleaseNotes.maximumLength {
            throw .releaseNotesTooLong(maximum: ReleaseNotes.maximumLength)
        }
        return normalized
    }

    /// Only plans that are still `planned` can be edited; later states are records of what happened.
    public static func isEditable(_ plan: ReleasePlan) -> Bool { plan.status == .planned }

    /// Planned and cancelled plans can be deleted; drafts and published plans are kept (M04 reconciles them).
    public static func isDeletable(_ plan: ReleasePlan) -> Bool { plan.status == .planned || plan.status == .cancelled }
}

/// Git naming rules (`git check-ref-format`) for the tags Relvora asks GitHub to create.
public enum GitRefName {
    public static func isValidTag(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 250, name != "@", !name.hasPrefix("-"), !name.hasPrefix("/"),
            !name.hasSuffix("/"), !name.hasSuffix("."), !name.contains(".."), !name.contains("//"),
            !name.contains("@{")
        else { return false }
        let forbidden = Set(" ~^:?*[\\")
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
            !name.contains(where: forbidden.contains)
        else { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }

    /// A full 40-character hexadecimal SHA-1 (lowercase).
    public static func isFullCommitSHA(_ sha: String) -> Bool {
        sha.count == 40 && sha.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
