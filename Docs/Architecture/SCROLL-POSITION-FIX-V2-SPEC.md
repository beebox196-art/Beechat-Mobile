# Scroll Position Race Fix v2 — Spec

**Status:** DRAFT v1 — for Q (technical) + Kieran (architecture) + Mel (UX) review
**Author:** Bee (drafted 14 Jun 2026)
**Related:** Gate 2F (Cross-Device Topic Sync), Gate 2B5 (Real Data Pipeline)
**Build target:** `feature/gate-2b5-phase1-v4` (after async message-loading commit `4f88f0f` is verified)

---

## 1. Problem Statement

Since Gate 2B5 Phase 2 (initial TestFlight rollout), the iOS chat view has exhibited three persistent scroll-position bugs:

1. **White space at the bottom of the message list** — after opening a topic, a gap appears between the last visible message and the bottom of the input bar. The gap "fills in" after the user pauses or scrolls slightly.
2. **Wrong initial scroll position** — when opening a topic, the view sometimes renders in the middle of the message tree rather than at the most recent message. The user has to scroll down manually to reach the bottom.
3. **"Jump to bottom" button unreliable** — Exyte's built-in scroll-to-bottom button (visible when the user scrolls up) inconsistently appears and disappears.

These bugs were partially masked before Gate 2F because:
- All messages were in local GRDB at startup (no async load)
- The data was small enough that the layout race was sub-perceptual
- The iPhone-only test environment hid the issue that surfaces when topics are Mac-origin (iPhone starts with empty local cache and must fetch from gateway)

After Gate 2F added async message loading (`loadMessagesWithHistory`, `messageSyncVersion`, `syncAllTopicMessages`), the race became reproducible on every topic open. Adam reported it on 14 Jun 2026.

---

## 2. Root Cause Analysis

The bug is **not** in our SwiftUI bindings or `.onChange` handlers. It is in how **Exyte ChatView 2.7.10** handles async updates to its `UIList` (a `UIViewRepresentable` wrapping `UITableView`).

### 2.1 Exyte ChatView internal architecture

**File:** `.build/checkouts/Chat/Sources/ExyteChat/Views/UIList.swift` (Exyte Chat 2.7.10, pinned via `Package.swift exact: "2.7.10"`)

Key internals:

| Line | Mechanism | Behaviour |
|------|-----------|-----------|
| 27 | `UIList: UIViewRepresentable` | Wraps a `UITableView` |
| 65 | `tableView.transform = CGAffineTransform(rotationAngle: .pi)` (for `.conversation` type) | Rotates table 180° so newest message is at visual bottom |
| 50 | `@State var updateQueue = UpdateQueue()` (an actor) | Serialises async table updates |
| 87 | `func updateUIView(_ tableView: UITableView, context: Context)` | Called by SwiftUI on state change |
| 99 | `await updateQueue.enqueue { ... }` | Queues the update behind any in-flight one |
| 113 | `updateIfNeeded` | Three paths: empty prev → `reloadData`; non-empty prev → diff; no change → return |
| 195 | `if isScrolledToBottom || isScrolledToTop { ... apply inserts ... }` | **Critical gate** — inserts are only applied if user is at an edge |
| 616 | `isScrolledToBottom = scrollView.contentOffset.y <= 0` | Computed in `scrollViewDidScroll`; "at bottom" = contentOffset at or above 0 in rotated frame |

And in `ChatView.swift`:
- Line 142: `@State private var isScrolledToBottom: Bool = true` (initial value is **true**)
- Line 308: jump-to-bottom button shown when `!isScrolledToBottom`
- Line 393: tap posts `.onScrollToBottom` notification; observer at `UIList.swift:73` calls `tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: true)`

### 2.2 The race

When a topic is opened:

