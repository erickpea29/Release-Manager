import Foundation
import RelvoraCore

/// What Claude can do in Relvora (ADR 0018): read projects, the version being planned, and tasks, and create tasks.
/// It can't edit, move, complete, or delete tasks, plan versions, or do anything on GitHub. Tasks are created with the
/// same rules as in the app, and labeled `claude`.
public struct RelvoraTools: Sendable {
    /// After tasks are created, so the app can show them.
    public struct Activity: Sendable, Equatable {
        public let projectID: UUID
        public let projectName: String
        /// The version they went to; `nil` for the Backlog.
        public let version: String?
        public let count: Int
    }

    public static let label = "claude"
    public static let maximumTasksPerCall = TaskCreationService.maximumTasks
    static let maximumListedTasks = 500
    static let maximumListedNotesLength = 2_000

    public static let instructions = """
        Relvora is the user's release planner on this Mac: projects (optionally in groups), each with at most one \
        version being planned. Its tasks are on that version's Board; other unfinished tasks are in the Backlog.
        Use list_projects to find the project and the version being planned, list_tasks to see what's already \
        there, then create_tasks to add tasks to that version or to the Backlog. Avoid duplicating existing tasks.
        Tasks you create are labeled "claude". You can't edit, move, complete, or delete tasks, plan versions, or \
        change anything on GitHub: ask the user to do that in Relvora.
        """

    private let projects: any ProjectRepository
    private let groups: any ProjectGroupRepository
    private let board: BoardService
    private let plans: ReleasePlanService
    private let didCreate: @Sendable (Activity) async -> Void

    public init(
        projects: any ProjectRepository, groups: any ProjectGroupRepository, board: BoardService,
        plans: ReleasePlanService, didCreate: @escaping @Sendable (Activity) async -> Void = { _ in }
    ) {
        self.projects = projects
        self.groups = groups
        self.board = board
        self.plans = plans
        self.didCreate = didCreate
    }

    public var all: [MCPTool] { [listProjects, listTasks, createTasks] }

    // MARK: list_projects

    var listProjects: MCPTool {
        MCPTool(
            name: "list_projects", title: "List Relvora projects",
            description: """
                The user's active projects in Relvora, with their group, the version being planned (if any) and \
                its task counts, the number of Backlog tasks, and the board's columns. Call this first.
                """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            isReadOnly: true
        ) { _ in
            do {
                let groupNames = Dictionary(uniqueKeysWithValues: try await groups.groups().map { ($0.id, $0.name) })
                var listed: [JSONValue] = []
                for project in try await projects.projects(includeArchived: false) {
                    let state = try await board.load(projectID: project.id)
                    let plan = try await plans.plans(projectID: project.id).first(where: \.status.isActive)
                    let planned = state.tasks.filter { VersionScope.isOnBoard($0, activePlanID: plan?.id) }
                    var item: [String: JSONValue] = [
                        "id": .string(project.id.uuidString), "name": .string(project.name),
                        "group": project.groupID.flatMap { groupNames[$0] }.map(JSONValue.string) ?? .null,
                        "backlogTasks": .integer(
                            state.tasks.count { VersionScope.isInBacklog($0, activePlanID: plan?.id) }),
                        "columns": .array(state.orderedColumns.map { .string($0.name) }),
                        "completionColumn": state.orderedColumns.first(where: \.isCompletionColumn)
                            .map { .string($0.name) } ?? .null,
                        "versionBeingPlanned": plan.map { plan in
                            Self.json(plan, tasks: planned.count, done: planned.count { $0.completedAt != nil })
                        } ?? .null,
                    ]
                    if let details = project.details { item["description"] = .string(details) }
                    listed.append(.object(item))
                }
                return .success(["projects": .array(listed)])
            } catch {
                return .failure("Relvora couldn’t read its projects: \(error.localizedDescription)")
            }
        }
    }

    // MARK: list_tasks

