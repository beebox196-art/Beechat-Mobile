# BeeChat Mobile

A native iOS chat client for OpenClaw, sharing core Swift packages with BeeChat v5 (macOS). Gateway is truth, iPhone is cache.

## In Scope

- Gate-aligned implementation: each Gate has a spec, build to the spec, nothing more
- Shared package compatibility: any change must compile for both iOS 17+ and macOS without conditional divergence
- Bug fixes for existing functionality (topic list, messages, send/receive, streaming, gateway connection)
- Mobile-specific UX: navigation adaptation (NavigationStack on iPhone, NavigationSplitView on iPad), background/foreground lifecycle, safe area handling
- Offline-first resilience: cached data shows immediately, reconnect when network returns
- Example in-scope PRs: "Fix topic list not refreshing on sessions.changed", "Add reconnection after background", "Fix IPv6 localhost resolution on simulator"

## Out of Scope

- New major features beyond the current Gate (push notifications, media, reactions) without Adam approval
- Changes to shared packages that break macOS BeeChat v5
- Broad refactors or new architectural layers
- New SPM dependencies (Exyte/Chat, Valet, GRDB are the stack — don't add more)
- Gateway or server-side changes (Mobile is a client)
- Features that cannot be tested on iPhone simulator against localhost gateway
- Example out-of-scope PRs: "Add APNs push notifications", "Replace Exyte/Chat with custom UI", "Add image sharing", "Rewrite SyncBridge in Combine"

## Needs Human

- Gate progression decisions (which Gate, spec approval, exit criteria changes)
- Any change to shared BeeChatPersistence, BeeChatGateway, or BeeChatSyncBridge APIs
- New feature proposals not in an approved Gate spec
- Real-device testing (requires Tailscale + physical iPhone)

## Merge Criteria

- Every Gate deliverable requires Kieran adversarial review before merge
- No Gate passes without Kieran sign-off
- Trivial fixes: build passes → commit
- Standard changes: tests pass + Kieran review → commit
- Critical changes: spec + doubt-driven-development + build + Kieran review + Adam sign-off → commit

## If Blocked

State exactly what's missing: the failing build step, the unresolvable platform difference, the spec ambiguity. Do not leave a PR open with vague blockers.