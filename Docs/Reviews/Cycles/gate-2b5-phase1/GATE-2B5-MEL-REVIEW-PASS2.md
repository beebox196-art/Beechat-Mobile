# Gate 2B.5 Topic Architecture — Mel UX Review Pass 2

**Date:** 2026-05-18
**Reviewer:** Mel
**Scope:** Detailed interaction design review after first-pass M1-M5 were incorporated
**Source reviewed:** `Docs/Architecture/GATE-2B5-TOPIC-ARCHITECTURE.md`
**Status:** Not ready for implementation until M6-M14 are resolved in the spec

## Summary

The revised Gate 2B.5 spec fixes the major architecture and first-pass UX problems: topics are now user-facing objects, raw session keys are hidden, creation is explicit, empty states are acknowledged, and destructive actions require confirmation.

The remaining risk is not architectural. It is interaction ambiguity. The spec still says "compact sheet", "swipe actions", "empty state", and "error states" without enough behavioral detail for Q to implement consistently or for Bee to validate manually. The implementation should not begin until the items below are added as acceptance criteria.

## M6 — Define the iPhone New Topic Sheet End-to-End

**Severity:** Must-have

The spec currently requires a compact sheet, but it does not define the actual flow. This creates too much room for inconsistent behavior.

Required interaction:

1. User taps the `+` toolbar button in the Topics list.
2. iPhone presents a `.presentationDetents([.height(220)])` sheet, with `.medium` allowed only when Dynamic Type requires more space.
3. Sheet content:
   - Navigation title: `New Topic`
   - Primary prompt label: `What would you like to talk about?`
   - Single-line text field placeholder: `Topic name`
   - Character counter below field: `0/80`
   - Toolbar buttons: `Cancel` leading, `Create` trailing
4. Keyboard appears automatically and focuses the text field when the sheet opens.
5. `Create` is disabled until the trimmed topic name is non-empty.
6. Tapping `Cancel` dismisses the sheet and discards the typed name.
7. Pulling down or tapping outside the sheet should be allowed only when the field is empty. If the user has typed text, show a confirmation dialog: `Discard topic draft?` with `Keep Editing` and `Discard`.
8. On create success:
   - Trim leading/trailing whitespace.
   - Save the topic locally with the upfront gateway-format session key.
   - Dismiss the sheet.
   - Auto-select the topic.
   - Navigate to the chat detail.
   - Focus the message composer, not the topic title.

Topic name constraints:

- Maximum length: 80 user-perceived characters.
- Text field enforces the limit while typing.
- Newlines are not allowed.
- If pasted text exceeds 80 characters, truncate at 80 and announce the limit through an inline caption: `Topic names can be up to 80 characters.`
- The list row displays long names at two lines maximum; the chat navigation title uses one line with truncation.

Why this matters: topic creation is the first real user intent in this architecture. It should feel immediate, local, and reversible.

## M7 — Clarify iPad Popover and Adaptive Presentation

**Severity:** Must-have

The spec says iPad uses a popover, but not what happens across iPad modes and compact-width devices.

Required behavior:

- Regular-width iPad: present a popover anchored to the `+` button.
- Popover size: 360 pt wide, content-driven height around 220 pt.
- Stage Manager or narrow iPad window: if horizontal size class becomes compact, fall back to the iPhone sheet behavior.
- Landscape iPhone and Plus/Max iPhone: still use the compact iPhone sheet, not an iPad popover.
- External display / Stage Manager minimum topic-list column width: 320 pt preferred, 280 pt absolute minimum. Below 280 pt, collapse to stack navigation.
- Popover dismissal follows the same dirty-draft rule as iPhone: empty field dismisses freely; typed content requires confirmation.

The acceptance criteria should explicitly test iPhone portrait, iPhone landscape, iPad full-screen landscape, iPad portrait, and iPad Stage Manager narrow window.

## M8 — Specify Topic List Swipe Actions and Undo

