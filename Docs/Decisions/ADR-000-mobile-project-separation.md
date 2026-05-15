# ADR-000: Mobile Project Separation

**Date:** 2026-05-12
**Status:** Accepted
**Context:** BeeChat v5 is the macOS client, reaching solid reliability. Mobile (iOS) is needed but must not contaminate v5's ongoing development.

**Decision:** Create `/Projects/BeeChat-Mobile/` as a standalone project. Core Swift packages (BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge) are shared via SPM local dependency pointing to v5's package directory. No code duplication, no shared mutable files.

**Consequences:**
- v5 team (Q) works freely without mobile concerns
- Mobile team works freely without breaking v5
- Core package changes propagate to both via SPM resolution
- Need discipline: Core package API changes require coordination
- Mobile project has its own STATUS, ADRs, build pipeline