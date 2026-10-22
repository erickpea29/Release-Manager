# 0001 — SwiftData behind repository protocols

- **Status:** Accepted (validated in M00)
- **Date:** 2026-10-19

## Context

The plan prefers SwiftData for a small dependency footprint, but wants persistence isolated so it can move to SQLite/GRDB if needed. Swift 6 strict concurrency makes `@Model` objects (non-`Sendable`) unsafe to pass around.

## Decision

- `@Model` classes live only inside the persistence module, nested in `VersionedSchema` enums from day one (`SchemaV1.ProjectEntity`, …).
- Repositories are `Sendable` protocols returning plain `Sendable` structs. SwiftData implementations are actors conforming to `ModelActor`, written out by hand so initializers can be `public`.
- Every schema change ships a new `VersionedSchema` and a `MigrationStage` in one `SchemaMigrationPlan`, even when the change is lightweight.
- `schemas`/`stages` are computed properties (`MigrationStage` is not `Sendable`).

## Consequences

- Mapping code between entities and domain structs (accepted cost).
- Migration tests must use a `.serialized` suite. Instantiating an old schema concurrently with the current one in one process crashes (M00 F1). Prefer committed fixture stores per schema version.
- Switching to GRDB later would replace only the repository implementations.

## Evidence

`spikes/M00/SpikeKit/Tests/PersistenceSpikeTests`: restart survival, CRUD, and V1→V2 (lightweight) → V3 (custom) migration on disk; sandboxed app relaunch test. See the [M00 report](../M00_TECHNICAL_VALIDATION.md#21-minimal-swiftui-app-with-local-persistence-pass).
