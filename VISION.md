# BeeChat Mobile

A native iOS app giving Adam remote access to Bee and the team when away from the Mac. Shares core Swift packages with BeeChat v5 (macOS) via SPM local dependency, but BeeChat-v5 is the master — Mobile is a client, not a peer.

## Purpose

BeeChat Mobile is Adam's access to the team whilst away from his desk. It does not need to replicate the full BeeChat macOS experience — it needs to keep Adam connected to the conversations, research, and file access that matter when he's not at the Mac.

Getting BeeChat Mobile to a working product is a near-term priority — a key win that makes the BeeChat experience platform-complete. Longer term it could extend to other family members, but that is a long-term consideration, not current scope.

## Relationship to BeeChat-v5 (macOS)

**BeeChat-v5 is the master.** No code changes should happen to BeeChat-v5 as a consequence of BeeChat Mobile work unless explicitly agreed and approved by Adam. BeeChat-v5 code and operation is the primary concern.

BeeChat Mobile will inevitably have some divergence from the macOS app due to:
- Device limitations (screen size, memory, battery)
- Non-local access to data (Tailscale remote vs localhost)
- iOS platform constraints (background lifecycle, sandbox restrictions)

This divergence is expected and acceptable. Mobile is not trying to be macOS — it's trying to be a capable remote interface.

## In Scope

- **Topic-based chat:** read and participate in topics — message streaming, send/receive, offline-first with cached data.
- **Research dialog:** access to the `/research` pipeline and research results from mobile.
- **Folder view:** access to desktop folder view and workspace resources from mobile.
- **Gate-aligned implementation:** each Gate has a spec, build to the spec, nothing more. Current focus: Gates 2D–2E (reconnect, real device), then Gate 3 (mobile UX shell).
- **Shared package consumption:** Mobile consumes BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge via SPM local dependency. Changes to these shared packages require Adam approval — they must not break macOS.
- **Tailscale connectivity:** real-device testing over Tailscale, with swap-out architecture (Tailscale is a dev convenience, not a dependency — the app connects to a URL).
- **Mobile-specific UX:** navigation adaptation (NavigationStack on iPhone, NavigationSplitView on iPad), background/foreground lifecycle, safe area handling, mobile-appropriate text sizing.
- **Offline-first resilience:** cached data shows immediately, reconnect when network returns.
- Bug fixes for existing functionality (topic list, messages, send/receive, streaming, gateway connection)
- Example in-scope PRs: "Fix topic list not refreshing on sessions.changed", "Add reconnection after background", "Wire research dialog for mobile", "Add folder view navigation"

## Out of Scope

- **BeeBoard on mobile** — not a key aspect of BeeChat Mobile. May be added in the future if Adam requests it, but not current scope.
- **Team activity watching** — not a priority for mobile. Adam can see team activity on macOS. Mobile is for conversation and remote access, not orchestration.
- Full macOS UI parity — Mobile does not need all the UI aspects that come with BeeChat macOS
- New major features beyond the current Gate (push notifications, media, reactions) without Adam approval
- Changes to BeeChat-v5 macOS code or shared packages that affect macOS operation (unless explicitly agreed and approved)
- Broad refactors or new architectural layers
- New SPM dependencies (Exyte/Chat, Valet, GRDB are the stack — don't add more)
- Gateway or server-side changes (Mobile is a client)
- Commercial features or multi-user auth (long-term aspiration, not current scope)
- Example out-of-scope PRs: "Add BeeBoard pin management on mobile", "Add full team activity dashboard", "Add APNs push notifications now", "Modify BeeChatPersistence shared package for mobile-only needs"

## Needs Human

- Gate progression decisions (which Gate, spec approval, exit criteria changes)
- Any change to shared BeeChatPersistence, BeeChatGateway, or BeeChatSyncBridge APIs — these affect macOS and require Adam approval
- New feature proposals not in an approved Gate spec
- Real-device testing (requires Tailscale + physical iPhone)

## The 12-Month Test (Mobile Edition)

Within a year, BeeChat Mobile should be installable on Adam's iPhone, connect to the gateway over Tailscale, and let Adam read topics, send messages, access research results, and browse files from his phone. If Adam can't leave the Mac for an hour and stay connected via Mobile, the vision isn't met.

## Merge Criteria

- Every Gate deliverable requires Kieran adversarial review before merge
- No Gate passes without Kieran sign-off
- Trivial fixes: build passes → commit
- Standard changes: tests pass + Kieran review → commit
- Critical changes: spec + doubt-driven-development + build + Kieran review + Adam sign-off → commit
- Any change touching shared packages must also compile and pass tests on macOS BeeChat-v5

## If Blocked

State exactly what's missing: the failing build step, the unresolvable platform difference, the spec ambiguity. Do not leave a PR open with vague blockers.