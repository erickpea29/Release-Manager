# Native macOS Release Manager — Product & Implementation Plan

## 1. Project Overview

Build a modern, low-cost, native macOS application for managing software projects and their releases. The application should combine a lightweight project dashboard, configurable Kanban boards, release planning, GitHub integration, changelog preparation, and an immutable release history.

The application is local-first: core project and task management must work offline, and no hosted backend is required for the MVP. GitHub is the source-control and release integration. Cloudflare is not part of the initial runtime architecture; it may be introduced later only if a concrete remote-service requirement justifies it.

### Product goals

- Manage multiple software projects from one native macOS application.
- Plan first releases and subsequent versions.
- Track release work through a Kanban board.
- Connect projects to one or more GitHub repositories.
- Inspect GitHub releases, tags, commits, and merged pull requests.
- Generate and edit Markdown changelogs.
- Create GitHub release drafts for review before publication.
- Preserve an accurate historical snapshot of each completed release.
- Provide a modern macOS experience with themes, optional translucent materials, keyboard navigation, and efficient workflows.
- Avoid mandatory paid infrastructure and unnecessary dependencies.

### Non-goals for the MVP

- Team collaboration or multi-user accounts.
- A hosted backend or mandatory cloud synchronization.
- Automatically deploying software to production.
- Automatically publishing GitHub releases without user review.
- Mandatory AI APIs or paid AI services.
- App Store Connect integration.
- Windows, Linux, or mobile applications.
- A complex project-management system with time tracking, billing, or enterprise administration.

## 2. Product Principles

1. **Native first:** Use Swift and SwiftUI for the application UI and macOS integration.
2. **Local first:** Projects, tasks, preferences, and release snapshots remain available offline.
3. **GitHub as an integration, not the local database:** Cache remote data as needed, but keep local planning independent of GitHub availability.
4. **Safe release operations:** Never silently publish a release, move a tag, or change the target commit after review.
5. **Immutable release history:** A completed release snapshot must not change when its source tasks are edited later.
6. **Minimal infrastructure:** Do not add a backend, Cloudflare service, or third-party service unless required by a confirmed feature.
7. **Incremental delivery:** Implement the app in independently testable phases.
8. **Accessible, readable design:** Translucency must never compromise contrast or usability.

## 3. Recommended Technology Stack

| Area | Technology | Notes |
|---|---|---|
| Language | Swift | Native implementation and strong type safety |
| UI | SwiftUI | macOS-native navigation, controls, layouts, and animations |
| Native window integration | AppKit where necessary | Use for window configuration and visual effects not adequately exposed by SwiftUI |
| Local persistence | SwiftData initially | Native persistence with a small dependency footprint |
| Database abstraction | Repository protocols | Isolate persistence so the implementation can move to SQLite/GRDB if future requirements justify it |
| Networking | URLSession | Native HTTP client |
| Concurrency | Swift concurrency (`async`/`await`, actors where appropriate) | Keep networking and shared mutable state safe |
| GitHub integration | GitHub REST API | Repositories, releases, tags, commits, pull requests |
| Authentication secrets | macOS Keychain | Never store access tokens in the app database or logs |
| Unit tests | Swift Testing and/or XCTest | Follow the framework supported by the selected Xcode version |
| UI tests | XCTest UI testing | Cover core user flows |
| CI | GitHub Actions on macOS runners | Build and test within available free usage |
| Distribution | Developer signing and notarization when required | Public distribution requirements must be assessed separately |

### Architecture decision: SwiftData versus SQLite

Start with SwiftData to keep the MVP native and low-maintenance. Hide persistence behind repository protocols and avoid making SwiftData model objects the public domain API.

Evaluate SQLite/GRDB only if actual requirements demonstrate a need for more explicit SQL control, advanced querying, migration behavior, or transaction management. Do not add both persistence systems preemptively.

### Avoid in the MVP

- React, Next.js, Node.js, or a web-based UI.
- A remote API gateway or custom backend.
- Cloudflare Workers, D1, R2, or Hyperdrive without a concrete requirement.
- A JavaScript monorepo manager.
- Heavy third-party UI frameworks when SwiftUI can meet the requirement.
- Mandatory subscription services.

