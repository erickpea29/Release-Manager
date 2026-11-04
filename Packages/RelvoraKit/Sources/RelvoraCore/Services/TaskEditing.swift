import Foundation

/// A change to one task from outside the Board: Claude's `update_tasks` (ADR 0026). Fields left `nil` keep their value.
public struct TaskEdit: Sendable, Equatable {
    /// Where the task belongs: the version being planned, or the Backlog.
    public enum Placement: Sendable, Equatable {
        /// Into the version being planned. Refused when there's none.
        case version
        /// Out of any version, into the Backlog (or, once done, out of sight).
        case backlog
    }

    public var id: UUID
    public var title: String?
    /// Markdown. Empty clears the notes.
    public var notes: String?
    public var type: TaskType?
    public var priority: TaskPriority?
    /// Replaces the labels.
    public var labels: [String]?
    /// Replaces the checklist, in this order. Items whose title is unchanged keep their identity.
    public var checklist: [ChecklistEntry]?
    /// A column's name, matched ignoring case and accents. The task goes to the end of it unless `before` is given.
    public var column: String?
    /// `true` moves the task to the completion column; `false` takes it out of it, to the first column.
    public var done: Bool?
    public var placement: Placement?
    /// Places the task just before this one, which must be in the column the task ends up in.
    public var before: UUID?

    public init(
        id: UUID, title: String? = nil, notes: String? = nil, type: TaskType? = nil, priority: TaskPriority? = nil,
        labels: [String]? = nil, checklist: [ChecklistEntry]? = nil, column: String? = nil, done: Bool? = nil,
        placement: Placement? = nil, before: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.type = type
        self.priority = priority
        self.labels = labels
        self.checklist = checklist
        self.column = column
        self.done = done
        self.placement = placement
        self.before = before
    }

    var isEmpty: Bool {
        title == nil && notes == nil && type == nil && priority == nil && labels == nil && checklist == nil
            && column == nil && done == nil && placement == nil && before == nil
    }
}

/// One step of a task's checklist, as given from outside the Board.
public struct ChecklistEntry: Sendable, Equatable {
    public var title: String
    public var isDone: Bool

    public init(title: String, isDone: Bool = false) {
        self.title = title
        self.isDone = isDone
    }
}

/// Why no task was changed. Problems with one task carry its number in the request, from 1.
public enum TaskEditingError: Error, Sendable, Equatable, LocalizedError {
    case archivedProject(String)
    case noTasks
    case tooManyTasks(maximum: Int)
    case unknownTask(task: Int, id: UUID)
    case repeatedTask(task: Int)
    case nothingToChange(task: Int)
    case invalidTitle(task: Int, ValidationError)
    case notesTooLong(task: Int, maximum: Int)
    case unknownColumn(task: Int, name: String, columns: [String])
    /// `done` and `column` disagree, such as done with a column that isn't the completion column.
    case doneConflictsWithColumn(task: Int, column: String, done: Bool)
    case noCompletionColumn(String)
    case noVersionBeingPlanned(task: Int, project: String)
    case unknownPosition(task: Int)

    /// The task the problem is about, from 1; `nil` when it's about the whole request.
    public var task: Int? {
        switch self {
        case .unknownTask(let task, _), .repeatedTask(let task), .nothingToChange(let task),
            .invalidTitle(let task, _), .notesTooLong(let task, _), .unknownColumn(let task, _, _),
            .doneConflictsWithColumn(let task, _, _), .noVersionBeingPlanned(let task, _), .unknownPosition(let task):
            task
        default: nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .archivedProject(let name): "\(name) is archived."
        case .noTasks: "There’s no task to change."
        case .tooManyTasks(let maximum): "At most \(maximum) tasks can be changed at a time."
        case .unknownTask(_, let id): "There’s no task \(id.uuidString) in this project."
        case .repeatedTask: "This task is already in the request."
        case .nothingToChange: "Nothing to change."
        case .invalidTitle(_, let error): error.errorDescription
        case .notesTooLong(_, let maximum): "Notes can be at most \(maximum) characters."
        case .unknownColumn(_, let name, let columns):
            "There’s no column “\(name)”. The columns are \(columns.joined(separator: ", "))."
        case .doneConflictsWithColumn(_, let column, let done):
            done
                ? "“\(column)” isn’t the completion column, so a task there isn’t done."
                : "“\(column)” is the completion column, so a task there is done."
        case .noCompletionColumn(let name): "\(name)’s board has no completion column."
        case .noVersionBeingPlanned(_, let project): "\(project) has no version being planned."
        case .unknownPosition: "“before” must be another task in the column the task ends up in."
        }
    }
}

