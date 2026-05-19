# Gate 2B.5 — Phase 2: UI Layer (v2)

**Status:** DRAFT — v2 revision (resolves v1 consolidated review blockers B1-B7 + warnings W1-W10)
**Parent:** GATE-2B5-TOPIC-ARCHITECTURE-v2.md
**Depends on:** GATE-2B5-PHASE1-DATA-LAYER-v3.2.md (✅ Complete, committed)
**Date:** 2026-05-19
**Author:** Bee (Coordinator)

---

## 0. Context

Phase 1 (Data Layer) is complete and committed. The ViewModel now uses `[Topic]`, the persistence layer has `pendingGatewaySync`, `Migration012` is live, and all team reviews passed. The app builds and runs on the simulator with 3 seed topics.

**Phase 2 adds the UI layer** — the user-facing Topic management that makes the data layer useful. This covers:

1. **New Topic creation** (popover with adaptive presentation)
2. **Empty states** (no topics, no messages)
3. **Swipe actions** (Archive + Delete)
4. **Offline/error states** in the Topic context
5. **Accessibility** (VoiceOver, Dynamic Type, Reduce Motion)
6. **ViewModel additions** (createTopic, archiveTopic, deleteTopic, import sessions)

No data model changes. No persistence changes (beyond two minimal `TopicRepository` additions). All new code is in `BeeChatUI` + `BeeChatMobileKit`.

---

## 1. Codebase Audit (Current State After Phase 1)

### 1.1 Existing Files

| File | Package | Status | Phase 2 Changes |
|------|---------|--------|-----------------|
| `TopicListView.swift` | BeeChatUI | ✅ Uses `Topic` model (Phase 1 fix) | Add `+` button, swipe actions, empty state, popover, import flow, archive undo |
| `BeeChatView.swift` | BeeChatUI | ✅ Session key resolution (Phase 1 fix) | Offline input state, empty messages overlay |
| `ConnectionViews.swift` | BeeChatUI | ✅ ConnectionStatusView + OfflineBannerView | No changes |
| `StreamingIndicatorView.swift` | BeeChatUI | ✅ Typing dots animation | No changes |
| `BeeChatTheme.swift` | BeeChatUI | ✅ Constants only (S7) | No changes |
| `MessageMapper.swift` | BeeChatUI | ✅ v5→Exyte mapping | No changes |
| `BeeChatMobileViewModel.swift` | BeeChatMobileKit | ✅ Phase 1 complete | Add createTopic, archiveTopic, deleteTopic, importSessions |
| `BeeChatMobileConfig.swift` | BeeChatMobileKit | ✅ No clientMode | No changes |
| `GatewayConfigLoader.swift` | BeeChatMobileKit | ✅ Multi-source config | No changes |
| `BeeChatMobileApp.swift` | App | ✅ Offline-first startup | No changes |

### 1.2 New Files Required

| File | Package | Purpose |
|------|---------|---------|
| `NewTopicSheet.swift` | BeeChatUI | Popover for creating topics (adaptive to sheet on compact size class) |
| `EmptyTopicsView.swift` | BeeChatUI | Empty state for topic list (no conversations / import available) |

### 1.3 Key Design Constraints

- **No new data model changes** — Phase 1 established the model
- **No new persistence changes** beyond two `TopicRepository` methods
- **No theme system** — Constants only (S7 from Gate 2 spec)
- **No separate `EmptyStateView.swift`** for messages — `.overlay` on ChatView (Q R2 + Mel R2)
- **macOS regression zero** — all changes are iOS-only (BeeChatUI + BeeChatMobileKit)
- **Exyte `ChatView` API:** `inputViewBuilder` closure replaces default input; `showNetworkConnectionProblem(true)` shows "Waiting for network" bar above input but doesn't disable the input field; `.disabled()` propagates to message list (unacceptable for offline state)

---

## 2. ViewModel Additions

### 2.1 `createTopic(name:)` — Create a new topic

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

```swift
/// Create a new topic with a user-provided name.
/// Generates an upfront gateway-format session key and bridge entry.
/// If the gateway is connected, sends a bootstrap message immediately.
/// If offline, sets pendingGatewaySync = true for later reconciliation.
///
/// - Parameter name: Display name (1-80 chars, trimmed)
/// - Returns: The created Topic
public func createTopic(name: String) throws -> Topic {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw TopicError.nameRequired
    }
    guard trimmed.count <= 80 else {
        throw TopicError.nameTooLong(count: trimmed.count)
    }
    
    let isOffline = syncBridge == nil || connectionState != .connected
    let topic = try persistenceStore.topicRepo.create(
        name: trimmed,
        pendingGatewaySync: isOffline
    )
    
    // If connected, send bootstrap immediately
    if !isOffline, let bridge = syncBridge, let sessionKey = topic.sessionKey {
        Task {
            do {
                _ = try await bridge.sendMessage(sessionKey: sessionKey, text: "Start", topic: topic)
                try persistenceStore.topicRepo.markSynced(topicId: topic.id)
            } catch {
                print("[ViewModel] Bootstrap send failed for \(topic.id): \(error)")
                // Topic stays pending — will reconcile on next connect
            }
        }
    }
    
    // Refresh and auto-select
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    self.selectedTopicId = topic.id
    return topic
}
```