    var listTasks: MCPTool {
        MCPTool(
            name: "list_tasks", title: "List a project's tasks",
            description: """
                A project's tasks: those of the version being planned (the default), the Backlog (unfinished tasks \
                outside it), or all of them. Each has its column, type, priority, labels, notes, and checklist.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": ["type": "string", "description": "The project's name or id, from list_projects."],
                    "scope": [
                        "type": "string", "enum": ["version", "backlog", "all"],
                        "description": .string(
                            "version (default): the version being planned. backlog: unfinished tasks outside it. "
                                + "all: every task."),
                    ],
                ],
                "required": ["project"], "additionalProperties": false,
            ],
            isReadOnly: true
        ) { arguments in
            do {
                let project = try await project(arguments["project"])
                let scope = arguments["scope"]?.stringValue ?? "version"
                guard ["version", "backlog", "all"].contains(scope) else {
                    throw ToolError("scope must be version, backlog, or all.")
                }
                let state = try await board.load(projectID: project.id)
                let projectPlans = try await plans.plans(projectID: project.id)
                let plan = projectPlans.first(where: \.status.isActive)
                if scope == "version", plan == nil {
                    throw ToolError(
                        "\(project.name) has no version being planned. Use scope \"backlog\", or ask the user to plan "
                            + "a version in Relvora.")
                }
                let versions = Dictionary(uniqueKeysWithValues: projectPlans.map { ($0.id, $0.version) })
                let columns = state.orderedColumns
                let tasks = state.tasks.filter {
                    switch scope {
                    case "version": VersionScope.isOnBoard($0, activePlanID: plan?.id)
                    case "backlog": VersionScope.isInBacklog($0, activePlanID: plan?.id)
                    default: true
                    }
                }
                .sorted { lhs, rhs in
                    let left = columns.firstIndex { $0.id == lhs.columnID } ?? 0
                    let right = columns.firstIndex { $0.id == rhs.columnID } ?? 0
                    return left != right ? left < right : lhs.sortOrder < rhs.sortOrder
                }
                var result: [String: JSONValue] = [
                    "project": .string(project.name), "scope": .string(scope),
                    "tasks": .array(
                        tasks.prefix(Self.maximumListedTasks).map { task in
                            Self.json(
                                task, column: state.column(task.columnID)?.name,
                                version: task.releasePlanID.flatMap { versions[$0] })
                        }),
                ]
                if let plan { result["versionBeingPlanned"] = .string(plan.version) }
                if tasks.count > Self.maximumListedTasks {
                    result["note"] = .string("Showing the first \(Self.maximumListedTasks) of \(tasks.count) tasks.")
                }
                return .success(.object(result))
            } catch {
                return .failure(Self.message(error))
            }
        }
    }

    // MARK: create_tasks

    var createTasks: MCPTool {
        let types = TaskType.allCases.map { JSONValue.string($0.rawValue) }
        let priorities = TaskPriority.allCases.map { JSONValue.string($0.rawValue) }
        return MCPTool(
            name: "create_tasks", title: "Create tasks in Relvora",
            description: """
                Adds tasks to a project: to the version being planned (the default), shown on its Board, or to the \
                Backlog. Each task goes at the end of a column (the first one unless named). Every task gets the \
                label "claude". Creates nothing if any task is invalid.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": ["type": "string", "description": "The project's name or id, from list_projects."],
                    "destination": [
                        "type": "string", "enum": ["version", "backlog"],
                        "description": "version (default): the version being planned. backlog: outside any version.",
                    ],
                    "tasks": [
                        "type": "array", "minItems": 1, "maxItems": .integer(Self.maximumTasksPerCall),
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": [
                                    "type": "string", "maxLength": .integer(BoardPlanner.maximumTaskTitleLength),
                                ],
                                "notes": ["type": "string", "description": "Markdown."],
                                "type": ["type": "string", "enum": .array(types), "description": "Default: feature."],
                                "priority": [
                                    "type": "string", "enum": .array(priorities), "description": "Default: medium.",
                                ],
                                "labels": ["type": "array", "items": ["type": "string"]],
                                "checklist": [
                                    "type": "array", "items": ["type": "string"],
                                    "description": "Steps within the task.",
                                ],
                                "column": [
                                    "type": "string",
                                    "description": .string(
                                        "A column's name from list_projects; the first column when omitted. Not the "
                                            + "completion column."),
                                ],
                            ],
                            "required": ["title"], "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["project", "tasks"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            do {
                return .success(try await create(arguments))
            } catch {
                return .failure(Self.message(error))
            }
        }
    }

    private func create(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let project = try await project(arguments["project"])
        let destination: TaskDestination
        switch arguments["destination"]?.stringValue ?? "version" {
        case "version": destination = .version
        case "backlog": destination = .backlog
        default: throw ToolError("destination must be version or backlog.")
        }
        guard let items = arguments["tasks"]?.arrayValue, !items.isEmpty else {
            throw ToolError("Give at least one task.")
        }
        let tasks = try items.enumerated().map { index, item in
            try Self.newTask(item, name: Self.taskName(index + 1, of: items.count))
        }

        // The rules Shortcuts uses too (TaskCreationService): every task is checked before any is created.
        let result: CreatedTasks
        do {
            result = try await TaskCreationService(board: board, plans: plans).create(
                tasks, in: project, destination: destination)
        } catch let error as TaskCreationError {
            throw ToolError(Self.message(error, taskCount: items.count))
        }
        let version = result.plan?.version
        let count = result.tasks.count
        await didCreate(Activity(projectID: project.id, projectName: project.name, version: version, count: count))
        let place = version.map { "\(project.name) \($0)" } ?? "the Backlog of \(project.name)"
        return [
            "created": .array(
                result.tasks.map { Self.json($0, column: result.board.column($0.columnID)?.name, version: version) }),
            "summary": .string("Created \(count) \(count == 1 ? "task" : "tasks") in \(place)."),
        ]
    }

    /// A task from Claude's arguments, labeled `claude`. Its title, notes, and column are checked with the others.
    private static func newTask(_ item: JSONValue, name: String) throws -> NewTask {
        guard let fields = item.objectValue else { throw ToolError("\(name) must be an object.") }
        let type = try fields["type"].map { value in
            guard let type = Self.taskType(value.stringValue) else {
                throw ToolError("\(name): unknown type. Use one of \(Self.list(TaskType.allCases.map(\.rawValue))).")
            }
            return type
        }
        let priority = try fields["priority"].map { value in
            guard let priority = value.stringValue.flatMap({ TaskPriority(rawValue: $0.lowercased()) }) else {
                throw ToolError(
                    "\(name): unknown priority. Use one of \(Self.list(TaskPriority.allCases.map(\.rawValue))).")
            }
            return priority
        }
        return NewTask(
            title: fields["title"]?.stringValue ?? "", notes: fields["notes"]?.stringValue, type: type ?? .feature,
            priority: priority ?? .medium,
            labels: (fields["labels"]?.arrayValue ?? []).compactMap(\.stringValue) + [Self.label],
            checklist: (fields["checklist"]?.arrayValue ?? []).compactMap(\.stringValue),
            column: fields["column"]?.stringValue)
    }

    private static func taskName(_ number: Int, of count: Int) -> String {
        count == 1 ? "The task" : "Task \(number)"
    }

    /// Problems in Claude's terms: what to change in the call, or what to ask the user.
    private static func message(_ error: TaskCreationError, taskCount: Int) -> String {
        switch error {
        case .archivedProject(let name): "\(name) is archived. Ask the user to unarchive it in Relvora first."
        case .noVersionBeingPlanned(let name):
            "\(name) has no version being planned. Use destination \"backlog\", or ask the user to plan a version in "
                + "Relvora."
        case .noTasks: "Give at least one task."
        case .tooManyTasks(let maximum): "Create at most \(maximum) tasks per call."
        default: (error.task.map { "\(taskName($0, of: taskCount)): " } ?? "") + (error.errorDescription ?? "")
        }
    }

    // MARK: Helpers

    /// By id, or by name ignoring case. Two projects with one name need the id.
    private func project(_ argument: JSONValue?) async throws -> Project {
        guard let text = argument?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ToolError("Name the project (its name or id from list_projects).")
        }
        let all = try await projects.projects(includeArchived: true)
        if let id = UUID(uuidString: text), let project = all.first(where: { $0.id == id }) { return project }
        let matches = all.filter {
            $0.name.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let active = matches.filter { !$0.isArchived }
        if let only = (active.count == 1 ? active.first : nil) ?? (matches.count == 1 ? matches.first : nil) {
            return only
        }
        if matches.isEmpty {
            let names = all.filter { !$0.isArchived }.map(\.name)
            throw ToolError("There’s no project named “\(text)”. Projects: \(Self.list(names)).")
        }
        throw ToolError("More than one project is named “\(text)”. Use its id from list_projects.")
    }

    static func taskType(_ text: String?) -> TaskType? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if let type = TaskType.allCases.first(where: { $0.rawValue.lowercased() == text }) { return type }
        switch text {
        case "bug", "bug fix", "bug_fix", "fix": return .bugFix
        case "docs", "doc": return .documentation
        case "chore": return .maintenance
        default: return nil
        }
    }

    static func json(_ plan: ReleasePlan, tasks: Int, done: Int) -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(plan.id.uuidString), "version": .string(plan.version), "status": .string(plan.status.title),
            "tasks": .integer(tasks), "done": .integer(done),
        ]
        if let title = plan.title { item["title"] = .string(title) }
        if let date = plan.plannedDate {
            item["plannedDate"] = .string(date.formatted(.iso8601.year().month().day()))
        }
        return .object(item)
    }

    static func json(_ task: ProjectTask, column: String?, version: String?) -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(task.id.uuidString), "title": .string(task.title),
            "column": column.map(JSONValue.string) ?? .null,
            "type": .string(task.type.rawValue), "priority": .string(task.priority.rawValue),
            "labels": .array(task.labels.map(JSONValue.string)), "done": .bool(task.completedAt != nil),
            "version": version.map(JSONValue.string) ?? .null,
        ]
        if let notes = task.details {
            item["notes"] = .string(
                notes.count > maximumListedNotesLength ? String(notes.prefix(maximumListedNotesLength)) + "…" : notes)
        }
        if !task.checklist.isEmpty {
            item["checklist"] = .array(
                task.checklist.map { ["title": .string($0.title), "done": .bool($0.isDone)] })
        }
        return .object(item)
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: ", ")
    }

    private static func message(_ error: any Error) -> String {
        (error as? ToolError)?.message ?? "Relvora couldn’t do that: \(error.localizedDescription)"
    }
}

/// A problem the model can fix or explain to the user.
struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
