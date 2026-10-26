import Foundation

/// Repositories exchange plain `Sendable` values; storage types never cross this boundary.
/// Every method is a single transaction: it saves completely or not at all.
public protocol ProjectRepository: Sendable {
    func projects(includeArchived: Bool) async throws(PersistenceError) -> [Project]
    func project(id: UUID) async throws(PersistenceError) -> Project
    /// Inserts a project together with its board columns. `project.groupID`, if set, must name an existing group.
    func create(_ project: Project, columns: [BoardColumn]) async throws(PersistenceError)
    /// Saves the project's fields, including its group.
    func update(_ project: Project) async throws(PersistenceError)
    /// Deletes the project and everything it owns.
    func deleteProject(id: UUID) async throws(PersistenceError)
}

public protocol ReleaseStepRepository: Sendable {
    /// A project's release checklist, in order.
    func steps(projectID: UUID) async throws(PersistenceError) -> [ReleaseStep]
    /// Replaces the project's checklist in one transaction: steps not listed are deleted.
    func replaceSteps(_ steps: [ReleaseStep], projectID: UUID) async throws(PersistenceError)
}

public protocol ProjectGroupRepository: Sendable {
    /// Every group, in sidebar order.
    func groups() async throws(PersistenceError) -> [ProjectGroup]
    /// Inserts or updates the groups in one transaction (a reorder can change several).
    func save(_ groups: [ProjectGroup]) async throws(PersistenceError)
    /// Deletes the group. Its projects stay, outside any group.
    func deleteGroup(id: UUID) async throws(PersistenceError)
}

/// A batch of board edits applied atomically. Order of application: column upserts, task upserts,
/// task deletions, column deletions. The batch is rejected if it would leave a deleted column with tasks,
/// a task in another project's column, or a project without exactly one completion column.
public struct BoardChanges: Sendable, Equatable {
    public var upsertColumns: [BoardColumn]
    public var upsertTasks: [ProjectTask]
    public var deleteTaskIDs: [UUID]
    public var deleteColumnIDs: [UUID]

    public init(
        upsertColumns: [BoardColumn] = [],
        upsertTasks: [ProjectTask] = [],
        deleteTaskIDs: [UUID] = [],
        deleteColumnIDs: [UUID] = []
    ) {
        self.upsertColumns = upsertColumns
        self.upsertTasks = upsertTasks
        self.deleteTaskIDs = deleteTaskIDs
        self.deleteColumnIDs = deleteColumnIDs
    }

    public var isEmpty: Bool {
        upsertColumns.isEmpty && upsertTasks.isEmpty && deleteTaskIDs.isEmpty && deleteColumnIDs.isEmpty
    }
}

public protocol BoardRepository: Sendable {
    /// Columns in board order.
    func columns(projectID: UUID) async throws(PersistenceError) -> [BoardColumn]
    /// Tasks in `sortOrder`, across all columns.
    func tasks(projectID: UUID) async throws(PersistenceError) -> [ProjectTask]
    func apply(_ changes: BoardChanges) async throws(PersistenceError)
}

extension BoardRepository {
    public func save(_ column: BoardColumn) async throws(PersistenceError) {
        try await apply(BoardChanges(upsertColumns: [column]))
    }

    /// Inserts or updates a task, including its checklist.
    public func save(_ task: ProjectTask) async throws(PersistenceError) {
        try await apply(BoardChanges(upsertTasks: [task]))
    }

    public func deleteTask(id: UUID) async throws(PersistenceError) {
        try await apply(BoardChanges(deleteTaskIDs: [id]))
    }
}

public protocol ReleasePlanRepository: Sendable {
    func plans(projectID: UUID) async throws(PersistenceError) -> [ReleasePlan]
    /// Inserts a plan, or updates one that is still `planned`, as `planned` or `cancelled`. Every other state is
    /// set only through `ReleaseSnapshotRepository.record`, so an edit can never overwrite the workflow's progress.
    func save(_ plan: ReleasePlan) async throws(PersistenceError)
    /// Only `planned` and `cancelled` plans can be deleted.
    func deletePlan(id: UUID) async throws(PersistenceError)
}

