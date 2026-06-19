# Gate 2B.5 Phase 2 UI Layer — Mel UX Review (v2 Spec)

**Date:** 2026-05-19
**Reviewer:** Mel
**Scope:** UX correctness, interaction gaps, accessibility, Phase 3 forward-fit
**Source reviewed:** `Docs/Architecture/GATE-2B5-PHASE2-UI-LAYER-v2.md`
**Cross-referenced:** `GATE-2B5-TOPIC-ARCHITECTURE-v2.md` (Mel M6-M14), `GATE2-SPEC.md` (Gate 2C), Exyte ChatView `InputViewBuilderClosure` signature
**Verdict:** NEEDS CHANGES (2 blockers, 7 warnings)

---

## Blockers

| # | Element | Issue | Recommendation |
|---|---------|-------|---------------|
| B1 | `inputViewBuilder` closure signature mismatch | The v2 spec's offline `inputViewBuilder` closure uses `($text, _, _, _, _, dismissKeyboard)` — 6 positional params. Exyte's actual `InputViewBuilderClosure` signature is `(Binding<String>, InputViewAttachments, InputViewState, InputViewStyle, @escaping (InputViewAction) -> Void, () -> Void) -> InputViewContent`. The spec's code will not compile because (1) the params are in the wrong positions (the 5th param is `inputViewActionClosure`, not `dismissKeyboardClosure`), and (2) the return type must be `InputViewContent` (a SwiftUI `Group` wrapper), not an `HStack` directly. Q will have to guess the correct wiring, which risks breaking the input bar's internal state management (attachments, input view state, action dispatch). | Rewrite the `inputViewBuilder` closure with the correct signature. The `inputViewActionClosure` must be wired or the input bar's internal state machine breaks. At minimum, the spec must show the correct parameter types and acknowledge `InputViewContent` as the return type. This is a build-blocker, not just a style issue. |
| B2 | Draft text preservation on offline transition | M10 explicitly requires "Preserve draft text in the composer" when going offline. The v2 spec has two completely separate `ChatView` instances — one for online, one for offline — behind an `if/else` on `connectionState`. When the connection drops, SwiftUI destroys the online `ChatView` and creates the offline one. The `@State private var draft: String = ""` in `BeeChatView` is local and will survive the switch, but the Exyte `ChatView` manages its own internal draft state, and when it's destroyed and recreated, any in-flight draft the user was typing is lost because Exyte's internal `InputView` state resets. The `@State` `draft` property is never bound to Exyte's input — it's only used as a placeholder in the spec code. | Move `draft` to a `@State` that is explicitly preserved across the online/offline switch, and on reconnection, feed the preserved draft back into the Exyte `ChatView`'s input. This requires either (a) using the `inputViewBuilder` on BOTH online and offline variants and managing draft externally, or (b) adding an `.onChange(of: viewModel.connectionState)` that captures the current Exyte draft before the view switch and restores it after. The spec must explicitly describe this preservation mechanism — it's a user-facing regression if someone is mid-sentence and the network drops. |

---

## Warnings

