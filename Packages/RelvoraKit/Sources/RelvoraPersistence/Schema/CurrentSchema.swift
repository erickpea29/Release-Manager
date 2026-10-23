import SwiftData

/// The schema the app reads and writes. Older versions exist only so migration can open old stores.
typealias CurrentSchema = RelvoraSchemaV4
typealias ProjectEntity = CurrentSchema.ProjectEntity
typealias BoardColumnEntity = CurrentSchema.BoardColumnEntity
typealias TaskEntity = CurrentSchema.TaskEntity
typealias ChecklistItemEntity = CurrentSchema.ChecklistItemEntity
typealias ReleasePlanEntity = CurrentSchema.ReleasePlanEntity
typealias RepositoryConnectionEntity = CurrentSchema.RepositoryConnectionEntity
typealias ReleaseSnapshotEntity = CurrentSchema.ReleaseSnapshotEntity
typealias ProjectGroupEntity = CurrentSchema.ProjectGroupEntity

enum RelvoraMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [RelvoraSchemaV1.self, RelvoraSchemaV2.self, RelvoraSchemaV3.self, RelvoraSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            // V2 only adds an entity and a to-many relationship.
            .lightweight(fromVersion: RelvoraSchemaV1.self, toVersion: RelvoraSchemaV2.self),
            // V3 adds an entity, a to-many relationship, and optional plan attributes.
            .lightweight(fromVersion: RelvoraSchemaV2.self, toVersion: RelvoraSchemaV3.self),
            // V4 adds an entity and an optional to-one relationship (a project's group).
            .lightweight(fromVersion: RelvoraSchemaV3.self, toVersion: RelvoraSchemaV4.self),
        ]
    }
}