1. **`BeeChatView.onAppear`** fires → `loadMessages()` runs in a `Task` (async)
2. **Exyte's `UIList` is created** with `coordinator.sections = []` and `isScrolledToBottom = true` (initial value)
3. **`UITableView` is empty**, contentSize = 0, contentOffset = 0
4. **Async load completes** (10–500ms typical), parent re-renders, `OnlineChatView` is re-instantiated with new `messages` prop
5. **`UIList.updateUIView` is called** with non-empty `sections`
6. **`UpdateQueue.enqueue`** is called; since `coordinator.sections` is empty, the "empty prev" path runs (line 117): `coordinator.sections = sections; tableView.reloadData()`
7. **`reloadData()` fires** → `UITableView` discards all data and re-lays out from scratch with the new sections
8. **Critical timing window** — at this exact moment, `isScrolledToBottom` is still bound to the SwiftUI state value `true` (no scroll has occurred, `scrollViewDidScroll` has not fired). The button is therefore hidden.
9. **`UITableView` lays out** — for an iPhone screen with, say, 30 messages, the contentSize becomes ~3000pt. The previous contentOffset was 0. After layout, contentOffset stays at 0 (top of the rotated table = bottom of the conversation). This is **correct** in principle.
10. **BUT** — if the layout is still in progress (cells being dequeued, estimated heights resolving, etc.), `contentSize` and `contentOffset` are unstable. SwiftUI's `@Binding` for `isScrolledToBottom` has captured the pre-layout value `true`.
11. **`scrollViewDidScroll` fires** with the now-stable layout (could be tens to hundreds of ms later). It recomputes `isScrolledToBottom = contentOffset.y <= 0`. In most cases this is still `true`. But in cases where the scroll position is non-zero after layout (because the table settled at a different position than the binding captured), the value flips to `false`.
12. **User sees the white space** — the table is rendered, but visually anchored to a position that doesn't correspond to "fully scrolled to the bottom of the conversation". The button may or may not appear depending on whether step 11 flipped the value.

### 2.3 Why each symptom appears

| Symptom | Cause |
|---------|-------|
| **White space at bottom** | `UITableView` lays out with contentSize > visible area but contentOffset is not at the maximum. Visible cells are at the top of the new content (in rotated frame), empty space below. The "isScrolledToBottom" binding may show `true` (button hidden) or `false` (button shows), depending on whether `scrollViewDidScroll` has fired yet. |
| **Renders higher in the tree** | Same race, different outcome: when `reloadData` is called and contentSize is initially 0, the scroll position briefly "moves backwards" because there's nothing to scroll. When the new content lays out, the scroll position is interpreted relative to the now-larger contentSize, and can end up anchored at a position that's not the bottom. |
| **Button unreliable** | The button's visibility depends on `isScrolledToBottom` (line 308), which is bound to the SwiftUI `@State` from `scrollViewDidScroll`. Because `scrollViewDidScroll` doesn't fire on initial layout, the binding retains its initial value `true` until something explicitly causes a scroll. When the user scrolls slightly, the value updates, and only then does the button appear. |

### 2.4 Why this didn't show up before Gate 2F

- All messages were in local GRDB on startup (Gate 2A pattern: load from DB, render immediately, no async fetch)
- The iPhone was always the originating device for messages, so local was never empty
- Gate 2F added the gateway fetch path, which makes the iPhone start with empty local cache for Mac-origin topics
- The async `loadMessagesWithHistory` + `messageSyncVersion` is the new race trigger

### 2.5 The fundamental problem

Exyte's `UIList` assumes the SwiftUI `isScrolledToBottom` binding accurately reflects the table's actual scroll state. This is true **only after** `scrollViewDidScroll` has fired at least once. On initial layout (and on `reloadData`), the binding is stale.

The fix must address this disconnect: either force a state-resync after layout, or wrap Exyte's scroll behaviour with our own coordination.

---

## 3. Fix Options

### Option A: Force-resync after `reloadData` (surgical)

**Approach:** Subclass or wrap `UIList` to observe when the empty→non-empty transition happens. After the first `reloadData` on a non-empty `sections`, force a synchronous re-read of the table's `contentOffset` and update the `isScrolledToBottom` binding. Then explicitly `scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: false)` to anchor at the bottom.

**Implementation sketch:**
```swift
// In our OnlineChatView / OfflineChatView wrapper
struct ExyteScrollSyncView: UIViewRepresentable {
    @Binding var isScrolledToBottom: Bool
    let chatView: ChatView<...>
    
    func makeCoordinator() -> Coordinator {
        Coordinator(isScrolledToBottom: $isScrolledToBottom)
    }
    
    class Coordinator: ... {
        var didFireInitialLayout = false
        
        func tableView(_ tableView: UITableView, didEndLayoutSubviews...) {
            if !didFireInitialLayout && tableView.numberOfRows(inSection: 0) > 0 {
                didFireInitialLayout = true
                // Re-read scroll state and force bottom anchor
                isScrolledToBottom = (tableView.contentOffset.y <= 0)
                if !isScrolledToBottom {
                    tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: false)
                }
            }
        }
    }
}
```

