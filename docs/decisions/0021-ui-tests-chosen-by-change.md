# 0021 — UI tests chosen by what a change affects

- **Status:** Accepted (asked for by the owner on 2026-10-26).
- **Date:** 2026-10-26

## Context

The UI tests grew to 27 and take about 6 minutes on CI, plus build time. Each pull request ran all of them before it could be merged, even when it changed one feature. GitHub bills macOS minutes at 10× on private repositories.

The owner asked to run only the UI tests of the new feature, and those it can affect.

## Decisions

1. **A pull request runs only the UI tests its changes can affect.**
   - **The map:** `scripts/ui-tests-for-changes.sh` maps each changed path to UI test classes, or to single tests. For example, `App/Features/Board/` selects the Board tests and the Board and Backlog accessibility audits.
   - **What counts as changed:** the working tree, new files included, since the branch left `main`.
   - **Selecting nothing:** documentation, design files, spikes, and package tests can't change the app. When only those change, no UI test runs, and the job still passes.
   - **Selecting everything:** unmapped paths and app-wide files do, so new code is covered until it's mapped. App-wide files include the project and its settings, the app's scenes and menus, sample data, persistence, and models.
   - **UI test files:** a changed one selects itself.
   - **Changes to the CI workflow or the script** run one quick launch test, which shows the job still works.
   - **A test that no longer exists:** if a map entry names one, everything runs, rather than nothing.
2. **Pushes to main, and runs started by hand, run every UI test.** `main` is fully tested before a release. With Relvora's CI status ([ADR 0020](0020-pull-requests-and-ci.md)), the commit offered for a release is one whose full run passed.
3. **Locally, the same selection is run** with `-only-testing`, unless the owner asks for everything.
4. **A run that selects tests but runs none fails.** `xcodebuild` passes when `-only-testing` matches nothing, so CI reads the number of tests run from the result bundle.

## Consequences

- **Faster pull requests that change one area.** A change to the Board runs 4 of the 27 tests; a documentation change runs none.
- **Changes that touch many areas still run most tests.** This one, which added ADR 0020, changed the GitHub client, the demo GitHub, the release plan, settings, and notifications. It runs 23 of 27.
- **A failure the map misses is caught on main**, after the merge but before a release: `main` then shows failed CI in Relvora.
- **The map is kept by hand.** A new feature folder or UI test class should be added to it. Until then, a new folder selects everything, and a new test runs only when its own file changes.

## Evidence

- The script's cases were checked with fake change lists:
  - documentation and package tests only select nothing;
  - a Board view selects the Board tests and two audits;
  - a schema or an unknown path selects everything;
  - a renamed test in the map selects everything;
  - the CI workflow selects the launch test.
- On this branch it selects 8 of 10 classes, all but the Board and Claude tests. The 23 tests pass locally.
- **The zero-test check:** the first local run passed every selection as one argument (zsh doesn't split words). It ran no tests, and `xcodebuild` still reported success. That's why CI now checks the count.
