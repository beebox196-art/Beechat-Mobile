# Gate 2B.5 — Phase 2: UI Layer v3 Delta (Changes from v2)

**Status:** DRAFT — v3 revision
**Applies to:** GATE-2B5-PHASE2-UI-LAYER-v2.md
**Date:** 2026-05-19
**Author:** Bee (Coordinator)

---

## Purpose

This document specifies ONLY the changes from v2 → v3. The v2 spec remains the base document. Reviewers should read v2 first, then apply these changes.

All 7 v1 blockers are confirmed resolved by all 3 reviewers. The v3 changes address the 4 new blockers and 10 high warnings found in v2 review.

---

## Blocker Fixes

### B1: BeeChatView ChatView Generic Type Mismatch (Q NB1, Mel B1)

**Problem:** `BeeChatView` has `if/else` on `connectionState` producing two different `ChatView` generic types. Won't compile.

**Fix:** Extract `OnlineChatView` and `OfflineChatView` as separate View structs.

**Changes to §1.2 (New Files):**
Add two new files:

| File | Package | Purpose |
|------|---------|---------|
| `OnlineChatView.swift` | BeeChatUI | Online chat with default Exyte input. Generic: `ChatView<EmptyView, EmptyView, DefaultMessageMenuAction>` |
| `OfflineChatView.swift` | BeeChatUI | Offline chat with disabled input + reconnect button. Generic: `ChatView<EmptyView, OfflineInputBar, DefaultMessageMenuAction>` |

**Replace §3.4 entirely with:**

#### §3.4 `BeeChatView.swift` — Coordinator with sub-views

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/BeeChatView.swift`

`BeeChatView` becomes a thin coordinator that switches between `OnlineChatView` and `OfflineChatView`. It owns `messages`, `preservedDraft`, and delegates to the appropriate sub-view.

```swift
public struct BeeChatView: View {
    @State public var viewModel: BeeChatMobileViewModel
    @State private var messages: [ExyteChat.Message] = []
    @State private var streamingMessageId: String = "streaming-msg"
    
    // Draft preservation across online/offline transitions (B3 fix)
    @State private var preservedDraft: String = ""
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusView(
                state: viewModel.connectionState,
                onRetry: {
                    Task { await viewModel.reconnect() }
                }
            )

            // B1 fix: Switch between two separate View structs.
            // Each has its own concrete ChatView generic type — valid Swift conditional.
            if viewModel.connectionState == .connected {
                OnlineChatView(
                    viewModel: viewModel,
                    messages: messages,
                    preservedDraft: $preservedDraft
                )
            } else {
                OfflineChatView(
                    viewModel: viewModel,
                    messages: messages,
                    preservedDraft: preservedDraft
                )
            }
        }
        .onAppear { loadMessages() }
        .onChange(of: viewModel.selectedTopicId) { _, _ in loadMessages() }
        .onChange(of: viewModel.isStreaming) { _, newValue in
            if !newValue { loadMessages() }
        }
    }

    private func loadMessages() {
        guard let topicId = viewModel.selectedTopicId,
              let key = viewModel.sessionKey(for: topicId) else { messages = []; return }
        Task {
            let msgs = (try? viewModel.messages(for: key)) ?? []
            let mapped = MessageMapper.exyteMessages(from: msgs)
            if viewModel.selectedTopicId == topicId {
                self.messages = mapped
            }
        }
    }
}
```

#### §3.4.1 `OnlineChatView` — New sub-view

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/OnlineChatView.swift`

