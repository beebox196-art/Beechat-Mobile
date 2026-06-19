# Gate 2B.5 — Phase 2: UI Layer (v1)

**Status:** DRAFT — Initial team review
**Parent:** GATE-2B5-TOPIC-ARCHITECTURE-v2.md
**Depends on:** GATE-2B5-PHASE1-DATA-LAYER-v3.2.md (✅ Complete, committed)
**Date:** 2026-05-19
**Author:** Bee (Coordinator)

---

## 0. Context

Phase 1 (Data Layer) is complete and committed. The ViewModel now uses `[Topic]`, the persistence layer has `pendingGatewaySync`, `Migration012` is live, and all team reviews passed. The app builds and runs on the simulator with 3 seed topics.

**Phase 2 adds the UI layer** — the user-facing Topic management that makes the data layer useful. This covers:

1. **New Topic creation** (sheet/popover)
2. **Empty states** (no topics, no messages)
3. **Swipe actions** (Archive + Delete)
4. **Offline/error states** in the Topic context
5. **Accessibility** (VoiceOver, Dynamic Type)
6. **ViewModel additions** (createTopic, archiveTopic, deleteTopic, import sessions)

No data model changes. No persistence changes. All new code is in `BeeChatUI` + `BeeChatMobileKit`.

---

## 1. Codebase Audit (Current State After Phase 1)

### 1.1 Existing Files

| File | Package | Status | Phase 2 Changes |
|------|---------|--------|-----------------|
| `TopicListView.swift` | BeeChatUI | ✅ Uses `Topic` model (Phase 1 fix) | Add `+` button, swipe actions, empty state, sheet/popover |
| `BeeChatView.swift` | BeeChatUI | ✅ Session key resolution (Phase 1 fix) | Offline composer state, empty messages state |
| `ConnectionViews.swift` | BeeChatUI | ✅ ConnectionStatusView + OfflineBannerView | Minor: retry action wiring |
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
| `NewTopicSheet.swift` | BeeChatUI | Sheet (iPhone) / Popover (iPad) for creating topics |
| `EmptyTopicsView.swift` | BeeChatUI | Empty state for topic list (no conversations / import available) |

### 1.3 Key Design Constraints

- **No new data model changes** — Phase 1 established the model
- **No new persistence changes** — TopicRepository already has all methods needed
- **No theme system** — Constants only (S7 from Gate 2 spec)
- **No separate `EmptyStateView.swift`** for messages — inline in `BeeChatView` (Q R2 + Mel R2)
- **No `ConnectionStatusView` + `OfflineBannerView` split** — already merged in `ConnectionViews.swift`
- **macOS regression zero** — all changes are iOS-only (BeeChatUI + BeeChatMobileKit)

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

/// Errors for topic operations
public enum TopicError: LocalizedError {
    case nameRequired
    case nameTooLong(count: Int)
    
