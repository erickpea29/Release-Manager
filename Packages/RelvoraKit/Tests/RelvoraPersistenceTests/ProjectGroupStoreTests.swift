import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

extension StoreTests {
    @Suite("Project groups")
    struct ProjectGroupStoreTests {
        @Test("Create, rename, and reorder groups; names stay unique")
        func lifecycle() async throws {
            let store = try PersistentStore.inMemory()
            let service = ProjectGroupService(repository: store.groups)
            let pilou = try await service.create(name: " Pilou ")
            let relvora = try await service.create(name: "Relvora")
            let acme = try await service.create(name: "Acme")
            #expect(try await service.groups().map(\.name) == ["Pilou", "Relvora", "Acme"])

            await #expect(throws: ValidationError.duplicateGroupName("relvora")) {
                try await service.create(name: "relvora")
            }
            await #expect(throws: ValidationError.duplicateGroupName("Acme")) {
                try await service.rename(pilou, to: "Acme")
            }
            _ = try await service.rename(pilou, to: "Pilou Labs")

            #expect(try await service.move(acme.id, to: 0).map(\.name) == ["Acme", "Pilou Labs", "Relvora"])
            #expect(try await service.move(acme.id, to: 2).map(\.name) == ["Pilou Labs", "Relvora", "Acme"])
            #expect(try await service.move(relvora.id, to: 1).map(\.name) == ["Pilou Labs", "Relvora", "Acme"])
        }

        @Test("Projects join and leave groups; deleting a group keeps its projects")
        func membership() async throws {
            let store = try PersistentStore.inMemory()
            let groups = ProjectGroupService(repository: store.groups)
            let projects = ProjectService(repository: store.projects)
            let pilou = try await groups.create(name: "Pilou")
            let web = try await projects.create(name: "Web", groupID: pilou.id)
            let api = try await projects.create(name: "API")
            _ = try await projects.setGroup(api, pilou.id)
            #expect(try await store.projects.projects(includeArchived: true).map(\.groupID) == [pilou.id, pilou.id])

            _ = try await projects.update(try await store.projects.project(id: web.id), name: "Website", details: nil)
            #expect(try await store.projects.project(id: web.id).groupID == pilou.id)

            try await groups.delete(pilou.id)
            #expect(try await groups.groups().isEmpty)
            let remaining = try await store.projects.projects(includeArchived: true)
            #expect(remaining.map(\.name) == ["Website", "API"])
            #expect(remaining.allSatisfy { $0.groupID == nil })
        }

        @Test("A project can't be put in a group that doesn't exist")
        func missingGroup() async throws {
            let store = try PersistentStore.inMemory()
            let projects = ProjectService(repository: store.projects)
            let missing = UUID()
            await #expect(throws: PersistenceError.notFound(entity: "group", id: missing)) {
                try await projects.create(name: "Web", groupID: missing)
            }
            let api = try await projects.create(name: "API")
            await #expect(throws: PersistenceError.notFound(entity: "group", id: missing)) {
                try await projects.setGroup(api, missing)
            }
            #expect(try await store.projects.project(id: api.id).groupID == nil)
            #expect(try await store.projects.projects(includeArchived: true).count == 1)
        }

        @Test("Backups carry groups and membership; a restore replaces the groups too")
        func backup() async throws {
            let store = try PersistentStore.inMemory()
            let groups = ProjectGroupService(repository: store.groups)
            let pilou = try await groups.create(name: "Pilou")
            let relvora = try await groups.create(name: "Relvora")
            _ = try await groups.move(relvora.id, to: 0)
            let web = try await ProjectService(repository: store.projects).create(name: "Web", groupID: pilou.id)
            _ = try await ProjectService(repository: store.projects).create(name: "Side")
            let document = try await BackupService(repository: store.backups).export(appVersion: nil)
            #expect(document.groups?.map(\.name) == ["Relvora", "Pilou"])

            let other = try PersistentStore.inMemory()
            _ = try await ProjectGroupService(repository: other.groups).create(name: "Old")
            let summary = try await BackupService(repository: other.backups).restore(
                try BackupDocument.decode(try document.encoded()))
            #expect(summary.groupCount == 2 && summary.projectCount == 2)
            // Backups keep milliseconds, so compare everything but the timestamps.
            let restored = try await other.groups.groups()
            let original = try await store.groups.groups()
            #expect(restored.map(\.id) == original.map(\.id) && restored.map(\.name) == ["Relvora", "Pilou"])
            #expect(restored.map(\.sortOrder) == original.map(\.sortOrder))
            #expect(try await other.projects.project(id: web.id).groupID == pilou.id)
            // By name: both projects can share a millisecond, so their order after a restore isn't fixed.
            let membership = try await other.projects.projects(includeArchived: true).map { ($0.name, $0.groupID) }
            #expect(Dictionary(uniqueKeysWithValues: membership) == ["Web": pilou.id, "Side": nil])
        }
    }
}
