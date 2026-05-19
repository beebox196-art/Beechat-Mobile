# Bug Fix: Simulator Test Findings (Phase 2)

**Date:** 2026-05-19
**Found by:** Adam (simulator testing)
**Severity:** P2 (crash + UX issue)

## Bug 1: NSMicrophoneUsageDescription Crash (CRITICAL)

**Symptom:** App crashes with TCC error when user taps the microphone/dictation button in Exyte's input bar:
```
This app has crashed because it attempted to access privacy-sensitive data without a usage description.
The app's Info.plist must contain an NSMicrophoneUsageDescription key.
```

**Root Cause:** The source `Info.plist` (`Sources/App/Info.plist`) contains `NSMicrophoneUsageDescription`, but Xcode 16+ doesn't reliably merge keys from the explicit Info.plist when `GENERATE_INFOPLIST_FILE` is implicitly YES at the project level. The built app's Info.plist is missing the key entirely.

Verified: `plutil -p BeeChatMobile.app/Info.plist` shows no `NSMicrophoneUsageDescription`.

**Fix:** Add `INFOPLIST_KEY_NSMicrophoneUsageDescription` as a build setting in the app target's Debug and Release configurations. Xcode 16+ respects `INFOPLIST_KEY_*` build settings even when generating the plist.

In `project.pbxproj`, add to BOTH the Debug and Release build configurations for the `com.ambox.beechatmobile` target:
```
INFOPLIST_KEY_NSMicrophoneUsageDescription = "BeeChat uses the microphone for voice dictation of messages.";
```

Also verify the key is present in `Sources/App/Info.plist` (it already is). Belt and suspenders.

**Alternative fix:** Set `GENERATE_INFOPLIST_FILE = NO` for the app target only (frameworks should keep YES). This forces Xcode to use the explicit Info.plist directly. But this means ALL required keys must be in the Info.plist file (they currently are).

**Recommended:** Use `INFOPLIST_KEY_NSMicrophoneUsageDescription` build setting — same pattern we used for SolarWidget.

**IMPORTANT:** This is the SAME bug pattern we hit with SolarWidget AppInfo.plist. Xcode 16+ doesn't merge `INFOPLIST_KEY_*` or explicit Info.plist values reliably when `GENERATE_INFOPLIST_FILE` is active. We need to add the key as a build setting.

## Bug 2: No Send Button Visible When Input Is Empty (UX)

**Symptom:** When the input field is empty, only a microphone icon is shown (no send button). User expects a send button to be visible.

**Root Cause:** This is **standard Exyte ChatView behavior**. The `rightOutsideButton` in `InputView.swift` shows:
- **Microphone button** when `state.canSend` is false (empty input)
- **Send arrow button** when `state.canSend` is true (text entered)

This is by design — the send arrow replaces the mic icon when you start typing. Pressing Return/Enter on the keyboard also sends.

**Fix Options:**
1. **No change (recommended):** This is standard chat UX (iMessage, WhatsApp, etc.). The send button appears when text is entered. Return key also sends.
2. **Custom theme:** Override `ChatTheme` to always show send button alongside mic, but this requires forking Exyte or a custom `InputView`.
3. **Hide mic entirely:** Remove `AvailableInputType.audio` from Exyte's config to always show send arrow (but we need mic for Phase 1 voice dictation).

**Recommended:** Keep current behavior. Add a visual indicator or tooltip that "Start typing to see the send button" is unnecessary — users familiar with iMessage/WhatsApp will expect this.

**Note for Adam:** The Return key on the software keyboard should send the message. If Return isn't sending, that's a separate bug in the `didSendMessage` callback wiring.

## Build Settings to Change

In `BeeChatMobile.xcodeproj/project.pbxproj`, add to both app target configs (lines ~409 and ~427):

```
INFOPLIST_KEY_NSMicrophoneUsageDescription = "BeeChat uses the microphone for voice dictation of messages.";
```

Also consider adding other privacy keys that may be needed:
- `INFOPLIST_KEY_NSCameraUsageDescription` — if camera attachment is enabled
- `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` — if photo picker is enabled

These aren't crashing yet because those features haven't been tested, but they'll fail the same way if triggered.