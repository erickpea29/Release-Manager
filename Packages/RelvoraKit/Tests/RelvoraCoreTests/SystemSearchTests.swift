import Foundation
import Testing

@testable import RelvoraCore

@Suite("Shortcuts and Spotlight")
struct SystemSearchTests {
    private let project = Project(name: "Relvora", details: "Release planning")
    private let toDo: BoardColumn
    private let done: BoardColumn
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return calendar
    }
    private let locale = Locale(identifier: "en_US")

    init() {
        toDo = BoardColumn(projectID: project.id, name: "To Do", sortOrder: 1)
        done = BoardColumn(projectID: project.id, name: "Done", sortOrder: 2, isCompletionColumn: true)
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func task(_ title: String, plan: ReleasePlan? = nil, done isDone: Bool = false, order: Double = 1)
        -> ProjectTask
    {
        ProjectTask(
            projectID: project.id, columnID: isDone ? done.id : toDo.id, releasePlanID: plan?.id, title: title,
            labels: ["UI"], sortOrder: order, completedAt: isDone ? .now : nil)
    }

    private func board(_ tasks: [ProjectTask]) -> BoardState {
        BoardState(columns: [done, toDo], tasks: tasks)
    }

    @Test("The next release: the version, its progress, and its planned date")
    func nextReleaseSummary() throws {
        var plan = ReleasePlan(
            projectID: project.id, version: "0.2.4", title: "Spotlight", plannedDate: date(11, 2), createdAt: .now)
        let released = ReleasePlan(projectID: project.id, version: "0.2.3", status: .published, createdAt: .now)
        let tasks = [
            task("A", plan: plan, done: true), task("B", plan: plan), task("C", plan: plan),
            task("Old", plan: released, done: true), task("Later"),
        ]
        let progress = try #require(VersionProgress(plans: [released, plan], board: board(tasks)))
        #expect(progress.plan.id == plan.id && progress.done == 1 && progress.total == 3)
        #expect(
            progress.summary(projectName: "Relvora", now: date(10, 26, 15), calendar: calendar, locale: locale)
                == "The next release of Relvora is 0.2.4 (Spotlight). 1 of 3 tasks are done. "
                + "It’s planned for November 2, 2026.")
        #expect(
            progress.summary(projectName: "Relvora", now: date(11, 2, 18), calendar: calendar, locale: locale)
                .hasSuffix("It’s planned for today."))
        #expect(
            progress.summary(projectName: "Relvora", now: date(11, 3), calendar: calendar, locale: locale)
                .hasSuffix("It was planned for November 2, 2026."))

        plan.title = nil
        plan.plannedDate = nil
        plan.status = .draftCreated
        let drafted = try #require(
            VersionProgress(plans: [plan], board: board([task("A", plan: plan, done: true)])))
        #expect(
            drafted.summary(projectName: "Relvora")
                == "The next release of Relvora is 0.2.4, with a draft on GitHub. Its only task is done.")
        let empty = try #require(VersionProgress(plans: [plan], board: board([])))
        #expect(empty.summary(projectName: "Relvora").hasSuffix("It has no tasks yet."))
        let bothDone = [task("A", plan: plan, done: true), task("B", plan: plan, done: true)]
        let finished = try #require(VersionProgress(plans: [plan], board: board(bothDone)))
        #expect(finished.summary(projectName: "Relvora").hasSuffix("All 2 tasks are done."))

        #expect(VersionProgress(plans: [released], board: board(tasks)) == nil)
        #expect(VersionProgress.nothingPlanned(projectName: "Relvora") == "Relvora has no version being planned.")
    }

    @Test("Spotlight lists active projects with the version's tasks and the Backlog, not past versions' finished work")
    func items() {
        let plan = ReleasePlan(projectID: project.id, version: "0.2.4", createdAt: .now)
        let released = ReleasePlan(projectID: project.id, version: "0.2.3", status: .published, createdAt: .now)
        let state = board([
            task("Shipped", plan: released, done: true), task("Second", plan: plan, order: 2),
            task("First", plan: plan, order: 1), task("Done in version", plan: plan, done: true),
            task("Someday", order: 3), task("Done without version", done: true),
        ])
        let items = SystemSearch.items(project, groupName: "Acme", board: state, plans: [released, plan])
        guard case .project(let searchable)? = items.first else {
            Issue.record("The project comes first")
            return
        }
        #expect(searchable.subtitle == "Acme · Planning 0.2.4" && searchable.details == "Release planning")

        let tasks = SystemSearch.tasks(of: project, board: state, plans: [released, plan])
        #expect(tasks.map(\.title) == ["First", "Second", "Someday", "Done in version"])
        #expect(items.count == 1 + tasks.count)
        #expect(tasks[0].subtitle == "Relvora 0.2.4 · To Do" && tasks[0].isOnBoard)
        #expect(tasks[2].subtitle == "Relvora Backlog · To Do" && !tasks[2].isOnBoard)
        #expect(tasks[3].isDone && tasks[3].subtitle == "Relvora 0.2.4 · Done")

        var archived = project
        archived.archivedAt = .now
        #expect(SystemSearch.items(archived, groupName: nil, board: state, plans: [plan]).isEmpty)
        #expect(SystemSearch.project(project, groupName: nil, plans: [])?.subtitle == "")
    }

    @Test("Spotlight identifiers name a project or a task")
    func identifiers() {
        let id = UUID()
        #expect(SearchableItem.target(of: SearchableItem.identifier(.project(id))) == .project(id))
        #expect(SearchableItem.target(of: "task-\(id.uuidString)") == .task(id))
        #expect(SearchableItem.target(of: "plan-\(id.uuidString)") == nil)
        #expect(SearchableItem.target(of: "task-42") == nil)
        #expect(SearchableItem.target(of: id.uuidString) == nil)
    }

    @Test("Only new and changed items are indexed again, and gone ones are removed")
    func changes() {
        let plan = ReleasePlan(projectID: project.id, version: "0.2.4", createdAt: .now)
        let kept = task("Kept", plan: plan, order: 1)
        var renamed = task("Before", order: 2)
        let removed = task("Deleted", order: 3)
        let before = SystemSearch.items(project, groupName: nil, board: board([kept, renamed, removed]), plans: [plan])
        renamed.title = "After"
        let added = task("New", order: 4)
        let after = SystemSearch.items(project, groupName: nil, board: board([kept, renamed, added]), plans: [plan])

        let indexed = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let changes = SystemSearch.changes(from: indexed, to: after)
        #expect(changes.index.map(\.target) == [.task(renamed.id), .task(added.id)])
        #expect(changes.remove == ["task-\(removed.id.uuidString)"])
        #expect(SystemSearch.changes(from: [:], to: after).index.count == after.count)
    }

    @Test("Tasks are found by title, notes, labels, or project")
    func taskSearch() {
        let searchable = SearchableTask(
            id: UUID(), projectID: project.id, projectName: "Relvora", title: "Fix login", notes: "Sign-in sheet",
            labels: ["auth"], type: .bugFix, priority: .high, column: "To Do", version: nil, isDone: false)
        #expect(searchable.matches("login relvora") && searchable.matches("AUTH") && searchable.matches("sheet"))
        #expect(!searchable.matches("logout"))
    }
}