**Severity:** Must-have

Archive/delete are named, but the exact gestures and recovery model are missing.

Required behavior:

- Leading swipe: optional `Pin` action only if pinning ships in this gate. If pinning is not in scope, no leading swipe.
- Trailing swipe:
  - Partial swipe reveals `Archive` and `Delete`.
  - Full swipe performs `Archive`, not delete.
  - `Archive` uses a neutral folder/archive icon and non-destructive tint.
  - `Delete` uses a trash icon and destructive tint.
- Delete always shows a confirmation alert:
  - Title: `Delete Topic?`
  - Message: `This permanently deletes the conversation and all local messages. This cannot be undone.`
  - Buttons: `Cancel`, `Delete`
- Archive shows no blocking alert. It removes the row with animation and shows an undo toast/banner for 5 seconds:
  - Text: `Archived "Project Alpha"`
  - Button: `Undo`
- Undo restores the topic to its prior position and selection state if it was selected.

Pinning recommendation:

- Do not add reordering in Gate 2B.5.
- Add `Pin Topic` as a context-menu action only if the data model already supports explicit pin/sort metadata. If not, defer pinning.
- Keep default order as `lastActivityAt DESC`, with pinned topics reserved for a later Gate 3 UX decision.

## M9 — Define the Two Empty States as Concrete Screens

**Severity:** Must-have

The spec correctly distinguishes fresh install from hidden existing sessions, but it needs exact UI.

Fresh install, no local topics and no importable sessions:

```text
Topics

        [BeeChat mark or simple chat glyph]
        No conversations yet
        Start a topic when you are ready to chat with Bee.

        [Start a Conversation]
```

- `Start a Conversation` is a primary filled button.
- Tapping it opens the New Topic sheet.
- No secondary links, no technical language, no raw session wording.

Existing sessions hidden, no local topics but importable sessions exist:

```text
Topics

        [BeeChat mark or simple chat glyph]
        No topics yet
        BeeChat now keeps your conversations organized as topics.

        [Start a Conversation]
        [Import Recent Sessions]
```

- `Start a Conversation` remains primary.
- `Import Recent Sessions` is a secondary button, not a small text link.
- Tapping import opens a sheet, not an immediate migration.
- Import sheet title: `Import Recent Sessions`
- Sheet shows a concise explanation and a selectable list of candidate sessions using human-readable derived titles only.
- Default selection: none, unless confidence is high that the session is user-created.
- Completion result: selected sessions become topics, then the user returns to the topic list.

If the import scan fails, keep the fresh empty state visible and show a non-blocking banner: `Could not load recent sessions. Try again.`

## M10 — Expand Gateway Disconnected and Send Failure UX

**Severity:** Must-have

The spec says disconnected topics remain visible with disabled composer, but Gate 2C depends on exact send behavior.

Required behavior when gateway is disconnected:

- Topic list remains usable.
- Chat history remains readable.
- Composer stays visible but sending is disabled.
- Placeholder changes to `Reconnect to send messages`.
- A non-blocking banner appears above the message list: `Offline. Showing cached messages.` with `Retry`.
- Tapping `Retry` attempts reconnect and updates the toolbar connection state.

If a user has already typed while offline:

- Preserve draft text in the composer.
- Disable the send button.
- Do not clear the draft.
- When reconnection succeeds, re-enable send and keep the draft in place.

If a send starts online and then fails:

- Keep the optimistic message bubble in the transcript.
- Mark it as failed inline.
- Show an inline `Retry` affordance on the failed bubble.
- Retry resends the same local message id if the delivery ledger supports idempotency; otherwise it creates a clear replacement and removes the failed duplicate after success.
- Do not show a modal for routine send failures.

Partial send failure:

- If the user's message is acknowledged but the assistant response stream fails, the user message should remain `sent`.
- The assistant bubble should show `Response interrupted` with `Retry`.
- Retry should regenerate/continue the assistant response for that topic rather than duplicating the user's message.

