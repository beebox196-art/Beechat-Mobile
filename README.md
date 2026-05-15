# BeeChat Mobile

Native iOS client for BeeChat — iPhone and iPad — connecting to the same OpenClaw gateway as BeeChat v5 (macOS).

## Why This Project Exists

BeeChat v5 is solid on Mac but ties Adam to the desk. Telegram fills the mobile gap but isn't BeeChat. This project builds a native iOS app that shares the same Core packages (BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge) but has its own UI layer optimised for touch, mobile navigation, and iOS conventions.

## ⚠️ Research-First Gate (READ FIRST)

**Before any build work:** Complete Phase 0 Prior Art Survey.
- See: `knowledge/Operations/RESEARCH-FIRST-FRAMEWORK.md`
- Research report required before code
- Reinvention timebox: 2 days max
- Track attributions: `knowledge/Operations/ATTRIBUTIONS.md`

---

## Quick Links
- [Status](./STATUS.md) — Current phase, blockers, priorities
- [Vision](./Docs/Vision/) — Goals and roadmap
- [Architecture](./Docs/Architecture/) — Technical design
- [Decisions](./Docs/Decisions/) — ADRs
- [History](./Docs/History/) — How we got here

## Structure
```
BeeChat-Mobile/
├── STATUS.md              # 30-second briefing (UPDATE THIS)
├── README.md              # This file
├── Docs/
│   ├── Vision/            # Goals, roadmap, mobile-specific vision
│   ├── Architecture/      # iOS architecture, shared packages, push
│   ├── Decisions/         # ADRs (platform choices, distribution, etc.)
│   ├── History/           # Development history, session summaries
│   └── Status/            # Build status, handoff notes
└── [Code folders]         # Xcode project, SwiftUI views, etc.
```

## Key Relationships
- **BeeChat v5** (`/Projects/BeeChat-v5/`) — macOS sibling. Shares Core Swift packages via Swift Package Manager local dependency. Same gateway, same DB schema, different UI.
- **OpenClaw Gateway** — Source of truth for all sessions and messages. Mobile client syncs from gateway, caches locally.
- **Next Gen BeeChat** (`/Projects/Next Gen BeeChat/`) — Godot-based future exploration. Separate project, separate goals.

## Key Decisions
- **macOS-first, iOS-ready** — v5 architecture was designed for this. Core packages are platform-agnostic by intent. Mobile adds iOS-specific UI + push notifications.
- **Same gateway, same truth** — No separate backend. Both clients sync from the same OpenClaw instance.
- **Clean separation** — This is a standalone project folder. No code changes to v5. Package reuse via SPM local dependency, not file sharing.

## Getting Started
1. Read STATUS.md for current phase
2. Review BeeChat v5 Core packages (BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge)
3. Start Phase 0 research on iOS chat app patterns and push notification strategies

---
*Created 2026-05-12 from project template.*