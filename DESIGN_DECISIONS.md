# Design Decisions

A running record of non-obvious architectural decisions, failed approaches, and confirmed solutions. Consult this before changing scroll/layout/interactivity behaviour in the preview.

---

## NSTextView for code-file previews (Phase 3)

**Decision**: replaced the WKWebView + HTML path for code files (`.swift`, `.py`, etc.) with a native `NativeCodePreviewController` backed by `NSTextView` / TextKit 1. Markdown prose still uses WKWebView (cmark-gfm output is HTML; native rendering of arbitrary HTML is not feasible). The markdown *source* tab also uses NSTextView.

**Why NSTextView instead of WKWebView for code**:

| Factor | WKWebView | NSTextView |
|---|---|---|
| First visible content | ~242 ms (must finish tokenizing before loading HTML) | **~15 ms** (plain text shown immediately, tokens applied after) |
| Memory | Separate web content process per pool | In-process |
| Scroll | Required JS workarounds for short files and right-edge padding (see sections below) | Native NSScrollView — no quirks |
| Architecture complexity | HTML generation + CSS + JS injection | `NSAttributedString` directly from tokens |

**Progressive rendering**: `NativeCodePreviewController` exposes two calls — `showPlainText(_:theme:)` fires immediately (before tokenization), then `display(tokens:theme:truncationNote:)` swaps in the syntax-highlighted `NSAttributedString` once the `TokenizerEngine` actor returns. The user sees content within ~15 ms regardless of file size; highlighting follows at ~250 ms.

**TextKit 1 stack** (explicit `NSTextStorage` / `NSLayoutManager` / `NSTextContainer`): required for word-wrap control. The default `NSTextView(frame:)` convenience path creates a TextKit 2 coordinator on macOS 12+; its `NSTextContainer` is owned by a different object and `widthTracksTextView` changes do not take effect predictably. Explicit TextKit 1 stack gives deterministic wrap toggle via `containerSize` + `widthTracksTextView` + `autoresizingMask`.

**Word-wrap hanging indent**: `TextKitRenderer` computes `NSParagraphStyle.headIndent` per source line from the leading whitespace width (`font.maximumAdvancement.width` × character count, tab = 4 spaces). This makes wrapped continuation lines align with the first non-space character, matching the visual indent expected from a code editor.

**The WKWebView sections below (horizontal scroll, right-edge padding, CSS percentage heights, `position: fixed`) apply only to the markdown prose tab.** They are no longer relevant to code-file previews.

---

## Horizontal scroll in short code files

**Problem**: When a code file has fewer lines than the viewport height, the horizontal scrollbar appeared just below the last line of code — not at the bottom of the Quick Look window. Hovering in the empty space below the code did not trigger scroll.

**Diagnostic findings** (via `evaluateJavaScript` + `WKNavigationDelegate.webView(_:didFinish:)`):
- JS *does* run in Quick Look's WKWebView (`evaluateJavaScript` works, `error=nil`).
- `window.innerHeight` = WKWebView frame height (e.g. 600px). Viewport ≠ content height.
- `#ql-content.offsetHeight` = ~564px (fills the viewport via `flex: 1`). The CSS layout was already correct.
- The scroll container size was never the issue.

**Root cause**: macOS WKWebView only routes scroll events to a CSS scroll container when the mouse is over an actual DOM element inside it. The `<pre>` element was only as tall as the code lines (e.g. 100px). The 464px of empty background space within `#ql-content` had no element underneath, so WKWebView swallowed those scroll events.

**What did NOT work**:

| Approach | Why it failed |
|---|---|
| `body/html { height: 100% }` + `#ql-content { flex: 1; overflow: auto }` | Layout was already correct; not the cause |
| `html { overflow: auto }` (viewport-level scroll) | Same — elements already at correct heights |
| `#ql-content { position: fixed; inset: 0; overflow: auto }` | `position: fixed` in Quick Look WKWebView resolves to content dimensions, not the NSView frame |
| `pre { min-height: 100% }` | Percentage heights do not resolve inside a CSS scroll container (`overflow: auto`) in WKWebView |
| `#ql-content { display: flex; flex-direction: column }` + `pre { flex: 1 }` | Flex children inside a scroll container (`overflow: auto`) cannot grow to fill it via CSS in WKWebView |
| `evaluateJavaScript` injecting `min-height: Xpx` on `html`/`body` | JS ran and injected correctly, but elements were already the right height — wrong diagnosis |

