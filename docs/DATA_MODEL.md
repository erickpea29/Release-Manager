# Data Model

Status: proposed for M01–M04. Changes from the plan's suggested fields are marked **Δ** and trace to [PRODUCT_SPEC §6](PRODUCT_SPEC.md#6-open-questions-and-plan-gaps).

## 1. Conventions

- Local identity is a `UUID`. GitHub identity is stored separately as `Int64` (`githubRepositoryID`, `githubReleaseID`).
- Every entity has `createdAt` and `updatedAt`, except write-once snapshots, which have `snapshotCreatedAt`.
- Versions are `String`, parsed by a `ReleaseVersion` value type: semver 2.0 with prerelease and build metadata, or a custom label. Ordering is semver precedence; custom labels sort after semver.
- Ordering uses `sortOrder: Double` (fractional indexing). Insert between neighbours with the midpoint. Renormalize a column (to 1, 2, 3, …) when a gap falls below `1e-9`, within the same transaction.

## 2. Entities

### Project
`id`, `name`, `details?`, `iconName?`, `accentColor?`, `createdAt`, `updatedAt`, `archivedAt?`

Owns columns, tasks, repository connections, release plans, and snapshots. Archive is the default. Hard delete cascades and requires confirmation; snapshots are deleted only with their project.

### RepositoryConnection
`id`, `projectID`, `githubRepositoryID` (unique per project), `owner`, `name`, `fullName`, `defaultBranch?`, `htmlURL`, `lastSyncedAt?`, `createdAt`, `updatedAt`

Owner and name are refreshed on sync; renames and transfers keep the same `githubRepositoryID`.

### BoardColumn
`id`, `projectID`, `name`, `sortOrder`, `isCompletionColumn`, `createdAt`, `updatedAt`

- Exactly one completion column per project.
- A column cannot be deleted while it holds tasks; the user picks a destination column first.
- New projects get the default columns from preferences.

### Task
`id`, `projectID`, `releasePlanID?`, **Δ `columnID`** (was `statusID`), `title`, `details?` (Markdown), `priority` (`low|medium|high|urgent`), `type` (`feature|improvement|bugFix|documentation|maintenance|other`), `labels: [String]` (trimmed, case-insensitive unique), `sortOrder`, `createdAt`, `updatedAt`, `completedAt?`

`completedAt` is set when the task enters the completion column and cleared when it leaves. A task's project must equal its column's project and its release plan's project.

### ChecklistItem **Δ**
`id`, `taskID`, `title`, `isDone`, `sortOrder`

Cascade-deleted with its task.

### ReleasePlan
`id`, `projectID`, **Δ `repositoryConnectionID?`**, `version`, `title?`, `details?`, `status`, `targetBranch?`, `targetCommitSHA?` (full 40-character SHA), `plannedDate?`, **Δ `changelogMarkdown`** (working draft, kept through failures), **Δ `githubDraftReleaseID?`**, `createdAt`, `updatedAt`, `releasedAt?`

At most one plan per project in `planned | draftCreated | reconciliationNeeded` (the MVP's "one active plan").

### GitHubReference
`id`, `projectID`, `taskID?`, `repositoryID: Int64`, `referenceType` (`commit|pullRequest|tag|release`), `number?`, `sha?`, `title?`, `htmlURL`, `mergedAt?`, `lastFetchedAt?`

### ReleaseSnapshot (write-once content)
- **Content, frozen at draft creation (Δ G2):** `id`, `projectID`, `releasePlanID?`, `version`, `title?`, `tagName`, `targetCommitSHA`, `releaseNotesMarkdown` (as submitted), `taskSnapshots` (an encoded `[TaskSnapshot]`: title, details, type, priority, labels, completion state, GitHub references), `repositoryID`, `snapshotCreatedAt`
- **Lifecycle, each set at most once:** `githubReleaseID`, `githubReleaseURL`, `releaseState`, `publishedAt?`, `publishedNotesMarkdown?` (stored only if GitHub's notes differ from the submitted ones)

Immutability is enforced by the repository API, which has no update method for content fields, and covered by tests.

### GitHub cache (M03)
`CachedRelease` and `CachedTag`, keyed by (`repositoryID`, GitHub ID or name), with `fetchedAt`. A refresh replaces a repository's rows only after a successful full fetch.

### Preferences
Stored in `UserDefaults` behind `PreferencesStore`:
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

- `SchemaV1` ships in M01. Every change adds a `VersionedSchema` and a stage ([ADR 0001](decisions/0001-swiftdata-behind-repositories.md)).
- A fixture store per released schema version lives in `Tests/Fixtures/`. Migration tests open each fixture with the current schema in a `.serialized` suite.
- A backup JSON envelope carries `formatVersion`. Restore refuses unknown future versions and validates referential integrity before replacing data.
