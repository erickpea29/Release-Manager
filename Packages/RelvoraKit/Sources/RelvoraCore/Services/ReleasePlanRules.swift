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
        return normalized
    }

    /// Only plans that are still `planned` can be edited; later states are records of what happened.
    public static func isEditable(_ plan: ReleasePlan) -> Bool { plan.status == .planned }

    /// Planned and cancelled plans can be deleted; drafts and published plans are kept (M04 reconciles them).
    public static func isDeletable(_ plan: ReleasePlan) -> Bool { plan.status == .planned || plan.status == .cancelled }
}
