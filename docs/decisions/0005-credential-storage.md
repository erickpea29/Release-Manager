# 0005 — Credential storage

- **Status:** Accepted (validated in M00)
- **Date:** 2026-10-19

## Context

Tokens must live in Keychain only. macOS has two keychain implementations:
- **File-based:** ACLs tied to the code signature.
- **Data-protection:** needs an application-identifier or keychain-access-group entitlement, and therefore a provisioning profile.

## Decision

- A `CredentialStore` protocol with a Keychain implementation and an in-memory fake for tests.
- **MVP uses the file-based keychain** (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Move to the data-protection keychain (one query flag) when distribution signing with a provisioning profile is set up in M05. That requires a one-time re-login, or a migration that reads the old item and writes the new one.
- Credential values are wrapped in a `Secret` type whose `description`, `debugDescription`, and `Mirror` are redacted.
- The API client's `URLSession` is ephemeral with `urlCache = nil`, so auth responses and private payloads are never cached on disk.
- **One signing identity per bundle ID.** Development builds use the team identity via `Config/Local.xcconfig`.

## Evidence (M00 §2.3)

- File-based keychain round trip passes in a sandboxed app under both ad-hoc and Apple Development signing.
- A different binary with the same identity reads the item with no prompt.
- The data-protection keychain returns `-34018` without a profile.
- A signer change under one bundle ID blocks launch on a container consent dialog.
