import Foundation

/// Repositories exchange plain `Sendable` values; storage types never cross this boundary.
/// Every method is a single transaction: it saves completely or not at all.
public protocol ProjectRepository: Sendable {
    func projects(includeArchived: Bool) async throws(PersistenceError) -> [Project]
    func project(id: UUID) async throws(PersistenceError) -> Project
    /// Inserts a project together with its board columns.
    func create(_ project: Project, columns: [BoardColumn]) async throws(PersistenceError)
    func update(_ project: Project) async throws(PersistenceError)
    /// Deletes the project and everything it owns.
    func deleteProject(id: UUID) async throws(PersistenceError)
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
    func save(_ plan: ReleasePlan) async throws(PersistenceError)
    func deletePlan(id: UUID) async throws(PersistenceError)
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

    public init(
        project: Project,
        columns: [BoardColumn],
        tasks: [ProjectTask],
        releasePlans: [ReleasePlan],
        repositoryConnections: [RepositoryConnection] = []
    ) {
        self.project = project
        self.columns = columns
        self.tasks = tasks
        self.releasePlans = releasePlans
        self.repositoryConnections = repositoryConnections
    }
}

public protocol BackupRepository: Sendable {
    /// Every project (archived included) with its contents, in creation order.
    func allProjectBundles() async throws(PersistenceError) -> [ProjectBundle]
    /// Replaces all local data with `bundles` in one transaction.
    func replaceAll(with bundles: [ProjectBundle]) async throws(PersistenceError)
}
