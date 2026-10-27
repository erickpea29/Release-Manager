import Foundation

/// Where tasks added from outside the Board go: Claude's `create_tasks` (ADR 0018) and Shortcuts (ADR 0023).
public enum TaskDestination: Sendable, Equatable {
    /// The version being planned. Refused when there's none.
    case version
    /// The Backlog, outside any version.
    case backlog
    /// The version being planned, or the Backlog when there's none.
    case versionOrBacklog
}

/// A task described from outside the Board, checked and placed by `TaskCreationService`.
public struct NewTask: Sendable, Equatable {
    public var title: String
    /// Markdown.
    public var notes: String?
    public var type: TaskType
    public var priority: TaskPriority
    public var labels: [String]
    /// Steps within the task, in order.
    public var checklist: [String]
    /// A column's name, matched ignoring case and accents. The first column when `nil`.
    public var column: String?

    public init(
        title: String, notes: String? = nil, type: TaskType = .feature, priority: TaskPriority = .medium,
        labels: [String] = [], checklist: [String] = [], column: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.type = type
        self.priority = priority
        self.labels = labels
        self.checklist = checklist
        self.column = column
    }
}

/// Why no task was created. Problems with one task carry its number, from 1.
public enum TaskCreationError: Error, Sendable, Equatable, LocalizedError {
    case archivedProject(String)
    case noVersionBeingPlanned(String)
    case noTasks
    case tooManyTasks(maximum: Int)
    case noColumns(String)
    case invalidTitle(task: Int, ValidationError)
    case notesTooLong(task: Int, maximum: Int)
    case unknownColumn(task: Int, name: String, columns: [String])
    case completionColumn(task: Int, name: String)

    /// The task the problem is about, from 1; `nil` when it's about the whole request.
    public var task: Int? {
        switch self {
        case .invalidTitle(let task, _), .notesTooLong(let task, _), .unknownColumn(let task, _, _),
            .completionColumn(let task, _):
            task
        default: nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .archivedProject(let name): "\(name) is archived."
        case .noVersionBeingPlanned(let name): "\(name) has no version being planned."
        case .noTasks: "There’s no task to add."
        case .tooManyTasks(let maximum): "At most \(maximum) tasks can be added at a time."
        case .noColumns(let name): "\(name) has no columns."
        case .invalidTitle(_, let error): error.errorDescription
        case .notesTooLong(_, let maximum): "Notes can be at most \(maximum) characters."
        case .unknownColumn(_, let name, let columns):
            "There’s no column “\(name)”. The columns are \(columns.joined(separator: ", "))."
        case .completionColumn(_, let name): "Tasks can’t be added to “\(name)”, which marks them done."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .archivedProject: "Unarchive it in Relvora first."
        case .noVersionBeingPlanned: "Plan a version in Relvora, or add the task to the Backlog."
        default: nil
        }
    }
}

/// The tasks created, and where they went.
public struct CreatedTasks: Sendable, Equatable {
    public let project: Project
    /// The version they joined; `nil` for the Backlog.
    public let plan: ReleasePlan?
    public let destination: TaskDestination
    /// In the order they were given.
    public let tasks: [ProjectTask]
    /// The board after the change.
    public let board: BoardState

    /// What Shortcuts and Siri say, such as "Added “Fix login” to Relvora 0.2.4."
    public var summary: String {
        let what = tasks.count == 1 ? "“\(tasks[0].title)”" : "\(tasks.count) tasks"
        if let plan { return "Added \(what) to \(project.name) \(plan.version)." }
        let reason = destination == .versionOrBacklog ? ", which has no version being planned" : ""
        return "Added \(what) to the Backlog of \(project.name)\(reason)."
    }
}

/// Adds tasks from outside the Board, with the rules of the app's task editor: Claude (ADR 0018) and Shortcuts
/// (ADR 0023) behave the same.
/// - Every task is checked before any is created, so a problem creates nothing.
/// - Each task goes at the end of its column (the first unless named), never into the completion column: creating a
///   task "done" would be completing it.
public struct TaskCreationService: Sendable {
    public static let maximumTasks = 50
    public static let maximumNotesLength = 10_000

    private let board: BoardService
    private let plans: ReleasePlanService

    public init(board: BoardService, plans: ReleasePlanService) {
        self.board = board
        self.plans = plans
    }

    /// Throws `TaskCreationError` for anything the caller can fix, and `PersistenceError` when saving fails.
    public func create(_ tasks: [NewTask], in project: Project, destination: TaskDestination) async throws
        -> CreatedTasks
    {
        guard !project.isArchived else { throw TaskCreationError.archivedProject(project.name) }
        guard !tasks.isEmpty else { throw TaskCreationError.noTasks }
        guard tasks.count <= Self.maximumTasks else { throw TaskCreationError.tooManyTasks(maximum: Self.maximumTasks) }
        let state = try await board.load(projectID: project.id)
        var plan: ReleasePlan?
        if destination != .backlog {
            plan = try await plans.plans(projectID: project.id).first(where: \.status.isActive)
            if plan == nil, destination == .version { throw TaskCreationError.noVersionBeingPlanned(project.name) }
        }

        let drafts = try tasks.enumerated().map { index, task in
            try Self.draft(task, number: index + 1, project: project, plan: plan, state: state)
        }
        var after = state
        var created: [ProjectTask] = []
        for draft in drafts {
            after = try await board.createTask(draft)
            created.append(after.task(draft.id) ?? draft)
        }
        return CreatedTasks(project: project, plan: plan, destination: destination, tasks: created, board: after)
    }

    static func draft(_ task: NewTask, number: Int, project: Project, plan: ReleasePlan?, state: BoardState)
        throws(TaskCreationError) -> ProjectTask
    {
        let title: String
        do {
            title = try BoardPlanner.validatedTitle(task.title)
        } catch {
            throw .invalidTitle(task: number, error)
        }
        if let notes = task.notes, notes.count > maximumNotesLength {
            throw .notesTooLong(task: number, maximum: maximumNotesLength)
        }
        let column: BoardColumn
        if let wanted = task.column {
            guard
                let match = state.orderedColumns.first(where: {
                    $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                })
            else {
                throw .unknownColumn(task: number, name: wanted, columns: state.orderedColumns.map(\.name))
            }
            guard !match.isCompletionColumn else { throw .completionColumn(task: number, name: match.name) }
            column = match
        } else {
            guard let first = state.orderedColumns.first(where: { !$0.isCompletionColumn }) else {
                throw .noColumns(project.name)
            }
            column = first
        }
        let checklist = task.checklist.enumerated().map {
            ChecklistItem(title: $0.element, sortOrder: Double($0.offset + 1))
        }
        return ProjectTask(
            projectID: project.id, columnID: column.id, releasePlanID: plan?.id, title: title, details: task.notes,
            priority: task.priority, type: task.type, labels: task.labels, checklist: checklist, sortOrder: 0)
    }
}
