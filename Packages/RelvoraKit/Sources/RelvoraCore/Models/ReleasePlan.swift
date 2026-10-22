import Foundation

/// Lifecycle of a planned release. Transitions are made only by `ReleaseWorkflow`, after GitHub confirms them.
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
    /// The connected repository this version is released from (one per plan in the MVP).
    public var repositoryConnectionID: UUID?
    public var targetBranch: String?
    /// Full 40-character commit SHA once chosen.
    public var targetCommitSHA: String?
    /// Git tag the GitHub release uses. GitHub creates it at the target commit when the draft is published.
    public var tagName: String?
    /// Tag the changelog compares from (usually the previous release).
    public var compareBaseTag: String?
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
        repositoryConnectionID: UUID? = nil,
        targetBranch: String? = nil,
        targetCommitSHA: String? = nil,
        tagName: String? = nil,
        compareBaseTag: String? = nil,
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
        self.repositoryConnectionID = repositoryConnectionID
        self.targetBranch = targetBranch
        self.targetCommitSHA = targetCommitSHA
        self.tagName = tagName
        self.compareBaseTag = compareBaseTag
        self.plannedDate = plannedDate
        self.changelogMarkdown = changelogMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.releasedAt = releasedAt
    }
}

extension ReleasePlan {
    /// `v1.4.0` for semantic versions; custom labels with spaces turned into hyphens.
    public var suggestedTagName: String {
        switch try? ReleaseVersion(parsing: version) {
        case .semantic(let semantic)?: "v\(semantic)"
        case .custom(let label)?: label.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        case nil: version
        }
    }

    /// Semantic versions with prerelease identifiers (`2.0.0-beta.1`) become GitHub pre-releases.
    public var isPrerelease: Bool {
        if case .semantic(let semantic)? = try? ReleaseVersion(parsing: version) {
            semantic.isPrerelease
        } else {
            false
        }
    }

    /// The release title on GitHub: the version, plus the plan's title when it has one.
    public var releaseName: String {
        title.map { "\(version) – \($0)" } ?? version
    }
}
