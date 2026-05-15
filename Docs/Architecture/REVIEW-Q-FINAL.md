# Gate 2 Spec Review: Buildability & Complexity

**Reviewer:** Q (Builder)
**Date:** 2026-05-15
**Spec:** `GATE2-SPEC.md` (Round 2 — final)
**Scope:** Buildability, v5 API mismatches, over-engineering, crash paths, build order

I've read the full spec and cross-referenced every claim against the actual v5 source code (`BeeChatPersistence`, `BeeChatGateway`, `BeeChatSyncBridge`) and the current demo (`BeeChatDemoView.swift`).

---

## BLOCKERS

### B1. AnyCodable `Equatable` is broken on iOS — the spec's fix is still wrong

**Source:** `BeeChatGateway/AnyCodable.swift` line 75

The current implementation:
```swift
return NSDictionary(object: lhs.value as Any, forKey: "v" as NSString)
    .isEqual(to: NSDictionary(object: rhs.value as Any, forKey: "v" as NSString))
```

The spec's corrected fix using `NSNumber` comparison is on the right track but has a **critical bug**: the `NSNumber` case will match `Bool` values before they're caught by the `Bool` case. In Swift, `Bool` bridges to `NSNumber` with `objCType "c"`. The spec tries to guard against this:

```swift
case let (a as NSNumber, b as NSNumber):
    let objCType = String(cString: NSNumber(value: a).objCType)
    if objCType == "c" || objCType == "B" { return false }  // Skip Bool masquerading as NSNumber
    return a == b
```

But this is **wrong**: if both values are actually `Bool`, the `Bool` case above will match first, so `return false` here is fine. However, if one value is `Bool` and the other is `Int` (e.g., `true` vs `1`), the `Bool` case won't match (because the `Int` won't match `as Bool`), so we fall through to `NSNumber` — and `NSNumber(value: true).objCType` is `"c"`, which hits the guard and returns `false`. That's correct behavior (`true != 1` in Swift semantics).

The **real problem**: the `NSNumber(value: a).objCType` line creates a **new** `NSNumber` from `a`, but `a` is already an `NSNumber`. On iOS, `NSNumber(value: a)` where `a` is already an `NSNumber` may not preserve the original objCType — it could normalize. This needs testing on iOS specifically. If it normalizes to a different type code, the Bool guard breaks.

**Recommendation:** Instead of the `NSNumber` approach, use an explicit type-ordered switch that handles `Bool` first, then all integer widths, then floating point:

```swift
case let (a as Bool, b as Bool): return a == b
case let (a as Int, b as Int): return a == b
case let (a as Double, b as Double): return a == b
case let (a as String, b as String): return a == b
// ... arrays and dicts with recursion
```

This avoids `NSNumber` entirely and is deterministic. The Swift runtime will match the most specific type first. After JSON decode, all values are `Bool`, `Int`, `Double`, `String`, `[Any]`, or `[String: Any]` — so this covers 100% of real-world values. For programmatically-created `Int64`/`UInt64`, we can add explicit cases, but these don't come through JSON decode.

**Severity:** Must fix before Gate 2A. The current `NSDictionary.isEqual` will silently produce wrong results on iOS (arrays always equal `false`, some numeric comparisons wrong). The spec's replacement has a subtle iOS-specific risk. Use the type-explicit switch.

---

### B2. Exyte `User` struct uses `UserType` enum, not `isCurrentUser` boolean

**Source:** Exyte Chat `User.swift`

The spec's `MessageMapper` creates users like:
```swift
static let adamUser = ExyteChat.User(id: "adam", name: "Adam", avatarURL: nil, isCurrentUser: true)
static let beeUser = ExyteChat.User(id: "bee", name: "", avatarURL: nil, isCurrentUser: false)
```