This aligns with the Gate 2 UX language: banners and inline recovery for routine network failures; alerts only for destructive actions.

## M11 — Add VoiceOver and Dynamic Type Acceptance Criteria

**Severity:** Must-have

Accessibility is currently too high-level for implementation.

Required labels and traits:

- New topic button: `New Topic`, hint `Creates a conversation topic`.
- Topic row: label includes topic name, last message preview if present, unread count if present, and connection/delivery status if relevant.
- Archive action: `Archive Topic`, hint `Hides this topic from the list`.
- Delete action: `Delete Topic`, hint `Permanently deletes this topic and its messages`.
- Undo archive button: `Undo archive`.
- Connection indicator must expose text state: `Connected`, `Offline`, `Reconnecting`, or `Error`.

Dynamic Type:

- Topic rows support at least two-line titles and two-line previews at large sizes.
- Empty states should scroll if content no longer fits.
- New Topic sheet may expand from fixed height to `.medium` at large accessibility sizes.
- Buttons must keep a 44 pt minimum hit target.

Color and status:

- Do not use a green dot alone for online state.
- Use icon + text in visual UI, and an accessibility label that names the state.
- Any unread indicator must include the number as text, not only a colored badge.

## M12 — Define First-Launch Onboarding Without a Walkthrough

**Severity:** Should-have

Do not add a multi-step walkthrough for Gate 2B.5. It would be heavier than the feature needs and would slow down first use.

Recommended onboarding:

- First launch lands on the empty topic list.
- The primary empty-state action is `Start a Conversation`.
- After the first topic is created and the chat detail opens, show a lightweight no-messages prompt in the transcript area:
  - `Ask Bee anything to get started.`
- The composer is focused after topic creation, so the next action is obvious.
- No coach marks unless usability testing shows users miss the `+` button and primary CTA.

This keeps onboarding native and quiet while still guiding the first successful action.

## M13 — Resolve Internal Spec Contradictions Before Build

**Severity:** Must-have

The revised top section says topics are created with a gateway-format session key upfront. Later sections still describe `sessionKey: nil`, first-message key creation, and updating the key after gateway response.

Q needs one source of truth:

- If Kieran B2 is accepted, remove or rewrite all remaining `sessionKey: nil` mobile flow text.
- Update D3, D6, Gate 2C impact, implementation plan step 7, and Q question 3.
- Manual validation should confirm topic creation creates both `Topic.sessionKey` and bridge entry before the first message.

This is not just a technical contradiction. It affects UX because offline-created topics can exist locally and preserve drafts before the first send.

## M14 — Add Manual UX Validation Checklist

**Severity:** Should-have

Add a specific UX checklist to the exit criteria:

- Create topic on iPhone portrait: sheet opens, keyboard focuses, create disabled until valid text.
- Try to dismiss dirty New Topic sheet: discard confirmation appears.
- Paste an overlong topic name: 80-character limit holds, UI does not overflow.
- Create topic on iPad: popover anchors to plus button.
- Archive topic: row animates away, undo restores it.
- Delete topic: destructive confirmation appears and copy mentions local messages.
- Fresh install empty state: only `Start a Conversation` primary action appears.
- Existing hidden sessions empty state: `Import Recent Sessions` secondary action opens an import sheet.
- Offline with cached topics: list and transcript remain readable, composer preserves draft, send disabled.
- Failed send: failed bubble has inline retry, no modal.
- VoiceOver can create, archive, delete, and undo archive without unlabeled controls.
- Large Dynamic Type does not truncate critical buttons or hide the create action.

## Recommendation

Approve the architecture direction, but hold implementation until the spec incorporates M6-M14. The biggest design correction is to make Topic creation and offline/send failure behavior deterministic. Once those are explicit, Q can build this with native SwiftUI patterns and Bee can validate it without interpretation.
