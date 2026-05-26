# Gate 2F — Mac App Wiring Changes

**Purpose:** The shared package infrastructure for topic sync is complete and reviewed. The iPhone app has reconciliation code. But the Mac app never *publishes* topic metadata to the gateway, so the iPhone has nothing to sync from. These 3 wiring changes connect what's already built.

**Rule:** No existing code is removed or changed. Only additive calls in the right places.

---

## Change 1: Publish all topics on startup

**File:** `Sources/App/AppRootView.swift`

**After** `self.connectionState = .connected` (line ~105), add:

```swift
// Publish all existing topic metadata to gateway for cross-device sync
Task {
    await bridge.reconcileAllTopicState()
}
```

**Why:** On startup, the Mac needs to push all its topic metadata to the gateway so the iPhone can discover them. `reconcileAllTopicState()` already exists in `SyncBridge` — it iterates all local topics and calls `publishTopicState()` for each.

---

## Change 2: Publish topic state on create, edit, delete

**File:** `Sources/App/UI/MainWindow.swift`

### 2a: After topic creation (line ~417, after the `sendMessage` block)

Add after the `print("[MainWindow] Gateway session created...")` line:

```swift
// Publish new topic metadata to gateway for cross-device sync
await bridge.publishTopicState(topic: newTopicForContext, sessionKey: gatewayKey)
```

Add after the `print("[MainWindow] Gateway session creation failed...")` line in the `catch` block:

```swift
// Still try to publish metadata even if session creation failed
try? await bridge.publishTopicState(topic: newTopicForContext, sessionKey: gatewayKey)
```

### 2b: After topic edit (line ~457, inside `saveTopicEdits`)

After the existing `requeueContextInjection` call (the `if oldProjectPath != newProjectPath` block), add:

```swift
// Publish updated topic metadata to gateway for cross-device sync
if let sessionKey = updatedTopic.sessionKey, let bridge = appState.syncBridge {
    await bridge.publishTopicState(topic: updatedTopic, sessionKey: sessionKey)
}
```

### 2c: After topic delete (line ~440, inside `deleteTopic`)

After `try topicRepo.deleteCascading(id)`, add:

```swift
// Clear topic metadata from gateway for cross-device sync
if let sessionKey = messageViewModel.topics.first(where: { $0.id == id })?.sessionKey,
   let bridge = appState.syncBridge {
    try? await bridge.clearTopicState(sessionKey: sessionKey)
}
```

**Note:** The `clearTopicState` call must happen *before* `deleteCascading` removes the topic from local state. Reorder the delete method so the gateway clear happens first:

```swift
private func deleteTopic(_ id: String) {
    Task { @MainActor in
        do {
            let topicRepo = TopicRepository()
            // Clear gateway metadata before local delete
            if let topic = try topicRepo.fetchById(id),
               let sessionKey = topic.sessionKey,
               let bridge = appState.syncBridge {
                try? await bridge.clearTopicState(sessionKey: sessionKey)
            }
            try topicRepo.deleteCascading(id)
            messageViewModel.removeTopic(id: id)
        } catch {
            print("🔴 Delete topic failed: \(error)")
            deleteErrorMsg = error.localizedDescription
            showDeleteAlert = true
        }
    }
}
```

---

## Change 3: Handle `sessions.changed` in SyncBridgeObserver

**File:** `Sources/App/UI/Observers/SyncBridgeObserver.swift`

Add the delegate method implementation (after the `didStopManualReset` method, around line 285):

```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        // When sessions change on the gateway, re-publish all topic metadata
        // to keep the gateway in sync with our local state
        await bridge.reconcileAllTopicState()
    }
}
```

**Why:** When another device (iPhone) creates/updates a session, the gateway fires `sessions.changed`. The Mac should re-publish its state so it stays authoritative. This is safe because `reconcileAllTopicState` is idempotent — it just writes the current Mac state to the gateway.

---

## Verification

After making these 3 changes:

1. **Build the Mac app** — should compile clean, no errors
2. **Launch Mac app** — existing topics should still work as before
3. **Check Xcode console** — look for `[SyncBridge] publishTopicState` messages on startup
4. **Create a new topic** — should publish to gateway
5. **Edit a topic** — should update gateway metadata
6. **Delete a topic** — should clear gateway metadata
7. **Launch iPhone app** — topics from Mac should appear within seconds

No tests needed — these are wiring calls to existing, tested methods. The exit criteria is: Mac topics appear on iPhone.