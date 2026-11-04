import Foundation
import RelvoraCore
@testable import RelvoraMCP
import RelvoraPersistence
import Testing

/// Claude's control of Relvora beyond creating tasks (ADR 0026): tasks, versions, columns, and projects.
@Suite("Relvora tools: control")
struct RelvoraToolsControlTests {
    // MARK: Tasks

    @Test("Tasks are edited: title, notes, type, priority, labels, and checklist ticks; unchanged steps keep their id")
    func editTask() async throws {
        let desk = try await Desk()
        let existing = try await desk.task("Existing")
        await desk.succeed(
            "update_tasks",
            [
                "project": "Relvora",
                "tasks": [
                    [
                        "id": .string(existing.id.uuidString), "title": "Existing, renamed", "notes": "Why.",
                        "type": "bug", "priority": "urgent", "labels": ["ui", "claude"],
                        "checklist": [["title": "Design", "done": true], "Build"],
                    ]
                ],
            ])
        var task = try await desk.task("Existing, renamed")
        #expect(task.details == "Why." && task.type == .bugFix && task.priority == .urgent)
        #expect(task.labels == ["ui", "claude"] && task.releasePlanID == desk.plan.id)
        #expect(task.checklist.map(\.title) == ["Design", "Build"] && task.checklist.map(\.isDone) == [true, false])
        let design = task.checklist[0].id

        // Ticking a step: the whole checklist again. Empty notes clear them.
        await desk.succeed(
            "update_tasks",
            [
                "project": "Relvora",
                "tasks": [
                    [
                        "id": .string(task.id.uuidString), "notes": "",
                        "checklist": [["title": "Design", "done": true], ["title": "Build", "done": true]],
                    ]
                ],
            ])
        task = try await desk.task("Existing, renamed")
        #expect(task.details == nil && task.checklist.allSatisfy(\.isDone) && task.checklist[0].id == design)
        #expect(desk.activity.all.map(\.kind) == [.changed, .changed])
        #expect(desk.activity.all.last?.summary == "Claude updated “Existing, renamed” in Relvora.")
    }

    @Test("Tasks move between columns; done moves them in and out of the completion column")
    func moveAndComplete() async throws {
        let desk = try await Desk()
        let id = JSONValue.string(try await desk.task("Existing").id.uuidString)
        func place() async throws -> (column: String?, done: Bool) {
            let task = try await desk.task("Existing")
            return (try await desk.board().column(task.columnID)?.name, task.completedAt != nil)
        }

        await desk.succeed("update_tasks", ["project": "Relvora", "tasks": [["id": id, "column": "in progress"]]])
        #expect(try await place() == ("In Progress", false))
        let done = await desk.succeed("update_tasks", ["project": "Relvora", "tasks": [["id": id, "done": true]]])
        #expect(try await place() == ("Done", true))
        #expect(done["summary"] == "Completed 1 task in Relvora.")
        #expect(desk.activity.all.last?.summary == "Claude completed “Existing” in Relvora.")
        await desk.succeed("update_tasks", ["project": "Relvora", "tasks": [["id": id, "done": false]]])
        #expect(try await place() == ("To Do", false))
        await desk.succeed("update_tasks", ["project": "Relvora", "tasks": [["id": id, "column": "Done"]]])
        #expect(try await place() == ("Done", true))
    }

    @Test("Tasks move into the version being planned, back to the Backlog, and before another task")
    func versionAndPosition() async throws {
        let desk = try await Desk()
        let someday = try await desk.task("Someday")
        let existing = try await desk.task("Existing")
        await desk.succeed(
            "update_tasks",
            [
                "project": "Relvora",
                "tasks": [
                    ["id": .string(someday.id.uuidString), "version": "version"],
                    ["id": .string(existing.id.uuidString), "version": "backlog"],
                ],
            ])
        #expect(try await desk.task("Someday").releasePlanID == desk.plan.id)
        #expect(try await desk.task("Existing").releasePlanID == nil)

        // Both are in To Do, Existing first: put Someday before it.
        await desk.succeed(
            "update_tasks",
            [
                "project": "Relvora",
                "tasks": [["id": .string(someday.id.uuidString), "before": .string(existing.id.uuidString)]],
            ])
        let toDo = try await desk.board().orderedColumns[0]
        #expect(try await desk.board().tasks(in: toDo.id).map(\.title) == ["Someday", "Existing"])
    }

