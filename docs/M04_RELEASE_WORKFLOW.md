# M04 — Release Workflow and History Report

Status: **Merged** in PR #5 (fix in PR #6) · 2026-10-22. Live publication check pending the owner (§4)

## 1. What was built

| Area | Implementation |
|---|---|
| Release preparation | The **Releases** tab is now a plan list plus a detail pane. A planned release walks through **Target** (repository, branch, commit picked from the branch's latest commits or pasted, tag, and compare-from tag), **Tasks** (completion and column), **Release Notes**, and **Check and Create Draft** |
| Target commit | Stored as a full 40-character SHA and shown in full, with summary, author, date, and link. Tag defaults to `v<version>`; validated with Git's ref rules |
| Changelog | Deterministic generator from completed tasks (by type), merged pull requests (by label, then Conventional Commits prefix), and other commits. Sections: Breaking Changes, Features, Improvements, Bug Fixes, Documentation, Maintenance, Other Changes, plus a compare link. A task with the same title as a PR is listed once. Options for tasks, PRs, and commits. Warnings for open tasks, truncated or partial data, and no previous release |
| Editing and export | Markdown editor with Edit/Preview, autosaved (and flushed before any check or review); **Export…** to `.md` from the editor and from history. Regenerating asks before replacing text |
| Conflict checks | Read from GitHub before every draft: tag exists at another commit (blocking, tags are never moved), tag exists at the target (note, reused), a published release or a draft for the tag (blocking, with link), incomplete release list, version not newer than the latest release, tag/version mismatch, empty or over-long notes, open tasks |
| Draft creation | Confirmation sheet with the exact repository, tag, full SHA, branch, title, pre-release flag, and rendered notes. **Incomplete tasks need an explicit checkbox.** Creates a **draft only**; tasks are never changed |
| Ambiguous outcomes | Intent saved before the request; the create is sent once; timeouts, dropped connections, and 5xx leave the plan in **Needs reconciliation** until **Check GitHub** reads GitHub (links the draft by tag + commit, reports duplicates, or confirms none was created) ([ADR 0010](decisions/0010-release-workflow-and-reconciliation.md)) |
| Publication | **Check Publication** (also automatic when a drafted plan is opened) reports published only after the tag resolves to the reviewed commit. A moved tag or changed tag name shows *Reviewed vs. Published*, with **Record as Published…**. A deleted draft is kept as *Draft deleted* and the plan can be drafted again |
| External releases | A published release for the plan's tag, created on GitHub, is detected; **Record Published Release…** stores GitHub's notes, tag, and commit with the plan's tasks |
| Snapshots | Schema **V3**: write-once `ReleaseSnapshot` (tasks, notes as submitted, tag, SHA, repository, PRs) with set-once lifecycle fields; notes edited on GitHub kept beside the submitted ones |
| History | **Release History** (sidebar): every project's releases, newest first, with search and project filter. Detail shows facts, links (release, commit, tag, compare), notes (as published / as submitted), frozen tasks, and PRs. Dashboard cards show each project's last release |
| Data | Plans gain repository, tag, and compare base (V3, lightweight V2→V3). Backup **format 3** includes snapshots; formats 1–2 still restore |
| Debug | `-RelvoraDemoGitHub YES` runs the app against an in-memory fake GitHub (Debug builds only, compiled out of Release). `-RelvoraDemoScenario prepare\|review\|draft\|published\|mismatch\|timeout\|history` steps the first plan through the workflow for UI checks |

## 2. Verification

| Check | Result |
|---|---|
| `swift test` | **127 tests in 30 suites pass**; 2 opt-in tests skipped by design (live GitHub, fixture generator) |
| New: workflow (in-memory store + fake GitHub) | Draft request contents; snapshot frozen against task edits and deletion; **duplicate requests (concurrent and sequential) send one create**; timeout → reconciliation → draft linked; timeout with nothing created → planned, retry allowed; **duplicate drafts on GitHub** → oldest linked, others reported; **failed save after creation** → reconciled without a second create; rejected create changes nothing; **conflicting tag/draft blocks before any request**; tag at the target reused; incomplete tasks need confirmation and stay unchanged; outdated review refused; **publication verified only when the tag points at the reviewed commit**; moved tag → mismatch → accepted with both values kept; deleted draft → abandoned, re-draft works; **external release** detected and recorded |
| New: storage | Store guards: replayed transition, discard of a confirmed draft, stale status, and workflow states through plain plan saves are refused. Snapshots in backups (restore exact), cascade with project. **Real V2→V3 migration** of the frozen M03 store (`Fixtures/RelvoraV2.store`, generated from `backup-v2.json` before the schema changed) |
| New: GitHub client | Create body (`draft: true`, full SHA as `target_commitish`, no generated notes); **a failed create is sent once** and classified (502, timeout, dropped connection, unreadable 201 → unknown; offline, 403, 422 → rejected); 422 details in the message; 401 → refresh and resend once; reads retry dropped connections; annotated tags resolved, missing tag → nil; deleted release → nil; branches, single commits, changes up to a target commit filtered to the release branch |
| New: core rules | Changelog grouping, ordering, dedupe, breaking changes, options, warnings, label mapping; pre-draft findings; Git tag rules; SHA validation; snapshot transitions and notes normalization |
| Strict lint / builds | **0 findings**; Debug and Release builds with 0 warnings; Release binary contains no demo code |
| UI (demo GitHub, dark and light) | Screenshots of every state: preparation with generated notes, confirmation sheet (Create Draft disabled until incomplete tasks are confirmed), draft created, published and verified, mismatch with Record as Published, timeout needing reconciliation, Release History |
| Live GitHub, read-only (owner's repository) | On a **copy** of the dev store (`M04Verification`, migrated V2→V3 on first open with all 9 tasks intact; the original untouched): branches, latest commit `b9fdae8` (merge of PR #4), changes with **all 4 merged PRs**, generated notes, and the full pre-draft check with no conflicts. The confirmation sheet opened; **no draft was created** |
| CI | **PASS**: PR #5, run 39733811967 on `macos-26` (lint, 127/127 tests, 2 opt-in skipped, app build) |
| Live draft creation | **PASS** (with the owner's approval, on a copy of the dev store). Release id 420378956 on `erickpea29/Release-Manager`: a **draft**, marked pre-release. Tag `v0.0.0-relvora-test` (throwaway), target `05157e7…` (full SHA), body **byte-identical** to the snapshot's notes (605 bytes). **Exactly one** release for the tag, and the tag was **not created** (404). The plan and its snapshot are `draftCreated`, linked to the release ID. The first attempt stopped safely before review (F21); nothing was sent |

## 3. Acceptance criteria

| Criterion | Status |
|---|---|
| A release can be prepared from local tasks and GitHub data | **PASS** (tests, demo UI, live read-only) |
| The target commit and release notes are visible before draft creation | **PASS**: full SHA in the Target section and the confirmation sheet, with rendered notes |
| The app creates a draft, not an automatically published release | **PASS**: `draft: true` is the only write; no publish, tag, or delete calls exist |
| Existing tags and ambiguous network outcomes are handled safely | **PASS** (workflow and API tests; demo UI for the timeout state) |
| The app does not report publication until verified | **PASS**: published only after tag → SHA verification |
| Release snapshots remain unchanged after source tasks are edited | **PASS** (immutability test; store refuses content changes) |
| Local history can be reconciled with releases published externally | **PASS**: drafts published on GitHub are detected; releases created on GitHub can be recorded |

## 4. Live draft check (owner)

The draft `v0.0.0-relvora-test` (release 420378956) now exists. To finish the check, publish or delete it on GitHub, then choose **Check Publication** in the `M04Verification` store. To repeat the whole flow yourself:

1. Run the Debug app, open **Relvora › Releases**, choose the repository, commit, and tag, and generate notes.
2. **Create GitHub Draft…**, review, confirm. The plan shows *Draft on GitHub* with a link.
3. On GitHub, either publish the draft (this creates the tag) or delete it, then choose **Check Publication**. Published → verified in Release History; deleted → *Draft deleted*, plan planned again.

Tip: use a throwaway tag such as `v0.0.0-relvora-test` and delete the draft afterwards, so the repository keeps no test release.

## 5. Findings

- **F19: A task tied to a view's identity is cancelled when that identity changes.** `.task(id: plan.status)` cancelled the demo scenario mid-request when the status changed. User actions already run in their own tasks. A cancelled create classifies as *unknown*, so the safe path holds anyway.
- **F20: An unsynced repository has no compare base.** Preparation now syncs the repository snapshot (tags, latest release) when none is cached.
- F18 recurred: a sentence after a localized time (`12:17 a.m..`). The published text now puts the time at the end of its own line.
- **F21 — A skipped reload left stale target data.** Choosing a repository cleared the commit list and started a load. If the view's initial load was still running, the new load was skipped (an `isLoading` guard), and the old load later filled in its data. Seen live: the first scripted run found no commits and stopped before review, so nothing was sent. Fixed in PR #6: every branch or commit load has a generation, and only the latest one's results are applied.

## 6. Known issues and notes

- Changelog category mapping is built in; making it configurable in Settings is M05.
- Publication is detected when a drafted plan is opened or checked; there is no background polling.
- The branch picker lists up to 300 branches and the commit picker the branch's latest 30 commits; an older commit can be pasted by SHA (**Other…**).
- The commit list of a long range (over 300 commits) is truncated and flagged; PR lookup covers the newest 40 commits (ADR 0009).