This actually works fine — Exyte's `User` has an `init(id:name:avatarURL:avatarCacheKey:isCurrentUser:)` that maps `isCurrentUser` to `type: .current` / `.other` internally. **However**, the spec says "empty name = no avatar initial." This is **incorrect**. Looking at Exyte's avatar rendering, an empty `name` string still renders a circular avatar area — it just shows nothing inside. The correct approach to suppress the "B" avatar initial is to set `avatarURL` to a transparent 1px image URL, OR check if Exyte supports `avatarURL: nil` gracefully (it does — nil avatar + non-empty name shows initials, nil avatar + empty name shows nothing useful but still takes space).

**Actually** the real issue: in the current demo, the assistant message uses `User(id: "bee", name: "Bee", ...)` which shows a "B" initial. The spec says `name: ""` fixes this. But Exyte's `User` with `name: ""` will still render a circle placeholder. We need to verify this renders correctly. If it doesn't, the fallback is a transparent pixel data URL for `avatarURL`.

**Severity:** Must verify in Gate 2A. Not a code blocker, but a visual bug if wrong. Test on simulator before proceeding.

---

### B3. `BeeChatPersistenceStore` is NOT `Sendable` — cross-actor boundary risk

**Source:** `BeeChatPersistenceStore.swift`

`BeeChatPersistenceStore` is a `class` (reference type) with no `Sendable` conformance. `SyncBridge` is an `actor`. The spec passes `BeeChatPersistenceStore` into `SyncBridgeConfiguration` which is a `struct` marked `Sendable`. In Swift 6 strict concurrency, this will emit a warning/error: **"Non-sendable type 'BeeChatPersistenceStore' cannot cross actor boundary."**

`SyncBridgeConfiguration` is marked `Sendable` and holds a `BeeChatPersistenceStore` instance:
```swift
public struct SyncBridgeConfiguration: Sendable {
    public let persistenceStore: BeeChatPersistenceStore  // NOT Sendable
```

This compiles in Swift 5 language mode (with warnings) but **will be an error in Swift 6**. The spec says to use `swiftLanguageVersion(.v5)` for all targets, so this won't block the build — but it will produce concurrency warnings.

**Severity:** Warning in Swift 5 mode, error in Swift 6. Not a blocker for Gate 2 (Swift 5 language mode), but must be tracked. Fix: make `BeeChatPersistenceStore` `@unchecked Sendable` or wrap it in an actor.

---

### B4. Package.swift has three critical mismatches vs spec

**Source:** `BeeChatMobile/Package.swift`

The current Package.swift:
1. **`swift-tools-version:5.9`** — spec says must be `6.0` (F4). v5 uses `6.0`.
2. **Exyte pinned `from: "2.1.0"`** — spec says must be `.exact("2.7.10")` (F1). The `from: "2.1.0"` will resolve to the latest compatible version (currently 3.1.0), which has breaking API changes.
3. **Single `BeeChatMobile` target** — spec requires splitting into `BeeChatMobileKit` + `BeeChatUI` library targets, with app target in Xcode project.

These are the Round 2 "Must Fix" items F1, F2, F4. The Package.swift as-is will not build correctly with the spec's module structure.

**Severity:** Must fix before any code is written. The Exyte version mismatch alone will cause build failures.

---

### B5. `ConnectionState` has no `.reconnecting` case — spec's UI implies it

**Source:** `BeeChatGateway/ConnectionState.swift`

```swift
public enum ConnectionState: String, Sendable, Codable {
    case disconnected, connecting, handshaking, connected, error
}
```

The spec's UX section lists UI states: `Offline`, `Connecting`, `Connected`, `Reconnecting`, `Error`. But `ConnectionState` has no `.reconnecting`. The v5 macOS app maps `.connecting` with a retry count to "reconnecting" in the UI. The mobile ViewModel needs a similar mapping or the UI will show "Connecting" during reconnection attempts, which is misleading.

