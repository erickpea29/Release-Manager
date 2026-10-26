import Foundation

public struct BackupSummary: Sendable, Equatable {
    public let groupCount: Int
    public let projectCount: Int
    public let taskCount: Int
    public let releasePlanCount: Int
    public let exportedAt: Date
}

/// Checks a whole backup before anything is restored. Restoring is all-or-nothing, so every rule that the
/// store or the board enforces is checked here first, to report a precise problem.
public enum BackupValidator {
    public static func validate(_ document: BackupDocument) throws(BackupError) {
        if let columns = document.preferences?.newProjectColumns {
            guard (try? ProjectRules.validatedTemplate(ProjectRules.withoutBacklog(columns))) != nil else {
                throw .invalid("the board template for new projects needs named columns and one completion column.")
            }
        }
        var projectIDs = Set<UUID>()
        var columnIDs = Set<UUID>()
        var taskIDs = Set<UUID>()
        var planIDs = Set<UUID>()
        var checklistIDs = Set<UUID>()
        var connectionIDs = Set<UUID>()
        var snapshotIDs = Set<UUID>()
        var stepIDs = Set<UUID>()

        var groupIDs = Set<UUID>()
        var groupNames = Set<String>()
        for group in document.groups ?? [] {
            guard groupIDs.insert(group.id).inserted else { throw .invalid("a group appears twice.") }
            guard let name = try? ProjectRules.validatedName(group.name), group.sortOrder.isFinite else {
                throw .invalid("a group has an invalid name or position.")
            }
            guard groupNames.insert(name.lowercased()).inserted else {
                throw .invalid("two groups are named “\(name)”.")
            }
        }

        for project in document.projects {
            guard projectIDs.insert(project.id).inserted else { throw .invalid("a project appears twice.") }
            guard (try? ProjectRules.validatedName(project.name)) != nil else {
                throw .invalid("a project has an invalid name.")
            }
            if let groupID = project.groupID, !groupIDs.contains(groupID) {
                throw .invalid("project “\(project.name)” is in a group the backup doesn’t contain.")
            }
            guard !project.columns.isEmpty else { throw .invalid("project “\(project.name)” has no columns.") }
            guard project.columns.filter(\.isCompletionColumn).count == 1 else {
                throw .invalid("project “\(project.name)” must have exactly one completion column.")
            }
            let ownColumns = Set(project.columns.map(\.id))
            let ownPlans = Set(project.releasePlans.map(\.id))

            for column in project.columns {
                guard columnIDs.insert(column.id).inserted else { throw .invalid("a column appears twice.") }
                guard column.sortOrder.isFinite else { throw .invalid("column “\(column.name)” has a bad position.") }
            }

            var activePlans = 0
            for plan in project.releasePlans {
                guard planIDs.insert(plan.id).inserted else { throw .invalid("a release plan appears twice.") }
                guard let status = ReleasePlanStatus(rawValue: plan.status) else {
                    throw .invalid("release plan \(plan.version) has an unknown status.")
                }
                guard (try? ReleaseVersion(parsing: plan.version)) != nil else {
                    throw .invalid("release plan “\(plan.version)” has an invalid version.")
                }
                if status.isActive { activePlans += 1 }
            }
            guard activePlans <= 1 else {
                throw .invalid("project “\(project.name)” has more than one active release plan.")
            }

            for step in project.releaseSteps {
                guard stepIDs.insert(step.id).inserted else {
                    throw .invalid("a release checklist step appears twice.")
                }
                let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= ReleaseChecklist.maximumTitleLength, step.sortOrder.isFinite
                else { throw .invalid("project “\(project.name)” has an invalid release checklist step.") }
            }

            var githubIDs = Set<Int64>()
            for connection in project.repositoryConnections {
                guard connectionIDs.insert(connection.id).inserted else {
                    throw .invalid("a repository connection appears twice.")
                }
                guard githubIDs.insert(connection.githubRepositoryID).inserted else {
                    throw .invalid("project “\(project.name)” connects \(connection.owner)/\(connection.name) twice.")
                }
                guard !connection.owner.isEmpty, !connection.name.isEmpty else {
                    throw .invalid("a repository connection has no owner or name.")
                }
            }

            var openSnapshotPlans = Set<UUID>()
            for snapshot in project.releaseSnapshots {
                guard snapshotIDs.insert(snapshot.id).inserted else { throw .invalid("a release appears twice.") }
                guard let state = ReleaseSnapshotState(rawValue: snapshot.state),
                    ReleaseSnapshotOrigin(rawValue: snapshot.origin) != nil
                else { throw .invalid("release \(snapshot.version) has an unknown state.") }
                guard GitRefName.isFullCommitSHA(snapshot.targetCommitSHA), !snapshot.tagName.isEmpty else {
                    throw .invalid("release \(snapshot.version) has an invalid tag or commit.")
                }
                guard state == .pending || snapshot.githubReleaseID != nil else {
                    throw .invalid("release \(snapshot.version) has no GitHub release.")
                }
                if state.isOpen, let planID = snapshot.releasePlanID {
                    guard openSnapshotPlans.insert(planID).inserted else {
                        throw .invalid("release plan \(snapshot.version) has more than one open draft.")
                    }
                }
            }

            for task in project.tasks {
                guard taskIDs.insert(task.id).inserted else { throw .invalid("a task appears twice.") }
                guard ownColumns.contains(task.columnID) else {
                    throw .invalid("task “\(task.title)” is in a column of another project.")
                }
                if let planID = task.releasePlanID, !ownPlans.contains(planID) {
                    throw .invalid("task “\(task.title)” belongs to a release plan of another project.")
                }
                guard TaskPriority(rawValue: task.priority) != nil, TaskType(rawValue: task.type) != nil else {
                    throw .invalid("task “\(task.title)” has an unknown priority or type.")
                }
                guard (try? BoardPlanner.validatedTitle(task.title)) != nil, task.sortOrder.isFinite else {
                    throw .invalid("a task has an invalid title or position.")
                }
                for item in task.checklist {
                    guard checklistIDs.insert(item.id).inserted else {
                        throw .invalid("a checklist item appears twice.")
                    }
                }
            }
        }
    }