## 4. High-Level Architecture

```text
┌──────────────────────────────────────────────────────┐
│                  Native macOS App                    │
│             SwiftUI + AppKit when needed             │
├─────────────────────────┬────────────────────────────┤
│       Feature UI        │       Design System        │
│ Dashboard / Projects    │ Themes / Components        │
│ Kanban / Releases       │ Typography / Materials     │
│ History / Settings      │ Accessibility              │
├─────────────────────────┴────────────────────────────┤
│                  Application Core                    │
│ Use Cases / Domain Models / Validation / Policies    │
├─────────────────────────┬────────────────────────────┤
│     Local Persistence   │      GitHub Integration    │
│ Repository Protocols    │ Auth / REST API / Cache    │
│ SwiftData               │ Releases / Tags / PRs      │
├─────────────────────────┴────────────────────────────┤
│                       macOS                          │
│                  Keychain / File I/O                 │
└──────────────────────────────────────────────────────┘
                              │
                              ▼
                       GitHub REST API

Optional future infrastructure only when justified:
Cloudflare Worker / R2 / other service
```

### Architectural rules

- UI views must not make raw GitHub HTTP requests directly.
- Views should call observable view models or feature-level state containers.
- Business rules belong in application/domain services, not inside SwiftUI view bodies.
- Persistence and remote API access must be separated behind protocols.
- Keep GitHub DTOs separate from local domain models.
- All network operations must support loading, failure, cancellation where applicable, and retry-safe behavior.
- Use explicit error types and user-readable error messages.
- Do not log credentials, authorization headers, or sensitive response payloads.
- Use dependency injection for services to make unit tests deterministic.

## 5. GitHub Integration

GitHub is a core feature. Users must be able to connect a project to one or more GitHub repositories and inspect repository release information.

### MVP capabilities

- Connect and disconnect a GitHub account.
- Browse repositories accessible to the authorized user.
- Search or filter repositories.
- Associate one or more repositories with a local project.
- Store GitHub repository IDs, owner/name, default branch, and canonical URL.
- Fetch and cache:
  - Published releases.
  - Draft releases where the API and granted permissions allow access.
  - Tags.
  - Commits between a previous release and a selected target commit.
  - Merged pull requests where accessible.
- Display external GitHub URLs and open them in the default browser.
- Detect remote changes when refreshing.
- Show last synchronization time and distinguish cached data from fresh data.
- Create a GitHub draft release.
- Reconcile local state after draft creation or publication on GitHub.

### Authentication strategy

Investigate a GitHub App-based user authorization flow suitable for a desktop application, including GitHub's device authorization flow where supported by the selected app configuration.

Before implementing the complete integration, complete a technical spike to validate:

1. GitHub App registration and supported authorization flow.
2. Whether the intended desktop flow can be implemented without embedding a confidential client secret.
3. Required repository permissions for all planned API endpoints.
4. Access to public and private repositories.
5. Token expiration, refresh, revocation, and reauthorization behavior.
6. Whether any token exchange requires a minimal server-side component.

Never embed a GitHub App private key or confidential client secret in the macOS application binary. A client ID is not a secret. If secure authorization cannot be completed without a confidential secret, assess a minimal Cloudflare Worker for the specific exchange requirement; do not introduce it until the spike demonstrates that it is necessary.

Store tokens in macOS Keychain. Never store tokens in SwiftData, source control, plain-text preferences, crash reports, analytics, or logs.

### Permission principle

Request the minimum permissions necessary. Validate the exact permissions against the GitHub REST endpoints used by the implementation.

Likely needs include:

- Repository metadata: read.
- Repository contents: read; write only where required for release/tag operations.
- Pull requests: read.

Do not request broad organization or administration permissions unless a documented feature requires them.

### API client requirements

- Use URLSession and Swift concurrency.
- Define typed request and response models.
- Handle pagination.
- Handle rate limits and `Retry-After` or relevant GitHub rate-limit headers.
- Handle expired or revoked credentials.
- Handle 401, 403, 404, 409, 422, 429, and 5xx responses appropriately.
- Use bounded retries for transient failures.
- Avoid retrying non-idempotent create operations blindly.
- Keep cached data when refresh fails.
- Do not confuse a tag, a draft release, and a published release.
- Use stable GitHub repository and release IDs rather than names alone.

