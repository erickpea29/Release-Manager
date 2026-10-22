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
            repositoryConnectionID: entity.repositoryConnectionID,
            targetBranch: entity.targetBranch,
            targetCommitSHA: entity.targetCommitSHA,
            tagName: entity.tagName,
            compareBaseTag: entity.compareBaseTag,
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
        repositoryConnectionID = plan.repositoryConnectionID
        targetBranch = plan.targetBranch
        targetCommitSHA = plan.targetCommitSHA
        tagName = plan.tagName
        compareBaseTag = plan.compareBaseTag
        plannedDate = plan.plannedDate
        changelogMarkdown = plan.changelogMarkdown
        updatedAt = plan.updatedAt
        releasedAt = plan.releasedAt
    }
}

/// The parts of a snapshot stored as one JSON value. Frozen with the snapshot; never rewritten.
struct SnapshotPayload: Codable {
    var tasks: [TaskSnapshot]
    var changes: ReleaseChangeSummary?

    static func encode(_ snapshot: ReleaseSnapshot) -> Data {
        // Encoding plain Codable values with no custom code cannot fail.
        (try? JSONEncoder().encode(SnapshotPayload(tasks: snapshot.tasks, changes: snapshot.changes))) ?? Data()
    }
}

extension ReleaseSnapshot {
    /// `nil` for a row whose project link is missing. An unreadable payload keeps the record without its tasks.
    init?(_ entity: ReleaseSnapshotEntity) {
        guard let projectID = entity.project?.id, let repositoryURL = URL(string: entity.repositoryURL) else {
            return nil
        }
        let payload: SnapshotPayload
        do {
            payload = try JSONDecoder().decode(SnapshotPayload.self, from: entity.contentPayload)
        } catch {
            Log.persistence.error("Unreadable snapshot payload: \(String(describing: error), privacy: .private)")
            payload = SnapshotPayload(tasks: [], changes: nil)
        }
        self.init(
            id: entity.id,
            projectID: projectID,
            releasePlanID: entity.releasePlanID,
            origin: ReleaseSnapshotOrigin(rawValue: entity.originRaw) ?? .relvoraDraft,
            version: entity.version,
            title: entity.title,
            releaseName: entity.releaseName,
            tagName: entity.tagName,
            targetCommitSHA: entity.targetCommitSHA,
            targetBranch: entity.targetBranch,
            isPrerelease: entity.isPrerelease,
            releaseNotesMarkdown: entity.releaseNotesMarkdown,
            tasks: payload.tasks,
            changes: payload.changes,
            githubRepositoryID: entity.githubRepositoryID,
            repositoryFullName: entity.repositoryFullName,
            repositoryURL: repositoryURL,
            snapshotCreatedAt: entity.snapshotCreatedAt,
            state: ReleaseSnapshotState(rawValue: entity.stateRaw) ?? .pending,
            githubReleaseID: entity.githubReleaseID,
            githubReleaseURL: entity.githubReleaseURL.flatMap(URL.init(string:)),
            publishedAt: entity.publishedAt,
            publishedNotesMarkdown: entity.publishedNotesMarkdown,
            publishedTagName: entity.publishedTagName,
            publishedCommitSHA: entity.publishedCommitSHA,
            stateChangedAt: entity.stateChangedAt
        )
    }
}

extension ReleaseSnapshotEntity {
    convenience init(_ snapshot: ReleaseSnapshot) {
        self.init(
            id: snapshot.id,
            originRaw: snapshot.origin.rawValue,
            version: snapshot.version,
            releaseName: snapshot.releaseName,
            tagName: snapshot.tagName,
            targetCommitSHA: snapshot.targetCommitSHA,
            releaseNotesMarkdown: snapshot.releaseNotesMarkdown,
            contentPayload: SnapshotPayload.encode(snapshot),
            githubRepositoryID: snapshot.githubRepositoryID,
            repositoryFullName: snapshot.repositoryFullName,
            repositoryURL: snapshot.repositoryURL.absoluteString,
            snapshotCreatedAt: snapshot.snapshotCreatedAt,
            stateRaw: snapshot.state.rawValue
        )
        releasePlanID = snapshot.releasePlanID
        title = snapshot.title
        targetBranch = snapshot.targetBranch
        isPrerelease = snapshot.isPrerelease
        applyLifecycle(snapshot)
    }

    /// Copies lifecycle fields only. Content columns are never written after insert.
    func applyLifecycle(_ snapshot: ReleaseSnapshot) {
        stateRaw = snapshot.state.rawValue
        githubReleaseID = snapshot.githubReleaseID
        githubReleaseURL = snapshot.githubReleaseURL?.absoluteString
        publishedAt = snapshot.publishedAt
        publishedNotesMarkdown = snapshot.publishedNotesMarkdown
        publishedTagName = snapshot.publishedTagName
        publishedCommitSHA = snapshot.publishedCommitSHA
        stateChangedAt = snapshot.stateChangedAt
    }
}