**What works** (`PreviewViewController.swift`, `webView(_:didFinish:)`):

```javascript
(function(){
    var qc = document.getElementById('ql-content');
    var pre = qc && qc.querySelector('pre');
    if (pre && qc) pre.style.minHeight = qc.offsetHeight + 'px';
})();
```

After the page loads, read `#ql-content.offsetHeight` (the actual rendered pixel height from the JS runtime) and set it as an inline `minHeight` on `<pre>`. Inline styles bypass all CSS percentage/flex resolution ambiguity. The `<pre>` now physically covers the entire scroll container, so every pixel of the viewport is over a real DOM element and WKWebView routes scroll events correctly.

**Do not revert or "clean up" this JS injection.** It looks redundant (the CSS layout is already correct) but it is load-bearing for scroll behaviour in short files.

---

## Right-edge padding on horizontal scroll

**Problem**: When a code line overflows the viewport horizontally, the rightmost character is flush with the window edge at maximum scroll position. The left edge has 20px padding (from `pre { padding-left: 20px }`); the right edge has none.

**Root cause**: CSS padding on the trailing (right) edge of block elements does not extend the scrollable overflow area in WebKit. This is a long-standing WebKit behaviour — the scroll container's extent is determined by the content box of descendants, not their padding boxes on the trailing edge. `body { display: flex }` (set by `ToolbarRenderer.css`) makes this worse by changing how overflow propagates through the layout tree.

**What did NOT work**:

| Approach | Why it failed |
|---|---|
| `pre { padding: 16px 20px }` (original) | Right padding not included in WebKit scroll extent |
| `pre { padding-right: 0 }` + `.line { padding-right: 20px }` | Block-level `padding-right` on `.line` does not extend scroll width in WebKit |
| `html { padding-right: 20px }` | `box-sizing: border-box` (global rule) makes the padding shrink `html`'s content area instead of adding to scroll width |
| `code { display: block; width: max-content; min-width: 100%; padding-right: 20px; box-sizing: content-box }` | `body { display: flex; flex-direction: column }` constrains the flex item (`#ql-content`) cross-axis width; overflow did not propagate to the scroll container as expected |
| `.line::after { content: ''; display: inline-block; width: 20px }` | The inline-block `::after` extended each line's inline width, but the scroll container still did not account for it |

| `pre { margin-right: 20px }` | Child margins should extend scroll overflow per spec; did not work in this WKWebView setup |
| `evaluateJavaScript` in `didFinish`: read `pre.scrollWidth`, set `pre.style.width = scrollWidth + 20 + 'px'` inline | Same pattern that fixed the vertical scroll issue; `pre` became wider but scroll container still didn't expose the extra 20px |

**Not attempted**:
- `pre { border-right: 20px solid transparent }` — borders are part of the border box (unlike padding) and may genuinely extend scroll extent; untried.
- `webView.scrollView.contentInsets` — `WKWebView` on macOS does not expose a `scrollView` property (iOS-only API); native inset control unavailable.

**Decision**: dropped. The left-edge padding is consistent and the right-flush behaviour is a minor cosmetic issue. Revisit if a clean solution emerges.

---

## JavaScript availability in Quick Look WKWebView

`ToolbarRenderer.swift` has a comment "Quick Look's WebView has JavaScript disabled". This is **incorrect** — JS is enabled by default in WKWebView and Quick Look does not disable it. The comment was written to justify the CSS-only toggle approach, not from empirical testing.

`evaluateJavaScript` *does* work. The earlier failed attempts failed due to timing (called before the page finished loading), not because JS was disabled.