**Severity:** Should fix in ViewModel mapping. Not a v5 change — just add a computed property:
```swift
var displayState: ConnectionDisplayState {
    switch connectionState {
    case .connecting: return retryCount > 0 ? .reconnecting : .connecting
    // ...
    }
}
```
But the ViewModel needs access to `GatewayClient.retryCount`, which is private. Either expose it, or infer `.reconnecting` from `.connecting` after an initial `.connected` has been seen.

**Severity:** Warning. The UI can say "Connecting…" for both, but "Reconnecting" is better UX. Can defer to post-Gate-2.

---

## WARNINGS

### W1. `DatabaseManager.shared` singleton — temporal coupling is fragile

**Source:** `DatabaseManager.swift`

`SyncBridge` initializes `DeliveryLedgerRepository(dbManager: DatabaseManager.shared)` and `Reconciler` in its `init`. If `DatabaseManager.shared.openDatabase(at:)` hasn't been called yet, all DB operations will throw `DatabaseManagerError.notOpen`. The spec documents this as an init-order invariant, but it's a runtime crash waiting to happen — there's no compile-time or assertion guard.

**Recommendation:** Add an assertion in `BeeChatMobileViewModel.init()`:
```swift
assert(persistenceStore != nil, "Call openDatabase before creating SyncBridge")
```
Or better: make `BeeChatMobileConfig.defaultDatabasePath()` the canonical place to open the DB, and have the ViewModel assert that the DB is open before proceeding.

---

### W2. `SyncBridgeDelegate` callbacks fire on SyncBridge's actor executor

**Source:** `SyncBridgeDelegate.swift`, `SyncBridge.swift`

