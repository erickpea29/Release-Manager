import Foundation
import RelvoraCore
import RelvoraPersistence
import Synchronization
import Testing

@testable import RelvoraMCP

private final class ActivityLog: Sendable {
    private let events = Mutex<[RelvoraTools.Activity]>([])

    func record(_ event: RelvoraTools.Activity) { events.withLock { $0.append(event) } }

    var all: [RelvoraTools.Activity] { events.withLock { $0 } }
}

/// An in-memory Relvora: "Relvora" in the group "Acme", planning 0.2.0, with one task in it and one in the Backlog.
private struct Desk {
    let store: PersistentStore
    let tools: RelvoraTools
    let project: Project
    let plan: ReleasePlan
    let activity = ActivityLog()

    init(planned: Bool = true) async throws {
        store = try PersistentStore.inMemory()
        let group = try await ProjectGroupService(repository: store.groups).create(name: "Acme")
        project = try await ProjectService(repository: store.projects).create(
            name: "Relvora", details: "Release planning", groupID: group.id)
        _ = try await ProjectService(repository: store.projects).create(name: "Side")
        let plans = ReleasePlanService(repository: store.releasePlans)
        plan = try await plans.create(projectID: project.id, version: "0.2.0", title: "Updates")
        let board = BoardService(repository: store.board)
        let first = try await board.load(projectID: project.id).orderedColumns[0]
        _ = try await board.createTask(
            projectID: project.id, columnID: first.id, title: "Existing", releasePlanID: plan.id)
        _ = try await board.createTask(projectID: project.id, columnID: first.id, title: "Someday")
        if !planned { _ = try await plans.cancel(plan) }
        let activity = activity
        tools = RelvoraTools(
            projects: store.projects, groups: store.groups, board: board, plans: plans,
            didCreate: { activity.record($0) })
    }

    func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async -> MCPToolResult {
        await tools.all.first { $0.name == name }!.run(arguments)
    }

    func tasks() async throws -> [ProjectTask] {
        try await BoardService(repository: store.board).load(projectID: project.id).tasks
    }
}

@Suite("Relvora tools")
struct RelvoraToolsTests {
    @Test("Projects list their group, the version being planned, and the board")
    func listProjects() async throws {
        let desk = try await Desk()
        let result = await desk.call("list_projects")
        #expect(!result.isError)
        let projects = try #require(result.content["projects"]?.arrayValue)
        #expect(projects.compactMap { $0["name"]?.stringValue }.sorted() == ["Relvora", "Side"])
        let relvora = try #require(projects.first { $0["name"] == "Relvora" })
        #expect(relvora["group"] == "Acme" && relvora["description"] == "Release planning")
        #expect(relvora["versionBeingPlanned"]?["version"] == "0.2.0")
        #expect(relvora["versionBeingPlanned"]?["tasks"] == 1 && relvora["backlogTasks"] == 1)
        #expect(relvora["columns"] == ["To Do", "In Progress", "Review", "Done"])
        #expect(relvora["completionColumn"] == "Done")
        #expect(projects.first { $0["name"] == "Side" }?["versionBeingPlanned"] == .null)
    }

