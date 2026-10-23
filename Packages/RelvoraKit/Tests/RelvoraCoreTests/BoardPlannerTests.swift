import Foundation
import Testing

@testable import RelvoraCore

/// A small board: Backlog, Doing, Done (completion). Tasks a, b, c in Backlog; d in Done.
private struct Fixture {
    let projectID = UUID()
    let backlog: BoardColumn
    let doing: BoardColumn
    let done: BoardColumn
    let a: ProjectTask
    let b: ProjectTask
    let c: ProjectTask
    let d: ProjectTask
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        backlog = BoardColumn(projectID: projectID, name: "Backlog", sortOrder: 1)
        doing = BoardColumn(projectID: projectID, name: "Doing", sortOrder: 2)
        done = BoardColumn(projectID: projectID, name: "Done", sortOrder: 3, isCompletionColumn: true)
        a = ProjectTask(projectID: projectID, columnID: backlog.id, title: "a", sortOrder: 1)
        b = ProjectTask(projectID: projectID, columnID: backlog.id, title: "b", sortOrder: 2)
        c = ProjectTask(projectID: projectID, columnID: backlog.id, title: "c", sortOrder: 3)
        d = ProjectTask(projectID: projectID, columnID: done.id, title: "d", sortOrder: 1, completedAt: earlier)
    }

    var state: BoardState { BoardState(columns: [done, backlog, doing], tasks: [c, a, d, b]) }

    func applying(_ changes: BoardChanges, to state: BoardState? = nil) -> BoardState {
        var result = state ?? self.state
        for task in changes.upsertTasks {
            result.tasks.removeAll { $0.id == task.id }
            result.tasks.append(task)
        }
        for column in changes.upsertColumns {
            result.columns.removeAll { $0.id == column.id }
            result.columns.append(column)
        }
        result.tasks.removeAll { changes.deleteTaskIDs.contains($0.id) }
        result.columns.removeAll { changes.deleteColumnIDs.contains($0.id) }
        return result
    }
}

@Suite("Board planner: tasks")
struct BoardPlannerTaskTests {
    @Test("Moving within a column changes only the moved task")
    func withinColumn() throws {
        let f = Fixture()
        let changes = try BoardPlanner.moveTask(f.c.id, toColumn: f.backlog.id, before: f.a.id, in: f.state, now: f.now)
        #expect(changes.upsertTasks.map(\.id) == [f.c.id])
        #expect(f.applying(changes).tasks(in: f.backlog.id).map(\.title) == ["c", "a", "b"])

        let toEnd = try BoardPlanner.moveTask(f.a.id, toColumn: f.backlog.id, before: nil, in: f.state, now: f.now)
        #expect(f.applying(toEnd).tasks(in: f.backlog.id).map(\.title) == ["b", "c", "a"])
    }

