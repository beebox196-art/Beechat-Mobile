# HTML Rendering — Final Consensus Assessment

**Status:** Consensus — ready for implementation planning
**Date:** 2026-07-02
**Authors:** Q (implementation agent), with reference to Fable's round-2 and bridge docs
**Architecture:** Native-first hybrid (Architecture C default + WebView escape hatch)

---

## Agreements — Where Round-2 Resolves Earlier Disagreements

### ✅ A1. "~95% native" claim is now correctly framed

My earlier review flagged Fable's "95%+" assertion as stated-as-fact without evidence. Round 2 reframes this correctly: the converter scaffold has a **closed allowlist** that defines the boundary, and `needsWebView` is a deterministic binary output. The 95% figure is now described as an estimate to be validated by logging `needsWebView` rates in production — "let data set N."

This is exactly right. The classification boundary is a product decision we own, not a statistical prediction. The scaffold's `nativeTags` set and resource caps make this enforceable in code. **Resolved.**

### ✅ A2. `NSAttributedString(html:)` — disagreement collapsed

Round 2 doesn't re-litigate this. The converter scaffold uses SwiftSoup exclusively; `NSAttributedString(html:)` doesn't appear. My earlier concern about keeping it as a dev reference is minor — we can add a debug-only comparison target later. The scaffold makes the right call by not depending on it. **Resolved; no action needed.**

### ✅ A3. Architecture B (single-WebView) — context dependency acknowledged

My review noted that B's low ranking was context-dependent (we've already invested in ExyteChat). Round 2's priority list puts B at position (ii) with the same caveats. Both reviews agree: for BeeChat specifically, B is wrong. For a greenfield app, it would be legitimate. **Resolved; documented.**

### ✅ A4. Security — both reviews agree, round 2 adds the converter-surface analysis

My review and Fable's findings both say: sanitize natively before injection. Round 2 adds the key insight that the **converter's output is inert** — no script execution surface at all. The attack surface moves to SwiftSoup parse-time DoS (handled by node/depth/length caps that fail closed to the WebView) and URL scheme validation. The test matrix's Tier 4 (S1–S10) covers this exhaustively. This is a significant addition that my review didn't have. **Resolved; adopted.**

### ✅ A5. Streaming bubble as WebView — universal across architectures

