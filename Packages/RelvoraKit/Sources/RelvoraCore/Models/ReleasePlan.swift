import Foundation

/// Lifecycle of a planned release. Transitions are enforced by the release workflow (M04).
public enum ReleasePlanStatus: String, Sendable, CaseIterable, Codable {
    case planned
    case draftCreated
    /// A remote outcome is unknown; GitHub must be re-read before anything else happens.
    case reconciliationNeeded
    case published
    case cancelled

    public var title: String {
        switch self {
        case .planned: "Planned"
        case .draftCreated: "Draft created"
        case .reconciliationNeeded: "Needs reconciliation"
        case .published: "Published"
        case .cancelled: "Cancelled"
        }
    }

    /// At most one active plan per project (MVP).
    public var isActive: Bool {
        switch self {
        case .planned, .draftCreated, .reconciliationNeeded: true
        case .published, .cancelled: false
        }
    }
}

public struct ReleasePlan: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    /// Stored as entered; interpret with `ReleaseVersion(parsing:)`.
    public var version: String
    public var title: String?
    public var details: String?
    public var status: ReleasePlanStatus
    public var targetBranch: String?
    /// Full 40-character commit SHA once chosen.
    public var targetCommitSHA: String?
    public var plannedDate: Date?
    /// Working changelog draft. Preserved across remote failures.
    public var changelogMarkdown: String
    public let createdAt: Date
    public var updatedAt: Date
    public var releasedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        version: String,
        title: String? = nil,
        details: String? = nil,
        status: ReleasePlanStatus = .planned,
        targetBranch: String? = nil,
        targetCommitSHA: String? = nil,
        plannedDate: Date? = nil,
        changelogMarkdown: String = "",
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        releasedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.version = version
        self.title = title
        self.details = details
        self.status = status
        self.targetBranch = targetBranch
        self.targetCommitSHA = targetCommitSHA
        self.plannedDate = plannedDate
        self.changelogMarkdown = changelogMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.releasedAt = releasedAt
    }
}