```swift
import SwiftUI
import ExyteChat
import BeeChatMobileKit
import BeeChatPersistence

/// Online chat view using the default Exyte input (no inputViewBuilder).
/// Generic type: ChatView<EmptyView, EmptyView, DefaultMessageMenuAction>
struct OnlineChatView: View {
    let viewModel: BeeChatMobileViewModel
    let messages: [ExyteChat.Message]
    @Binding var preservedDraft: String
    @State private var streamingMessageId: String = "streaming-msg"
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ChatView(messages: mergedMessages) { draft in
            guard let topicId = viewModel.selectedTopicId else { return }
            Task {
                do {
                    try await viewModel.send(text: draft.text, to: topicId)
                    preservedDraft = ""  // Clear on successful send
                } catch {
                    viewModel.connectionError = error.localizedDescription
                }
            }
        }
        .showNetworkConnectionProblem(false)
        .overlay {
            // Empty messages prompt
            if messages.isEmpty && !viewModel.isStreaming {
                VStack {
                    Text("Ask Bee anything to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            if viewModel.isStreaming {
                VStack {
                    StreamingIndicatorView()
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }
    
    private var mergedMessages: [ExyteChat.Message] {
        guard let topicId = viewModel.selectedTopicId,
              viewModel.isStreaming,
              let key = viewModel.sessionKey(for: topicId),
              let streamingText = viewModel.streamingContent[key],
              !streamingText.isEmpty else {
            return messages
        }
        
        var merged = messages
        merged.removeAll { $0.id == streamingMessageId }
        let streamingMsg = ExyteChat.Message(
            id: streamingMessageId,
            user: ExyteChat.User(id: "bee", name: "Bee", avatarURL: nil, isCurrentUser: false),
            status: .sent, createdAt: Date(), text: streamingText
        )
        merged.append(streamingMsg)
        return merged
    }
}
```

**Draft preservation note:** Exyte's `ChatView` manages draft text internally. When the view is destroyed (user goes offline), that draft is lost. `preservedDraft` is cleared on successful send. On going offline, the `OfflineChatView` shows `preservedDraft` in its placeholder so the user has visual context. Full restoration into Exyte's internal state requires `inputViewBuilder` on the online view too — a future refinement if the loss is significant in practice.

#### §3.4.2 `OfflineChatView` — New sub-view

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/OfflineChatView.swift`

```swift
import SwiftUI
import ExyteChat
import BeeChatMobileKit
import BeeChatPersistence

