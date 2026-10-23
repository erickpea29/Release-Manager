import Foundation

/// Board use cases: load the current board, plan the change with `BoardPlanner`, apply it atomically.
/// Every mutating method returns the board as it is after the change.
public struct BoardService: Sendable {
    private let repository: any BoardRepository
    private let now: @Sendable () -> Date

    public init(repository: any BoardRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    public func load(projectID: UUID) async throws -> BoardState {
        BoardState(
            columns: try await repository.columns(projectID: projectID),
            tasks: try await repository.tasks(projectID: projectID)
        )
    }

    // MARK: Tasks

    /// Adds a task (from the editor) at the end of its column.
    public func createTask(_ draft: ProjectTask) async throws -> BoardState {
        let state = try await load(projectID: draft.projectID)
        let task = try BoardPlanner.newTask(draft, in: state, now: now())
        return try await commit(BoardChanges(upsertTasks: [task]), projectID: draft.projectID)
    }

    /// Quick add: a task with just a title at the end of `columnID`.
    public func createTask(
        projectID: UUID,
        columnID: UUID,
        title: String,
        priority: TaskPriority = .medium,
        type: TaskType = .feature,
        releasePlanID: UUID? = nil
    ) async throws -> BoardState {
        try await createTask(
            ProjectTask(
                projectID: projectID, columnID: columnID, releasePlanID: releasePlanID, title: title,
                priority: priority, type: type, sortOrder: 0))
    }

    /// Saves edits made in the task editor.
    public func updateTask(_ edited: ProjectTask) async throws -> BoardState {
        let state = try await load(projectID: edited.projectID)
        guard let original = state.task(edited.id) else {
            throw PersistenceError.notFound(entity: "task", id: edited.id)
        }
        let task = try BoardPlanner.update(edited, original: original, in: state, now: now())
        return try await commit(BoardChanges(upsertTasks: [task]), projectID: edited.projectID)
    }

    /// Moves a task to `columnID`, before `beforeTaskID` or at the end. Used by drag and drop and menus.
    public func moveTask(_ taskID: UUID, projectID: UUID, toColumn columnID: UUID, before beforeTaskID: UUID?)
        async throws -> BoardState
    {
        let state = try await load(projectID: projectID)
        let changes = try BoardPlanner.moveTask(
            taskID, toColumn: columnID, before: beforeTaskID, in: state, now: now())
        return try await commit(changes, projectID: projectID, unchanged: state)
    }

    /// Folds a board's old “Backlog” column into the next column (`BoardPlanner.retireBacklogColumns`). Returns the
    /// new board, or `nil` when there was nothing to change.
    public func retireBacklogColumns(projectID: UUID) async throws -> BoardState? {
        let state = try await load(projectID: projectID)
        guard let changes = BoardPlanner.retireBacklogColumns(in: state, now: now()) else { return nil }
        return try await commit(changes, projectID: projectID)
    }

    public func deleteTask(_ taskID: UUID, projectID: UUID) async throws -> BoardState {
        try await commit(BoardChanges(deleteTaskIDs: [taskID]), projectID: projectID)
    }

    // MARK: Columns

    public func addColumn(named name: String, projectID: UUID) async throws -> BoardState {
        let state = try await load(projectID: projectID)
        let (_, changes) = try BoardPlanner.addColumn(named: name, projectID: projectID, in: state, now: now())
        return try await commit(changes, projectID: projectID)
    }

    public func renameColumn(_ columnID: UUID, to name: String, projectID: UUID) async throws -> BoardState {
        let state = try await load(projectID: projectID)
        return try await commit(
            try BoardPlanner.renameColumn(columnID, to: name, in: state, now: now()), projectID: projectID)
    }

    public func moveColumn(_ columnID: UUID, toIndex index: Int, projectID: UUID) async throws -> BoardState {
        let state = try await load(projectID: projectID)
        return try await commit(
            try BoardPlanner.moveColumn(columnID, toIndex: index, in: state), projectID: projectID, unchanged: state)
    }

    public func makeCompletionColumn(_ columnID: UUID, projectID: UUID) async throws -> BoardState {
        let state = try await load(projectID: projectID)
        return try await commit(
            try BoardPlanner.makeCompletionColumn(columnID, in: state, now: now()),
            projectID: projectID,
            unchanged: state
        )
    }

    public func deleteColumn(_ columnID: UUID, movingTasksTo destination: UUID?, projectID: UUID) async throws
        -> BoardState
    {
        let state = try await load(projectID: projectID)
        return try await commit(
            try BoardPlanner.deleteColumn(columnID, movingTasksTo: destination, in: state, now: now()),
            projectID: projectID
        )
    }

    private func commit(_ changes: BoardChanges, projectID: UUID, unchanged: BoardState? = nil) async throws
        -> BoardState
    {
        if changes.isEmpty, let unchanged { return unchanged }
        try await repository.apply(changes)
        return try await load(projectID: projectID)
    }
}

/// Release plan use cases. Enforces `ReleasePlanRules` against the project's existing plans.
public struct ReleasePlanService: Sendable {
    private let repository: any ReleasePlanRepository
    private let now: @Sendable () -> Date

    public init(repository: any ReleasePlanRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    public func plans(projectID: UUID) async throws -> [ReleasePlan] {
        try await repository.plans(projectID: projectID)
    }

    public func create(
        projectID: UUID,
        version: String,
        title: String? = nil,
        details: String? = nil,
        plannedDate: Date? = nil,
        targetBranch: String? = nil
    ) async throws -> ReleasePlan {
        let draft = ReleasePlan(
            projectID: projectID,
            version: version,
            title: title,
            details: details,
            targetBranch: targetBranch,
            plannedDate: plannedDate,
            createdAt: now()
        )
        let plan = try ReleasePlanRules.validated(draft, existing: try await repository.plans(projectID: projectID))
        try await repository.save(plan)
        return plan
    }

    public func update(_ edited: ReleasePlan) async throws -> ReleasePlan {
        let existing = try await repository.plans(projectID: edited.projectID)
        guard let original = existing.first(where: { $0.id == edited.id }) else {
            throw PersistenceError.notFound(entity: "release plan", id: edited.id)
        }
        guard ReleasePlanRules.isEditable(original) else { throw ValidationError.releasePlanLocked(original.status) }
        var plan = try ReleasePlanRules.validated(edited, existing: existing)
        plan.status = original.status
        plan.updatedAt = now()
        try await repository.save(plan)
        return plan
    }

    public func cancel(_ plan: ReleasePlan) async throws -> ReleasePlan {
        guard ReleasePlanRules.isEditable(plan) else { throw ValidationError.releasePlanLocked(plan.status) }
        var cancelled = plan
        cancelled.status = .cancelled
        cancelled.updatedAt = now()
        try await repository.save(cancelled)
        return cancelled
    }

    /// Tasks linked to the plan stay on the board, unlinked.
    public func delete(_ plan: ReleasePlan) async throws {
        guard ReleasePlanRules.isDeletable(plan) else { throw ValidationError.releasePlanLocked(plan.status) }
        try await repository.deletePlan(id: plan.id)
    }
}