    @Test(
        "Nothing changes when any edit is invalid",
        arguments: [
            ("an unknown id", ["id": .string(UUID().uuidString), "title": "X"], "no task"),
            ("no change", [:], "Nothing to change"),
            ("done in a column that isn't Done", ["column": "Review", "done": true], "isn’t the completion column"),
            ("an unknown column", ["column": "QA"], "no column “QA”"),
            ("an empty title", ["title": "  "], "title"),
            ("a position in another column", ["column": "Review", "before": "self"], "“before”"),
        ] as [(String, [String: JSONValue?], String)])
    func refusesEdits(case: String, fields: [String: JSONValue?], message: String) async throws {
        let desk = try await Desk()
        let existing = try await desk.task("Existing")
        let someday = try await desk.task("Someday")
        var second: [String: JSONValue] = ["id": .string(someday.id.uuidString)]
        for (key, value) in fields {
            if let value { second[key] = value == "self" ? .string(existing.id.uuidString) : value }
        }
        let refused = await desk.refusal(
            "update_tasks",
            [
                "project": "Relvora",
                "tasks": [["id": .string(existing.id.uuidString), "title": "Changed"], .object(second)],
            ])
        #expect(refused.contains("Task 2") && refused.contains(message), "\(refused)")
        #expect(try await desk.task("Existing").title == "Existing")
        #expect(desk.activity.all.isEmpty)
    }

    @Test("Without a version being planned, moving a task into it is refused")
    func noVersionToMoveInto() async throws {
        let desk = try await Desk(planned: false)
        let someday = try await desk.task("Someday")
        let refused = await desk.refusal(
            "update_tasks",
            ["project": "Relvora", "tasks": [["id": .string(someday.id.uuidString), "version": "version"]]])
        #expect(refused.contains("no version being planned") && refused.contains("plan_version"))
    }

    @Test("Tasks are deleted together, or not at all when an id is unknown")
    func deleteTasks() async throws {
        let desk = try await Desk()
        let ids = try await desk.tasks().map { JSONValue.string($0.id.uuidString) }
        let refused = await desk.refusal(
            "delete_tasks", ["project": "Relvora", "ids": .array(ids + [.string(UUID().uuidString)])])
        #expect(refused.contains("Task 3") && refused.contains("no task"))
        #expect(try await desk.tasks().count == 2)

        let deleted = await desk.succeed("delete_tasks", ["project": "Relvora", "ids": .array(ids)])
        #expect(deleted["summary"] == "Deleted 2 tasks from Relvora.")
        #expect(try await desk.tasks().isEmpty)
        let activity = try #require(desk.activity.all.last)
        #expect(activity.kind == .removed && activity.summary == "Claude deleted 2 tasks from Relvora.")
        #expect(activity.detail == "“Existing”, “Someday”." || activity.detail == "“Someday”, “Existing”.")
    }

    @Test("Deleting is the only destructive change to tasks, and is announced as one")
    func destructiveAnnotations() async throws {
        let desk = try await Desk()
        let listing = try #require(desk.tools.all.first { $0.name == "delete_tasks" }).listing
        #expect(listing["annotations"]?["destructiveHint"] == true && listing["annotations"]?["readOnlyHint"] == false)
        let update = try #require(desk.tools.all.first { $0.name == "update_tasks" }).listing
        #expect(update["annotations"]?["destructiveHint"] == false)
    }

    // MARK: Versions

