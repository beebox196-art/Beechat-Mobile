# Gate 2F Phase 1: Mac-Side Topic Publishing — Kieran Adversarial Review

**Date:** 2026-05-22
**Reviewer:** Kieran (Adversarial)
**Spec:** `GATE-2F-PHASE1-MAC-PUBLISHING.md`
**Existing code reviewed:** `RPCClient.swift`, `SyncBridge.swift`, `GatewayClient.swift`, `BeeChatTopicMetadata.swift`, `SyncBridgeConfiguration.swift`

---

## BLOCKERS

### K-B1: Half-published ghost topic — `pluginPatch` succeeds, `patch` fails

**Spec order:** metadata FIRST, label SECOND. This is the right ordering, but the failure path is hand-waved.

The spec says: if `pluginPatch` fails, `return` (skip `sessionsPatch`). That's fine — no ghost. But the inverse path is broken:

- `pluginPatch` succeeds → `BeeChatTopicMetadata` is stored on gateway
- `sessionsPatch` fails (network blip, timeout, scope revoked mid-flight)
- Gateway now has a session with `beechat.metadata.topicId` but `label` is the old value or empty
- iPhone receives `sessions.changed`, calls `sessions.list`, sees metadata with no matching label
- iPhone renders topic name as... what? The parent spec v2 says `session.label ?? "(untitled)"`. So it shows "(untitled)" with a UUID in the metadata.

This is a **silent corruption**, not a crash. User sees "(untitled)" topic on iPhone. They delete it. Mac still has the real topic. Now Mac's `reconcileAllTopicState()` will republish on next reconnect, resurrecting the ghost. **Zombie topic.**

**Fix required:** `publishTopicState` needs a retry mechanism for the second call, not just a log. At minimum: if `sessionsPatch` fails after `pluginPatch` succeeds, re-queue a delayed retry. The existing "fire-and-forget, reconcile handles it" defence is too slow — reconcile only fires on reconnect, which could be hours or never if connection is stable but that one call failed.

### K-B2: `operator.admin` scope is asserted, not verified

The spec has a table saying Mac has `operator.admin`. The exit criteria say "Mac client confirms `operator.admin` in handshake response." But there is **no code specified** that checks the handshake response scopes before publishing.

Looking at `GatewayClient.performHandshake()`: the Mac *requests* `["operator.read", "operator.write", "operator.admin", "operator.approvals", "operator.pairing"]` as desired scopes. The handshake response is decoded into `HelloOk` which has `auth?.scopes`. But:

1. Nothing in the spec reads `HelloOk.auth?.scopes` after handshake
2. Nothing guards against the gateway silently granting a subset (e.g., if gateway config changes and drops `operator.admin`)
3. The `RPCClient.sessionsPluginPatch` call will fail at runtime with an error — but that error is caught by `log.error` in `publishTopicState`'s catch block and silently swallowed

If `operator.admin` is missing, `sessions.pluginPatch` fails, every topic publish fails, and the user sees nothing. The iPhone shows zero topics (if it was a fresh install) or stale topics (if it was already connected).

**Fix required:** Add a scope verification step in `SyncBridge.start()` after `sessionsSubscribe()`. Read the handshake `auth.scopes` (or call a scope-check RPC) and fail fast with a visible error if `operator.admin` is absent. Don't let the publish path discover this by silent failure.

### K-B3: Debug assert is useless in Release — no runtime guard on topicId/sessionKey consistency

The spec's debug assert:

```swift
assert(topic.id.lowercased() == sessionKey.split(separator: ":").last.map(String.init), ...)
```

This is a `#assert` — compiled out in Release builds. If a topic gets created with a mismatched ID (developer error, data migration bug, database corruption), Release builds will happily publish metadata with a wrong `topicId` to the wrong session key. iPhone will derive the topic list and may create **two topics** for the same conversation or miss one entirely.

**Fix required:** Replace `assert` with a runtime check that logs a `log.error()` and **refuses to publish** when the IDs don't match. This is a data integrity guard, not a debug hint. The cost is negligible (one string split and compare) and the damage of getting it wrong is non-trivial.

---

## WARNINGS

### K-W1: Race condition — rapid CRUD operations, no sequencing

The spec fires `Task { ... }` fire-and-forget for every CRUD operation. Consider:

1. User creates topic "Project Alpha" (id: `abc123`)
2. User immediately renames to "Project Alpha v2"
3. Both `publishTopicState` fire concurrently in detached Tasks
4. Task 2 (rename) calls `pluginPatch` first → succeeds
5. Task 1 (create) calls `pluginPatch` second → overwrites with stale metadata (isArchived=false, old updatedAt)
6. Task 1 then calls `sessionsPatch` → sets label to "Project Alpha" (the old name!)

**Result:** Topic ends up with the old name and old metadata, because Task 1 happened to finish its RPCs after Task 2.

This isn't just theoretical — rename-after-create is a very common user pattern. The spec has **no ordering guarantee** between concurrent publish calls for the same topic.