/// The tasks as saved, in the order they were given.
public struct EditedTasks: Sendable, Equatable {
    public let project: Project
    public let tasks: [ProjectTask]
    /// The version being planned, if any.
    public let plan: ReleasePlan?
    /// The board after the change.
    public let board: BoardState
}

/// The tasks deleted, as they were.
public struct DeletedTasks: Sendable, Equatable {
    public let project: Project
    public let tasks: [ProjectTask]
    /// The board after the change.
    public let board: BoardState
}

/// Edits, moves, completes, and deletes tasks from outside the Board (Claude, ADR 0026), with the rules of the app's
/// task editor and drag and drop:
/// - Every change is checked before any is made, so a problem changes nothing.
/// - Entering the completion column marks a task done; leaving it marks it not done.
public struct TaskEditingService: Sendable {
    public static let maximumTasks = TaskCreationService.maximumTasks

    private let board: BoardService
    private let plans: ReleasePlanService
    private let now: @Sendable () -> Date

    public init(board: BoardService, plans: ReleasePlanService, now: @escaping @Sendable () -> Date = { .now }) {
        self.board = board
        self.plans = plans
        self.now = now
    }

    /// Throws `TaskEditingError` for anything the caller can fix, and `PersistenceError` when saving fails.
    public func update(_ edits: [TaskEdit], in project: Project) async throws -> EditedTasks {
        try Self.checkRequest(count: edits.count, project: project)
        let state = try await board.load(projectID: project.id)
        let plan = try await plans.plans(projectID: project.id).first(where: \.status.isActive)

        var seen = Set<UUID>()
        var planned: [(task: ProjectTask, before: UUID?)] = []
        for (index, edit) in edits.enumerated() {
            let number = index + 1
            guard seen.insert(edit.id).inserted else { throw TaskEditingError.repeatedTask(task: number) }
            let task = try Self.edited(edit, number: number, project: project, plan: plan, state: state, now: now())
            planned.append((task, edit.before))
        }

        var after = state
        var saved: [ProjectTask] = []
        for (task, before) in planned {
            after = try await board.updateTask(task)
            if let before {
                after = try await board.moveTask(task.id, projectID: project.id, toColumn: task.columnID, before: before)
            }
            saved.append(after.task(task.id) ?? task)
        }
        // A later move can renumber an earlier task's position: report each as it ends up.
        saved = saved.map { after.task($0.id) ?? $0 }
        return EditedTasks(project: project, tasks: saved, plan: plan, board: after)
    }

    /// Deletes the tasks in one change. Throws `TaskEditingError` when one isn't in the project.
    public func delete(_ ids: [UUID], in project: Project) async throws -> DeletedTasks {
        try Self.checkRequest(count: ids.count, project: project)
        let state = try await board.load(projectID: project.id)
        var seen = Set<UUID>()
        var tasks: [ProjectTask] = []
        for (index, id) in ids.enumerated() where seen.insert(id).inserted {
            guard let task = state.task(id) else { throw TaskEditingError.unknownTask(task: index + 1, id: id) }
            tasks.append(task)
        }
        let after = try await board.deleteTasks(tasks.map(\.id), projectID: project.id)
        return DeletedTasks(project: project, tasks: tasks, board: after)
    }

