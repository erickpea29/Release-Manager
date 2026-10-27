# 0020 — Pull requests and CI in Relvora

- **Status:** Accepted (the owner chose the options on 2026-10-26).
- **Date:** 2026-10-26

## Context

The owner's day-to-day loop:
1. Claude Code builds a feature, pushes a branch, and opens a pull request.
2. The owner opens GitHub to wait for CI, then merges into `main`.
3. Back in Relvora, the owner picks `main`'s latest commit and creates the release.

Steps 2 and 3 meant going back and forth to github.com only to learn whether CI finished. The owner asked to see that in Relvora, and to choose the current `main` commit to release from there.

The owner chose:
- **where:** the release plan and the GitHub tab;
- **merging:** from Relvora, with a confirmation;
- **notifications:** yes, when CI finishes.

## Decisions

1. **Where pull requests show.**
   - **The release plan** (while planned), above **Target**: open pull requests into the plan's branch, and those merged into it in the last 3 days.
   - **The GitHub tab:** a **Pull Requests** section per repository, first and selected by default, with pull requests into every branch.
   - **The same list in both places** (`PullRequestList`). Each open pull request shows its branch, author, and CI ("CI passed", "CI running (1 of 2 done)", "CI failed: UI tests"). It also says whether it can merge, and has **Merge…** and a link to GitHub.
   - **A merged pull request** shows the commit the merge created and that commit's CI.
2. **CI is read from GitHub's check runs.** That covers GitHub Actions jobs and other CI that reports checks.
   - **A summary per commit (`CIStatus`):** none reported, running, passed, or failed. A failure shows as soon as one check fails, even while others still run. Neutral and skipped checks don't count as failures.
   - **New GitHub App permission: Checks (read).** The owner adds it, and each installation accepts it once ([GitHub App setup](../GITHUB_APP_SETUP.md)). Until then, the list says that Relvora needs it, and merging stays off (below).
   - **Not covered:** CI that reports only commit statuses. That would need the Commit statuses permission too.
3. **Merging is the only GitHub write outside releasing.**
   - **When Merge… is offered (`MergeReadiness`):** the pull request isn't a draft, has no conflicts, its CI passed (or the repository reports none), and GitHub says it can merge.
   - **Otherwise the row says why:** waiting for CI, CI failed, a draft, conflicts, behind its base, blocked by the branch's rules (such as a required review), or GitHub still checking. CI that Relvora can't read also keeps merging off.
   - **The confirmation sheet shows** the pull request, both branches, the head commit, its CI, and the method: a merge commit, squash, or rebase. The last method used is remembered on this Mac.
   - **Exactly what was shown is merged:** the head commit is sent with the merge. If the branch got new commits since, GitHub refuses (HTTP 409) and Relvora says so.
   - **GitHub's other refusals** (HTTP 405, for example a method the repository doesn't allow) are shown with GitHub's reason, and nothing changes.
   - **Sent once, like every write.** After a timeout or a dropped connection, Relvora reads the pull request to learn whether it merged.
   - **Permission:** merging uses **Contents (write)**, which Relvora already has for releases.
4. **The release's commit.**
   - **CI in the commit picker:** the plan reads CI for its branch's latest 8 commits and for the selected one. The picker shows each one's CI, and the selected commit shows its CI under its SHA.
   - **The suggestion:** the newest commit whose CI passed is offered with **Use abc1234, the latest commit whose CI passed** when another commit is selected.
   - **Never chosen for you:** the user still picks the commit.
   - **After a merge,** whether from Relvora or seen on GitHub, the branch's new commit loads into the picker. It's suggested once its CI passes.
5. **"CI finishes" notifications.** A fifth kind in **Settings › Notifications** ([ADR 0019](0019-notifications.md)), on until turned off.
   - **What's watched:** while Relvora is open, it checks every 2 minutes the repositories of versions being planned: the plan's repository, or the project's first one. That covers their open pull requests, and the latest commit of the plan's branch.
   - **Examples:** "#15 is ready to merge" (CI passed and Relvora would offer the merge), "CI passed on #15" with the reason it can't merge yet, "CI failed on #15", "main is ready for Relvora 0.2.3", and "CI failed on main".
   - **Each outcome is announced once per commit.** A check that is run again and passes is a new outcome.
   - **What had finished when Relvora first looked isn't announced.** That's the first time a repository's CI can be read: CI read before the Checks permission is added doesn't count.
   - **A click opens the project's Releases tab.**
6. **Nothing is saved.**
   - **Pull requests and CI are read from GitHub each time**, kept in memory (`PullRequestModel`), and shared by the views and the watcher.
   - **When they're refreshed:** when shown, every minute while shown and Relvora is active, and when Relvora becomes active.
   - **Finished CI is kept for 10 minutes** before it's read again (a check can be re-run). Running CI is read on every refresh.

## Consequences

- **No GitHub visit for the usual loop:** the owner sees CI, merges, gets notified when `main` passes, and releases the commit that passed, all in Relvora.
- **More requests while a version is planned.** Each check costs about 3 requests, plus about 2 per open pull request (whether it can merge, and its CI). That's a few hundred per hour at most, well under GitHub's 5,000.
- **Merging may need another permission.** A pull request that changes `.github/workflows` files may need **Workflows (write)**. Without it, GitHub refuses and Relvora shows its reason; merge that one on GitHub. The permission isn't requested, because it lets an app change workflows.
- **No schema, backup, or MCP change.** The merge method is a per-Mac setting outside backups.
- **Draft pull requests aren't read in detail.** They can't merge, so whether GitHub could merge them isn't asked.

## Evidence

- Package tests (10 new):
  - **CI and merging:** CI summaries, when merging is offered, recently merged pull requests, and the suggested commit.
  - **Notifications:** finished CI announced once, and their wording.
  - **The API:** listing, mergeability, check runs (including the 403 without Checks), and merging (the head SHA sent, a 405 refusal, a 409 conflict, and a timeout sent once).
- UI tests (2 new), on the demo GitHub (#16 passed, #17 running, draft #18 failed):
  - #16 is merged from the release plan, and main's new commit is used once its CI passes;
  - "#17 is ready to merge" and "main is ready for Relvora 0.2.0" are recorded, but nothing about CI that finished before Relvora looked;
  - the GitHub tab lists pull requests into every branch.