**Mitigation suggested:** Use an actor-isolated queue per topic, or at minimum a `lastPublishSequence` counter that lets the second task abort if it detects it's operating on stale data. Or make `publishTopicState` serial for a given topic.

### K-W2: Reconnect flood — 50 topics × 2 RPCs = 100 simultaneous calls

`reconcileAllTopicState()` does:

```swift
for topic in topics where !topic.isArchived && !topic.isDeleted {
    let sessionKey = deriveSessionKey(from: topic)
    publishTopicState(topic: topic, sessionKey: sessionKey)
}
```

Each `publishTopicState` fires a `Task`. With 50 topics, that's 50 concurrent Tasks, each doing 2 RPCs = **100 in-flight gateway calls** at the same instant.

Looking at `GatewayClient.call()`: there's no client-side rate limiting. Each call increments `nextRequestId` and fires into the WebSocket. The gateway may handle this fine (it's a local WebSocket), but:

- If the gateway is remote or on a slow connection, this could hit WebSocket backpressure
- The `pendingRequests` map stores 100 entries simultaneously — each with a 30s timeout
- If 20 of those calls fail (e.g., gateway is still warming up after reconnect), they all log errors and silently drop

**Mitigation suggested:** Batch the reconcile calls. Either serialise them with a small delay (e.g., 50-100ms between topics), or use a semaphore/task group with a concurrency limit (e.g., max 5 concurrent publishes). This is cheap insurance against overload.

### K-W3: `clearTopicState` is one-shot — no retry, no verification

On topic deletion, `clearTopicState` calls `sessionsPluginPatch(unset: true)` once. If it fails (catch block), it logs and stops. The session metadata remains on the gateway forever.

The spec says `reconcileAllTopicState` doesn't re-publish deleted topics (correct — it filters `!topic.isDeleted`). So there is **no recovery path** for a failed `clearTopicState`. The ghost metadata persists.

Compare this to `publishTopicState` which at least has reconcile as a recovery mechanism. Delete has none.

**Mitigation suggested:** Either (a) have `clearTopicState` retry once with a delay, or (b) have the reconcile loop also publish a "clear" for sessions where `beechat.metadata.topicId` exists in gateway data but no corresponding local topic exists (orphan detection).

### K-W4: `sessionsPluginPatch` value encoding is fragile

The spec's implementation:

```swift
if let value = value, !unset {
    params["value"] = try encodeCodable(value)
}
```

What is `encodeCodable`? It's not defined in the spec. Looking at existing `RPCClient` patterns, all other methods use `AnyCodable` wrappers:

```swift
params["key"] = AnyCodable(sessionKey)
```

The `gateway.call()` method expects `[String: AnyCodable]`. If `encodeCodable` returns `[String: AnyCodable]` (encoding the metadata struct and re-decoding it), that's fine but needs to be explicit. If it returns raw `Data` or a raw JSON `String`, the gateway won't parse it correctly.

**This is a build risk, not a logic risk** — the compiler will catch type mismatches — but the spec doesn't define this function and the existing codebase doesn't have one.

**Fix required:** Show the actual implementation. Pattern from `RPCClient.sessionsReset` suggests: encode to JSON, decode to `[String: AnyCodable]`. Spell this out.

### K-W5: `publishTopicState` uses `Task { [weak self] }` inside a non-async function — weak self race window

```swift
func publishTopicState(topic: Topic, sessionKey: String) {
    Task { [weak self] in
        guard let self = self else { return }
        ...
    }
}
```

`SyncBridge` is an `actor`. The `Task` captures `weak self`. If the actor is deallocated mid-flight (app shutdown, settings change that recreates SyncBridge), the Task silently aborts. This is correct behaviour but means a publish in flight during app shutdown will be lost — no retry, no persistence.

This is acceptable for fire-and-forget, but worth documenting in the risks table. Currently the risks table says "Gateway offline → reconcile catches up." It does not mention "app shutdown during publish → lost until next manual CRUD or reconnect."

### K-W6: Protocol method names are hardcoded string literals

The spec hardcodes:
- `"sessions.patch"`
- `"sessions.pluginPatch"`
- `"beechat"` (pluginId)
- `"metadata"` (namespace)

These appear in multiple places: RPC wrappers, publish logic, metadata access on iPhone. If the gateway changes the RPC method name or the plugin namespace, this silently breaks across the entire sync pipeline.

**Existing code precedent:** `RPCClient` already hardcodes `"sessions.list"`, `"sessions.subscribe"`, `"chat.history"` etc. So this is consistent with existing patterns. But it means there's zero compile-time safety.