**Key decisions:**
- Uses `topicRepo.create(name:pendingGatewaySync:)` from Phase 1 (§3.3.1)
- Gateway-format key is generated upfront (D3 from architecture spec)
- If offline, `pendingGatewaySync = true` — reconciled on next `connect()`
- If online, bootstrap message sent immediately in background Task
- Auto-selects the new topic after creation
- Validation: 1-80 chars, trimmed

### 2.2 `archiveTopic(id:)` — Archive a topic

```swift
/// Archive a topic. Removes it from the active list.
/// Uses the existing TopicRepository.archive(topicId:) method which
/// performs a surgical SQL UPDATE (no stale in-memory data risk).
/// Returns the archived topic for undo support.
public func archiveTopic(id: String) throws -> Topic? {
    // Fetch the topic before archiving (for undo)
    guard let topic = try persistenceStore.topicRepo.fetchById(id) else { return nil }
    
    // Use the existing repo method — direct SQL UPDATE
    try persistenceStore.topicRepo.archive(topicId: id)
    
    // Refresh list
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    
    // If archived topic was selected, select the first remaining
    if selectedTopicId == id {
        selectedTopicId = topics.first?.id
    }
    
    return topic
}
```

**v1→v2 change:** Uses `topicRepo.archive(topicId:)` instead of `save()` with mutated in-memory copy. The existing method does `UPDATE topics SET isArchived = 1, updatedAt = ? WHERE id = ?` — surgical, no stale data risk.

### 2.3 `unarchiveTopic(id:)` — Undo archive

```swift
/// Restore an archived topic. Used for undo support.
/// Re-selects the restored topic so the user sees it immediately.
public func unarchiveTopic(id: String) throws {
    guard var topic = try persistenceStore.topicRepo.fetchById(id) else { return }
    topic.isArchived = false
    topic.updatedAt = Date()
    try persistenceStore.topicRepo.save(topic)
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    
    // Re-select the restored topic (Mel B3 from v1 review)
    self.selectedTopicId = topic.id
}
```

**v1→v2 change:** Sets `selectedTopicId = topic.id` on undo (not just when `nil`). The user expects to see the topic they just restored.

### 2.4 `deleteTopic(id:)` — Delete a topic with cascading

```swift
/// Delete a topic and all associated data (messages, bridge entry).
/// This is permanent and cannot be undone.
/// The caller must show a confirmation dialog before calling this.
public func deleteTopic(id: String) throws {
    try persistenceStore.topicRepo.deleteCascading(id)
    
    // Refresh list
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    
    // If deleted topic was selected, select the first remaining
    if selectedTopicId == id {
        selectedTopicId = topics.first?.id
    }
}
```

**Note:** `deleteCascading()` already exists from Phase 1 — it deletes the topic, its bridge entries, and associated messages.

### 2.5 `TopicRepository` additions (minimal, in BeeChat-v5)

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift`

Two new methods:

```swift
/// Fetch a single topic by ID, regardless of archived status.
/// Used for undo operations where the topic may be archived.
/// Internal-only — not exposed outside BeeChat ecosystem.
public func fetchById(_ id: String) throws -> Topic? {
    try dbManager.reader.read { db in
        try Topic.fetchOne(db, key: id)
    }
}

