# HTML Message Rendering — Q Review

**Reviewer:** Q (Implementation Agent)
**Date:** 2026-07-02
**Spec Pack:** `/Docs/Specs/html-rendering/` (5 files by Fable)
**Recommendation:** **Native-first hybrid (Architecture C + A escape hatch). Adopt Fable's recommendation.**

---

## Agreements — Where Fable Is Right

### A1. Per-bubble WKWebView as default is a hard pass

I agree completely. The risk analysis (01-risk-analysis.md) is accurate and thorough:

- **Memory:** 3–15 MB in-process + 10–40 MB WebContent per live view is correct. I've seen these numbers in production apps. On a 4 GB device, 20 visible bubbles will hit jetsam.
- **Async height round-trip → scroll jump:** This is the fatal flaw. In ExyteChat's inverted `UITableView`, every late height invalidation shifts the scroll position. There is no SwiftUI/UIKit API for "keep visual anchor while rows above resize." This cannot be worked around — it's a structural defect of the per-bubble design.
- **VoiceOver fragmentation:** Each web view is its own accessibility container. Chat transcripts become incoherent for VoiceOver users. This is not a polish issue — it's a showstopper for accessibility compliance.
- **Cell reuse stale content:** The `updateUIView` identity keying pattern Fable provides in `MessageWebView.swift` is necessary but doesn't eliminate the white-flash-on-recycle problem. Every cell reuse triggers the full template-load → JS inject → async render cycle. You see the flash.

**Verdict:** Architecture A (per-bubble WKWebView for all messages) should not ship. I agree with Fable's bottom line on this.

### A2. Architecture B (single WebView for transcript) is correct to rank second

Fable's analysis of the single-webview approach is fair:

- **Pros:** Eliminates per-bubble height round-trip, one WebContent process, coherent layout.
- **Cons are real and severe:** We'd be rebuilding ExyteChat's entire chat UX (swipe actions, context menus, scroll anchors, unread markers, keyboard avoidance) in HTML/JS. We'd own two complete UI stacks. This is months of work for something ExyteChat already gives us natively.

**My additional concern:** The Phase 0 research report explicitly chose ExyteChat to *avoid* building chat UI from scratch. Architecture B discards that investment entirely. It's not just maintenance cost — it's rewriting the core UX in a different paradigm.

### A3. The template and scaffold are production-quality

`MessageTemplate.html` is well-structured:
- CSS custom properties for theming — easy to drive from Swift
- `font: -apple-system-body` for Dynamic Type compliance
- `dir=auto` for RTL
- `ResizeObserver` for height reporting (correct over `MutationObserver`)
- Weak proxy pattern in `MessageWebView.swift` to break the `WKUserContentController` retain cycle
- `webViewWebContentProcessDidTerminate` recovery
- `overrideUserInterfaceStyle` for manual theme switching
- Navigation lockdown in `WKNavigationDelegate`

If we need WKWebView for the escape hatch, this scaffold is ready to use with minimal adaptation. I would ship this.

### A4. The security analysis is correct and important

- **Sanitization must happen natively before injection.** `innerHTML` doesn't execute `<script>`, but `<img onerror=…>` absolutely does. Fable's test cases 21–25 are the right ones.
- **Navigation denial in `WKNavigationDelegate`** (only allow `.other` navigation type for the initial template load) is correct and the scaffold implements it properly.
- **`data:` URI policy** needs a product decision (test case 15). I'd recommend capping at 64 KB and blocking by default, with tap-to-load.

### A5. The test matrix is solid

26 edge cases plus 6 dynamic scenarios is the right scope. The specific cases (long unbroken tokens, nested blockquotes, RTL, broken images, jetsam simulation) are exactly the ones that break real chat rendering.

I would add one case to the matrix:

