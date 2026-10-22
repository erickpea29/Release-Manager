import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

extension StoreTests {
    /// Writes a store file for the *current* schema, filled from the representative backup fixture.
    /// Run only when freezing a schema version, before changing it:
    ///
    ///     RELVORA_FIXTURE_OUTPUT=/tmp/RelvoraVn.store swift test --filter FixtureGenerator
    ///
    /// Then checkpoint the WAL into the main file (`sqlite3 <file> "PRAGMA wal_checkpoint(TRUNCATE);"`) and commit
    /// it to `Fixtures/` as `RelvoraV<n>.store`.
    @Suite("Fixture generator")
    struct FixtureGenerator {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["RELVORA_FIXTURE_OUTPUT"] != nil))
        func writeCurrentSchemaFixture() async throws {
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RELVORA_FIXTURE_OUTPUT"]!)
            let url = try #require(
                Bundle.module.url(forResource: "backup-v1", withExtension: "json", subdirectory: "Fixtures"))
            let document = try BackupService.inspect(try Data(contentsOf: url)).document
            let store = try PersistentStore.open(at: output)
            try await BackupService(repository: store.backups).restore(document)
            #expect(try await store.projects.projects(includeArchived: true).count == 2)
        }
    }
}
