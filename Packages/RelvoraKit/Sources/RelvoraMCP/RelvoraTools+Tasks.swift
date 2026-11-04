import Foundation
import RelvoraCore

/// Creating, editing, moving, completing, and deleting tasks (ADR 0018, ADR 0026).
extension RelvoraTools {
    /// The fields `create_tasks` and `update_tasks` share.
    private static func taskProperties(type: String?, priority: String?, labels: String?) -> [String: JSONValue] {
        func described(_ schema: [String: JSONValue], _ description: String?) -> JSONValue {
            var schema = schema
            if let description { schema["description"] = .string(description) }
            return .object(schema)
        }
        return [
            "title": ["type": "string", "maxLength": .integer(BoardPlanner.maximumTaskTitleLength)],
            "notes": ["type": "string", "description": "Markdown."],
            "type": described(
                ["type": "string", "enum": .array(TaskType.allCases.map { .string($0.rawValue) })], type),
            "priority": described(
                ["type": "string", "enum": .array(TaskPriority.allCases.map { .string($0.rawValue) })], priority),
            "labels": described(["type": "array", "items": ["type": "string"]], labels),
        ]
    }

    // MARK: create_tasks

    var createTasks: MCPTool {
        var properties = Self.taskProperties(type: "Default: feature.", priority: "Default: medium.", labels: nil)
        properties["checklist"] = [
            "type": "array", "items": ["type": "string"], "description": "Steps within the task.",
        ]
        properties["column"] = [
            "type": "string",
            "description": "A column's name from list_projects; the first column when omitted. Not the completion column.",
        ]
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
                    "project": Self.projectProperty,
                    "destination": [
                        "type": "string", "enum": ["version", "backlog"],
                        "description": "version (default): the version being planned. backlog: outside any version.",
                    ],
                    "tasks": [
                        "type": "array", "minItems": 1, "maxItems": .integer(Self.maximumTasksPerCall),
                        "items": [
                            "type": "object", "properties": .object(properties), "required": ["title"],
                            "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["project", "tasks"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run { try await create(arguments) }
        }
    }

    private func create(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let project = try await project(arguments["project"])
        let destination: TaskDestination
        switch try Self.string(arguments, "destination") ?? "version" {
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
        let place = version.map { "\(project.name) \($0)" } ?? "the Backlog of \(project.name)"
        await didChange(
            Activity(
                projectID: project.id, projectName: project.name, kind: .addedTasks(count: count, version: version),
                summary: "Claude added \(Self.count(count, "task")) to \(place).",
                tab: version == nil ? "backlog" : "board"))
        return [
            "created": .array(
                result.tasks.map { Self.json($0, column: result.board.column($0.columnID)?.name, version: version) }),
            "summary": .string("Created \(Self.count(count, "task")) in \(place)."),
        ]
    }

    /// A task from Claude's arguments, labeled `claude`. Its title, notes, and column are checked with the others.
    private static func newTask(_ item: JSONValue, name: String) throws -> NewTask {
        guard let fields = item.objectValue else { throw ToolError("\(name) must be an object.") }
        return NewTask(
            title: try string(fields, "title", in: name) ?? "", notes: try string(fields, "notes", in: name),
            type: try fields["type"].map { try taskType($0, name: name) } ?? .feature,
            priority: try fields["priority"].map { try priority($0, name: name) } ?? .medium,
            labels: (try strings(fields["labels"], "labels", name: name) ?? []) + [label],
            checklist: try strings(fields["checklist"], "checklist", name: name) ?? [],
            column: try string(fields, "column", in: name))
    }

    static func taskName(_ number: Int, of count: Int) -> String {
        count == 1 ? "The task" : "Task \(number)"
    }

    /// Problems in Claude's terms: what to change in the call, or what to ask the user.
    private static func message(_ error: TaskCreationError, taskCount: Int) -> String {
        switch error {
        case .archivedProject(let name):
            "\(name) is archived. Unarchive it first (update_project with archived false), if the user wants to "
                + "change it."
        case .noVersionBeingPlanned(let name):
            "\(name) has no version being planned. Use destination \"backlog\", or plan one with plan_version."
        case .noTasks: "Give at least one task."
        case .tooManyTasks(let maximum): "Create at most \(maximum) tasks per call."
        default: (error.task.map { "\(taskName($0, of: taskCount)): " } ?? "") + (error.errorDescription ?? "")
        }
    }

    // MARK: update_tasks

    var updateTasks: MCPTool {
        var properties = Self.taskProperties(type: nil, priority: nil, labels: "Replaces the labels.")
        properties["id"] = ["type": "string", "description": "The task's id, from list_tasks."]
        properties["notes"] = ["type": "string", "description": "Markdown. Replaces the notes; empty clears them."]
        properties["checklist"] = [
            "type": "array",
            "description": "Replaces the checklist, in this order. Resend every step to tick or untick one.",
            "items": [
                "type": "object",
                "properties": ["title": ["type": "string"], "done": ["type": "boolean"]],
                "required": ["title"], "additionalProperties": false,
            ],
        ]
        properties["column"] = [
            "type": "string",
            "description": .string(
                "Moves the task to the end of this column (a name from list_projects). The completion column marks "
                    + "it done; leaving it marks it not done."),
        ]
        properties["done"] = [
            "type": "boolean",
            "description": .string(
                "true moves the task to the completion column; false moves a done task back to the first column."),
        ]
        properties["version"] = [
            "type": "string", "enum": ["version", "backlog"],
            "description": .string(
                "version: put the task in the version being planned, on its Board. backlog: take it out of any "
                    + "version. It keeps its column."),
        ]
        properties["before"] = [
            "type": "string",
            "description": "Places the task just before this task (an id) in the column it ends up in.",
        ]
        return MCPTool(
            name: "update_tasks", title: "Edit, move, or complete tasks",
            description: """
                Changes tasks: title, notes, type, priority, labels, checklist (and its ticks), column, done, \
                position, and whether they're in the version being planned or the Backlog. Give only what changes. \
                Changes nothing if any change is invalid.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "tasks": [
                        "type": "array", "minItems": 1, "maxItems": .integer(Self.maximumTasksPerCall),
                        "items": [
                            "type": "object", "properties": .object(properties), "required": ["id"],
                            "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["project", "tasks"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run { try await update(arguments) }
        }
    }

    private func update(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let project = try await project(arguments["project"])
        guard let items = arguments["tasks"]?.arrayValue, !items.isEmpty else {
            throw ToolError("Give at least one task.")
        }
        let edits = try items.enumerated().map { index, item in
            try Self.edit(item, name: Self.taskName(index + 1, of: items.count))
        }
        let result: EditedTasks
        do {
            result = try await TaskEditingService(board: board, plans: plans).update(edits, in: project)
        } catch let error as TaskEditingError {
            throw ToolError(Self.message(error, taskCount: items.count))
        }
        let versions = Dictionary(
            uniqueKeysWithValues: try await plans.plans(projectID: project.id).map { ($0.id, $0.version) })
        let onlyCompleting = edits.allSatisfy { $0 == TaskEdit(id: $0.id, done: true) }
        let verb = onlyCompleting ? "completed" : "updated"
        await didChange(
            Activity(
                projectID: project.id, projectName: project.name, kind: .changed,
                summary: "Claude \(verb) \(Self.tasksPhrase(result.tasks)) in \(project.name).",
                tab: await tasksTab(project)))
        return [
            "updated": .array(
                result.tasks.map {
                    Self.json(
                        $0, column: result.board.column($0.columnID)?.name,
                        version: $0.releasePlanID.flatMap { versions[$0] })
                }),
            "summary": .string("\(verb.capitalized) \(Self.count(result.tasks.count, "task")) in \(project.name)."),
        ]
    }

    /// A change to one task from Claude's arguments.
    private static func edit(_ item: JSONValue, name: String) throws -> TaskEdit {
        guard let fields = item.objectValue else { throw ToolError("\(name) must be an object.") }
        guard let id = try string(fields, "id", in: name) else {
            throw ToolError("\(name): give its id, from list_tasks.")
        }
        var edit = TaskEdit(id: try uuid(id, "a task"))
        edit.title = try string(fields, "title", in: name)
        edit.notes = try string(fields, "notes", in: name)
        edit.type = try fields["type"].map { try taskType($0, name: name) }
        edit.priority = try fields["priority"].map { try priority($0, name: name) }
        edit.labels = try strings(fields["labels"], "labels", name: name)
        if let steps = fields["checklist"], steps != .null {
            guard let steps = steps.arrayValue else { throw ToolError("\(name): checklist must be a list.") }
            edit.checklist = try steps.map { step in
                if let title = step.stringValue { return ChecklistEntry(title: title) }
                guard let step = step.objectValue, let title = try string(step, "title", in: name) else {
                    throw ToolError("\(name): each checklist step needs a title.")
                }
                return ChecklistEntry(title: title, isDone: try bool(step, "done", in: name) ?? false)
            }
        }
        edit.column = try string(fields, "column", in: name)
        edit.done = try bool(fields, "done", in: name)
        switch try string(fields, "version", in: name) {
        case "version": edit.placement = .version
        case "backlog": edit.placement = .backlog
        case nil: break
        default: throw ToolError("\(name): version must be version or backlog.")
        }
        edit.before = try string(fields, "before", in: name).map { try uuid($0, "a task") }
        return edit
    }

    private static func message(_ error: TaskEditingError, taskCount: Int) -> String {
        switch error {
        case .archivedProject(let name):
            "\(name) is archived. Unarchive it first (update_project with archived false), if the user wants to "
                + "change it."
        case .noTasks: "Give at least one task."
        case .tooManyTasks(let maximum): "Change at most \(maximum) tasks per call."
        case .unknownTask(let number, let id):
            "\(taskName(number, of: taskCount)): there’s no task \(id.uuidString) in this project. Ids come from "
                + "list_tasks."
        case .noVersionBeingPlanned(let number, let project):
            "\(taskName(number, of: taskCount)): \(project) has no version being planned. Plan one with "
                + "plan_version first."
        default: (error.task.map { "\(taskName($0, of: taskCount)): " } ?? "") + (error.errorDescription ?? "")
        }
    }

    // MARK: delete_tasks

    var deleteTasks: MCPTool {
        MCPTool(
            name: "delete_tasks", title: "Delete tasks",
            description: """
                Deletes tasks for good, with their notes and checklists. This can't be undone: delete only tasks \
                the user asked to remove. To finish a task, use update_tasks with done true instead. Deletes \
                nothing if any id is unknown.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "ids": [
                        "type": "array", "minItems": 1, "maxItems": .integer(Self.maximumTasksPerCall),
                        "items": ["type": "string"], "description": "The tasks' ids, from list_tasks.",
                    ],
                ],
                "required": ["project", "ids"], "additionalProperties": false,
            ],
            isReadOnly: false, isDestructive: true
        ) { arguments in
            await Self.run { try await delete(arguments) }
        }
    }

    private func delete(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let project = try await project(arguments["project"])
        guard let ids = try Self.strings(arguments["ids"], "ids", name: "The request"), !ids.isEmpty else {
            throw ToolError("Give at least one task id.")
        }
        let result: DeletedTasks
        do {
            result = try await TaskEditingService(board: board, plans: plans).delete(
                try ids.map { try Self.uuid($0, "a task") }, in: project)
        } catch let error as TaskEditingError {
            throw ToolError(Self.message(error, taskCount: ids.count))
        }
        let titles = result.tasks.map { "“\($0.title)”" }
        await didChange(
            Activity(
                projectID: project.id, projectName: project.name, kind: .removed,
                summary: "Claude deleted \(Self.tasksPhrase(result.tasks)) from \(project.name).",
                detail: result.tasks.count == 1 ? nil : Self.list(titles) + ".", tab: await tasksTab(project)))
        return [
            "deleted": .array(result.tasks.map { .string($0.title) }),
            "summary": .string("Deleted \(Self.count(result.tasks.count, "task")) from \(project.name)."),
        ]
    }
}
