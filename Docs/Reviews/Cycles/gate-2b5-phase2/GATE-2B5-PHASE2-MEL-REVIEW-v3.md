# Gate 2B.5 Phase 2 UI Layer — Mel UX Review (v3 Delta)

**Date:** 2026-05-19
**Reviewer:** Mel
**Scope:** UX correctness of v3 delta changes, resolution of v2 blockers B1 + B2, warnings, new gaps, Phase 3 forward-fit
**Source reviewed:** `GATE-2B5-PHASE2-UI-LAYER-v3-DELTA.md` applied over `GATE-2B5-PHASE2-UI-LAYER-v2.md`
**Cross-referenced:** Exyte `ChatView.swift` (actual `InputViewBuilderClosure` signature), `GATE-2B5-PHASE2-MEL-REVIEW-v2.md`
**Verdict:** APPROVED (with 0 blockers, 4 warnings)

---

## Blocker Resolution Review

### B1: inputViewBuilder Closure Signature — ✅ RESOLVED

**v2 issue:** The closure used positional params `($text, _, _, _, _, dismissKeyboard)` that didn't match Exyte's actual API. Build-blocker.

**v3 fix:** The `OfflineChatView` now uses:
```swift
inputViewBuilder: { text, attachments, state, style, inputViewAction, dismissKeyboard in
```

**Verification against Exyte source** (`ChatView.swift:52-58`):
```swift
public typealias InputViewBuilderClosure = (
    _ text: Binding<String>,
    _ attachments: InputViewAttachments,
    _ inputViewState: InputViewState,
    _ inputViewStyle: InputViewStyle,
    _ inputViewActionClosure: @escaping (InputViewAction) -> Void,
    _ dismissKeyboardClosure: ()->()
) -> InputViewContent
```

| Param | Exyte label | v3 label | Match? |
|-------|------------|-----------|--------|
| 1 | `text: Binding<String>` | `text` | ✅ |
| 2 | `attachments: InputViewAttachments` | `attachments` | ✅ |
| 3 | `inputViewState: InputViewState` | `state` | ✅ |
| 4 | `inputViewStyle: InputViewStyle` | `style` | ✅ |
| 5 | `inputViewActionClosure: @escaping (InputViewAction) -> Void` | `inputViewAction` | ✅ |
| 6 | `dismissKeyboardClosure: ()->()` | `dismissKeyboard` | ✅ |

The parameter names are descriptive and correctly ordered. The return type `InputViewContent` is a generic `View` constraint — the `HStack` returned is valid.

**One concern:** The `inputViewAction` closure is not wired in the v3 code. Exyte calls this internally as `inputViewModel.inputViewAction()` and passes it to the builder so custom input bars can dispatch actions (e.g., `.recordAudioTap`). The offline input doesn't need any of these actions (it's disabled), so ignoring it is functionally correct. However, Q should be aware that if they later add attachment support to the offline bar, this closure needs to be called.

**Assessment:** ✅ Resolved. No build issue. The unwired `inputViewAction` is safe for the offline-only use case.

---

### B2: Draft Text Lost on Online↔Offline Switch — ✅ RESOLVED (with accepted limitation)

**v2 issue:** Two separate `ChatView` instances behind `if/else` destroyed Exyte's internal draft state on network transitions.

**v3 fix:** `preservedDraft: @State` on `BeeChatView` survives the sub-view switch. The online view clears it on successful send. The offline view shows it in the placeholder text: `"Draft: \"\(preservedDraft)\" — reconnect to send"`.

**Is this good UX?**

What the user actually sees when they lose their draft:
1. **Before disconnect:** User is typing "Can you summarise the Q3 report" in the Exyte input bar.
2. **Connection drops:** `OnlineChatView` is destroyed. `OfflineChatView` appears.
3. **What they see:** A disabled text field with placeholder `Draft: "Can you summarise the Q3 report" — reconnect to send` and a reconnect button.
4. **On reconnect:** `OfflineChatView` is destroyed. `OnlineChatView` appears with an empty input bar. The user must re-type their message.

**Assessment for M10:**

