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
    /// This project's release snapshots, oldest first.
    private(set) var snapshots: [ReleaseSnapshot] = []
    private(set) var loadState = LoadState.loading
    var filter = TaskFilter()
    /// The board's keyboard selection.
    var selectedTaskID: UUID?
    var alert: AppAlert?
    var taskEditor: TaskEditorRequest?
    var planEditor: PlanEditorRequest?

    private let board: BoardService
    private let plans: ReleasePlanService
    private let connectionService: RepositoryConnectionService
    private let snapshotRepository: any ReleaseSnapshotRepository
    /// The workflow for release drafts; `nil` when this build has no GitHub App.
    let workflow: ReleaseWorkflow?
    /// Plan edits run one after another, each on the latest copy, so concurrent edits never overwrite each other.
    private var planWrites: Task<Void, Never>?
    /// Lets the dashboard refresh its numbers after changes.
    private let didChange: @MainActor () async -> Void

    init(projectID: UUID, environment: AppEnvironment, didChange: @escaping @MainActor () async -> Void) {
        self.projectID = projectID
        self.board = environment.board
        self.plans = environment.releasePlans
        self.connectionService = environment.repositoryConnections
        self.snapshotRepository = environment.store.releaseSnapshots
        self.workflow = environment.releaseWorkflow
        self.didChange = didChange
    }

    // MARK: Reading

    var columns: [BoardColumn] { state.orderedColumns }

    // MARK: Board and Backlog

    /// The Board shows the version being planned, like a sprint; the Backlog has everything unfinished outside it.
    func boardTasks(in columnID: UUID) -> [ProjectTask] {
        state.tasks(in: columnID).filter { VersionScope.isOnBoard($0, activePlanID: activePlan?.id) }
    }

    func visibleTasks(in columnID: UUID) -> [ProjectTask] {
        boardTasks(in: columnID).filter(filter.matches)
    }

    /// The version's tasks that match the filter, in Board order: by column, then position.
    var visibleVersionTasks: [ProjectTask] { columns.flatMap { visibleTasks(in: $0.id) } }

    var versionTaskCount: Int { state.tasks.filter { VersionScope.isOnBoard($0, activePlanID: activePlan?.id) }.count }

    var backlogTasks: [ProjectTask] {
        state.tasks.filter { VersionScope.isInBacklog($0, activePlanID: activePlan?.id) }
            .sorted(by: VersionScope.backlogOrder)
    }

    var visibleBacklogTasks: [ProjectTask] { backlogTasks.filter(filter.matches) }

    /// Finished outside the version and not in a published release, so neither the Board nor the history has them.
    var doneOutsideVersion: [ProjectTask] {
        let published = Set(releasePlans.filter { $0.status == .published }.map(\.id))
        return state.tasks
            .filter {
                VersionScope.isDoneOutsideVersion($0, activePlanID: activePlan?.id, publishedPlanIDs: published)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    var visibleDoneOutsideVersion: [ProjectTask] { doneOutsideVersion.filter(filter.matches) }

    /// Adds a task to the version being planned, or returns it to the Backlog (`nil`). It keeps its column.
    func setVersion(of taskID: UUID, to planID: UUID?) async {
        guard var task = state.task(taskID), task.releasePlanID != planID else { return }
        task.releasePlanID = planID
        await perform(planID == nil ? "Couldn’t move the task to the Backlog" : "Couldn’t add the task to the version")
        {
            try await self.board.updateTask(task)
        }
    }

    /// Every label used on the board, for the filter menu.
    var allLabels: [String] {
        var seen = Set<String>()
        return state.tasks.flatMap(\.labels).filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    var activePlan: ReleasePlan? { releasePlans.first(where: \.status.isActive) }

    func plan(_ id: UUID?) -> ReleasePlan? { id.flatMap { id in releasePlans.first { $0.id == id } } }

    func taskCount(for plan: ReleasePlan) -> Int { state.tasks.filter { $0.releasePlanID == plan.id }.count }

    func tasks(of plan: ReleasePlan) -> [ProjectTask] { state.tasks.filter { $0.releasePlanID == plan.id } }

    func columnName(_ id: UUID) -> String? { state.columns.first { $0.id == id }?.name }

    func connection(of plan: ReleasePlan) -> RepositoryConnection? {
        plan.repositoryConnectionID.flatMap { id in connections.first { $0.id == id } }
    }

    /// Snapshots of one plan, oldest first.
    func snapshots(of plan: ReleasePlan) -> [ReleaseSnapshot] { snapshots.filter { $0.releasePlanID == plan.id } }

    /// The snapshot of the plan's current draft (pending or created), if any.
    func openSnapshot(of plan: ReleasePlan) -> ReleaseSnapshot? { snapshots(of: plan).last { $0.state.isOpen } }

    func load() async {
        do {
            state = try await board.load(projectID: projectID)
            // A board from before the Backlog tab: its Backlog column folds into To Do. If that fails, the board
            // still opens as it is.
            if let retired = try? await board.retireBacklogColumns(projectID: projectID) { state = retired }
            releasePlans = try await plans.plans(projectID: projectID)
            connections = try await connectionService.connections(projectID: projectID)
            snapshots = try await snapshotRepository.snapshots(projectID: projectID)
            loadState = .loaded
        } catch {
            loadState = .failed(AppAlert.message(for: error))
        }
    }

    // MARK: Tasks

    /// A new task in the version being planned (on the Board), or in the Backlog.
    func beginNewTask(in columnID: UUID? = nil, inVersion: Bool = true) {
        guard let column = columnID ?? columns.first?.id else { return }
        taskEditor = .new(
            ProjectTask(
                projectID: projectID, columnID: column, releasePlanID: inVersion ? activePlan?.id : nil, title: "",
                sortOrder: 0))
    }

    /// Adds a task with just a title, in the version being planned or in the Backlog, at the end of `columnID`
    /// (the first column when `nil`).
    func quickAdd(title: String, to columnID: UUID? = nil, inVersion: Bool) async -> Bool {
        guard let column = columnID ?? columns.first?.id else { return false }
        let planID = inVersion ? activePlan?.id : nil
        return await perform("Couldn’t add task") {
            try await self.board.createTask(
                projectID: self.projectID, columnID: column, title: title, releasePlanID: planID)
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
        if selectedTaskID == taskID { selectedTaskID = nil }
    }

    // MARK: Keyboard

    enum Direction {
        case up, down, left, right
    }

    var selectedTask: ProjectTask? { selectedTaskID.flatMap(state.task) }

    /// Moves the keyboard selection between visible cards. Left and right skip columns with no visible cards.
    func moveSelection(_ direction: Direction) {
        guard let task = selectedTask, let columnIndex = columns.firstIndex(where: { $0.id == task.columnID }) else {
            selectedTaskID = columns.lazy.compactMap { self.visibleTasks(in: $0.id).first }.first?.id
            return
        }
        let tasks = visibleTasks(in: task.columnID)
        let index = tasks.firstIndex { $0.id == task.id } ?? 0
        switch direction {
        case .up: if index > 0 { selectedTaskID = tasks[index - 1].id }
        case .down: if index + 1 < tasks.count { selectedTaskID = tasks[index + 1].id }
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var other = columnIndex + step
            while columns.indices.contains(other) {
                let candidates = visibleTasks(in: columns[other].id)
                if !candidates.isEmpty {
                    selectedTaskID = candidates[min(index, candidates.count - 1)].id
                    return
                }
                other += step
            }
        }
    }

    /// Whether the selected card can move that way.
    func canMoveSelectedTask(_ direction: Direction) -> Bool {
        guard let task = selectedTask, let columnIndex = columns.firstIndex(where: { $0.id == task.columnID }) else {
            return false
        }
        let tasks = visibleTasks(in: task.columnID)
        let index = tasks.firstIndex { $0.id == task.id } ?? 0
        switch direction {
        case .up: return index > 0
        case .down: return index + 1 < tasks.count
        case .left: return columnIndex > 0
        case .right: return columnIndex + 1 < columns.count
        }
    }

    /// Moves the selected card: up and down within its column, left and right to the end of the adjacent column.
    func moveSelectedTask(_ direction: Direction) async {
        guard canMoveSelectedTask(direction), let task = selectedTask,
            let columnIndex = columns.firstIndex(where: { $0.id == task.columnID })
        else { return }
        let tasks = visibleTasks(in: task.columnID)
        let index = tasks.firstIndex { $0.id == task.id } ?? 0
        switch direction {
        case .up: await moveTask(task.id, to: task.columnID, before: tasks[index - 1].id)
        case .down:
            await moveTask(
                task.id, to: task.columnID, before: tasks.indices.contains(index + 2) ? tasks[index + 2].id : nil)
        case .left: await moveTask(task.id, to: columns[columnIndex - 1].id, before: nil)
        case .right: await moveTask(task.id, to: columns[columnIndex + 1].id, before: nil)
        }
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
                plannedDate: draft.plannedDate)
        case .edit:
            _ = try await plans.update(draft)
        }
        releasePlans = try await plans.plans(projectID: projectID)
        await didChange()
    }

    /// Applies `change` to the latest stored copy of a planned release and saves it. Throws validation errors.
    func updatePlan(_ id: UUID, _ change: @escaping (inout ReleasePlan) -> Void) async throws {
        let previous = planWrites
        let write = Task { () async throws -> Void in
            await previous?.value
            guard var plan = self.plan(id) else { throw PersistenceError.notFound(entity: "release plan", id: id) }
            change(&plan)
            let saved = try await self.plans.update(plan)
            if let index = self.releasePlans.firstIndex(where: { $0.id == id }) { self.releasePlans[index] = saved }
        }
        planWrites = Task { _ = try? await write.value }
        try await write.value
    }

    /// Reloads plans and snapshots after a workflow step, which changes both together.
    func reloadReleases() async {
        do {
            releasePlans = try await plans.plans(projectID: projectID)
            snapshots = try await snapshotRepository.snapshots(projectID: projectID)
            await didChange()
        } catch {
            alert = AppAlert(title: "Couldn’t reload releases", error: error)
        }
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