    @Test("Dropping a task where it already is changes nothing")
    func noOps() throws {
        let f = Fixture()
        #expect(
            try BoardPlanner.moveTask(f.a.id, toColumn: f.backlog.id, before: f.a.id, in: f.state, now: f.now).isEmpty)
        #expect(
            try BoardPlanner.moveTask(f.a.id, toColumn: f.backlog.id, before: f.b.id, in: f.state, now: f.now).isEmpty)
        #expect(try BoardPlanner.moveTask(f.c.id, toColumn: f.backlog.id, before: nil, in: f.state, now: f.now).isEmpty)
    }

    @Test("Entering the completion column completes a task; leaving it reopens the task")
    func completion() throws {
        let f = Fixture()
        let finished = f.applying(
            try BoardPlanner.moveTask(f.b.id, toColumn: f.done.id, before: f.d.id, in: f.state, now: f.now))
        let b = try #require(finished.task(f.b.id))
        #expect(b.completedAt == f.now)
        #expect(b.updatedAt == f.now)
        #expect(finished.tasks(in: f.done.id).map(\.title) == ["b", "d"])

        let reopened = f.applying(
            try BoardPlanner.moveTask(f.d.id, toColumn: f.doing.id, before: nil, in: finished, now: f.now), to: finished
        )
        #expect(reopened.task(f.d.id)?.completedAt == nil)

        // Reordering inside the completion column keeps the original completion date.
        let reordered = f.applying(
            try BoardPlanner.moveTask(f.d.id, toColumn: f.done.id, before: f.b.id, in: finished, now: f.now),
            to: finished)
        #expect(reordered.task(f.d.id)?.completedAt == f.earlier)
    }

    @Test("Exhausted gaps renumber the target column and keep the requested order")
    func renormalization() throws {
        let f = Fixture()
        var crowded = f.state
        crowded.tasks = crowded.tasks.map { task in
            var copy = task
            if task.id == f.a.id { copy.sortOrder = 1 }
            if task.id == f.b.id { copy.sortOrder = 1 + 1e-10 }
            return copy
        }
        let changes = try BoardPlanner.moveTask(f.c.id, toColumn: f.backlog.id, before: f.b.id, in: crowded, now: f.now)
        let result = f.applying(changes, to: crowded)
        #expect(result.tasks(in: f.backlog.id).map(\.title) == ["a", "c", "b"])
        #expect(result.tasks(in: f.backlog.id).map(\.sortOrder) == [1, 2, 3])
        // `a` already had key 1, so only the moved task and `b` are written.
        #expect(changes.upsertTasks.map(\.title).sorted() == ["b", "c"])
    }

    @Test("Unknown columns and tasks are rejected")
    func unknown() {
        let f = Fixture()
        #expect(throws: ValidationError.unknownColumn) {
            try BoardPlanner.moveTask(f.a.id, toColumn: UUID(), before: nil, in: f.state, now: f.now)
        }
        #expect(throws: ValidationError.unknownColumn) {
            try BoardPlanner.moveTask(UUID(), toColumn: f.done.id, before: nil, in: f.state, now: f.now)
        }
    }

    @Test("Editor updates are normalized; a column change appends to the new column")
    func editorUpdate() throws {
        let f = Fixture()
        var edited = f.a
        edited.title = "  Renamed  "
        edited.details = "   "
        edited.labels = [" UI", "ui", "Board "]
        edited.checklist = [
            ChecklistItem(title: " First ", sortOrder: 7), ChecklistItem(title: "  ", sortOrder: 8),
            ChecklistItem(title: "Second", sortOrder: 3),
        ]
        let sameColumn = try BoardPlanner.update(edited, original: f.a, in: f.state, now: f.now)
        #expect(sameColumn.title == "Renamed")
        #expect(sameColumn.details == nil)
        #expect(sameColumn.labels == ["UI", "Board"])
        #expect(sameColumn.checklist.map(\.title) == ["First", "Second"])
        #expect(sameColumn.checklist.map(\.sortOrder) == [1, 2])
        #expect(sameColumn.sortOrder == f.a.sortOrder)
        #expect(sameColumn.updatedAt == f.now)

        edited.columnID = f.done.id
        let moved = try BoardPlanner.update(edited, original: f.a, in: f.state, now: f.now)
        #expect(moved.sortOrder > f.d.sortOrder)
        #expect(moved.completedAt == f.now)

        edited.title = " "
        #expect(throws: ValidationError.emptyTitle) {
            try BoardPlanner.update(edited, original: f.a, in: f.state, now: f.now)
        }
    }
}