The visual approach is acceptable for M10 because:
- The user is **informed** their draft existed — they're not left wondering where their text went.
- The placeholder text is clear: "reconnect to send" tells them exactly what to do.
- The reconnect button is right there, one tap away.

However, the **loss of the actual text** on reconnection is a real friction point. The user must re-type from memory (or from reading the placeholder). For short messages this is fine. For long messages being composed when a brief network hiccup occurs, it's annoying.

**Why this is acceptable for M10:** Network transitions that occur mid-composition are relatively rare. The duration of an offline period is typically short (seconds to a minute). The placeholder preserves enough context to reconstruct the draft. The v3 delta explicitly acknowledges this limitation and identifies the future refinement path (using `inputViewBuilder` on both views for external draft management).

**Recommendation for post-M10:** When `inputViewBuilder` is added to `OnlineChatView`, `preservedDraft` can be bound as the initial text value, achieving true draft restoration. This is a 1-line change at that point. The current `preservedDraft` infrastructure makes this trivial.

---

## Warnings

| # | Element | Issue | Severity | Recommendation |
|---|---------|-------|----------|---------------|
| W1 | Toast timeout 7s — timing semantics | The v3 changes the non-VoiceOver timeout from 5s to 7s. Is 7s the right number? 7s is reasonable — it gives ~4s of reading time + ~3s of decision/reach time on a small screen. However, the spec doesn't clarify **when the timer starts**. Does it start when the toast appears (animation start) or when the animation completes? If the slide-up animation takes 0.3s, the effective visible time is ~6.7s. This matters because `withAnimation(.easeInOut)` on the toast means the timer and animation start simultaneously, but the toast isn't fully visible until the animation completes. | Low | Clarify: timer starts on `withAnimation` call (toast appears), so effective visible time is animation duration (~0.3s) + 7s = ~6.7s of fully visible time. This is fine. No code change needed, but add a comment in the timer code: `// Timer starts with animation; effective visible time ≈ 6.7s after animation completes`. 8s would be over-engineering — 7s hits the sweet spot between "too quick to read" and "lingering toast". |
| W2 | ProgressView in empty state — visual subtlety | The v3 adds `isLoadingCandidateCount` + a `ProgressView()` that appears after the CTA buttons in `EmptyTopicsView`. On a fresh-appearing empty state, a `ProgressView()` spinner below "Start a Topic" is fine — it communicates "checking for importable sessions." But the placement (after buttons) means it appears at the bottom of the view, possibly near the safe area. On small screens (iPhone SE), this could be very close to the bottom edge. Also, the spinner appears with no label — a VoiceOver user hears "loading indicator" with no context about what's loading. | Medium | Add `.accessibilityLabel("Checking for sessions")` to the `ProgressView()`. Optionally add a text label: `ProgressView()` + `Text("Checking for sessions…").font(.caption2).foregroundStyle(.tertiary)`. This helps both visual and VoiceOver users. The spinner should also be **above** the buttons (before CTAs), not after — a loading state should appear at the top of the information hierarchy so the user sees "still loading" before "take action." Otherwise the user may tap "Start a Topic" before the import button appears (the original W3 concern from v2). |
| W3 | "No topics yet" / "Start a Topic" — first-time terminology | The v3 unifies terminology to "topics" everywhere. "Start a Topic" replaces "Start a Conversation." For a first-time user who doesn't know what a "topic" is, this is slightly abstract. However, "conversation" was also abstract in a different way — the v2 used "conversations" for fresh install and "topics" for import-available, which was **worse** because it created an inconsistency. | Low | The v3's consistent use of "topics" is the right call. If the first-time meaning is unclear, the subtitle text handles it: "Start a topic when you're ready to chat with Bee." The word "chat" in the subtitle bridges the gap. No change needed. If user testing reveals confusion, a future iteration can rename to "Chats" (like iMessage/WhatsApp) but "topics" is defensible for the app's mental model. |
| W4 | `preservedDraft` placeholder escaping | The offline placeholder shows: `Draft: "\(preservedDraft)" — reconnect to send`. If `preservedDraft` contains quote characters (e.g., the user typed `He said "hello"`), the placeholder renders as `Draft: "He said "hello"" — reconnect to send`. The nested quotes are visually confusing and could look like a formatting error. | Low | Strip or replace double quotes in the placeholder display: `preservedDraft.replacingOccurrences(of: "\"", with: "'")`. Or use different delimiters: `Draft: 'He said "hello"' — reconnect to send`. This is a minor edge case — most users don't type literal quotes in message drafts — but the fix is trivial. |

