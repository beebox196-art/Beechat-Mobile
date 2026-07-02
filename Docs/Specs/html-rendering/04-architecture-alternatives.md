# HTML Message Rendering — Architecture Alternatives

Three candidate architectures for rendering HTML message content in BeeChat-Mobile,
plus the recommended hybrid. Context: transcript is currently ExyteChat
(inverted UITableView under SwiftUI), messages arrive as HTML.

---

## A. Per-bubble WKWebView (the proposed approach)

Each bubble embeds a `WKWebView` via `UIViewRepresentable`; JS reports intrinsic height.

- **Memory: poor.** 3–15 MB in-process per live web view + 10–40 MB/document in WebContent
  processes. Lazy stacks never release them; List/table reuse means constant rebuild churn
  instead. Jetsam kills WebContent → blank bubbles needing recovery.
- **Performance: poor.** Out-of-process async paint (pop-in/white flash on every recycled
  cell), 10–50 ms creation cost per view during scroll, and the fatal one: **async height
  round-trip → late row-height changes → scroll jumps** while paging through history.
- **Accessibility: poor.** Transcript fragments into per-bubble web containers; VoiceOver
  order and focus become unreliable; Dynamic Type only via `-apple-system-body` + reload.
- **Maintenance: medium.** The template/bridge is contained (see scaffold), but you own a
  web view reuse pool, jetsam recovery, sanitizer, and scroll-anchoring workarounds forever.

## B. Single WKWebView renders the whole transcript

One web view is the chat surface; messages are DOM nodes; SwiftUI provides the shell
(nav, composer, sheets). This is the classic email-client architecture applied to chat.

- **Memory: good.** One document, one process; WebKit manages tiles for offscreen content.
  Long histories need JS DOM windowing (virtualized list) or memory grows with the DOM.
- **Performance: good.** No per-cell creation, no height bridging — the document lays
  itself out, so heights are *internal* and scroll never jumps. 60fps is WebKit scrolling,
  which feels near-native but not identical (rubber-banding, keyboard interactions differ).
- **Accessibility: fair.** One coherent web container with a stable reading order — much
  better than A — but everything (actions, labels, rotor) is web-flavored, not native.
- **Maintenance: high.** You are now building a chat UI twice: swipe actions, context
  menus, selection, scroll-to-bottom, unread anchors, timestamps all reimplemented in
  HTML/JS. ExyteChat gets discarded. Two UI stacks, two theming systems, JS build tooling
  in an iOS repo.

## C. Native conversion — HTML → AttributedString / TextKit

Convert HTML to `AttributedString` (or NSAttributedString + TextKit 2) and render in
native `Text`/`UITextView` inside the existing bubbles.

- **Memory: best.** Attributed strings are kilobytes; cells recycle normally; no extra
  processes; images become native `AsyncImage`/attachment views with a shared cache.
- **Performance: best.** Synchronous, cheap layout → row heights known up front → **no
  scroll jumps, ever**. Conversion can run off-main at receive time and be cached.
- **Accessibility: best.** Native text = VoiceOver, Dynamic Type, Bold Text, selection,
  and localization for free; the transcript stays one coherent native surface.
- **Maintenance: medium.** The cost is the converter. **Do not use `NSAttributedString(html:)`**
  — it is WebKit-backed, main-thread-only, slow (~50–200 ms/message), and crash-prone.
  Use SwiftSoup (already-common SPM dep) → walk the DOM → build `AttributedString`, or a
  maintained lib (e.g. DTCoreText-class). The real limitation: **fidelity ceiling** — tables,
  arbitrary CSS, and exotic markup don't map to attributed strings.

---

## Rankings (1 = best)

| Dimension | A: per-bubble web view | B: single web view | C: native conversion |
|---|---|---|---|
| Memory | 3 | 2 | **1** |
| Scroll performance | 3 | 2 | **1** |
| Accessibility | 3 | 2 | **1** |
| HTML fidelity | 1 (tied) | 1 (tied) | 3 |
| Maintenance cost | 2 | 3 | **1–2** (converter is bounded; A/B costs are open-ended) |
| **Overall** | **3rd** | **2nd** | **1st** |

## Recommendation: C as default, A as bounded escape hatch

This is the pattern every major messenger converged on (iMessage, WhatsApp, Telegram,
Slack render markup natively; mail clients use web views because email HTML demands it):

1. **Classify each message at receive time.** If its HTML uses only the native-friendly
   subset (paragraphs, inline styles, links, lists, blockquotes, code, images), convert to
   `AttributedString` off-main, cache it, render natively. Expect this to cover ~95%+ of
   real chat traffic.
2. **Complex messages (tables, heavy markup)** render in a per-message `WKWebView` using
   `MessageTemplate.html` + `MessageWebView.swift` from this folder — but as the *exception*,
   so at most a handful are ever live, which neutralizes A's memory and scroll problems.
   Alternatively: show a native preview snippet with a "View formatted" full-screen web view.
3. **Sanitize once, natively, at ingest** (allowlist) regardless of render path.

This keeps ExyteChat and the native transcript feel, caps web view count at "a few",
and gives full HTML fidelity where it's genuinely needed.

**If product requires pixel-perfect HTML in every bubble**, choose **B** (single web view
with DOM windowing) over A — it converts the per-bubble height-bridging problem, the worst
defect of A, into ordinary document layout. A per-bubble web view as the default renderer
is the one configuration we should not ship.
