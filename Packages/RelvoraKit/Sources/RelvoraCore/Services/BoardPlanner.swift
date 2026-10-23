import Foundation

/// A project's board as loaded from the store.
public struct BoardState: Sendable, Equatable {
    public var columns: [BoardColumn]
    public var tasks: [ProjectTask]

    public init(columns: [BoardColumn], tasks: [ProjectTask]) {
        self.columns = columns
        self.tasks = tasks
    }

    public var orderedColumns: [BoardColumn] { columns.sorted { $0.sortOrder < $1.sortOrder } }

    public func column(_ id: UUID) -> BoardColumn? { columns.first { $0.id == id } }

    public func task(_ id: UUID) -> ProjectTask? { tasks.first { $0.id == id } }

    /// Tasks of one column in board order.
    public func tasks(in columnID: UUID) -> [ProjectTask] {
        tasks.filter { $0.columnID == columnID }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Sort key that places an item after everything currently in `columnID`.
    public func endSortOrder(in columnID: UUID) -> Double {
        FractionalIndex.between(tasks(in: columnID).last?.sortOrder, nil)
    }
}

/// Pure board operations. Each returns the changes that implement it; nothing is saved here.
public enum BoardPlanner {
    public static let maximumColumnNameLength = 50
    public static let maximumTaskTitleLength = 200

    // MARK: Tasks

    /// Moves a task into `columnID`, directly before `beforeTaskID` (or to the end when `nil`).
    /// Entering the completion column marks the task complete; leaving it clears completion.
    /// Returns no changes when the task would end up where it already is.
    public static func moveTask(
        _ taskID: UUID,
        toColumn columnID: UUID,
        before beforeTaskID: UUID?,
        in state: BoardState,
        now: Date
    ) throws(ValidationError) -> BoardChanges {
        guard let task = state.task(taskID), let column = state.column(columnID) else { throw .unknownColumn }
        if beforeTaskID == taskID { return BoardChanges() }

        let siblings = state.tasks(in: columnID).filter { $0.id != taskID }
        let index = beforeTaskID.flatMap { id in siblings.firstIndex { $0.id == id } } ?? siblings.count
        if task.columnID == columnID, state.tasks(in: columnID).firstIndex(where: { $0.id == taskID }) == index {
            return BoardChanges()
        }

        var moved = task
        moved.columnID = columnID
        moved.completedAt = column.isCompletionColumn ? (task.completedAt ?? now) : nil
        moved.updatedAt = now

        let lower = index > 0 ? siblings[index - 1].sortOrder : nil
        let upper = index < siblings.count ? siblings[index].sortOrder : nil
        guard FractionalIndex.needsRenormalization(lower, upper) else {
            moved.sortOrder = FractionalIndex.between(lower, upper)
            return BoardChanges(upsertTasks: [moved])
        }

        var ordered = siblings
        ordered.insert(moved, at: index)
        var changed: [ProjectTask] = []
        for (item, order) in zip(ordered, FractionalIndex.renormalized(count: ordered.count)) {
            var updated = item
            updated.sortOrder = order
            if updated != item || updated.id == taskID { changed.append(updated) }
        }
        return BoardChanges(upsertTasks: changed)
    }

    /// Validates a new task from the editor and places it at the end of its column.
    public static func newTask(_ draft: ProjectTask, in state: BoardState, now: Date) throws(ValidationError)
        -> ProjectTask
    {
        guard let column = state.column(draft.columnID) else { throw .unknownColumn }
        var task = ProjectTask(
            id: draft.id,
            projectID: draft.projectID,
            columnID: draft.columnID,
            releasePlanID: draft.releasePlanID,
            title: try validatedTitle(draft.title),
            details: draft.details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            priority: draft.priority,
            type: draft.type,
            labels: draft.labels,
            checklist: normalizedChecklist(draft.checklist),
            sortOrder: state.endSortOrder(in: draft.columnID),
            createdAt: now,
            completedAt: column.isCompletionColumn ? now : nil
        )
        task.updatedAt = now
        return task
    }