**Pros:**
- Smallest possible change
- Doesn't touch our SwiftUI structure
- Doesn't depend on Exyte version

**Cons:**
- Tightly coupled to Exyte's internal coordinator pattern (uses `UITableViewDelegate` callbacks)
- Wrapping Exyte's `UIViewRepresentable` requires duplicating its body or using `.background()` trick
- `didEndLayoutSubviews` fires multiple times; need to be careful with the once-only logic
- The rotated transform (180°) means "scroll to bottom" maps to "scroll to row 0, at .bottom" — easy to get wrong

### Option B: Replace `UIList` with `ScrollViewReader` (most robust)

**Approach:** Don't use Exyte's `ChatView` for rendering. Build a SwiftUI `ScrollView` + `LazyVStack` ourselves, use `ScrollViewReader` to manage scroll position via `.scrollTo(id, anchor: .bottom)`, and only use Exyte for the input bar and message bubble views.

**Implementation sketch:**
```swift
ScrollViewReader { proxy in
    ScrollView {
        LazyVStack(spacing: 8) {
            ForEach(messages) { message in
                MessageBubbleView(message: message).id(message.id)
            }
        }
    }
    .onChange(of: messages) { _, new in
        if let last = new.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
    .onAppear {
        if let last = messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
```

**Pros:**
- Full control over scroll behaviour
- We can use `defaultScrollAnchor` (iOS 17+) and `scrollPosition` (iOS 18+)
- No dependency on Exyte's internal state machine
- Easier to test in isolation

**Cons:**
- We lose Exyte's input bar, message menu, attachments, Giphy picker, etc.
- Would need to re-implement ~70% of Exyte's functionality
- Major architecture change; equivalent to swapping out a core dependency

### Option C: Exyte version bump (cheapest if it works)

