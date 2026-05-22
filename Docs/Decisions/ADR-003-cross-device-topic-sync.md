# ADR-003: Cross-Device Topic Sync via Gateway Plugin Extensions

**Date:** 2026-05-22
**Status:** Accepted
**Decision makers:** Adam (product), Bee (coordinator), Q (builder), Kieran (reviewer), Mel (designer)
**Supersedes:** None
**Related:** Gate 2F Spec v2, ADR-002 (team-driven development)

---

## Context

BeeChat runs on macOS and iOS. Both connect to the same OpenClaw Gateway. Topics (the user-facing concept) are currently stored only in each device's local GRDB database. Creating a topic on Mac does not make it appear on iPhone. This is a fundamental usability gap — Adam expects the same topic list on both devices, like Telegram.

## Decision

**We will sync topics across devices using the gateway's existing `sessions.patch` and `sessions.pluginPatch` APIs.** The gateway becomes the authoritative source of topic state. Mac publishes topic metadata on every CRUD operation. iPhone derives its topic list from gateway session metadata.

### Key design choices:

1. **Mac is master.** Topic definitions flow Mac → iPhone only. iPhone does not write topic state to the gateway. This eliminates bidirectional sync complexity.

2. **Gateway is truth, iPhone is cache.** iPhone local state is always a cache of gateway state. On conflict, gateway wins. No last-write-wins, no timestamp comparison, no CRDTs.

3. **Use existing gateway infrastructure.** `sessions.patch` for labels, `sessions.pluginPatch` for metadata (archive status, project binding, topic ID). `sessions.list` for reads, `sessions.changed` for push notifications. No new gateway endpoints.

4. **Messages are shared automatically.** Same session key = same gateway conversation. No message sync layer needed.

5. **`pluginPatch` first, `patch` second.** On publish, metadata goes before label. If metadata fails, don't set label. Consistent partial failure over inconsistent partial success.

6. **Full re-list on change, not incremental.** For personal use (~20-50 sessions), full `sessions.list` refresh on every `sessions.changed` event is acceptable. Incremental handling is a future optimization.

7. **Reconcile on reconnect.** Mac republishes all topic state on `SyncBridge.start()`. This catches up any missed publishes from offline periods.

## Alternatives Considered

### A: CloudKit sync for GRDB
- **Pros:** Native Apple ecosystem, works offline
- **Cons:** Introduces a second sync transport (separate from gateway), requires Apple Developer paid account, CloudKit rate limits, not cross-platform if we ever add Android/web
- **Rejected:** Too much complexity for single-master use case. Gateway is already the sync transport.

### B: CRDTs (Conflict-free Replicated Data Types)
- **Pros:** Handles multi-writer concurrent edits, offline-first
- **Cons:** Massive over-engineering for one-master, one-client. CRDTs solve a problem we don't have.
- **Rejected:** Wrong tool for the job.

### C: Shared database (SQLite on network share)
- **Pros:** Simple concept
- **Cons:** SQLite over network share is unreliable. Requires both devices on same network. Doesn't work over Tailscale/mobile.
- **Rejected:** Fragile, not mobile-friendly.

### D: Full bidirectional sync from day one
- **Pros:** Most complete solution
- **Cons:** Adds conflict resolution, merge semantics, clock sync, test surface. Way more code. Not needed for Adam's use case (one device at a time).
- **Rejected:** Can add later if BeeChat becomes a saleable product. Start simple.

## Consequences

### Positive
- **Minimal new code:** ~150-200 lines across both apps. Using existing gateway infrastructure.
- **No new gateway endpoints:** Everything we need already exists.
- **Self-healing:** Reconcile on reconnect means offline periods don't cause permanent divergence.
- **Consistent with Telegram/Signal model:** Gateway is server, devices are clients. Users understand this.
- **Messages shared for free:** No extra work needed for conversation history across devices.

### Negative
- **iPhone cannot create topics.** Under the master-client model, iPhone can only chat in existing topics. This is a product limitation. Can add "Quick Chat" (local-only topics) or bidirectional sync later.
- **Gateway dependency for topic list.** If gateway is down, iPhone shows stale topic list. Offline banner already handles this.
- **`operator.admin` scope required on Mac.** If Mac client pairing fails or scopes are reduced, topic publishing silently breaks. Documented and verified.
- **Topic deletion requires gateway cleanup.** `pluginPatch(unset:true)` on delete. If this fails, ghost topics may appear on iPhone until next reconcile.

### Risks
- Client identity changes (e.g., iOS mode changed to "webchat") could silently break `sessions.patch` — mitigated by documentation
- Two Macs in future would need topic namespacing — logged as future concern
- Large session counts could make full re-list slow — mitigated by personal use scale (~20-50 sessions)

## References

- Gate 2F Spec v2: `Docs/Architecture/GATE-2F-CROSS-DEVICE-TOPIC-SYNC-v2.md`
- Team reviews: `Docs/Architecture/GATE-2F-V1-Q-REVIEW.md`, `GATE-2F-V1-KIERAN-REVIEW.md`, `GATE-2F-V1-MEL-REVIEW.md`
- Consolidated review: `Docs/Architecture/GATE-2F-V1-CONSOLIDATED-REVIEW.md`
- Gateway protocol docs: `/Users/openclaw/.local/lib/node_modules/openclaw/docs/gateway/protocol.md`
- Gateway plugin extensions: `/Users/openclaw/.local/lib/node_modules/openclaw/docs/plugins/hooks.md`