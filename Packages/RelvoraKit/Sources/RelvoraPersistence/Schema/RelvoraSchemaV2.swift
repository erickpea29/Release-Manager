import Foundation
import SwiftData

/// Schema version 2 (M03): adds GitHub repository connections to projects.
/// Frozen once merged to `main`; every later change adds a new `VersionedSchema` and a migration stage.
enum RelvoraSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            ProjectEntity.self, BoardColumnEntity.self, TaskEntity.self, ChecklistItemEntity.self,
            ReleasePlanEntity.self,
            RepositoryConnectionEntity.self,
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
        var targetBranch: String?
        var targetCommitSHA: String?
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
}