    public var errorDescription: String? {
        switch self {
        case .nameRequired: return "Topic name is required"
        case .nameTooLong(let count): return "Topic name must be 80 characters or less (currently \(count))"
        }
    }
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
/// Undo support: returns the archived topic for potential restoration.
public func archiveTopic(id: String) throws -> Topic? {
    guard var topic = topics.first(where: { $0.id == id }) else { return nil }
    topic.isArchived = true
    try persistenceStore.topicRepo.save(topic)
    
    // Refresh list
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    
    // If archived topic was selected, select the first remaining
    if selectedTopicId == id {
        selectedTopicId = topics.first?.id
    }
    
    return topic
}
```

**Note:** No separate `TopicRepository.archive()` method needed — `save()` with `isArchived = true` already works. The existing `fetchAllActiveWithCounts()` filters `WHERE isArchived = 0`.

### 2.3 `unarchiveTopic(id:)` — Undo archive

```swift
/// Restore an archived topic. Used for undo support.
public func unarchiveTopic(id: String) throws {
    // Fetch from DB (not topics array — archived topics aren't in it)
    let allTopics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    // Need to fetch archived — add a helper or use save directly
    // For now: create a fresh topic with the same ID and name
    // Actually, we need to read the topic from DB first
    guard let topic = try persistenceStore.topicRepo.fetchAllActive(limit: 1000)
        .first(where: { $0.id == id }) else { return }
    // Problem: fetchAllActive only returns non-archived. We need to update directly.
    try persistenceStore.topicRepo.save(Topic(
        id: topic.id, name: topic.name, isArchived: false,
        sessionKey: topic.sessionKey, createdAt: topic.createdAt, updatedAt: Date()
    ))
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
}
```

**Wait — this is a problem.** `TopicRepository` doesn't have a `fetchById()` method or a way to fetch archived topics. Let me add what we need:

### 2.4 `TopicRepository` additions (minimal, in BeeChat-v5)

**File:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/TopicRepository.swift`

Add one method for archive undo support:

```swift
/// Fetch a single topic by ID, regardless of archived status.
/// Used for undo operations where the topic may be archived.
public func fetchById(_ id: String) throws -> Topic? {
    try dbManager.reader.read { db in
        try Topic.fetchOne(db, key: id)
    }
}
```

And one method for the import sessions flow:

```swift
/// Fetch all active topics with their session keys.
/// Used by the import flow to check which sessions already have topics.
public func fetchAllActiveSessionKeys() throws -> Set<String> {
    try dbManager.reader.read { db in
        let bridges = try TopicSessionBridge
            .filter(Column("status") == "active")
            .fetchAll(db)
        return Set(bridges.map { $0.openclawSessionKey })
    }
}
```

**These are the only two new repository methods needed for Phase 2.** Everything else already exists from Phase 1.

### 2.5 `unarchiveTopic(id:)` — Revised with `fetchById`

```swift
/// Restore an archived topic. Used for undo support.
public func unarchiveTopic(id: String) throws {
    guard var topic = try persistenceStore.topicRepo.fetchById(id) else { return }
    topic.isArchived = false
    topic.updatedAt = Date()
    try persistenceStore.topicRepo.save(topic)
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    
    // Re-select if it was previously selected
    if selectedTopicId == nil {
        selectedTopicId = topics.first?.id
    }
}
```

### 2.6 `deleteTopic(id:)` — Delete a topic with cascading

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

**Note:** `deleteCascading()` already exists from Phase 1 — it deletes the topic, its bridge entries, and associated messages. No new persistence code needed.

### 2.7 `importSessions()` — Import recent gateway sessions as topics

```swift
/// Import recent gateway sessions as new topics.
/// Filters to sessions that don't already have a topic and appear to be
/// user-created (not cron/agent sessions).
///
/// Returns the number of topics created.
public func importSessions() throws -> Int {
    guard let bridge = syncBridge else {
        throw TopicError.gatewayNotConnected
    }
    
    // This must be called when connected — fetch sessions synchronously isn't possible
    // Actually, bridge.fetchSessions() is async. Need a different approach.
    // The import flow needs to:
    // 1. Fetch sessions from gateway (async)
    // 2. Filter to those without topics
    // 3. Create topics for selected ones
    
    // Design: async method that returns candidate sessions, then user selects
    // This is a two-step flow:
    // Step 1: importCandidates() -> [Session] (for the sheet)
    // Step 2: importSelected([Session]) -> Int (creates topics)
    
    return 0
}

/// Fetch candidate sessions that could be imported as topics.
/// These are gateway sessions that don't already have a local topic.
public func importCandidates() async throws -> [Session] {
    guard syncBridge != nil else {
        throw TopicError.gatewayNotConnected
    }
    
    let sessions = try await syncBridge!.fetchSessions()
    let existingKeys = try persistenceStore.topicRepo.fetchAllActiveSessionKeys()
    
    // Filter to sessions that don't already have a topic
    let candidates = sessions.filter { session in
        !existingKeys.contains(session.id)
    }
    
    // Filter to likely user-created sessions (not cron/agent)
    let beeChatCandidates = candidates.filter { session in
        (try? BeeChatSessionFilter.isBeeChatSession(session.id, topicRepo: persistenceStore.topicRepo)) == false
        // Wait — this is backwards. We want sessions that AREN'T BeeChat sessions?
        // No — we want sessions that look like user conversations.
        // The filter identifies sessions that HAVE topics.
        // For import, we want sessions that DON'T have topics but look like user sessions.
        // We need a different heuristic here.
        true  // For now: show all sessions without topics
    }
    
    return beeChatCandidates
}

/// Create topics from selected gateway sessions.
public func importSelected(_ sessions: [Session]) throws -> Int {
    var count = 0
    for session in sessions {
        // Create topic from session data
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
        } catch {
            print("[ViewModel] Bridge already exists for session \(session.id): \(error)")
            continue
        }
        count += 1
    }
    
    // Refresh
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    return count
}
```

**Key design decision:** Import is a two-step flow:
1. `importCandidates()` returns sessions for the user to browse
2. `importSelected(_:)` creates topics for the ones they pick

**Important difference from normal topic creation:** Imported topics use the **existing gateway session key** (not a new `agent:main:<uuid>` key). This preserves the message history from the gateway.

### 2.8 Error enum addition

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
}
```

---

## 3. UI Changes

### 3.1 `NewTopicSheet.swift` — New file

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/NewTopicSheet.swift`

