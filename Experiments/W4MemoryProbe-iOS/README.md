# W4 Memory Probe — iOS

iOS companion to `BeeChat-v5/Experiments/W4MemoryProbe` (macOS). Same 500-message
corpus and container shape (`ScrollView + LazyVStack`), same markdown-webview vs
native-Text comparison — but measured against iOS's much tighter budget, where the
ceiling is **jetsam**, not user patience.

## Build & run

```
cd Experiments/W4MemoryProbe-iOS
xcodegen
open W4MemoryProbeiOS.xcodeproj
```

Run **on device**, ideally the oldest supported class (iPhone SE / 4 GB). Simulator
numbers are indicative only — jetsam limits and WebContent process behavior differ
materially on device.

## Protocol

1. Native renderer: "Scroll" through all 500 (~25 s). Record settled MB. Baseline.
2. Relaunch fresh. markdown-webview renderer: scroll all 500. Record settled + peak MB
   and the ⚠︎ memory-warning counter (top right).
3. Reflow stress (iOS counterpart of macOS window resize): tap "Aa" to jump between
   default and accessibility3 Dynamic Type with everything instantiated; watch for
   stale heights, hangs, and footprint spikes. Rotate the device twice for the same
   reason.
4. Background the app for 1 min, foreground it: bubbles must repaint (WebContent
   processes are reclaimed aggressively on iOS — blank bubbles here = missing
   `webViewWebContentProcessDidTerminate` handling in whatever ships).

## Provisional pass/fail thresholds (per Q's consensus numbers)

| Metric | Threshold |
|---|---|
| App footprint (settled, after full scroll) | **≤ 200 MB** |
| Memory warnings during protocol | **0** |
| Jetsam kill during protocol | disqualifying |
| Dynamic Type / rotation reflow | heights settle ≤ 200 ms, no stale/overlapping bubbles |
| Foreground-return after backgrounding | all bubbles repaint, no permanent blanks |
| vs native baseline | ≤ 4× |

**Context:** BeeChat-Mobile's iOS-specific risk analysis for this pattern (jetsam,
cell-reuse churn, UIViewRepresentable specifics) is in this repo at
`Docs/Specs/html-rendering/01-risk-analysis.md`. Keep this cycle's numbers separate
from the macOS/BeeChat-v5 thresholds — different ceilings, different failure modes.