    public static func summary(of document: BackupDocument) -> BackupSummary {
        BackupSummary(
            groupCount: document.groups?.count ?? 0,
            projectCount: document.projects.count,
            taskCount: document.projects.reduce(0) { $0 + $1.tasks.count },
            releasePlanCount: document.projects.reduce(0) { $0 + $1.releasePlans.count },
            exportedAt: document.exportedAt
        )
    }
}

/// Export and restore of all local data.
public struct BackupService: Sendable {
    private let repository: any BackupRepository
    private let now: @Sendable () -> Date

    public init(repository: any BackupRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    public func export(appVersion: String?, preferences: BackupDocument.PreferencesRecord? = nil) async throws
        -> BackupDocument
    {
        BackupDocument(
            bundles: try await repository.allProjectBundles(), groups: try await repository.groups(), exportedAt: now(),
            appVersion: appVersion, preferences: preferences)
    }

    /// Decodes and validates a backup without changing anything, so the user can confirm what it contains.
    public static func inspect(_ data: Data) throws(BackupError) -> (document: BackupDocument, summary: BackupSummary) {
        let document = try BackupDocument.decode(data)
        try BackupValidator.validate(document)
        return (document, BackupValidator.summary(of: document))
    }

    /// Replaces all local data with the backup. Validates first; on any failure nothing changes.
    @discardableResult
    public func restore(_ document: BackupDocument) async throws -> BackupSummary {
        try BackupValidator.validate(document)
        try await repository.replaceAll(with: try document.bundles(), groups: document.projectGroups())
        return BackupValidator.summary(of: document)
    }
}
