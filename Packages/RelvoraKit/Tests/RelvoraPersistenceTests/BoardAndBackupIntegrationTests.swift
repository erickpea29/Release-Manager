import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

private func temporaryStoreURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RelvoraIntegrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("Relvora.store")
}

private func fixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "backup-v1", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Integration tests: services from RelvoraCore against real SwiftData stores.
@Suite("Board integration", .serialized)
struct BoardIntegrationTests {
    @Test("Task order and column changes persist across reopening the store")
    func orderSurvivesRestart() async throws {
        let url = try temporaryStoreURL()
        var projectID = UUID()
        var expected: [String: [String]] = [:]
        do {
            let store = try PersistentStore.open(at: url)
            let project = try await ProjectService(repository: store.projects).create(name: "Relvora")
            projectID = project.id
            let board = BoardService(repository: store.board)
            var state = try await board.load(projectID: projectID)
            let backlog = state.orderedColumns[0]
            for title in ["One", "Two", "Three", "Four"] {
                state = try await board.createTask(projectID: projectID, columnID: backlog.id, title: title)
            }
            let ids = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.title, $0.id) })
            state = try await board.moveTask(
                ids["Four"]!, projectID: projectID, toColumn: backlog.id, before: ids["One"])
            let done = try #require(state.orderedColumns.last)
            state = try await board.moveTask(ids["Two"]!, projectID: projectID, toColumn: done.id, before: nil)
            state = try await board.addColumn(named: "QA", projectID: projectID)
            expected = Dictionary(
                uniqueKeysWithValues: state.orderedColumns.map { column in
                    (column.name, state.tasks(in: column.id).map(\.title))
                })
            #expect(expected["Backlog"] == ["Four", "One", "Three"])
            #expect(state.orderedColumns.map(\.name) == ["Backlog", "To Do", "In Progress", "Review", "QA", "Done"])
            #expect(state.task(ids["Two"]!)?.completedAt != nil)
        }

        let reopened = try await BoardService(repository: PersistentStore.open(at: url).board).load(
            projectID: projectID)
        let restored = Dictionary(
            uniqueKeysWithValues: reopened.orderedColumns.map { column in
                (column.name, reopened.tasks(in: column.id).map(\.title))
            })
        #expect(restored == expected)
    }

    @Test("A batch with one invalid change applies nothing")
    func atomicBatches() async throws {
        let store = try PersistentStore.inMemory()
        let project = try await ProjectService(repository: store.projects).create(name: "A")
        let other = try await ProjectService(repository: store.projects).create(name: "B")
        let columns = try await store.board.columns(projectID: project.id)
        let foreign = try await store.board.columns(projectID: other.id)[0]

        let good = ProjectTask(projectID: project.id, columnID: columns[0].id, title: "Good", sortOrder: 1)
        let bad = ProjectTask(projectID: project.id, columnID: foreign.id, title: "Bad", sortOrder: 2)
        var renamed = columns[0]
        renamed.name = "Renamed"
        await #expect(throws: PersistenceError.self) {
            try await store.board.apply(BoardChanges(upsertColumns: [renamed], upsertTasks: [good, bad]))
        }
        #expect(try await store.board.tasks(projectID: project.id).isEmpty)
        #expect(try await store.board.columns(projectID: project.id)[0].name == "Backlog")
    }

    @Test("The store refuses to delete non-empty columns or break the completion-column rule")
    func storeIntegrity() async throws {
        let store = try PersistentStore.inMemory()
        let project = try await ProjectService(repository: store.projects).create(name: "A")
        let board = BoardService(repository: store.board)
        var state = try await board.load(projectID: project.id)
        let backlog = state.orderedColumns[0]
        state = try await board.createTask(projectID: project.id, columnID: backlog.id, title: "Task")

        // Bypassing BoardPlanner: the repository still guards the invariants.
        await #expect(throws: PersistenceError.self) {
            try await store.board.apply(BoardChanges(deleteColumnIDs: [backlog.id]))
        }
        var secondDone = backlog
        secondDone.isCompletionColumn = true
        await #expect(throws: PersistenceError.self) { try await store.board.save(secondDone) }
        let done = try #require(state.orderedColumns.last)
        await #expect(throws: PersistenceError.self) {
            try await store.board.apply(BoardChanges(deleteColumnIDs: [done.id]))
        }

        // Through the service: tasks move first, then the column goes, in one transaction.
        let review = state.orderedColumns[3]
        state = try await board.deleteColumn(backlog.id, movingTasksTo: review.id, projectID: project.id)
        #expect(state.column(backlog.id) == nil)
        #expect(state.tasks(in: review.id).map(\.title) == ["Task"])
        await #expect(throws: ValidationError.cannotDeleteCompletionColumn) {
            try await board.deleteColumn(done.id, movingTasksTo: nil, projectID: project.id)
        }
    }

    @Test("Release plans: one active plan, cancel, and delete without losing tasks")
    func releasePlans() async throws {
        let store = try PersistentStore.inMemory()
        let project = try await ProjectService(repository: store.projects).create(name: "A")
        let plans = ReleasePlanService(repository: store.releasePlans)
        let board = BoardService(repository: store.board)

        let first = try await plans.create(projectID: project.id, version: "1.0.0", title: "Launch")
        await #expect(throws: ValidationError.activeReleasePlanExists(version: "1.0.0")) {
            try await plans.create(projectID: project.id, version: "1.1.0")
        }
        let column = try await board.load(projectID: project.id).orderedColumns[0]
        _ = try await board.createTask(
            projectID: project.id, columnID: column.id, title: "Linked", releasePlanID: first.id)

        var edited = first
        edited.version = "1.0.1"
        #expect(try await plans.update(edited).version == "1.0.1")

        let cancelled = try await plans.cancel(try await plans.plans(projectID: project.id)[0])
        await #expect(throws: ValidationError.releasePlanLocked(.cancelled)) { try await plans.update(cancelled) }
        _ = try await plans.create(projectID: project.id, version: "1.1.0")

        try await plans.delete(cancelled)
        #expect(try await plans.plans(projectID: project.id).map(\.version) == ["1.1.0"])
        let task = try #require(try await board.load(projectID: project.id).tasks.first)
        #expect(task.title == "Linked" && task.releasePlanID == nil)
    }
}

