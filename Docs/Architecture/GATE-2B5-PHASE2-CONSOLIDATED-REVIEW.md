# Gate 2B.5 — Phase 2 UI Layer: Consolidated Review (v1)

**Date:** 2026-05-19
**Status:** Compiled — awaiting v2 spec revision
**Reviewers:** Q (Builder) ✅, Kieran (Adversarial) ✅, Mel (Designer) ✅

---

## Reviewer Verdicts

| Reviewer | Verdict | Blockers | Warnings |
|----------|---------|---------|----------|
| **Mel** | 🟡 NEEDS CHANGES | 4 | 13 |
| **Kieran** | 🟡 NEEDS CHANGES | 3 | 6 |
| **Q** | 🟡 NEEDS CHANGES | 4 | 10 |

**Total unique blockers: 7** (after deduplication)

---

## Blockers (Consolidated & Deduplicated)

| # | Issue | Sources | Impact | Fix |
|---|-------|---------|--------|-----|
| **B1** | `.sheet` + `.popover` on same view doesn't adaptively select based on size class | Mel B1, Q B1 | iPad gets wrong presentation; undefined behavior | Use single `.popover` with iOS 16.4+ compact adaptation, OR use `@Environment(\.horizontalSizeClass)` to conditionally present. Remove the dual-modifier approach. |
| **B2** | `archiveTopic()` ignores existing `TopicRepository.archive(topicId:)` method; reinvents with `save()` which overwrites stale in-memory data | Kieran B2, Q B2 | Data inconsistency: stale `unreadCount`, `lastMessagePreview` overwritten on archive | Use `persistenceStore.topicRepo.archive(topicId: id)` — existing method does surgical SQL UPDATE |
| **B3** | Archive undo toast uses `DispatchQueue.main.asyncAfter` — races with second archive, vanishes on navigation, VoiceOver-inaccessible | Mel B2, Kieran B3, Q W2 | Undo lost on navigation or re-archive; inaccessible to VoiceOver users | Replace with `Task` + `Task.sleep` that cancels on new archive or view disappear. Extend/remove timeout for VoiceOver. |
| **B4** | Import button shown on connection state, not actual candidate count | Mel B4 | Users see "Import" button, tap it, get empty sheet — feels broken | Load candidate count on connection change; only show button when count > 0. Or show button with empty-state in sheet. |
| **B5** | `saveBridge()` UNIQUE index conflict not handled in `importSelected()` — `ON CONFLICT(topicId)` doesn't catch `openclawSessionKey` conflicts | Kieran B1 | Crash / silent data skip on import when session already bridged | Pre-check via `fetchAllActiveSessionKeys()` in `importSelected()` before calling `saveBridge()`. On failure, rollback the topic too (not just `continue`). |
| **B6** | Exyte `ChatView` `.disabled()` propagates to all subviews including message list — offline composer approach doesn't work | Q W1 | Messages become unscrollable when offline | Use custom `inputViewBuilder` or Exyte's `showNetworkConnectionProblem(true)`. Don't use `.disabled()`. |
| **B7** | `unarchiveTopic()` selection logic wrong — checks `selectedTopicId == nil` instead of re-selecting the unarchived topic | Mel B3 | Undo doesn't restore selection; user has to find topic manually | Set `selectedTopicId = topic.id` on undo (matches user expectation) |

---

## Warnings (High Severity — Should Fix)