    @Test("Versions are listed with what can be changed, and the release checklist of the one being planned")
    func listVersions() async throws {
        let desk = try await Desk()
        let result = await desk.succeed("list_versions", ["project": "Relvora"])
        let version = try #require(result["versions"]?.arrayValue?.first)
        #expect(version["version"] == "0.2.0" && version["title"] == "Updates" && version["status"] == "Planned")
        #expect(version["beingPlanned"] == true && version["canEdit"] == true && version["canDelete"] == true)
        #expect(version["tasks"] == 1 && version["done"] == 0)
        #expect(
            version["releaseChecklist"]
                == [["step": "Test on a clean Mac", "done": false], ["step": "Update the docs", "done": false]])
    }

    @Test("A version is edited: version, title, notes, planned date, and release checklist ticks")
    func editVersion() async throws {
        let desk = try await Desk()
        let result = await desk.succeed(
            "update_version",
            [
                "project": "Relvora", "newVersion": "0.2.1", "title": "", "notes": "Smaller.",
                "plannedDate": "2026-11-20",
                "releaseChecklist": [["step": "test on a clean mac", "done": true]],
            ])
        #expect(result["version"]?["version"] == "0.2.1" && result["version"]?["plannedDate"] == "2026-11-20")
        #expect(result["version"]?["releaseChecklist"]?.arrayValue?.first?["done"] == true)
        let plan = try #require(try await desk.plans().first)
        #expect(plan.version == "0.2.1" && plan.title == nil && plan.details == "Smaller.")
        #expect(plan.completedStepIDs.count == 1 && plan.status == .planned)
        #expect(desk.activity.all.last?.summary == "Claude edited Relvora 0.2.1.")

        #expect(
            await desk.refusal(
                "update_version", ["project": "Relvora", "releaseChecklist": [["step": "Ship it", "done": true]]]
            ).contains("no step “Ship it”"))
        #expect(
            await desk.refusal("update_version", ["project": "Relvora", "plannedDate": "2026-02-30"])
                .contains("isn’t a date"))
        #expect(await desk.refusal("update_version", ["project": "Relvora"]).contains("Nothing to change"))
    }

    @Test("One version at a time: planning another is refused until the first is cancelled")
    func planCancelAndPlanAgain() async throws {
        let desk = try await Desk()
        #expect(
            await desk.refusal("plan_version", ["project": "Relvora", "version": "0.3.0"])
                .contains("0.2.0 is still being planned"))
        #expect(await desk.refusal("cancel_version", ["project": "Relvora"]).contains("Name the version"))

        await desk.succeed("cancel_version", ["project": "Relvora", "version": "0.2.0"])
        #expect(try await desk.plans().first?.status == .cancelled)
        let backlog = await desk.succeed("list_tasks", ["project": "Relvora", "scope": "backlog"])
        #expect(
            backlog["tasks"]?.arrayValue?.compactMap { $0["title"]?.stringValue }.sorted() == ["Existing", "Someday"])
        let cancelled = try #require(desk.activity.all.last)
        #expect(cancelled.kind == .removed && cancelled.summary == "Claude cancelled Relvora 0.2.0.")
        #expect(
            await desk.refusal("cancel_version", ["project": "Relvora", "version": "0.2.0"]).contains("cancelled"))

        let planned = await desk.succeed(
            "plan_version", ["project": "Relvora", "version": "0.3.0", "title": "Control", "plannedDate": "2026-12-01"])
        #expect(planned["version"]?["beingPlanned"] == true && planned["version"]?["plannedDate"] == "2026-12-01")
        #expect(desk.activity.all.last?.summary == "Claude planned Relvora 0.3.0.")
        #expect(
            await desk.refusal("plan_version", ["project": "Relvora", "version": "v0.3.0"]).contains(
                "still being planned"))
    }

    @Test("Deleting a version keeps its tasks, outside any version")
    func deleteVersion() async throws {
        let desk = try await Desk()
        let result = await desk.succeed("delete_version", ["project": "Relvora", "version": "0.2.0"])
        #expect(result["summary"] == "Deleted Relvora 0.2.0. Its 1 task stayed.")
        #expect(try await desk.plans().isEmpty)
        #expect(try await desk.task("Existing").releasePlanID == nil)
        #expect(desk.activity.all.last?.kind == .removed)
        #expect(
            await desk.refusal("delete_version", ["project": "Relvora", "version": "9.9.9"])
                .contains("has no version 9.9.9"))
    }

    // MARK: Columns

    @Test("Columns are added, renamed, moved, made the completion column, and deleted with their tasks moved")
    func columns() async throws {
        let desk = try await Desk()
        var result = await desk.succeed("add_column", ["project": "Relvora", "name": "QA", "position": 2])
        #expect(result["columns"] == ["To Do", "QA", "In Progress", "Review", "Done"])
        #expect(await desk.refusal("add_column", ["project": "Relvora", "name": "qa"]).contains("already has"))
        result = await desk.succeed("add_column", ["project": "Relvora", "name": "Later"])
        #expect(result["columns"] == ["To Do", "QA", "In Progress", "Review", "Later", "Done"])

        result = await desk.succeed(
            "update_column", ["project": "Relvora", "column": "QA", "name": "Testing", "position": 4])
        #expect(result["columns"] == ["To Do", "In Progress", "Review", "Testing", "Later", "Done"])

        // Existing goes to Testing, which then becomes the completion column: Existing is done.
        let existing = try await desk.task("Existing")
        await desk.succeed(
            "update_tasks",
            ["project": "Relvora", "tasks": [["id": .string(existing.id.uuidString), "column": "Testing"]]])
        result = await desk.succeed("update_column", ["project": "Relvora", "column": "Testing", "completion": true])
        #expect(result["completionColumn"] == "Testing")
        #expect(try await desk.task("Existing").completedAt != nil)

        #expect(
            await desk.refusal("delete_column", ["project": "Relvora", "column": "Testing"])
                .contains("completion column can’t be deleted"))
        await desk.succeed("update_column", ["project": "Relvora", "column": "Done", "completion": true])
        #expect(
            await desk.refusal("delete_column", ["project": "Relvora", "column": "Testing"])
                .contains("still has 1 task"))
        result = await desk.succeed(
            "delete_column", ["project": "Relvora", "column": "Testing", "moveTasksTo": "Done"])
        #expect(result["columns"] == ["To Do", "In Progress", "Review", "Later", "Done"])
        #expect(result["summary"] == "Deleted “Testing”. Its 1 task moved to “Done”.")
        #expect(try await desk.board().column(try await desk.task("Existing").columnID)?.name == "Done")
        #expect(desk.activity.all.last?.kind == .removed)
    }

    // MARK: Projects

    @Test("Projects are created with the new-project board, in a group that's created when new")
    func createProject() async throws {
        let desk = try await Desk()
        let result = await desk.succeed(
            "create_project", ["name": "Website", "description": "Marketing site", "group": "Pilou"])
        #expect(result["project"]?["group"] == "Pilou" && result["project"]?["columns"] == ["Next", "Shipped"])
        #expect(result["summary"] == "Created Website in the new group Pilou.")
        let groups = try await desk.store.groups.groups().map(\.name).sorted()
        #expect(groups == ["Acme", "Pilou"])
        let activity = try #require(desk.activity.all.last)
        #expect(activity.changedProject && activity.summary == "Claude created the project Website in Pilou.")

        let again = await desk.succeed("create_project", ["name": "Blog", "group": "acme"])
        #expect(again["project"]?["group"] == "Acme")
        #expect(try await desk.store.groups.groups().count == 2)
        #expect(await desk.refusal("create_project", ["name": "website"]).contains("already a project named"))
        // A bad name creates no group.
        #expect(await desk.refusal("create_project", ["name": "  ", "group": "Orphan"]).contains("name is required"))
        #expect(
            await desk.refusal("update_project", ["project": "Side", "name": "", "group": "Orphan"]).contains("name"))
        #expect(try await desk.store.groups.groups().count == 2)
    }

    @Test("Projects are renamed, regrouped, archived, and unarchived; archived projects can't be changed")
    func updateProject() async throws {
        let desk = try await Desk()
        await desk.succeed(
            "update_project", ["project": "Relvora", "name": "Relvora App", "description": "", "group": ""])
        var project = try #require(
            try await desk.store.projects.projects(includeArchived: true).first { $0.id == desk.project.id })
        #expect(project.name == "Relvora App" && project.details == nil && project.groupID == nil)
        #expect(desk.activity.all.last?.summary == "Claude edited the project Relvora App.")

        await desk.succeed("update_project", ["project": "Relvora App", "archived": true])
        #expect(desk.activity.all.last?.summary == "Claude archived Relvora App.")
        let listed = await desk.succeed("list_projects", [:])
        #expect(listed["projects"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Side"])
        let all = await desk.succeed("list_projects", ["includeArchived": true])
        #expect(all["projects"]?.arrayValue?.first { $0["name"] == "Relvora App" }?["archived"] == true)

        let someday = try await desk.task("Someday")
        #expect(
            await desk.refusal(
                "update_tasks",
                ["project": "Relvora App", "tasks": [["id": .string(someday.id.uuidString), "done": true]]]
            ).contains("archived"))
        #expect(
            await desk.refusal("plan_version", ["project": "Relvora App", "version": "1.0.0"]).contains("archived"))
        #expect(await desk.refusal("update_project", ["project": "Relvora App", "name": "X"]).contains("archived"))

        await desk.succeed("update_project", ["project": "Relvora App", "archived": false, "group": "Acme"])
        project = try #require(
            try await desk.store.projects.projects(includeArchived: true).first { $0.id == desk.project.id })
        #expect(!project.isArchived && project.groupID != nil)
    }
}
