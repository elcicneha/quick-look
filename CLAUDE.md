# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naming Convention

**Internal code pattern**: `QuickLookCode` / `quicklookcode` — used everywhere in code, bundle IDs, app group identifiers, UTType identifiers, Swift module names, file names. Never change these; they are plumbing, not branding.

**User-facing display name**: `Peekaboo` — used only in `CFBundleDisplayName` (already set in `project.pbxproj`) and the README. This is a marketing name and may change independently of the code.

Do not conflate the two. If the display name changes again, only update `INFOPLIST_KEY_CFBundleDisplayName` in `project.pbxproj` and the README title — nothing else.

## Build & Test Commands

```bash
# Build from command line
xcodebuild -project QuickLookCode/QuickLookCode.xcodeproj -scheme QuickLookCode -configuration Debug build

# Install to /Applications (required for proper Quick Look / LS registration)
cp -R ~/Library/Developer/Xcode/DerivedData/QuickLookCode-*/Build/Products/Debug/QuickLookCode.app /Applications/

# Test the extension on a file
qlmanage -p path/to/file.swift

# Reload the extension after changes (run both)
qlmanage -r
killall -HUP Finder

# Check the extension is registered
pluginkit -m -v | grep quicklook

# Check extension logs
log stream --predicate 'subsystem contains "quicklookcode"' --level debug

# Rebuild the JS tokenizer bundle (after editing tokenizer/src/tokenizer-jsc.js)
cd tokenizer && pnpm run build
# Output goes directly to QuickLookCode/QuickLookCodeShared/Resources/tokenizer-jsc.js
```

## Architecture

Three Xcode targets, all in `QuickLookCode/QuickLookCode.xcodeproj`:

- **QuickLookCode** — host macOS app (required by macOS to ship an extension). Minimal SwiftUI UI showing IDE detection status and active theme.
- **QuickLookCodeExtension** — the actual Quick Look preview extension (view-based `QLPreviewingController`). Entry point: `PreviewViewController.swift` — hosts a sandboxed `WKWebView` and calls `webView.loadHTMLString(...)` with the rendered HTML. Routes files through the full render pipeline; falls back to plain text on any failure.
- **QuickLookCodeShared** — framework linked into both targets above. Contains all IDE integration logic.

### Renderer Routing

```
file extension
    ├── "md" / "markdown"  →  MarkdownRenderer  →  cmark-gfm + per-block SourceCodeRenderer
    └── everything else    →  SourceCodeRenderer →  JSC vscode-textmate pipeline
                                                     both → HTML string → WKWebView.loadHTMLString
```

### Data Flow

```
IDELocator.preferred → IDEInfo (app URL, settings URL, extension paths)
    ├── GrammarLoader(ide) → grammarData(for: "python") → Data (TextMate JSON)
    └── ThemeLoader.loadActiveTheme(from: ide) → ThemeData
            └── serializeTheme(ThemeData) → IRawTheme JSON → vscode-textmate registry.setTheme
```

### Key Constraints

**Sandbox**: Both app and extension run sandboxed. Read access is granted via entitlement exceptions to:
- `/Applications/` (VS Code, Antigravity)
- `~/Applications/`
- `~/Library/Application Support/Code/` and `~/Library/Application Support/Antigravity/`
- `~/.vscode/` and `~/.antigravity/`

Any new file paths the extension needs to read must be added to both `QuickLookCode.entitlements` and `QuickLookCodeExtension.entitlements`.

**App Group**: `group.com.nehagupta.quicklookcode` — used for shared UserDefaults **and the disk cache** between app and extension. The cache lives at `<AppGroupContainer>/Library/Caches/quicklookcode/` and contains `manifest.json`, `ide.json`, `theme.json`, and `grammar-index.json`.

### IDE Abstraction

The project supports both **VS Code** and **Antigravity** (a VS Code fork). `IDEInfo` holds all paths for a given IDE. `IDELocator.preferred` returns whichever is found first. All downstream code (GrammarLoader, ThemeLoader) takes an `IDEInfo` — never hardcode VS Code paths.

### Token Scope Matching

Scope→color resolution is handled entirely by `vscode-textmate` internally via `tokenizeLine2`. The library's registry resolves descendant selectors, parent selectors, exclusion selectors, and specificity scoring identically to VS Code. `TokenMapper.swift` has been deleted — there is no Swift-side scope matching.

### Caching Architecture

Three layers eliminate redundant work between previews:

```
L3 — App Group disk cache (survives process death)
     CacheManager.bootstrap() reads or rebuilds on first call.
     Invalidated by: IDE app mtime change, settings.json mtime change, schema bump, Refresh button.

L2 — Process-lifetime in-memory singletons
     IDELocator._cached, ThemeLoader._cachedTheme / _cachedSerializedTheme,
     GrammarLoader static URL/data/sibling caches.
     Survive across space-bar presses while macOS keeps the extension host warm.

L1 — Per-render work (always runs)
     File read, tokenizeLine2, HTML string build, WKWebView paint.
```

