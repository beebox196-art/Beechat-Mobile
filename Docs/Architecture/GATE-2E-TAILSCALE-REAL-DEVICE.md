# Gate 2E: Tailscale + Real Device Baseline

**Status:** 🟡 IN PROGRESS — Tailscale Serve verified, code updated, awaiting real device test  
**Author:** Bee  
**Date:** 2026-05-20  
**Updated:** 2026-05-20  
**Depends on:** Gate 2C ✅ (simulator-verified, send/receive working)  
**Blocks:** Gate 3 (backgrounding, reconnect — needs real device)

---

## Goal

Enable BeeChat Mobile to run on a **real iPhone** connected to the BeeChat-v5 gateway over **Tailscale**, replacing the simulator+localhost development model. Establish a swap-out architecture so Tailscale is a **development convenience, not a permanent dependency**.

## Why Tailscale

- Each device gets a stable, encrypted IP — works on any network (home WiFi, mobile data, different locations)
- Removes entire category of networking debugging (LAN IP, port forwarding, NAT, firewall)
- Free tier covers personal dev use (up to 100 devices)
- Zero config networking — install, auth, done
- Development-only: the app never "knows" about Tailscale, it just connects to a URL

## Why a Swap-Out Plan

Tailscale is a development convenience, not an architectural dependency. If any of these happen:
- Tailscale introduces pricing that doesn't work for us
- Tailscale changes free tier limits
- We want to move to a different networking approach (Cloudflare Tunnel, direct hosting, etc.)
- The app goes public and needs a production-grade setup

...we should be able to swap out Tailscale in **one config change**, not a code refactor.

---

## Exit Criteria

1. ~~**Tailscale installed and connected** on Mac mini (server) and iPhone (client)~~ ✅ Done
2. ~~**Configurable server URL** — app connects to Tailscale Serve URL (`wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws`) instead of `localhost`~~ ✅ Done
3. **Real device deployment** — app runs on physical iPhone via Xcode USB
4. **Basic send/receive works** on real device over Tailscale
5. ~~**Swap-out documented** — one-page guide for replacing Tailscale with alternative networking~~ ✅ Done (in code + this doc)
6. ~~**No code changes needed** to switch between localhost / Tailscale URL / any other URL~~ ✅ Done (env var / config file / hardcoded fallback)

---

## Architecture: Swap-Out by Design

The app already has a layered config resolution system. Tailscale fits into this with **zero code changes**:

### Config Resolution Order (existing)

```
1. Environment variable BEECHAT_GATEWAY_URL  (Xcode scheme injection)
2. Config file gateway-config.json           (app container)
3. Hardcoded fallback                        (wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws)
```

### How Tailscale Serve Works

Tailscale Serve provides an **HTTPS reverse proxy** from the tailnet to the local gateway:
- Gateway stays bound to `localhost:18789` (loopback only — secure)
- Tailscale Serve proxies `https://openclaws-mac-mini-1.tail3f2df8.ts.net/` → `http://127.0.0.1:18789`
- iOS connects via `wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws?token=...`
- Automatic HTTPS + TLS (Tailscale manages certificates)
- Only accessible from devices on our tailnet

This is better than direct tailnet bind (`gateway.bind = "tailnet"`) because:
- Gateway stays on loopback (safer)
- Automatic HTTPS/TLS (no plain WebSocket over the internet)
- Tailscale identity headers available for auth (future)
- Loopback access from Mac still works

### How to Switch URLs

| Method | How to Switch to Tailscale | How to Switch Away |
|--------|---------------------------|-------------------|
| **Env var** (recommended for dev) | Set `BEECHAT_GATEWAY_URL=wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws` in Xcode scheme | Remove env var, app falls back to config file |
| **Config file** | Write `gateway-config.json` with Tailscale URL | Edit file to new URL, or delete it |
| **Hardcoded** | Change `BeeChatMobileConfig` default | Change it back |

**Tip for simulator testing:** To test on simulator with localhost, set env var `BEECHAT_GATEWAY_URL=ws://127.0.0.1:18789` in the Xcode scheme. This overrides the default Tailscale URL.

### What Tailscale Is NOT

- Tailscale is **not** in the app code — no Tailscale SDK, no Tailscale import, no Tailscale dependency
- The app connects to a **URL**. Tailscale makes that URL reachable. That's it.
- Swapping Tailscale for any alternative (Cloudflare Tunnel, ngrok, direct LAN IP, public DNS) is **changing one URL value** — no refactoring

---

## Implementation Steps

### Step 1: Tailscale Setup ✅
- [x] Install Tailscale on Mac mini
- [x] Install Tailscale on iPhone
- [x] Verify both devices show "Connected" in Tailscale admin console
- [x] Mac mini Tailscale IP: `100.102.64.30`, iPhone: `100.102.202.102`

