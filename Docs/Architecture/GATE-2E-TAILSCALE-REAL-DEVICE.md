# Gate 2E: Tailscale + Real Device Baseline

**Status:** 🟡 SPEC DRAFT — Awaiting Adam approval  
**Author:** Bee  
**Date:** 2026-05-20  
**Depends on:** Gate 2D (or current working state — simulator-verified hotfix #2)  
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

1. **Tailscale installed and connected** on Mac mini (server) and iPhone (client)
2. **Configurable server URL** — app connects to Tailscale IP (`ws://100.x.x.x:18789`) instead of `localhost`
3. **Real device deployment** — app runs on physical iPhone via Xcode USB
4. **Basic send/receive works** on real device over Tailscale
5. **Swap-out documented** — one-page guide for replacing Tailscale with alternative networking
6. **No code changes needed** to switch between localhost / Tailscale IP / any other URL

---

## Architecture: Swap-Out by Design

The app already has a layered config resolution system. Tailscale fits into this with **zero code changes**:

### Config Resolution Order (existing)

```
1. Environment variable BEECHAT_GATEWAY_URL  (Xcode scheme injection)
2. Config file gateway-config.json           (app container)
3. Hardcoded fallback                        (ws://127.0.0.1:18789)
```

### How Tailscale Works Here

| Method | How to Switch to Tailscale | How to Switch Away |
|--------|---------------------------|-------------------|
| **Env var** (recommended for dev) | Set `BEECHAT_GATEWAY_URL=ws://100.x.x.x:18789` in Xcode scheme | Remove env var, app falls back to config file |
| **Config file** | Write `gateway-config.json` with Tailscale URL | Edit file to new URL, or delete it |
| **Hardcoded** | Change `BeeChatMobileConfig` default (not recommended for dev) | Change it back |

**Recommended dev setup:** Xcode scheme environment variable. Easy to toggle between simulator (localhost) and real device (Tailscale IP) without touching files.

### What Tailscale Is NOT

- Tailscale is **not** in the app code — no Tailscale SDK, no Tailscale import, no Tailscale dependency
- The app connects to a **URL**. Tailscale makes that URL reachable. That's it.
- Swapping Tailscale for any alternative (Cloudflare Tunnel, ngrok, direct LAN IP, public DNS) is **changing one URL value** — no refactoring

---

## Implementation Steps

### Step 1: Tailscale Setup (manual, Adam done)
- [x] Install Tailscale on Mac mini
- [x] Install Tailscale on iPhone
- [ ] Verify both devices show "Connected" in Tailscale admin console
- [ ] Note Mac mini's Tailscale IP (100.x.x.x)

### Step 2: Gateway Accessibility
- [ ] Confirm BeeChat-v5 gateway is accessible at `ws://100.x.x.x:18789` from iPhone
- [ ] Confirm WebSocket connection works (use Safari websocket test or similar)
- [ ] Document Mac mini Tailscale IP in project notes

### Step 3: Real Device Deployment
- [ ] Apple Developer account (free tier works for 7-day signing)
- [ ] Xcode project configured for real device deployment
- [ ] Build & run on iPhone via USB
- [ ] App launches, shows topic list (even if empty/offline initially)

### Step 4: Configurable Server URL
- [ ] Xcode scheme environment variable: `BEECHAT_GATEWAY_URL=ws://100.x.x.x:18789`
- [ ] OR: `gateway-config.json` seeded on device with Tailscale URL
- [ ] Verify app connects to gateway on real device
- [ ] Verify connection status shows 🟢 Online

### Step 5: Functional Verification on Real Device
- [ ] Topic list loads from gateway
- [ ] Send message → appears immediately in chat (hotfix #2)
- [ ] Bee's response streams back correctly
- [ ] Message order correct (oldest top, newest bottom)
- [ ] Mic button shows privacy prompt (no crash — hotfix #1)

### Step 6: Documentation
- [ ] Update STATUS.md with Gate 2E completion
- [ ] Write swap-out guide (this document, Section: "Rolling Out of Tailscale")

---

## Rolling Out of Tailscale

If you need to stop using Tailscale, here's how:

### Option A: Direct LAN IP (simplest, home/office only)
1. Note your Mac mini's LAN IP (e.g. `192.168.1.x`)
2. Change `BEECHAT_GATEWAY_URL` to `ws://192.168.1.x:18789`
3. Limitation: only works on the same network

### Option B: Cloudflare Tunnel (production-grade, free tier available)
1. Install `cloudflared` on Mac mini
2. `cloudflared tunnel --url ws://localhost:18789`
3. Get a `https://xxx.trycloudflare.com` URL
4. Change `BEECHAT_GATEWAY_URL` to `wss://xxx.trycloudflare.com`
5. Advantage: works from any network, no Tailscale needed on client

### Option C: Public Server (for distribution)
1. Deploy BeeChat-v5 to a VPS or cloud server
2. Point DNS at it (e.g. `beechat.yourdomain.com`)
3. Change `BEECHAT_GATEWAY_URL` to `wss://beechat.yourdomain.com`
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
| Tailscale IP changes | Very low — Tailscale IPs are stable per device | Can also use Tailscale MagicDNS (`hostname.tailnet`) |
| Config file seeding on device | Medium — need to get config onto real device | Xcode scheme env vars easiest for dev; file-based for later |

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