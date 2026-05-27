# Gate 2B.5 Phase 1 v4.1 — Kieran Confirmation Review

**Reviewer:** Kieran (adversarial)  
**Date:** 2026-05-27T16:37Z  
**Spec:** GATE-2B5-PHASE1-DATA-LAYER-v4.md (v4.1)

---

## Blocker Re-Check

### B1: `fetchSessions()` filters out 0-token sessions
**Verdict: PASS**

v4.1 §2.3 (`didReceiveSessionChange` rewrite) explicitly uses `bridge.fetchSessionInfos()` — not `fetchSessions()`. The rationale names Kieran B1 directly. The §2.2 change in `connect()` also routes through `fetchSessionInfos()` → `reconcileFromGateway()`. The fix is correct and complete.

### B2: Duplication between `connect()` and `didReceiveSessionChange`
**Verdict: PASS**

v4.1 §2.4 extracts `reconcileFromGateway(_ sessionInfos:)` as a shared private method. §2.2 routes `connect()` through it, §2.3 routes `didReceiveSessionChange` through it. Both call sites use the same method. The shared method handles BeeChat filtering, topic creation, and list refresh. Metadata sync (`syncMetadataFromSessions`) remains separate in `connect()` only — this is correct because `SessionInfo` lacks preview/unread fields.

---

## Warning Re-Check

### W4: Orphan detection silently dropped
**Verdict: PASS**

Explicitly documented in §5 (Scope Boundary — Out of Scope): "Orphan detection … acknowledged as removed capability (Kieran W4)". Also present in §6 Risk Table item 5. No ambiguity — the reader knows this capability is gone.

### W6: Topic ID independence (different IDs per device, session key is canonical link)
**Verdict: FAIL**

The §11 review table claims W6 is "Documented in §4.5". **§4.5 is "macOS Regression"** — it contains two build checkboxes and zero text about topic IDs. No other section documents the assumption that Mac and iPhone generate independent topic UUIDs with the bridge (session key) as the canonical link. The fact that `reconcileFromGateway()` generates `UUID().uuidString` (§2.4, line 186) implies it, but it is not *documented* as an architectural assumption. A reader (or future implementor) has no explicit statement that topic IDs are device-local and session key is the cross-device link.

---

## Summary

| Check | Result |
|-------|--------|
| B1 resolved | ✅ PASS |
| B2 resolved | ✅ PASS |
| W4 acknowledged | ✅ PASS |
| W6 documented | ❌ FAIL |

## Overall Verdict: BLOCKED

One blocker resolved (B1). One recommendation resolved (B2). One warning acknowledged (W4). **One warning fails: W6 is claimed to be documented in §4.5 but is not there.**

**Fix required:** Add a dedicated subsection (e.g., §4.6 "Topic ID Independence") or expand the existing W6 row in §11 into a proper architectural note stating: each device generates its own `Topic.id` (UUID), topic IDs are NOT shared across devices, and the `sessionKey` via the bridge table is the canonical cross-device link. The §11 table cross-reference (§4.5) should be updated to point to the correct section.
