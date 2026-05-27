# Gate 2B5 Phase 2 v3.1 — Build Summary

**Date:** 2026-05-27  
**Builder:** Q  
**Spec:** [GATE-2B5-PHASE2-SPEC-v3.1.md](./GATE-2B5-PHASE2-SPEC-v3.1.md)  
**Status:** ✅ BUILT & VALIDATED

---

## Changes Made

### 1. `TopicSyncPayload.swift` — NEW
**Path:** `BeeChatMobile/Sources/BeeChatMobileKit/TopicSyncPayload.swift`

- `TopicSyncPayload` struct: `v`, `timestamp`, `topics` array
- `TopicPayloadItem` struct: `id`, `name`, `sessionKey`, `isArchived`, `lastActivityAt`, `lastMessagePreview`
- `extract(from:)` static method parses JSON from message content, handles both pure JSON and wrapped content
- Size guard: rejects payloads > 50KB
- Validation: requires `v == 1`, requires `topics` to be an array
- Empty payload guard: returns `nil` if `topics` array is empty

### 2. `BeeChatMobileViewModel.swift` — MODIFIED
**Path:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

**Added:**
- `readSyncSession(bridge:)` — fetches history from well-known sync session key `agent:main:beechat-sync`, parses payload
- `reconcileFromPayload(_:)` — reconciliation logic: match by `sessionKey` first, then by `id`; update/create topics; archive orphaned Mac-origin topics; UserDefaults staleness guard (`beechat_lastSyncTimestamp`)

**Removed:**
- `reconcileFromGateway()` method — deleted entirely
- `fetchSessionInfos()` call in `connect()` — deleted
- `BeeChatSessionFilter.isBeeChatSession()` usage — removed entirely
- `syncMetadataFromSessions()` call — deleted

**Modified:**
- `connect()`: after `bridge.start()`, calls `readSyncSession()` then `reconcileFromPayload()` if payload found; standalone mode if no payload
- `didReceiveSessionChange()`: reacts only to `agent:main:beechat-sync` key changes, calls `readSyncSession()` + `reconcileFromPayload()`

### 3. `MessageMapper.swift` — MODIFIED
**Path:** `BeeChatMobile/Sources/BeeChatUI/MessageMapper.swift`

- Dedup window: `2.0` → `10.0` seconds
- Added ≥20 character guard: only dedups messages where `content.count >= 20`
- User-role filter preserved

### 4. `SyncBridge.swift` — VERIFIED (no changes needed)
**Path:** `BeeChat-v5/Sources/BeeChatSyncBridge/SyncBridge.swift`

- Already calls `dedupLocalMessages(sessionKey:)` after `fetchHistory()` in both `processChatFinal()` and `processChatError()`

### 5. `MessageRepository.swift` — VERIFIED (no changes needed)
**Path:** `BeeChat-v5/Sources/BeeChatPersistence/Repositories/MessageRepository.swift`

- Already has `dedupLocalMessages(sessionKey:)` method implementing the required SQL dedup logic (1:1 matching, user role, ≥20 char prefix, 10s window)

### 6. Xcode Project — FIXED
**Path:** `BeeChatMobile/BeeChatMobile.xcodeproj/project.pbxproj`

- Fixed UUID collision on `TopicSyncPayload.swift` file reference (same UUID as its PBXBuildFile entry caused "unrecognized selector" crash)
- Changed fileRef UUID suffix from `C06D06` to `C06D07`

---

## Build Verification

### iOS Target
```bash
xcodebuild -project BeeChatMobile.xcodeproj -scheme BeeChatMobile -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO
```
**Result:** ✅ BUILD SUCCEEDED

### macOS Target (BeeChat-v5)
```bash
cd /Users/openclaw/Projects/BeeChat-v5 && swift build
```
**Result:** ✅ BUILD SUCCEEDED (one pre-existing warning in `MainWindow.swift` — unused `sessionKey` — unrelated to this change)

---

## Notes

- Mac app code was **not touched**; compiles unchanged
- `reconcileFromGateway()` was **fully removed** — no fallback kept
- `BeeChatSessionFilter.isBeeChatSession()` usage was **fully removed** from ViewModel
- `Topic.init(...)` + `topicRepo.save()` used for payload-derived topics (not `create()`)
- Empty payload guard implemented: returns nil when `topics` array is empty
