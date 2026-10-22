import Foundation
import SwiftData

/// Plain, Sendable domain value. SwiftData model objects never cross the repository boundary.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var slug: String
    public var createdAt: Date
    public var archivedAt: Date?

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now, archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.slug = Slug.make(from: name)
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }
}

public protocol ProjectRepository: Sendable {
    func allProjects() async throws -> [ProjectSummary]
    func save(_ project: ProjectSummary) async throws
    func delete(id: UUID) async throws
}

public enum SpikeStore {
    public static func makeContainer(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, migrationPlan: SpikeMigrationPlan.self, configurations: [configuration])
    }

    public static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: SpikeMigrationPlan.self, configurations: [configuration])
    }
}

/// Written out by hand instead of `@ModelActor` so the initializer can be public across module boundaries.
public actor SwiftDataProjectRepository: ProjectRepository, ModelActor {
    public nonisolated let modelExecutor: any ModelExecutor
    public nonisolated let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
    }

    public func allProjects() throws -> [ProjectSummary] {
        let descriptor = FetchDescriptor<CurrentSchema.ProjectEntity>(sortBy: [SortDescriptor(\.createdAt)])
        return try modelContext.fetch(descriptor).map(ProjectSummary.init(entity:))
    }

    public func save(_ project: ProjectSummary) throws {
        if let existing = try entity(id: project.id) {
            existing.name = project.name
            existing.slug = project.slug
            existing.archivedAt = project.archivedAt
        } else {
            modelContext.insert(CurrentSchema.ProjectEntity(
                id: project.id,
                name: project.name,
                slug: project.slug,
                createdAt: project.createdAt,
                archivedAt: project.archivedAt
            ))
        }
        try modelContext.save()
    }

    public func delete(id: UUID) throws {
        guard let existing = try entity(id: id) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func entity(id: UUID) throws -> CurrentSchema.ProjectEntity? {
        var descriptor = FetchDescriptor<CurrentSchema.ProjectEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension ProjectSummary {
    init(entity: CurrentSchema.ProjectEntity) {
        self.id = entity.id
        self.name = entity.name
        self.slug = entity.slug
        self.createdAt = entity.createdAt
        self.archivedAt = entity.archivedAt
    }
}
