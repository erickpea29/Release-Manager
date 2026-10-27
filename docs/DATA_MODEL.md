# Data Model

Status: **schema V5 implemented** — V1 (M01: Project, BoardColumn, ProjectTask, ChecklistItem, ReleasePlan) + V2 (M03: RepositoryConnection) + V3 (M04: ReleaseSnapshot, plan repository/tag/compare base) + V4 (0.1.1: ProjectGroup) + V5 (ReleaseStep, plan checklist ticks). Changes from the plan's suggested fields are marked **Δ** and trace to [PRODUCT_SPEC §6](PRODUCT_SPEC.md#6-open-questions-and-plan-gaps).

## 1. Conventions

- Local identity is a `UUID`. GitHub identity is stored separately as `Int64` (`githubRepositoryID`, `githubReleaseID`).
- Every entity has `createdAt` and `updatedAt`, except write-once snapshots, which have `snapshotCreatedAt`.
- Versions are `String`, parsed by a `ReleaseVersion` value type: semver 2.0 with prerelease and build metadata, or a custom label. Ordering is semver precedence; custom labels sort after semver.
- Ordering uses `sortOrder: Double` (fractional indexing). Insert between neighbours with the midpoint. Renormalize a column (to 1, 2, 3, …) when a gap falls below `1e-9`, within the same transaction.

## 2. Entities

### Project
`id`, `name`, `details?`, `iconName?`, `accentColor?`, `createdAt`, `updatedAt`, `archivedAt?`, `groupID?` (V4)

Owns columns, tasks, repository connections, release plans, and snapshots. Archive is the default. Hard delete cascades and requires confirmation; snapshots are deleted only with their project.

### ProjectGroup (0.1.1, schema V4)
`id`, `name` (trimmed, unique ignoring case), `sortOrder`, `createdAt`, `updatedAt`

Organizes projects, for example by company, in the sidebar, the Dashboard, quick actions, and the Release History filter ([ADR 0014](decisions/0014-project-groups.md)). One level; a project is in at most one group. Deleting a group nullifies its projects' link, so they stay, outside any group. A project can't refer to a group that doesn't exist.

### RepositoryConnection (M03, schema V2)
`id`, `projectID`, `githubRepositoryID` (unique per project), `owner`, `name`, `fullName`, `defaultBranch?`, `htmlURL`, `lastSyncedAt?`, `createdAt`, `updatedAt`

Owner and name are refreshed on sync; renames and transfers keep the same `githubRepositoryID`. Stored fields: plus `isPrivate`; `fullName` is derived. Cascade-deleted with the project; unique per project by `githubRepositoryID`.

### BoardColumn
`id`, `projectID`, `name`, `sortOrder`, `isCompletionColumn`, `createdAt`, `updatedAt`

- Exactly one completion column per project.
- A column cannot be deleted while it holds tasks; the user picks a destination column first.
- New projects get the default columns To Do, In Progress, Review, and Done (the completion column), or the columns set in **Settings › Board**.
- No column may be named “Backlog”: the Backlog is a tab, holding every unfinished task outside the version being planned (`VersionScope`, [ADR 0012](decisions/0012-backlog-tab-and-version-board.md)). A board from before the tab loses its Backlog column when the project opens: its tasks move to To Do, keeping their order and version, or the column is renamed To Do when there is none (`BoardPlanner.retireBacklogColumns`).

### ProjectTask **Δ** (plan: `Task`, renamed so it doesn't shadow Swift's `Task`)
`id`, `projectID`, `releasePlanID?`, **Δ `columnID`** (was `statusID`), `title`, `details?` (Markdown), `priority` (`low|medium|high|urgent`), `type` (`feature|improvement|bugFix|documentation|maintenance|other`), `labels: [String]` (trimmed, case-insensitive unique), `sortOrder`, `createdAt`, `updatedAt`, `completedAt?`

`completedAt` is set when the task enters the completion column and cleared when it leaves. A task's project must equal its column's project and its release plan's project.

### ChecklistItem **Δ**
`id`, `taskID`, `title`, `isDone`, `sortOrder`

Cascade-deleted with its task.

