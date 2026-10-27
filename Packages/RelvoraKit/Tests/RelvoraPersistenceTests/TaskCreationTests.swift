import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

extension StoreTests {
    /// The rules Claude's `create_tasks` and Shortcuts' Add Task share (ADR 0018, ADR 0023).
    @Suite("Task creation")
    struct TaskCreationTests {
        /// "Relvora", planning 0.2.4 unless `planned` is false, with one task in the Backlog.
        private struct Desk {
            let store: PersistentStore
            let project: Project
            let plan: ReleasePlan?
            let service: TaskCreationService

            init(planned: Bool = true) async throws {
                store = try PersistentStore.inMemory()
                project = try await ProjectService(repository: store.projects).create(name: "Relvora")
                let plans = ReleasePlanService(repository: store.releasePlans)
                plan = planned ? try await plans.create(projectID: project.id, version: "0.2.4") : nil
                let board = BoardService(repository: store.board)
                let first = try await board.load(projectID: project.id).orderedColumns[0]
                _ = try await board.createTask(projectID: project.id, columnID: first.id, title: "Someday")
                service = TaskCreationService(board: board, plans: plans)
            }

            func tasks() async throws -> [ProjectTask] {
                try await BoardService(repository: store.board).load(projectID: project.id).tasks
            }
        }

        @Test("Tasks join the version being planned, at the end of the first column, with their details")
        func intoVersion() async throws {
            let desk = try await Desk()
            let created = try await desk.service.create(
                [
                    NewTask(
                        title: " Fix login ", notes: "The sheet.", type: .bugFix, priority: .high, labels: ["auth"],
                        checklist: ["Reproduce", "Fix"]),
                    NewTask(title: "Review copy", column: "réview"),
                ], in: desk.project, destination: .versionOrBacklog)
            #expect(created.plan?.id == desk.plan?.id && created.tasks.map(\.title) == ["Fix login", "Review copy"])
            #expect(created.summary == "Added 2 tasks to Relvora 0.2.4.")

            let fix = try #require(try await desk.tasks().first { $0.title == "Fix login" })
            #expect(fix.releasePlanID == desk.plan?.id && fix.type == .bugFix && fix.priority == .high)
            #expect(
                fix.details == "The sheet." && fix.labels == ["auth"]
                    && fix.checklist.map(\.title) == ["Reproduce", "Fix"])
            #expect(created.board.column(fix.columnID)?.name == "To Do" && fix.completedAt == nil)
            let someday = try #require(try await desk.tasks().first { $0.title == "Someday" })
            #expect(fix.sortOrder > someday.sortOrder)
            #expect(created.board.column(created.tasks[1].columnID)?.name == "Review")
        }

        @Test(
            "Without a version being planned, the task goes to the Backlog, or is refused when the version is required")
        func withoutVersion() async throws {
            let desk = try await Desk(planned: false)
            await #expect(throws: TaskCreationError.noVersionBeingPlanned("Relvora")) {
                try await desk.service.create([NewTask(title: "A")], in: desk.project, destination: .version)
            }
            let created = try await desk.service.create(
                [NewTask(title: "A")], in: desk.project, destination: .versionOrBacklog)
            #expect(created.plan == nil && created.tasks[0].releasePlanID == nil)
            #expect(created.summary == "Added “A” to the Backlog of Relvora, which has no version being planned.")

            let planned = try await Desk()
            let backlog = try await planned.service.create(
                [NewTask(title: "Later")], in: planned.project, destination: .backlog)
            #expect(backlog.plan == nil && backlog.tasks[0].releasePlanID == nil)
            #expect(backlog.summary == "Added “Later” to the Backlog of Relvora.")
        }

        @Test(
            "Nothing is created when any task is invalid",
            arguments: [
                ([NewTask(title: "Fine"), NewTask(title: "  ")], TaskCreationError.invalidTitle(task: 2, .emptyTitle)),
                (
                    [NewTask(title: "A", notes: String(repeating: "x", count: 10_001))],
                    .notesTooLong(task: 1, maximum: 10_000)
                ),
                ([NewTask(title: "A", column: "Done")], .completionColumn(task: 1, name: "Done")),
                (
                    [NewTask(title: "A", column: "QA")],
                    .unknownColumn(task: 1, name: "QA", columns: ["To Do", "In Progress", "Review", "Done"])
                ),
                ([], .noTasks),
                (Array(repeating: NewTask(title: "A"), count: 51), .tooManyTasks(maximum: 50)),
            ])
        func refuses(tasks: [NewTask], expected: TaskCreationError) async throws {
            let desk = try await Desk()
            await #expect(throws: expected) {
                try await desk.service.create(tasks, in: desk.project, destination: .version)
            }
            #expect(try await desk.tasks().map(\.title) == ["Someday"])
        }

        @Test("Archived projects take no tasks")
        func archived() async throws {
            let desk = try await Desk()
            let archived = try await ProjectService(repository: desk.store.projects).setArchived(desk.project, true)
            await #expect(throws: TaskCreationError.archivedProject("Relvora")) {
                try await desk.service.create([NewTask(title: "A")], in: archived, destination: .backlog)
            }
            #expect(TaskCreationError.archivedProject("Relvora").recoverySuggestion == "Unarchive it in Relvora first.")
        }
    }
}
