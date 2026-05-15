# ADR-001: Validation-First Build Approach

**Date:** 2026-05-12
**Status:** Accepted
**Context:** BeeChat v5 had painful rework cycles from building before validating. Adam explicitly wants too much checking rather than solutions that don't work.

**Decision:** Hard-gated phased build. Each gate has explicit exit criteria that must pass before moving to the next phase. No gate is skipped or soft-passed.

**Gates:**
- Gate 0: Core Package iOS Audit — prove packages compile for iOS
- Gate 1: Exyte/Chat Spike — prove UI library works before building on it
- Gate 2: Real Data Pipeline — prove end-to-end data flow
- Gate 3: Mobile UX Shell — prove navigation and lifecycle
- Gate 4: Push Notifications MVP — prove APNs flow
- Gate 5: Polish & Distribution — TestFlight-ready

**Escape hatches:**
- If Exyte fights us for >1 day at Gate 1, switch to SwiftyChat before sunk cost builds up
- If a Core package needs significant iOS rework at Gate 0, document it and decide before proceeding
- Any gate can reveal a "stop and rethink" issue — we surface it immediately

**Consequences:**
- Slower start, but each phase is built on verified foundations
- Issues caught early when they're cheap to fix
- No "we'll fix it later" — each gate is a genuine pass/fail