| # | Element | Issue | Recommendation |
|---|---------|-------|---------------|
| W1 | Popover frame on iPad | `.frame(minWidth: 320, maxWidth: 360, minHeight: 220)` is on `NewTopicSheet` itself, but on iPad, popover size is determined by the `.popover` attachment anchor and `presentationDetents`, not by the content's `.frame`. SwiftUI may ignore or fight with the frame. The M7 spec says "360 pt wide, ~220 pt tall" — this should be set via `.presentationSizing(.page)` or via `attachmentAnchor` + `frame` on the container, not directly on `NavigationStack` content. | Test on iPad simulator. If `.frame` doesn't size the popover, add `.presentationSizing(.page)` or wrap in a fixed-size container. Document the correct approach. |
| W2 | Toast timeout too short for non-VoiceOver | 5 seconds is aggressive for a non-VoiceOver user who is reading the topic name in the toast and deciding whether to undo. Reading "Archived 'Quarterly Business Review'" + making a decision + tapping Undo in 5s is tight, especially on a small screen where the thumb needs to reach the button. The v2 spec itself acknowledges this concern (reviewer prompt asks about 7s). | Change non-VoiceOver timeout from 5s to 7s. This is a modest increase that gives readers a comfortable window without making the toast feel sticky. 30s for VoiceOver is correct. |
| W3 | Import candidate count loading state | When the gateway connects, `refreshImportCandidateCount()` fires asynchronously. Between the connection event and the count arriving, `importCandidateCount` is 0, so the empty state shows "No conversations yet" (fresh install variant) even if importable sessions exist. The user might tap "Start a Conversation" before the import button appears. There's no loading indicator. | Add a `isLoadingCandidateCount` state. While loading, show the "No conversations yet" state but add a subtle progress indicator (e.g., a small `ProgressView()` near where the import button would appear, or a "Checking for sessions…" text). Alternatively, delay showing the empty state until the count is resolved (brief skeleton). |
| W4 | Empty state copy distinction | "No conversations yet" vs "No topics yet" — to a first-time user, the distinction between "conversations" and "topics" is unclear. The app just introduced topics. Why are some things conversations and others topics? | Use consistent terminology. Both states should use "topics" since that's the primary noun in the app. Suggested: Fresh install → "No topics yet. Start a topic when you're ready to chat with Bee." Import available → "No topics yet. BeeChat keeps your conversations organized as topics. Import your recent sessions to get started." The word "conversations" should only appear in explanatory text, never as a primary heading that the user needs to distinguish from "topics." |
| W5 | Archive last topic → toast + empty state overlap | When the user archives the last topic, `showArchiveUndo` becomes true and the overlay shows the toast. Simultaneously, `viewModel.topics.isEmpty` becomes true and `EmptyTopicsView` replaces the list. The toast is overlaid on the `VStack` containing the empty state. The empty state has `Spacer()`s that push content to center, so the toast should sit at the bottom without pushing the empty state up. However, if the empty state's bottom CTA buttons are near the bottom of the screen, the toast will overlap them. The 44pt button targets become harder to tap. | Either (a) add bottom padding to the empty state when `showArchiveUndo` is true (push CTAs up), or (b) ensure the toast has a higher z-index and a tap-through passthrough (which SwiftUI overlays do by default, but a 44pt+ toast still obscures targets). Simplest fix: add `.padding(.bottom, 60)` to `EmptyTopicsView` when `showArchiveUndo` is true. |
| W6 | Import sheet empty state — when does it occur? | The v2 spec adds an empty state for "No sessions available" in the import sheet. But `importCandidates` is only fetched when `importCandidateCount > 0`, and the button is only shown when count > 0. The only way the sheet can show an empty list is if the count was > 0 when the button appeared, but by the time the sheet loads its detailed candidates list, the gateway returned 0 (e.g., network race, sessions expired). This is an edge case. | Keep the empty state (defensive UX), but document that it's a race condition handler. Also add a retry button in the empty state, not just static text. "No sessions available" + "Try Again" button that re-fetches candidates. |
| W7 | Reduce Motion table incomplete | The §4.3 table covers swipe reveal, toast, streaming, delete, and sheet/popover. Missing animations: (1) NavigationSplitView column animation on topic selection, (2) row insertion/removal animation when topics are created/deleted, (3) Exyte message bubble appearance animation, (4) keyboard avoidance animation, (5) `ConnectionStatusView` state change animation, (6) empty state crossfade when transitioning from list to empty. | Add rows for at least (1), (3), and (6). Row insertion can use system default ( SwiftUI handles it). Exyte bubble animation is Exyte-internal and may not be controllable — note it as "Exyte managed, not configurable." Empty state crossfade should be `.opacity` under Reduce Motion (no slide/scale). |

---

## Additional UX Observations

### 1. Popover Adaptation on iPhone SE (B1 from reviewer prompt)

The `.popover(isPresented:)` with iOS 16.4+ compact adaptation works correctly — on compact size class (iPhone SE, all iPhones), iOS presents it as a half-sheet. The adaptation is automatic and reliable. No UX concern here.

