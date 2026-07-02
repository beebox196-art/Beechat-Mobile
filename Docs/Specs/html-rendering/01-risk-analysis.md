# HTML Message Rendering — Risk Analysis: WKWebView per bubble

**Scope:** each message bubble hosts a `WKWebView` via `UIViewRepresentable`, embedded in the
transcript scroll view. BeeChat-Mobile currently renders the transcript with **ExyteChat**, whose
message list is backed by an inverted `UITableView` — so bubbles live inside *reused table cells
hosted by SwiftUI*. That combination is the worst-case environment for embedded web views and
several risks below are amplified by it.

---

## 1. Memory

| Risk | Detail |
|---|---|
| Per-instance cost | A `WKWebView` is not a label. Each instance carries its own compositing layer tree, scroll view, and a slice of a WebContent process. Realistic cost: **3–15 MB in-process per live web view** (layers, tiles) plus **10–40 MB per document** in the out-of-process WebContent process depending on content (images dominate). 30 visible-ish bubbles ≈ hundreds of MB total footprint. |
| `LazyVStack` never releases | If the transcript were a `ScrollView { LazyVStack }`: lazy stacks **create views on demand but do not destroy them when they scroll offscreen** (documented behavior — "lazy" means deferred creation, not recycling). Scrolling a 500-message history instantiates up to 500 web views that all stay alive. Memory only ever grows. |
| `List` / `UITableView` reuse churn | `List` (iOS 16+: `UICollectionView`-backed) and ExyteChat's `UITableView` **do** recycle cells — which means `makeUIView`/`updateUIView`/`dismantleUIView` fire constantly during scroll. You trade unbounded memory for constant web view teardown/rebuild (see Performance). SwiftUI may also *reuse* the same representable UIView for a different message, so `updateUIView` must fully reset content or you get **stale message content in recycled bubbles** — a classic reuse bug. |
| Jetsam kills WebContent | Under memory pressure iOS terminates WebContent processes *before* your app. Symptom: bubbles silently go **blank/white** mid-session. You must implement `webViewWebContentProcessDidTerminate(_:)` on every web view and reload — otherwise dead bubbles persist until cell reuse. With dozens of web views this fires often on older devices. |
| Process pool | Without a shared `WKProcessPool`, instances may spawn multiple WebContent processes. Always share one pool app-wide. (Modern WebKit consolidates aggressively, but sharing the pool is still the documented way to keep cookies/process behavior coherent.) |

## 2. Performance

| Risk | Detail |
|---|---|
| Async paint → white flash | WKWebView renders **out of process**. Between cell display and first paint there is a visible flash — white in dark mode unless `isOpaque = false` + `backgroundColor = .clear` + CSS `background: transparent` are all set. Even then, content "pops in" a frame or three after the cell appears. Every scroll over recycled cells re-triggers this. |
| Height round-trip → scroll jump | Intrinsic height arrives **asynchronously** (JS `ResizeObserver` → message handler → `@State`). The row is first laid out at a placeholder height, then jumps when the real height lands. In a chat transcript (anchored at the bottom, scrolling *up* through history) every late height change **shifts the scroll position**. This is the single worst UX defect of the per-bubble design and there is no SwiftUI API to invalidate a row height without a state-driven relayout. ExyteChat's inverted table makes the math worse, not better. |
| First-creation cost | The first `WKWebView` ever created spawns the WebContent process: 100–500 ms on device. Subsequent creations are ~10–50 ms *each* — still far over the 8 ms frame budget, so creating web views during scroll guarantees dropped frames. Mitigation is a pre-warmed reuse pool, which you now have to build and own. |
| `sizeThatFits` can't help | iOS 16's `UIViewRepresentable.sizeThatFits(_:uiView:context:)` is synchronous; a web view cannot answer its content height synchronously on first pass. You are structurally stuck with the two-pass placeholder→real-height layout. |
| JS bridge chatter | Every image load, font resolution, or `details` toggle re-fires height messages. Each one is a state write → SwiftUI diff → possible row invalidation. With many live bubbles this becomes a steady stream of main-thread work. |

## 3. Scrolling & gestures

- The web view's internal `UIScrollView` must be disabled (`scrollView.isScrollEnabled = false`) or it eats the transcript's pan gesture.
- Link long-press previews (`allowsLinkPreview`) conflict with bubble context menus — disable and reimplement natively.
- Text selection inside web content fights with cell swipe actions and ExyteChat's gestures; loupe/selection handles behave inconsistently inside recycled cells.
- `dataDetectorTypes` defaults add tap targets you didn't sanction; set to `[]` and handle links yourself.

