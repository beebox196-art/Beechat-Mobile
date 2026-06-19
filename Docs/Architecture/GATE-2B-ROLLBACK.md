# Gate 2B — Rollback Plan

**Created:** 2026-05-18
**Author:** Bee (orchestrator)
**Status:** Active — pre-change documentation

---

## Baseline (Known Good State)

### BeeChat-v5 (macOS app + shared packages)
- **Commit:** `8edfafa` — fix(AnyCodable): type-explicit Equatable switch for iOS compatibility
- **Location:** `/Users/openclaw/Projects/BeeChat-v5/`
- **macOS BeeChat status:** Working, connects to gateway, full scopes

### BeeChat-Mobile
- **Commit:** `3ca8587` — status: Gate 2B in progress (WebSocket connects, scope issue pending)
- **Location:** `/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/`
- **iOS Simulator status:** Builds and runs, connects to gateway, but `sessions.subscribe` fails with "missing scope: operator.read"

### Gateway
- **Port:** 18789
- **Config:** `allowInsecureAuth: true` (local loopback only)
- **Status:** Running, healthy

---

## Changes Planned

### Change 1: GatewayClient.swift — Always send device identity
**File:** `/Users/openclaw/Projects/BeeChat-v5/Sources/BeeChatGateway/GatewayClient.swift`
**Lines:** ~443-497 (the `performHandshake()` method)
**Current code:**
```swift
var deviceIdentity: ConnectParams.DeviceIdentity? = nil
if currentDeviceToken != nil {  // ← THIS GUARD IS THE BUG
    print("[GW] performHandshake — building device identity (have deviceToken)")
    do {
        let keyPair = try DeviceCrypto.getOrCreateKeyPair()
        // ... build device identity ...
    } catch {
        print("[GW] Device identity build failed: \(error)")
    }
}
```
**New code:**
```swift
// ALWAYS build device identity — needed for pairing flow on first connect
// The gateway clears scopes for connections without device identity (except Control UI).
// With device identity, local connections get auto-paired and full scopes.
do {
    let keyPair = try DeviceCrypto.getOrCreateKeyPair()
    // ... build device identity unconditionally ...
} catch {
    print("[GW] Device identity build failed: \(error)")
    // Connection will proceed without device identity, but scopes may be limited
}
```
**Impact:** Both macOS BeeChat and iOS BeeChat use this code path.
- macOS BeeChat currently works via `preserveInsecureLocalControlUiScopes` bypass. After fix, it works via proper device identity path. Same result, more secure.
- iOS BeeChat currently fails (scopes cleared). After fix, it auto-pairs and gets full scopes.

### Change 2: BeeChatMobileConfig.swift — clientMode "ui" for iOS
**File:** `/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileConfig.swift`
**What:** The iOS app's `GatewayConfigLoader` must set `clientMode: "ui"` (not `"webchat"`) so the gateway recognises it as a native app UI client for auto-pairing.
**Impact:** iOS-only. Does not affect macOS BeeChat at all.

### Change 3: GatewayConfigLoader.swift — Use homeDirectoryForCurrentUser on simulator
**File:** `/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/Sources/BeeChatMobileKit/GatewayConfigLoader.swift`
**What:** Fix `NSHomeDirectory()` → `FileManager.default.homeDirectoryForCurrentUser` for reading `~/.openclaw/openclaw.json` on simulator.
**Impact:** iOS simulator only. Does not affect macOS BeeChat.

---

## Rollback Procedure

### If macOS BeeChat breaks after Change 1:
```bash
# Revert BeeChat-v5 to known-good commit
cd /Users/openclaw/Projects/BeeChat-v5
git checkout 8edfafa -- Sources/BeeChatGateway/GatewayClient.swift
# Rebuild macOS BeeChat in Xcode
```
**Risk:** Minimal. Change 1 only affects the `performHandshake()` conditional. Reverting restores the `if currentDeviceToken != nil` guard.

### If iOS BeeChat has issues after Changes 2 or 3:
```bash
# Revert BeeChat-Mobile to known-good commit
cd /Users/openclaw/Projects/BeeChat-Mobile
git checkout 3ca8587 -- BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileConfig.swift
git checkout 3ca8587 -- BeeChatMobile/Sources/BeeChatMobileKit/GatewayConfigLoader.swift
# Clean rebuild
cd BeeChatMobile
rm -rf build/DerivedData
xcodegen generate && xcodebuild ...
```

### Nuclear option — revert everything:
```bash
# Reset both repos to their pre-change states
cd /Users/openclaw/Projects/BeeChat-v5 && git checkout 8edfafa
cd /Users/openclaw/Projects/BeeChat-Mobile && git checkout 3ca8587
```

---

## Validation Checklist (Post-Change)

### macOS BeeChat (must NOT regress):
- [ ] App launches and connects to gateway
- [ ] Messages appear in real-time
- [ ] Sessions list loads
- [ ] Streaming text works
- [ ] No scope errors in gateway logs

### iOS BeeChat Mobile (must IMPROVE):
- [ ] App launches on simulator
- [ ] Connects to gateway at 127.0.0.1:18789
- [ ] Auto-pairing occurs (check gateway logs for `silentLocalPairing` or `deviceToken` in hello-ok)
- [ ] `sessions.subscribe` succeeds (no "missing scope" error)
- [ ] Messages render in real-time
- [ ] Session list updates on sessions.changed
- [ ] Offline banner shows when disconnected

---

## Risk Assessment

| Scenario | Likelihood | Impact | Mitigation |
|----------|-----------|--------|------------|
| macOS BeeChat stops connecting | Low | High | Rollback Change 1 (one `git checkout` command) |
| iOS auto-pairing fails | Medium | Medium | Fall back to manual `openclaw devices approve` |
| Keychain access fails on simulator | Low | Low | Device identity build fails gracefully, connection proceeds with limited scopes |
| Gateway rejects new device identity | Low | High | Same rollback as above |

**Overall risk: LOW.** The changes are small, well-understood, and easily reversible.