However, the `.presentationDetents` code references a `dynamicTypeSize` property that is hardcoded to `.large` with a comment "Default; will be read from environment in implementation." This is a code smell — the dynamic type detection won't work until Q wires `@Environment(\.dynamicTypeSize)`. The spec should show this as `@Environment(\.dynamicTypeSize) private var dynamicTypeSize` on `TopicListView`, not a placeholder.

### 2. Dynamic Type Breakpoint (reviewer prompt question)

`.medium` for `.xLarge` is the right starting breakpoint. However, `.xxLarge` and `.xxxL` may need even more space. At `.xxxL`, a `.height(220)` sheet would definitely overflow. The `.medium` detent is flexible enough to handle these sizes since it adapts to content. The concern is: at `.xxLarge`+, the text field and buttons inside the sheet might need vertical padding to avoid clipping against the nav bar. 

**Recommendation:** Keep `.xLarge` as the threshold but add a note that at `.xxLarge` and `.xxxL`, the sheet should use `.large` detent (full sheet) because `.medium` may still clip with 2-line labels and a keyboard. This can be deferred to post-Gate 2B.5 with a TODO comment.

### 3. VoiceOver Labels Completeness (§4.1)

The label table is good but missing:
- **Empty state buttons:** "Start a Conversation" and "Import Recent Sessions" need explicit labels and hints in the table.
- **Character counter** (`0/80`): Should have a label like "0 of 80 characters" (the raw `0/80` is not meaningful to VoiceOver).
- **Offline text field:** "Reconnect to send messages" placeholder is not a label. VoiceOver reads the placeholder but the field should also have `.accessibilityLabel("Message input, currently offline")`.
- **Empty state icon** (`bubble.left.and.bubble.right`): Should be `.accessibilityHidden(true)` — decorative, not informative.
- **Import session rows:** Each row needs a VoiceOver label combining title, preview, and relative time.

### 4. NewTopicSheet `.onAppear` Auto-Focus

Using `.onAppear { isNameFocused = true }` works, but on iPad popover, `onAppear` fires when the popover's container appears, which may be before the popover animation completes. On some iOS versions, this causes the keyboard to appear before the popover is fully laid out, causing a visual jump. 

**Recommendation:** Add a small delay (0.3s) or use `DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)` before setting `isNameFocused`. This is a known SwiftUI popover timing issue.

### 5. `importSelected()` — No Feedback on Completion

When the user imports sessions and the sheet dismisses, there's no confirmation that the import succeeded. The topics just appear in the list (if the user notices). For a first-time user importing 5+ sessions, this feels uncertain.

**Recommendation:** After `importSelected()` completes, show a brief confirmation: either a toast "Imported N topics" or an auto-dismissing alert. A toast matches the archive undo pattern already in the spec.

### 6. Delete Confirmation Copy

The v2 spec uses: "This deletes this conversation and all its messages from BeeChat. This cannot be undone." The double "this" is awkward. 

**Recommendation:** "This conversation and all its messages will be permanently deleted from BeeChat. This cannot be undone."

### 7. Unarchive via `save()` vs `archive()` asymmetry

`archiveTopic()` uses the surgical `topicRepo.archive(topicId:)` (SQL UPDATE). `unarchiveTopic()` uses `topicRepo.save(topic)` with a mutated in-memory copy. The v2 spec justified this as using the existing method, but it introduces an inconsistency: archive is surgical, unarchive is a full save. If `Topic` has computed properties or the in-memory copy is stale, `save()` could overwrite concurrent changes.

**Recommendation:** Add `topicRepo.unarchive(topicId:)` as a surgical SQL UPDATE counterpart, or document why `save()` is safe here (e.g., the topic was just fetched, no concurrent writes possible on @MainActor).

---

## Phase 3 Forward-Fit Assessment

