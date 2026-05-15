# Gate 0 Fixes — iOS Platform Compatibility

**Date:** 2026-05-12  
**Agent:** Q  
**Validation:** ✅ `swift build` passed (4.24s)

---

## Changes Made

### 1. Package.swift — Added iOS platform declaration
**File:** `/Users/openclaw/Projects/BeeChat-v5/Package.swift`

Added `.iOS(.v17)` to the platforms array alongside the existing `.macOS(.v14)`.

```swift
platforms: [
    .macOS(.v14),
    .iOS(.v17)
],
```

### 2. DeviceCrypto.swift — Dynamic platform defaults
**File:** `/Users/openclaw/Projects/BeeChat-v5/Sources/BeeChatGateway/Auth/DeviceCrypto.swift`

Replaced hardcoded `platform: String = "macos"` and `deviceFamily: String = "desktop"` default parameter values with `#if os(iOS)` / `#if os(macOS)` conditional closures:

- `platform` defaults to `"ios"` on iOS, `"macos"` on macOS
- `deviceFamily` defaults to `"mobile"` on iOS, `"desktop"` on macOS

### 3. GatewayClient.swift — Three hardcoded "macos" strings
**File:** `/Users/openclaw/Projects/BeeChat-v5/Sources/BeeChatGateway/GatewayClient.swift`

#### Line ~31 — ClientInfo default
Replaced static `.init(id: "openclaw-macos", version: "1.0", platform: "macos", mode: clientMode)` with a conditional block that uses `"openclaw-ios"` / `"ios"` on iOS.

#### Line ~492 — Device identity platform parameter
Replaced hardcoded `platform: "macos"` and `deviceFamily: "desktop"` in the `DeviceCrypto.signChallenge` call with conditional closures.

#### Line ~517 — User-Agent string
Replaced hardcoded `"BeeChat/1.0 (macOS)"` with a conditional block returning `"BeeChat/1.0 (iOS)"` on iOS, `"BeeChat/1.0 (macOS)"` on macOS.

---

## Validation

```bash
cd /Users/openclaw/Projects/BeeChat-v5
swift build 2>&1
```

**Result:** ✅ Build completed successfully in 4.24s.

All targets compiled:
- BeeChatPersistence
- BeeChatGateway
- BeeChatSyncBridge
- BeeChatIntegrationTest
- BeeChatApp

**Warnings observed:** Pre-existing Swift 6 Sendable warnings in `AnyCodable.swift` and `SyncBridgeConfiguration.swift` — unrelated to our changes.

**No regressions:** Existing macOS build is unaffected. The `#if os(macOS)` paths preserve the original behavior on macOS.

---

## Issues Found

None. All changes are additive (iOS platform support) and backward-compatible (macOS behavior unchanged).
