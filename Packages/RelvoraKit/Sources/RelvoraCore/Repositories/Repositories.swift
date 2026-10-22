import Foundation

/// Repositories exchange plain `Sendable` values; storage types never cross this boundary.
/// Every multi-record method is a single transaction: it saves completely or not at all.
public protocol ProjectRepository: Sendable {
    func projects(includeArchived: Bool) async throws(PersistenceError) -> [Project]
    func project(id: UUID) async throws(PersistenceError) -> Project
    /// Inserts a project together with its board columns.
    func create(_ project: Project, columns: [BoardColumn]) async throws(PersistenceError)
    func update(_ project: Project) async throws(PersistenceError)
    /// Deletes the project and everything it owns.
    func deleteProject(id: UUID) async throws(PersistenceError)
}

public protocol BoardRepository: Sendable {
    /// Columns in board order.
    func columns(projectID: UUID) async throws(PersistenceError) -> [BoardColumn]
    /// Tasks in `sortOrder`, across all columns.
    func tasks(projectID: UUID) async throws(PersistenceError) -> [ProjectTask]
    func save(_ column: BoardColumn) async throws(PersistenceError)
    /// Inserts or updates a task, including its checklist. The column must belong to the task's project.
    func save(_ task: ProjectTask) async throws(PersistenceError)
    func deleteTask(id: UUID) async throws(PersistenceError)
}

public protocol ReleasePlanRepository: Sendable {
    func plans(projectID: UUID) async throws(PersistenceError) -> [ReleasePlan]
    func save(_ plan: ReleasePlan) async throws(PersistenceError)
    func deletePlan(id: UUID) async throws(PersistenceError)
}
