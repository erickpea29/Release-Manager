import Foundation
import RelvoraCore
import SwiftData
import os

/// The app's local store and the repositories that read and write it.
public struct PersistentStore: Sendable {
    public let projects: any ProjectRepository
    public let groups: any ProjectGroupRepository
    public let board: any BoardRepository
    public let releasePlans: any ReleasePlanRepository
    public let backups: any BackupRepository
    public let repositoryConnections: any RepositoryConnectionRepository
    public let releaseSnapshots: any ReleaseSnapshotRepository
    public let releaseSteps: any ReleaseStepRepository

    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/Relvora/<name>.store` when sandboxed.
    public static func defaultURL(name: String = "Relvora") -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Relvora", directoryHint: .isDirectory)
            .appending(path: "\(name).store")
    }

    public static func open(at url: URL) throws(PersistenceError) -> PersistentStore {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw Self.unavailable(error)
        }
        return try make(ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
    }

    public static func inMemory() throws(PersistenceError) -> PersistentStore {
        try make(ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private static let schema = Schema(versionedSchema: CurrentSchema.self)

    private static func make(_ configuration: ModelConfiguration) throws(PersistenceError) -> PersistentStore {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: RelvoraMigrationPlan.self,
                configurations: [configuration]
            )
        } catch {
            throw Self.unavailable(error)
        }
        // One actor (one ModelContext) for all repositories, so cross-repository work stays serialized.
        let repository = SwiftDataRepository(modelContainer: container)
        return PersistentStore(
            projects: repository, groups: repository, board: repository, releasePlans: repository, backups: repository,
            repositoryConnections: repository, releaseSnapshots: repository, releaseSteps: repository)
    }

    private static func unavailable(_ error: any Error) -> PersistenceError {
        Log.persistence.error("Store unavailable: \(String(describing: error), privacy: .private)")
        return .storeUnavailable(reason: String(describing: error))
    }
}

enum Log {
    static let persistence = Logger(subsystem: "com.erickpea29.Relvora", category: "persistence")
}