### Step 2: Tailscale Serve Configuration ✅
- [x] Enable Tailscale Serve in admin console (Adam action)
- [x] Configure OpenClaw gateway: `gateway.tailscale.mode = "serve"` (already set)
- [x] Gateway bind stays as `loopback` (Tailscale Serve proxies to localhost:18789)
- [x] Verify: `tailscale serve status` → `https://openclaws-mac-mini-1.tail3f2df8.ts.net/ → http://127.0.0.1:18789`
- [x] Verify: WebSocket handshake via Tailscale Serve returns `connect.challenge` ✅
- [x] Verify: HTTPS health endpoint returns `{"ok":true}` ✅

### Step 3: Code Update — Gateway URL ✅
- [x] `BeeChatMobileConfig.swift` default changed: `ws://127.0.0.1:18789` → `wss://openclaws-mac-mini-1.tail3f2df8.ts.net/ws`
- [x] `GatewayConfigLoader.swift` OpenClaw config fallback URL updated to Tailscale Serve URL
- [x] Swap-out architecture documentation added to `GatewayConfigLoader.swift` doc comments
- [x] Build compiles clean on iOS Simulator target (warnings only, no errors)
- [x] Committed and pushed: `a8cd3e0`

### Step 4: Real Device Deployment ⏳
- [ ] Apple Developer account (free tier works for 7-day signing)
- [ ] Xcode project configured for real device deployment
- [ ] Build & run on iPhone via USB
- [ ] App launches, shows topic list (even if empty/offline initially)

### Step 5: Functional Verification on Real Device ⏳
- [ ] Topic list loads from gateway
- [ ] Send message → appears immediately in chat (hotfix #2)
- [ ] Bee's response streams back correctly
- [ ] Message order correct (oldest top, newest bottom)
- [ ] Mic button shows privacy prompt (no crash — hotfix #1)

### Step 6: Documentation ⏳
- [ ] Update STATUS.md with Gate 2E completion
- [ ] Tag repo when Gate 2E passes

---

## Rolling Out of Tailscale

If you need to stop using Tailscale, here's how:

### Option A: Direct LAN IP (simplest, home/office only)
1. Change `gateway.bind` from `"loopback"` to `"tailnet"` or `"all"` in OpenClaw config
2. Note your Mac mini's LAN IP (e.g. `192.168.1.x`)
3. Change `BEECHAT_GATEWAY_URL` to `ws://192.168.1.x:18789`
4. Limitation: only works on the same network, no TLS

### Option B: Cloudflare Tunnel (production-grade, free tier available)
1. Install `cloudflared` on Mac mini
2. `cloudflared tunnel --url http://localhost:18789`
3. Get a `https://xxx.trycloudflare.com` URL
4. Change `BEECHAT_GATEWAY_URL` to `wss://xxx.trycloudflare.com/ws`
5. Advantage: works from any network, no Tailscale needed on client

### Option C: Public Server (for distribution)
1. Deploy BeeChat-v5 to a VPS or cloud server
2. Point DNS at it (e.g. `beechat.yourdomain.com`)
3. Change `BEECHAT_GATEWAY_URL` to `wss://beechat.yourdomain.com/ws`
4. Add SSL/TLS termination (Let's Encrypt or similar)

### Option D: Custom VPN (WireGuard, etc.)
1. Set up WireGuard server on Mac mini or VPS
2. Install WireGuard app on iPhone
3. Connect, get VPN IP
4. Change `BEECHAT_GATEWAY_URL` to `ws://10.x.x.x:18789`

**All options:** Change one URL value. No code changes. No app rebuild needed (just change config and relaunch).

### When to Swap

| Scenario | Recommended Option |
|----------|-------------------|
| Tailscale adds paid tier we don't want | Option A (LAN) for dev, Option B for remote |
| Going public with the app | Option C (public server) |
| Need remote dev but Tailscale not available | Option B (Cloudflare Tunnel) |
| Corporate environment blocks Tailscale | Option D (WireGuard) or Option B |

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Tailscale free tier limits change | Low — app doesn't depend on Tailscale SDK | Swap URL to alternative (see above) |
| iOS kills WebSocket in background | Expected — this is Gate 3 territory | Not a 2E blocker; documented for next gate |
| Apple Developer account needed for real device | Low — free account works for 7-day windows | Use free account for dev; paid account ($99/yr) for TestFlight later |
| Tailscale Serve URL changes | Very low — Tailscale MagicDNS names are stable per tailnet | Update hardcoded default + any config files |
| Config file seeding on device | Medium — need to get config onto real device | Use Xcode scheme env vars for dev; gateway-config.json for later |

---

## What Gate 2E Does NOT Cover

These are deferred to later gates:

- **Backgrounding / WebSocket lifecycle** (Gate 3)
- **Push notifications** (Gate 4)
- **App Store / TestFlight** (Gate 5)
- **Production networking** (post-Gate 5, depends on hosting decision)
- **Multiple server profiles** (nice-to-have, not needed now)

---

## Success Definition

Adam opens BeeChat Mobile on his iPhone, connected via Tailscale, and can:
1. See his topics
2. Send a message
3. See Bee's response stream in
4. No crashes

And the Tailscale URL is **one config value** that can be swapped to any alternative without code changes.