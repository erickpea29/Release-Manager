# Release Manager

A native, local-first macOS app for planning software releases: projects, Kanban boards, GitHub release data, changelogs, GitHub draft releases, and an immutable release history.

**Status:** M00 (Technical Validation). No product code yet. See [docs/PHASE_STATUS.md](docs/PHASE_STATUS.md).

## Documentation

| Document | Purpose |
|---|---|
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Source plan: goals, scope, phases |
| [docs/PHASE_STATUS.md](docs/PHASE_STATUS.md) | Phase checklist and current status |
| [docs/M00_TECHNICAL_VALIDATION.md](docs/M00_TECHNICAL_VALIDATION.md) | M00 evidence, results, and open risks |
| [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md) | What the MVP does, plus open product questions |
| [docs/TECHNICAL_ARCHITECTURE.md](docs/TECHNICAL_ARCHITECTURE.md) | Modules, boundaries, concurrency, security |
| [docs/DATA_MODEL.md](docs/DATA_MODEL.md) | Local entities, state machines, migration strategy |
| [docs/DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md) | Appearance, materials, accessibility rules |
| [docs/GITHUB_APP_SETUP.md](docs/GITHUB_APP_SETUP.md) | Registering the GitHub App |
| [docs/decisions/](docs/decisions/) | Architecture decision records |

## Requirements (development)

- macOS 26 with Xcode 26.x (validated with Xcode 26.6, Swift 6.3.3, macOS SDK 26.5)
- No third-party tools or dependencies

Throwaway validation code lives in [`spikes/M00/`](spikes/M00/README.md).
