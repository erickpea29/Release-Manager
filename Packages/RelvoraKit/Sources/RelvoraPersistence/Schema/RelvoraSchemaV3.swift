import Foundation
import SwiftData

/// Schema version 3 (M04): adds release snapshots, and the repository, tag, and compare base of release plans.
/// Frozen: shipped in 0.1.0. Never edit; migrations read old stores through these definitions.
enum RelvoraSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            ProjectEntity.self, BoardColumnEntity.self, TaskEntity.self, ChecklistItemEntity.self,
            ReleasePlanEntity.self,
            RepositoryConnectionEntity.self,
            ReleaseSnapshotEntity.self,
        ]
    }

    @Model
    final class ProjectEntity {
        @Attribute(.unique) var id: UUID
        var name: String
        var details: String?
        var iconName: String?
        var accentColor: String?
        var createdAt: Date
        var updatedAt: Date
        var archivedAt: Date?

        @Relationship(deleteRule: .cascade, inverse: \BoardColumnEntity.project)
        var columns: [BoardColumnEntity] = []
        @Relationship(deleteRule: .cascade, inverse: \TaskEntity.project)
        var tasks: [TaskEntity] = []
        @Relationship(deleteRule: .cascade, inverse: \ReleasePlanEntity.project)
        var releasePlans: [ReleasePlanEntity] = []
        @Relationship(deleteRule: .cascade, inverse: \RepositoryConnectionEntity.project)
        var repositoryConnections: [RepositoryConnectionEntity] = []
        @Relationship(deleteRule: .cascade, inverse: \ReleaseSnapshotEntity.project)
        var releaseSnapshots: [ReleaseSnapshotEntity] = []

        init(id: UUID, name: String, createdAt: Date) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    @Model
    final class BoardColumnEntity {
        @Attribute(.unique) var id: UUID
        var name: String
        var sortOrder: Double
        var isCompletionColumn: Bool
        var createdAt: Date
        var updatedAt: Date
        var project: ProjectEntity?

        // Column deletion is guarded by domain rules (a column with tasks cannot be removed).
        @Relationship(deleteRule: .nullify, inverse: \TaskEntity.column)
        var tasks: [TaskEntity] = []

        init(id: UUID, name: String, sortOrder: Double, isCompletionColumn: Bool, createdAt: Date) {
            self.id = id
            self.name = name
            self.sortOrder = sortOrder
            self.isCompletionColumn = isCompletionColumn
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    @Model
    final class TaskEntity {
        @Attribute(.unique) var id: UUID
        var title: String
        var details: String?
        var priorityRaw: String
        var typeRaw: String
        var labels: [String]
        var sortOrder: Double
        var createdAt: Date
        var updatedAt: Date
        var completedAt: Date?
        var project: ProjectEntity?
        var column: BoardColumnEntity?
        var releasePlan: ReleasePlanEntity?

        @Relationship(deleteRule: .cascade, inverse: \ChecklistItemEntity.task)
        var checklist: [ChecklistItemEntity] = []

        init(id: UUID, title: String, priorityRaw: String, typeRaw: String, sortOrder: Double, createdAt: Date) {
            self.id = id
            self.title = title
            self.priorityRaw = priorityRaw
            self.typeRaw = typeRaw
            self.labels = []
            self.sortOrder = sortOrder
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    @Model
    final class ChecklistItemEntity {
        @Attribute(.unique) var id: UUID
        var title: String
        var isDone: Bool
        var sortOrder: Double
        var task: TaskEntity?

        init(id: UUID, title: String, isDone: Bool, sortOrder: Double) {
            self.id = id
            self.title = title
            self.isDone = isDone
            self.sortOrder = sortOrder
        }
    }

    @Model
    final class ReleasePlanEntity {
        @Attribute(.unique) var id: UUID
        var version: String
        var title: String?
        var details: String?
        var statusRaw: String
        var repositoryConnectionID: UUID?
        var targetBranch: String?
        var targetCommitSHA: String?
        var tagName: String?
        var compareBaseTag: String?
        var plannedDate: Date?
        var changelogMarkdown: String
        var createdAt: Date
        var updatedAt: Date
        var releasedAt: Date?
        var project: ProjectEntity?

        @Relationship(deleteRule: .nullify, inverse: \TaskEntity.releasePlan)
        var tasks: [TaskEntity] = []

        init(id: UUID, version: String, statusRaw: String, createdAt: Date) {
            self.id = id
            self.version = version
            self.statusRaw = statusRaw
            self.changelogMarkdown = ""
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    @Model
    final class RepositoryConnectionEntity {
        @Attribute(.unique) var id: UUID
        var githubRepositoryID: Int64
        var owner: String
        var name: String
        var defaultBranch: String?
        var htmlURL: String
        var isPrivate: Bool
        var lastSyncedAt: Date?
        var createdAt: Date
        var updatedAt: Date
        var project: ProjectEntity?

        init(id: UUID, githubRepositoryID: Int64, owner: String, name: String, htmlURL: String, createdAt: Date) {
            self.id = id
            self.githubRepositoryID = githubRepositoryID
            self.owner = owner
            self.name = name
            self.htmlURL = htmlURL
            self.isPrivate = false
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    /// Write-once release record. Content columns are set on insert only; lifecycle columns are filled in by the
    /// repository's `record`, which allows only the transitions in `ReleaseSnapshot.applying`.
    @Model
    final class ReleaseSnapshotEntity {
        @Attribute(.unique) var id: UUID
        /// Plain ID rather than a relationship: the record outlives a deleted plan.
        var releasePlanID: UUID?
        var originRaw: String
        var version: String
        var title: String?
        var releaseName: String
        var tagName: String
        var targetCommitSHA: String
        var targetBranch: String?
        var isPrerelease: Bool
        var releaseNotesMarkdown: String
        /// JSON-encoded tasks and change summary, frozen at creation.
        var contentPayload: Data
        var githubRepositoryID: Int64
        var repositoryFullName: String
        var repositoryURL: String
        var snapshotCreatedAt: Date
        var stateRaw: String
        var githubReleaseID: Int64?
        var githubReleaseURL: String?
        var publishedAt: Date?
        var publishedNotesMarkdown: String?
        var publishedTagName: String?
        var publishedCommitSHA: String?
        var stateChangedAt: Date
        var project: ProjectEntity?

        init(
            id: UUID, originRaw: String, version: String, releaseName: String, tagName: String,
            targetCommitSHA: String, releaseNotesMarkdown: String, contentPayload: Data, githubRepositoryID: Int64,
            repositoryFullName: String, repositoryURL: String, snapshotCreatedAt: Date, stateRaw: String
        ) {
            self.id = id
            self.originRaw = originRaw
            self.version = version
            self.releaseName = releaseName
            self.tagName = tagName
            self.targetCommitSHA = targetCommitSHA
            self.isPrerelease = false
            self.releaseNotesMarkdown = releaseNotesMarkdown
            self.contentPayload = contentPayload
            self.githubRepositoryID = githubRepositoryID
            self.repositoryFullName = repositoryFullName
            self.repositoryURL = repositoryURL
            self.snapshotCreatedAt = snapshotCreatedAt
            self.stateRaw = stateRaw
            self.stateChangedAt = snapshotCreatedAt
        }
    }
}