**CSS-only toggles** (radio inputs + `:checked` sibling selectors) are still the right approach for user interaction (the Preview/Code pill, word-wrap button) because they are synchronous with user input and need no round-trip. But JS is available for post-load DOM measurement and correction.

---

## Why `position: fixed` does not fill the WKWebView frame

In a normal browser, `position: fixed; inset: 0` fills the viewport (browser window). In Quick Look's WKWebView, the "viewport" for fixed-position elements resolves to the HTML document content area, not the NSView frame. Confirmed by the failed `#ql-content { position: fixed; inset: 0 }` experiment — it did not fill the frame. The `.ql-wrap-btn { position: fixed; top: 6px; right: 6px }` appears visually correct only because the content area starts at the top-left of the NSView, making corner-anchored fixed elements look right.

---

## CSS scroll containers and child percentage heights

In WKWebView (and WebKit generally), children of an element with `overflow: auto` or `overflow: scroll` cannot use percentage heights (`height: 100%`, `min-height: 100%`) to fill the parent. The parent's height is not considered "definite" for percentage resolution purposes once it becomes a scroll container.

This also applies to `flex: 1` on a child of a flex item that has `overflow: auto` — the child does not grow to fill the scroll container.

The only reliable way to fill a scroll container to its rendered height is to read `offsetHeight` via JavaScript at runtime and set an explicit pixel value as an inline style.

---

## L3 disk cache on ad-hoc-signed builds

