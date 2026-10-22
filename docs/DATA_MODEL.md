# Data Model

Status: **schema V2 implemented** — V1 (M01: Project, BoardColumn, ProjectTask, ChecklistItem, ReleasePlan) + V2 (M03: RepositoryConnection). Entities marked M04 are still proposals. Changes from the plan's suggested fields are marked **Δ** and trace to [PRODUCT_SPEC §6](PRODUCT_SPEC.md#6-open-questions-and-plan-gaps).

## 1. Conventions

- Local identity is a `UUID`. GitHub identity is stored separately as `Int64` (`githubRepositoryID`, `githubReleaseID`).
- Every entity has `createdAt` and `updatedAt`, except write-once snapshots, which have `snapshotCreatedAt`.
- Versions are `String`, parsed by a `ReleaseVersion` value type: semver 2.0 with prerelease and build metadata, or a custom label. Ordering is semver precedence; custom labels sort after semver.
- Ordering uses `sortOrder: Double` (fractional indexing). Insert between neighbours with the midpoint. Renormalize a column (to 1, 2, 3, …) when a gap falls below `1e-9`, within the same transaction.

## 2. Entities

### Project
`id`, `name`, `details?`, `iconName?`, `accentColor?`, `createdAt`, `updatedAt`, `archivedAt?`

Owns columns, tasks, repository connections, release plans, and snapshots. Archive is the default. Hard delete cascades and requires confirmation; snapshots are deleted only with their project.

### RepositoryConnection (M03, schema V2)
`id`, `projectID`, `githubRepositoryID` (unique per project), `owner`, `name`, `fullName`, `defaultBranch?`, `htmlURL`, `lastSyncedAt?`, `createdAt`, `updatedAt`

Owner and name are refreshed on sync; renames and transfers keep the same `githubRepositoryID`. Stored fields: plus `isPrivate`; `fullName` is derived. Cascade-deleted with the project; unique per project by `githubRepositoryID`.

### BoardColumn
`id`, `projectID`, `name`, `sortOrder`, `isCompletionColumn`, `createdAt`, `updatedAt`

- Exactly one completion column per project.
- A column cannot be deleted while it holds tasks; the user picks a destination column first.
- New projects get the default columns Backlog, To Do, In Progress, Review, and Done (the completion column). Making the defaults configurable in Settings is deferred to M05 (per-project columns are fully editable since M02).

### ProjectTask **Δ** (plan: `Task`, renamed so it doesn't shadow Swift's `Task`)
`id`, `projectID`, `releasePlanID?`, **Δ `columnID`** (was `statusID`), `title`, `details?` (Markdown), `priority` (`low|medium|high|urgent`), `type` (`feature|improvement|bugFix|documentation|maintenance|other`), `labels: [String]` (trimmed, case-insensitive unique), `sortOrder`, `createdAt`, `updatedAt`, `completedAt?`

`completedAt` is set when the task enters the completion column and cleared when it leaves. A task's project must equal its column's project and its release plan's project.

### ChecklistItem **Δ**
`id`, `taskID`, `title`, `isDone`, `sortOrder`

Cascade-deleted with its task.

### ReleasePlan
`id`, `projectID`, **Δ `repositoryConnectionID?`**, `version`, `title?`, `details?`, `status`, `targetBranch?`, `targetCommitSHA?` (full 40-character SHA), `plannedDate?`, **Δ `changelogMarkdown`** (working draft, kept through failures), **Δ `githubDraftReleaseID?`**, `createdAt`, `updatedAt`, `releasedAt?`

At most one plan per project in `planned | draftCreated | reconciliationNeeded` (the MVP's "one active plan"; enforced by a use case in M02). V1 stores the local fields only. `repositoryConnectionID` and `githubDraftReleaseID` arrive with M03/M04 as an additive schema change.

Deleting a plan unlinks its tasks; it does not delete them.

### GitHubReference (M03)
`id`, `projectID`, `taskID?`, `repositoryID: Int64`, `referenceType` (`commit|pullRequest|tag|release`), `number?`, `sha?`, `title?`, `htmlURL`, `mergedAt?`, `lastFetchedAt?`

### ReleaseSnapshot (write-once content, M04)
- **Content, frozen at draft creation (Δ G2):** `id`, `projectID`, `releasePlanID?`, `version`, `title?`, `tagName`, `targetCommitSHA`, `releaseNotesMarkdown` (as submitted), `taskSnapshots` (an encoded `[TaskSnapshot]`: title, details, type, priority, labels, completion state, GitHub references), `repositoryID`, `snapshotCreatedAt`
- **Lifecycle, each set at most once:** `githubReleaseID`, `githubReleaseURL`, `releaseState`, `publishedAt?`, `publishedNotesMarkdown?` (stored only if GitHub's notes differ from the submitted ones)

Immutability is enforced by the repository API, which has no update method for content fields, and covered by tests.

### GitHub cache (M03, not in the schema)
One JSON `RepositorySnapshot` per repository (releases, tags, unreleased commits and merged PRs, notes, `fetchedAt`) under `Application Support/Relvora/GitHub Cache/`. Written only after a successful sync; excluded from backups ([ADR 0009](decisions/0009-github-integration-design.md)).

### Preferences
Stored in `UserDefaults`. M01 uses `@AppStorage` with centralized keys (`PreferenceKey`); a `PreferencesStore` protocol arrives with backup/restore in M02:
- Appearance and accent.
- Window material.
- Sidebar visibility.
- Default columns.
- Changelog categories (label → section mapping).
- Last-selected project and view.

## 3. State machines

**ReleasePlanStatus**

```text
planned ──create draft (confirmed)──▶ draftCreated ──publication verified──▶ published
   │                │                       │
   │                └─timeout/save failure─▶ reconciliationNeeded ──re-read GitHub──▶ draftCreated | planned | published
   └──────────────cancel──────────────▶ cancelled ◀──cancel── draftCreated
```

**ReleaseSnapshotState:** `draftCreated` → `published` | `abandoned` (the draft was deleted on GitHub). No other transitions.

## 4. Migration and integrity

- `RelvoraSchemaV1` shipped in M01 and is **frozen once merged to `main`**, because development builds may hold real data. Every later change adds a `VersionedSchema` and a stage ([ADR 0001](decisions/0001-swiftdata-behind-repositories.md)).
- Delete rules in V1: a project cascades to its columns, tasks, and plans, and a task cascades to its checklist. Deleting a column or plan nullifies the link; column deletion is guarded by a domain rule (M02).
- Integrity rules enforced by the repository: a task's column and release plan must belong to the task's project, and records never move between projects. A rejected save is rolled back completely.
- A fixture store per frozen schema version lives in `Tests/Fixtures/`, starting with V1 when V2 is introduced. Migration tests open each fixture with the current schema in a `.serialized` suite.
- Backup format 1 (`BackupDocument`) mirrors V1 with string enum values and millisecond ISO 8601 dates. Restore refuses newer `formatVersion`s and validates the following before replacing data:
  - unique IDs;
  - exactly one completion column per project;
  - tasks referencing only their own project's columns and plans;
  - valid enums and versions;
  - at most one active plan.
