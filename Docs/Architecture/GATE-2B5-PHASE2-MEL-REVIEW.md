# Phase 2 v1 Review — Mel (Designer)

**Reviewer:** Mel (UX Designer)
**Date:** 2026-05-19
**File reviewed:** GATE-2B5-PHASE2-UI-LAYER-v1.md
**Reference spec:** GATE-2B5-TOPIC-ARCHITECTURE-v2.md (Mel M6–M14)

**Verdict:** NEEDS CHANGES

---

## Blockers

| # | Issue | M# Ref | Impact | Fix |
|---|-------|--------|--------|-----|
| B1 | `.sheet` and `.popover` both attached to same `isShowingNewTopicSheet` state — SwiftUI does NOT automatically pick the correct one by size class. On iPad, the `.sheet` modifier fires first (or both fire), resulting in a sheet instead of a popover. The spec claims "SwiftUI uses the correct one based on size class" — this is wrong. | M7 | iPad users get a bottom sheet instead of an anchored popover, breaking the spatial relationship to the `+` button | Use a single `.popover` with `.presentationCompactAdaptation` or use `UIScreen.main.traitCollection` to conditionally present. Correct pattern: one `.popover` modifier with `attachmentAnchor: .point(.center)` which automatically adapts on iPhone to a sheet via iOS 16.4+ compact adaptation. Alternatively, use `.sheet` on compact and `.popover` on regular via an explicit `@Environment(\.horizontalSizeClass)` check. |
| B2 | Archive undo toast uses `DispatchQueue.main.asyncAfter(deadline: .now() + 5)` — if the user navigates away (selects another topic, taps back) during the 5s window, the toast disappears and the undo is silently lost. The spec says nothing about what happens on navigation. | M8 | User archives a topic, navigates, comes back — topic is gone with no way to undo and no indication it was archived | Either: (a) persist the undo state so the toast reappears on return to TopicListView, or (b) cancel the timer on view disappear and accept the archive as final, or (c) use a proper undo pattern that doesn't depend on a 5-second timer visible on one screen. Recommend (b) with a brief "Topic archived" confirmation that doesn't need undo. |
| B3 | `unarchiveTopic(id:)` has a selection bug — the spec says "Re-select if it was previously selected" but then checks `if selectedTopicId == nil`. This means undo only restores selection if nothing else was selected, which is the normal case after archiving (since archiving auto-selects the first remaining topic). But the original archived topic's selection was already replaced. The undo should either: restore the topic to its original position and re-select it, or just restore it without re-selecting. The current logic is confusing and doesn't match what the user expects from "Undo". | M8 | Undo doesn't re-select the restored topic; user has to find it manually | Either: (a) re-select the unarchived topic (`selectedTopicId = topic.id`) to match user expectation of "Undo", or (b) explicitly document that undo restores the topic but doesn't re-select it. Option (a) is the expected UX. |
| B4 | `EmptyTopicsView` determines `hasImportableSessions` based on `viewModel.connectionState == .connected` — but being connected doesn't mean importable sessions exist. The gateway could be connected with zero sessions. The spec should check for actual candidate sessions, not just connection state. | M9 | Users see "Import Recent Sessions" button, tap it, get an empty import sheet — feels broken | Either: (a) load candidate count on connection change and only show the import button when count > 0, or (b) show the button but handle the empty case gracefully in the import sheet with an empty state message "No sessions to import." Option (a) is cleaner. |

---

## Warnings

