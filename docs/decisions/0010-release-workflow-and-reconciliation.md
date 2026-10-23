# 0010 — Release workflow: intent first, reconcile by reading GitHub

- **Status:** Accepted (M04). Amended by [ADR 0015](0015-publish-from-relvora.md): Relvora can also publish a draft, after a second confirmation.
- **Date:** 2026-10-22

## Context

M04 adds the app's only GitHub write: creating a draft release. M00 found that a draft does not create its tag and that GitHub accepts any number of drafts for the same tag (F13). The create request is therefore not idempotent, and a timeout leaves its outcome unknown. The plan also requires the following:
- Release history must never claim publication before it is verified.
- Snapshots must be immutable.
- Tasks must never be changed by a release.

## Decisions

1. **One workflow service in `RelvoraCore`.**
   - `ReleaseWorkflow` holds every state change of a release.
   - It talks to GitHub through a `ReleaseRemote` protocol. `GitHubIntegration` implements it with `GitHubReleaseRemote`; tests use an in-memory fake that mimics F13.
   - The pre-draft rules are pure functions (`ReleaseChecker`).
2. **Intent before the request.**
   - Before `POST /releases`, one transaction saves a `pending` snapshot (tasks, notes, tag, and SHA, frozen) and moves the plan to `reconciliationNeeded`.
   - If the app quits, the request times out, or the follow-up save fails, the plan stays in reconciliation, so the next step must read GitHub first.
3. **Compare-and-set on plan status.**
   - Workflow writes go through `ReleaseSnapshotRepository.record`, which requires the plan's stored status to equal the status the step expects. Otherwise it throws `outdated`.
   - Two concurrent attempts therefore cannot both send a create.
   - `ReleasePlanRepository.save` may only write `planned` or `cancelled`, and only over a `planned` plan, so an edit cannot overwrite workflow progress.
4. **Writes are sent once.**
   - `GitHubAPIClient` retries reads on 5xx, timeouts, and dropped connections. It never retries a write that may have reached GitHub.
   - A 401 (with a refreshed token) or a short `Retry-After` is repeated once, because GitHub rejects those before acting.
   - `GitHubReleaseRemote` classifies a failed create:
     - **unknown:** timeout, dropped connection, 5xx, or an unreadable response.
     - **rejected:** offline before sending, 4xx, or auth.
   - A rejected create discards the pending snapshot and returns the plan to `planned`. An unknown outcome leaves the plan in reconciliation.
5. **Reconciliation reads GitHub, matching on tag and target commit.**
   - A pending snapshot is matched to releases with the same `tag_name` and `target_commitish` (the SHA Relvora sent). If there are several, the oldest is linked and the rest are reported as duplicates to delete.
   - When nothing matches and the release list is complete, the pending snapshot is discarded and the plan is `planned` again. A truncated list is not taken as proof.
   - Only the user starts reconciliation of a pending create. Automatic checks run only for created drafts (publication), so a slow request can't race the check.
6. **Publication is verified, not assumed.**
   - The release must be published, its tag must equal the reviewed tag, and the tag must resolve (annotated tags followed) to the reviewed SHA.
   - Any mismatch moves the plan to `reconciliationNeeded` and shows both values. The user may then **Record as Published**, and history keeps the reviewed and the published tag and commit side by side.
7. **Snapshots are write-once records** (schema V3).
   - Content is frozen at the draft request (G2).
   - Lifecycle fields change only through `ReleaseSnapshot.applying`:
     - `pending` → `draftCreated` → `published` | `abandoned`
   - Each field is set once. The release URL is the exception, because GitHub moves the `untagged-…` page to the tag page at publication.
   - Published notes are stored separately, only when they differ (ignoring CRLF and trailing whitespace).
   - The store re-checks every transition.
8. **Releases published outside Relvora** are detected when a planned plan's tag already has a published release. **Record Published Release** stores GitHub's notes, tag, and commit, with the plan's tasks frozen at that moment (`origin = external`).
9. **No local cancel of a drafted plan.**
   - To abandon a draft, delete it on GitHub and choose **Check Publication**. The snapshot becomes `abandoned` and the plan returns to `planned` (then cancel or re-draft).
   - This keeps local history from disagreeing with GitHub. It differs from the M02 state diagram, which allowed cancel from `draftCreated`.

## Consequences

- No duplicate draft from Relvora's own retries. A request delayed past reconciliation can still land; the next pre-draft check sees that draft and blocks until it is resolved on GitHub.
- The only GitHub write is the draft. Tags are never created, moved, or deleted, and nothing is published by the app.
- Publication is detected when the user opens or refreshes the plan. There is no background polling.
- More states in the UI (pending, mismatch). Each has a single explained action.

## Evidence

- `ReleaseWorkflowTests` cover:
  - duplicate requests (concurrent and sequential);
  - a timeout with and without a created draft;
  - duplicate drafts on GitHub;
  - a failed save after creation;
  - a rejected create;
  - conflicting tags and drafts;
  - incomplete tasks;
  - an outdated review;
  - publication, a moved tag, a deleted draft, and an external release.
- `ReleaseAPITests` cover the create request body, single-send classification, 422 details, the 401 retry, and annotated tags.
- `ReleaseSnapshotStoreTests` cover store-level guards, backup, cascade, and the V2→V3 migration.
