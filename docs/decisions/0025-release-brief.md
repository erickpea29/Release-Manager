# 0025 — Release brief with Apple Intelligence

- **Status:** Accepted. The owner asked for generative UI in the Releases view, for 0.2.5. They chose Apple's on-device model and a release brief. Narrows the "AI inside Relvora" non-goal in [PRODUCT_SPEC §5](../PRODUCT_SPEC.md#5-non-goals-mvp).
- **Date:** 2026-11-03

## Context

The Releases view shows a planned version as fixed sections: Pull Requests, Target, Tasks, Notes, Checklist, and Check. The owner wants it enhanced with generative UI: a part of the view composed for the version in front of them.

The facts that shaped the design:

- **Relvora's promises.**
  - It's local-first, with no hosted backend and no paid AI API ([IMPLEMENTATION_PLAN](../IMPLEMENTATION_PLAN.md)).
  - "Relvora itself contains no AI" ([ADR 0018](0018-claude-creates-tasks.md)).
  - Every GitHub write is confirmed by the user.
- **macOS 26 has Apple's Foundation Models framework:** Apple Intelligence's on-device model.
  - It needs no key, costs nothing, and makes no network request.
  - Guided generation streams Swift values (`@Generable`) as they're generated, so a view can grow as the model writes.
- **The model is small and not always there.**
  - Its context window is small, and it can get facts wrong.
  - It runs only on Apple silicon with Apple Intelligence turned on, and only once its model has downloaded.
  - CI runners don't have it.
- **The plan view already knows everything a brief needs:** the check's findings, the tasks, the release checklist, the selected commit's CI, and the open pull requests.
- **Options considered:**
  - **The on-device model**: chosen.
  - **The Claude API**: better writing, but it sends the plan to a service and needs a paid key.
  - **Claude Code over MCP**: Relvora would stay free of AI, but the panel would only change while a session drives it.

## Decisions

1. **The model composes; Relvora decides.** The brief is a fixed set of native components:
   - the verdict, headline, and summary;
   - the next step;
   - themes;
   - what needs attention;
   - progress.

   The model writes the headline, the summary, and the theme titles. It picks theme symbols from a list, groups the tasks into themes, orders the sections and the attention items, and picks the next step from the choices Relvora offers.
2. **The facts are Relvora's** (`ReleaseBriefComposer.facts`).
   - Every finding of the check becomes an attention item. So do the selected commit's CI, a newer commit whose CI passed, and up to four open pull requests into the release's branch.
   - Each item has a stable key (`commit`, `checklist`, `pr-15`…) and the action that deals with it.
   - **The verdict comes from their severities, never from the model:** *Not ready yet* (something blocking), *Almost ready* (warnings), or *Ready for a draft*.
3. **Everything the model returns is checked** (`ReleaseBriefComposer.resolve`).
   - Unknown task references, keys, sections, and symbols are dropped.
   - Each task appears once. Once the brief is complete, tasks the model left out are listed under "Other", so none is hidden.
   - Every attention item is shown, the most severe first. The model orders them only within a severity. Something blocking always comes before the themes.
   - The next step must be one Relvora offers. While something blocks the draft, it must be a blocking item.
   - Text is trimmed and length-capped.
4. **Actions are the plan's own:**
   - use a commit;
   - scroll to a section;
   - open on GitHub;
   - run the GitHub check;
   - start the draft, which checks GitHub again and opens the existing confirmation;
   - edit the plan.

   Their titles differ from the plan's buttons ("Go to Checklist", "Start the Draft…"), so each label names one button.
5. **On-device only.**
   - The model is `SystemLanguageModel.default`, with a new session for each brief and temperature 0.3. Relvora never asks for a server model.
   - The prompt is compact lines: at most 40 tasks, titles cut at 90 characters, the attention items, the checklist count, the selected commit's CI, and the choices.
6. **Streaming and rewriting.**
   - The first brief streams into view: the headline first, then the themes one by one.
   - When the facts change, the brief is rewritten after a one-second pause. The facts are fingerprinted (task titles and states, attention keys and severities, checklist count), so only real changes count.
   - A rewrite replaces the brief shown only once it's complete, so the brief never empties while the plan changes. The verdict, counts, and actions always show the current facts.
   - A failed write isn't retried for the same facts until **Write Again**.
   - Briefs are kept in memory only: never saved, synced, or backed up.
7. **Without the model, Relvora writes a standard brief.**
   - It has Relvora's own headline and a summary by task type, groups the tasks by type, and uses the most severe item as the next step.
   - A line says why there's no written brief: Apple Intelligence is off, the Mac isn't eligible, or the model isn't ready yet.
   - **Settings › Releases › Write release briefs with Apple Intelligence** is on by default. It's kept per Mac, not in backups.
8. **Code.**
   - `RelvoraCore` has the rules, as pure functions: the facts, the standard brief, `resolve`, the prompt, and the `ReleaseBriefWriter` protocol.
   - A new package module, `RelvoraIntelligence`, is the only code that imports FoundationModels: `OnDeviceBriefWriter`, and the `@Generable` `BriefDraft`.
   - The app has `ReleaseBriefModel` (what was written, per plan) and `ReleaseBriefSection`.
   - **Debug only:** `-RelvoraBriefWriter demo` streams a scripted brief that groups tasks by progress; `off` shows only the standard brief. UI tests launch with `off` unless they ask for `demo`, so they never depend on the Mac's Apple Intelligence.