/// One step of the release workflow, saved atomically: a plan status change guarded by the status it expects
/// (so two concurrent attempts can't both start a draft), plus at most one snapshot operation.
public struct ReleaseRecord: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case none
        /// A new snapshot: `pending` for a Relvora draft, or `published` for a release recorded from GitHub.
        case insert(ReleaseSnapshot)
        case transition(snapshotID: UUID, SnapshotTransition)
        /// Removes a `pending` snapshot after GitHub confirmed that no draft was created.
        case discardPending(snapshotID: UUID)
    }

    public let planID: UUID
    public let expectedStatus: ReleasePlanStatus
    public let newStatus: ReleasePlanStatus
    public var releasedAt: Date?
    /// Replaces the plan's target commit (a release recorded from GitHub whose tag points elsewhere).
    public var targetCommitSHA: String?
    public let operation: Operation
    public let date: Date

    public init(
        planID: UUID,
        expectedStatus: ReleasePlanStatus,
        newStatus: ReleasePlanStatus,
        releasedAt: Date? = nil,
        targetCommitSHA: String? = nil,
        operation: Operation,
        date: Date
    ) {
        self.planID = planID
        self.expectedStatus = expectedStatus
        self.newStatus = newStatus
        self.releasedAt = releasedAt
        self.targetCommitSHA = targetCommitSHA
        self.operation = operation
        self.date = date
    }
}

/// Release snapshots are write-once: there is no update method for their content.
public protocol ReleaseSnapshotRepository: Sendable {
    /// One project's snapshots, oldest first.
    func snapshots(projectID: UUID) async throws(PersistenceError) -> [ReleaseSnapshot]
    /// Every project's snapshots, oldest first.
    func allSnapshots() async throws(PersistenceError) -> [ReleaseSnapshot]
    /// Applies one workflow step in a single transaction. Throws `outdated` when the plan's status isn't
    /// `expectedStatus`, and `integrityViolation` for a transition the snapshot doesn't allow.
    func record(_ record: ReleaseRecord) async throws(PersistenceError)
}

public protocol RepositoryConnectionRepository: Sendable {
    /// Connections of one project, in the order they were added.
    func connections(projectID: UUID) async throws(PersistenceError) -> [RepositoryConnection]
    /// Inserts or updates. A project can connect a given GitHub repository only once.
    func save(_ connection: RepositoryConnection) async throws(PersistenceError)
    func deleteConnection(id: UUID) async throws(PersistenceError)
}

/// Everything a project owns, as plain values. Used for backup and restore.
public struct ProjectBundle: Sendable, Equatable {
    public var project: Project
    public var columns: [BoardColumn]
    public var tasks: [ProjectTask]
    public var releasePlans: [ReleasePlan]
    public var repositoryConnections: [RepositoryConnection]
    public var releaseSnapshots: [ReleaseSnapshot]
    public var releaseSteps: [ReleaseStep]

    public init(
        project: Project,
        columns: [BoardColumn],
        tasks: [ProjectTask],
        releasePlans: [ReleasePlan],
        repositoryConnections: [RepositoryConnection] = [],
        releaseSnapshots: [ReleaseSnapshot] = [],
        releaseSteps: [ReleaseStep] = []
    ) {
        self.project = project
        self.columns = columns
        self.tasks = tasks
        self.releasePlans = releasePlans
        self.repositoryConnections = repositoryConnections
        self.releaseSnapshots = releaseSnapshots
        self.releaseSteps = releaseSteps
    }
}

public protocol BackupRepository: Sendable {
    /// Every project (archived included) with its contents, in creation order.
    func allProjectBundles() async throws(PersistenceError) -> [ProjectBundle]
    /// Every group, in sidebar order.
    func groups() async throws(PersistenceError) -> [ProjectGroup]
    /// Replaces all local data with `groups` and `bundles` in one transaction. Projects may refer only to these
    /// groups.
    func replaceAll(with bundles: [ProjectBundle], groups: [ProjectGroup]) async throws(PersistenceError)
}