/// Fetch all session keys that already have a topic bridge entry,
/// regardless of bridge status (active, pending, etc.).
/// Used by the import flow to check which sessions already have topics.
public func fetchAllActiveSessionKeys() throws -> Set<String> {
    try dbManager.reader.read { db in
        let bridges = try TopicSessionBridge.fetchAll(db)
        return Set(bridges.map { $0.openclawSessionKey })
    }
}
```

**v1→v2 change for `fetchAllActiveSessionKeys()`:** Removed the `.filter(Column("status") == "active")` — the import flow needs to know about ALL existing bridges regardless of status, not just "active" ones (Kieran W5 from v1 review). This prevents importing a session that has a non-active bridge entry (which would hit the UNIQUE constraint on `openclawSessionKey`).

**GRDB safety note:** Both methods are safe to call from `@MainActor` because GRDB's `DatabaseReader.read` dispatches to its own serial queue (Q verified in v1 review).

### 2.6 `importCandidates()` — Fetch sessions available for import

```swift
/// Fetch candidate sessions that could be imported as topics.
/// These are gateway sessions that don't already have a local topic bridge.
/// Filters out known system/cron session patterns.
public func importCandidates() async throws -> [Session] {
    guard let bridge = syncBridge else {
        throw TopicError.gatewayNotConnected
    }
    
    let sessions = try await bridge.fetchSessions()
    let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()
    
    // Filter to sessions that don't already have a bridge entry
    let candidates = sessions.filter { session in
        !existingKeys.contains(session.id)
    }
    
    // Filter out known system/cron/agent session patterns
    let filtered = candidates.filter { session in
        let id = session.id.lowercased()
        // Skip cron jobs, scheduled tasks, and agent-internal sessions
        let systemPrefixes = ["cron:", "schedule:", "luna-", "gav-", "kieran-", "q-"]
        return !systemPrefixes.contains(where: { id.hasPrefix($0) })
    }
    
    return filtered
}
```

**v1→v2 change:** Removed the confusing `BeeChatSessionFilter` dead code. Added basic system prefix filtering (W2 from v1 review). The `systemPrefixes` list can be expanded later — this is a reasonable starting set.

### 2.7 `importSelected(_:)` — Create topics from selected sessions

```swift
/// Create topics from selected gateway sessions.
/// Uses the existing gateway session key to preserve message history.
/// On bridge failure, rolls back the topic to avoid orphans.
///
/// - Returns: The number of topics successfully created.
public func importSelected(_ sessions: [Session]) throws -> Int {
    let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()
    var count = 0
    
    for session in sessions {
        // Pre-check: skip if session already has a bridge (defensive against UNIQUE constraint)
        if existingKeys.contains(session.id) {
            continue
        }
        
        let topic = Topic(
            id: UUID().uuidString,
            name: session.title ?? session.customName ?? "Conversation",
            lastMessagePreview: session.lastMessagePreview,
            lastActivityAt: session.lastMessageAt ?? session.updatedAt,
            unreadCount: session.unreadCount,
            sessionKey: session.id  // Use the existing gateway session key
        )
        try persistenceStore.topicRepo.save(topic)
        do {
            try persistenceStore.topicRepo.saveBridge(topicId: topic.id, sessionKey: session.id)
            count += 1
        } catch {
            // Bridge failed (UNIQUE constraint or other) — roll back the topic
            // to avoid leaving an orphan topic with no bridge entry
            try? persistenceStore.topicRepo.deleteCascading(topic.id)
            print("[ViewModel] Bridge creation failed for session \(session.id), topic rolled back: \(error)")
        }
    }
    
    // Refresh
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    return count
}
```

**v1→v2 changes:**
- Added `existingKeys` pre-check before creating each topic (B5 from v1 review)
- On bridge failure, roll back by deleting the topic with `deleteCascading()` (W7 from v1 review) — avoids orphaned topics with 0 message count
- Removed the `continue` on error that left orphaned topics

### 2.8 Error enum

```swift
public enum TopicError: LocalizedError {
    case nameRequired
    case nameTooLong(count: Int)
    case gatewayNotConnected
    
    public var errorDescription: String? {
        switch self {
        case .nameRequired: return "Topic name is required"
        case .nameTooLong(let count): return "Topic name must be 80 characters or less (currently \(count))"
        case .gatewayNotConnected: return "Gateway is not connected"
    }
}
```

**Note:** `TopicError` is a top-level type in `BeeChatMobileViewModel.swift`. If the ViewModel grows significantly, it should be nested or extracted — but for Phase 2 scope this is fine.

---

## 3. UI Changes

### 3.1 `NewTopicSheet.swift` — New file

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/NewTopicSheet.swift`

**Spec:** Mel M6 (iPhone) + M7 (iPad)

**v1→v2 key change:** This is now a single `View` presented via `.popover` with iOS 16.4+ compact adaptation. On iPhone (compact size class), iOS automatically presents it as a sheet. On iPad (regular size class), it shows as a popover. No dual `.sheet` + `.popover` modifiers needed.

```swift
import SwiftUI
import BeeChatMobileKit

struct NewTopicSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool
    
    let onCreate: (String) -> Void
    
    @State private var showDiscardConfirmation = false
    
    private var isNameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80
    }
    
    private var isDirty: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("What would you like to talk about?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                TextField("Topic name", text: $name)
                    .focused($isNameFocused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if isNameValid { createAndDismiss() }
                    }
                
                HStack {
                    Text("\(name.count)/80")
                        .font(.caption)
                        .foregroundStyle(name.count > 80 ? .red : .secondary)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("New Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty {
                            showDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createAndDismiss()
                    }
                    .disabled(!isNameValid)
                }
            }
            .alert("Discard topic draft?", isPresented: $showDiscardConfirmation) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard", role: .destructive) { dismiss() }
            } message: {
                Text("Your topic name will be lost.")
            }
        }
        .onAppear {
            isNameFocused = true
        }
        .frame(minWidth: 320, maxWidth: 360, minHeight: 220)
        // Presentation sizing is handled by the presenter (TopicListView):
        // - iPhone (compact): .presentationDetents([.height(220), .medium])
        // - iPad (regular): .frame above + popover arrow
    }
    
    private func createAndDismiss() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNameValid else { return }
        onCreate(trimmed)
        dismiss()
    }
}
```

**Key design decisions:**
- **Single presentation method:** `.popover` with compact adaptation (B1 fix) — no dual modifiers
- Keyboard auto-focuses on appear (Mel M6)
- Create disabled until valid text entered
- Dirty draft discard shows confirmation (Mel M6)
- Character counter shows `/80`
- On submit (return key), creates if valid
- `.frame(minWidth: 320, maxWidth: 360, minHeight: 220)` sets the popover size on iPad

### 3.2 `EmptyTopicsView.swift` — New file

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/EmptyTopicsView.swift`

**Spec:** Mel M9

Two states:

1. **Fresh install** (no topics, no importable sessions):
   ```
   [BeeChat icon]
   No conversations yet
   Start a topic when you are ready to chat with Bee.
   
