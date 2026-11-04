import Foundation
import RelvoraCore

/// What Claude can do in Relvora (ADR 0018, ADR 0026): read projects, versions, and tasks; create, edit, move,
/// complete, and delete tasks; plan, edit, cancel, and delete versions; change columns; and create, edit, archive, and
/// group projects. Everything goes through the same services, with the same rules, as the app's own editing.
/// It can't delete projects or groups, change settings, or do anything on GitHub.
public struct RelvoraTools: Sendable {
    /// What Claude did, so the app can show it, reload what it changed, and notify the user.
    public struct Activity: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Tasks created; `version` is `nil` for the Backlog.
            case addedTasks(count: Int, version: String?)
            /// Something removed or ended for good: tasks or a column deleted, a version deleted or cancelled.
            case removed
            /// Anything else: tasks edited or moved, a version planned or edited, columns, projects.
            case changed
        }

        public let projectID: UUID
        public let projectName: String
        public let kind: Kind
        /// One sentence: "Claude deleted 2 tasks from Relvora."
        public let summary: String
        /// More about it, such as the deleted tasks' titles.
        public let detail: String?
        /// The project itself changed (created, renamed, archived, moved to a group): project lists reload.
        public let changedProject: Bool
        /// Where to see it: a workspace tab (`board`, `backlog`, `releases`).
        public let tab: String

        public init(
            projectID: UUID, projectName: String, kind: Kind, summary: String, detail: String? = nil,
            changedProject: Bool = false, tab: String
        ) {
            self.projectID = projectID
            self.projectName = projectName
            self.kind = kind
            self.summary = summary
            self.detail = detail
            self.changedProject = changedProject
            self.tab = tab
        }
    }

    public static let label = "claude"
    public static let maximumTasksPerCall = TaskCreationService.maximumTasks
    static let maximumListedTasks = 500
    static let maximumListedNotesLength = 2_000

    public static let instructions = """
        Relvora is the user's release planner on this Mac: projects (optionally in groups), each with at most one \
        version being planned. That version's tasks are on its Board, in columns; the completion column (usually \
        Done) marks a task done. Other unfinished tasks are in the Backlog.
        Start with list_projects, then list_tasks or list_versions to see what's there before changing it, and avoid \
        duplicating tasks. You can create, edit, move, complete, and delete tasks; plan, edit, cancel, and delete \
        versions, and tick their release checklist; change a board's columns; and create, edit, archive, and group \
        projects. Tasks you create are labeled "claude".
        Deleting and cancelling can't be undone: do it only when the user asked for it. You can't delete projects or \
        groups, change Relvora's settings, or do anything on GitHub (repositories, drafts, publishing, pull \
        requests): ask the user to do that in Relvora.
        """

    let projects: any ProjectRepository
    let groups: any ProjectGroupRepository
    let board: BoardService
    let plans: ReleasePlanService
    let checklist: ReleaseChecklistService
    /// The board new projects start with (Settings › Board).
    let newProjectColumns: @Sendable () async -> [ColumnTemplate]
    let didChange: @Sendable (Activity) async -> Void

    public init(
        projects: any ProjectRepository, groups: any ProjectGroupRepository, board: BoardService,
        plans: ReleasePlanService, checklist: ReleaseChecklistService,
        newProjectColumns: @escaping @Sendable () async -> [ColumnTemplate] = { ProjectRules.defaultTemplate },
        didChange: @escaping @Sendable (Activity) async -> Void = { _ in }
    ) {
        self.projects = projects
        self.groups = groups
        self.board = board
        self.plans = plans
        self.checklist = checklist
        self.newProjectColumns = newProjectColumns
        self.didChange = didChange
    }

    public var all: [MCPTool] {
        [
            listProjects, listTasks, createTasks, updateTasks, deleteTasks,
            listVersions, planVersion, updateVersion, cancelVersion, deleteVersion,
            addColumn, updateColumn, deleteColumn, createProject, updateProject,
        ]
    }

    // MARK: list_projects

    var listProjects: MCPTool {
        MCPTool(
            name: "list_projects", title: "List Relvora projects",
            description: """
                The user's projects in Relvora, with their group, the version being planned (if any) and its task \
                counts, the number of Backlog tasks, and the board's columns. Call this first.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "includeArchived": [
                        "type": "boolean", "description": "Also list archived projects. Default: false.",
                    ]
                ],
                "additionalProperties": false,
            ],
            isReadOnly: true
        ) { arguments in
            do {
                let archived = try Self.bool(arguments, "includeArchived") ?? false
                let groupNames = Dictionary(uniqueKeysWithValues: try await groups.groups().map { ($0.id, $0.name) })
                var listed: [JSONValue] = []
                for project in try await projects.projects(includeArchived: archived) {
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
                    if archived { item["archived"] = .bool(project.isArchived) }
                    listed.append(.object(item))
                }
                return .success(["projects": .array(listed)])
            } catch let error as ToolError {
                return .failure(error.message)
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
                outside it), or all of them. Each has its id, column, type, priority, labels, notes, and checklist.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
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
                let scope = try Self.string(arguments, "scope") ?? "version"
                guard ["version", "backlog", "all"].contains(scope) else {
                    throw ToolError("scope must be version, backlog, or all.")
                }
                let state = try await board.load(projectID: project.id)
                let projectPlans = try await plans.plans(projectID: project.id)
                let plan = projectPlans.first(where: \.status.isActive)
                if scope == "version", plan == nil {
                    throw ToolError(
                        "\(project.name) has no version being planned. Use scope \"backlog\", or plan one with "
                            + "plan_version.")
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

    // MARK: Projects

    static let projectProperty: JSONValue = [
        "type": "string", "description": "The project's name or id, from list_projects.",
    ]

    /// By id, or by name ignoring case. Two projects with one name need the id.
    func project(_ argument: JSONValue?) async throws -> Project {
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

    /// A project that can be changed: not archived.
    func changeableProject(_ argument: JSONValue?) async throws -> Project {
        let project = try await project(argument)
        guard !project.isArchived else { throw Self.archived(project) }
        return project
    }

    static func archived(_ project: Project) -> ToolError {
        ToolError(
            "\(project.name) is archived. Unarchive it first (update_project with archived false), if the user "
                + "wants to change it.")
    }

    /// The tab to look at a project's tasks: its Board when a version is being planned, else its Backlog.
    func tasksTab(_ project: Project) async -> String {
        let plan = try? await plans.plans(projectID: project.id).first(where: \.status.isActive)
        return plan == nil ? "backlog" : "board"
    }

    // MARK: Arguments

    /// Text, or `nil` when absent or null.
    static func string(_ arguments: [String: JSONValue], _ key: String, in name: String? = nil) throws -> String? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw ToolError("\(name.map { "\($0): " } ?? "")\(key) must be text.")
        }
    }

    static func bool(_ arguments: [String: JSONValue], _ key: String, in name: String? = nil) throws -> Bool? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw ToolError("\(name.map { "\($0): " } ?? "")\(key) must be true or false.")
        }
    }

    static func integer(_ arguments: [String: JSONValue], _ key: String) throws -> Int? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let integer = value.integerValue else { throw ToolError("\(key) must be a whole number.") }
        return integer
    }

    static func uuid(_ text: String, _ what: String) throws -> UUID {
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ToolError("“\(text)” isn’t \(what) id. Ids come from list_tasks.")
        }
        return id
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

    static func taskType(_ value: JSONValue, name: String) throws -> TaskType {
        guard let type = taskType(value.stringValue) else {
            throw ToolError("\(name): unknown type. Use one of \(list(TaskType.allCases.map(\.rawValue))).")
        }
        return type
    }

    static func priority(_ value: JSONValue, name: String) throws -> TaskPriority {
        guard let priority = value.stringValue.flatMap({ TaskPriority(rawValue: $0.lowercased()) }) else {
            throw ToolError("\(name): unknown priority. Use one of \(list(TaskPriority.allCases.map(\.rawValue))).")
        }
        return priority
    }

    static func strings(_ value: JSONValue?, _ key: String, name: String) throws -> [String]? {
        guard let value, value != .null else { return nil }
        guard let items = value.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
            throw ToolError("\(name): \(key) must be a list of text.")
        }
        return items.compactMap(\.stringValue)
    }

    /// A day as `2026-11-20`, at noon on this Mac's calendar, like a date picked in the plan editor.
    static func day(_ text: String) throws -> Date {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-").map { Int($0) }
        let calendar = Calendar.current
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
            calendar.dateComponents([.year, .month, .day], from: date)
                == DateComponents(year: year, month: month, day: day)
        else { throw ToolError("“\(text)” isn’t a date. Write dates like 2026-11-20.") }
        return date
    }

    /// `2026-11-20`, on this Mac's calendar.
    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Results

    static func json(_ plan: ReleasePlan, tasks: Int, done: Int) -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(plan.id.uuidString), "version": .string(plan.version), "status": .string(plan.status.title),
            "tasks": .integer(tasks), "done": .integer(done),
        ]
        if let title = plan.title { item["title"] = .string(title) }
        if let date = plan.plannedDate { item["plannedDate"] = .string(day(date)) }
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

    static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: ", ")
    }

    static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }

    /// “Fix login” for one task, else "3 tasks".
    static func tasksPhrase(_ tasks: [ProjectTask]) -> String {
        tasks.count == 1 ? "“\(tasks[0].title)”" : count(tasks.count, "task")
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? ToolError { return error.message }
        if let error = error as? ValidationError {
            return [error.errorDescription, error.recoverySuggestion].compactMap(\.self).joined(separator: " ")
        }
        return "Relvora couldn’t do that: \(error.localizedDescription)"
    }

    /// Runs a tool that changes something: problems become errors Claude can explain.
    static func run(_ body: () async throws -> JSONValue) async -> MCPToolResult {
        do {
            return .success(try await body())
        } catch {
            return .failure(message(error))
        }
    }
}

/// A problem the model can fix or explain to the user.
struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
