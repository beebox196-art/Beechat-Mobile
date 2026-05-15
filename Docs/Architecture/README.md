# BeeChat Mobile — Architecture

## Overview
Native iOS client sharing Core Swift packages with BeeChat v5 (macOS). Separate UI layer built with SwiftUI for iOS 17+.

## Shared Architecture (from v5)
- **BeeChatPersistence** — GRDB/SQLite local cache. Gateway owns truth, DB is cache + UX accelerator.
- **BeeChatGateway** — WebSocket transport for OpenClaw gateway events and RPC calls.
- **BeeChatSyncBridge** — Glue layer: subscribes to gateway events, writes to DB, publishes GRDB observations.

## iOS-Specific Architecture

### Package Dependency
```
BeeChat-Mobile (Xcode Project)
├── BeeChatApp (iOS app target)
│   ├── Views/           — SwiftUI iOS views
│   ├── Navigation/      — Sheet-based mobile navigation
│   ├── Push/            — APNs registration + handling
│   └── Widgets/         — Lock screen / home screen widgets
├── BeeChatPersistence   (local SPM dependency → BeeChat-v5)
├── BeeChatGateway       (local SPM dependency → BeeChat-v5)
└── BeeChatSyncBridge    (local SPM dependency → BeeChat-v5)
```

### Key Design Decisions (to be confirmed in Phase 0)
1. **SPM local dependency** — Point to BeeChat-v5 packages, not copy files. Changes to Core propagate to both platforms.
2. **iOS 17+ target** — Matches v5's minimum (macOS 14 = iOS 17 era APIs). Uses @Observable, NavigationStack, etc.
3. **Push notifications** — Gateway needs a push relay component. Options: (a) APNs direct from gateway, (b) third-party push service, (c) self-hosted relay. Research needed.
4. **Background strategy** — No persistent WebSocket in background. Use push notifications to wake, then reconnect + reconcile on open.
5. **iPad** — NavigationSplitView for sidebar/detail, not just scaled iPhone layout.

### Data Flow (same as v5)
```
Gateway (WebSocket) → BeeChatGateway → BeeChatSyncBridge → BeeChatPersistence (SQLite) → SwiftUI Views (GRDB ValueObservation)
```

### What's Different from v5
| Aspect | v5 (macOS) | Mobile |
|---|---|---|
| UI framework | AppKit + SwiftUI | SwiftUI only |
| Navigation | Window/toolbar | Sheet/tab/navigation stack |
| Background | Always-on WebSocket | Push notification + reconnect |
| Input | Keyboard + mouse | Touch + keyboard |
| Notifications | macOS native | APNs push |
| Widgets | macOS widget | iOS lock screen / home screen |

---
*Created 2026-05-12. To be expanded after Phase 0 research.*