---

## Additional UX Observations on v3 Changes

### 1. OnlineChatView + OfflineChatView Split (B1 fix)

The sub-view split is clean. By making each a concrete `View` struct, SwiftUI can correctly infer different generic types for `ChatView`. The coordinator pattern in `BeeChatView` is simple and maintainable.

**Minor concern:** `mergedMessages` is duplicated across both sub-views. This is ~20 lines of identical code. For Phase 2 this is fine, but if the merging logic changes (it will when Phase 3 adds real-time updates), both files need updating. Consider extracting a `StreamingMessagesMerger` helper in Phase 3.

### 2. `saveAndBridgeInTransaction()` — Atomic Import (B2 fix)

The transactional approach is correct. No orphaned topics, no deleted gateway messages. This is a significant improvement over v2's `deleteCascading()` rollback.

**One UX implication:** If the import fails due to a UNIQUE constraint (concurrent write from macOS BeeChat), the user gets no feedback — the session is silently skipped. The `count` returned from `importSelected()` increments only on success, so a toast "Imported 3 topics" when the user selected 4 would be confusing.

**Recommendation:** Track failures separately and surface them:
```swift
var failures = 0
// in the catch block: failures += 1
// After loop:
if failures > 0 && count > 0 {
    // Show: "Imported \(count) topics. \(failures) already existed."
} else if failures > 0 && count == 0 {
    // Show: "All selected sessions already have topics."
}
```

### 3. Archive Double-Guard (W8 fix)

```swift
guard !topic.isArchived else { return nil }
```

This is correct and defensive. Prevents a swipe-to-archive on an already-archived topic (edge case: slow UI update after a previous archive). No UX concern.

### 4. `@Environment(\.accessibilityVoiceOverEnabled)` (W6 fix)

Replacing `UIAccessibility.isVoiceOverRunning` with the SwiftUI environment value is correct. The UIKit call reads the value once at call time; the environment value reacts to changes (e.g., user enables VoiceOver while the app is running). This is a genuine accessibility improvement.

### 5. `.presentationDetents` + `.popover` Note (W1 fix)

The added note clarifying that detents apply only when the popover adapts to a sheet is helpful. Q will need to know this. No UX issue.

### 6. Delete Confirmation Copy (v2 W8)

The v2 spec already improved this from "local messages" to the current wording. The v3 doesn't change it further. My v2 review suggestion ("This conversation and all its messages will be permanently deleted from BeeChat. This cannot be undone.") is still better than the double-"this" construction, but this is a copy polish, not a blocker.

### 7. Toast + Empty State Overlap (v2 W5 → v3 W7)

The v3 adds `.padding(.bottom, showArchiveToast ? 60 : 0)` to `EmptyTopicsView`. Let me verify the math:
- Toast height: HStack with `.padding()` (default 16pt vertical) + `.padding(.bottom, 8)` + `.padding(.horizontal)` + content (~20pt text/button row) = ~44pt content + 32pt internal padding + 8pt bottom = ~52-56pt total from the bottom safe area.
- 60pt padding pushes the empty state CTAs up by 60pt, which gives ~4-8pt clearance between the toast and the buttons.

60pt is sufficient on standard devices. On devices with large bottom safe areas (iPhone with home indicator), the toast sits above the safe area inset, and the 60pt pushes CTAs above that. **This works.**

**One note:** The `showArchiveToast` parameter is now on `EmptyTopicsView`. This means `TopicListView` needs to pass `showArchiveUndo` through to the empty state. The v3 delta shows this in the code. Correct.

### 8. Empty State Icon Accessibility (W4 fix)

The v3 adds `.accessibilityHidden(true)` for the decorative icon. Correct — a `bubble.left.and.bubble.right` SF Symbol doesn't convey information beyond what the text already says.

