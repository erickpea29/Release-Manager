# Phase Status

| Phase | Status |
|---|---|
| M00 — Technical Validation | **In progress**: repository-level GitHub probe pending (owner: select repo in app installation) |
| M01 — Foundation | Not started (unblocked) |
| M02 — Projects and Kanban | Not started |
| M03 — GitHub Integration | Not started |
| M04 — Release Workflow and History | Not started |
| M05 — Design Polish and Distribution | Not started |

## M00 checklist

- [x] Inspect environment, Xcode, SDKs ([report §1](M00_TECHNICAL_VALIDATION.md#1-development-environment))
- [x] Choose minimum macOS target: **macOS 26** ([ADR 0003](decisions/0003-minimum-macos-target.md))
- [x] Minimal SwiftUI app with local persistence, restored after relaunch
- [x] SwiftData migration strategy validated on disk (lightweight + custom stages)
- [x] Token storage validated in a sandboxed, signed app (file-based keychain)
- [x] GitHub auth flow, permissions, refresh, and revocation researched in official docs
- [x] GitHub App registered; live device flow and secretless refresh PASS ([report §2.5](M00_TECHNICAL_VALIDATION.md#25-github-app-authorization-pass-auth-and-refresh--repository-probe-pending))
- [ ] Repository probe with granted access + draft-release semantics: needs the repository selected in the app installation
- [x] Translucency prototype (three modes plus Reduce Transparency fallback), verified programmatically
- [x] Visual readability check of translucency ([report §2.4](M00_TECHNICAL_VALIDATION.md#24-window-translucency-pass-visual-check-2026-10-21))
- [x] Architecture changes documented (ADRs 0001–0006, spec documents)
- [x] Unresolved risks documented ([report §4](M00_TECHNICAL_VALIDATION.md#4-open-risks-and-decisions-needed-before-m01))
