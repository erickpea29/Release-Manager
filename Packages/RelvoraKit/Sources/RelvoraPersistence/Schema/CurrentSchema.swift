import SwiftData

/// The schema the app reads and writes. Older versions exist only so migration can open old stores.
typealias CurrentSchema = RelvoraSchemaV2
typealias ProjectEntity = CurrentSchema.ProjectEntity
typealias BoardColumnEntity = CurrentSchema.BoardColumnEntity
typealias TaskEntity = CurrentSchema.TaskEntity
typealias ChecklistItemEntity = CurrentSchema.ChecklistItemEntity
typealias ReleasePlanEntity = CurrentSchema.ReleasePlanEntity
typealias RepositoryConnectionEntity = CurrentSchema.RepositoryConnectionEntity

enum RelvoraMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [RelvoraSchemaV1.self, RelvoraSchemaV2.self] }

    static var stages: [MigrationStage] {
        [
            // V2 only adds an entity and a to-many relationship.
            .lightweight(fromVersion: RelvoraSchemaV1.self, toVersion: RelvoraSchemaV2.self)
        ]
    }
}