## 4. Accessibility

- **VoiceOver fragmentation:** each web view is its own accessibility container with web-style navigation inside it. The transcript stops being one coherent swipe order; focus can get trapped inside a bubble or lost entirely when its cell is recycled. Merged native labels ("Alice, 2:14 PM, message…") become impossible without heavy `UIAccessibility` surgery.
- **Dynamic Type:** web content ignores the user's text size unless the CSS uses Apple's system text styles (`font: -apple-system-body`). Even then, a live text-size change may require reloading each document (listen for `UIContentSizeCategory.didChangeNotification`). Native `Text` gets all of this for free.
- **Bold Text / Increase Contrast / Smart Invert:** none propagate into web content automatically. Smart Invert in particular produces garish results on web content unless you opt out per-element.
- **Reduce Motion:** animated GIFs and CSS animations inside bubbles don't respect it unless you wire `prefers-reduced-motion` and the setting actually reaches the web view.

## 5. Theme switching

- `WKWebView` resolves `prefers-color-scheme` from its own trait collection. It follows the app *if* the app follows the system; if BeeChat adds a manual theme toggle you must set `webView.overrideUserInterfaceStyle` on **every live web view** on switch.
- The dark-mode white flash (default white page background before CSS applies) is the most reported cosmetic issue with this architecture. Mitigations: `isOpaque = false`, clear background, `<meta name="color-scheme" content="light dark">`, and never loading a document without the stylesheet inlined.
- Theme switching mid-scroll = every visible web view re-resolves media queries and repaints simultaneously → visible stagger vs. SwiftUI's atomic transition.

## 6. Security (unavoidable once messages are HTML)

- Message HTML is remote, user-authored input rendered in a JS-capable context. **Sanitize natively before injection** (allowlist of tags/attributes; strip `on*` handlers, `javascript:` URLs, `<script>`, `<iframe>`, `<object>`, `<style>`, form elements). Note: injecting via `innerHTML` does not execute `<script>` tags, but **`<img onerror=…>` does execute** — sanitization is mandatory, not defense-in-depth.
- Deny all navigation in `WKNavigationDelegate` except the initial template load; open links natively after scheme validation (`http/https/mailto/tel` only).
- Remote images are a read-receipt/IP-leak vector — consider blocking by default (`WKContentRuleList`) with tap-to-load, as mail clients do.

## 7. Specific known bugs / sharp edges to test against

1. **State write during view update:** posting the JS height into a `@Binding` synchronously from the message handler can land inside a SwiftUI update pass → `AttributeGraph: cycle detected` warnings or `Modifying state during view update` crashes. Always hop through `DispatchQueue.main.async` / `Task { @MainActor … }`.
2. **`WKUserContentController` retain cycle:** `add(_:name:)` retains the handler strongly; a coordinator that owns the web view leaks both. Use a weak proxy handler and/or remove handlers in `dismantleUIView`. Long chat sessions leak one coordinator + web view per message otherwise.
3. **iOS 16+ `List` reuse of representables:** SwiftUI hands your `updateUIView` a web view that previously displayed a *different* message. If you key content injection on "did I already load?" you render stale messages. Key on message identity.
4. **Lazy stack retention:** Apple's own docs for `LazyVStack` note views are created as needed — nothing recycles them. Verified behavior: memory monotonically grows while scrolling history.
5. **`NSAttributedString(html:)` importer is main-thread-only and WebKit-backed** (documented in Apple's docs; it will crash or deadlock off-main). Relevant because it's the tempting "easy" alternative — see architecture doc.
6. **WebContent process termination** (`webViewWebContentProcessDidTerminate`) under jetsam pressure → blank bubbles; reproduce by scrolling a long image-heavy history on a 3–4 GB device.
7. **ScrollView position restoration:** SwiftUI's `ScrollViewReader.scrollTo` + late-arriving heights = anchor drift. There is no supported "keep visual position while row heights change above the viewport" API; chat apps hand-roll this at the UIKit level (which is partly why ExyteChat wraps UITableView).

## Bottom line

Per-bubble WKWebView is **viable only for a bounded subset of messages** (e.g. the rare
rich-HTML message), with a shared process pool, a web view reuse pool, native sanitization,
and jetsam recovery. As the default renderer for every bubble it fails on memory, scroll
stability, and VoiceOver. See `04-architecture-alternatives.md` for the recommended shape.
