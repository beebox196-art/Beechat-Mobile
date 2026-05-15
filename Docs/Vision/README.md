# BeeChat Mobile — Vision

## Goal
A native iOS app (iPhone + iPad) that gives Adam full BeeChat access away from the Mac — same sessions, same messages, same gateway, mobile-native UX.

## Why Not Just Telegram?
Telegram works as a mobile bridge today but:
- Locked to Telegram's UI and notification timing
- No custom BeeChat features (voice, BeeBoard, agent routing)
- Dependent on Telegram's infrastructure and policies
- Not our product — can't control the experience

## Why Native iOS (Not Web/PWA)?
- Real push notifications (Apple requires native for reliable push)
- Offline message cache (GRDB, same as v5)
- Native feel — haptics, gestures, sheet navigation
- SwiftUI + shared Core packages = high code reuse, low duplication
- PWA push on iOS is unreliable and limited

## Architecture Principle
**Same gateway, same truth, different glass.**

The OpenClaw gateway owns session state. Both Mac and iPhone sync from it, cache locally, reconcile on reconnect. No server-side changes needed — the gateway already serves WebSocket events and RPC calls.

## Core Package Reuse
| Package | Reuse? | Notes |
|---|---|---|
| BeeChatPersistence | ✅ Yes | GRDB + SQLite, already platform-ready |
| BeeChatGateway | ✅ Yes | WebSocket client, URLSession-based |
| BeeChatSyncBridge | ✅ Yes | Event routing, reconciliation logic |
| BeeChatApp (UI) | ❌ No | macOS AppKit — needs new SwiftUI iOS layer |

## New Work Required
1. **iOS UI layer** — SwiftUI views optimised for touch (sheet-based navigation, swipe gestures, compact layouts)
2. **Push notifications** — APNs integration via gateway relay or push service
3. **Background strategy** — Foreground WebSocket + background push, not persistent connection
4. **Distribution** — TestFlight for personal use, potential App Store later
5. **Apple Developer account** — Needed for device provisioning and push certs

## Success Criteria (MVP)
- See all sessions and messages from gateway
- Send messages and receive replies in real-time (foreground)
- Push notifications for new messages (background)
- Offline cache — read history without connection
- iPad layout — not just a stretched iPhone app

## Success Criteria (Full)
- Voice input/output (Phase 2 from voice roadmap)
- BeeBoard integration
- Multi-device sync indicators
- Notification preferences per session
- Quick actions / widgets

---
*Created 2026-05-12.*