@Suite("Backup integration", .serialized)
struct BackupIntegrationTests {
    @Test("A representative backup restores exactly and exports back to the same content")
    func fixtureRoundTrip() async throws {
        let (document, summary) = try BackupService.inspect(try fixtureData())
        #expect(summary.projectCount == 2 && summary.taskCount == 5 && summary.releasePlanCount == 3)

        let store = try PersistentStore.open(at: try temporaryStoreURL())
        let service = BackupService(repository: store.backups)
        #expect(try await service.restore(document) == summary)

        let exported = try await service.export(appVersion: "test")
        #expect(exported.projects == document.projects)

        // Restored data is usable through the normal services.
        let relvora = try #require(
            try await store.projects.projects(includeArchived: true).first { $0.name == "Relvora" })
        let board = try await BoardService(repository: store.board).load(projectID: relvora.id)
        #expect(board.orderedColumns.map(\.name) == ["Backlog", "Doing", "QA", "Done"])
        #expect(board.task(UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)?.checklist.count == 2)
        #expect(try await store.projects.projects(includeArchived: false).map(\.name) == ["Relvora"])
    }

    @Test("Restoring replaces current data, including records with the same IDs")
    func replaceInPlace() async throws {
        let store = try PersistentStore.inMemory()
        let service = BackupService(repository: store.backups)
        try await service.restore(try BackupService.inspect(try fixtureData()).document)
        let snapshot = try await service.export(appVersion: nil)

        // Change things after the backup was taken.
        let extra = try await ProjectService(repository: store.projects).create(name: "Added later")
        let relvora = try #require(
            try await store.projects.projects(includeArchived: false).first { $0.name == "Relvora" })
        _ = try await ProjectService(repository: store.projects).update(relvora, name: "Renamed", details: nil)

        try await service.restore(snapshot)
        let names = try await store.projects.projects(includeArchived: true).map(\.name)
        #expect(Set(names) == ["Relvora", "Website Redesign"])
        #expect(!names.contains(extra.name))
        #expect(try await service.export(appVersion: nil).projects == snapshot.projects)
    }

    @Test("An invalid backup changes nothing")
    func invalidLeavesDataIntact() async throws {
        let store = try PersistentStore.inMemory()
        let service = BackupService(repository: store.backups)
        _ = try await ProjectService(repository: store.projects).create(name: "Keep me")

        var broken = try BackupService.inspect(try fixtureData()).document
        broken.projects[1].tasks[0].columnID = broken.projects[0].columns[0].id
        await #expect(throws: BackupError.self) { try await service.restore(broken) }
        #expect(try await store.projects.projects(includeArchived: true).map(\.name) == ["Keep me"])
    }
}