**Problem**: end-users install via the quarantine-stripped zip from GitHub Releases. The packaging pipeline strips the App Group entitlement (it can't coexist with ad-hoc signing — see CLAUDE.md "Distribution"). With App Group gone, `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil`, and `CacheManager.cacheDir` would be `nil` on every end-user machine.

**What the original implementation did**: gated all disk cache reads/writes on `cacheDir != nil`. On ad-hoc builds this silently turned into a no-op — every cold extension launch ran the full `rebuildAndLoad` path (full `/Applications/<IDE>.app/.../extensions/` walk for theme registry + per-language grammar directory search), then discarded the result. Cold-launch first-render for a 4-line `.md` was 400–1150 ms, dominated by filesystem walks that re-ran from scratch each time the system killed the idle extension host.

**What did NOT work (considered and rejected)**:

| Approach | Why not |
|---|---|
| Keep the App Group entitlement | Ad-hoc signing + `com.apple.security.application-groups` is a hard launch failure; would re-break distribution. See CLAUDE.md "Ad-hoc re-sign step" — this is non-negotiable. |
| Write L3 into the framework bundle's Resources dir | Read-only after code signing; cache writes would fail. |
| Warm the L2 singletons from the host app over XPC at extension launch | NSExtensionContext does not provide a bidirectional XPC channel on Quick Look extensions. Would require building a LaunchAgent; orders of magnitude more complexity for the same outcome. |

**What works**: `cacheDir` falls back to `FileManager.urls(for: .cachesDirectory, in: .userDomainMask).first` inside the calling process's own sandbox container (`~/Library/Containers/<bundle-id>/Data/Library/Caches/quicklookcode/`). Every sandboxed process can read/write its own caches dir without any entitlement. The extension now persists L3 across cold launches on end-users' machines, same as the dev build.

**Trade-off**: host app and extension no longer share one cache (different containers). Host's Refresh button rewrites only the host's L3; the extension's Darwin-notification handler therefore force-rebuilds its own L3 rather than `loadFromDisk`-ing stale data. Selected at runtime via `cacheIsShared`. In practice end-users rarely open the host app; `settings.json` mtime bumps still catch real theme changes automatically.

**Do not revert to "bail out when App Group is unavailable"** — the speed cost on end-user machines is severe and compounds with every system-idle extension teardown.

---

## Deferred markdown Code-tab tokenization

**Problem**: `MarkdownRenderer.render` originally called `generateSourceHTML` inline as step 6 of every render. `generateSourceHTML` loads the markdown grammar, loads sibling grammars for every fenced language in the doc, serializes the theme to `IRawTheme` JSON, warms the `TokenizerEngine` actor (62 KB JS eval in JSContext, ~60–150 ms cold), calls `initGrammar` (parse grammar + compile every regex via `onig_new`, ~30–70 ms), then tokenizes the whole markdown source. For a 4-line MD file with no code fences, that's 100–220 ms of wasted work to populate a Code-tab the user never clicks.

**Why the Code tab can't just be thrown away**: users toggling Preview/Code is part of the advertised UX for the renderer; its absence is visible. The work has to happen eventually, just not before first paint.

**What did NOT work**:

| Approach | Why not |
|---|---|
| Return a plain-text `<pre>` for the Code tab, skip tokenization entirely | Code tab becomes non-highlighted raw markdown; breaks the "shows your editor colors" promise. |
| Run `generateSourceHTML` inside `async let` in parallel with `highlightCodeBlocks` | Both funnel through the same `TokenizerEngine` actor; the actor serializes them. Wall-clock is unchanged. |
| Pre-generate the Code-tab HTML on the host app's main process so the extension can load a pre-warmed L3 entry | Source HTML is per-file, not per-IDE; can't pre-compute. |

**What works**: split the render into two phases.

1. **Fast phase** — `MarkdownRenderer.render` returns `RenderResult { html, markdown }`. `html` is the fully-rendered prose (cmark-gfm + fenced-block highlights); `markdown` is the raw source string. `WKWebView.loadHTMLString` fires immediately with the prose. The source tab shows a plain-text `NSAttributedString` placeholder via `MarkdownPreviewController.showSourcePlaceholder(_:theme:)` — no tokenizer work yet.
2. **Deferred phase** — `PreviewViewController.renderMarkdown` calls `MarkdownRenderer.tokenizeSource(markdown:theme:ide:)` on a background task, then calls `MarkdownPreviewController.showSource(tokens:theme:)` which replaces the NSTextView's `textStorage` with the highlighted `NSAttributedString`. The 100–220 ms of tokenizer init + `initGrammar` overlaps with WKWebView rendering the prose.

**Phase 3 change**: the source tab is now a native `NSTextView` inside `MarkdownPreviewController`, not a `#ql-source-slot` div injected into the WKWebView via `callAsyncJavaScript`. The JS injection approach (with `ql-source-slot`, `webView(_:didFinish:)` callback, and the argument-bridge injection) has been removed. The two-phase split is preserved but the deferred result now writes to `NSTextStorage` instead of the DOM.

**Why native NSTextView for the source tab**: consistent with the code-file path; eliminates the HTML generation step (`renderSourceHTML`) for the source tab; avoids the JS injection surface; and the wrap toggle is handled natively by `NSParagraphStyle` / `NSTextContainer` rather than a CSS checkbox hack.

**Why the deferred call is in `renderMarkdown` not `webView(_:didFinish:)`**: with a native NSTextView there is no page-load callback to hook. The deferred task runs as a plain `await` after `installChild` returns — simpler and still non-blocking for the prose display.

---

## Task cancellation in the render pipeline

**Problem**: rapid space-bar presses on successive files created overlapping `preparePreviewOfFile` calls. Each one hit the `TokenizerEngine` actor; dismissed previews kept running to completion because `async`/`await` does not auto-cancel. A burst of 3–4 rapid presses would stack tokenize requests on the actor's mailbox, each blocking the next, and Quick Look's own response deadline would eventually surface "Failed to load preview" for requests that couldn't get through in time.

**What works**: `Task.isCancelled` checks at each await-boundary in `preparePreviewOfFile` / `renderCode` / `renderMarkdown`. When QL cancels a preview, the in-flight task bails before doing the expensive work, leaving the actor free for the replacement preview.

**Why `if Task.isCancelled { return }` not `try Task.checkCancellation()`**: throwing from `preparePreviewOfFile` makes Quick Look show its own "Failed to load preview" banner — user sees an error instead of a blank-then-swap. Silent early-return avoids the error UI; QL drops the empty result on the floor because it's already moved on.

**Do not drop these checks.** They are the difference between "rapid space-press works" and "rapid space-press degrades into stuck failures."
