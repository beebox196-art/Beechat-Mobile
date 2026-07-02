# HTML Message Rendering — Spec Pack

Validation + scaffolding for rendering HTML message content in BeeChat-Mobile (2026-07-02).

| File | What it is |
|---|---|
| `01-risk-analysis.md` | What breaks with WKWebView-per-bubble inside SwiftUI scroll containers: memory, performance, accessibility, theming, security, known SwiftUI/WebKit sharp edges. |
| `MessageTemplate.html` | Complete bubble template: BeeChat styling, dark mode, Dynamic Type, height reporting via ResizeObserver → `bcHeight`, link/image bridging, wide-table handling. |
| `MessageWebView.swift` | `UIViewRepresentable` scaffold pairing with the template: shared process pool, weak message-handler proxy (leak fix), reuse-safe content injection, jetsam recovery, navigation lockdown. |
| `03-test-matrix.md` | 26 HTML edge cases + 6 dynamic scenarios with expected outcomes. |
| `04-architecture-alternatives.md` | Per-bubble web view vs single web view vs native AttributedString conversion — ranked; recommendation is native-first hybrid. |

**TL;DR:** per-bubble WKWebView as the default renderer fails on memory, scroll stability
(async height → transcript jumps), and VoiceOver. Recommended: convert the common HTML
subset to `AttributedString` natively (SwiftSoup walker, *not* `NSAttributedString(html:)`),
and reserve the web view (template + scaffold here) for the rare table-heavy message.