## 6. Release Workflow

The primary action should be **Prepare Release** or **Create GitHub Draft**, not an ambiguous button that claims a release has been published.

### Expected workflow

1. Create a local release plan.
2. Select the project and associated GitHub repository.
3. Set a version string and optional title.
4. Choose a target branch and target commit.
5. Review tasks included in the release.
6. Fetch commits and merged pull requests between the previous release tag and the target commit.
7. Generate an initial changelog.
8. Edit and confirm the changelog.
9. Validate the selected tag and target commit.
10. Create a GitHub draft release.
11. Open the draft in GitHub for final review and publication.
12. Detect or confirm publication on GitHub.
13. Save an immutable local release snapshot with the verified GitHub release ID, URL, tag, commit SHA, release notes, and task snapshots.

### Release safety requirements

- Do not publish automatically in the MVP.
- Do not move or overwrite an existing tag silently.
- Show the exact target commit SHA before creating a draft.
- Detect existing tags and conflicting releases.
- Require confirmation before creating a draft.
- Do not claim that a release was published until publication has been verified.
- If the remote draft is created but the local save fails, fetch/reconcile the remote state before retrying.
- If a request times out after a create operation, check GitHub for the resulting release before issuing another create request.
- Do not mark all tasks complete automatically when creating a release.
- Warn about incomplete tasks but allow an explicit override if the user chooses.
- Preserve the final release notes as a snapshot, even if the GitHub draft is later edited.
- Clearly distinguish local planned, draft-created, published, and failed/reconciliation-needed states.

### Changelog generation

Generate changelogs deterministically from available GitHub data.

- Compare commits from the previous release tag to the selected target commit.
- Retrieve merged pull requests when available.
- Associate commits and pull requests where possible.
- Group changes by configured categories or labels.
- Allow manual editing before the draft is created.
- Support Markdown export.
- Clearly identify missing data when the repository history is incomplete or the user lacks permission.

AI-generated changelog text is optional and out of scope for the MVP.

## 7. Local Data Model

Use stable UUIDs for local entities and explicit relationships. Persist GitHub IDs separately from local UUIDs.

### Project

Suggested fields:

- `id: UUID`
- `name: String`
- `description: String?`
- `iconName: String?`
- `accentColor: String?`
- `createdAt: Date`
- `updatedAt: Date`
- `archivedAt: Date?`

Relationships:

- Repository connections.
- Release plans.
- Tasks, directly or through release plans, depending on the chosen ownership model.

### RepositoryConnection

Suggested fields:

- `id: UUID`
- `projectID: UUID`
- `githubRepositoryID: Int64`
- `owner: String`
- `name: String`
- `fullName: String`
- `defaultBranch: String?`
- `htmlURL: URL`
- `lastSyncedAt: Date?`
- `createdAt: Date`

Do not use the repository name as its unique identity. A repository can be renamed or transferred.

### ReleasePlan

Suggested fields:

- `id: UUID`
- `projectID: UUID`
- `version: String`
- `title: String?`
- `description: String?`
- `status: ReleasePlanStatus`
- `targetBranch: String?`
- `targetCommitSHA: String?`
- `plannedDate: Date?`
- `createdAt: Date`
- `updatedAt: Date`
- `releasedAt: Date?`

Version is a string, not a floating-point number. Support semantic versions such as `1.10.0`, prereleases such as `2.0.0-beta.1`, and optional custom labels if product requirements permit them.

For the MVP, support one active planned release per project. Keep the model extensible enough for multiple release branches later.

### Task

Suggested fields:

- `id: UUID`
- `projectID: UUID`
- `releasePlanID: UUID?`
- `title: String`
- `details: String?`
- `statusID: UUID`
- `priority: TaskPriority`
- `type: TaskType`
- `labels: [String]` or a normalized relationship if needed
- `sortOrder: Double`
- `createdAt: Date`
- `updatedAt: Date`
- `completedAt: Date?`

MVP task types may include feature, improvement, bug fix, documentation, maintenance, and other.

Support a basic checklist and notes. Avoid complex task dependencies and estimation systems in the MVP.

### BoardColumn