| # | Issue | M# Ref | Severity | Fix |
|---|-------|--------|----------|-----|
| W1 | NewTopicSheet detent height `.height(220)` is a fixed pixel value. With Dynamic Type at accessibility sizes, the content (title, subtitle, text field, counter, toolbar) will overflow. The spec mentions "`.medium` detent for large accessibility sizes" as a comment but doesn't specify the implementation. | M6, M11 | High | Add an explicit size-class or Dynamic Type check: if `@Environment(\.dynamicTypeSize)` is `.xLarge` or above, use `.presentationDetents([.medium])` instead of `.height(220)`. This should be in the spec, not a comment. |
| W2 | The dirty draft discard alert text says "Your topic name will be lost." — this is fine, but there's no consideration for what happens if the user taps "Keep Editing" and then taps Cancel again. The sheet correctly re-shows the confirmation, but the flow isn't documented. | M6 | Low | Add a note: "Cancel with dirty draft always shows confirmation — no double-tap-to-exit pattern." |
| W3 | Swipe actions spec says Archive has `.tint(.orange)` — this conflicts with the Topic Architecture spec which says "neutral icon/tint" for Archive. Orange implies a warning, not a neutral action. | M8 | Medium | Change Archive tint to a neutral color (system gray or the app's secondary tint). Orange should be reserved for caution actions. The icon `archivebox` is neutral enough, but the tint sends a signal. |
| W4 | Delete confirmation text: "This permanently deletes the conversation and all local messages. This cannot be undone." — the word "local" is ambiguous here. Does it mean only messages stored on device, or does the gateway also lose the conversation? From the data model, `deleteCascading` deletes local records only. A user might think "local" means it's still on the server. | M8 | Medium | Rephrase to: "This deletes this conversation and all its messages from BeeChat. This cannot be undone." — clearer and doesn't make claims about server state. |
| W5 | The import sessions flow shows candidates with `session.title ?? session.customName ?? "Untitled"` — but the Topic Architecture spec (§5.3) says "human-readable titles only" and "Default selection: none unless high confidence the session is user-created." The Phase 2 spec doesn't implement any filtering of cron/agent sessions from the import list. `importCandidates()` has a placeholder `true // For now: show all sessions without topics`. | M9 | High | Implement session filtering before showing the import list. At minimum, filter out sessions that match known cron/agent patterns (e.g., sessions created by `luna-*`, `gav-*`, or system agents). Without this, the import sheet will show noise and confuse users. |
| W6 | The archive undo toast has no consideration for VoiceOver. A timed toast that auto-dismisses is inaccessible — VoiceOver users may not hear it before it disappears, and the Undo button may not be focusable in time. | M11 | High | For VoiceOver: the toast should remain visible until VoiceOver focus leaves it, not auto-dismiss after 5 seconds. Use `@Environment(\.accessibilityReduceMotion)` or check `UIAccessibility.isVoiceOverRunning` to extend or remove the timeout. |
| W7 | The `+` button accessibility hint "Creates a conversation topic" is good, but there's no accessibility hint on the swipe action buttons. VoiceOver users need to know what Archive and Delete do before activating. | M11 | Medium | Add explicit accessibility hints: Archive → "Archives this topic, removing it from the list", Delete → "Permanently deletes this topic and its messages, cannot be undone". These must be on the swipe action buttons, not just labels. |
| W8 | Topic row VoiceOver label is "Topic: {name}, {preview}, {time}, {unread}" — but the spec doesn't define what happens when preview or time is nil/empty. An empty topic (just created, no messages) would announce "Topic: Ideas, , , 0 unread messages" with awkward gaps. | M11 | Medium | Define conditional label: if no messages, "Topic: {name}, no messages yet". If no preview, skip it. If no unread, don't announce "0 unread". |
| W9 | The empty messages state in BeeChatView says "Ask Bee anything to get started." — this is the M12 first-launch text. But it will show every time a topic has no messages, not just on first launch. Is this intentional? A returning user opening a topic with no messages (e.g., they created it but didn't chat) would see this prompt again, which is fine — but the spec should clarify this is per-topic, not global first-launch. | M12 | Low | Add a note: "This empty chat prompt appears for any topic with no messages, not just on first use. This is intentional — it encourages the user to start chatting." |
| W10 | `NewTopicSheet` uses `TextField("Topic name", text: $name)` — a single-line field. But the Topic Architecture spec (§5.2) says "Single-line text field." What happens if the user pastes multi-line text? The `.trimmingCharacters(in: .whitespacesAndNewlines)` will strip newlines, silently joining lines. This could be surprising. | M6 | Low | Either: (a) accept it (most topic names are single-line), or (b) add a note that newlines in pasted text are silently converted to spaces. Option (a) is fine for MVP. |
| W11 | No Reduce Motion implementation detail beyond "static dots instead of animation" and "no slide animation, just appear/disappear" for the toast. What about the swipe action animation? What about the sheet presentation animation? What about the row deletion animation after archive? | M11 | Medium | Add explicit Reduce Motion handling: (a) swipe actions: no spring animation, instant reveal, (b) sheet: use `.transaction { $0.animation = nil }` or `.presentationTransition` with no animation, (c) row deletion: no fade/slide, instant removal, (d) archive toast: no slide-from-bottom, instant appear. These should be in the accessibility section, not left to implementation. |
| W12 | The offline banner uses `OfflineBannerView(onRetry:)` — but the spec doesn't define what "Retry" does in the topic list context. If the user taps Retry and reconnection succeeds, does the import button appear? Does the empty state change? The connection state transition effects on the UI aren't specified. | M10 | Medium | Add a note: "On successful reconnection: banner disappears, composer re-enables, import button appears (if candidates exist), pending topics reconcile. No explicit reload needed — ViewModel publishes state changes." |
| W13 | The import sheet shows "Import {count}" as the confirm button text. When 0 selected, it's disabled. But when many are selected, the button could say "Import 50" — that's a lot. There's no confirmation step after tapping Import. | M9 | Low | Consider: for >5 selected, show a confirmation "Import 12 conversations?" or add a brief success toast "Imported 12 conversations" after completion. Low priority for MVP. |

---

## M6–M12 Compliance

### M6: New Topic Sheet (iPhone) ✅ Mostly Compliant

| Requirement | Spec Coverage | Status |
|-------------|---------------|--------|
| `.presentationDetents([.height(220)])` | §3.3 | ✅ Specified |
| `.medium` for large Dynamic Type | §3.3 (comment only) | ⚠️ Not implemented, just a comment. **W1** |
| Title: "New Topic" | §3.1 | ✅ |
| Prompt: "What would you like to talk about?" | §3.1 | ✅ |
| Single-line text field, placeholder "Topic name" | §3.1 | ✅ |
| Character counter: `N/80` | §3.1 | ✅ |
| Cancel (leading), Create (trailing) | §3.1 | ✅ |
| Create disabled until trimmed name non-empty | §3.1 | ✅ |
| Keyboard auto-focuses | §3.1 `isNameFocused = true` onAppear | ✅ |
| Dirty draft discard confirmation | §3.1 alert | ✅ |
| On create: trim, save, dismiss, auto-select, navigate, focus composer | §2.1 auto-selects | ⚠️ "Focus composer" not specified — the spec says `selectedTopicId = topic.id` but doesn't mention focusing the chat composer after topic creation |
| On submit (return key): create if valid | §3.1 `.onSubmit` | ✅ |

**Gap:** "Focus composer" after topic creation is in M6 but missing from the Phase 2 spec. The ViewModel auto-selects the topic, but there's no spec for the chat view to auto-focus the input bar.

### M7: iPad Popover ⛔ Non-Compliant

| Requirement | Spec Coverage | Status |
|-------------|---------------|--------|
| Popover anchored to `+` button (regular width) | §3.3 claims both modifiers | ❌ **B1** — SwiftUI doesn't auto-select between `.sheet` and `.popover` |
| 360pt wide, ~220pt tall | §3.3 `.frame(minWidth: 320, maxWidth: 360, minHeight: 220)` | ⚠️ 320 min should be 360 min to match M7 |
| Falls back to iPhone sheet for compact width | §3.3 comment | ❌ Not implemented, just a comment |
| Minimum topic list width: 280pt | Not mentioned | ❌ Missing |

**This is a blocker.** The iPad presentation pattern is broken.

### M8: Swipe Actions ⚠️ Partially Compliant

| Requirement | Spec Coverage | Status |
|-------------|---------------|--------|
| Trailing swipe: Archive + Delete | §3.3 | ✅ |
| Full swipe = Archive (not Delete) | §3.3 `allowsFullSwipe: true` on Archive | ✅ |
| Archive: neutral icon/tint | §3.3 `.tint(.orange)` | ❌ **W3** — Orange is not neutral |
| Delete: destructive, trash icon | §3.3 `role: .destructive` | ✅ |
| Delete confirmation text | §3.3 | ⚠️ **W4** — "local" is ambiguous |
| Archive undo toast, 5s timeout | §3.5 | ⚠️ **B2** — Navigation edge case, **W6** — VoiceOver |
| Undo restores position and selection | §3.5 `undoArchive()` | ⚠️ **B3** — Selection bug |
| No leading swipe | §3.3 | ✅ (not present) |

### M9: Empty States ⚠️ Partially Compliant

| Requirement | Spec Coverage | Status |
|-------------|---------------|--------|
| Fresh install: "No conversations yet" + CTA | §3.2 | ✅ |
| Import available: "No topics yet" + both buttons | §3.2 | ⚠️ **B4** — Import button shown based on connection, not actual candidates |
| Import opens sheet with human-readable titles | §3.6 | ⚠️ **W5** — No filtering of cron/agent sessions |
| Import failure: non-blocking banner | §3.3 (not in §3.6) | ⚠️ Missing from ImportSessionsSheet spec |
| Default selection: none | §3.6 `selectedImportIds = []` | ✅ |

**Gap:** ImportSessionsSheet has no empty state or error state of its own. If candidates load but are empty, or if loading fails, what does the user see?

### M10: Offline/Error States ⚠️ Partially Compliant

| Requirement | Spec Coverage | Status |
|-------------|---------------|--------|
| Topic list usable offline | §3.3 (no `disabled` on list) | ✅ |
| Chat history readable offline | Not explicitly stated | ⚠️ Implicit, should be stated |
| Composer visible but disabled | §3.4 `.disabled(viewModel.connectionState != .connected)` | ⚠️ May not work with Exyte ChatView — spec acknowledges this |
| Placeholder: "Reconnect to send messages" | §3.4 | ⚠️ No implementation detail for placeholder text |
| Banner: "Offline. Showing cached messages." + Retry | §3.3 `OfflineBannerView` | ⚠️ **W12** — Retry effects not specified |
| Draft text preserved | §3.4 "Draft text preserved in composer (if possible with Exyte)" | ⚠️ Vague — "if possible" is not a spec |
| Send failure: inline retry on bubble | Not in Phase 2 spec | ❌ **Gap** — M10 specifies this but Phase 2 doesn't cover it |
| Partial failure: "Response interrupted" + Retry | Not in Phase 2 spec | ❌ **Gap** — M10 specifies this but Phase 2 doesn't cover it |

**Two M10 requirements are completely absent from Phase 2:** inline retry on failed bubbles and interrupted stream handling. These may be intentionally deferred, but the spec doesn't acknowledge the gap.

### M11: Accessibility ⚠️ Partially Compliant

| Requirement | Spec Coverage | Status |
|-------------|---------------|--------|
| VoiceOver labels on all interactive elements | §4.1 | ✅ Table provided |
| Connection indicator: text state, not just dot | §4.1 | ✅ |
| 44pt minimum hit targets | §4.2 | ⚠️ Spec says it but doesn't enforce or verify in code |
| Dynamic Type: topic rows scale | §4.2 | ✅ |
| Dynamic Type: sheet expands for large sizes | §4.2 | ⚠️ **W1** — Comment only, not specified |
| Reduce Motion: static dots | §4.3 | ✅ |
| Reduce Motion: toast no slide | §4.3 | ⚠️ **W11** — Incomplete, missing swipe/sheet/row animations |
| Swipe action accessibility hints | — | ❌ **W7** — Not specified |
| Topic row label handles nil/empty | — | ❌ **W8** — Not specified |
| Toast accessible to VoiceOver | — | ❌ **W6** — Timed toast is inaccessible |

### M12: First Launch ✅ Mostly Compliant

| Requirement | Spec Coverage | Status |
|-------------|---------------|--------|
| No walkthrough | Not present | ✅ |
| Empty topic list with "Start a Conversation" CTA | §3.2 | ✅ |
| After first topic: "Ask Bee anything to get started." | §3.4 | ✅ |
| Composer auto-focused after creation | — | ❌ **Gap** — Not specified |
| No coach marks | Not present | ✅ |

---

## UX Gaps

### 1. No haptic feedback spec
iOS users expect haptic feedback on destructive actions (delete confirmation), successful actions (topic created), and undo. The spec is silent on this. At minimum: success haptic on topic creation, error haptic on failed delete.

### 2. No transition animation spec between states
When the user creates their first topic, the empty state disappears and the topic list appears. What's the transition? Fade? Slide? Instant? This matters for perceived polish. A cross-fade between `EmptyTopicsView` and the `List` would feel smooth; an instant swap would feel jarring.

### 3. No loading state for import candidates
The `loadImportCandidates()` is async, but there's no loading indicator. `isLoadingCandidates` is set but never used in the UI. The import sheet should show a spinner or loading state while fetching sessions from the gateway.

### 4. No keyboard dismissal on scroll
In the import sessions sheet, the user might tap to search or interact, but there's no way to dismiss the keyboard by scrolling. Standard iOS pattern, but worth noting for the multi-select list.

### 5. Multi-select UX in import sheet is underspecified
`ImportSessionsSheet` uses `List` with `selection: $selectedIds` — but SwiftUI's `List` selection binding with `selection: Set<String>` creates an editing mode with checkmarks. Is this the intended UX? Or should it be `List` with toggle rows? The checkmark pattern is standard for multi-select on iOS, but the spec doesn't show it explicitly. Also: no "Select All" / "Deselect All" option.

### 6. No error state for individual import failures
`importSelected()` catches per-session bridge errors with `continue`, but the user gets no feedback if 2 out of 5 imports fail. They just see the 3 that succeeded. There should be a brief result summary: "Imported 3 of 5 conversations" or similar.

### 7. Empty messages state should differ by context
"Ask Bee anything to get started" works for a brand-new topic, but if all messages were deleted (edge case), the same prompt appears, which could be confusing. Minor for MVP, but worth a TODO.

### 8. No spec for what happens when topic list is long
With many topics, the `+` button stays in the toolbar (good). But what about pull-to-refresh? The spec defers it, but currently there's no way to manually refresh the topic list if polling (500ms) isn't working. The offline → online transition should trigger a refresh, but that's not explicit.

### 9. Archive undo toast visual design is undefined
The spec provides code for a `.regularMaterial` background with rounded corners, but no design spec for: font size, text color, button style, shadow, safe area handling, relationship to home indicator. Is this a floating toast or a bottom bar? The code suggests floating with padding, but the positioning relative to the bottom safe area isn't specified.

### 10. NewTopicSheet on keyboard dismiss
If the user taps outside the text field (but not on Cancel/Create), the keyboard dismisses. Should the sheet stay open? Yes, but the spec doesn't address this. Also: `.scrollDismissesKeyboard()` isn't specified for the sheet content.

### 11. Missing: What if user archives the last topic?
If there's only one topic and the user archives it, the list transitions from 1 topic → empty state. But the archive toast and the empty state transition happen simultaneously. The toast would appear on top of `EmptyTopicsView`. This should be handled: either suppress the toast when transitioning to empty, or show the toast briefly then transition.

---

## Summary

The Phase 2 spec covers most of the M6–M12 requirements but has four blockers and several warnings that need resolution before implementation:

**Must fix (Blockers):**
1. iPad popover presentation is architecturally wrong (B1)
2. Archive undo doesn't handle navigation or VoiceOver (B2, W6)
3. Undo selection logic is broken (B3)
4. Import button shown based on connection state, not actual candidates (B4)

**Should fix (High-severity warnings):**
- Dynamic Type detent handling is a comment, not a spec (W1)
- No filtering of cron/agent sessions from import list (W5)
- Reduce Motion handling is incomplete (W11)

**After fixes, this spec is close to implementation-ready.** The ViewModel logic is solid, the component structure is clean, and the M6/M8/M9 specs are mostly correct. The accessibility section needs the most work.