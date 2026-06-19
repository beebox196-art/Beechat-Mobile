# Code Review Brief: P2 Simulator Bug Fix

**Reviewer:** Kieran (adversarial code review)
**Scope:** NSMicrophoneUsageDescription crash fix in project.pbxproj

## Context

Adam tested Phase 2 on the simulator. Two issues found:

1. **CRASH:** App crashes with TCC error when tapping the mic/dictation button — `NSMicrophoneUsageDescription` key missing from built app's Info.plist despite being in the source file. This is the Xcode 16+ `GENERATE_INFOPLIST_FILE` bug we hit on SolarWidget.

2. **UX:** No send button visible when input is empty — this is expected Exyte ChatView behavior (send arrow replaces mic icon when you type). No fix needed.

## Bug 1 Fix

Q is adding `INFOPLIST_KEY_NSMicrophoneUsageDescription`, `INFOPLIST_KEY_NSCameraUsageDescription`, and `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` as build settings in the app target's Debug and Release configurations. These are belt-and-suspenders alongside the existing `Sources/App/Info.plist` entries.

## What to Review

When Q's fix is committed:

1. **Verify** the `INFOPLIST_KEY_*` build settings are in BOTH Debug and Release configs for the `com.ambox.beechatmobile` target
2. **Verify** the keys are NOT added to framework targets (BeeChatMobileKit, BeeChatUI) — frameworks don't need them
3. **Verify** the existing `Sources/App/Info.plist` still has the original keys (belt and suspenders)
4. **Check** the built app's Info.plist contains all three privacy keys
5. **Confirm** no other `INFOPLIST_KEY_*` settings were accidentally removed or changed

## Expected Files Changed

- `BeeChatMobile/BeeChatMobile.xcodeproj/project.pbxproj` — only this file
- No Swift source files should be modified