**Spec:** Mel M6 (iPhone) + M7 (iPad)

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
        // iPad: fixed size popover
        // This is handled by the presenter, not the sheet itself
        // .presentationDetents for iPhone sheet
        // .frame(maxWidth: 360) for iPad popover
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
- `.presentationDetents([.height(220)])` is set by the presenter (TopicListView), not the sheet itself
- iPad gets `.popover` presentation which auto-sizes
- Keyboard auto-focuses on appear (Mel M6)
- Create disabled until valid text entered
- Dirty draft discard shows confirmation (Mel M6)
- Character counter shows `/80`
- No `.medium` detent for standard sizes — only for large Dynamic Type (handled in presenter)
- On submit (return key), creates if valid

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

2. **Import available** (no topics, but gateway connected + sessions exist):
   ```
   [BeeChat icon]
   No topics yet
   BeeChat now keeps your conversations organized as topics.
   
   [Start a Conversation]
   [Import Recent Sessions]
   ```

```swift
import SwiftUI

struct EmptyTopicsView: View {
    let hasImportableSessions: Bool
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

Changes from current state:

1. **Add `+` toolbar button** that opens `NewTopicSheet`
2. **Add empty state** when `topics.isEmpty`
3. **Add swipe actions** (Archive + Delete)
4. **Add sheet/popover presentation** for `NewTopicSheet`
5. **Add import sessions flow**

```swift
public struct TopicListView: View {
    @State public var viewModel: BeeChatMobileViewModel
    
    // Sheet state
    @State private var isShowingNewTopicSheet = false
    @State private var isShowingImportSheet = false
    
    // Import candidates (loaded async)
    @State private var importCandidates: [Session] = []
    @State private var selectedImportIds: Set<String> = []
    @State private var isLoadingCandidates = false
    
    // Archive undo
    @State private var archivedTopic: Topic? = nil
    @State private var showArchiveUndo = false
    
