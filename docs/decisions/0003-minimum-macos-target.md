# 0003 — Minimum macOS version

- **Status:** Accepted (owner, 2026-10-21)
- **Date:** 2026-10-19

## Context

The plan requires testing on "the minimum supported macOS version and the current target OS" but does not name a minimum. The only test machine runs macOS 26.6. The spikes compile with a macOS 15.0 deployment target.

## Options

| | macOS 15 | macOS 26 (recommended) |
|---|---|---|
| Reach | Macs on Sequoia and later | Macs that run Tahoe |
| Visual design | Two looks: pre-glass on 15, Liquid Glass on 26 (automatic with the 26 SDK) | One look |
| Testability | Runtime/visual checks on 15 need a VM or CI-only runs. CI cannot judge readability | Everything testable on the dev machine |
| Code | `#available` branches for glass and newer SwiftUI/SwiftData APIs | None |

## Recommendation

**macOS 26.0** for the MVP. This is a personal tool developed and tested on 26, and the acceptance criteria require testing on the minimum version. Lowering the target later is possible but costs availability branches and a second visual QA pass. Going the other way (15 now, raise later) is cheaper only if older-Mac users are a confirmed requirement.

## Decision

**macOS 26.0** is the minimum. Use macOS 26 APIs directly, with no `#available` branches. The M00 spikes still target 15.0; they are throwaway and are not changed.