    /// Validates a task edited outside the board (title, notes, labels, checklist, column, release plan).
    /// A column change appends the task to its new column; otherwise position and completion are kept.
    public static func update(
        _ edited: ProjectTask,
        original: ProjectTask,
        in state: BoardState,
        now: Date
    ) throws(ValidationError) -> ProjectTask {
        guard let column = state.column(edited.columnID) else { throw .unknownColumn }
        var task = edited
        task.title = try validatedTitle(edited.title)
        task.details = edited.details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        task.labels = ProjectTask.normalizedLabels(edited.labels)
        task.checklist = normalizedChecklist(edited.checklist)
        if edited.columnID != original.columnID {
            task.sortOrder = state.endSortOrder(in: edited.columnID)
            task.completedAt = column.isCompletionColumn ? (original.completedAt ?? now) : nil
        } else {
            task.sortOrder = original.sortOrder
            task.completedAt = original.completedAt
        }
        task.updatedAt = now
        return task
    }

    public static func validatedTitle(_ title: String) throws(ValidationError) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyTitle }
        guard trimmed.count <= maximumTaskTitleLength else { throw .titleTooLong(maximum: maximumTaskTitleLength) }
        return trimmed
    }

    /// Drops empty items, trims titles, and renumbers in the given order.
    public static func normalizedChecklist(_ items: [ChecklistItem]) -> [ChecklistItem] {
        let kept = items.compactMap { item -> ChecklistItem? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            var copy = item
            copy.title = title
            return copy
        }
        return zip(kept, FractionalIndex.renormalized(count: kept.count)).map { item, order in
            var copy = item
            copy.sortOrder = order
            return copy
        }
    }

    // MARK: Columns

    /// A name for a new or renamed column: valid, and not “Backlog”, which is its own tab.
    static func newColumnName(_ name: String) throws(ValidationError) -> String {
        let name = try validatedColumnName(name)
        guard !ProjectRules.isBacklogName(name) else { throw .reservedColumnName(name) }
        return name
    }

    public static func validatedColumnName(_ name: String) throws(ValidationError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard trimmed.count <= maximumColumnNameLength else { throw .nameTooLong(maximum: maximumColumnNameLength) }
        return trimmed
    }

    /// Adds a column. It goes just before the completion column when that column is last (so "Done" stays
    /// at the end), otherwise at the end.
    public static func addColumn(
        named name: String,
        projectID: UUID,
        in state: BoardState,
        now: Date
    ) throws(ValidationError) -> (column: BoardColumn, changes: BoardChanges) {
        var column = BoardColumn(
            projectID: projectID, name: try newColumnName(name), sortOrder: 0, createdAt: now)
        var ordered = state.orderedColumns
        let index = ordered.last?.isCompletionColumn == true ? ordered.count - 1 : ordered.count
        let lower = index > 0 ? ordered[index - 1].sortOrder : nil
        let upper = index < ordered.count ? ordered[index].sortOrder : nil
        guard FractionalIndex.needsRenormalization(lower, upper) else {
            column.sortOrder = FractionalIndex.between(lower, upper)
            return (column, BoardChanges(upsertColumns: [column]))
        }
        ordered.insert(column, at: index)
        let renumbered = renumber(ordered)
        return (renumbered[index], BoardChanges(upsertColumns: renumbered))
    }

    public static func renameColumn(
        _ id: UUID,
        to name: String,
        in state: BoardState,
        now: Date
    ) throws(ValidationError) -> BoardChanges {
        guard var column = state.column(id) else { throw .unknownColumn }
        column.name = try newColumnName(name)
        column.updatedAt = now
        return BoardChanges(upsertColumns: [column])
    }

    /// Moves a column to `index` in board order and renumbers all columns.
    public static func moveColumn(_ id: UUID, toIndex index: Int, in state: BoardState) throws(ValidationError)
        -> BoardChanges
    {
        guard let column = state.column(id) else { throw .unknownColumn }
        var ordered = state.orderedColumns.filter { $0.id != id }
        ordered.insert(column, at: min(max(index, 0), ordered.count))
        let changed = zip(renumber(ordered), ordered).filter { renumbered, _ in
            state.column(renumbered.id)?.sortOrder != renumbered.sortOrder
        }.map(\.0)
        return BoardChanges(upsertColumns: changed)
    }

    /// Makes `id` the project's only completion column and updates task completion to match.
    public static func makeCompletionColumn(_ id: UUID, in state: BoardState, now: Date) throws(ValidationError)
        -> BoardChanges
    {
        guard let target = state.column(id) else { throw .unknownColumn }
        guard !target.isCompletionColumn else { return BoardChanges() }
        var changes = BoardChanges()
        for var column in state.columns where column.isCompletionColumn != (column.id == id) {
            column.isCompletionColumn = column.id == id
            column.updatedAt = now
            changes.upsertColumns.append(column)
        }
        for var task in state.tasks {
            let complete = task.columnID == id
            guard (task.completedAt != nil) != complete else { continue }
            task.completedAt = complete ? now : nil
            changes.upsertTasks.append(task)
        }
        return changes
    }

    /// Deletes a column. Its tasks, if any, move to the end of `destination` in their current order.
    public static func deleteColumn(
        _ id: UUID,
        movingTasksTo destination: UUID?,
        in state: BoardState,
        now: Date
    ) throws(ValidationError) -> BoardChanges {
        guard let column = state.column(id) else { throw .unknownColumn }
        guard !column.isCompletionColumn else { throw .cannotDeleteCompletionColumn }
        guard state.columns.count > 1 else { throw .cannotDeleteLastColumn }

        let tasks = state.tasks(in: id)
        guard !tasks.isEmpty else { return BoardChanges(deleteColumnIDs: [id]) }
        guard let destination, destination != id, let target = state.column(destination) else {
            throw .columnNotEmpty(taskCount: tasks.count)
        }
        var order = state.tasks(in: destination).last?.sortOrder ?? 0
        let moved = tasks.map { task in
            var copy = task
            order += 1
            copy.columnID = destination
            copy.sortOrder = order
            copy.completedAt = target.isCompletionColumn ? (task.completedAt ?? now) : nil
            copy.updatedAt = now
            return copy
        }
        return BoardChanges(upsertTasks: moved, deleteColumnIDs: [id])
    }

    /// Boards from before the Backlog tab had a “Backlog” column. Its tasks move to the board's To Do column, keeping
    /// their order and their version, and the column goes; a board without a To Do column renames it To Do instead.
    /// Either way the tasks stay not started. Returns `nil` when the board has no Backlog column.
    public static func retireBacklogColumns(in state: BoardState, now: Date) -> BoardChanges? {
        let isToDo = { (column: BoardColumn) in
            !column.isCompletionColumn
                && column.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("To Do") == .orderedSame
        }
        var board = state
        var changes = BoardChanges()
        for column in state.orderedColumns where !column.isCompletionColumn && ProjectRules.isBacklogName(column.name) {
            if let toDo = board.orderedColumns.first(where: isToDo),
                let deletion = try? deleteColumn(column.id, movingTasksTo: toDo.id, in: board, now: now)
            {
                let moved = Dictionary(uniqueKeysWithValues: deletion.upsertTasks.map { ($0.id, $0) })
                board = BoardState(
                    columns: board.columns.filter { $0.id != column.id },
                    tasks: board.tasks.map { moved[$0.id] ?? $0 })
                changes.upsertTasks += deletion.upsertTasks
                changes.deleteColumnIDs += deletion.deleteColumnIDs
            } else {
                var renamed = column
                renamed.name = "To Do"
                renamed.updatedAt = now
                board = BoardState(columns: board.columns.map { $0.id == column.id ? renamed : $0 }, tasks: board.tasks)
                changes.upsertColumns.append(renamed)
            }
        }
        return changes.isEmpty ? nil : changes
    }

    private static func renumber(_ columns: [BoardColumn]) -> [BoardColumn] {
        zip(columns, FractionalIndex.renormalized(count: columns.count)).map { column, order in
            var copy = column
            copy.sortOrder = order
            return copy
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
