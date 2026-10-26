# 0016 — Version suggestions and release checklists

- **Status:** Accepted (the owner chose these from the [roadmap](../ROADMAP.md))
- **Date:** 2026-10-26

## Context

**Version numbers.** Choosing them was guesswork: 0.0.1 was followed by 0.1.0, and 0.1.1 shipped new features. Relvora already sorts every change into release-note sections (breaking, features, fixes, and so on), so it can propose the Semantic Versioning answer.

**Checking steps.** The owner wants their own steps checked before every release, such as "test on a clean Mac", and wants the release to remember them.

## Decisions

### Version suggestion

No stored data; it is computed when shown.

1. **Rules** (`VersionSuggester`):
   - breaking changes raise the major version;
   - new features raise the minor version;
   - anything else, or nothing yet, raises the patch version;
   - a project without releases starts at **0.1.0**.
   - **Before 1.0**, breaking changes raise the minor version. 1.0.0 is offered as a choice, never forced.
2. **The changes are the release notes' sections** (`ChangelogGenerator.entries`):
   - pull request labels, including the owner's label rules in Settings;
   - Conventional Commits prefixes;
   - completed task types.
   - So labelling pull requests, or setting task types, improves the suggestion.
3. **The base is the latest stable release.** Candidates are the project's published plans and releases, and the published releases in the cached GitHub data. Prereleases and custom labels are ignored.
4. **Where it shows.**
   - **New Release Plan** starts with the suggested version and gives the reason. Patch, minor, and major are one click away.
   - **On a plan being prepared**, the Target section compares the plan's version with what its changes suggest and offers **Use x.y.z**. Using it also changes the tag, if the tag simply followed the version.
   - It is never applied without the user.

### Release checklist

1. **Per project.**
   - The owner's own steps (`ReleaseStep`): edited in the plan's **Release Checklist** section, reordered by dragging, or copied from another project.
   - Each plan stores the steps ticked on it (`ReleasePlan.completedStepIDs`). Renaming a step keeps its ticks. A deleted step's tick is ignored.
2. **Blocking.** Every step must be ticked before the draft is created (`ReleaseIssue.checklistIncomplete`, a blocking issue). Ticks can change only while the plan is planned.
3. **Kept with the release.**
   - The checklist with its ticks is frozen into the release snapshot when the draft is requested. It is also frozen when a release published outside Relvora is recorded.
   - Release History shows it. Later checklist edits don't change it.
4. **Storage.**
   - **Schema V5:** `ReleaseStepEntity` (cascade-deleted with its project) and an optional `completedStepIDs` on plans. A lightweight migration from V4, tested on `RelvoraV4.store`, a fixture frozen from the 0.1.1 schema with a project group.
   - The snapshot's checklist goes in its JSON payload, so snapshots need no schema change.
   - **Backup format 6** carries steps, ticks, and frozen checklists. Format 5 files restore without them, and 0.1.1 refuses format 6 files.

## Consequences

- Version numbers become a suggestion with a reason, not a convention to remember.
- A project with a checklist can't create a draft until its steps are ticked. A project without one works as before.
- Once a store has been opened by this version, 0.1.1 can't open it: schema V5 is newer. Export a backup before updating, as for 0.1.1.
