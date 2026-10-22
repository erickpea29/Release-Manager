import Foundation
import RelvoraCore

// Entity <-> domain mapping. Entities never leave this module.

extension Project {
    init(_ entity: ProjectEntity) {
        self.init(
            id: entity.id,
            name: entity.name,
            details: entity.details,
            iconName: entity.iconName,
            accentColor: entity.accentColor,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            archivedAt: entity.archivedAt
        )
    }
}

extension ProjectEntity {
    func apply(_ project: Project) {
        name = project.name
        details = project.details
        iconName = project.iconName
        accentColor = project.accentColor
        updatedAt = project.updatedAt
        archivedAt = project.archivedAt
    }
}

extension BoardColumn {
    init(_ entity: BoardColumnEntity) {
        self.init(
            id: entity.id,
            projectID: entity.project?.id ?? UUID(),
            name: entity.name,
            sortOrder: entity.sortOrder,
            isCompletionColumn: entity.isCompletionColumn,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt
        )
    }
}

extension ProjectTask {
    /// `nil` for a task whose project or column link is missing; such rows are skipped rather than shown wrongly.
    init?(_ entity: TaskEntity) {
        guard let projectID = entity.project?.id, let columnID = entity.column?.id else { return nil }
        self.init(
            id: entity.id,
            projectID: projectID,
            columnID: columnID,
            releasePlanID: entity.releasePlan?.id,
            title: entity.title,
            details: entity.details,
            priority: TaskPriority(rawValue: entity.priorityRaw) ?? .medium,
            type: TaskType(rawValue: entity.typeRaw) ?? .other,
            labels: entity.labels,
            checklist: entity.checklist
                .map { ChecklistItem(id: $0.id, title: $0.title, isDone: $0.isDone, sortOrder: $0.sortOrder) }
                .sorted { $0.sortOrder < $1.sortOrder },
            sortOrder: entity.sortOrder,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            completedAt: entity.completedAt
        )
    }
}

extension TaskEntity {
    func apply(_ task: ProjectTask) {
        title = task.title
        details = task.details
        priorityRaw = task.priority.rawValue
        typeRaw = task.type.rawValue
        labels = ProjectTask.normalizedLabels(task.labels)
        sortOrder = task.sortOrder
        updatedAt = task.updatedAt
        completedAt = task.completedAt
    }
}

extension ReleasePlan {
    init?(_ entity: ReleasePlanEntity) {
        guard let projectID = entity.project?.id else { return nil }
        self.init(
            id: entity.id,
            projectID: projectID,
            version: entity.version,
            title: entity.title,
            details: entity.details,
            status: ReleasePlanStatus(rawValue: entity.statusRaw) ?? .reconciliationNeeded,
            targetBranch: entity.targetBranch,
            targetCommitSHA: entity.targetCommitSHA,
            plannedDate: entity.plannedDate,
            changelogMarkdown: entity.changelogMarkdown,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            releasedAt: entity.releasedAt
        )
    }
}

extension RepositoryConnection {
    init?(_ entity: RepositoryConnectionEntity) {
        guard let projectID = entity.project?.id, let url = URL(string: entity.htmlURL) else { return nil }
        self.init(
            id: entity.id,
            projectID: projectID,
            githubRepositoryID: entity.githubRepositoryID,
            owner: entity.owner,
            name: entity.name,
            defaultBranch: entity.defaultBranch,
            htmlURL: url,
            isPrivate: entity.isPrivate,
            lastSyncedAt: entity.lastSyncedAt,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt
        )
    }
}

extension RepositoryConnectionEntity {
    func apply(_ connection: RepositoryConnection) {
        owner = connection.owner
        name = connection.name
        defaultBranch = connection.defaultBranch
        htmlURL = connection.htmlURL.absoluteString
        isPrivate = connection.isPrivate
        lastSyncedAt = connection.lastSyncedAt
        updatedAt = connection.updatedAt
    }
}

extension ReleasePlanEntity {
    func apply(_ plan: ReleasePlan) {
        version = plan.version
        title = plan.title
        details = plan.details
        statusRaw = plan.status.rawValue
        targetBranch = plan.targetBranch
        targetCommitSHA = plan.targetCommitSHA
        plannedDate = plan.plannedDate
        changelogMarkdown = plan.changelogMarkdown
        updatedAt = plan.updatedAt
        releasedAt = plan.releasedAt
    }
}
