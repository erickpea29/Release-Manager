# 0008 — A fresh ModelContext per repository operation

- **Status:** Accepted (M02)
- **Date:** 2026-10-22

## Context

M01's repository actor used one long-lived `ModelContext` and called `rollback()` when a transaction failed. M02's integrity tests caught a case where a rejected batch still left its changes in memory:
- A column rename was part of a batch that later failed an integrity check. The column read back as "Renamed".
- A completion flag set by a rejected save made a later integrity check pass when it should have failed.

`ModelContext.rollback()` did not undo property changes on already-fetched objects, so a later unrelated save could have persisted a rejected edit.

## Decision

- Every repository method creates its own `ModelContext(container)`, with autosave off. A write saves once at the end; on any error the context is simply discarded.
- The repository stays an `actor`, so writes are serialized. It no longer conforms to `ModelActor`, because it doesn't need a long-lived context.
- Integrity rules that span a batch (column membership, exactly one completion column, empty-before-delete) are computed from the batch itself, not read back from inverse relationships.

## Consequences

- Rejected operations cannot leak into later saves; this is covered by the atomic-batch and store-integrity tests.
- Slightly more work per call (creating a context), which is negligible at this data size.
- No cached objects are shared between calls. Callers always get fresh values.