    @Test("Tasks are listed for the version, the Backlog, or everything")
    func listTasks() async throws {
        let desk = try await Desk()
        func titles(_ scope: String?) async -> [String] {
            var arguments: [String: JSONValue] = ["project": "relvora"]
            if let scope { arguments["scope"] = .string(scope) }
            let result = await desk.call("list_tasks", arguments)
            return result.content["tasks"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        }
        #expect(await titles(nil) == ["Existing"])
        #expect(await titles("backlog") == ["Someday"])
        #expect(await titles("all").sorted() == ["Existing", "Someday"])
        let result = await desk.call("list_tasks", ["project": "Relvora"])
        let task = try #require(result.content["tasks"]?.arrayValue?.first)
        #expect(task["column"] == "To Do" && task["version"] == "0.2.0" && task["done"] == false)
    }

    @Test("Created tasks join the version being planned, labeled claude, in the first column")
    func createInVersion() async throws {
        let desk = try await Desk()
        let result = await desk.call(
            "create_tasks",
            [
                "project": .string(desk.project.id.uuidString),
                "tasks": [
                    [
                        "title": "Show the update sheet", "notes": "From the sidebar.", "type": "bug",
                        "priority": "high", "labels": ["ui"], "checklist": ["Design", "Build"],
                    ],
                    ["title": "Write ADR 0018", "type": "documentation", "column": "review"],
                ],
            ])
        #expect(!result.isError, "\(result.content)")
        #expect(result.content["summary"] == "Created 2 tasks in Relvora 0.2.0.")

        let tasks = try await desk.tasks()
        let sheet = try #require(tasks.first { $0.title == "Show the update sheet" })
        #expect(sheet.releasePlanID == desk.plan.id && sheet.type == .bugFix && sheet.priority == .high)
        #expect(sheet.labels == ["ui", "claude"] && sheet.details == "From the sidebar.")
        #expect(sheet.checklist.map(\.title) == ["Design", "Build"] && sheet.completedAt == nil)
        let state = try await BoardService(repository: desk.store.board).load(projectID: desk.project.id)
        #expect(state.column(sheet.columnID)?.name == "To Do")
        let adr = try #require(tasks.first { $0.title == "Write ADR 0018" })
        #expect(state.column(adr.columnID)?.name == "Review" && adr.labels == ["claude"])
        #expect(
            desk.activity.all
                == [.init(projectID: desk.project.id, projectName: "Relvora", version: "0.2.0", count: 2)])
    }

    @Test("Tasks can go to the Backlog, outside any version")
    func createInBacklog() async throws {
        let desk = try await Desk()
        let result = await desk.call(
            "create_tasks", ["project": "Relvora", "destination": "backlog", "tasks": [["title": "Later idea"]]])
        #expect(result.content["summary"] == "Created 1 task in the Backlog of Relvora.")
        let task = try #require(try await desk.tasks().first { $0.title == "Later idea" })
        #expect(task.releasePlanID == nil && task.type == .feature && task.priority == .medium)
    }

    @Test(
        "Nothing is created when any task is invalid, or the place doesn't exist",
        arguments: [
            ("an empty title", ["project": "Relvora", "tasks": [["title": "Fine"], ["title": "  "]]], "Task 2"),
            ("an unknown type", ["project": "Relvora", "tasks": [["title": "A", "type": "epic"]]], "unknown type"),
            (
                "the Done column", ["project": "Relvora", "tasks": [["title": "A", "column": "Done"]]],
                "marks them done"
            ),
            (
                "an unknown column", ["project": "Relvora", "tasks": [["title": "A", "column": "QA"]]], "no column “QA”"
            ),
            ("an unknown project", ["project": "Nope", "tasks": [["title": "A"]]], "no project named “Nope”"),
            ("no tasks", ["project": "Relvora", "tasks": []], "at least one task"),
        ] as [(String, [String: JSONValue], String)])
    func refuses(case: String, arguments: [String: JSONValue], message: String) async throws {
        let desk = try await Desk()
        let result = await desk.call("create_tasks", arguments)
        #expect(result.isError)
        #expect(result.content.stringValue?.contains(message) == true, "\(result.content)")
        #expect(try await desk.tasks().count == 2)
        #expect(desk.activity.all.isEmpty)
    }

    @Test("Without a version being planned, the version is refused and the Backlog still works")
    func noVersion() async throws {
        let desk = try await Desk(planned: false)
        let refused = await desk.call("create_tasks", ["project": "Relvora", "tasks": [["title": "A"]]])
        #expect(refused.isError && refused.content.stringValue?.contains("no version being planned") == true)
        let backlog = await desk.call(
            "create_tasks", ["project": "Relvora", "destination": "backlog", "tasks": [["title": "A"]]])
        #expect(!backlog.isError)
    }

    @Test("Too many tasks in one call are refused")
    func limit() async throws {
        let desk = try await Desk()
        let tasks = JSONValue.array((1...51).map { ["title": .string("Task \($0)")] })
        let result = await desk.call("create_tasks", ["project": "Relvora", "tasks": tasks])
        #expect(result.isError && result.content.stringValue?.contains("at most 50") == true)
    }

    @Test("Only reading and creating are offered")
    func toolset() async throws {
        let desk = try await Desk()
        #expect(desk.tools.all.map(\.name) == ["list_projects", "list_tasks", "create_tasks"])
        #expect(desk.tools.all.map(\.isReadOnly) == [true, true, false])
    }
}