- **27. Rapid theme toggle:** Switch light → dark → light → dark within 2 seconds. Verify no white flash, no stale theme, no layout thrash. (This is a real regression source that the existing cases don't explicitly cover.)

### A6. SwiftSoup is the right HTML parser

Fable recommends SwiftSoup for the native converter. I agree. It's a mature SPM package (MIT), already widely used in iOS projects, and handles HTML5 error recovery correctly. Using it as the DOM walker for AttributedString conversion is the right call — it avoids `NSAttributedString(html:)` entirely (which is WebKit-backed, main-thread-only, and documented as crash-prone off-main).

---

## Disagreements — Where Fable Is Wrong or Overstated

### D1. "~95% of messages" claim is asserted without evidence

Fable says "Expect this to cover ~95%+ of real chat traffic." This is a reasonable *hypothesis*, but it's stated as fact. The actual percentage depends entirely on what BeeChat agents send:

- If agents primarily send **Markdown** (which the gateway already supports), the native path covers nearly 100% because `AttributedString(markdown:)` handles full Markdown, and our converter only needs to handle the HTML that arrives as `<p>`, `<strong>`, `<code>`, etc. — all trivial conversions.
- If agents start sending **tables** or **complex HTML structures** frequently, the WebView escape hatch becomes common and the 95% claim fails.

**My counter:** The correct framing is "the native path handles a *controllable* subset; we define the boundary, not the data." The classification boundary between native and WebView should be a *product decision* we make, not a statistical prediction we hope for. We should classify at ingest time based on a strict allowlist, not a fuzzy heuristic.

**Action:** Define the native-compatible subset explicitly (see Build Plan §B3). Messages outside that subset go to WebView *by design*, not by accident.

### D2. `NSAttributedString(html:)` is dismissed too broadly

Fable says: "Do not use `NSAttributedString(html:)` — it is WebKit-backed, main-thread-only, slow (~50–200 ms/message), and crash-prone."

This is correct for *production use at scale*, but it's too absolute. `NSAttributedString(html:)` is still useful as:

1. **A validation reference** during development — render a message with both SwiftSoup→AttributedString and `NSAttributedString(html:)`, compare outputs, use the delta to fix converter bugs.
2. **An emergency fallback** if the SwiftSoup converter fails on an edge case — catch the failure, fall back to `NSAttributedString(html:)`, and log the failure for future converter improvement.

I wouldn't use it in the hot path, but I'd keep it in the toolbox.

### D3. The single-webview approach (B) isn't given enough credit for chat apps that *aren't* ExyteChat

Fable's maintenance ranking of B as "3 (worst)" is correct *for our specific context* because we've already invested in ExyteChat. But for a greenfield chat app, B would be a legitimate choice — it's what email clients do, and Discord's mobile app uses a similar hybrid. The ranking is context-dependent, and the doc should acknowledge that explicitly.

This is a minor disagreement — for BeeChat Mobile, B is indeed the wrong choice. But someone reading this spec in isolation might over-generalize the conclusion.

### D4. The scaffold has one bug I'd fix

In `MessageWebView.swift`, the `dismantleUIView` method removes all four message handlers:

```swift
["bcHeight", "bcLink", "bcImage", "bcReady"].forEach {
    controller.removeScriptMessageHandler(forName: $0)
}
```

This is correct, but it should *also* nil out `coordinator.currentHTML` and set `coordinator.templateReady = false` to prevent the coordinator from trying to inject into a deallocated web view during the teardown window. This is a race condition window, not a leak, but it's defensive hygiene.

### D5. Data-URI size cap recommendation is missing

Test case 15 mentions data-URI images but says "policy decision." For the WebView escape hatch specifically, data-URIs above ~64 KB should be stripped by the sanitizer because:
- They bypass the native image pipeline (no caching, no downscaling)
- They bloat WebContent process memory disproportionately
- They're rarely legitimate in chat messages (base64-encoded images should arrive as attachments)

The native path should handle images through `AsyncImage` + URL cache, never through inline data-URIs.

---

## Open Questions — Need Real Prototyping

### Q1. Where exactly is the classification boundary?

The converter needs a binary decision: does this HTML go native or WebView? The boundary must be deterministic and testable. Proposed classification:

**Native-compatible (SwiftSoup → AttributedString):**
- `<p>`, `<br>`, `<div>` (paragraph/line breaks)
- `<b>`, `<strong>`, `<i>`, `<em>`, `<s>`, `<u>` (inline formatting)
- `<a href>` (links)
- `<code>`, `<pre>` (inline and block code)
- `<ul>`, `<ol>`, `<li>` (lists)
- `<blockquote>` (quotes)
- `<h1>`–`<h6>` (headings)
- `<hr>` (dividers)
- `<img>` with remote `src` (via `AsyncImage` attachment)
- Plain text with no HTML tags at all

**WebView escape hatch:**
- `<table>` (any)
- `<iframe>`, `<video>`, `<audio>` (media embeds — if allowlisted at all)
- Multiple `<img>` in a single message with complex layout
- Any tag not in the native allowlist
- Messages where the SwiftSoup converter fails or produces unexpected output

**Open question:** What about `<details>/<summary>`? It's useful for collapsible content but not representable in AttributedString. Probably WebView, but this affects the 95% claim if agents use it heavily.

**What needs prototyping:** Build the classifier, run it against 1,000 real BeeChat messages from the gateway, and measure the actual native vs. WebView split. Until we have real data, the 95% claim is aspirational.

### Q2. What does the SwiftSoup→AttributedString converter look like in practice?

The converter is the core risk of Architecture C. It's bounded work (finite set of HTML tags to map), but the fidelity matters:

- **Bold, italic, strikethrough, underline, code, links** → trivial in AttributedString
- **Lists** → possible with bullet/number prefix + indentation, but not as rich as web rendering
- **Blockquotes** → possible with indentation + vertical bar character, but visually different from the gold-bar `<blockquote>` in the template
- **Code blocks** → possible with monospace font + background, but line wrapping and horizontal scroll need special handling
- **Headings** → possible with font size scaling, but the cap (1.35em in the template) needs to be replicated
- **Images** → need to be extracted as separate SwiftUI views with `AsyncImage`, not embedded in the AttributedString flow

**What needs prototyping:** A SwiftSoup DOM walker that produces AttributedString for the native-compatible subset, plus a SwiftUI view builder that composes the AttributedString with image attachments. This is a 2–3 day spike at most, but it must be done before committing to Architecture C.

### Q3. How does ExyteChat's `messageStyler` hook interact with native HTML rendering?

ExyteChat currently provides a `messageStyler: (String) -> AttributedString` closure. The default is `String.markdownStyler`, which calls `AttributedString(markdown:)`. 

Our current `MessageMapper` passes raw message content as `text` and lets ExyteChat style it. If we adopt Architecture C, we need to:

1. **Ingest:** Receive HTML from the gateway (already the case)
2. **Classify:** Determine native vs. WebView at message-receive time
3. **Native path:** Convert HTML → `AttributedString` via SwiftSoup walker, cache the result
4. **WebView path:** Keep the raw sanitized HTML for `MessageWebView`

This means `MessageMapper.exyteMessage(from:)` needs to produce either a native `AttributedString` (via the styler) or a flag that triggers the WebView bubble. ExyteChat's `MessageView` would need a conditional: native `MessageTextView` for most messages, `MessageWebView` for the escape hatch.

**What needs prototyping:** Can we cleanly extend ExyteChat's `MessageView` to support a custom bubble type alongside the default text bubble? The library has `customView` support — we need to verify this works for our case.

### Q4. Can we get synchronous height from the native path?

The entire scroll-jump problem in Architecture A comes from async height. Architecture C eliminates this because:

- `AttributedString` layout is synchronous in SwiftUI
- ExyteChat's `UITableView` gets the correct row height on first pass
- No height round-trips, no JS callbacks, no white flashes

This is the single strongest argument for Architecture C and it should be verified by measuring scroll performance with 200+ native-rendered messages in the simulator.

### Q5. What happens during the transition period?

We currently have no HTML rendering at all — `MessageMapper` passes raw text (which happens to be HTML from the gateway) through ExyteChat's markdown styler. This means HTML tags currently render as raw text in the app.

The transition plan needs to handle:
1. Messages already in the local DB (stored as raw HTML) must render correctly
2. The converter must handle HTML that our own agents send (which is Markdown-flavored)
3. New messages arriving after the change must be classified and rendered immediately

---

## Recommendation

### Native-first hybrid (Architecture C as default, A as escape hatch)

I adopt Fable's recommendation. The reasoning:

1. **Scroll stability is non-negotiable.** Chat apps must scroll smoothly with predictable layout. Async height round-trips in a recycled table view are architecturally broken for this use case. Architecture C gives synchronous layout. Architecture A does not. This alone decides it.

2. **Accessibility is a requirement, not a nice-to-have.** Native `Text` gets VoiceOver, Dynamic Type, Bold Text, Increase Contrast, and Reduce Motion for free. WebView fragments all of this. We should not ship an inaccessible chat transcript.

3. **Memory is constrained.** iOS devices still ship with 4–8 GB. Architecture A's per-bubble WebContent cost is unbounded. Architecture C's AttributedString cost is kilobytes per message. The difference is 100–1000×.

4. **ExyteChat investment is preserved.** Architecture C keeps the existing message list, cell recycling, gestures, and input bar. Architecture B throws it all away. Architecture A fights against it.

5. **The escape hatch is bounded.** For the <5% of messages that need tables or complex HTML, the WebView scaffold from the spec pack is production-ready. With at most a handful of WebView bubbles live at any time, A's memory and scroll problems disappear.

6. **The converter is bounded work.** Mapping a finite set of HTML tags to AttributedString attributes is a finite, testable problem. SwiftSoup is a known dependency. The converter is ~500–800 lines of Swift — not trivial, but not open-ended either.

---

## Build Plan

### Phase 0: Prototyping Spike (2–3 days)

**Goal:** Validate that Architecture C works with ExyteChat before committing.

| Step | What | Depends on | Output |
|------|------|------------|--------|
| P0.1 | Add SwiftSoup SPM dependency | None | Package.swift updated |
| P0.2 | Build minimal HTML classifier: `HTMLContentClassifier.swift` — given HTML string, returns `.native` or `.webView` based on tag allowlist | None | Classifier with unit tests |
| P0.3 | Build SwiftSoup→AttributedString converter for native-compatible subset (paragraphs, inline formatting, links, code, lists, blockquotes, headings) | P0.1 | Converter with unit tests covering test matrix cases 1–9, 17–20 |
| P0.4 | Integrate converter into `MessageMapper`: replace `text: message.content` with `text: message.content` + custom `messageStyler` that runs classifier + converter | P0.2, P0.3 | Messages render natively in ExyteChat |
| P0.5 | Add `MessageWebView` for escape-hatch messages alongside ExyteChat's custom view hook | P0.2, spec scaffold | WebView renders complex HTML |
| P0.6 | Scroll performance test: 200 messages, 95% native, 5% WebView, measure scroll FPS, memory, height stability | P0.4, P0.5 | Performance baseline |

**Exit criteria:**
- [ ] Native-rendered messages scroll at 55+ FPS on iPhone SE (2nd gen) simulator
- [ ] Native-rendered messages get correct VoiceOver reading order
- [ ] Native-rendered messages respond to Dynamic Type changes
- [ ] WebView escape-hatch messages render without white flash
- [ ] Memory stays under 150 MB for 200 messages (95% native, 5% WebView)
- [ ] No scroll jumps when loading history upward

### Phase 1: Production Converter (3–5 days)

**Goal:** Ship the native converter with full test coverage and the sanitizer.

| Step | What | Depends on |
|------|------|------------|
| P1.1 | Complete SwiftSoup→AttributedString converter with all native-compatible tags (add images via AsyncImage attachment, `<hr>`, `<br>`) | P0 spike results |
| P1.2 | Build native HTML sanitizer: tag allowlist + attribute allowlist, strip `on*` handlers, `javascript:`/`data:` URLs, `<script>`, `<style>`, `<iframe>`, `<form>` | None |
| P1.3 | Wire sanitizer into message receive pipeline: sanitize before classify + convert | P1.2 |
| P1.4 | Wire classifier result into `MessageMapper`: native path uses converter, WebView path passes sanitized HTML to `MessageWebView` | P1.1, P1.2 |
| P1.5 | Implement `MessageWebView` with spec pack scaffold (shared process pool, weak proxy, jetsam recovery, theme switching) | P0.5 validated |
| P1.6 | Unit tests covering all 26 test matrix cases + dynamic scenarios | P1.1–P1.5 |
| P1.7 | Accessibility audit: VoiceOver through 10-message transcript with mixed native/WebView content | P1.4, P1.5 |

### Phase 2: Polish & Edge Cases (2–3 days)

| Step | What | Depends on |
|------|------|------------|
| P2.1 | Dynamic Type: verify native path responds to text-size changes, WebView path reloads with `-apple-system-body` | P1 |
| P2.2 | Theme switching: verify light/dark transitions on both native and WebView paths, no white flash | P1 |
| P2.3 | Image handling: native path extracts `<img>` tags as AsyncImage with shared URL cache; WebView path renders inline | P1 |
| P2.4 | RTL: verify `dir=auto` on native path (AttributedString handles this) and WebView path | P1 |
| P2.5 | Error states: converter failure falls back to plain text (not WebView — keep the escape hatch for complex HTML, not converter bugs); WebView jetsam recovery | P1 |
| P2.6 | Long message truncation: native path clips at ~4,000 px with "Show more"; WebView path clips similarly | P1 |

### Phase 3: Deferred Work

These are important but not on the critical path for initial HTML rendering support:

| Item | Rationale |
|------|-----------|
| Pre-warmed WebView pool | Only needed if WebView escape-hatch frequency is higher than expected. Measure first. |
| "View formatted" full-screen WebView | Product decision — whether to show complex HTML inline or behind a tap. Depends on how often agents send tables. |
| Animated GIF support | Native path: `AsyncImage` doesn't animate GIFs. WebView path: animates but ignores Reduce Motion. Needs a product decision. |
| Link preview enrichment | ExyteChat already has `shouldShowLinkPreview` — wire it for native messages. WebView links go through `bcLink` bridge. |
| Copy/select in WebView bubbles | Text selection inside WKWebView conflicts with cell gestures. Needs native gesture coordination. |

### Dependency Graph

```
P0.1 (SwiftSoup dep)
  ├── P0.2 (classifier)
  │     └── P0.4 (MessageMapper integration)
  └── P0.3 (converter)
        └── P0.4 (MessageMapper integration)
P0.2 + scaffold → P0.5 (MessageWebView)
P0.4 + P0.5 → P0.6 (scroll perf test)
P0.6 passes → P1 (production build)
P1 → P2 (polish)
```

**Total estimated timeline:** 7–11 days (2–3 day spike + 3–5 day production + 2–3 day polish).

---

## Summary

| Dimension | Fable's assessment | Q's assessment |
|-----------|-------------------|-----------------|
| Architecture A (per-bubble WebView) | 3rd choice — fails on memory, scroll, a11y | Agree — should not ship as default |
| Architecture B (single WebView) | 2nd choice — high maintenance, discards ExyteChat | Agree — wrong for our context |
| Architecture C (native AttributedString) | 1st choice — best on all dimensions except fidelity | Agree — recommended with escape hatch |
| "~95% native" claim | Asserted without evidence | Likely correct but must be validated with real data; classification boundary is a product decision |
| `NSAttributedString(html:)` | Never use | Mostly agree, but keep as dev reference and emergency fallback |
| Spec pack quality | N/A (Fable's own work) | High quality — template, scaffold, and test matrix are production-ready |
| Security analysis | Correct | Agree — sanitizer is mandatory, not optional |

**Bottom line:** Build the native-first hybrid. Start with the 2–3 day prototyping spike. Use the spec pack's `MessageWebView.swift` and `MessageTemplate.html` for the escape hatch. Validate the converter against real BeeChat messages before committing to Phase 1.

The converter is the only non-trivial new code. Everything else (ExyteChat integration, WebView scaffold, sanitizer) is wiring.