    // Delete confirmation
    @State private var topicToDelete: Topic? = nil
    
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
                        hasImportableSessions: viewModel.connectionState == .connected,
                        onStartConversation: { isShowingNewTopicSheet = true },
                        onImportSessions: viewModel.connectionState == .connected ? {
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
                            // Archive (default full-swipe action)
                            Button {
                                archiveTopic(topic)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.orange)
                            
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
            .sheet(isPresented: $isShowingNewTopicSheet) {
                NewTopicSheet(onCreate: { name in
                    do {
                        try viewModel.createTopic(name: name)
                    } catch {
                        viewModel.connectionError = error.localizedDescription
                    }
                })
                .presentationDetents([.height(220)])
                // For large Dynamic Type sizes, allow medium detent
                // .presentationDetents([.height(220), .medium]) — applied dynamically
            }
            .popover(isPresented: $isShowingNewTopicSheet) {
                // iPad gets popover instead of sheet
                NewTopicSheet(onCreate: { name in
                    do {
                        try viewModel.createTopic(name: name)
                    } catch {
                        viewModel.connectionError = error.localizedDescription
                    }
                })
                .frame(minWidth: 320, maxWidth: 360, minHeight: 220)
            }
            // Note: .sheet and .popover both attached — SwiftUI uses the
            // correct one based on size class. On compact (iPhone), .sheet.
            // On regular (iPad), .popover.
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
        // Delete confirmation alert
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
            Text("This permanently deletes the conversation and all local messages. This cannot be undone.")
        }
        // Archive undo toast
        .toast(isPresenting: $showArchiveUndo, duration: 5) {
            // Note: SwiftUI doesn't have a native toast. Use a simple overlay.
            // Alternative: use .overlay with a timed view.
            // For MVP: use a sheet with auto-dismiss or a custom view modifier.
        }
    }
    
    // MARK: - Actions
    
    private func archiveTopic(_ topic: Topic) {
        do {
            _ = try viewModel.archiveTopic(id: topic.id)
            archivedTopic = topic
            showArchiveUndo = true
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
    }
    
    private func undoArchive() {
        guard let topic = archivedTopic else { return }
        do {
            try viewModel.unarchiveTopic(id: topic.id)
            archivedTopic = nil
            showArchiveUndo = false
        } catch {
            viewModel.connectionError = error.localizedDescription
        }
    }
    
    // MARK: - Import
    
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

**Design decisions:**
- `+` button is in toolbar (primary action position) — standard iOS pattern
- Sheet on iPhone, popover on iPad — SwiftUI handles this with both modifiers attached
- **Full swipe = Archive** (not Delete) — Mel M8 specification
- Delete requires explicit confirmation alert (destructive action)
- Archive undo: 5-second window with toast + undo button
- Import flow: async loading of candidates, then selection sheet
- Accessibility labels on all interactive elements (Mel M11)

**Known issue — Toast:** SwiftUI doesn't have a native toast component. For the archive undo, I'll use a custom `ToastView` overlay or a simple bottom bar. This is a small component, not a separate file.

### 3.4 `BeeChatView.swift` — Offline composer + empty messages

**File:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/BeeChatView.swift`

Changes from current state:

1. **Disable composer when offline** with placeholder "Reconnect to send messages" (Mel M10)
2. **Empty messages state** — inline prompt (not separate file, Q R2 + Mel R2)

The current `ChatView` from Exyte doesn't natively support disabling the input bar. The cleanest approach is to overlay the input area when offline.

**Minimal approach:** When disconnected, show the `OfflineBannerView` at the bottom of the chat area (above where the input bar would be), and use a ZStack or overlay to disable/replace the input.

```swift
// Add to BeeChatView body, after the ChatView:
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
.disabled(viewModel.connectionState != .connected)  // Disable input when offline
```

**Note:** Exyte's `ChatView` may not support `.disabled()` on the input bar. If it doesn't, we'll need a different approach — possibly hiding the input bar and showing a placeholder. This needs Q's verification during implementation.

For empty messages (when a topic has no messages yet):

```swift
// Add inline empty state inside BeeChatView:
if messages.isEmpty && !viewModel.isStreaming {
    VStack {
        Spacer()
        Text("Ask Bee anything to get started.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        Spacer()
    }
}
```

This replaces the empty messages area with a lightweight prompt (Mel M9). No separate file needed.

### 3.5 Archive Undo Toast

SwiftUI doesn't have a native toast. I'll implement a lightweight toast as a `ViewModifier` inline in `TopicListView.swift` (not a separate file). The toast:

- Shows "Archived 'Topic Name'" with an Undo button
- Auto-dismisses after 5 seconds
- Appears at the bottom of the screen

```swift
// Simplified approach: overlay a toast view at the bottom
.overlay(alignment: .bottom) {
    if showArchiveUndo, let topic = archivedTopic {
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                showArchiveUndo = false
                archivedTopic = nil
            }
        }
    }
}
```

### 3.6 Import Sessions Sheet

A sheet showing candidate gateway sessions that can be imported as topics. Multi-select list with human-readable titles.

```swift
// Import sessions sheet — inline in TopicListView or a separate struct
struct ImportSessionsSheet: View {
    let candidates: [Session]
    @State private var selectedIds: Set<String> = []
    let onImport: ([Session]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
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

### 4.2 Dynamic Type

- Topic rows: support 2-line titles/previews at large sizes
- NewTopicSheet: expand to `.medium` detent for large accessibility sizes
- All buttons: minimum 44pt hit target

### 4.3 Reduce Motion

- Streaming indicator: static dots instead of animation
- Archive undo toast: no slide animation, just appear/disappear

---

## 5. Scope Boundary

### In Scope (Phase 2)

1. `NewTopicSheet.swift` — New file (sheet + popover)
2. `EmptyTopicsView.swift` — New file (two states)
3. `TopicListView.swift` — Add `+` button, swipe actions, empty state, sheet/popover, import flow, archive undo
4. `BeeChatView.swift` — Offline composer state, empty messages prompt
5. `BeeChatMobileViewModel.swift` — Add `createTopic`, `archiveTopic`, `unarchiveTopic`, `deleteTopic`, `importCandidates`, `importSelected`, `TopicError`
6. `TopicRepository.swift` (BeeChat-v5) — Add `fetchById()`, `fetchAllActiveSessionKeys()`
7. `ImportSessionsSheet` — Inline in TopicListView or new file (decide during implementation)
8. Accessibility labels on all new interactive elements

### Out of Scope

- **Rename topic** — deferred to post-Gate 2B.5
- **Pin topic** — deferred to Gate 3
- **Pull-to-refresh** — deferred (500ms polling already refreshes)
- **ValueObservation** replacing polling — deferred to post-Gate 2
- **Keyboard-safe composer growth** — Exyte handles this natively
- **Copy Diagnostic ID** (context menu) — deferred to post-Gate 2B.5
- **iPad compact width handling** — standard SwiftUI size class adaptation
- **Separate empty state file for messages** — inline in BeeChatView (Q R2)
- **Theme system** — constants only (S7)
- **`ConnectionState.reconnecting`** — defer to post-Gate 2 (Q S13)

---

## 6. Success Criteria

### 6.1 Build

- [ ] BeeChat-v5 compiles (macOS + iOS)
- [ ] BeeChat-Mobile compiles (iOS simulator)

### 6.2 New Topic Creation

- [ ] `+` button visible in toolbar
- [ ] Tap `+` opens NewTopicSheet (iPhone: sheet, iPad: popover)
- [ ] Keyboard auto-focuses on sheet open
- [ ] Create button disabled until valid name entered
- [ ] Character counter shows `N/80`
- [ ] Overlong name shows red counter, Create disabled
- [ ] Submit (return key) creates topic if valid
- [ ] Cancel with dirty draft shows confirmation dialog
- [ ] Cancel with clean draft dismisses immediately
- [ ] On create: topic appears in list, auto-selected, composer focused
- [ ] On create offline: topic appears with pending state, reconciled on connect

### 6.3 Empty States

- [ ] Fresh install: shows "No conversations yet" with "Start a Conversation" button
- [ ] Gateway connected, no topics: shows "No topics yet" with both buttons
- [ ] Tap "Start a Conversation" opens NewTopicSheet
- [ ] Tap "Import Recent Sessions" opens import sheet (when available)

### 6.4 Swipe Actions

- [ ] Swipe left reveals Archive (orange) + Delete (red)
- [ ] Full swipe = Archive (not Delete)
- [ ] Archive: row animates away, toast "Archived '{name}'" with Undo
- [ ] Undo: topic restores to list
- [ ] Delete: confirmation alert appears with destructive warning
- [ ] Delete confirmed: topic and messages removed, list updates

### 6.5 Offline States

- [ ] Composer disabled or placeholder "Reconnect to send messages" when offline
- [ ] Draft text preserved in composer (if possible with Exyte)
- [ ] Offline banner shows over topic list

### 6.6 Import Sessions

- [ ] Import button only visible when gateway connected
- [ ] Import sheet shows candidate sessions with human-readable titles
- [ ] Multi-select with Import button showing count
- [ ] Import creates topics with existing gateway session keys (preserving message history)
- [ ] Import failure: non-blocking banner "Could not load recent sessions"

### 6.7 Accessibility

- [ ] All interactive elements have VoiceOver labels
- [ ] Connection indicator: text state, not just colored dot
- [ ] 44pt minimum hit targets
- [ ] Dynamic Type: topic rows scale, sheet expands for large sizes

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
8. Update `TopicListView.swift`: `+` button, sheet/popover, empty state, swipe actions, archive undo, import flow
9. Update `BeeChatView.swift`: offline composer, empty messages prompt
10. Add accessibility labels to all new interactive elements
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