@Suite("Board planner: columns")
struct BoardPlannerColumnTests {
    @Test("New columns go before a trailing completion column, otherwise at the end")
    func addColumn() throws {
        let f = Fixture()
        let (qa, changes) = try BoardPlanner.addColumn(named: " QA ", projectID: f.projectID, in: f.state, now: f.now)
        #expect(qa.name == "QA")
        #expect(f.applying(changes).orderedColumns.map(\.name) == ["Backlog", "Doing", "QA", "Done"])

        var doneFirst = f.state
        doneFirst.columns = [
            BoardColumn(id: f.done.id, projectID: f.projectID, name: "Done", sortOrder: 0, isCompletionColumn: true),
            f.backlog, f.doing,
        ]
        let (later, laterChanges) = try BoardPlanner.addColumn(
            named: "Later", projectID: f.projectID, in: doneFirst, now: f.now)
        #expect(f.applying(laterChanges, to: doneFirst).orderedColumns.last?.id == later.id)

        #expect(throws: ValidationError.emptyName) {
            try BoardPlanner.addColumn(named: "  ", projectID: f.projectID, in: f.state, now: f.now)
        }
    }

    @Test("Moving a column renumbers the board; moving to the same place changes nothing")
    func moveColumn() throws {
        let f = Fixture()
        let changes = try BoardPlanner.moveColumn(f.done.id, toIndex: 0, in: f.state)
        #expect(f.applying(changes).orderedColumns.map(\.name) == ["Done", "Backlog", "Doing"])
        #expect(try BoardPlanner.moveColumn(f.doing.id, toIndex: 1, in: f.state).isEmpty)
    }

    @Test("Changing the completion column updates every affected task")
    func completionColumn() throws {
        let f = Fixture()
        let result = f.applying(try BoardPlanner.makeCompletionColumn(f.backlog.id, in: f.state, now: f.now))
        #expect(result.columns.filter(\.isCompletionColumn).map(\.id) == [f.backlog.id])
        #expect(result.tasks(in: f.backlog.id).allSatisfy { $0.completedAt == f.now })
        #expect(result.task(f.d.id)?.completedAt == nil)
        #expect(try BoardPlanner.makeCompletionColumn(f.backlog.id, in: result, now: f.now).isEmpty)
    }

    @Test("Deleting columns enforces the board rules")
    func deleteColumn() throws {
        let f = Fixture()
        #expect(throws: ValidationError.cannotDeleteCompletionColumn) {
            try BoardPlanner.deleteColumn(f.done.id, movingTasksTo: nil, in: f.state, now: f.now)
        }
        #expect(throws: ValidationError.columnNotEmpty(taskCount: 3)) {
            try BoardPlanner.deleteColumn(f.backlog.id, movingTasksTo: nil, in: f.state, now: f.now)
        }
        #expect(
            try BoardPlanner.deleteColumn(f.doing.id, movingTasksTo: nil, in: f.state, now: f.now)
                == BoardChanges(deleteColumnIDs: [f.doing.id]))

        let changes = try BoardPlanner.deleteColumn(f.backlog.id, movingTasksTo: f.done.id, in: f.state, now: f.now)
        let result = f.applying(changes)
        #expect(result.tasks(in: f.done.id).map(\.title) == ["d", "a", "b", "c"])
        #expect(result.tasks(in: f.done.id).allSatisfy { $0.completedAt != nil })
        #expect(result.column(f.backlog.id) == nil)

        let lonely = BoardState(columns: [f.done], tasks: [])
        #expect(throws: ValidationError.cannotDeleteCompletionColumn) {
            try BoardPlanner.deleteColumn(f.done.id, movingTasksTo: nil, in: lonely, now: f.now)
        }
    }
}

@Suite("Board planner: the old Backlog column")
struct BacklogColumnTests {
    @Test("Its tasks move to To Do, in order and keeping their version, and the column goes")
    func retire() throws {
        let f = Fixture()
        let toDo = BoardColumn(projectID: f.projectID, name: "To Do", sortOrder: 1.5)
        let plan = UUID()
        var a = f.a
        a.releasePlanID = plan
        let e = ProjectTask(projectID: f.projectID, columnID: toDo.id, title: "e", sortOrder: 1)
        let state = BoardState(columns: [f.done, f.backlog, f.doing, toDo], tasks: [f.c, a, f.d, f.b, e])

        let changes = try #require(BoardPlanner.retireBacklogColumns(in: state, now: f.now))
        let board = f.applying(changes, to: state)
        #expect(board.orderedColumns.map(\.name) == ["To Do", "Doing", "Done"])
        #expect(board.tasks(in: toDo.id).map(\.title) == ["e", "a", "b", "c"])
        #expect(board.task(a.id)?.releasePlanID == plan)
        #expect(BoardPlanner.retireBacklogColumns(in: board, now: f.now) == nil)
    }

    @Test("A board without a To Do column renames it To Do, so its tasks stay not started")
    func rename() throws {
        let f = Fixture()
        let changes = try #require(BoardPlanner.retireBacklogColumns(in: f.state, now: f.now))
        let board = f.applying(changes)
        #expect(board.orderedColumns.map(\.name) == ["To Do", "Doing", "Done"])
        #expect(board.tasks(in: f.backlog.id).map(\.title) == ["a", "b", "c"])
        #expect(board.tasks(in: f.doing.id).isEmpty)
    }

    @Test("“Backlog” can’t name a new or renamed column, or one in the template for new projects")
    func reservedName() {
        let f = Fixture()
        let board = BoardState(columns: [f.doing, f.done], tasks: [])
        #expect(throws: ValidationError.reservedColumnName("backlog")) {
            try BoardPlanner.addColumn(named: " backlog ", projectID: f.projectID, in: board, now: f.now)
        }
        #expect(throws: ValidationError.reservedColumnName("Backlog")) {
            try BoardPlanner.renameColumn(f.doing.id, to: "Backlog", in: board, now: f.now)
        }
        let old = [
            ColumnTemplate(name: "Backlog", isCompletion: false), ColumnTemplate(name: "Doing", isCompletion: false),
            ColumnTemplate(name: "Done", isCompletion: true),
        ]
        #expect(throws: ValidationError.reservedColumnName("Backlog")) { try ProjectRules.validatedTemplate(old) }
        #expect(ProjectRules.withoutBacklog(old).map(\.name) == ["Doing", "Done"])
    }
}
