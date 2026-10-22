# 0009 — GitHub integration design

- **Status:** Accepted (M03)
- **Date:** 2026-10-22

## Context

M03 implements sign-in, repository browsing, and read access to releases, tags, commits, and pull requests. It builds on ADR 0002 (GitHub App, device flow, no backend) and the M00 live findings: refresh works without a secret, tokens rotate, and repositories must be selected in the installation.

## Decisions

1. **Module boundary.**
   - `GitHubIntegration` holds auth, the REST client, DTOs, sync, and the cache.
   - DTOs are internal; everything public is a `RelvoraCore` value (`GitHubRepository`, `RemoteRelease`, …), so the UI and M04 never see GitHub's JSON.
2. **API version pinned to `2022-11-28`.**
   - It is supported until 2028-03-10.
   - `2026-03-10` is current but has breaking changes, for example `merge_commit_sha` is removed from PR responses. Relvora doesn't need any of its additions.
   - Revisit before March 2028 or when a needed feature requires it.
3. **Configuration.**
   - The public client ID and app slug live in `Config/Shared.xcconfig` and are read from Info.plist.
   - A client ID is not a secret and must ship in the app.
   - No client secret or private key exists anywhere in the repository.
4. **Tokens.**
   - One Keychain item holds a JSON `TokenSet`: access token, refresh token, expiry dates, and account.
   - `GitHubSession` refreshes five minutes before expiry and once after a 401.
   - Concurrent requests share a single refresh, because refresh tokens rotate.
   - `bad_refresh_token` or an expired refresh token deletes the item and asks the user to reconnect.
   - The account is stored with the tokens, so connection status shows offline.
5. **Requests.**
   - GETs only in M03.
   - Transient failures (5xx, timeouts) retry twice with backoff, and a `Retry-After` of 5 s or less is waited out once.
   - Pagination follows `Link: rel="next"` only on the API host (the token is never sent elsewhere), with page caps that are reported as truncation.
6. **Unreleased changes.**
   - Computed as a compare from the latest published release tag (else the highest SemVer tag) to the default branch, newest first.
   - Merged PRs are looked up per commit for the newest 40 commits, to bound API use to about 50 requests per refresh.
   - Older commits are matched from merge or squash commit messages, and the snapshot records that the PR data is incomplete.
7. **Cache as JSON files, not SwiftData.**
   - One `RepositorySnapshot` per repository, stored under `Application Support/Relvora/GitHub Cache/`.
   - The cache is disposable, re-downloadable, and excluded from backups, so it doesn't belong in the versioned schema.
   - Only successful syncs are written, so a failed refresh never erases cached data.
   - This replaces the `CachedRelease`/`CachedTag` entities proposed in DATA_MODEL.
8. **Repository connections are user data** (schema V2, backup format 2). Identity is GitHub's numeric repository ID; owner, name, and branch are refreshed on each sync (`GET /repositories/{id}`), so renames and transfers are followed.

## Consequences

- No server, no secrets, and offline-safe UI: cached data is always shown with its age, and a failed refresh is explained.
- A refresh costs about 5 requests plus up to 40 PR lookups. That is acceptable against 5,000/h, but M04 must reuse snapshots instead of re-fetching.
- Disconnect only deletes local tokens; full revocation stays on github.com (ADR 0002).