## Consequences

- **Relvora now contains AI, but on-device only.** The plan never leaves the Mac, and there's no key or cost. PRODUCT_SPEC's non-goal now reads that way.
- **Only Apple silicon Macs with Apple Intelligence on get written briefs.** Other Macs get the standard brief, which has the same verdict, items, and actions.
- **The model's words can be wrong:** a headline can overstate. The verdict, counts, and buttons can't be, because they're Relvora's. The footer says who wrote the words.
- **Writing takes a few seconds and some energy for each real change.** The pause and the fingerprint keep it to changes that matter.
- **The brief is written in English,** like the rest of the app. A Mac whose language the model doesn't support gets the standard brief, with the model's error.
- **No schema, backup format, or GitHub permission change.**
- *Help writing release notes* ([roadmap](../ROADMAP.md)) can use the same module.

## Evidence

On 2026-11-03, with Xcode 27.2 (Swift 6.4.2), on macOS 26.6 with a Retina display:

- **Package tests:** all 269 pass, 19 of them new. 16 cover the brief's rules (the facts, the standard brief, `resolve`, the prompt and its limits); 3 read the model's output.
- **UI tests:**
  - The 3 new `ReleaseBriefUITests` pass: the demo writer's themes and headline, the next step scrolling to the checklist and the verdict changing once it's ticked, and turning briefs off in Settings.
  - The other 34 UI tests that ran also pass, including every release workflow and pull request test, now with the brief above their sections.
- **The release plan's accessibility audit found problems in the brief, now fixed:**
  - The audit caught text in mid-animation. Only the model's writing animates now.
  - The verdict's coloured icon shared the element with its words. They're separate elements now.
  - The progress meter had no role. The progress indicator carries the label and value now.
  - The themes grid had no description. It's labelled "Tasks by theme" now.
  - The test now waits for the prepared plan, as the release tests do.
- **The audit's other findings were on the Pull Requests list:** small captions, which `main` fails too on Xcode 27.2. That list now draws CI's icon as a separate element, uses full-strength text for numbers and readiness, and `.callout` for metadata and status. The audit passes.
- **CI found two problems on its small, slow runner:**
  - the brief moved a link under a click;
  - the CI watcher's first look could happen before CI was read, and then announced runs that had already finished.

  Both are fixed, and CI's full UI suite passed.
- **`swift-format lint --strict`** is clean, run with swift-format 6.2.3. Xcode 27.2's swift-format 6.4.4 can't read `.swift-format`, which lacks the new key `orderedImports.shouldGroupImports`.
- **Not yet done:** a brief written by the real model on an Apple Intelligence Mac.

## Addendum: release contents and live steps (2026-11-03)

The owner asked for generative UI like an agent's work card: a title written for the change, a commit graph with branch lanes, pending work faded, live steps with spinners, and a size chip. They chose both cards below, in the same PR.

1. **What's in this release**, a card below the brief.
   - **The title** is Apple Intelligence's: `changesTitle` in the draft, written from the commit summaries the prompt now lists (at most 20). Without a model, the plan's title.
   - **The graph:** the commits since the last release, newest first, at most 12.
     - `CommitGraph.layout` (RelvoraCore) gives each commit a lane, like `git log --graph`. A merge's second parent opens a branch lane, and lanes join where the branch started.
     - The branch name comes from the merge message ("Merge pull request #14 from octo/drafts" gives `drafts`).
     - Parents outside the commits shown lead to the last release, which closes the graph.
   - **Open pull requests** into the release's branch (not drafts, at most 3) wait above the newest commit, on a dashed line.
   - **The size chip**, "+557 −73" with GitHub's five squares.
   - **The data** comes from GitHub's compare response, which Relvora already read: each commit's `parents`, and the `files` with their additions and deletions. There's no new request or permission.
     - `RemoteCommit.parentSHAs` decodes as empty from older repository caches, and an empty list is drawn as a straight line.
     - `UnreleasedChanges.stats` is optional.
2. **Live steps** for GitHub work: checking, starting the draft, creating it, reading it, publishing, and checking publication.
   - **Each step is real work, in order.** For example, "Saving the notes", then "Checking tags, releases, and the version on GitHub", then "Reading the changes since v0.1.0".
   - **Each step shows as it happens:** pending, running with a spinner, then done or failed. The header shows the seconds so far.
   - **Finished work folds** behind its header ("Checked GitHub 1s · Ready for a draft"). Failed work stays open, with the reason.
   - **The draft and publish sheets** show the step in progress.
   - **Quiet reconciliations** (on opening a plan) show no steps.
   - **Not included:** watching the build after publishing. Relvora doesn't read GitHub Actions runs yet ([roadmap](../ROADMAP.md)).
3. **Accessibility.**
   - Each row's texts are separate elements: grouped rows were measured with their tinted chips and colored icons, and failed the contrast audit.
   - The graph is decoration (hidden from VoiceOver); the rows say the same things in words.

**Evidence:**
- **Package tests:** 280 pass (11 new). They cover lanes for straight, merged, and truncated histories, older caches, branch names from merge messages, the size bar, parents and stats from a comparison, and the commits in the prompt and title.
- **UI tests:** the 15 for releases, pull requests, error states, and the brief all pass, as does the release plan's accessibility audit. The 2 new ones cover the graph (with the demo GitHub's merged branch) and a failed step while offline.