Suggested fields:

- `id: UUID`
- `projectID: UUID`
- `name: String`
- `sortOrder: Double`
- `isCompletionColumn: Bool`
- `createdAt: Date`
- `updatedAt: Date`

Provide sensible defaults such as Backlog, To Do, In Progress, Review, and Done. Allow users to rename, reorder, add, or remove columns while validating that tasks remain associated with a valid column.

### GitHubReference

Suggested fields:

- `id: UUID`
- `projectID: UUID`
- `taskID: UUID?`
- `repositoryID: Int64`
- `referenceType: GitHubReferenceType`
- `number: Int?`
- `sha: String?`
- `title: String?`
- `htmlURL: URL`
- `mergedAt: Date?`
- `lastFetchedAt: Date?`

Use this entity to associate tasks or release plans with commits, pull requests, or tags where useful.

### ReleaseSnapshot

Suggested fields:

- `id: UUID`
- `projectID: UUID`
- `releasePlanID: UUID?`
- `version: String`
- `title: String?`
- `tagName: String?`
- `targetCommitSHA: String?`
- `releaseNotesMarkdown: String`
- `taskSnapshots: [TaskSnapshot]` or a serialized immutable snapshot payload
- `repositoryID: Int64?`
- `githubReleaseID: Int64?`
- `githubReleaseURL: URL?`
- `publishedAt: Date?`
- `snapshotCreatedAt: Date`
- `releaseState: ReleaseSnapshotState`

The snapshot must preserve the relevant task title, description, type, completion state, and GitHub references as they existed at release time. Later task edits must not change the snapshot.

### Preferences

Persist non-secret preferences such as:

- Appearance mode: system, light, dark.
- Accent color.
- Translucent-window preference.
- Sidebar visibility.
- Default Kanban columns.
- Changelog category preferences.
- Keyboard shortcut preferences where customizable.
- Last-selected project and view.

Tokens and other credentials must be stored separately in Keychain.

### Data integrity

- Use transactions for operations that update multiple related records.
- Define and test migration behavior.
- Provide local export and backup/restore.
- Never delete cached GitHub data merely because a refresh failed.
- Add `createdAt` and `updatedAt` consistently.
- Ensure release snapshots are immutable through application logic.
- Test restore behavior with real versioned database fixtures.

## 8. UI and Design System

The app should feel like a modern Mac productivity tool, not a web dashboard placed inside a window.

### Main navigation

- Dashboard.
- Projects.
- Kanban.
- Releases.
- Release History.
- Settings.

A project should show its current version, next planned version, progress, connected repositories, and recent release activity.

### Visual direction

- Native SwiftUI controls where they fit.
- Clear hierarchy, restrained spacing, and readable typography.
- Light, dark, and system appearance.
- Configurable accent color.
- Rounded cards and panels used consistently.
- Subtle animations and transitions.
- Keyboard navigation and accessible labels.
- Empty, loading, offline, and error states for all remote-data views.

### Transparency

Implement two independent settings:

1. **Window material:** standard opaque appearance or a translucent macOS material.
2. **Interface theme:** system/light/dark, with configurable accent and panel styling.

Use supported SwiftUI materials where possible. Use AppKit integration, such as `NSVisualEffectView`, only where needed for true window-level translucency or behavior unavailable in SwiftUI.

Requirements:

- Test on the minimum supported macOS version and the current target OS.
- Ensure sufficient contrast in both light and dark environments.
- Keep text and interactive controls readable over changing desktop backgrounds.
- Provide an opaque fallback.
- Avoid unsupported private APIs.
- Do not make visual transparency a dependency for core functionality.

## 9. Repository and Monorepo Structure

Host the source code in one GitHub repository. A native Swift project does not need a JavaScript monorepo manager. Use Xcode and Swift Package Manager to organize code where module boundaries provide value.

Suggested structure:

```text
release-manager/
├── ReleaseManager.xcodeproj/
├── Package.swift
├── Sources/
│   ├── ReleaseManagerApp/
│   │   ├── App/
│   │   ├── Features/
│   │   │   ├── Dashboard/
│   │   │   ├── Projects/
│   │   │   ├── Kanban/
│   │   │   ├── Releases/
│   │   │   ├── History/
│   │   │   └── Settings/
│   │   ├── DesignSystem/
│   │   └── Resources/
│   ├── ReleaseManagerCore/
│   │   ├── Models/
│   │   ├── Repositories/
│   │   ├── Services/
│   │   └── UseCases/
│   └── GitHubIntegration/
│       ├── Authentication/
│       ├── API/
│       ├── DTOs/
│       └── ReleaseWorkflow/
├── Tests/
│   ├── ReleaseManagerCoreTests/
│   ├── GitHubIntegrationTests/
│   └── ReleaseManagerUITests/
├── docs/
│   ├── PRODUCT_SPEC.md
│   ├── TECHNICAL_ARCHITECTURE.md
│   ├── DATA_MODEL.md
│   ├── DESIGN_SYSTEM.md
│   ├── IMPLEMENTATION_PLAN.md
│   └── decisions/
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── release.yml
├── .gitignore
├── README.md
└── LICENSE
```

This is a logical starting point, not a requirement to create a Swift package for every directory. Keep module boundaries small and purposeful.

### Repository conventions

- `main` should remain buildable.
- Use feature branches and pull requests for substantial changes.
- CI should build and test on macOS runners.
- Signing credentials must be stored as protected CI secrets when CI signing is configured.
- Never commit personal GitHub tokens, signing certificates, database files, or local project data.
- Version documentation alongside the implementation.
- Do not add Cloudflare configuration until a remote service is approved as part of the architecture.

## 10. MVP Scope

### Included

- Create, edit, archive, and search projects.
- Create releases using semantic or custom version strings.
- Configurable Kanban columns.
- Drag-and-drop tasks.
- Task priorities, types, labels, notes, and basic checklists.
- Local persistence and offline operation.
- GitHub authorization and disconnection.
- Repository browser and project-to-repository association.
- GitHub release and tag browsing.
- Commit and merged pull request retrieval.
- Deterministic changelog generation and editing.
- Creation of GitHub draft releases.
- Immutable local release snapshots.
- Light, dark, and system appearance.
- Basic translucent window material with an opaque fallback.
- Local export and backup/restore.
- Unit tests and CI build validation.
- Documentation for installation, authentication, backup, and recovery.

### Phase 2

- Advanced command palette and global shortcuts.
- Notifications and reminders.
- More advanced task-to-commit and task-to-PR linking.
- Multiple concurrent release branches.
- Richer audit history.
- Release templates and version suggestions.
- More configurable floating-window behavior.
- Better filtering and saved views.

### Later optional integrations

- AI-assisted changelog editing.
- GitHub Actions deployment status.
- App Store Connect.
- Remote synchronization.
- Cloud backup or sharing.
- Cloudflare Worker/R2 services if required by a confirmed remote feature.

## 11. Phased Implementation Plan

Every phase must end with a buildable application, passing relevant tests, updated documentation, and explicit acceptance criteria. Do not implement all phases in one large change.

### M00 — Technical Validation

Tasks:

- Inspect the development environment, Xcode version, SDKs, and minimum macOS target.
- Validate a minimal SwiftUI app with local persistence.
- Validate the intended GitHub App authorization flow end to end.
- Verify the minimum permissions for repository browsing, commits, pull requests, tags, and draft creation.
- Confirm token storage and refresh/re-authorization behavior.
- Prototype the desired translucent window behavior on the target macOS version.
- Document any architecture changes discovered during validation.

Acceptance criteria:

- A minimal native app builds and runs.
- Local data can be saved and restored after restarting.
- GitHub authorization is validated without embedding confidential credentials in the app.
- Required GitHub permissions are documented and minimized.
- Translucency works with a readable opaque fallback.
- Unresolved technical risks are documented before the next phase.

### M01 — Foundation

Tasks:

- Create the Xcode project and minimal Swift package boundaries.
- Establish project conventions, formatting, and build settings.
- Implement domain models and persistence repositories.
- Add initial schema/migration strategy.
- Add application navigation and design-system foundations.
- Implement typed errors and dependency injection.
- Configure GitHub Actions CI for macOS build and tests.
- Create initial unit tests and documentation.

Acceptance criteria:

- The application launches successfully.
- Project data can be saved and restored.
- Core logic can be tested independently of the UI.
- CI builds the application and runs tests.
- No credentials or personal data are committed.

### M02 — Projects and Kanban

Tasks:

- Implement project creation, editing, archiving, and search.
- Implement release-plan creation and editing.
- Implement configurable Kanban columns.
- Implement drag-and-drop with persistent ordering.
- Implement task editing, priority, type, labels, notes, and checklists.
- Add filters and useful empty states.
- Add local backup/export and restore.
- Test data integrity during moves, edits, and deletions.

Acceptance criteria:

- Users can manage projects and tasks entirely offline.
- Task ordering persists after relaunch.
- Tasks remain associated with valid projects and columns.
- Backup and restore work on a representative test dataset.
- UI supports loading, empty, and error states where applicable.

### M03 — GitHub Integration

Tasks:

- Implement GitHub authorization and Keychain storage.
- Implement account connection status and disconnection.
- Implement repository browsing and search.
- Associate repositories with local projects.
- Fetch releases, tags, commits, and merged pull requests.
- Implement pagination and API rate-limit handling.
- Cache remote data with synchronization timestamps.
- Handle expired credentials, permission errors, offline operation, and transient failures.
- Add mock-based tests and targeted integration tests.

Acceptance criteria:

- The user can connect GitHub and browse permitted repositories.
- A project can be associated with one or more repositories.
- Remote data is clearly distinguished from cached data.
- A failed refresh does not erase cached information.
- The app never logs tokens or authorization headers.
- API errors are displayed as actionable messages.

### M04 — Release Workflow and History

Tasks:

- Implement release preparation and validation.
- Allow the user to choose a target repository, tag, branch, and commit.
- Generate a changelog from commits and merged pull requests.
- Support editing and Markdown export.
- Detect existing tags and conflicting releases.
- Create a GitHub draft release with the reviewed tag, target commit, and notes.
- Reconcile ambiguous outcomes after timeouts before retrying.
- Detect or confirm publication on GitHub.
- Save immutable local release snapshots.
- Implement release history and links to GitHub.
- Add tests for duplicate requests, failed saves, conflicting tags, and external publication.

Acceptance criteria:

- A release can be prepared from local tasks and GitHub data.
- The target commit and release notes are visible before draft creation.
- The app creates a draft, not an automatically published release.
- Existing tags and ambiguous network outcomes are handled safely.
- The app does not report publication until verified.
- Release snapshots remain unchanged after source tasks are edited.
- Local history can be reconciled with releases published externally.

### M05 — Design Polish and Distribution

Tasks:

- Finish dashboard, project, Kanban, release, history, and settings views.
- Implement light, dark, and system appearance.
- Implement configurable accent color and translucent window settings.
- Add keyboard navigation and accessibility labels.
- Add a basic command palette or quick actions if scope allows.
- Test minimum supported and current macOS versions.
- Expand UI tests and error-state tests.
- Document installation, backups, recovery, and GitHub authorization.
- Prepare signing and notarization instructions.
- Add release build automation when credentials and distribution requirements are known.

Acceptance criteria:

- Core workflows are usable in both light and dark appearance.
- Translucency has a readable fallback.
- Core UI interactions are keyboard-accessible.
- Tests cover the most important end-to-end flows.
- A clean build and installation procedure is documented.
- Signing and notarization limitations are documented for the intended distribution method.

## 12. Testing Strategy

### Unit tests

- Version string handling.
- Release state transitions.
- Kanban ordering and task movement.
- Changelog grouping and Markdown output.
- Snapshot immutability.
- Persistence repository behavior.
- GitHub response decoding and error mapping.
- Retry and reconciliation logic.

### Integration tests

- SwiftData persistence and migrations.
- Keychain wrapper behavior.
- GitHub API client using mocked URLSession responses.
- Pagination and rate-limit behavior.
- Draft creation and subsequent reconciliation.
- Backup and restore.

### UI tests

- Create and edit a project.
- Create a release plan.
- Add and move a task.
- Connect a repository through a testable authentication boundary.
- Prepare a changelog and create a draft through a mocked service.
- Browse release history.
- Switch appearance and transparency settings.