**Approach:** Check whether Exyte Chat has fixed this in a newer version (we're pinned to 2.7.10). If a newer version handles the empty→non-empty case correctly, bump.

**Steps:**
1. Check Exyte Chat release notes / changelog from 2.7.10 → current
2. Look for any scroll-related fixes
3. If found, bump `Package.swift` `exact: "2.7.10"` to the new version
4. Re-run our existing tests
5. Manual verification on real device

**Pros:**
- One-line change
- Maintained by upstream
- May fix other issues we don't know about

**Cons:**
- Newer versions may have breaking API changes
- May not actually fix our case
- We have no test coverage of this specific scenario
- Upstream may have regressed something else we depend on

### Option D: Hybrid — keep Exyte, layer our own coordination on top (recommended)

**Approach:** Keep Exyte's `ChatView` and `UIList` as the rendering engine. But add our own coordination layer:

1. **In `BeeChatView`**: track a "messagesStable" boolean state. Set it to `false` when `loadMessages` is in flight, `true` when complete + a small `Task.sleep` or `Task.yield()` after first render.

2. **In `OnlineChatView`**: only pass `messages` to Exyte's `ChatView` when `messagesStable == true`. When loading, pass an empty array (placeholder).

3. **After the first stable render**: post `.onScrollToBottom` notification to force Exyte to scroll to bottom.

4. **On every subsequent `messages` change** (real-time message arrives): post `.onScrollToBottom` if the user is "supposed to be" at the bottom (which we track via our own `userIsAtBottom` boolean, updated by detecting contentOffset changes).

**Implementation sketch:**
```swift
// BeeChatView.swift
@State private var messagesStable: Bool = false

func loadMessages() {
    messagesStable = false
    Task {
        let msgs = (try? await viewModel.loadMessagesWithHistory(sessionKey: key)) ?? []
        self.messages = mapped
        // Give Exyte a runloop to settle, then mark stable
        try? await Task.sleep(for: .milliseconds(50))
        self.messagesStable = true
        if let lastMsgId = mapped.last?.id {
            // Exyte notification observer will catch this
            NotificationCenter.default.post(name: .onScrollToBottom, object: lastMsgId)
        }
    }
}

var body: some View {
    ChatView(messages: messagesStable ? messages : [])  // gate
        .onChange(of: messagesStable) { _, stable in
            if stable && !messages.isEmpty {
                // Force Exyte to anchor at bottom after first stable load
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .onScrollToBottom, object: nil)
                }
            }
        }
}
```

**Pros:**
- Preserves all of Exyte's functionality
- Surgical change to our code only
- The "buffer" pattern is well-understood
- Easy to test (mock the stable toggle)
- Easy to remove if a real fix appears upstream

**Cons:**
- 50ms is a magic number (might need tuning)
- Slight flash possible on first load (empty → populated) — better than white space
- The "user is supposed to be at bottom" assumption is ours to manage

---

## 4. Recommended Approach

**Option D (Hybrid)**, with the following specifics:

### 4.1 Success criteria

The fix is successful when, on a real iPhone (iOS 17+, iPhone 12 or newer), in a real TestFlight build:

1. **Empty topic open** — first message list render shows the messages, anchored at the bottom of the conversation, with no white space below the last message. Jump-to-bottom button is NOT visible (we are at the bottom).
2. **Mac-origin topic open** — same behaviour, but messages are fetched from gateway (the path that triggers the race today). No white space, no mis-scroll, button behaves correctly.
3. **Topic switch** — switching from Topic A to Topic B shows Topic B at its bottom, with no carry-over scroll position from A.
4. **App backgrounded + foregrounded** — when returning to the app, the current topic is still anchored at its bottom (no white space, no wrong position).
5. **Send a message** — after sending, the new message is visible at the bottom, no white space below it, jump-to-bottom button not visible.
6. **Receive a real-time message** while at the bottom — the new message appears at the bottom, no white space, no button shown.
7. **User scrolls up to read history** — button appears. User taps button — view scrolls to bottom, button disappears.

### 4.2 Non-goals (out of scope for this fix)

- Replacing Exyte ChatView with our own implementation
- Performance optimisations unrelated to scroll
- Pagination / infinite scroll (existing Exyte behaviour preserved)
- Reactions, message edits, attachments (untouched)

### 4.3 Implementation plan

1. **Phase 1 — spec review** (this document)
   - Q: technical review of the race analysis and the Option D approach
   - Kieran: architecture review — does the buffer pattern fit the project's "Mac is master, iPhone is cache" model? Any new invariants?
   - Mel: UX review — is the "50ms flash" acceptable, or do we need a placeholder view?

2. **Phase 2 — implementation** (after all three approve)
   - Q: implement Option D in `BeeChatView.swift` and (if needed) `OnlineChatView.swift`
   - Add a `ScrollRaceLogger` that records timing of each phase (load start, load end, stable marked, notification posted) — useful for debugging on device
   - No new tests added in this phase (we have no UI test infrastructure; manual verification on real device per project rule)

3. **Phase 3 — verification on real iPhone** (no TestFlight until this passes)
   - Open 5 topics in sequence (mix of iPhone-origin and Mac-origin)
   - Background + foreground 3 times
   - Send 3 messages, receive 3 real-time messages
   - Scroll up, tap jump-to-bottom, verify
   - Capture logs, share with team for review
   - **No TestFlight push until the team signs off on the video/screenshots/logs**

4. **Phase 4 — TestFlight push** (after Phase 3 sign-off)
   - Push to TestFlight
   - Live test on Adam's iPhone for 24 hours
   - If clean → merge to develop via PR
   - If issues → rollback via PR, post-mortem

### 4.4 Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| 50ms delay is too short for slow devices (older iPhones) | Medium | Use `Task.yield()` instead of fixed sleep, or observe first stable frame via `.onScrollPhaseChange` |
| 50ms delay causes visible flash on iPhone 15 Pro | Low | Add a subtle "Loading messages..." overlay during the buffer window if Mel flags it as visible |
| Notification-based scroll-to-bottom doesn't fire because the observer is on the wrong queue | Medium | Verify with logs; add fallback that posts from main thread |
| The `messagesStable` flag races with `loadMessagesWithHistory` returning | Low | Reset `messagesStable` to `false` at the start of every `loadMessages` call |
| Exyte 2.7.10 API change in future (we're pinned to exact 2.7.10) | None | `exact:` pin protects us |
| Real device behaviour differs from simulator | Medium | Phase 3 is mandatory real-device verification before any TestFlight push |

### 4.5 Test plan (manual, on real device)

Run on iPhone 12 or newer, iOS 17.0+, paired with the development Mac. Tailscale active. TestFlight build installed.

| Test | Steps | Pass criteria |
|------|-------|---------------|
| **1. Cold open, iPhone-origin topic** | Force-quit app → relaunch → tap first topic in list | Renders at bottom, no white space, button not visible |
| **2. Cold open, Mac-origin topic** | On Mac, send a message in a new topic → on iPhone, force-quit app → relaunch → tap that new topic | Renders at bottom, no white space, button not visible |
| **3. Hot topic switch** | From topic A (loaded) → tap topic B | B renders at B's bottom, no scroll carry-over from A |
| **4. Background + foreground** | Open topic → background app 30s → foreground | Topic still at bottom, no white space |
| **5. Send message** | Open topic → type → send | New message at bottom, input bar still visible, button not shown |
| **6. Receive real-time** | From Mac, send message to the iPhone's current topic | New message appears at bottom, no white space, button not shown |
| **7. Jump to bottom** | Open topic → scroll up → button appears → tap button | View scrolls to bottom, button disappears |
| **8. Rapid topic switching** | Open 5 topics in quick succession | All open at their bottom, no white space, no flicker |
| **9. Empty topic** | Create a new topic on iPhone (no messages) | Empty state shown ("Ask Bee anything to get started"), no scroll artefacts |

Pass criteria for the whole fix: all 9 tests pass on a real device, with logs clean (no errors, no warnings about scroll).

### 4.6 Rollout gating

Per project rule, **no more "build and hope"**:
- No TestFlight push without Phase 3 video/screenshots/logs sign-off
- After TestFlight push, 24-hour observation on Adam's iPhone before merge to develop
- If any new symptom appears, immediate revert + post-mortem

---

## 5. Open Questions for Reviewers

**For Q (technical):**
1. Is `Task.yield()` or `Task.sleep(for: .milliseconds(50))` more reliable here? Any experience with iOS 17+ SwiftUI scroll stabilising patterns?
2. Should the buffer be on the View side (gate `messagesStable`) or on the ViewModel side (return a `Result` only after first frame)? View-side is simpler but ViewModel-side is more testable.
3. The `NotificationCenter.default.post(name: .onScrollToBottom, object: nil)` is an Exyte-public API. Is it safe to post from our code, or does it have undocumented assumptions about the call site?
4. Could we use `.onScrollPhaseChange(for: .bottom)` (iOS 18+) as a more robust signal that the table has settled? Or is that too new a deployment target?

**For Kieran (architecture):**
1. Does the "buffer then publish" pattern fit with the project's "Mac is master, iPhone is cache" model? We're temporarily hiding the cache from the View; is that a violation of any invariant?
2. Should this fix ship as part of Gate 2F, or as a separate gate (e.g., Gate 2G — Scroll Fix)?
3. Is there a risk that masking the race with a buffer prevents us from seeing a deeper issue in the data layer?

**For Mel (UX):**
1. Is the 50ms empty→populated transition acceptable, or do we need a visual placeholder?
2. Should the jump-to-bottom button behaviour be tuned (e.g., threshold for when to show)? Exyte's current threshold is "any scroll up".
3. Is there a known design pattern for "loading historical messages" in this kind of chat app that we should follow instead?

---

## 6. Out-of-Scope but Worth Tracking

1. **Exyte version bump audit** — separate spike. Check if 2.7.10 → current fixes this case. If yes, Option C becomes viable.
2. **Pagination / infinite scroll** — currently Exyte's `paginationHandler` is not wired. After this fix, we should wire it.
3. **Skeletor/loading states** — if Mel wants richer loading UI, that's a separate spec.
4. **Performance** — the buffer adds ~50ms latency to first render. Not a concern at 30 messages, but worth measuring at 1000+.

---

## 7. Change Log

- **v1 (14 Jun 2026):** Initial draft by Bee. Awaiting Q + Kieran + Mel review.
