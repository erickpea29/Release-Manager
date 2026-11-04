import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

extension StoreTests {
    /// The rules Claude's `update_tasks` and `delete_tasks` follow (ADR 0026).
    @Suite("Task editing")
    struct TaskEditingTests {
        /// "Relvora", planning 0.3.1, with "Fix login" in it (two checklist steps) and "Someday" in the Backlog.
        private struct Desk {
            let store: PersistentStore
            let project: Project
            let plan: ReleasePlan
            let service: TaskEditingService

            init() async throws {
                store = try PersistentStore.inMemory()
                project = try await ProjectService(repository: store.projects).create(name: "Relvora")
                let plans = ReleasePlanService(repository: store.releasePlans)
                plan = try await plans.create(projectID: project.id, version: "0.3.1")
                let board = BoardService(repository: store.board)
                _ = try await TaskCreationService(board: board, plans: plans).create(
                    [NewTask(title: "Fix login", checklist: ["Reproduce", "Fix"])], in: project, destination: .version)
                _ = try await TaskCreationService(board: board, plans: plans).create(
                    [NewTask(title: "Someday")], in: project, destination: .backlog)
                service = TaskEditingService(board: board, plans: plans)
            }

            func board() async throws -> BoardState {
                try await BoardService(repository: store.board).load(projectID: project.id)
            }

            func task(_ title: String) async throws -> ProjectTask {
                try #require(try await board().tasks.first { $0.title == title })
            }

            func column(of title: String) async throws -> String? {
                try await board().column(try await task(title).columnID)?.name
            }
        }

        @Test("Edits are saved with the editor's rules: trimmed title, empty notes cleared, steps keep their identity")
        func edit() async throws {
            let desk = try await Desk()
            let original = try await desk.task("Fix login")
            let edited = try await desk.service.update(
                [
                    TaskEdit(
                        id: original.id, title: "  Fix the login sheet ", notes: "  ", priority: .high,
                        labels: ["auth", "Auth", " "],
                        checklist: [ChecklistEntry(title: "Fix", isDone: true), ChecklistEntry(title: "Test")])
                ], in: desk.project)
            let task = try #require(edited.tasks.first)
            #expect(task.title == "Fix the login sheet" && task.details == nil && task.priority == .high)
            #expect(task.labels == ["auth"] && task.releasePlanID == desk.plan.id)
            #expect(task.checklist.map(\.title) == ["Fix", "Test"] && task.checklist.map(\.isDone) == [true, false])
            #expect(task.checklist[0].id == original.checklist[1].id)
            #expect(task.sortOrder == original.sortOrder && task.columnID == original.columnID)
        }

        @Test("done moves a task into the completion column and back out to the first column")
        func done() async throws {
            let desk = try await Desk()
            let id = try await desk.task("Fix login").id
            // Not done yet: done false changes nothing about its place.
            _ = try await desk.service.update([TaskEdit(id: id, done: false)], in: desk.project)
            #expect(try await desk.column(of: "Fix login") == "To Do")
            _ = try await desk.service.update([TaskEdit(id: id, column: "Review")], in: desk.project)
            _ = try await desk.service.update([TaskEdit(id: id, done: true)], in: desk.project)
            #expect(try await desk.column(of: "Fix login") == "Done")
            #expect(try await desk.task("Fix login").completedAt != nil)
            _ = try await desk.service.update([TaskEdit(id: id, done: false)], in: desk.project)
            #expect(try await desk.column(of: "Fix login") == "To Do")
            #expect(try await desk.task("Fix login").completedAt == nil)
        }

        @Test("A problem with any edit changes nothing")
        func atomic() async throws {
            let desk = try await Desk()
            let fix = try await desk.task("Fix login")
            let someday = try await desk.task("Someday")
            let cases: [([TaskEdit], TaskEditingError)] = [
                (
                    [TaskEdit(id: fix.id, title: "Changed"), TaskEdit(id: someday.id, column: "Review", done: true)],
                    .doneConflictsWithColumn(task: 2, column: "Review", done: true)
                ),
                (
                    [TaskEdit(id: fix.id, title: "Changed"), TaskEdit(id: fix.id, priority: .low)],
                    .repeatedTask(task: 2)
                ),
                ([TaskEdit(id: fix.id, title: "Changed"), TaskEdit(id: someday.id)], .nothingToChange(task: 2)),
                (
                    [TaskEdit(id: fix.id, title: "Changed"), TaskEdit(id: someday.id, column: "Done", done: false)],
                    .doneConflictsWithColumn(task: 2, column: "Done", done: false)
                ),
            ]
            for (edits, expected) in cases {
                await #expect(throws: expected) { try await desk.service.update(edits, in: desk.project) }
            }
            #expect(try await desk.task("Fix login").title == "Fix login")
        }

        @Test("Tasks join the version being planned or leave it for the Backlog, keeping their column")
        func placement() async throws {
            let desk = try await Desk()
            let fix = try await desk.task("Fix login")
            let someday = try await desk.task("Someday")
            _ = try await desk.service.update(
                [TaskEdit(id: someday.id, placement: .version), TaskEdit(id: fix.id, placement: .backlog)],
                in: desk.project)
            #expect(try await desk.task("Someday").releasePlanID == desk.plan.id)
            #expect(try await desk.task("Fix login").releasePlanID == nil)
            #expect(try await desk.column(of: "Fix login") == "To Do")
        }

        @Test("Tasks are deleted in one change, or none when one is unknown")
        func delete() async throws {
            let desk = try await Desk()
            let ids = try await desk.board().tasks.map(\.id)
            let unknown = UUID()
            await #expect(throws: TaskEditingError.unknownTask(task: 2, id: unknown)) {
                try await desk.service.delete([ids[0], unknown], in: desk.project)
            }
            #expect(try await desk.board().tasks.count == 2)
            let deleted = try await desk.service.delete(ids + [ids[0]], in: desk.project)
            #expect(deleted.tasks.count == 2 && deleted.board.tasks.isEmpty)
        }

        @Test("Archived projects can't be changed")
        func archived() async throws {
            let desk = try await Desk()
            let archived = try await ProjectService(repository: desk.store.projects).setArchived(desk.project, true)
            let id = try await desk.task("Fix login").id
            await #expect(throws: TaskEditingError.archivedProject("Relvora")) {
                try await desk.service.update([TaskEdit(id: id, done: true)], in: archived)
            }
            await #expect(throws: TaskEditingError.archivedProject("Relvora")) {
                try await desk.service.delete([id], in: archived)
            }
        }
    }
}
