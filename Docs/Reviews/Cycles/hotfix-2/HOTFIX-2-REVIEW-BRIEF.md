# Hotfix #2 — Adversarial Code Review Brief (Kieran)

**Date:** 2026-05-19  
**Scope:** User messages not appearing in chat view  
**Files changed:**
1. `BeeChatMobileKit/BeeChatMobileViewModel.swift` — Local persistence of user messages in online send path
2. `BeeChatUI/MessageMapper.swift` — Content-based dedup for user messages within 2-second window

## What to review

### 1. Local persistence before gateway send
- Does the user message get persisted BEFORE `bridge.sendMessage()`?
- Is the message ID unique (UUID)?
- Does the offline path still work? (It already had local persistence)
- Error handling: if `persistenceStore.saveMessage()` throws, does the send still proceed?

### 2. Content-based dedup in MessageMapper
- Does the dedup skip gateway-echoed user messages (same content, same role, within 2s)?
- Does it preserve intentionally repeated messages (user sends same text twice, >2s apart)?
- Is the dedup logic correct for the `exyteMessages(from:)` method?
- Does it handle nil content gracefully?
- Are assistant messages excluded from dedup? (They should be — only user messages get duplicated)

### 3. Race conditions
- `messageVersion += 1` triggers `loadMessages()` after send
- The user message is now in the DB before `loadMessages()` fires
- The gateway echo arrives later — will it be deduped correctly?
- What if the user sends the same message twice quickly? (Should show twice if intentional)

### 4. Data integrity
- No orphaned messages in the DB
- No data loss on error paths
- Gateway echo dedup is by content+time, not by ID — is this safe?

## Expected verdict
APPROVED (no blockers) or NEEDS CHANGES (with specific blockers).