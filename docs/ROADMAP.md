# Roadmap

Feature ideas for Relvora that aren't built yet, chosen by the owner on 2026-10-26.

**How to use this list:**
- When work on an idea starts, add its branch or PR after it: `— in progress: PR #14`.
- When it ships, remove it. [PHASE_STATUS.md](PHASE_STATUS.md) keeps what shipped in each version.
- An idea that needs a decision gets an ADR in `docs/decisions/`, linked from here.

Sizes are rough: **S** is a few hours, **M** a day or two, **L** several days, with schema or workflow changes.

## Next up

Recommended first. With publishing, updates, and notifications already in Relvora, they close the release loop: merge when CI passes, release, watch the build.

- [ ] **Watch the build after publishing** (S–M)
  - After a release is published, the plan shows the GitHub Actions run live: building, notarizing, and the attached `Relvora-x.y.z.zip`.
  - It ends with a link to the release's files, or with the run's error.
  - Needs **Actions: read** on the GitHub App. The owner adds it; every installation accepts the new permission once.
- [ ] **Pull requests and CI in Relvora** (M), added by the owner on 2026-10-26 — in progress: branch `feature/pull-requests` ([ADR 0020](decisions/0020-pull-requests-and-ci.md))
  - Open pull requests with their CI, merged from Relvora once CI passed, and the latest commit whose CI passed offered for the release.
  - A notification when CI finishes. Needs **Checks: read** on the GitHub App.

## Claude

Added by the owner on 2026-10-26.

Claude Code already reads projects and creates tasks ([ADR 0018](decisions/0018-claude-creates-tasks.md)).

- [ ] **Claude Desktop** (S)
  - A small stdio bridge in the app bundle, so the Claude Desktop app can connect too.
- [ ] **Claude edits tasks** (S–M)
  - Also edit, move between columns, and complete tasks. Still no deletions and nothing on GitHub.

## Releasing

- [ ] **Hotfix next to a planned version** (L)
  - Ship 0.1.2 from an older commit while 0.2.0 is still being planned.
  - Today a project has one version in progress. This changes the Board and Backlog rules ([ADR 0012](decisions/0012-backlog-tab-and-version-board.md)), so it needs an ADR first.
- [ ] **Fix a published release** (M)
  - Edit the notes after publishing, mark a release as not the latest, or mark it broken with a reason.
  - Each is a GitHub write with its own confirmation. Release History keeps what was published and what changed.

## GitHub

- [ ] **Tasks linked to pull requests and issues** (M–L)
  - A card shows its pull request's status, and the task can move to Done when the pull request merges.
  - Linking: by number, or found from the branch name.
  - Needs **Issues: read** to import issues. Pull requests and their CI are already read ([ADR 0020](decisions/0020-pull-requests-and-ci.md)).
- [ ] **Import GitHub issues into the Backlog** (M)
  - Choose issues by label or milestone. The task keeps a link to its issue.
  - Part of the item above, but can ship on its own.
- [ ] **Several GitHub accounts** (M–L)
  - Personal and work accounts signed in at the same time, each repository connected through one of them.
  - Each account's tokens are stored separately in the Keychain.

## Groups

- [ ] **Group overview** (S–M)
  - One page per group: every project's next version, progress, and last release, plus the group's recent releases.
- [ ] **Release train** (L)
  - Several projects of a group released together, such as Web 0.4, API 1.2, and iOS 2.0, with one checklist and one combined history entry.
  - This is the second model from [ADR 0014](decisions/0014-project-groups.md), so it needs an ADR first.

## macOS

- [ ] **Menu bar icon** (S–M)
  - Versions in progress and drafts waiting, each one click from opening.
  - Can be turned off in Settings.
- [ ] **Shortcuts and Spotlight** (S–M)
  - App Intents: "Add a task to Relvora", "What's the next release of …".
  - Tasks and projects can be found in Spotlight.
- [ ] **Desktop widget** (M)
  - Progress of the next release of a chosen project, or of every project.
  - Needs a widget extension and a shared container.

## Once ruled out

[PRODUCT_SPEC §5](PRODUCT_SPEC.md#5-non-goals-mvp) left these out of the first version. The owner wants them listed too. Each needs a short decision, recorded as an ADR, before work starts, because it changes something basic.

- [ ] **Sync between Macs** (L)
  - Uses iCloud: the store would move to CloudKit-compatible SwiftData.
  - Today everything is local, by design.
- [ ] **Help writing release notes** (M)
  - A suggested summary of the changes, always shown for editing, never published without review.
  - Needs a decision on which service, and on what data leaves the Mac.
- [ ] **Time estimates** (M)
  - Rough sizes on tasks, and how much of a version is done by size, not only by count.
- [ ] **Task dependencies** (M)
  - "Blocked by" between tasks, shown on the Board and checked before a release.
- [ ] **App Store Connect** (L)
  - Upload builds and submit for review, beside the GitHub release.
  - Needs App Store Connect API keys, kept in the Keychain like the GitHub sign-in.