Both reviews agree: the streaming bubble is a WebView in every architecture on the table. Round 2 makes this explicit: "the streaming bubble is a web view in every candidate architecture." This is correct because streaming requires incremental `innerHTML` replacement at ~5fps, which native AttributedString cannot do incrementally (you'd need to re-parse and re-layout the entire message on each chunk). One WebView for one message is fine — the problem only arises at scale. **Resolved; adopted as invariant.**

### ✅ A6. Block-based output model — superior to single AttributedString

My review assumed the converter would produce a single `AttributedString`. Round 2's scaffold produces `[MessageBlock]`, which is strictly better:

- Code blocks with backgrounds and monospace need their own view container
- Images need `AsyncImage`, not inline text
- Blockquotes need visual nesting that a single `AttributedString` can't express
- Per-block theming is trivial with blocks; impossible with a single string

The render sketch in the scaffold's comment section shows exactly how `ConvertedMessageView` composes these. This is the right design. **Adopted; my review's Phase 0 converter step should target `[MessageBlock]` output, not `AttributedString`.**

### ✅ A7. Fail-closed behavior — correct and well-specified

Unknown tags, resource cap breaches, and `<table>` all set `needsWebView = true`. The converter never produces partial output presented as complete. This is the right invariant. Test matrix S1–S10 verify it. **Adopted.**

---

## Remaining Concerns

### ⚠️ R1. The `collapsedWhitespace()` edge case

The scaffold's `collapsedWhitespace()` extension splits on `.whitespacesAndNewlines`, joins with single spaces, then re-adds leading/trailing whitespace. This handles `<b>bold</b> text` correctly (preserving the boundary space). But it will **collapse intentional line breaks** inside `<pre>` content that SwiftSoup's `text()` returns with newlines intact.

However: `<pre>` content is extracted via `wholeText()`, not `text()`, and `wholeText()` preserves newlines. The `collapsedWhitespace()` function is only called on `TextNode` content in the inline/block walk, not inside `<pre>` blocks. So this is actually fine — `<pre>` bypasses the whitespace collapse path entirely.

**Verdict:** Not a bug. But add a test case (C27) that explicitly verifies `<pre>` whitespace preservation, so this invariant is pinned. The scaffold's `collapsedWhitespace()` should have a doc comment noting that it's intentionally not used inside `<pre>`.

### ⚠️ R2. `<div>` handling — too permissive in `nativeTags`

`<div>` is in `nativeTags`, which means `<div class="warning-box">` will be converted natively, with the `class` attribute silently dropped. This is correct behavior (the converter degrades styling, not structure), but it could produce unexpected results: a `<div>` that was semantically important (e.g., a callout box) renders as a plain paragraph.

The fail-closed philosophy says unknown tags → WebView. But `<div>` is known, just commonly misused. The converter should map `<div>` to `.paragraph` (which it does), and the product decision is: do we want `<div>` with class attributes to fall through to WebView?

**Recommendation:** Keep `<div>` in `nativeTags` for now. The vast majority of `<div>` in chat messages are structural wrappers, not styled callouts. Log the `needsWebView` rate in production and revisit if `<div>`-with-classes becomes common. Add a test case for `<div>` with class/style attributes verifying they're silently dropped.

### ⚠️ R3. `<sub>/<sup>/<small>/<mark>` — needs a product decision

The test matrix (C19) flags these as "not in nativeTags, currently trips needsWebView." This is a real gap: subscript, superscript, and highlighted text appear in technical agent output. `<mark>` (highlight) is especially likely in search-result summaries.

**Recommendation:** Add `<sub>`, `<sup>`, `<small>`, and `<mark>` to `nativeTags` as plain-text passthrough (strip tags, keep content). This keeps the fail-closed pattern — we're not trying to render them with native formatting, just not ejecting the entire message to WebView because of a `<mark>` tag. The test matrix should assert this degradation.

### ⚠️ R4. Inline `<code>` inside `<pre>` — double extraction risk

The scaffold extracts `<pre>` content via:
```swift
let codeEl = (try? child.select("code").first()) ?? nil
```

If `<pre>` contains `<code class="language-swift">`, it correctly extracts the language and content. But if `<pre>` contains bare text without `<code>`, it falls back to `child.wholeText()`, which is also correct.

The edge case: `<pre><code>...</code>more text</pre>` — the `wholeText()` extraction on `codeEl ?? child` would get the `<code>` content only, losing "more text". This is extremely rare in real HTML (browsers render `<pre>` with mixed content poorly too), but the test should pin the behavior.

**Recommendation:** Add test case for `<pre>` with mixed `<code>` and bare text. Document that `<pre>` extraction is "first `<code>` child or whole text" and that mixed content degrades gracefully (doesn't crash, may lose trailing text in `<pre>`).

### ⚠️ R5. The scaffold doesn't handle `<br>` inside inline context

The scaffold handles `<br>` in the block walk (adding `\n` to `pendingInline`), but not in `buildInline`. If `<br>` appears inside `<b>text<br>more</b>`, the inline walk hits the `default` case, which calls `buildInline` recursively on `<br>` — but `<br>` isn't in the inline switch cases.

Looking more carefully: `<br>` is in `nativeTags`, so it passes the `nativeTags.contains(tag)` check. But in the `switch` inside `buildInline`, there's no case for `"br"`. It falls through to `default: break`, which means `<b>text<br>more</b>` would produce "textmore" without a line break.

**This is a bug.** Fix: add `case "br":` to `buildInline` that appends `AttributedString("\n")`.

**Severity:** Medium. `<br>` inside inline formatting is common enough to hit in real chat messages.

### ⚠️ R6. Image handling — inline `<img>` drops silently

The scaffold's `buildInline` handles `<img>` by replacing it with alt text:
```swift
case "img":
    inner = AttributedString((try? child.attr("alt")) ?? "")
```

This means `<p>See <img src="chart.png" alt="the chart"> for details</p>` becomes "See the chart for details" — the image context is lost and the user sees plain text where they expected a visual.

In the block walk, `<img>` with http/https `src` produces `.image(source:alt:)`, which renders as `AsyncImage`. But inline images (inside paragraphs) are degraded to alt text with no way to tap-to-load.

**Recommendation:** This is acceptable for v1 with a documented limitation. For v2, consider splitting paragraphs that contain images into: text-before + `.image()` + text-after, composing multiple blocks from one `<p>`. This requires more complex block assembly logic but is the right UX.

### ⚠️ R7. The scaffold's render sketch uses `ForEach(indices)`

The comment-block render sketch uses:
```swift
ForEach(converted.blocks.indices, id: \.self) { i in
```

This is fine for prototyping, but in production, `MessageBlock` needs a stable identity for animated insertions. Consider adding a `uuid` to each `MessageBlock` or using the parent message's ID + block index as a composite key. This is a polish concern, not a blocker.

---

## The Sanitizer Question

Fable's round 2 correctly identifies this as **"the only unowned prerequisite — it gates every architecture on the table."**

### Where should the sanitizer allowlist live?

**Answer: In the app, at ingest time. Not in the gateway.**

Rationale:

1. **Trust boundary:** The gateway serves multiple clients. A sanitizer allowlist that's correct for iOS may be wrong for macOS or a future web client. The gateway should deliver content faithfully; the client should sanitize for its rendering capabilities.

2. **Offline resilience:** Messages stored in the local DB must be renderable without network. If sanitization happens at the gateway, a message that passes the gateway's sanitizer today might fail a future stricter version. If sanitization happens at ingest, the stored message is always in a known-good state for the local renderer.

3. **Attack surface:** The converter's fail-closed behavior (`needsWebView`) means that even if a message contains unsanitary HTML, it won't execute in the WebView either (because the WebView also needs a sanitizer, but that's a second line of defense). The native path produces inert output regardless. The WebView path receives sanitized HTML.

4. **The gateway still has a role:** The gateway should do *basic* sanitization — strip `<script>`, `<style>`, `<iframe>`, `<form>`, event handlers (`on*`), and `javascript:` URLs. This is defense-in-depth, not the primary allowlist. The app's ingest sanitizer is the authoritative one.

### Implementation plan:

1. **Gateway:** Strip `<script>`, `<style>`, `<iframe>`, `<form>`, `on*` attributes, `javascript:`/`data:` URLs. This is coarse and always safe.
2. **App ingest:** Apply the full allowlist (the `nativeTags` set + attribute allowlist). Strip anything not on it. This is the authoritative sanitizer.
3. **Converter:** Receives already-sanitized HTML. Unknown tags → `needsWebView`. The converter's own resource caps (5k nodes, depth 32, 200k chars) are DoS protection, not content policy.

The `HTMLMessageConverter` should document that it expects **sanitized** input. The sanitizer is a separate module that runs before the converter.

---

## W4 Memory Probe — iOS Adaptation Assessment

### Can we use it as-is for BeeChat-Mobile?

**No, not directly.** The probe targets macOS 14+ and uses `NSApplicationDelegate`, `NSApp.setActivationPolicy`, and macOS-specific window management. BeeChat-Mobile is an iOS app.

### What changes are needed for iOS?

| Component | Current (macOS) | iOS adaptation |
|-----------|-----------------|----------------|
| Platform target | `.macOS(.v14)` | `.iOS(.v17)` |
| App bootstrap | `NSApplicationDelegate`, `NSApp.activate` | Standard SwiftUI `@main App` |
| Window sizing | `.frame(minWidth: 700, minHeight: 500)` | Full-screen on device, flexible on simulator |
| Memory readout | `task_info` with `TASK_VM_INFO` | Same API works on iOS (Darwin kernel) |
| ScrollView container | `ScrollView + LazyVStack` | Same — this is the key invariant |
| Renderer picker | Toolbar `Picker` | Bottom sheet or segmented control |
| Drag-resize (W1) | Window resize gesture | N/A on iOS; replace with rotation + Dynamic Type stress test |

### What numbers do we need from it?

For BeeChat-Mobile, the critical thresholds are much tighter than macOS:

| Metric | macOS threshold | Proposed iOS threshold |
|--------|----------------|----------------------|
| App footprint (settled) | ≤ 400 MB | ≤ 200 MB (jetsam risk on 4GB devices) |
| Total (app + WebContent) | ≤ 1.2 GB | ≤ 600 MB |
| Idle drift | < 5% growth | < 5% growth |
| Scroll performance | No hang ≥ 100ms | 55+ FPS on iPhone SE 2nd gen |
| vs native baseline | ≤ 4× | ≤ 4× |
| WebContent process count | Stable small number | 1–2 (iOS shares process differently) |

### Recommendation

Adapt the probe for iOS (estimated 2–3 hours of work: change platform target, strip macOS-specific bootstrap, adjust thresholds). Run it before Phase 0 spike to get baseline numbers. The probe is well-structured and the corpus is realistic — it's worth adapting rather than rewriting.

**Key insight from the probe:** It tests `markdown-webview` specifically, not our `MessageWebView`. For our architecture, the more relevant test is: N WebView bubbles (streaming + fallback messages) + M native-rendered messages. The probe should be extended to test our hybrid layout, not just per-bubble WebView. But as a first data point, the per-bubble WebView numbers from this probe will confirm whether Fable's memory concerns are validated.

---

## Converter Scaffold Review — Is It Production-Ready?

### Verdict: Strong starting point, needs 5 fixes before Phase 0

The scaffold is well-architected:
- ✅ Block-based output model (`[MessageBlock]`) is correct and superior to single `AttributedString`
- ✅ Fail-closed: unknown tags, resource caps, `<table>` all route to `needsWebView`
- ✅ Semantic styling via `inlinePresentationIntent` (theme-applicable at render time)
- ✅ Resource caps (5k nodes, depth 32, 200k chars) are sensible DoS protection
- ✅ URL scheme validation on parsed URLs (not raw strings)
- ✅ The render sketch in comments is a clean SwiftUI composition

### Bugs to fix before using as Phase 0 starting point:

**B1 (Medium): `<br>` not handled in inline context.** `buildInline` has no case for `"br"`, so `<b>text<br>more</b>` produces "textmore" without a line break. Fix: add `case "br": inner = AttributedString("\n")` in `buildInline`.

**B2 (Low): `<div>` in `nativeTags` silently drops class/style attributes.** This is correct behavior but should be documented and tested. Add a test case for `<div class="callout">text</div>` verifying it renders as plain paragraph.

**B3 (Low): `<pre>` with mixed `<code>` and bare text.** The `codeEl ?? child` fallback means `<pre>text<code>code</code>more</pre>` loses "more". Document this limitation; it's rare enough to not block v1.

**B4 (Cosmetic): `collapsedWhitespace()` needs a doc comment** noting it's intentionally not used inside `<pre>` blocks, which preserve whitespace via `wholeText()`.

**B5 (Product decision): `<sub>/<sup>/<small>/<mark>` should be added to `nativeTags`** as plain-text passthrough. Without this, any message containing these common tags falls through to WebView unnecessarily.

### Architectural observations:

- The converter runs **off-main** (noted in the file header). This is correct — message ingest happens on a background queue. The `ConvertedMessage` is a value type (struct), so it's safe to pass to the main thread for rendering.
- **Caching** is mentioned ("in-memory keyed by message id, or a GRDB column"). For Phase 0, in-memory cache with message ID key is sufficient. The cache should have a size limit (e.g., 500 messages) to prevent unbounded growth.
- The **render sketch** is useful but needs production work: `ForEach(indices)` should use stable IDs, and `ConvertedMessageView` needs proper theme integration via `@Environment`.

---

## Go/No-Go for Phase 0 Spike

### Verdict: **GO — Phase 0 spike is still the right next step, with adjustments.**

The converter scaffold changes the Phase 0 plan in two ways:

1. **P0.3 (converter) is partially done.** The scaffold provides the architecture (`[MessageBlock]` output, fail-closed, SwiftSoup walker). Phase 0 should start from the scaffold, fix B1–B5, and add tests for the test matrix cases. This is less work than building from scratch.

2. **P0.2 (classifier) is largely done.** The scaffold's `nativeTags` set + `needsWebView` flag IS the classifier. The binary decision is already implemented. What remains is: extract it into a separate `HTMLContentClassifier.swift` if we want classification logic separate from conversion, or keep it inline. I'd recommend keeping it inline — the converter already makes the classification as a side effect of walking the tree, and a separate classifier would parse the HTML twice.

### Adjusted Phase 0 plan:

| Step | What | Change from original |
|------|------|----------------------|
| P0.1 | Add SwiftSoup SPM dependency | Unchanged |
| P0.2 | ~~Build minimal classifier~~ → Use scaffold's `needsWebView` flag; no separate classifier needed | **Simplified** |
| P0.3 | Fix scaffold bugs (B1–B5), add tests for converter test matrix C1–C15, S1–S10 | **Start from scaffold, not from scratch** |
| P0.4 | Integrate into `MessageMapper` with `[MessageBlock]`-based rendering | Updated for block output model |
| P0.5 | Add `MessageWebView` for escape-hatch messages | Unchanged |
| P0.6 | Scroll performance test: 200 messages, hybrid layout | Unchanged |

**Estimated time:** 2–3 days, unchanged. The scaffold saves time on P0.2/P0.3 that gets reallocated to testing and integration.

### Exit criteria (unchanged from my review):

- [ ] Native-rendered messages scroll at 55+ FPS on iPhone SE (2nd gen) simulator
- [ ] Native-rendered messages get correct VoiceOver reading order
- [ ] Native-rendered messages respond to Dynamic Type changes
- [ ] WebView escape-hatch messages render without white flash
- [ ] Memory stays under 150 MB for 200 messages (95% native, 5% WebView)
- [ ] No scroll jumps when loading history upward

---

## The Critical Path Question: Streaming Bubble WebView

### Does the streaming WebView create a minimum-viable WebView integration we should build first?

**Yes, and it's already in the Phase 0 plan implicitly — but we should make it explicit.**

Here's why the streaming WebView is architecturally significant:

1. **It's guaranteed in every architecture.** Round 2 states: "the streaming bubble is a web view in every candidate architecture." This means we MUST build a `MessageWebView` (or `StreamingBubbleView`) regardless of whether the main transcript uses native or WebView rendering.

2. **It validates the scaffold.** The streaming bubble uses the same `MessageTemplate.html`, `WKNavigationDelegate`, height-reporting bridge, and theme injection as the fallback WebView. Building it first validates the entire WebView infrastructure.

3. **It's low-risk, high-value.** One WebView, one message at a time, with `innerHTML` replacement at ~5fps. No memory scaling issues, no scroll-jump problems, no cell-reuse complexity. It's the simplest possible WebView integration and it ships immediate user value (streaming agent responses rendered with formatting).

4. **It forces the sanitizer.** You can't ship a streaming WebView without sanitizing the HTML it renders. Building the streaming bubble first forces us to implement the sanitizer, which gates everything else.

### Recommended Phase 0 ordering:

```
P0.0: Streaming WebView bubble (MessageWebView + sanitizer + MessageTemplate)
  ↓
P0.1: SwiftSoup dependency
P0.2–3: Converter (from scaffold, with fixes)
P0.4: MessageMapper integration (native path + WebView fallback)
P0.5: (Already done in P0.0 — MessageWebView exists)
P0.6: Scroll performance test
```

P0.0 is the new step. It should take ~1 day (the scaffold already has `MessageWebView.swift` and `MessageTemplate.html`; we wire them into ExyteChat's streaming bubble). This de-risks the entire project because:

- The WebView infrastructure is proven before we build the converter
- The sanitizer is implemented and tested before the converter needs it
- Streaming responses (the primary UX) work from day one
- The converter becomes an optimization, not a prerequisite

---

## Summary

| Dimension | Q Review | Fable Round 2 | Consensus |
|-----------|----------|---------------|-----------|
| Architecture | C (native-first hybrid) | C (native-first hybrid, bounded-webview path i as pragmatic alternative) | **C, with streaming WebView built first** |
| "~95% native" | Likely but must validate with data | Estimate to be measured by logging needsWebView | **Closed allowlist defines boundary; log rates in production** |
| Converter output | Single AttributedString | `[MessageBlock]` (block model) | **Block model adopted** |
| `NSAttributedString(html:)` | Keep as dev reference | Not mentioned | **Not in scaffold; can add debug comparison later** |
| Fail-closed | Agreed | Converter is inert; fail to WebView | **Adopted** |
| Sanitizer location | Not specified (my review) | Gates every architecture | **App-side at ingest; gateway does coarse strip** |
| Streaming bubble | Agreed it's WebView | Agreed it's WebView in every architecture | **Build first as P0.0** |
| W4 probe | Not evaluated | Built and ready to run | **Adapt for iOS; run before Phase 0** |
| Converter scaffold | Not yet written | Written, with bugs | **5 fixes (B1–B5), then use as Phase 0 starting point** |
| Phase 0 timeline | 2–3 days | Priority list starts with converter | **2–3 days, starting from scaffold + streaming WebView first** |

### Build order:

1. **Streaming WebView bubble + sanitizer** (day 1) — immediate UX value, validates infrastructure
2. **Converter from scaffold** (days 2–3) — fix B1–B5, add test matrix coverage, integrate into MessageMapper
3. **Hybrid layout test** (day 3) — 200-message scroll test with native + WebView mix
4. **iOS W4 probe adaptation** (parallel, 2–3 hours) — get memory numbers before committing to Phase 1

**Total Phase 0: 2–3 days. Phase 1–3 timeline unchanged from review (7–11 days total).**
---

## W4 Memory Probe — Measured Results (macOS, M-series, 2026-07-02)

### Native Text Baseline (500 messages, ScrollView + LazyVStack)

| State | App Footprint |
|-------|--------------|
| Fresh start | 48 MB |
| After full auto-scroll | 59 MB |
| Peak | 59 MB |
| 3 min idle (drift) | 0% |

### Per-bubble WebView (markdown-webview, 500 messages)

| State | App Footprint |
|-------|--------------|
| Fresh start | 48 MB |
| After full auto-scroll | 251 MB |
| Peak during scroll | 253 MB |
| 3 min idle (drift) | 0% (251 MB stable) |
| W1 resize spike | 434 MB peak → 271 MB settled |

### Comparison

| Metric | Value |
|--------|-------|
| WebView / native ratio (settled) | 4.25× (251/59) |
| Resize transient spike ratio | 1.73× (434/251) |

### Threshold Compliance (macOS)

| Metric | Fable's Threshold | Result | Status |
|--------|-------------------|--------|--------|
| App process (settled) | ≤ 400 MB | 251 MB | ✅ Pass |
| Idle drift (3 min) | < 5% | 0% | ✅ Pass |
| Interactive scroll | No hang ≥ 100ms | Smooth | ✅ Pass |
| vs native baseline | ≤ 4× | 4.25× | ⚠️ Marginal |
| WebContent process count | Stable, not per-bubble | Pooled | ✅ Pass |

### W1 Resize Test

| Metric | Threshold | Result | Status |
|--------|-----------|--------|--------|
| No overlapping/clipped/stale bubbles | Zero | Minor top-left clipping during drag | ⚠️ Needs Instruments verification |
| Heights settle ≤ 200ms | ≤ 200ms | Not measurable with current setup | ⬜ Open |
| No main-thread hang ≥ 100ms | Zero | Not measured | ⬜ Open |
| WebContent CPU idle ≤ 2s | ≤ 2s | Not measured | ⬜ Open |

### iOS Projection

iOS thresholds are much tighter (≤ 200 MB app footprint on 4 GB devices, jetsam kills aggressively). macOS 4.25× ratio projects to approximately 240 MB app footprint on iOS (4.25 × ~56 MB native baseline on device). This exceeds the 200 MB jetsam-safe threshold, confirming Fable's analysis: per-bubble WebView at scale is not viable on iOS.

### Conclusion

The macOS numbers confirm the core risk: per-bubble WebView uses 4.25× the memory of native rendering, exceeding the ≤ 4× threshold marginally on macOS and projecting to exceed jetsam limits on iOS. The native-first hybrid (Architecture C) remains the correct choice. The bounded escape hatch (N recent messages as WebView) is safe because N is bounded to a handful — the 4.25× penalty only becomes problematic at 500-message scale.