Do not make ordinary CI tests depend on a real GitHub account. Use mocks for normal test runs and keep any live integration tests explicit, isolated, and opt-in.

## 13. Error Handling and Reliability

The app must account for:

- No network connection.
- GitHub API rate limits.
- Expired or revoked credentials.
- Insufficient repository permissions.
- Renamed or transferred repositories.
- Deleted or inaccessible tags and releases.
- Existing tag conflicts.
- Duplicate draft creation attempts.
- Timeouts after a remote operation may have succeeded.
- Local persistence failures.
- Migration failures and corrupted backups.

Use typed errors internally and actionable, non-technical messages in the UI. Preserve user-entered changelog text and local data when remote operations fail.

## 14. Cost Strategy

Target zero mandatory recurring infrastructure costs for personal use.

- Store source code in GitHub.
- Store project data locally.
- Use native Apple frameworks where practical.
- Use GitHub REST API directly from the app.
- Use GitHub Actions within the available free allowance.
- Do not run a permanent server for the MVP.
- Do not require Cloudflare Workers, D1, R2, or other hosted services.
- Do not require a paid AI API.
- Evaluate Apple Developer Program membership, signing, notarization, and distribution costs separately if public distribution is planned.

Free-tier allowances and distribution requirements may change; verify current official documentation before relying on them.

## 15. Security and Privacy

- Store GitHub tokens in macOS Keychain.
- Never embed private keys or confidential client secrets in the application.
- Request minimum permissions.
- Do not log tokens or sensitive authorization payloads.
- Keep local project data on-device by default.
- Clearly disclose any future synchronization or external processing.
- Avoid analytics in the MVP unless explicitly approved.
- Do not include repository contents or release notes in crash reports.
- Make disconnection revoke or remove locally stored credentials as appropriate.
- Provide a clear way to export and delete local project data.

## 16. Definition of Done for the MVP

The MVP is complete when all of the following are verified:

- Two or more projects can be created independently.
- Each project can contain release plans and tasks.
- Kanban state and ordering persist across relaunches.
- Local work continues without network access.
- GitHub authorization and repository browsing work with the validated permission model.
- Releases, tags, commits, and merged pull requests can be retrieved where permissions allow.
- A changelog can be generated, edited, and exported as Markdown.
- The app can create a GitHub draft using the reviewed tag and target commit.
- Existing tags and ambiguous network failures do not lead to unsafe or duplicate operations.
- Publication status is verified before the local history claims a release was published.
- Release snapshots remain immutable.
- Backup and restore are tested.
- Light/dark appearance and translucent-window fallback are usable.
- CI builds and runs the automated test suite.
- Documentation covers setup, GitHub authentication, backup, recovery, and distribution.

## 17. Instructions for Codex

Use this document as the project implementation plan.

Before changing code:

1. Inspect the repository and existing project state.
2. Inspect the installed Xcode version, SDKs, and available build tools.
3. Identify relevant existing code, conventions, and constraints.
4. Validate M00 technical risks before finalizing implementation details.
5. Create or update `PRODUCT_SPEC.md`, `TECHNICAL_ARCHITECTURE.md`, `DATA_MODEL.md`, and `DESIGN_SYSTEM.md` under `docs/`.
6. Create a concise decision log in `docs/decisions/` for significant architectural choices.
7. Identify gaps or contradictions and report them rather than silently inventing requirements.

During implementation:

- Work phase by phase in the specified order.
- Do not skip acceptance criteria.
- Do not implement future-phase features unless necessary for the current phase.
- Keep changes small and reviewable.
- Build and run relevant tests after each meaningful change.
- Do not claim a test passed unless it was actually run.
- Do not add paid services or cloud dependencies without approval.
- Do not embed secrets or personal credentials.
- Update documentation and the phase checklist as work progresses.
- If a technical blocker invalidates a decision, explain the evidence and propose the smallest viable adjustment before proceeding.

At the end of each phase, report:

- What was implemented.
- Files and modules changed.
- Build and test commands executed and their actual results.
- Acceptance criteria passed, failed, or blocked.
- Known issues and security considerations.
- Recommended next steps.

Do not attempt to implement the entire product in a single pass. The objective is a maintainable, secure, native macOS application delivered through small, verified increments.
