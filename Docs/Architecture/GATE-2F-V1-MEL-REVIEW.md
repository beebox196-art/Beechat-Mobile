# Gate 2F Spec v1 — Mel (Designer) Review

**Date:** 2026-05-22
**Reviewer:** Mel (Designer)
**Spec:** GATE-2F-CROSS-DEVICE-TOPIC-SYNC.md (v1)

---

## Highlights

### H1 — The "Mac is master" model is clean and honest

This is the right call for v1. Adam confirmed it, and it removes an enormous amount of complexity. No merge conflicts, no last-write-wins ambiguity in the user's mental model. The rule is simple: topics live on Mac, phone is a reader. Good.

### H2 — Message sharing with zero extra work is elegant

Using the same session key so both devices see the same conversation history without any sync layer — that's the kind of design that makes me happy. No loading spinners, no "syncing…" banners for messages. It just works.

---

## Blockers (must fix)

### B1 — No loading state defined for topic list appearance

When a user opens the iPhone app, there's a moment between "app launched" and "sessions.list returned" where the topic list is empty or stale. The spec says:

> iPhone shows last-known topic state, updates on reconnect

But it doesn't define **what the user sees during that gap on first launch** (no cached state yet). If the list is blank for 1-3 seconds, that's a bad first impression. We need:

- A **skeleton/shimmer** for the topic list during initial load (first launch, no cache)
- A **pull-to-refresh** gesture on the topic list for manual sync (trust affordance)
- A subtle **"Updated just now"** or timestamp in the list header after a successful refresh

Without this, the iPhone feels broken on first open.

### B2 — Archive on Mac → topic vanishes on iPhone with no trace

The spec says:

> Archiving a topic on Mac removes it from iPhone topic list

But what if the user was mid-conversation on iPhone? They switch to Mac, archive the topic, come back to iPhone — the topic is gone, and they have **no way to find it or understand why**. There's no undo, no "recently archived" section, no explanation.

This needs at least one of:
- A **"Recently archived"** section at the bottom of the topic list (collapsible, shows topics archived in last 24h)
- A **toast notification**: "Topic archived from Mac" when a `sessions.changed` event removes a topic
- A **"Show archived"** toggle (the spec's future list mentions this implicitly but doesn't commit)

Silent disappearance is a trust-breaker. The user will think it's a bug.

---

## Warnings (should fix)

### W1 — Import flow removal may lose a mental model

The spec removes `ImportSessionsSheet` and `importCandidates`. I understand why — topics now arrive automatically, so there's nothing to "import." But the import sheet served a second purpose: **it was the place where the user first understood that Mac sessions and iPhone topics are connected.** Without it, the user opens the iPhone app and topics just… appear. That might feel magical, or it might feel like the app is doing things without their knowledge.

**Recommendation:** Replace the import sheet with a **first-run onboarding step**: "Your topics from Mac will appear here automatically." One screen, one dismiss. No flow, no decisions. Just expectation-setting.

### W2 — No empty state for first launch with no Mac topics

If Adam sets up the iPhone before creating any topics on Mac, the topic list is empty. The spec doesn't define what that looks like. A blank list with no guidance is the #1 cause of "I don't know what this app does" churn.

**Empty state should show:**
- A friendly illustration (bee/hive motif, consistent with app brand)
- "No topics yet" heading
- "Create a topic on your Mac to get started" subtext
- (Optional) A deep link or instruction: "Open BeeChat on your Mac → click + → New Topic"

### W3 — No sync status indicator

The spec assumes one-device-at-a-time usage, but real life is messier. Adam might have both devices open. He might be on a train with flaky cellular. The spec has no affordance for the user to know **whether the topic list is current**.

**Recommendation:** A subtle indicator in the topic list header:
- **Green dot + "Synced"** → last refresh was successful
- **Yellow dot + "Last synced 2m ago"** → stale but not ancient
- **No indicator** when fully fresh (<10s since last refresh)

This is not a banner or a toast. It's a small, calm status line. Informational, not alarming.

### W4 — No handling for "Mac archived while iPhone user is typing"

If Adam is typing a message on iPhone in Topic X, and the topic gets archived from Mac, what happens? The spec doesn't address this edge case. Options:

- **Block:** Show an alert "This topic was archived on Mac. Finish your message or it will be discarded." — disruptive but honest
- **Allow:** Let the message send. The topic reappears in the iPhone list briefly, then disappears on next refresh. Mac user can find it in archived. — less disruptive but confusing
- **Silent accept:** Message sends into the archived topic. Topic stays hidden on iPhone. — cleanest UX but feels like a ghost

My preference: **Allow + toast**. Let the message go through (it's just a gateway message on an existing session). Show a brief non-blocking toast: "Topic archived from Mac." The topic fades from the list on next refresh.

### W5 — iPhone topic creation removal feels premature

The spec removes local topic creation from iPhone entirely (Phase 3, item 3). I understand the "Mac is master" constraint, but this means **Adam can never start a new conversation on his phone.** That's a real limitation for "conversations on the go."

Even if topics don't sync back to Mac, a "Quick Chat" or "Local Note" mode on iPhone would let Adam capture thoughts without reaching for his Mac. The future list mentions this, but I think it should be a **Phase 2.5** item, not a someday-item:

- iPhone can create a local-only topic (not published to gateway, no session metadata)
- Labelled with a subtle "📱" badge to distinguish from synced topics
- When/if bidirectional sync is added, these get promoted to full topics

---

## Questions

### Q1 — What's the expected latency for `sessions.changed` events?

The spec says the iPhone receives `sessions.changed` events, but doesn't state an expected latency. Is this sub-second? 2-5 seconds? This matters for UX: if there's a 5-second delay, we need a different loading pattern than if it's instant.

### Q2 — Should the iPhone show the `projectPath` at all?

The spec stores `projectPath` in metadata and says "for display, not functional on iOS yet." But showing a file path like `/Users/adam/Projects/Topcon-Eval` on an iPhone screen is… not useful. It's too long, not tappable, and means nothing on iOS. Should we just **not show it** rather than show something that looks broken?

### Q3 — What happens if Adam has two Macs?

The spec assumes one Mac. But if Adam gets a second Mac (work laptop?), topics from both would flow to the same iPhone. Would that work? Would topics collide? This is a future concern but worth noting.

---

## Summary

| ID | Severity | Issue |
|---|---|---|
| B1 | Blocker | No loading state for first launch / initial topic fetch |
| B2 | Blocker | Archived topics vanish silently — trust-breaker |
| W1 | Warning | Import flow removal needs first-run onboarding replacement |
| W2 | Warning | Empty state not defined |
| W3 | Warning | No sync status indicator |
| W4 | Warning | No handling for archive-while-typing edge case |
| W5 | Warning | Local iPhone topic creation removed too early — consider "Quick Chat" |
| Q1 | Question | Expected latency for sessions.changed events? |
| Q2 | Question | Should projectPath be displayed on iPhone at all? |
| Q3 | Question | What happens with two Macs? |
| H1 | Highlight | "Mac is master" model is clean and honest |
| H2 | Highlight | Zero-work message sharing via shared session key is elegant |

The architecture is sound. The two blockers are both about **what the user sees and understands**, not about how the system works. Fix the empty/loading states and the archive-vanish problem, and this is a solid v1.

---

*v2 resolution: All blockers and warnings addressed in v2 spec.*