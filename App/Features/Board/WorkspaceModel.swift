import Foundation
import Observation
import RelvoraCore

enum TaskEditorRequest: Identifiable {
    case new(ProjectTask)
    case edit(ProjectTask)

    var id: UUID {
        switch self {
        case .new(let task), .edit(let task): task.id
        }
    }

    var task: ProjectTask {
        switch self {
        case .new(let task), .edit(let task): task
        }
    }

    var isNew: Bool { if case .new = self { true } else { false } }
}

enum PlanEditorRequest: Identifiable {
    case new
    case edit(ReleasePlan)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let plan): plan.id.uuidString
        }
    }
}

/// State for one project's board and release plans. Created per open project.
@Observable
final class WorkspaceModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let projectID: UUID
    private(set) var state = BoardState(columns: [], tasks: [])
    private(set) var releasePlans: [ReleasePlan] = []
    private(set) var connections: [RepositoryConnection] = []
    private(set) var loadState = LoadState.loading
    var filter = TaskFilter()
    var alert: AppAlert?
    var taskEditor: TaskEditorRequest?
    var planEditor: PlanEditorRequest?

    private let board: BoardService
    private let plans: ReleasePlanService
    private let connectionService: RepositoryConnectionService
    /// Lets the dashboard refresh its numbers after changes.
    private let didChange: @MainActor () async -> Void

    init(projectID: UUID, environment: AppEnvironment, didChange: @escaping @MainActor () async -> Void) {
        self.projectID = projectID
        self.board = environment.board
        self.plans = environment.releasePlans
        self.connectionService = environment.repositoryConnections
        self.didChange = didChange
    }

    // MARK: Reading

    var columns: [BoardColumn] { state.orderedColumns }

    func visibleTasks(in columnID: UUID) -> [ProjectTask] {
        state.tasks(in: columnID).filter(filter.matches)
    }

    /// Every label used on the board, for the filter menu.
    var allLabels: [String] {
        var seen = Set<String>()
        return state.tasks.flatMap(\.labels).filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    var activePlan: ReleasePlan? { releasePlans.first(where: \.status.isActive) }

    func plan(_ id: UUID?) -> ReleasePlan? { id.flatMap { id in releasePlans.first { $0.id == id } } }

    func taskCount(for plan: ReleasePlan) -> Int { state.tasks.filter { $0.releasePlanID == plan.id }.count }

    func load() async {
        do {
            state = try await board.load(projectID: projectID)
            releasePlans = try await plans.plans(projectID: projectID)
            connections = try await connectionService.connections(projectID: projectID)
            loadState = .loaded
        } catch {
            loadState = .failed(AppAlert.message(for: error))
        }
    }

    // MARK: Tasks

    func beginNewTask(in columnID: UUID? = nil) {
        guard let column = columnID ?? columns.first?.id else { return }
        taskEditor = .new(
            ProjectTask(
                projectID: projectID, columnID: column, releasePlanID: activePlan?.id, title: "", sortOrder: 0))
    }

    func quickAdd(title: String, to columnID: UUID) async -> Bool {
        await perform("Couldn’t add task") {
            try await self.board.createTask(projectID: self.projectID, columnID: columnID, title: title)
        }
    }

    /// Throws so the editor can show validation messages inline.
    func save(_ request: TaskEditorRequest, edited: ProjectTask) async throws {
        state = request.isNew ? try await board.createTask(edited) : try await board.updateTask(edited)
        await didChange()
    }

    func moveTask(_ taskID: UUID, to columnID: UUID, before beforeTaskID: UUID?) async {
        guard state.task(taskID) != nil else { return }
        await perform("Couldn’t move task") {
            try await self.board.moveTask(taskID, projectID: self.projectID, toColumn: columnID, before: beforeTaskID)
        }
    }

    func deleteTask(_ taskID: UUID) async {
        await perform("Couldn’t delete task") { try await self.board.deleteTask(taskID, projectID: self.projectID) }
    }

    // MARK: Columns

    func addColumn(named name: String) async {
        await perform("Couldn’t add column") { try await self.board.addColumn(named: name, projectID: self.projectID) }
    }

    func renameColumn(_ columnID: UUID, to name: String) async {
        await perform("Couldn’t rename column") {
            try await self.board.renameColumn(columnID, to: name, projectID: self.projectID)
        }
    }

    func moveColumn(_ columnID: UUID, by offset: Int) async {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        await perform("Couldn’t move column") {
            try await self.board.moveColumn(columnID, toIndex: index + offset, projectID: self.projectID)
        }
    }

    func makeCompletionColumn(_ columnID: UUID) async {
        await perform("Couldn’t change the completion column") {
            try await self.board.makeCompletionColumn(columnID, projectID: self.projectID)
        }
    }

    func deleteColumn(_ columnID: UUID, movingTasksTo destination: UUID?) async {
        await perform("Couldn’t delete column") {
            try await self.board.deleteColumn(columnID, movingTasksTo: destination, projectID: self.projectID)
        }
    }

    // MARK: Release plans

    /// Throws so the editor can show validation messages inline.
    func savePlan(_ request: PlanEditorRequest, draft: ReleasePlan) async throws {
        switch request {
        case .new:
            _ = try await plans.create(
                projectID: projectID, version: draft.version, title: draft.title, details: draft.details,
                plannedDate: draft.plannedDate, targetBranch: draft.targetBranch)
        case .edit:
            _ = try await plans.update(draft)
        }
        releasePlans = try await plans.plans(projectID: projectID)
        await didChange()
    }

    func cancelPlan(_ plan: ReleasePlan) async {
        await performPlans("Couldn’t cancel the plan") { _ = try await self.plans.cancel(plan) }
    }

    func deletePlan(_ plan: ReleasePlan) async {
        await performPlans("Couldn’t delete the plan") { try await self.plans.delete(plan) }
        state = (try? await board.load(projectID: projectID)) ?? state
    }

    // MARK: Repository connections

    /// Throws so the picker can show the problem inline.
    func connect(_ remote: GitHubRepository) async throws -> RepositoryConnection {
        let connection = try await connectionService.connect(remote, to: projectID)
        connections.append(connection)
        return connection
    }

    func disconnect(_ connection: RepositoryConnection) async {
        do {
            try await connectionService.disconnect(connection)
            connections.removeAll { $0.id == connection.id }
        } catch {
            alert = AppAlert(title: "Couldn’t disconnect the repository", error: error)
        }
    }

    /// Stores the sync time and any rename or transfer GitHub reported.
    func recordSync(of connection: RepositoryConnection, remote: GitHubRepository) async {
        do {
            let updated = try await connectionService.recordSync(connection, remote: remote, at: .now)
            if let index = connections.firstIndex(where: { $0.id == updated.id }) { connections[index] = updated }
        } catch {
            alert = AppAlert(title: "Couldn’t save the sync result", error: error)
        }
    }

    // MARK: Helpers

    @discardableResult
    private func perform(_ title: String, _ operation: @escaping () async throws -> BoardState) async -> Bool {
        do {
            state = try await operation()
            await didChange()
            return true
        } catch {
            alert = AppAlert(title: title, error: error)
            // Re-sync in case the store and the screen disagree.
            if let fresh = try? await board.load(projectID: projectID) { state = fresh }
            return false
        }
    }

    private func performPlans(_ title: String, _ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            releasePlans = try await plans.plans(projectID: projectID)
            await didChange()
        } catch {
            alert = AppAlert(title: title, error: error)
        }
    }
}
