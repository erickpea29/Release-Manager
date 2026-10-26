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
    /// The project's release checklist steps ticked for this plan (`ReleaseStep`). IDs of deleted steps are ignored.
    public var completedStepIDs: Set<UUID>

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
        releasedAt: Date? = nil,
        completedStepIDs: Set<UUID> = []
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
        self.completedStepIDs = completedStepIDs
    }
}

/// One step of a project's release checklist, such as "Test on a clean Mac". Every step must be ticked on a release
/// plan before its draft is created; the ticks are kept with the release.
public struct ReleaseStep: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let projectID: UUID
    public var title: String
    public var sortOrder: Double
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), projectID: UUID, title: String, sortOrder: Double, createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

public enum ReleaseChecklist {
    public static let maximumTitleLength = 200

    /// Steps not yet ticked on the plan, in checklist order.
    public static func remaining(_ steps: [ReleaseStep], plan: ReleasePlan) -> [ReleaseStep] {
        steps.filter { !plan.completedStepIDs.contains($0.id) }
    }

    /// The edited checklist ready to save: trimmed titles, blank steps dropped, positions renumbered 1, 2, 3 in the
    /// given order. Existing steps keep their IDs, so plans keep their ticks.
    public static func validated(_ steps: [ReleaseStep], projectID: UUID, now: Date) throws(ValidationError)
        -> [ReleaseStep]
    {
        var result: [ReleaseStep] = []
        for step in steps {
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            guard title.count <= maximumTitleLength else { throw .titleTooLong(maximum: maximumTitleLength) }
            let order = Double(result.count + 1)
            let changed = step.title != title || step.sortOrder != order || step.projectID != projectID
            result.append(
                ReleaseStep(
                    id: step.id, projectID: projectID, title: title, sortOrder: order, createdAt: step.createdAt,
                    updatedAt: changed ? now : step.updatedAt))
        }
        return result
    }

    /// The checklist as it stands on the plan, for the release record.
    public static func snapshot(_ steps: [ReleaseStep], plan: ReleasePlan) -> [ReleaseStepSnapshot] {
        steps.map { ReleaseStepSnapshot(title: $0.title, isDone: plan.completedStepIDs.contains($0.id)) }
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
