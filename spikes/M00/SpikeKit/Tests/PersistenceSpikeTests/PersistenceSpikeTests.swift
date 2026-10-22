import Foundation
import SwiftData
import Testing
@testable import PersistenceSpike

// Serialized: instantiating an older VersionedSchema while another test uses the current one in the same
// process makes Core Data resolve the shared entity name against the wrong model (NSUnknownKeyException).
@Suite("SwiftData persistence spike", .serialized)
struct PersistenceSpikeTests {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceSpikeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("spike.store")
    }

    @Test("Data written through the repository survives a container restart")
    func survivesRestart() async throws {
        let url = try temporaryStoreURL()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let project = ProjectSummary(name: "Release Manager", createdAt: created)

        do {
            let repository = SwiftDataProjectRepository(modelContainer: try SpikeStore.makeContainer(url: url))
            try await repository.save(project)
        }

        let reopened = SwiftDataProjectRepository(modelContainer: try SpikeStore.makeContainer(url: url))
        let projects = try await reopened.allProjects()
        #expect(projects == [project])
    }

    @Test("Update and delete round-trip through the repository")
    func updateAndDelete() async throws {
        let repository = SwiftDataProjectRepository(modelContainer: try SpikeStore.makeInMemoryContainer())
        var project = ProjectSummary(name: "Alpha")
        try await repository.save(project)

        project.name = "Alpha Renamed"
        project.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.save(project)
        #expect(try await repository.allProjects().map(\.name) == ["Alpha Renamed"])

        try await repository.delete(id: project.id)
        #expect(try await repository.allProjects().isEmpty)
    }

    @Test("An on-disk V1 store migrates through lightweight and custom stages to V3")
    func migratesV1StoreToCurrent() async throws {
        let url = try temporaryStoreURL()
        let id = UUID()

        do {
            let v1Schema = Schema(versionedSchema: SpikeSchemaV1.self)
            let v1Container = try ModelContainer(
                for: v1Schema,
                configurations: [ModelConfiguration(schema: v1Schema, url: url)]
            )
            let context = ModelContext(v1Container)
            context.insert(SpikeSchemaV1.ProjectEntity(id: id, name: "Legacy Project 2", createdAt: .now))
            try context.save()
        }

        let repository = SwiftDataProjectRepository(modelContainer: try SpikeStore.makeContainer(url: url))
        let projects = try await repository.allProjects()

        #expect(projects.count == 1)
        #expect(projects.first?.id == id)
        #expect(projects.first?.archivedAt == nil)
        #expect(projects.first?.slug == "legacy-project-2")
    }
}