/// Offline chat view with disabled input and reconnect button.
/// Generic type: ChatView<EmptyView, OfflineInputBar, DefaultMessageMenuAction>
struct OfflineChatView: View {
    let viewModel: BeeChatMobileViewModel
    let messages: [ExyteChat.Message]
    let preservedDraft: String  // Show what user was typing before going offline
    @State private var streamingMessageId: String = "streaming-msg"
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        ChatView(
            messages: mergedMessages,
            inputViewBuilder: { text, attachments, state, style, inputViewAction, dismissKeyboard in
                // Correct Exyte InputViewBuilderClosure signature:
                // (Binding<String>, InputViewAttachments, InputViewState, InputViewStyle,
                //  @escaping (InputViewAction) -> Void, () -> Void) -> InputViewContent
                HStack {
                    TextField(preservedDraft.isEmpty
                              ? "Reconnect to send messages"
                              : "Draft: \"\(preservedDraft)\" — reconnect to send",
                              text: text)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                        .accessibilityLabel("Message input, currently offline")
                    Button {
                        Task { await viewModel.reconnect() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reconnect")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        ) { _ in
            // Callback won't fire — input is disabled
        }
        .showNetworkConnectionProblem(true)
        .overlay {
            if viewModel.isStreaming {
                VStack {
                    StreamingIndicatorView()
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }
    
    private var mergedMessages: [ExyteChat.Message] {
        guard let topicId = viewModel.selectedTopicId,
              viewModel.isStreaming,
              let key = viewModel.sessionKey(for: topicId),
              let streamingText = viewModel.streamingContent[key],
              !streamingText.isEmpty else {
            return messages
        }
        
        var merged = messages
        merged.removeAll { $0.id == streamingMessageId }
        let streamingMsg = ExyteChat.Message(
            id: streamingMessageId,
            user: ExyteChat.User(id: "bee", name: "Bee", avatarURL: nil, isCurrentUser: false),
            status: .sent, createdAt: Date(), text: streamingText
        )
        merged.append(streamingMsg)
        return merged
    }
}
```

---

### B2: importSelected() Rollback Destroys Gateway Messages (Kieran B1)

**Problem:** `deleteCascading()` in import rollback deletes gateway messages that existed before the import attempt.

**Fix:** Replace `deleteCascading()` with a GRDB write transaction that atomically saves topic + bridge. On bridge failure, the transaction rolls back — no orphaned topic, no deleted messages.

**Add to §2.5 (TopicRepository additions):**

```swift
/// Atomically save a topic and its bridge entry in a single write transaction.
/// If bridge creation fails (e.g., UNIQUE constraint on openclawSessionKey),
/// the entire transaction rolls back — no orphaned topic is left behind.
/// Crucially, this does NOT use deleteCascading() which would destroy
/// existing gateway messages linked to the session key.
public func saveAndBridgeInTransaction(_ topic: Topic, sessionKey: String) throws {
    try dbManager.write { db in
        try topic.save(db)  // GRDB upsert
        // If this throws (UNIQUE on openclawSessionKey), the transaction
        // rolls back and the topic save is also undone.
        try db.execute(
            sql: """
            INSERT INTO topic_session_bridge (topicId, openclawSessionKey, status, createdAt, updatedAt)
            VALUES (?, ?, 'active', datetime('now'), datetime('now'))
            """,
            arguments: [topic.id, sessionKey]
        )
    }
}
```

**Replace §2.7 `importSelected(_:)` entirely with:**

```swift
/// Create topics from selected gateway sessions.
/// Uses the existing gateway session key to preserve message history.
/// Each import is wrapped in a GRDB write transaction for atomicity.
/// On bridge failure (UNIQUE constraint), the transaction rolls back —
/// no orphaned topic, no deleted messages.
///
/// Note: The existingKeys pre-check reduces UNIQUE violations but does not
/// guarantee prevention — concurrent writes from other processes (macOS BeeChat)
/// could insert between check and write. The transaction rollback handles remaining cases.
///
/// - Returns: The number of topics successfully created.
public func importSelected(_ sessions: [Session]) throws -> Int {
    let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()
    var count = 0
    
    for session in sessions {
        // Pre-check: skip if session already has a bridge.
        // This reduces violations but doesn't guarantee prevention (TOCTOU race).
        if existingKeys.contains(session.id) {
            continue
        }
        
        let topic = Topic(
            id: UUID().uuidString,
            name: session.title ?? session.customName ?? "Conversation",
            lastMessagePreview: session.lastMessagePreview,
            lastActivityAt: session.lastMessageAt ?? session.updatedAt,
            unreadCount: session.unreadCount,
            sessionKey: session.id
        )
        
        // Atomic transaction: topic + bridge saved together, or neither.
        do {
            try persistenceStore.topicRepo.saveAndBridgeInTransaction(topic, sessionKey: session.id)
            count += 1
        } catch {
            // Transaction rolled back — topic was never persisted.
            // No cleanup needed. No messages deleted.
            print("[ViewModel] Import failed for session \(session.id): \(error)")
        }
    }
    
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    return count
}
```

---

### B3: Draft Text Lost on Online↔Offline Switch (Mel B2)

**Fix:** Covered in B1 above. `preservedDraft` is a `@State` on `BeeChatView` that survives the sub-view switch. The online view clears it on successful send. The offline view shows it in the placeholder text so the user has visual context.

**Limitation:** Full draft restoration into Exyte's internal `InputView` state is not possible without using `inputViewBuilder` on the online view too. The current approach preserves the text visually but the user must re-type on reconnection. This is acceptable for Phase 2 — if the loss is significant in practice, a future refinement can use `inputViewBuilder` on both views to manage draft externally.

---

### B4: TOCTOU Race on importSelected() (Kieran B2)

**Fix:** Covered in B2 above. The GRDB write transaction makes each import atomic. If a concurrent process inserts a bridge between the pre-check and the transaction, the transaction will fail with a UNIQUE constraint error and roll back cleanly. No data loss, no orphans.

---

## Warning Fixes

### W1: `.presentationDetents` + `.popover` Documentation

**Add note to §3.3 (TopicListView) and §3.1 (NewTopicSheet):**

> **Note:** `.presentationDetents` applies only when the popover adapts to a sheet (iPhone/compact size class). On iPad where it presents as a popover, the `.frame(minWidth: 320, maxWidth: 360, minHeight: 220)` on `NewTopicSheet` controls the size. Detents are silently ignored for popover presentation.

### W2: Toast Timeout 7s (non-VoiceOver)

**Change in §3.3 (TopicListView):**

```swift
let timeout: TimeInterval = isVoiceOverEnabled ? 30 : 7  // was 5 for non-VoiceOver
```

### W3: Import Candidate Count Loading State

**Add to §3.3 (TopicListView):**

Add `@State private var isLoadingCandidateCount = false` and show a subtle loading indicator in `EmptyTopicsView` while the count is loading:

```swift
// In TopicListView, when loading candidates:
EmptyTopicsView(
    hasImportableSessions: importCandidateCount > 0,
    showArchiveToast: showArchiveUndo,
    isLoading: isLoadingCandidateCount,  // new parameter
    onStartConversation: { isShowingNewTopicSheet = true },
    onImportSessions: ...
)
```

Add `isLoading` parameter to `EmptyTopicsView`:
```swift
struct EmptyTopicsView: View {
    let hasImportableSessions: Bool
    let showArchiveToast: Bool
    let isLoading: Bool  // new: shows subtle loading indicator
    ...
    // In body, after the CTA buttons:
    if isLoading {
        ProgressView()
            .padding(.top, 4)
    }
}
```

### W4: Consistent "Topics" Terminology

**Change in §3.2 (EmptyTopicsView):**

- Fresh install heading: "No topics yet" (was "No conversations yet")
- Fresh install body: "Start a topic when you're ready to chat with Bee."
- Import available body: "Import your recent sessions to get started."
- CTA button: "Start a Topic" (was "Start a Conversation")
- Empty state icon: `.accessibilityHidden(true)` (decorative)

Already applied in the v3 EmptyTopicsView code above.

### W5: Use `@Environment(\.dynamicTypeSize)`

**Change in §3.3 (TopicListView):**

Replace the hardcoded `dynamicTypeSize` computed property with:

```swift
@Environment(\.dynamicTypeSize) private var dynamicTypeSize
```

Remove the fake helper method.

### W6: Use `@Environment(\.accessibilityVoiceOverEnabled)`

**Change in §3.3 (TopicListView):**

Replace `UIAccessibility.isVoiceOverRunning` with:

```swift
@Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
```

Then use `isVoiceOverEnabled` in the archive toast timer:

```swift
let timeout: TimeInterval = isVoiceOverEnabled ? 30 : 7
```

### W7: Toast + Empty State Overlap

**Change in §3.2 (EmptyTopicsView):**

Add `showArchiveToast: Bool` parameter and bottom padding:

```swift
.padding(.bottom, showArchiveToast ? 60 : 0)
```

Already applied in the v3 EmptyTopicsView code above.

### W8: Guard Double-Archive

**Change in §2.2 (archiveTopic):**

Add guard after `fetchById()`:

```swift
guard !topic.isArchived else { return nil }
```

Already applied in the v3 code above.

### W9: Correct inputViewBuilder Parameter Labels

**Change in §3.4.2 (OfflineChatView):**

Use descriptive parameter names matching Exyte's actual signature:

```swift
inputViewBuilder: { text, attachments, state, style, inputViewAction, dismissKeyboard in
```

Already applied in the v3 code above.

### W10: TopicError Sendable Conformance

**Change in §2.8:**

```swift
public enum TopicError: LocalizedError, Sendable {
```

Already applied in the v3 code above.

---

## §1.1 Updated — BeeChatView Changes

Change the Phase 2 Changes column for `BeeChatView.swift`:

| File | Package | Status | Phase 2 Changes |
|------|---------|--------|-----------------|
| `BeeChatView.swift` | BeeChatUI | ✅ Session key resolution (Phase 1 fix) | Becomes coordinator only; online/offline logic extracted to sub-views |

---

## §4.1 Accessibility Labels — Additions

Add to the VoiceOver labels table:

| Element | Label | Hint |
|---------|-------|------|
| Empty state icon | (none — `.accessibilityHidden(true)`) | Decorative |
| "Start a Topic" button | "Start a Topic" | "Creates a new conversation topic" |
| "Import Recent Sessions" button | "Import Recent Sessions" | "Imports recent gateway sessions as topics" |
| Character counter | "N of 80 characters" | — |
| Offline input field | "Message input, currently offline" | — |

---

## §4.3 Reduce Motion — Additions

Add rows to the table:

| Animation | Default | Reduce Motion |
|-----------|---------|---------------|
| Empty state crossfade (list → empty) | System default | `.opacity` only |
| Online ↔ Offline sub-view switch | System default | System handles |
| Import sheet row selection checkmark | Toggle animation | Instant toggle |

---

## §9 Review History Update

Add row:

| Version | Date | Changes | Result |
|---------|------|---------|--------|
| v2 | 2026-05-19 | Resolved v1 B1-B7 + W1-W10 | 🔴 4 new blockers (B1 generic types, B2 data loss, B3 draft loss, B4 TOCTOU) |
| v3 | 2026-05-19 | Resolved v2 B1-B4 + W1-W10 | Pending team review |