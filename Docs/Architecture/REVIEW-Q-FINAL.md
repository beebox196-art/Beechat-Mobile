# Q — Gate 2 Spec Review: Buildability & Complexity Pass

**Date:** 2026-05-15
**Angle:** Buildability, complexity, module structure, v5 integration, file count
**Verdict:** Mostly buildable, with several simplifications needed for stability and one critical prerequisite fix.

## 1. Buildability: Can this be built in the specified sub-gate order?

**Verdict: Mostly yes, with one ordering issue and one missing prerequisite.**

### Sub-gate 2A ordering: ✅ Sound
- AnyCodable fix → compile Core packages → open GRDB → write test data → render in Exyte. This works. No circular dependencies.

### Missing prerequisite: The app target isn't an app target yet
The current `Package.swift` defines `BeeChatMobile` as a **library**, not an executable/app target. The spec says to add `BeeChatMobile` as an executable target (the app), but SPM **cannot build iOS app targets** — you need an Xcode project or a `Package.swift` that uses `xcode` project generation.

**Fix needed:** The spec needs to clarify that `BeeChatMobile` (the app) will be an Xcode project target, not an SPM target. The SPM package should contain only `BeeChatMobileKit` and `BeeChatUI` as library targets. The Xcode project wraps them. This is the standard iOS app pattern — SPM for libraries, Xcode project for the app. The current project structure (single `BeeChatMobile` library target) needs restructuring anyway, so this is the right time to do it.

### Init order invariant is real but manageable
The spec correctly identifies that `DatabaseManager.shared.openDatabase(at:)` must be called before `SyncBridge` is created. This is a temporal coupling inherited from v5. The spec documents it with a `⚠️ INIT ORDER INVARIANT` comment, which is the right approach. No code change needed, but the ViewModel's `init` or a setup method needs to enforce this ordering.

### KeychainTokenStore: Already iOS-compatible
I checked the actual code. `KeychainTokenStore` uses `kSecAttrAccessibleAfterFirstUnlock` which works on both macOS and iOS. No `SecAccessControl` macOS-specific APIs are used. The spec's concern about "macOS `SecAccessControl` may need iOS adjustment" is **not actually an issue** — the implementation uses simple `kSecClassGenericPassword` + `kSecAttrService` + `kSecAttrAccount` which is platform-neutral. Gate 2A's `KeychainTokenStore+iOS.swift` may not be needed at all.

## 2. Unnecessary Complexity

### SyncBridgeDelegateHandler.swift — Unnecessary separate file
The spec lists `SyncBridgeDelegateHandler.swift` as a new file in the Kit module, but the delegate conformance is naturally part of the ViewModel. In v5, `SyncBridgeObserver` is a single `@MainActor @Observable` class that conforms to `SyncBridgeDelegate`. Splitting the delegate conformance into a separate file adds indirection without benefit — you'd still need to update ViewModel state from the delegate callbacks.

**Recommendation:** Merge the delegate conformance into `BeeChatMobileViewModel.swift` via an extension. This is exactly what v5 does with `SyncBridgeObserver`. One less file, one less indirection.

### Exyte `User` type mismatch
The spec defines `adamUser` and `beeUser` with the old Exyte `User(id:name:avatarURL:isCurrentUser:)` initializer. The current Exyte Chat code (2.7.10) has changed `User` to use a `type` enum instead of `isCurrentUser: Bool`. The actual initializer is:
```swift
User(id: String, name: String, avatarURL: URL?, avatarCacheKey: String? = nil, isCurrentUser: Bool)
```
This still works — `isCurrentUser` maps to `type == .current` internally. But the spec should note that `isCurrentUser` is a convenience initializer that sets `UserType.current` or `.other`. Not a blocker, just needs the right initializer call.

**Key issue:** The spec says `name: ""` for beeUser to "avoid avatar initials." This works — Exyte shows no initial when name is empty. Confirmed buildable.