The spec correctly identifies this (Kieran's finding, marked as #1 crash risk). Every delegate callback (`didUpdateConnectionState`, `didStartStreaming`, etc.) fires inside the `SyncBridge` actor. If the ViewModel conforms to `SyncBridgeDelegate` as a `@MainActor` class, calling `self.connectionState = state` directly from these callbacks is a **data race** — you're writing to a `@MainActor`-isolated property from a non-MainActor context.

The spec's fix (`nonisolated` + `Task { @MainActor in }`) is correct. But it introduces **ordering risk**: `Task { @MainActor in }` is not guaranteed to execute in order. Two rapid delegate callbacks (e.g., `didStartStreaming` then `didStopStreaming` within milliseconds) could have their `Task`s execute in reverse order on MainActor.

**Recommendation:** For Gate 2, accept this risk — streaming start/stop ordering is handled by the streaming buffer anyway. Post-Gate-2, consider `AsyncStream`-based observation where ordering is guaranteed.

---

### W3. `GatewayClient.Configuration.token` is `String` (not optional)

**Source:** `GatewayClient.swift`

```swift
public let token: String  // NOT optional
```

The spec's `BeeChatMobileConfig` has `gatewayToken: String?` (optional). But `GatewayClient.Configuration.init` requires a non-optional `token`. The "offline mode" where `gatewayToken` is `nil` cannot create a `GatewayClient` at all.

This is actually correct behavior — you can't connect without a token. But the spec's offline-first flow (Gate 2A) should NOT attempt to create a `GatewayClient` at all. The ViewModel should only create `GatewayClient` + `SyncBridge` when going online.

**Severity:** Warning. The spec's `connect()` code sample creates `GatewayClient` inside the method, which is fine. But the `BeeChatMobileConfig` should document that `gatewayURL` and `gatewayToken` are both required for online mode. The `nil` case means "offline only — don't create Gateway/SyncBridge."

---

### W4. `SyncBridge.init` creates internal dependencies eagerly

**Source:** `SyncBridge.swift` init

```swift
self.ledgerRepo = DeliveryLedgerRepository(dbManager: DatabaseManager.shared)
```

This hard-codes `DatabaseManager.shared` inside `SyncBridge.init`. The spec can't inject a different `DatabaseManager` — it must use the shared singleton. This is fine for MVP but means tests can't easily swap the DB.

**Severity:** Nit. Not a blocker. Tests can use in-memory SQLite via `DatabaseManager.shared.openDatabase(at: ":memory:")` (if GRDB supports it — it does via `DatabasePool`). Just be aware that multiple tests sharing `DatabaseManager.shared` will conflict unless each test opens/closes its own DB path.

---

### W5. `Message` model has no `status` field — the spec's optimistic send code is misleading

**Source:** `BeeChatPersistence/Models/Message.swift`

The v5 `Message` struct has no `status` field. The spec's Gate 2C code sample shows:
```swift
optimisticMessage.status = .error
```

This won't compile. `Message` doesn't have a `status` property. The spec's own "Message status mapping" section acknowledges this: "v5 doesn't have explicit delivery status on messages." The fix is to track send status separately in the ViewModel (a dictionary `[(messageId): ExyteChat.Message.Status]`), not by mutating v5's `Message`.

Gav's Round 2 finding (F6) already caught this: "Don't add status to Message. v5's SyncBridge.sendMessage already owns idempotency and delivery ledger." The spec's final action items agree. But the code sample in Gate 2C still shows `optimisticMessage.status = .error`, which is misleading.

**Severity:** Warning. The implementation must NOT try to add a `status` field to v5's `Message`. Track status in the ViewModel's mapping layer instead.

---

### W6. Exyte `Message.Status.error` requires a `DraftMessage` — can't just set `.error`

**Source:** Exyte Chat `Message.swift`

```swift
public enum Status: Equatable, Hashable, Sendable {
    case sending, sent, delivered, read
    case error(DraftMessage)  // NOT just .error
}
```

The spec mentions "inline retry affordance" for failed messages, but Exyte's `.error` case requires a `DraftMessage` (containing the text to retry). This is actually helpful — it gives us the retry text for free. But the implementation must create a `DraftMessage` from the failed message text, not just set `.error`.

**Severity:** Warning. Not a blocker, but the ViewModel must map to `Message.Status.error(DraftMessage(text: originalText))` rather than just `.error`. This is actually better than a bare `.error` state.

---

### W7. `BeeChatPersistenceStore` uses synchronous DB methods — all calls are blocking

**Source:** `BeeChatPersistenceStore.swift`

Methods like `fetchSessions(limit:offset:)`, `upsertSessions(_:)`, `saveMessage(_:)` are all synchronous `throws` functions. When called from `@MainActor` ViewModel, they'll block the main thread.

`SyncBridge` (an actor) calls these from its own executor, which is fine. But the ViewModel's `loadCachedData()` (Gate 2A offline path) calls `persistenceStore.fetchSessions()` directly — this runs on MainActor and blocks the UI.

**Recommendation:** Wrap DB reads in `Task.detached` for Gate 2:
```swift
func loadCachedSessions() async {
    let sessions = await Task.detached {
        try? self.persistenceStore.fetchSessions(limit: 100, offset: 0)
    }.value
    self.sessions = sessions ?? []
}
```
Or use GRDB's `ValueObservation` (Gav's S6 recommendation) which is async-friendly.

---

## NITS

### N1. `BeeChatMobileConfig.defaultDatabasePath()` uses force-unwrap

**Spec code:**
```swift
let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
```

On iOS this will never be nil, but defensive coding says use `guard let` with a fallback. Not a real risk on iOS.

---

### N2. `ChatHistoryMessage.timestamp` is `TimeInterval` (Double), but v5 `Message.timestamp` is `Date`

**Source:** `GatewayRPCResponses.swift` — `ChatHistoryMessage.timestamp: TimeInterval`
**Source:** `BeeChatPersistence/Models/Message.swift` — `Message.timestamp: Date`

The spec's `MessageMapper` will need `Date(timeIntervalSince1970: historyMessage.timestamp)`. The existing `SyncBridge.fetchHistory` already does this conversion. Not a bug, just something to be aware of.

---

### N3. `SessionInfo.totalTokens` is `Int?`, but `SyncBridge.fetchSessions` passes it to `Session.totalTokens: Int?`