| Phase 3 Feature | v2 Data Model Support | v2 UI Structure Support | Notes |
|-----------------|----------------------|------------------------|-------|
| Pin topic | ✅ `isArchived` pattern exists; `isPinned` column or metadata is a straightforward addition | ⚠️ No leading swipe defined yet; `.sort` metadata not in model | M8 deferred pin correctly. Ensure `Topic` model can add `isPinned` without breaking `fetchAllActiveWithCounts()` query. |
| Rename topic | ✅ `Topic.name` is mutable, `save()` exists | ✅ Context menu placeholder documented | Deferred correctly. No structural blocker. |
| Pull-to-refresh | ✅ ViewModel has `importCandidates()` | ⚠️ `refreshable` modifier on List would need to trigger both session sync and topic refresh | Currently 500ms polling. Pull-to-refresh is additive. |
| ValueObservation | ✅ GRDB supports this | ⚠️ Switching from polling to observation changes how `topics` array is updated — need to verify no race with swipe actions | Deferred correctly. |
| Reorder topics | ✅ Can add `sortOrder` to Topic | ⚠️ List would need `ForEach` + `onMove`; current `List(viewModel.topics, id:)` doesn't support drag-to-reorder easily | Structure is compatible. |
| Topic search/filter | ✅ `Topic.name` is searchable | ⚠️ No search bar in current `NavigationSplitView` sidebar | Add `searchable` modifier. Compatible. |
| Multi-topic archive/restore | ✅ `archiveTopic(id:)` works per-topic | ⚠️ No batch mode; `archivedTopic` holds single topic for undo | Batch undo would need array. Not a blocker — can add later. |
| Connection state `.reconnecting` | ⚠️ Not in current model | ⚠️ `BeeChatView` only handles `.connected` vs "else" | The `else` branch catches `.reconnecting` but shows "Reconnect to send messages" which is misleading. Recommend adding a third state for `.reconnecting` that shows a spinner instead of the reconnect button. |

**Overall Phase 3 readiness:** The v2 data model and UI structure are well-positioned for Phase 3. The biggest forward-fit gap is the `.reconnecting` connection state, which the v2 spec lumps into the offline UI. This will need a distinct treatment in Gate 2C when actual send/receive is wired.

---

## Summary

### What v2 Gets Right

1. **B1 fix (popover):** Single `.popover` with compact adaptation is the correct SwiftUI pattern. Clean, no dual-modifier hack.
2. **B3 fix (toast):** `Task` + `Task.sleep` is structurally correct. Cancel-on-new-archive and cancel-on-disappear are both handled.
3. **B4 fix (import button):** Conditional visibility based on async count is the right pattern.
4. **B6 fix (offline composer):** `inputViewBuilder` is the right Exyte API. Message list stays scrollable.
5. **W5 fix (archive tint):** `.secondary` is correct — neutral, not alarming.
6. **W8 fix (delete copy):** Much clearer than "local messages."
7. **Reduce Motion table:** Good structure, even with gaps noted above.
8. **Import rollback on bridge failure:** Defensive, correct.

### What Still Needs Work

- **B1 (closure signature):** The `inputViewBuilder` code won't compile as written. Must be corrected before Q implements.
- **B2 (draft preservation):** The two-ChatView switch destroys Exyte's internal draft state. This is a user-facing data loss on network transitions.
- **W2 (toast timeout):** 5s is too short. 7s for non-VoiceOver.
- **W3 (import loading):** No loading state between connection and count arrival.
- **W4 (empty state copy):** "Conversations" vs "topics" is confusing terminology.
- **W5 (toast + empty state overlap):** Button targets obscured.
- **W7 (Reduce Motion):** Missing animations in the table.

---

## Verdict: NEEDS CHANGES

Two blockers must be resolved before Q can implement:
1. The `inputViewBuilder` closure signature must match Exyte's actual API.
2. Draft preservation across online/offline transitions must be explicitly designed.

Seven warnings should be addressed in a v3 spec revision. None are implementation-blocking, but W2 (toast timeout), W3 (loading state), and W4 (terminology) are high-value UX fixes that are cheap to specify now and expensive to patch later.