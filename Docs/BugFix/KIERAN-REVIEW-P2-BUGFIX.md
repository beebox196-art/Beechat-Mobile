# Kieran Review: P2 NSMicrophoneUsageDescription Crash Fix

**Date:** 2026-05-19  
**Reviewer:** Kieran (adversarial)  
**Author of fix:** Q  
**Severity:** Crash (app terminates on microphone/dictation tap)

---

## Summary: APPROVED with 1 non-blocking observation

The fix is correct, durable, and narrowly scoped. The crash is resolved.

---

## Check-by-Check

### 1. Keys in app target only — ✅ PASS

`project.yml` places all three `INFOPLIST_KEY_*` settings under the `BeeChatMobile` application target's `settings.base`. Confirmed absent from both framework targets:

- **BeeChatMobileKit** (lines 380–398 in pbxproj): No `INFOPLIST_KEY_*` entries
- **BeeChatUI** (lines 447–473 in pbxproj): No `INFOPLIST_KEY_*` entries

Correct. Privacy keys belong on the app target, not frameworks.

### 2. Original Info.plist key preserved — ✅ PASS

`Sources/App/Info.plist` still contains the original `NSMicrophoneUsageDescription` key with matching description string. Belt-and-suspenders configuration — both the plist source file AND the xcodegen build settings carry the key. Good.

### 3. xcodegen regeneration — ✅ PASS

`BeeChatMobile.xcodeproj/project.pbxproj` contains the three keys in **both** build configurations for the app target:
- **Debug config** (lines 404–406)
- **Release config** (lines 425–427)

Values are identical across both configs. xcodegen was run after the project.yml change.

### 4. Built app contains NSMicrophoneUsageDescription — ✅ PASS

Verified via `PlistBuddy` on the simulator build:
```
NSMicrophoneUsageDescription = "BeeChat uses the microphone for voice dictation of messages."
```

The crash is fixed. The built app will present a proper privacy prompt instead of terminating.

### 5. No accidental drift — ✅ PASS

Git status shows only `Info.plist` as modified (2 lines added — the NSMicrophoneUsageDescription key/value pair). The `project.yml` changes are untracked (pre-existing state, not part of this fix). `pbxproj` regenerated cleanly with only the 3 expected additions (6 lines total: 3 keys × 2 configs). No other settings touched.

### 6. Camera and Photo Library keys in built plist — ⚠️ OBSERVATION

`NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` are **NOT** present in the built app's Info.plist, despite being defined in `project.yml`.

**Root cause (benign):** Xcode's `GENERATE_INFOPLIST_FILE = YES` merges build settings with the base `INFOPLIST_FILE` (the static plist). However, the app target's linked frameworks are:
- `BeeChatMobileKit.framework`
- `BeeChatUI.framework`
- `GiphyUISDK`

No direct linkage to `AVFoundation` (for Camera) or `Photos`/`PhotosUI` frameworks. Xcode's plist generation prunes usage-description keys when the corresponding framework isn't linked — this is by design to avoid shipping unnecessary privacy keys.

**Impact:** None currently. If the app later adds camera/photo features and links the relevant frameworks, the keys will automatically appear. The build settings act as a dormant configuration ready to activate. Not a bug, but worth documenting.

### 7. Description string review — ✅ PASS

| Key | String | Assessment |
|---|---|---|
| NSMicrophoneUsageDescription | "BeeChat uses the microphone for voice dictation of messages." | Clear, specific, user-facing. Explains both *what* (microphone) and *why* (voice dictation). |
| NSCameraUsageDescription | "BeeChat uses the camera to take photos for messages." | Good. Would need updating if camera is used for anything beyond photos (e.g., video, scanning). |
| NSPhotoLibraryUsageDescription | "BeeChat uses the photo library to select photos for messages." | Good. Covers read access. Note: `NSPhotoLibraryAddUsageDescription` may be needed separately if the app ever *saves* to the library (write-only vs read-write are distinct keys). |

---

## Risks & Recommendations

### Low Risk: Inconsistent key source

The `NSMicrophoneUsageDescription` key exists in **two places**:
1. `Sources/App/Info.plist` (static file)
2. `project.yml` → `INFOPLIST_KEY_NSMicrophoneUsageDescription` (build setting)

Both currently carry the same value. If someone updates one but forgets the other, the build setting wins (it overrides the plist key during merge). This is fine as long as the plist file is treated as the fallback and the build settings as the source of truth.

**Recommendation:** Consider removing the key from `Info.plist` and consolidating all usage descriptions in `project.yml` for a single source of truth. This avoids future drift. Not urgent — the current redundancy is harmless and arguably defensive.

### Low Risk: Future camera/photo features

The Camera and Photo Library usage descriptions are defined but inactive. When those features are added, verify:
- Relevant frameworks are linked to the app target
- The keys appear in the built plist
- Consider whether `NSPhotoLibraryAddUsageDescription` (write-only) is needed instead of or alongside the read-write `NSPhotoLibraryUsageDescription`

---

## Verdict

**APPROVED.** The fix is correct, minimal, and durable. The crash is resolved. The observation about Camera/Photo Library keys being dormant is informational, not a defect. No blocking issues.