**CacheManager** (`Cache/CacheManager.swift`) orchestrates bootstrap and refresh. Call `CacheManager.bootstrap()` before the first render (idempotent). The host app's **Refresh** button calls `CacheManager.refresh()` to force a full rebuild — use this after changing the IDE theme.

**TokenizerEngine** (`Cache/TokenizerEngine.swift`) is a Swift `actor` that owns one `JSContext` for the process lifetime. `tokenizer-jsc.js` is evaluated once; oniguruma is bridged once. `initGrammar` is called only when language or theme changes between calls — browsing a folder of `.py` files hits `doTokenize` directly. Markdown code blocks all share the same warm context.

### Tokenization Pipeline

```
CacheManager.bootstrap()
    → IDELocator._cached / ThemeLoader._cachedTheme (L2 hit — no disk I/O)
    → GrammarLoader.grammarData(for:) (L2 static cache hit after first use)

SourceCodeRenderer.render(fileURL:grammarData:theme:)
    → tokenize(code:language:grammarData:theme:)
        → TokenizerEngine.shared.tokenize(...)  ← shared JSContext (actor)
            → initGrammar (only on language/theme change)
            → doTokenize(code) ← tokenizeLine2 → [{text, color, fontStyle}]
    → HTMLRenderer.render(lines:theme:)         ← inlined-CSS HTML document
```

The JS bundle (`tokenizer-jsc.js`) is built via esbuild from `tokenizer/src/tokenizer-jsc.js`. The build output goes directly to `QuickLookCode/QuickLookCodeShared/Resources/tokenizer-jsc.js` — no manual copy needed. Run `pnpm run build` inside `tokenizer/` after changing JS source.

`HTMLRenderer` composes the final document and delegates the file-info header/toolbar (filename, icon, language badge) to `ToolbarRenderer`. The toolbar is hidden / scaled down in the Finder column-view preview and shown at full size in the dedicated Quick Look window.

**Xcode 16+ `fileSystemSynchronizedGroups`**: The project uses this feature, so adding or removing source files on disk is sufficient — no `project.pbxproj` edits are needed.

**Vendored C libraries**: Two C libraries are vendored under `QuickLookCodeShared/Vendor/`:

- **`Oniguruma/`** — 48 `.c` files. The `COniguruma` module (`module.modulemap`) is imported by `OnigScanner.swift`. Provides native regex for vscode-textmate.
- **`cmark-gfm/`** — ~60 `.c` files (cmark core + GFM extensions). The `CCmarkGFM` module is imported by `MarkdownRenderer.swift`. Four CMake-generated headers are hand-crafted for macOS (`config.h`, `cmark-gfm_version.h`, `cmark-gfm_export.h`, `cmark-gfm-extensions_export.h`). Two data-only `.inc` files from upstream are renamed to `.h` (`case_fold_switch_data.h`, `entities_data.h`) so `PBXFileSystemSynchronizedRootGroup` treats them as headers rather than attempting to compile them.

Both vendor directories are added to `SWIFT_INCLUDE_PATHS` and `USER_HEADER_SEARCH_PATHS` in `project.pbxproj`.

### Quick Look Reply

The extension uses **view-based preview** (`QLIsDataBasedPreview: false` in `Info.plist`). `PreviewViewController` loads the rendered HTML into a `WKWebView`. View-based was chosen to enable keyboard shortcut support and future interactive affordances (the earlier data-based path using `QLPreviewReply(.html)` has been removed).

**WKWebView entitlement**: the sandboxed `WKWebView` requires `com.apple.security.network.client` in both entitlement files even when only loading local HTML strings — without it the web content process crashes silently and the preview renders blank.

## Current Status

- **Phase 0** (Scaffolding) ✅ — extension loads, `qlmanage` works
- **Phase 1** (IDE Integration) ✅ — IDELocator, GrammarLoader, ThemeLoader complete; ContentView shows live theme info
- **Phase 2** (Tokenization + HTML output) ✅ — JSC-based vscode-textmate pipeline, HTMLRenderer, FileTypeRegistry
- **Phase 2.5** (Native library migration) ✅ — `tokenizeLine2` for internal color resolution; native oniguruma C library replacing JS regex shim; `TokenMapper` deleted
- **Phase 3** (Markdown renderer with cmark-gfm) ✅ — `MarkdownRenderer.swift`, `markdown-styles.css`, cmark-gfm vendored; prose follows system light/dark, code blocks use VS Code theme
- **Phase 4** (`.ts` TypeScript preview) — **not achievable** via QL extension API; see PLAN.md
- **Phase 4.5** (Performance — multi-layer caching) ✅ — `CacheManager`, `TokenizerEngine` actor, `SharedWebProcessPool`, grammar index, pre-serialized theme JSON, host app Refresh button
- **Phase 5** (FSEventStream theme watching, font sync, line numbers) — planned

See `PLAN.md` for full phase specifications.
