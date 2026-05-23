# Gate 2F Phase 1: Mel (UI/UX) Review

**Date:** 2026-05-22
**Reviewer:** Mel (UI/UX Designer)
**Spec:** GATE-2F-PHASE1-MAC-PUBLISHING.md
**Parent:** GATE-2F-CROSS-DEVICE-TOPIC-SYNC-v2.md
**Verdict:** ✅ PASS — No blockers. Two minor warnings, one question for clarification.

---

## Blockers

_None._ Phase 1 is genuinely backend plumbing with zero planned UI changes. Nothing here requires a design decision before proceeding.

---

## Warnings

### W1: Scope-missing UI warning contradicts "no UI changes" scope

The **Risks** table states:
> *"Mac client lacks `operator.admin` after re-pairing" → Mitigation: "Show warning in UI if missing."*

But the **Scope** section says:
> *"UI changes on Mac (no visible UI changes expected)"*

These contradict. If a scope-missing warning is planned, it's a UI change — however small — and needs design treatment (what does it say? where does it appear? does it dismiss?). If it's not planned, the risk table should say *"Log error, reconcile retries on reconnect"* instead.

**Recommendation:** Decide now. If scope-missing is truly "Low likelihood" and reconciliation catches it, I'd suggest removing the UI warning and relying on logs + reconnect. It's a rare failure case and the local DB remains correct. A toast saying "Topic sync unavailable" for something that self-heals in 99% of cases creates anxiety for no benefit.

### W2: Reconciliation loop runs synchronously on main thread risk

`reconcileAllTopicState()` iterates over all topics in a `for` loop:

```swift
for topic in topics where !topic.isArchived && !topic.isDeleted {
    publishTopicState(topic: topic, sessionKey: sessionKey)
}
```

Each call spawns a `Task`, so the RPC work is async. But the **loop itself** runs synchronously on whichever thread calls `reconcileAllTopicState()`. At ~50 topics, that's 50 iterations of `deriveSessionKey()` + struct construction + Task spawn. Likely sub-50ms total, but if this fires on the **main thread after reconnect**, and the topic count grows over time, it could cause a perceptible hitch on slower machines.

**Recommendation:** Wrap the loop in its own `Task` or dispatch it to a background queue. One line change, eliminates any risk of main-thread jank during reconnect:

```swift
Task {
    let topics = delegate.allTopics()
    for topic in topics where !topic.isArchived && !topic.isDeleted { ... }
}
```

### W3: `assert()` in production builds is silent

The debug assert validates topicId/sessionKey alignment:
```swift
assert(topic.id.lowercased() == sessionKey.split(...), "topicId does not match session key suffix")
```

Swift's `assert()` is compiled out in Release builds. If a mismatch somehow makes it to a production build, it silently passes. Not a UX problem per se, but if the assert is meant as a safety net, it should be a logged warning instead (or an additional `fatalError` for debug builds).

**Recommendation:** Add a `log.warning()` alongside the assert so mismatches are visible in production logs even without the assert firing. Low UX impact, good hygiene.

---

## Questions

### Q1: "Manual republish all button" as future option — should we design it now?

The spec mentions:
> *"Manual 'republish all' button as future option."*

If this is Phase 2 or later, I don't need to design it now. But if Adam wants it in Phase 2 as a settings escape hatch, I should note where it would live. Is this a real planned feature or just a risk-mitigation footnote?

### Q2: Offline period visibility on Mac

Phase 2 defines a sync indicator for iPhone ("Synced" / "Last synced X ago"). Does Mac need anything similar? Currently, if the gateway is offline and topics are created, the user on Mac has no indication that publishing hasn't happened yet. They see their topic created (local DB works fine), but wouldn't know it hasn't propagated.

For personal use, this is probably fine — local state is correct and reconnect fixes it. But it's worth confirming: **is zero offline feedback on Mac the intended UX?**

---

## Highlights

### H1: Fire-and-forget is the right UX choice for Phase 1

Silent failure on gateway publish is appropriate here. The user is performing a familiar operation (create/rename/archive/delete a topic) and it works exactly as before — locally. The gateway publish is invisible scaffolding. Showing spinners, retry dialogs, or "syncing" indicators would make the user feel like something is broken when it isn't. **Correct decision.**

### H2: Publish order (metadata first, label second) is user-invisible but architecturally sound

The spec explains why: metadata without label = usable (shows session key). Label without metadata = ghost topic iPhone can't identify. This means the worst-case failure state is a slightly ugly name on the Mac, not a broken experience on iPhone. Good priority ordering.

### H3: No regression exit criteria explicitly protect the existing experience

The exit criteria include:
> *"No regression: topic CRUD works identically when gateway is unreachable"*
> *"No regression: existing SyncBridge features unaffected"*

This is exactly the right bar for a Phase 1 that's supposed to be invisible. If Q and Kieran validate these, the UX is protected.

### H4: Phase 1 decisions are Phase 2-friendly

Phase 1's publishing model (metadata struct, session key format, gateway-wins pattern) sets up Phase 2's iPhone UX cleanly:
- Toast on archive → Phase 1 publishes `isArchived: true` to gateway, iPhone sees it via `sessions.changed`
- Empty state → Phase 1 ensures gateway reflects deletions, so iPhone can correctly show "no topics"
- Sync indicator → Phase 1's `updatedAt` timestamp enables "Last synced X ago"
- First-run onboarding → Phase 1's publishing means topics appear on iPhone after first Mac session, so onboarding text is accurate

Nothing in Phase 1 constrains or conflicts with any Phase 2 UX element defined in the parent v2 spec. **No lock-in concerns.**

---

## Summary

| Category | Count | Notes |
|---|---|---|
| Blockers | 0 | — |
| Warnings | 3 | W1: UI warning contradiction, W2: Main-thread loop, W3: assert in release |
| Questions | 2 | Q1: Republish button design, Q2: Mac offline feedback |
| Highlights | 4 | All positive — architecture supports good UX |

**Sign-off:** ✅ Phase 1 spec passes UX review. The three warnings are low-severity and don't block implementation. Q1 and Q2 are forward-looking and can be addressed during Phase 2 planning.

---

_Mel, 2026-05-22_