---

## New UX Gaps Introduced by v3

### N1: No Loading State for Empty State Transition

When the user archives the last topic, the view transitions from the list to `EmptyTopicsView`. During this transition, `refreshImportCandidateCount()` fires asynchronously. Between the archive action and the count returning, `EmptyTopicsView` shows the fresh-install variant ("No topics yet" without import button). Then the import button appears. This causes a **visual jump** — the empty state layout shifts when the import button appears.

**Severity:** Low. The jump is brief (<1s typically) and the import button appearance is a positive event. But it's a layout shift that can feel jarring.

**Mitigation:** No code change needed for M10. If it's noticeable in testing, the `isLoadingCandidateCount` state can be used to show a skeleton/placeholder where the import button will appear, preventing the shift.

### N2: `OnlineChatView` Has No `preservedDraft` Input

When transitioning from offline back to online, the user sees an empty input bar. The `preservedDraft` is stored but not restored into the Exyte `ChatView`'s internal `InputView`. This is the accepted B2 limitation.

**Severity:** Already assessed above (B2). Acceptable for M10.

### N3: Sub-View `mergedMessages` Duplication

Both `OnlineChatView` and `OfflineChatView` contain identical `mergedMessages` computed properties. If one is updated and the other isn't, the streaming behaviour will differ between online and offline states.

**Severity:** Low for Phase 2 (streaming won't occur offline in practice). Will need extraction in Phase 3.

---

## Phase 3 Forward-Fit Assessment

| Phase 3 Feature | v3 Impact | Readiness | Notes |
|-----------------|-----------|-----------|-------|
| Pin topic | Unchanged from v2 | ✅ | Sub-view split doesn't affect pin — it's a List modification |
| Rename topic | Unchanged from v2 | ✅ | Context menu works on both sub-views |
| Pull-to-refresh | Unchanged from v2 | ✅ | Add `.refreshable` to List |
| ValueObservation | Unchanged from v2 | ✅ | Sub-views consume `messages` — observation can update the array |
| Reorder topics | Unchanged from v2 | ✅ | List-level concern |
| Topic search/filter | Unchanged from v2 | ✅ | Sidebar-level concern |
| Multi-topic archive/restore | Unchanged from v2 | ⚠️ | Toast still single-topic. Post-M10. |
| Connection state `.reconnecting` | **Improved by v3** | ✅ | The sub-view split makes adding a `ReconnectingChatView` trivial — just add a third branch in the coordinator |
| Draft restoration | **Infrastructure added by v3** | ✅ | `preservedDraft` + `inputViewBuilder` pattern established. Full restoration is a 1-step refinement |
| Transactional import | **Improved by v3** | ✅ | Atomic save supports concurrent writes. Phase 3 multi-device sync won't conflict |

**Overall Phase 3 readiness:** The v3 changes improve Phase 3 readiness in two areas:
1. The sub-view split makes adding a `.reconnecting` state trivial (add a third View, no refactoring).
2. `preservedDraft` infrastructure is in place for full draft restoration.

No v3 changes create Phase 3 regressions. The `mergedMessages` duplication should be extracted before Phase 3 adds real-time message updates, but that's a refactor, not a blocker.

---

## Verdict: APPROVED

**0 blockers.** Both v2 blockers are resolved:
- **B1 (inputViewBuilder signature):** Correct parameter names, correct order, matches Exyte's actual `InputViewBuilderClosure`. Build-able.
- **B2 (draft preservation):** Visual-only approach via `preservedDraft` placeholder is acceptable for M10. Infrastructure supports future full restoration.

**4 warnings** (none blocking):
- W1: Toast timer semantics (clarify in comment, no code change)
- W2: ProgressView placement and accessibility label (medium priority, easy fix)
- W3: "Topics" terminology (consistent, defensible, no change needed)
- W4: Quote escaping in preservedDraft placeholder (edge case, trivial fix)

**1 recommendation:** Track import failures separately and surface them to the user (N2 from observations — silent skip is confusing when `count` < selected count).

Q can implement from this spec. The v3 is a clean, build-able, UX-coherent design for Phase 2.