### ReleasePlan
`id`, `projectID`, **Δ `repositoryConnectionID?`** (V3), **Δ `completedStepIDs`** (V5; the release checklist steps ticked on the plan, stored as strings; IDs of deleted steps are ignored), `version`, `title?`, `details?`, `status`, `targetBranch?`, `targetCommitSHA?` (full 40-character lowercase SHA), **Δ `tagName?`** (V3; Git ref rules), **Δ `compareBaseTag?`** (V3; the changelog's base, default the latest release), `plannedDate?`, **Δ `changelogMarkdown`** (working draft, kept through failures), `createdAt`, `updatedAt`, `releasedAt?`

At most one plan per project in `planned | draftCreated | reconciliationNeeded` (the MVP's "one active plan"; enforced by a use case in M02). **Δ** The proposed `githubDraftReleaseID` was not added: the plan's open snapshot holds the GitHub release ID.

A plain save writes only `planned` or `cancelled`, and only over a `planned` plan; every other status is set by the release workflow's guarded `record` ([ADR 0010](decisions/0010-release-workflow-and-reconciliation.md)). Deleting a plan (only `planned` or `cancelled`) unlinks its tasks; it does not delete them. Snapshots keep the plan's ID as a plain value and outlive it.

### GitHubReference (not implemented)
Proposed: `id`, `projectID`, `taskID?`, `repositoryID: Int64`, `referenceType` (`commit|pullRequest|tag|release`), `number?`, `sha?`, `title?`, `htmlURL`, `mergedAt?`, `lastFetchedAt?`. **Δ** Not needed in M04: a snapshot records the pull requests of its release in its change summary. Linking tasks to pull requests remains a later option.

### ReleaseStep (schema V5)
`id`, `projectID`, `title` (trimmed, 1–200 characters), `sortOrder`, `createdAt`, `updatedAt`

A step of the project's release checklist, such as "Test on a clean Mac". Every step must be ticked on a plan before its draft is created (`ReleaseIssue.checklistIncomplete`). Cascade-deleted with the project. The checklist is saved as a whole: existing steps keep their IDs, so plans keep their ticks ([ADR 0016](decisions/0016-version-suggestion-and-release-checklist.md)).

### ReleaseSnapshot (M04, schema V3, write-once)
- **Content, frozen when the draft is requested (Δ G2):** `id`, `projectID`, `releasePlanID?` (plain value), **Δ `origin`** (`relvoraDraft | external`), `version`, `title?`, **Δ `releaseName`** (title sent to GitHub), `tagName`, `targetCommitSHA`, **Δ `targetBranch?`**, **Δ `isPrerelease`**, `releaseNotesMarkdown` (as submitted), and a JSON payload with `tasks` (`[TaskSnapshot]`: source ID, title, details, type, priority, labels, completion and date, column name, checklist counts) **Δ `changes`** (base tag, commit count, merged pull requests, compare URL, completeness), and **Δ `checklist`** (since V5: each release checklist step's title and whether it was ticked; absent in older snapshots). Also `githubRepositoryID`, **Δ `repositoryFullName`**, **Δ `repositoryURL`** (as they were), `snapshotCreatedAt`.
- **Lifecycle, each set at most once:** `state`, `githubReleaseID`, `githubReleaseURL` (updated once more at publication, when GitHub moves the draft's `untagged-…` page), `publishedAt?`, `publishedNotesMarkdown?` (only if GitHub's notes differ, ignoring CRLF and trailing whitespace), **Δ `publishedTagName?`** (only if it differs and the user accepted it), **Δ `publishedCommitSHA?`** (the verified commit), **Δ `stateChangedAt`**.

Immutability: the repository has no content update. `record` applies only the transitions `ReleaseSnapshot.applying` allows and writes lifecycle columns only; a new snapshot must be `pending` (Relvora draft) or `published` (recorded from GitHub); only a `pending` one can be discarded, after GitHub showed no draft was created. Covered by store and workflow tests.

### GitHub cache (M03, not in the schema)
One JSON `RepositorySnapshot` per repository (releases, tags, unreleased commits and merged PRs, notes, `fetchedAt`) under `Application Support/Relvora/GitHub Cache/`. Written only after a successful sync; excluded from backups ([ADR 0009](decisions/0009-github-integration-design.md)).

### Preferences (M05)
Stored in `UserDefaults` through one `Preferences` store in the app. Keys from M01–M04 are unchanged. Values:
- Appearance (`system|light|dark`).
- Accent (`system|blue|purple|pink|red|orange|green|graphite`).
- Window (`opaque|translucent`).
- Sidebar visibility.
- **Columns for new projects**: `[ColumnTemplate]` (name, isCompletion), validated by `ProjectRules.validatedTemplate` (one or more columns, exactly one completion column, names differ ignoring case, none named “Backlog”; a saved template from before the Backlog tab drops it).
- **Release-note label rules**: `[ChangelogLabelRule]` (label → `ChangelogCategory` key), which win over the built-in label meanings.
- **GitHub refresh** (`5m|15m|1h|never`, default `5m`): how often the repository open in the GitHub tab refreshes while Relvora is active.
- **Menu bar icon** (on by default): whether Relvora shows its menu bar icon ([ADR 0022](decisions/0022-menu-bar-icon.md)). In backups as an optional field within format 6.

Backup format 4 carries these settings, except sidebar visibility, as a `preferences` record. Restore applies the known, valid values and keeps the current ones otherwise (G12). The last-selected project and tab are window state (`SceneStorage`), not preferences.

## 3. State machines

**ReleasePlanStatus** (implemented by `ReleaseWorkflow`, [ADR 0010](decisions/0010-release-workflow-and-reconciliation.md))

```text
planned ──create draft (confirmed; intent saved first)──▶ reconciliationNeeded ──GitHub confirms──▶ draftCreated
   │                                                         │   (timeout: stays until Check GitHub)          │
   │                                     no draft on GitHub ─┘──▶ planned                                     │
   │                                                                                                          ▼
   │      draft deleted on GitHub ◀────────────── draftCreated ──published (in Relvora, confirmed, or on GitHub),
   │                                                  │            tag at reviewed SHA──▶ published
   │      (snapshot abandoned, plan planned)          │
   │                                                  └──published, tag/SHA differs──▶ reconciliationNeeded ──Record as Published──▶ published
   ├──release published on GitHub for the tag ──Record Published Release──▶ published
   └──cancel──▶ cancelled
```

Publishing from Relvora ([ADR 0015](decisions/0015-publish-from-relvora.md)) needs no intermediate state: the request is idempotent, so after a lost response the plan stays `draftCreated` until GitHub is read.

**Δ** A drafted plan is not cancelled locally: delete the draft on GitHub, check, then cancel or re-draft, so history never disagrees with GitHub.

**ReleaseSnapshotState:** `pending` → `draftCreated` → `published` | `abandoned`. A `pending` snapshot is discarded (not kept) when GitHub shows no draft was created. External records start as `published`. No other transitions.

## 4. Migration and integrity

- `RelvoraSchemaV1` shipped in M01 and is **frozen once merged to `main`**, because development builds may hold real data. Every later change adds a `VersionedSchema` and a stage ([ADR 0001](decisions/0001-swiftdata-behind-repositories.md)).
- Delete rules in V1: a project cascades to its columns, tasks, and plans, and a task cascades to its checklist. Deleting a column or plan nullifies the link; column deletion is guarded by a domain rule (M02).
- Integrity rules enforced by the repository: a task's column and release plan must belong to the task's project, and records never move between projects. A rejected save is rolled back completely.
- A fixture store per frozen schema version lives in `Tests/Fixtures/`, starting with V1 when V2 is introduced. Migration tests open each fixture with the current schema in a `.serialized` suite.
- Fixture stores:
  - `RelvoraV1.store`: frozen M02.
  - `RelvoraV2.store`: frozen M03, generated from `backup-v2.json` before V3.
  - `RelvoraV3.store`: 0.1.0, generated from `backup-v2.json` before V4.
  - `RelvoraV4.store`: 0.1.1, generated from `backup-v5.json` (with a project group) before V5.
- Backup format 6 (`BackupDocument`; 1 = V1, 2 adds connections, 3 adds snapshots and plan targets, 4 adds settings, 5 adds groups and each project's group, 6 adds release checklists, their ticks, and each snapshot's frozen checklist) uses string enum values and millisecond ISO 8601 dates. Restore refuses newer `formatVersion`s and validates the following before replacing data (format 3 adds: unique snapshot IDs, known states, full SHAs, a GitHub release ID for non-pending snapshots, at most one open snapshot per plan):
  - unique IDs;
  - exactly one completion column per project;
  - tasks referencing only their own project's columns and plans;
  - valid enums and versions;
  - at most one active plan;
  - (format 5) unique group IDs and names, and projects only in the backup's groups;
  - (format 6) unique checklist step IDs, with valid titles and positions.