| # | Issue | Source | Fix |
|---|-------|--------|-----|
| **W1** | Dynamic Type detent handling is a comment, not a spec — `.height(220)` overflows at large accessibility sizes | Mel W1 | Add explicit size-class/Dynamic Type check; use `.medium` for `.xLarge` and above |
| **W2** | No filtering of cron/agent sessions from import list — `importCandidates()` has placeholder `true` | Mel W5 | Implement session filtering or at minimum filter known system patterns (luna-*, gav-*) |
| **W3** | VoiceOver can't use timed toast — 5-second auto-dismiss is inaccessible | Mel W6 | Check `UIAccessibility.isVoiceOverRunning`; extend or remove timeout for VoiceOver |
| **W4** | Reduce Motion handling incomplete — no spec for swipe animation, sheet presentation, row deletion | Mel W11 | Add explicit Reduce Motion handling for all animations |
| **W5** | Archive tint `.orange` contradicts architecture spec ("neutral") | Mel W3 | Change to neutral gray or app secondary tint |
| **W6** | iOS `List(selection:)` multi-select requires edit mode activation | Q W9 | Add `.environment(\.editMode, .constant(.active))` or use custom checkmark rows |
| **W7** | `importSelected()` bridge failure creates orphan topic with 0 message count | Q B4, Q Q5 | On bridge failure, delete the topic too; or clarify that `topic.sessionKey` still works for message loading |
| **W8** | Delete confirmation text "local messages" is ambiguous | Mel W4 | Rephrase: "This deletes this conversation and all its messages from BeeChat." |
| **W9** | `fetchAllActiveSessionKeys()` only returns "active" status bridges — non-active bridges missed | Kieran W5 | Return all statuses or add a separate check for non-active bridges |
| **W10** | Empty messages state placement undefined — where in view hierarchy? | Q W10 | Use `.overlay` on ChatView or replace ChatView entirely when empty |

---

## Warnings (Lower Severity — Defer or Accept)

| # | Issue | Source |
|---|-------|--------|
| Bootstrap race: user message may arrive before bootstrap completes | Kieran W1 |
| Sheet dismissal during in-flight creation | Kieran W2 |
| `TopicError` nested vs top-level style preference | Q W4 |
| `fetchAllActiveSessionKeys()` string literal for status filter | Q W5 |
| Dead code comment in `importCandidates()` filter | Q W6 |
| Double-archive is idempotent by accident | Kieran W6 |
| `fetchById()` should be documented as internal-only | Kieran W4 |
| No haptic feedback on archive/delete | Mel UX gap |
| No loading state for import candidates | Mel UX gap |
| No "Select All/Deselect All" in import sheet | Mel UX gap |
| No error summary for partial import failures | Mel UX gap |
| Toast visual design undefined (font, shadow, safe area) | Mel UX gap |
| Archive last topic → simultaneous toast + empty state | Mel UX gap |

---

## Resolved Design Decisions

| Decision | Resolution |
|----------|------------|
| `fetchById()` implementation | ✅ GRDB `fetchOne(db, key:)` works with Topic model (Q verified) |
| `createTopic(name:)` key generation | ✅ `topicRepo.create()` sets sessionKey before returning |
| `@MainActor` crossing in `importCandidates()` | ✅ Safe — GRDB dispatches to its own queue (Q B3, not a real blocker) |
| `topic.sessionKey` works for imported topics | ✅ Direct column on Topic model, doesn't need bridge for message loading |

---

## v2 Spec Changes Required

### Must Fix (Blockers)

1. **B1:** Replace dual `.sheet` + `.popover` with single `.popover` + compact adaptation or explicit size-class branching
2. **B2:** Rewrite `archiveTopic()` to use `persistenceStore.topicRepo.archive(topicId:)`
3. **B3:** Replace `DispatchQueue` toast timer with `Task` + `Task.sleep`, cancel on new archive/view disappear, VoiceOver-safe
4. **B4:** Only show import button when candidate count > 0 (or handle empty candidates gracefully in sheet)
5. **B5:** Pre-check `fetchAllActiveSessionKeys()` in `importSelected()`, rollback topic on bridge failure
6. **B6:** Replace `.disabled()` with custom `inputViewBuilder` or `showNetworkConnectionProblem(true)` for offline composer
7. **B7:** Fix `unarchiveTopic()` to re-select the unarchived topic (`selectedTopicId = topic.id`)

### Should Fix (High Warnings)

8. **W1:** Add explicit Dynamic Type detent handling
9. **W2:** Add session filtering for import candidates (even basic pattern matching)
10. **W3:** VoiceOver-safe toast timeout
11. **W4:** Reduce Motion spec for all animations
12. **W5:** Change Archive tint from `.orange` to neutral
13. **W6:** Add edit mode or custom checkmarks for iOS import multi-select
14. **W7:** Rollback orphan topics on bridge failure in `importSelected()`
15. **W8:** Rephrase delete confirmation text
16. **W9:** `fetchAllActiveSessionKeys()` returns all statuses
17. **W10:** Specify empty messages state placement (`.overlay` on ChatView)