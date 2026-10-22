import Foundation
import RelvoraCore
import SwiftData
import Testing

@testable import RelvoraPersistence

/// On-disk SwiftData tests. Serialized: future migration tests instantiate older schemas, which must never run
/// concurrently with the current one in the same process (M00 finding F1).
@Suite("Persistent store", .serialized)
struct PersistentStoreTests {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelvoraPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Relvora.store")
    }

    /// Creates a project with its default board, a release plan, and one task with a checklist.
    private func seed(_ store: PersistentStore) async throws -> (Project, [BoardColumn], ReleasePlan, ProjectTask) {
        let project = try await ProjectService(repository: store.projects).create(
            name: "Relvora", details: "Release planning")
        let columns = try await store.board.columns(projectID: project.id)
        let plan = ReleasePlan(projectID: project.id, version: "1.0.0", title: "First release")
        try await store.releasePlans.save(plan)
        let task = ProjectTask(
            projectID: project.id,
            columnID: columns[1].id,
            releasePlanID: plan.id,
            title: "Kanban board",
            details: "Drag and drop **columns**",
            priority: .high,
            type: .feature,
            labels: ["UI", "board"],
            checklist: [
                ChecklistItem(title: "Columns", isDone: true, sortOrder: 1),
                ChecklistItem(title: "Drag and drop", sortOrder: 2),
            ],
            sortOrder: 1
        )
        try await store.board.save(task)
        return (project, columns, plan, task)
    }

    @Test("Everything written survives reopening the store")
    func survivesRestart() async throws {
        let url = try temporaryStoreURL()
        let (project, columns, plan, task) = try await seed(try PersistentStore.open(at: url))

        let reopened = try PersistentStore.open(at: url)
        #expect(try await reopened.projects.projects(includeArchived: false) == [project])
        #expect(try await reopened.board.columns(projectID: project.id) == columns)
        #expect(try await reopened.board.tasks(projectID: project.id) == [task])
        #expect(try await reopened.releasePlans.plans(projectID: project.id) == [plan])
    }

    @Test("Archived projects are hidden unless requested")
    func archiving() async throws {
        let store = try PersistentStore.inMemory()
        var project = try await ProjectService(repository: store.projects).create(name: "Old")
        project.archivedAt = .now
        try await store.projects.update(project)

        #expect(try await store.projects.projects(includeArchived: false).isEmpty)
        #expect(try await store.projects.projects(includeArchived: true).map(\.isArchived) == [true])
    }

    @Test("Task edits replace the checklist and keep labels normalized")
    func taskUpdates() async throws {
        let store = try PersistentStore.inMemory()
        var (project, columns, _, task) = try await seed(store)

        task.checklist = [ChecklistItem(id: task.checklist[1].id, title: "Drag and drop", isDone: true, sortOrder: 1)]
        task.labels = ["ui", "  Release "]
        task.columnID = columns[4].id
        try await store.board.save(task)

        let saved = try #require(try await store.board.tasks(projectID: project.id).first)
        #expect(saved.checklist.map(\.title) == ["Drag and drop"])
        #expect(saved.checklist.first?.isDone == true)
        #expect(saved.labels == ["ui", "Release"])
        #expect(saved.columnID == columns[4].id)
        project = try await store.projects.project(id: project.id)
        #expect(project.name == "Relvora")
    }

    @Test("A task cannot reference another project's column, and the rejected save leaves nothing behind")
    func crossProjectIntegrity() async throws {
        let store = try PersistentStore.inMemory()
        let (first, _, _, _) = try await seed(store)
        let second = try await ProjectService(repository: store.projects).create(name: "Other")
        let foreignColumn = try #require(try await store.board.columns(projectID: second.id).first)

        let stray = ProjectTask(projectID: first.id, columnID: foreignColumn.id, title: "Stray", sortOrder: 9)
        await #expect(throws: PersistenceError.self) { try await store.board.save(stray) }

        #expect(try await store.board.tasks(projectID: first.id).map(\.title) == ["Kanban board"])
        #expect(try await store.board.tasks(projectID: second.id).isEmpty)
    }

    @Test("Deleting a project removes everything it owns")
    func cascadeDelete() async throws {
        let url = try temporaryStoreURL()
        let store = try PersistentStore.open(at: url)
        let (project, _, _, _) = try await seed(store)
        let survivor = try await ProjectService(repository: store.projects).create(name: "Survivor")

        try await store.projects.deleteProject(id: project.id)

        let context = ModelContext(
            try ModelContainer(
                for: Schema(versionedSchema: RelvoraSchemaV1.self),
                configurations: [ModelConfiguration(url: url, cloudKitDatabase: .none)]
            ))
        #expect(try context.fetchCount(FetchDescriptor<ProjectEntity>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<BoardColumnEntity>()) == ProjectRules.defaultColumnNames.count)
        #expect(try context.fetchCount(FetchDescriptor<TaskEntity>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChecklistItemEntity>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ReleasePlanEntity>()) == 0)
        #expect(try await store.projects.projects(includeArchived: true) == [survivor])
    }

    @Test("Release plans round-trip and delete")
    func releasePlans() async throws {
        let store = try PersistentStore.inMemory()
        let (project, _, plan, _) = try await seed(store)
        var updated = plan
        updated.status = .draftCreated
        updated.targetCommitSHA = String(repeating: "a", count: 40)
        updated.changelogMarkdown = "## Features\n- Board"
        try await store.releasePlans.save(updated)
        #expect(try await store.releasePlans.plans(projectID: project.id) == [updated])

        try await store.releasePlans.deletePlan(id: plan.id)
        #expect(try await store.releasePlans.plans(projectID: project.id).isEmpty)
        // The task that referenced the plan survives, unlinked.
        #expect(try await store.board.tasks(projectID: project.id).first?.releasePlanID == nil)
    }

    @Test("Missing records surface as notFound")
    func notFound() async throws {
        let store = try PersistentStore.inMemory()
        let id = UUID()
        await #expect(throws: PersistenceError.notFound(entity: "project", id: id)) {
            try await store.projects.project(id: id)
        }
        await #expect(throws: PersistenceError.notFound(entity: "task", id: id)) {
            try await store.board.deleteTask(id: id)
        }
    }
}
