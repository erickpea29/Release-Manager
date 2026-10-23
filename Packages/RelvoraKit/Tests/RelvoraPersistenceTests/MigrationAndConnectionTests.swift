import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

extension StoreTests {
    @Suite("Schema migration")
    struct MigrationTests {
        /// `RelvoraV1.store` was written by the M02 code from `backup-v1.json`, then frozen.
        @Test("A V1 store migrates to the current schema with every record intact")
        func v1ToCurrent() async throws {
            let fixture = try #require(
                Bundle.module.url(forResource: "RelvoraV1", withExtension: "store", subdirectory: "Fixtures"))
            let directory = FileManager.default.temporaryDirectory.appending(path: "Migration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appending(path: "Relvora.store")
            try FileManager.default.copyItem(at: fixture, to: copy)  // never migrate the committed file in place

            let store = try PersistentStore.open(at: copy)
            let migrated = try await BackupService(repository: store.backups).export(appVersion: nil)
            let expectedURL = try #require(
                Bundle.module.url(forResource: "backup-v1", withExtension: "json", subdirectory: "Fixtures"))
            let expected = try BackupService.inspect(try Data(contentsOf: expectedURL)).document
            #expect(migrated.projects == expected.projects)

            // New V2 capability works on migrated data and survives reopening.
            let relvora = try #require(migrated.projects.first { $0.name == "Relvora" })
            let remote = GitHubRepository(
                id: 1_429_211_413, owner: "erickpea29", name: "Release-Manager", defaultBranch: "main",
                htmlURL: URL(string: "https://github.com/erickpea29/Release-Manager")!, isPrivate: true)
            _ = try await RepositoryConnectionService(repository: store.repositoryConnections).connect(
                remote, to: relvora.id)
            let reopened = try PersistentStore.open(at: copy)
            #expect(
                try await reopened.repositoryConnections.connections(projectID: relvora.id).map(\.fullName)
                    == ["erickpea29/Release-Manager"])
        }

        /// `RelvoraV3.store` was written by the 0.1.0 code (schema V3) from `backup-v2.json`, then frozen.
        @Test("A V3 store from 0.1.0 migrates with every record intact, and its projects can join groups")
        func v3ToCurrent() async throws {
            let fixture = try #require(
                Bundle.module.url(forResource: "RelvoraV3", withExtension: "store", subdirectory: "Fixtures"))
            let directory = FileManager.default.temporaryDirectory.appending(path: "Migration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appending(path: "Relvora.store")
            try FileManager.default.copyItem(at: fixture, to: copy)

            let store = try PersistentStore.open(at: copy)
            let migrated = try await BackupService(repository: store.backups).export(appVersion: nil)
            let expectedURL = try #require(
                Bundle.module.url(forResource: "backup-v2", withExtension: "json", subdirectory: "Fixtures"))
            let expected = try BackupService.inspect(try Data(contentsOf: expectedURL)).document
            #expect(migrated.projects == expected.projects)
            #expect(migrated.groups == [])
            #expect(migrated.projects.allSatisfy { $0.groupID == nil })

            let group = try await ProjectGroupService(repository: store.groups).create(name: "Erick")
            let project = try #require(try await store.projects.projects(includeArchived: true).first)
            _ = try await ProjectService(repository: store.projects).setGroup(project, group.id)
            let reopened = try PersistentStore.open(at: copy)
            #expect(try await reopened.groups.groups() == [group])
            #expect(try await reopened.projects.project(id: project.id).groupID == group.id)
        }
    }

    @Suite("Repository connections")
    struct RepositoryConnectionTests {
        private let remote = GitHubRepository(
            id: 42, owner: "octo", name: "app", defaultBranch: "main",
            htmlURL: URL(string: "https://github.com/octo/app")!, isPrivate: false)

        @Test("Connect, sync metadata after a rename, and disconnect")
        func lifecycle() async throws {
            let store = try PersistentStore.inMemory()
            let project = try await ProjectService(repository: store.projects).create(name: "App")
            let service = RepositoryConnectionService(repository: store.repositoryConnections)

            let connection = try await service.connect(remote, to: project.id)
            await #expect(throws: ValidationError.repositoryAlreadyConnected("octo/app")) {
                try await service.connect(remote, to: project.id)
            }

            let renamed = GitHubRepository(
                id: 42, owner: "new-owner", name: "renamed", defaultBranch: "trunk",
                htmlURL: URL(string: "https://github.com/new-owner/renamed")!, isPrivate: true)
            let synced = Date(timeIntervalSince1970: 1_800_000_000)
            _ = try await service.recordSync(connection, remote: renamed, at: synced)
            let stored = try #require(try await service.connections(projectID: project.id).first)
            #expect(stored.fullName == "new-owner/renamed")
            #expect(stored.githubRepositoryID == 42 && stored.defaultBranch == "trunk" && stored.isPrivate)
            #expect(stored.lastSyncedAt == synced)

            try await service.disconnect(stored)
            #expect(try await service.connections(projectID: project.id).isEmpty)
        }

        @Test("The store rejects a second connection to the same repository")
        func storeUniqueness() async throws {
            let store = try PersistentStore.inMemory()
            let project = try await ProjectService(repository: store.projects).create(name: "App")
            let first = RepositoryConnection(
                projectID: project.id, githubRepositoryID: 42, owner: "octo", name: "app", defaultBranch: nil,
                htmlURL: remote.htmlURL, isPrivate: false)
            try await store.repositoryConnections.save(first)
            var second = first
            second = RepositoryConnection(
                projectID: project.id, githubRepositoryID: 42, owner: "octo", name: "app", defaultBranch: nil,
                htmlURL: remote.htmlURL, isPrivate: false)
            await #expect(throws: PersistenceError.self) { try await store.repositoryConnections.save(second) }
        }

        @Test("Connections are deleted with their project and included in backups")
        func cascadeAndBackup() async throws {
            let store = try PersistentStore.inMemory()
            let projects = ProjectService(repository: store.projects)
            let keep = try await projects.create(name: "Keep")
            let drop = try await projects.create(name: "Drop")
            let service = RepositoryConnectionService(repository: store.repositoryConnections)
            _ = try await service.connect(remote, to: keep.id)
            _ = try await service.connect(remote, to: drop.id)  // the same repository may serve two projects

            try await projects.delete(drop.id)
            let backups = BackupService(repository: store.backups)
            let document = try await backups.export(appVersion: nil)
            #expect(document.projects.map(\.repositoryConnections.count) == [1])

            let restoredStore = try PersistentStore.inMemory()
            try await BackupService(repository: restoredStore.backups).restore(document)
            #expect(
                try await restoredStore.repositoryConnections.connections(projectID: keep.id).map(\.githubRepositoryID)
                    == [42])
        }
    }
}