This is correct — both are `Int?`. No mismatch. Just noting for completeness.

---

### N4. Demo `BeeChatDemoView.swift` uses `DispatchQueue.main.asyncAfter` for streaming

The current demo simulates streaming with `Timer.scheduledTimer`. The real implementation will use `SyncBridge.streamingContent(for:)` polling. The demo code will be deleted entirely (replaced by `BeeChatView` + ViewModel), so this isn't a concern.

---

### N5. `SyncBridge.messageStream(sessionKey:)` uses `ValueObservation` with `scheduling: .mainActor`

**Source:** `SyncBridge.swift`

This is perfect for the mobile ViewModel — it already delivers DB changes on MainActor. The ViewModel should subscribe to this stream rather than polling. This is exactly Gav's S6 recommendation. Use it.

---

### N6. v5 `Package.swift` uses `swift-tools-version:6.0` with `swiftLanguageVersion(.v5)` per target

The mobile Package.swift must match. The spec says `6.0` — confirmed correct.

---

### N7. `BeeChatSessionFilter.isBeeChatSession` creates a new `TopicRepository()` each call

**Source:** `SessionKeyNormalizer.swift`

This creates a new `TopicRepository()` (which uses `DatabaseManager.shared`) on every call. For the mobile app, topics aren't used (no topic-based sessions). This function won't be called in the mobile flow, so it's fine. But if it is called, it's inefficient.

---

## BUILD ORDER ASSESSMENT

The spec's sub-gate structure (2A→2B→2C→2D) is correct and well-sequenced:

1. **Gate 2A** (offline DB) is properly isolated — no network needed, tests pure data flow
2. **Gate 2B** (live connection) builds on 2A by adding `SyncBridge` lifecycle
3. **Gate 2C** (send/receive) builds on 2B by adding outbound message flow
4. **Gate 2D** (reconnect) builds on 2C by adding resilience

Each gate has clear exit criteria that can be verified on simulator.

The module structure (`BeeChatMobileKit` → `BeeChatUI` → App) is correct. The dependency graph is acyclic and each layer has a clear responsibility.

---

## SUMMARY

| Category | Count | Items |
|----------|-------|-------|
| **BLOCKER** | 2 | B1 (AnyCodable fix still has risk), B4 (Package.swift must-fix mismatches) |
| **BLOCKER (verify)** | 1 | B2 (Exyte avatar with empty name — test on simulator) |
| **BLOCKER (deferred)** | 1 | B3 (PersistenceStore not Sendable — Swift 5 warnings OK, Swift 6 error) |
| **WARNING** | 7 | W1-W7 (temporal coupling, callback ordering, token non-optional, eager init, Message.status, Exyte error type, blocking DB) |
| **NIT** | 7 | N1-N7 |

### Must-fix before coding starts:
1. **Fix Package.swift** — swift-tools-version 6.0, Exyte exact pin 2.7.10, split into Kit + UI targets
2. **Fix AnyCodable** — use type-explicit switch, not NSNumber comparison
3. **Don't add `status` to v5 Message** — track in ViewModel mapping layer
4. **App target must be Xcode project** — SPM can't build iOS app bundles

### Must-verify on first simulator run:
1. **Exyte empty-name avatar** — confirm `name: ""` suppresses the "B" initial, or use transparent pixel URL

### Can defer to post-Gate-2:
1. `BeeChatPersistenceStore` Sendable conformance
2. `.reconnecting` UI state (just show "Connecting…" for both)
3. `ValueObservation` for session/message lists (manual refresh works for MVP)
4. Topic-based session filtering (mobile uses gateway keys directly)

The spec is solid. The architecture is sound. The v5 Core packages are well-structured and the bridge pattern is correct. The main risks are the known AnyCodable bug and Package.swift mismatches — both are fixable before any code is written. After those fixes, Gate 2A should compile and run on the first attempt.