### ConnectionStatusView, OfflineBannerView, EmptyStateView, StreamingIndicatorView — Could merge for MVP
These are 4 small view files that could be consolidated into 1-2 files for the initial build. `ConnectionStatusView` and `OfflineBannerView` are both connection-state UI — they could be a single `ConnectionViews.swift`. `EmptyStateView` is trivially small. `StreamingIndicatorView` is used only inside `BeeChatView`.

**Recommendation for initial build:** Consolidate to:
- `ConnectionViews.swift` (status indicator + offline banner)
- `BeeChatView.swift` (main chat + empty state inline)
- `StreamingIndicatorView.swift` (keep separate — it has non-trivial state logic)

This saves 2 files and fewer navigation jumps during initial build. Can split later.

### BeeChatMobileConfig — Slightly over-engineered for Gate 2
The config struct has `clientMode: String` which is always `"mobile"`. For Gate 2 (MVP), a simple `static let development` is sufficient. The full config with optionals for `gatewayURL` and `gatewayToken` is fine, but the `clientMode` field adds no value — `GatewayClient.Configuration` already derives `clientInfo.platform` from `#if os(iOS)`.

**Recommendation:** Drop `clientMode` from `BeeChatMobileConfig`. Let `GatewayClient.Configuration` handle platform detection via its existing `#if os(iOS)` logic.

## 3. Module Split: BeeChatMobileKit + BeeChatUI — correct for MVP

The split aligns with the dependency graph:
- `BeeChatMobileKit` → no UI dependencies, pure logic layer
- `BeeChatUI` → depends on ExyteChat + BeeChatMobileKit

This means Kit can be tested without rendering views, UI can be swapped later, and Mel can work on themes while Q works on Kit logic.

