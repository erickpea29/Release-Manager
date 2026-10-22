import Foundation
import SwiftData

// Validates: versioned schemas, a lightweight stage (V1 -> V2) and a custom stage (V2 -> V3)
// against an on-disk store, which is the migration strategy proposed for M01.

public enum SpikeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [ProjectEntity.self] }

    @Model
    public final class ProjectEntity {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var createdAt: Date

        public init(id: UUID, name: String, createdAt: Date) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
        }
    }
}

/// Adds an optional field: expected to migrate without custom code.
public enum SpikeSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] { [ProjectEntity.self] }

    @Model
    public final class ProjectEntity {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var createdAt: Date
        public var archivedAt: Date?

        public init(id: UUID, name: String, createdAt: Date, archivedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.archivedAt = archivedAt
        }
    }
}

/// Adds a derived, non-optional field that must be backfilled by a custom stage.
public enum SpikeSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    public static var models: [any PersistentModel.Type] { [ProjectEntity.self] }

    @Model
    public final class ProjectEntity {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var slug: String = ""
        public var createdAt: Date
        public var archivedAt: Date?

        public init(id: UUID, name: String, slug: String, createdAt: Date, archivedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.slug = slug
            self.createdAt = createdAt
            self.archivedAt = archivedAt
        }
    }
}

public typealias CurrentSchema = SpikeSchemaV3

public enum SpikeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SpikeSchemaV1.self, SpikeSchemaV2.self, SpikeSchemaV3.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SpikeSchemaV1.self, toVersion: SpikeSchemaV2.self),
            .custom(
                fromVersion: SpikeSchemaV2.self,
                toVersion: SpikeSchemaV3.self,
                willMigrate: nil,
                didMigrate: { context in
                    let projects = try context.fetch(FetchDescriptor<SpikeSchemaV3.ProjectEntity>())
                    for project in projects where project.slug.isEmpty {
                        project.slug = Slug.make(from: project.name)
                    }
                    try context.save()
                }
            ),
        ]
    }
}

public enum Slug {
    public static func make(from name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