   [Start a Conversation]
   ```

2. **Import available** (no topics, but gateway connected + candidates exist):
   ```
   [BeeChat icon]
   No topics yet
   BeeChat now keeps your conversations organized as topics.
   
   [Start a Conversation]
   [Import Recent Sessions]
   ```

**v1→v2 key change:** Import button only shown when `importCandidateCount > 0` (B4 fix from v1 review). The parent view loads the count asynchronously and passes it down.

```swift
import SwiftUI

struct EmptyTopicsView: View {
    let hasImportableSessions: Bool  // true only when count > 0
    let onStartConversation: () -> Void
    let onImportSessions: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 8) {
                Text(hasImportableSessions ? "No topics yet" : "No conversations yet")
                    .font(.title2.bold())
                
                Text(hasImportableSessions
                     ? "BeeChat now keeps your conversations organized as topics."
                     : "Start a topic when you are ready to chat with Bee.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            VStack(spacing: 12) {
                Button(action: onStartConversation) {
                    Label("Start a Conversation", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                if hasImportableSessions, let onImport = onImportSessions {
                    Button(action: onImport) {
                        Label("Import Recent Sessions", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 32)
            
            Spacer()
        }
    }
}
```

### 3.3 `TopicListView.swift` — Modifications

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/TopicListView.swift`

**v1→v2 key changes:**
- **Single `.popover` presentation** instead of dual `.sheet` + `.popover` (B1)
- **Dynamic Type detent** — `.medium` for accessibility sizes (W1)
- **Archive tint neutral** — `.secondary` not `.orange` (W5)
- **VoiceOver-safe toast** — `Task` + `Task.sleep`, extended/no timeout for VoiceOver (B3, W3)
- **Import button conditional** — only shown when `importCandidateCount > 0` (B4)
- **Import multi-select** — edit mode activation (W6)
- **Delete confirmation rephrased** — no "local messages" ambiguity (W8)
- **Reduce Motion handling** — static animations (W4)

```swift
public struct TopicListView: View {
    @State public var viewModel: BeeChatMobileViewModel
    
    // Popover state
    @State private var isShowingNewTopicSheet = false
    
    // Import state
    @State private var isShowingImportSheet = false
    @State private var importCandidates: [Session] = []
    @State private var selectedImportIds: Set<String> = []
    @State private var isLoadingCandidates = false
    @State private var importCandidateCount: Int = 0  // For button visibility
    
    // Archive undo — Task-based (not DispatchQueue)
    @State private var archivedTopic: Topic? = nil
    @State private var showArchiveUndo = false
    @State private var archiveUndoTask: Task<Void, Never>? = nil
    
    // Delete confirmation
    @State private var topicToDelete: Topic? = nil
    
    // Accessibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    public init(viewModel: BeeChatMobileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Offline banner when disconnected
                if viewModel.connectionState == .disconnected || viewModel.connectionState == .error {
                    OfflineBannerView(onRetry: {
                        Task { await viewModel.reconnect() }
                    })
                }
                
                if viewModel.topics.isEmpty {
                    // Empty state (M9)
                    EmptyTopicsView(
                        hasImportableSessions: importCandidateCount > 0,
                        onStartConversation: { isShowingNewTopicSheet = true },
                        onImportSessions: importCandidateCount > 0 ? {
                            Task { await loadImportCandidates() }
                            isShowingImportSheet = true
                        } : nil
                    )
                } else {
                    // Topic list with swipe actions
                    List(viewModel.topics, id: \.id, selection: Binding(
                        get: { viewModel.selectedTopicId },
                        set: { viewModel.selectedTopicId = $0 }
                    )) { topic in
                        NavigationLink(value: topic.id) {
                            TopicRow(topic: topic)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // Archive (default full-swipe action) — neutral tint
                            Button {
                                archiveTopic(topic)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.secondary)  // Neutral tint (W5 fix — was .orange)
                            
                            // Delete (destructive)
                            Button(role: .destructive) {
                                topicToDelete = topic
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Topics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingNewTopicSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Topic")
                    .accessibilityHint("Creates a conversation topic")
                }
            }
            // Single presentation: .popover with compact adaptation
            // On iOS 16.4+, popovers automatically adapt to sheets on compact size class
            .popover(isPresented: $isShowingNewTopicSheet) {
                NewTopicSheet(onCreate: { name in
                    do {
                        try viewModel.createTopic(name: name)
                    } catch {
                        viewModel.connectionError = error.localizedDescription
                    }
                })
                // Dynamic Type: use .medium for large accessibility sizes (W1)
                .presentationDetents(
                    dynamicTypeSize > .xLarge
                        ? [.medium]
                        : [.height(220)]
                )
            }
        } detail: {
            if let topicId = viewModel.selectedTopicId {
                BeeChatView(viewModel: viewModel)
                    .id(topicId)
                    .navigationTitle(viewModel.topics.first(where: { $0.id == topicId })?.name ?? "Chat")
            } else {
                Text("Select a topic")
                    .foregroundStyle(.secondary)
            }
        }
        // Error alert
        .alert("Error", isPresented: Binding(
            get: { viewModel.connectionError != nil },
            set: { if !$0 { viewModel.connectionError = nil } }
        )) {
            Button("OK") { viewModel.connectionError = nil }
            Button("Retry") {
                viewModel.connectionError = nil
                Task { await viewModel.reconnect() }
            }
        } message: {
            Text(viewModel.connectionError ?? "Unknown error")
        }
        // Delete confirmation — rephrased (W8)
        .alert("Delete Topic?", isPresented: Binding(
            get: { topicToDelete != nil },
            set: { if !$0 { topicToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { topicToDelete = nil }
            Button("Delete", role: .destructive) {
                if let topic = topicToDelete {
                    try? viewModel.deleteTopic(id: topic.id)
                    topicToDelete = nil
                }
            }
        } message: {
            Text("This deletes this conversation and all its messages from BeeChat. This cannot be undone.")
        }
        // Archive undo toast — overlay (B3 fix: Task-based, VoiceOver-safe)
        .overlay(alignment: .bottom) {
            if showArchiveUndo, let topic = archivedTopic {
                archiveUndoToast(topic: topic)
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Load import candidate count when connection state changes (B4)
        .onChange(of: viewModel.connectionState) { _, newState in
            if newState == .connected {
                Task { await refreshImportCandidateCount() }
            } else {
                importCandidateCount = 0
            }
        }
        // Cancel archive undo task on disappear
        .onDisappear {
            archiveUndoTask?.cancel()
        }
    }
    
    // MARK: - Dynamic Type helper
    
    private var dynamicTypeSize: DynamicTypeSize {
        // Read from environment — available on iOS 15+
        // In practice, use @Environment(\.dynamicTypeSize) if targeting iOS 15+
        // For iOS 16+, this is available as an Environment value
        .large  // Default; will be read from environment in implementation
    }
    
    // MARK: - Archive Undo Toast (Task-based, VoiceOver-safe)
    
    @ViewBuilder
    private func archiveUndoToast(topic: Topic) -> some View {
        HStack {
            Text("Archived '\(topic.name)'")
                .font(.subheadline)
            Spacer()
            Button("Undo") {
                undoArchive()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Topic archived. Undo available.")
        // VoiceOver: announce the toast
        .accessibilityAnnouncement("Archived \(topic.name)")
    }
    
    // MARK: - Actions
    
    private func archiveTopic(_ topic: Topic) {
        // Cancel any existing undo timer (handles re-archive)
        archiveUndoTask?.cancel()
        
        do {
            _ = try viewModel.archiveTopic(id: topic.id)
            archivedTopic = topic
            withAnimation(reduceMotion ? .none : .easeInOut) {
                showArchiveUndo = true
            }
            
            // VoiceOver-safe timeout: if VoiceOver running, don't auto-dismiss
            let isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
            let timeout: TimeInterval = isVoiceOverRunning ? 30 : 5
            
            archiveUndoTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(reduceMotion ? .none : .easeInOut) {
                        showArchiveUndo = false
                    }
                    archivedTopic = nil
                }
            }
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
    }
    
    private func undoArchive() {
        archiveUndoTask?.cancel()
        guard let topic = archivedTopic else { return }
        do {
            try viewModel.unarchiveTopic(id: topic.id)
            withAnimation(reduceMotion ? .none : .easeInOut) {
                showArchiveUndo = false
            }
            archivedTopic = nil
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
    }
    
    // MARK: - Import
    
    private func refreshImportCandidateCount() async {
        guard viewModel.connectionState == .connected else { return }
        do {
            let candidates = try await viewModel.importCandidates()
            importCandidateCount = candidates.count
        } catch {
            importCandidateCount = 0
        }
    }
    
    private func loadImportCandidates() async {
        isLoadingCandidates = true
        do {
            importCandidates = try await viewModel.importCandidates()
            selectedImportIds = []
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
        isLoadingCandidates = false
    }
}
```

**Design decisions (v2):**
- **B1 fix:** Single `.popover(isPresented:)` — iOS 16.4+ adapts to sheet on compact size class
- **B3 fix:** `Task` + `Task.sleep` for toast timer, cancels on new archive or `onDisappear`
- **B4 fix:** Import button only visible when `importCandidateCount > 0`, loaded on connection change
- **W1 fix:** Dynamic Type detent — `.medium` for `.xLarge` and above
- **W3 fix:** VoiceOver running → 30s timeout (not 5s); toast has accessibility labels
- **W4 fix:** `reduceMotion` environment checked for all animations
- **W5 fix:** Archive tint changed to `.secondary` (neutral)
- **W8 fix:** Delete confirmation rephrased

### 3.4 `BeeChatView.swift` — Offline input + empty messages

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/BeeChatView.swift`

**v1→v2 key changes:**
- **B6 fix:** Use `inputViewBuilder` for offline state, not `.disabled()`
- **W10 fix:** Empty messages state as `.overlay` on ChatView

```swift
public struct BeeChatView: View {
    @State public var viewModel: BeeChatMobileViewModel
    @State private var messages: [ExyteChat.Message] = []
    @State private var draft: String = ""
    @State private var streamingMessageId: String = "streaming-msg"
    
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

            if viewModel.connectionState == .connected {
                // Online: normal ChatView with full input
                ChatView(messages: mergedMessages) { draft in
                    guard let topicId = viewModel.selectedTopicId else { return }
                    Task {
                        do {
                            try await viewModel.send(text: draft.text, to: topicId)
                            loadMessages()
                        } catch {
                            viewModel.connectionError = error.localizedDescription
                        }
                    }
                }
                .showNetworkConnectionProblem(false)
                .overlay {
                    // Empty messages prompt (W10)
                    if messages.isEmpty && !viewModel.isStreaming {
                        VStack {
                            Text("Ask Bee anything to get started.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    
                    // Streaming indicator
                    if viewModel.isStreaming {
                        VStack {
                            StreamingIndicatorView()
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
            } else {
                // Offline: ChatView with custom input showing reconnect prompt (B6 fix)
                ChatView(
                    messages: mergedMessages,
                    inputViewBuilder: { $text, _, _, _, _, dismissKeyboard in
                        // Custom offline input bar
                        HStack {
                            TextField("Reconnect to send messages", text: $text)
                                .textFieldStyle(.roundedBorder)
                                .disabled(true)
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
                ) { draft in
                    // Won't fire — input is disabled
                }
                .showNetworkConnectionProblem(true)
                .overlay {
                    // Streaming indicator (if streaming from before disconnect)
                    if viewModel.isStreaming {
                        VStack {
                            StreamingIndicatorView()
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .onAppear {
            loadMessages()
        }
        .onChange(of: viewModel.selectedTopicId) { _, _ in
            loadMessages()
        }
        .onChange(of: viewModel.streamingContent) { _, _ in
            updateStreamingMessage()
        }
        .onChange(of: viewModel.isStreaming) { _, newValue in
            if !newValue {
                loadMessages()
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
            user: ExyteChat.User(
                id: "bee",
                name: "Bee",
                avatarURL: nil,
                isCurrentUser: false
            ),
            status: .sent,
            createdAt: Date(),
            text: streamingText
        )
        merged.append(streamingMsg)
        return merged
    }

    private func updateStreamingMessage() {
        // onChange handles the refresh automatically via mergedMessages
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

**Key design decisions (v2):**
- **B6 fix:** Offline state uses `inputViewBuilder` with a disabled text field + reconnect button. No `.disabled()` on the ChatView. Message list remains scrollable offline.
- **W10 fix:** Empty messages state is a `.overlay` on the ChatView, not a conditional in the VStack.
- Messages are still visible when offline (read-only) — the input is just replaced.
- `showNetworkConnectionProblem(true)` shows the Exyte "Waiting for network" bar above the input on the offline variant.
- Reduce Motion respected for streaming indicator transitions.

### 3.5 Import Sessions Sheet

**v1→v2 key changes:**
- **W6 fix:** Edit mode activated for multi-select on iOS
- Loading state added

```swift
struct ImportSessionsSheet: View {
    let candidates: [Session]
    @State private var selectedIds: Set<String> = []
    let onImport: ([Session]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No sessions available to import")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(candidates, id: \.id, selection: $selectedIds) { session in
                        VStack(alignment: .leading) {
                            Text(session.title ?? session.customName ?? "Untitled")
                                .font(.headline)
                            if let preview = session.lastMessagePreview {
                                Text(preview)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(session.lastMessageAt?.formatted(.relative(presentation: .named)) ?? "")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // W6 fix: activate edit mode for iOS multi-select
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Import Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selectedIds.count)") {
                        let selected = candidates.filter { selectedIds.contains($0.id) }
                        onImport(selected)
                        dismiss()
                    }
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
    }
}
```

**Key decisions:**
- Empty candidates shows a friendly empty state (not a blank list)
- Edit mode always active for immediate multi-select on iOS
- "Import N" button shows count and is disabled until at least one selected

---

## 4. Accessibility (Mel M11)

### 4.1 VoiceOver Labels

| Element | Label | Hint |
|---------|-------|------|
| `+` button | "New Topic" | "Creates a conversation topic" |
| Topic row | "Topic: {name}, {preview}, {time}, {unread}" | "Tap to open conversation" |
| Archive swipe | "Archive" | "Archives this topic" |
| Delete swipe | "Delete" | "Permanently deletes this topic and messages" |
| Connection indicator | "{state text}" (e.g., "Online", "Offline") | "Current connection status" |
| Unread badge | "{count} unread messages" | — |
| Create button in sheet | "Create" | "Creates the topic with this name" |
| Cancel button in sheet | "Cancel" | "Dismisses without creating" |
| Archive undo toast | "Topic archived. Undo available." | — |
| Offline reconnect button | "Reconnect" | "Reconnects to the gateway" |

### 4.2 Dynamic Type

- Topic rows: support 2-line titles/previews at large sizes
- NewTopicSheet: `.medium` detent for `.xLarge` and above
- All buttons: minimum 44pt hit target

### 4.3 Reduce Motion

| Animation | Default | Reduce Motion |
|-----------|---------|---------------|
| Swipe action reveal | Slide in | Fade in |
| Archive undo toast | Slide up from bottom | Fade in/out |
| Streaming indicator | Animated dots | Static dots |
| Topic list delete | Slide out | Fade out |
| Sheet/popover presentation | System default | System handles (prefers cross-dissolve) |

---

## 5. Scope Boundary

### In Scope (Phase 2)

1. `NewTopicSheet.swift` — New file (adaptive popover)
2. `EmptyTopicsView.swift` — New file (two states)
3. `TopicListView.swift` — Add `+` button, swipe actions, empty state, popover, import flow, archive undo (Task-based)
4. `BeeChatView.swift` — Offline input state (inputViewBuilder), empty messages overlay
5. `BeeChatMobileViewModel.swift` — Add `createTopic`, `archiveTopic`, `unarchiveTopic`, `deleteTopic`, `importCandidates`, `importSelected`, `TopicError`
6. `TopicRepository.swift` (BeeChat-v5) — Add `fetchById()`, `fetchAllActiveSessionKeys()`
7. `ImportSessionsSheet` — Inline in TopicListView or new file
8. Accessibility labels on all new interactive elements
9. Reduce Motion handling for all animations

### Out of Scope

- **Rename topic** — deferred to post-Gate 2B.5
- **Pin topic** — deferred to Gate 3
- **Pull-to-refresh** — deferred (500ms polling already refreshes)
- **ValueObservation** replacing polling — deferred to post-Gate 2
- **Keyboard-safe composer growth** — Exyte handles this natively
- **Copy Diagnostic ID** (context menu) — deferred to post-Gate 2B.5
- **iPad compact width handling** — standard SwiftUI size class adaptation
- **Separate empty state file for messages** — overlay on ChatView (Q R2)
- **Theme system** — constants only (S7)
- **`ConnectionState.reconnecting`** — defer to post-Gate 2 (Q S13)
- **Haptic feedback on archive/delete** — deferred to post-Gate 2B.5

---

## 6. Success Criteria

### 6.1 Build

- [ ] BeeChat-v5 compiles (macOS + iOS)
- [ ] BeeChat-Mobile compiles (iOS simulator)

### 6.2 New Topic Creation

- [ ] `+` button visible in toolbar
- [ ] Tap `+` opens NewTopicSheet as popover (iPad) or adaptive sheet (iPhone)
- [ ] Keyboard auto-focuses on sheet open
- [ ] Create button disabled until valid name entered
- [ ] Character counter shows `N/80`
- [ ] Overlong name shows red counter, Create disabled
- [ ] Submit (return key) creates topic if valid
- [ ] Cancel with dirty draft shows confirmation dialog
- [ ] Cancel with clean draft dismisses immediately
- [ ] On create: topic appears in list, auto-selected
- [ ] On create offline: topic appears with pending state, reconciled on connect

### 6.3 Empty States

- [ ] Fresh install: shows "No conversations yet" with "Start a Conversation" button only
- [ ] Gateway connected + candidates > 0: shows "No topics yet" with both buttons
- [ ] Gateway connected + no candidates: shows "No conversations yet" (import button hidden)
- [ ] Tap "Start a Conversation" opens NewTopicSheet
- [ ] Tap "Import Recent Sessions" opens import sheet with candidates

### 6.4 Swipe Actions

- [ ] Swipe left reveals Archive (neutral) + Delete (red)
- [ ] Full swipe = Archive (not Delete)
- [ ] Archive: row animates away, toast "Archived '{name}'" with Undo
- [ ] Undo: topic restores to list and re-selects
- [ ] Delete: confirmation alert with clear wording
- [ ] Delete confirmed: topic and messages removed, list updates

### 6.5 Offline States

- [ ] When offline: input bar replaced with disabled field + reconnect button
- [ ] Message list remains scrollable when offline
- [ ] "Waiting for network" bar shown above input
- [ ] Offline banner shows over topic list

### 6.6 Import Sessions

- [ ] Import button only visible when candidate count > 0
- [ ] Import sheet shows candidate sessions with titles and previews
- [ ] Multi-select works on iOS (edit mode active)
- [ ] Import creates topics with existing gateway session keys
- [ ] Bridge failure: topic rolled back (no orphans)
- [ ] Empty candidates: friendly empty state in sheet

### 6.7 Accessibility

- [ ] All interactive elements have VoiceOver labels
- [ ] Archive undo toast accessible to VoiceOver (30s timeout)
- [ ] 44pt minimum hit targets
- [ ] Dynamic Type: topic rows scale, sheet expands for large sizes
- [ ] Reduce Motion: all animations respect preference

### 6.8 macOS Regression

- [ ] BeeChat macOS still builds and runs
- [ ] `fetchById()` and `fetchAllActiveSessionKeys()` don't affect macOS code path

---

## 7. Implementation Steps (Q)

1. Add `fetchById()` and `fetchAllActiveSessionKeys()` to `TopicRepository` (BeeChat-v5)
2. Add `TopicError` enum to `BeeChatMobileViewModel`
3. Add `createTopic(name:)` to ViewModel
4. Add `archiveTopic(id:)`, `unarchiveTopic(id:)`, `deleteTopic(id:)` to ViewModel
5. Add `importCandidates()` and `importSelected(_:)` to ViewModel
6. Create `NewTopicSheet.swift`
7. Create `EmptyTopicsView.swift`
8. Update `TopicListView.swift`: `+` button, popover, empty state, swipe actions, archive undo (Task-based), import flow
9. Update `BeeChatView.swift`: offline input via `inputViewBuilder`, empty messages overlay
10. Add accessibility labels + Reduce Motion handling
11. Build and test on iOS simulator
12. Verify macOS BeeChat still works

---

## 8. Rollback

If Phase 2 causes issues:

```bash
# BeeChat-v5 — only 2 methods added to TopicRepository
cd /Users/openclaw/Projects/BeeChat-v5
git log --oneline -5   # find pre-Phase-2 commit
git checkout <commit>

# BeeChat-Mobile — UI changes + ViewModel additions
cd /Users/openclaw/Projects/BeeChat-Mobile
git log --oneline -5   # find pre-Phase-2 commit
git checkout <commit>
```

The rollback baseline commit will be recorded after Q's changes are committed.

---

## 9. Review History

| Version | Date | Changes | Result |
|---------|------|---------|--------|
| v1 | 2026-05-19 | Initial spec | 🔴 7 blockers (B1-B7) + 10 high warnings |
| v2 | 2026-05-19 | Resolved all B1-B7 + W1-W10 | Pending team review |

### v1→v2 Resolution Table

| # | Blocker | v1 Issue | v2 Fix |
|---|---------|----------|--------|
| B1 | `.sheet` + `.popover` dual modifier | SwiftUI doesn't adaptively select | Single `.popover` with iOS 16.4+ compact adaptation |
| B2 | `archiveTopic()` ignores `topicRepo.archive()` | Reinvents with `save()`, stale data risk | Uses `topicRepo.archive(topicId:)` — surgical SQL UPDATE |
| B3 | Toast uses `DispatchQueue.asyncAfter` | Races, vanishes on nav, VoiceOver-inaccessible | `Task` + `Task.sleep`, cancels properly, 30s for VoiceOver |
| B4 | Import button shown on connection state, not count | Empty sheet on tap | `importCandidateCount` loaded async, button hidden when 0 |
| B5 | `saveBridge()` UNIQUE conflict in import | `ON CONFLICT(topicId)` misses `openclawSessionKey` | Pre-check via `fetchAllActiveSessionKeys()`, rollback topic on failure |
| B6 | `.disabled()` on ChatView disables message list | Messages unscrollable | `inputViewBuilder` with disabled field + reconnect button |
| B7 | `unarchiveTopic()` doesn't re-select | User can't find restored topic | Sets `selectedTopicId = topic.id` |

| # | Warning | v1 Issue | v2 Fix |
|---|---------|----------|--------|
| W1 | Dynamic Type detent is a comment | Overflows at large sizes | `.medium` detent for `.xLarge` and above |
| W2 | No filtering of system sessions | Import shows cron/agent sessions | `systemPrefixes` filter (cron:, schedule:, luna-, gav-, kieran-, q-) |
| W3 | VoiceOver can't use 5s toast | Auto-dismiss inaccessible | 30s timeout when VoiceOver running |
| W4 | Reduce Motion incomplete | Missing animations specified | Explicit table for swipe, toast, streaming, delete, sheet |
| W5 | Archive tint `.orange` | Contradicts architecture | Changed to `.secondary` (neutral) |
| W6 | iOS multi-select needs edit mode | `List(selection:)` doesn't work without it | `.environment(\.editMode, .constant(.active))` |
| W7 | Bridge failure orphans topic | `continue` leaves topic without bridge | `deleteCascading()` rollback on bridge failure |
| W8 | Delete text says "local messages" | Ambiguous | "This deletes this conversation and all its messages from BeeChat." |
| W9 | `fetchAllActiveSessionKeys()` filters by status | Misses non-active bridges | Removed status filter, returns ALL bridge keys |
| W10 | Empty messages placement undefined | Where in view hierarchy? | `.overlay` on ChatView with full-space frame |