**One concern:** The spec says the app accesses `BeeChatMobileKit` **only through** `BeeChatUI` (Kieran's review removed the direct app dependency). This is wrong for the MVP. The app entry point needs to:
1. Create `BeeChatMobileConfig`
2. Create `BeeChatMobileViewModel`
3. Open the database (`DatabaseManager.shared.openDatabase`)
4. Call `viewModel.loadCachedData()` on launch

All of these are Kit-layer concerns. The app must directly depend on `BeeChatMobileKit`. The dependency graph should be:

```
BeeChatMobile (app)
├── BeeChatUI
│   ├── ExyteChat
│   └── BeeChatMobileKit
└── BeeChatMobileKit  ← direct dependency needed
```

**Fix:** Add `BeeChatMobileKit` as a direct app dependency. Kieran's review was incorrect on this point — the app needs to initialize the ViewModel and config, which are in Kit.

## 4. File Count: Revised

| File | Verdict | Notes |
|------|---------|-------|
| BeeChatMobileConfig.swift | ✅ Keep | Essential config |
| BeeChatMobileViewModel.swift | ✅ Keep | Core ViewModel |
| MessageMapper.swift | ✅ Keep | Essential mapping logic |
| KeychainTokenStore+iOS.swift | ⚠️ Likely unneeded | KeychainStore already iOS-compatible |
| SyncBridgeDelegateHandler.swift | ❌ Merge | Fold into ViewModel extension |
| BeeChatView.swift | ✅ Keep | Main chat view |
| SessionListView.swift | ✅ Keep | Navigation container |
| ConnectionStatusView.swift | 🔄 Merge | Into ConnectionViews.swift |
| OfflineBannerView.swift | 🔄 Merge | Into ConnectionViews.swift |
| EmptyStateView.swift | 🔄 Merge | Inline in BeeChatView |
| StreamingIndicatorView.swift | ✅ Keep | Has state logic |
| Theme/BeeChatTheme.swift | ✅ Keep | Theme config |
| BeeChatMobileApp.swift | ✅ Keep | App entry |
| Info.plist | ✅ Keep | Required |

**Revised count:** 11-12 new files (merge 3, drop 1). Lean and buildable.

## 5. v5 Integration Gotchas

### 5.1 Swift tools version mismatch — #1 build risk
The v5 Package.swift uses `swift-tools-version:6.0` with `swiftLanguageVersion(.v5)` per target. The mobile Package.swift uses `swift-tools-version:5.9`. 

Swift 6.0 package tools version means v5 requires Swift 6.0 toolchain to resolve. The mobile package at 5.9 may or may not work depending on Xcode version. Since the spec targets Xcode 26.x, this should be fine (Xcode 26 ships Swift 6+), but the mobile Package.swift needs to declare `swift-tools-version:6.0` to match v5's requirement, otherwise SPM may refuse to resolve the dependency graph.

**Fix:** Update mobile `Package.swift` `swift-tools-version` from `5.9` to `6.0`. Add `swiftLanguageVersion(.v5)` to each target to keep Swift 5 mode (matching v5's approach). This is a safe change — it doesn't change the language, it just declares compatibility.

### 5.2 AnyCodable fix must not break macOS build
The spec's NSNumber comparison for `Equatable` is iOS-safe, but v5's macOS app also depends on `AnyCodable`. The fix must be tested against both platforms, not just iOS. The NSNumber bridging works on macOS too (Cocoa bridging is universal), but the test should explicitly cover both paths.

### 5.3 GatewayClient.Configuration initialization
The spec shows `GatewayClient.Configuration(apiBaseURL:gatewayURL, token:token, clientInfo:.init(platform:"mobile", ...))`. Need to verify this matches the actual v5 API. The `clientInfo` parameter may be a different type or have different field names. Q should check `GatewayClient.swift` directly during Gate 2A.

### 5.4 DatabaseManager.shared is a singleton — no injection for testing
`DatabaseManager.shared` is a hard singleton. The spec doesn't add a protocol abstraction for it, which is correct for the MVP (don't over-abstract), but it means unit tests will hit a real SQLite file. This is acceptable for Gate 2 — add a protocol wrapper later if testing demands it.

## 6. Code I'd implement differently

### ViewModel init pattern
The spec shows `BeeChatMobileViewModel(config: BeeChatMobileConfig)` as the only initializer. For iOS app lifecycle, the ViewModel should support:
1. **Designated init with config** — for production use
2. **Convenience init using UserDefaults/Keychain** — for SwiftUI `@StateObject` creation (which requires parameterless init or init with `@ObservedObject`-compatible parameters)

SwiftUI's `@StateObject` creates the object once and persists it. If the ViewModel needs a config at init time, the app needs to pass it through `App` → `WindowGroup` → `ContentView`. This is workable but needs the app entry point to handle config creation before the ViewModel.

### StreamingMessage array management
The spec mentions `@Published var streamingMessages: [String: StreamingMessage]` on the ViewModel. This is correct, but the key should be the message ID (UUID), not the session ID. v5's `StreamingMessageTracker` uses message-level IDs. Using session ID would make it impossible to track multiple simultaneous streams in different sessions.

**Fix:** Key by message ID, not session ID.

## Summary

### Must fix before building:
1. **App target must be Xcode project target, not SPM** — SPM can't build iOS app bundles
2. **Add BeeChatMobileKit as direct app dependency** — app needs to create ViewModel and Config
3. **Update mobile Package.swift swift-tools-version to 6.0** — match v5's requirement
4. **Drop clientMode from BeeChatMobileConfig** — unnecessary, platform detection exists in v5

### Should fix for cleaner build:
5. **Merge SyncBridgeDelegateHandler into ViewModel extension** — follow v5's pattern
6. **Merge ConnectionStatusView + OfflineBannerView into ConnectionViews.swift** — reduce file count
7. **Merge EmptyStateView inline into BeeChatView** — trivial component
8. **KeychainTokenStore+iOS.swift likely unneeded** — v5's implementation is already iOS-compatible
9. **StreamingMessages should key by message ID, not session ID** — match v5's StreamingMessageTracker

### Nits:
10. **Exyte User initializer uses isCurrentUser convenience init** — works fine, just document it
11. **DatabaseManager.shared singleton** — fine for MVP, no protocol wrapper needed yet
12. **File count reduced from 15 to 11-12** — lean and buildable