    private static func checkRequest(count: Int, project: Project) throws(TaskEditingError) {
        guard !project.isArchived else { throw .archivedProject(project.name) }
        guard count > 0 else { throw .noTasks }
        guard count <= maximumTasks else { throw .tooManyTasks(maximum: maximumTasks) }
    }

    /// The task with `edit` applied, checked against the board as it is now.
    static func edited(
        _ edit: TaskEdit, number: Int, project: Project, plan: ReleasePlan?, state: BoardState, now: Date
    ) throws(TaskEditingError) -> ProjectTask {
        guard let original = state.task(edit.id) else { throw .unknownTask(task: number, id: edit.id) }
        guard !edit.isEmpty else { throw .nothingToChange(task: number) }
        var task = original
        if let title = edit.title {
            do {
                task.title = try BoardPlanner.validatedTitle(title)
            } catch {
                throw .invalidTitle(task: number, error)
            }
        }
        if let notes = edit.notes {
            guard notes.count <= TaskCreationService.maximumNotesLength else {
                throw .notesTooLong(task: number, maximum: TaskCreationService.maximumNotesLength)
            }
            task.details = notes
        }
        if let type = edit.type { task.type = type }
        if let priority = edit.priority { task.priority = priority }
        if let labels = edit.labels { task.labels = labels }
        if let checklist = edit.checklist { task.checklist = Self.checklist(checklist, replacing: original.checklist) }
        task.columnID = try column(for: edit, number: number, original: original, project: project, state: state)
        switch edit.placement {
        case .version?:
            guard let plan else { throw .noVersionBeingPlanned(task: number, project: project.name) }
            task.releasePlanID = plan.id
        case .backlog?: task.releasePlanID = nil
        case nil: break
        }
        if let before = edit.before {
            guard before != task.id, state.task(before)?.columnID == task.columnID else {
                throw .unknownPosition(task: number)
            }
        }
        do {
            return try BoardPlanner.update(task, original: original, in: state, now: now)
        } catch ValidationError.unknownColumn {
            throw .unknownColumn(task: number, name: edit.column ?? "", columns: state.orderedColumns.map(\.name))
        } catch {
            throw .invalidTitle(task: number, error)
        }
    }

    /// The column the task ends up in: the one named, or the one `done` implies, or its own.
    private static func column(
        for edit: TaskEdit, number: Int, original: ProjectTask, project: Project, state: BoardState
    ) throws(TaskEditingError) -> UUID {
        let columns = state.orderedColumns
        if let name = edit.column {
            guard let named = BoardState.column(named: name, in: columns) else {
                throw .unknownColumn(task: number, name: name, columns: columns.map(\.name))
            }
            if let done = edit.done, done != named.isCompletionColumn {
                throw .doneConflictsWithColumn(task: number, column: named.name, done: done)
            }
            return named.id
        }
        let isDone = state.column(original.columnID)?.isCompletionColumn == true
        switch edit.done {
        case true? where !isDone:
            guard let completion = columns.first(where: \.isCompletionColumn) else {
                throw .noCompletionColumn(project.name)
            }
            return completion.id
        case false? where isDone:
            return columns.first { !$0.isCompletionColumn }?.id ?? original.columnID
        default:
            return original.columnID
        }
    }

    /// The new checklist, in order. An item keeps its identity when an existing one has the same title.
    static func checklist(_ entries: [ChecklistEntry], replacing items: [ChecklistItem]) -> [ChecklistItem] {
        var unused = items
        return entries.enumerated().map { index, entry in
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = unused.firstIndex { $0.title == title }.map { unused.remove(at: $0).id } ?? UUID()
            return ChecklistItem(id: id, title: title, isDone: entry.isDone, sortOrder: Double(index + 1))
        }
    }
}
