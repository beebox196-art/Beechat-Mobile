# HTML Message Rendering — Test Matrix

26 edge cases for the bubble renderer (MessageTemplate.html + sanitizer + MessageWebView).
"Sanitizer" = the native allowlist pass that runs before `beechat.setContent()`.

Run each case in **light and dark mode**, at **default and XXL Dynamic Type**, and verify:
(a) rendering matches Expected, (b) exactly one final `bcHeight` matching visual height,
(c) no horizontal bubble overflow, (d) no console/JS errors.

| # | Case | Input sketch | Expected outcome |
|---|------|--------------|------------------|
| 1 | Plain paragraph | `<p>Hello bee</p>` | Body text style, no margins collapsing into padding (first/last child margins stripped). |
| 2 | Multiple paragraphs + `<br>` | 3 `<p>`, stray `<br><br>` | 0.6em paragraph gaps; `<br>` honored; height = sum, no trailing gap. |
| 3 | Inline formatting | `<b><i><s><u><code>` mix | All render; inline `code` gets pill background; baseline unchanged. |
| 4 | Headings h1–h6 | One of each | Capped scale (h1 = 1.35em) — headings don't shout in a bubble. |
| 5 | Nested lists 4 deep | `ul>ol>ul>ol`, long items | Indentation preserved, no overflow; wrapped lines align after the marker. |
| 6 | Long unbroken token | 300-char URL / `AAAA…` | Breaks mid-token (`word-break`), bubble width unchanged, no horizontal scroll. |
| 7 | Code block, long lines | `<pre>` with 200-col lines | Horizontal scroll *inside* the pre block; bubble width fixed; monospace. |
| 8 | Code block, huge | 500-line `<pre>` | Renders fully; height reported correctly (multi-thousand px); scroll smooth. |
| 9 | Nested blockquote | `blockquote>blockquote` | Stacked gold bars, dimmed text, no runaway indentation. |
| 10 | Wide table | 10 columns, long cells | JS wraps in `.bc-scroll-x`; table scrolls horizontally; bubble width fixed. |
| 11 | Table with colspan/rowspan | Irregular grid | Renders without layout explosion; borders coherent. |
| 12 | Image with width/height attrs | `<img width=2000 height=1000>` | Scales to bubble width, aspect kept (`height:auto`); height reported after load, once. |
| 13 | Image without dimensions | Bare `<img src>` | One reflow on load; `bcHeight` re-fires; row grows without scroll jump *below* viewport (known jump risk above — see risk doc §2). |
| 14 | Broken image src | 404 / bad host | `.bc-broken` placeholder block + alt text; no infinite spinner; height settles. |
| 15 | Data-URI image (1 MB+) | Base64 png | Renders; watch WebContent memory; sanitizer may cap data-URI size (policy decision). |
| 16 | Animated GIF | Looping GIF | Animates; with Reduce Motion on, CSS animations stop (GIFs still animate — document as known limitation or block). |
| 17 | Emoji-only message | `🐝🐝🐝` | Renders at body size (native bubbles may special-case jumbo emoji — decide parity policy). |
| 18 | RTL text | Arabic paragraph | `dir=auto` right-aligns; punctuation correct. |
| 19 | Mixed RTL/LTR | Arabic + English + numbers | Bidi runs correct; no mirrored layout of the whole bubble. |
| 20 | Malformed HTML | Unclosed `<b>`, stray `</div>`, `<p><table>` | Parser recovers (HTML5 error recovery); formatting may bleed to end of message but never crashes or leaks outside the bubble. Sanitizer should re-serialize balanced markup. |
| 21 | Script injection | `<script>alert(1)</script>` | Stripped by sanitizer. (Even unsanitized, `innerHTML` won't execute it — but never rely on that.) |
| 22 | Event-handler injection | `<img src=x onerror=alert(1)>` | **Sanitizer must strip `on*` attributes** — this *would* execute via innerHTML. The single most important security case. |
| 23 | `javascript:` / `data:` links | `<a href="javascript:…">` | Sanitizer drops/neuters href; Swift side also refuses non http/https/mailto/tel. Tap does nothing. |
| 24 | Embedded frames/media | `<iframe>`, `<object>`, `<embed>`, `<video autoplay>` | Removed by allowlist; no network requests fired (verify with proxy). |
| 25 | Style abuse | `<style>` tag, `style="position:fixed;top:0"` | `<style>` stripped; inline style attribute stripped or allowlisted — content cannot escape flow or overlay other bubbles. |
| 26 | Very long message | 10,000 words | Renders; height in tens of thousands px reported correctly; scroll through it stays >55fps; consider native "Show more" truncation above ~4,000 px (product decision). |

## Additional dynamic scenarios (not single inputs)

- **Cell reuse:** scroll 200-message history fast, both directions — no stale content in recycled bubbles, no white flashes in dark mode, memory plateaus rather than climbs.
- **`details`/`summary` toggle** (if allowlisted): expanding fires new `bcHeight`; the row animates without the transcript jumping.
- **Theme switch mid-scroll:** all visible bubbles flip together; no white flash frame.
- **Dynamic Type change while chat open:** text resizes (or documents reload) and heights re-report.
- **Jetsam simulation:** `webView.setValue` memory pressure / Simulate Memory Warning → blank bubbles recover via `webViewWebContentProcessDidTerminate` reload.
- **VoiceOver pass:** swipe through a 10-message transcript containing cases 1, 7, 10, 12 — every message reachable, order stable, no focus traps.