**Not a blocker** (it's consistent with the rest of the codebase), but worth noting as a structural weakness. If a constants file or enum were introduced, future changes would be safer.

### K-W7: `deriveSessionKey(from: topic)` is undefined

The spec calls `deriveSessionKey(from: topic)` but doesn't define it. Looking at the assert, the expected format is `agent:main:<topicId.lowercased()>`. If this function produces a malformed key, `sessionsPatch` and `sessionsPluginPatch` will fail silently.

**Fix required:** Define this function explicitly in the spec, and add a non-failing guard that logs when it produces an unexpected format.

---

## QUESTIONS

### K-Q1: What happens if the gateway `sessions.list` returns a session with `beechat.metadata` but the Mac's local DB has no corresponding topic?

This could happen if: (a) Mac was reinstalled and local DB was wiped, or (b) a topic was deleted from local DB but `clearTopicState` failed. On reconnect, `reconcileAllTopicState` only iterates local topics — it would miss these orphans. The gateway metadata persists forever.

Is this acceptable? Or should reconcile also detect orphan gateway metadata and clean it up?

### K-Q2: The spec says `publishTopicState` is called AFTER local DB operation succeeds. What if the local DB transaction succeeds but the app crashes before `publishTopicState` fires?

The call site is in the Mac app's CRUD handler, outside the SyncBridge. If the app crashes between DB commit and publish call, the topic exists locally but not on gateway. iPhone won't see it.

Is there a mechanism to detect this? The current defence is "reconcile on reconnect" — but if the app never reconnects (crashed, user didn't restart), the topic stays invisible to iPhone indefinitely.

### K-Q3: Does `sessions.pluginPatch` with `value: nil, unset: true` actually clear the metadata, or does it set the metadata to `null`?

There's a semantic difference. If the gateway stores `null` as a value, iPhone's `beechatMetadata` accessor (Phase 0) may still find a `pluginExtensions.beechat.metadata` key with a null value, and the nil-coalescing may behave differently. The parent spec v2 says iPhone filters sessions "where `beechatMetadata != nil`" — so `null` should be excluded. But this needs verification.

### K-Q4: The `reconcileAllTopicState` hook fires "after successful handshake + sessions.subscribe." Could it fire before `fetchSessions()` completes?

Looking at `SyncBridge.start()`:
```swift
try await config.gatewayClient.connect()
try await rpcClient.sessionsSubscribe()
_ = try await fetchSessions()
```

The spec says reconcile fires on reconnect in the `connectionStateStream` handler. But on **initial** start, who calls `reconcileAllTopicState()`? The spec says "Called on `SyncBridge.start()`" — but `start()` doesn't call it. Is this a spec omission, or is initial publish implicit (each CRUD will fire as user creates topics)?

If the Mac had existing topics before this feature was deployed, they won't be published until the first CRUD operation or a reconnect. Is a "publish all on first start" call needed?

### K-Q5: What's the `encodeCodable` implementation, and does it handle `BeeChatTopicMetadata`'s nested structure correctly?

`BeeChatTopicMetadata` has `topicId: String`, `isArchived: Bool`, `projectPath: String?`, `updatedAt: String`. Encoding this to `[String: AnyCodable]` requires either:
- Encode to JSON Data → decode to `[String: AnyCodable]` (AnyCodable round-trip)
- Manual construction: `["topicId": AnyCodable(meta.topicId), "isArchived": AnyCodable(meta.isArchived), ...]`

Which approach? The first is more maintainable, the second is more explicit. The spec doesn't show it.

---

## HIGHLIGHTS

### K-H1: Metadata-first ordering is correct

The spec explicitly calls out `pluginPatch` before `sessionsPatch`. This is the right call. The rationale ("session with metadata but no label is usable; session with label but no metadata is a ghost") is sound. This ordering minimises the blast radius of partial failures.

### K-H2: Fire-and-forget + reconcile-on-reconnect is appropriate for personal use

For a production multi-tenant system, you'd want a persistent retry queue with exponential backoff. For Adam's personal two-device setup, the simplicity of "log it, reconcile later" is the right trade-off. Less code, fewer moving parts, fewer things to debug at 2am.

### K-H3: Scope table and client identity contract are well-documented

The spec clearly documents which RPCs need which scopes, and the `client.id`/`mode` requirements to pass `rejectWebchatSessionMutation`. This makes it easy to audit and easy to catch configuration drift.

### K-H4: No UI changes in Phase 1

Zero visual impact on Mac. No spinners, no error dialogs, no state changes the user would notice. This is clean separation — infrastructure first, UI later if needed.

---

## SUMMARY

| Category | Count |
|---|---|
| **Blockers** | 3 — ghost topic half-publish, unverified scope, missing runtime topicId guard |
| **Warnings** | 7 — race conditions, reconnect flood, one-shot clear, encoding fragility, weak-self lifecycle, hardcoded strings, undefined deriveSessionKey |
| **Questions** | 5 — orphan detection, crash-between-DB-and-publish, null semantics, initial reconcile, encoding approach |
| **Highlights** | 4 — good ordering, appropriate simplicity, clear scope docs, no UI impact |

**Verdict:** **NOT READY** — resolve Blockers K-B1, K-B2, K-B3 before implementation. Warnings K-W1 (race) and K-W2 (reconnect flood) are strong recommendations that should be addressed given the low implementation cost (a serial queue and a concurrency limiter are ~10 lines each).

---

*Kieran out. Break it before it breaks you.*
