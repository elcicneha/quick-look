# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naming Convention

**Internal code pattern**: `QuickLookCode` / `quicklookcode` — used in bundle IDs, app group identifiers, UTType identifiers, Swift module names, Xcode target names, scheme name, the `.xcodeproj` filename, source file names, source file folders, and the embedded extension/framework bundle filenames (`QuickLookCodeExtension.appex`, `QuickLookCodeShared.framework`). Never change these; they are plumbing, referenced by bundle ID and `@rpath`.

**User-facing display name**: `Peekaboo` — used in `CFBundleDisplayName`, `CFBundleName`, `PRODUCT_NAME` for the host-app target (all set in `project.pbxproj`), and the README. The host-app target's `PRODUCT_NAME = Peekaboo` means every build (debug or release) produces `Peekaboo.app` directly — no post-build rename. The extension and framework targets keep `PRODUCT_NAME = $(TARGET_NAME)` so their inner bundle filenames remain plumbing.

macOS uses both Info.plist keys on different surfaces: `CFBundleDisplayName` wins in Finder/Spotlight, `CFBundleName` wins in the menu bar and some system dialogs. If the display name changes again, update `INFOPLIST_KEY_CFBundleDisplayName` and `INFOPLIST_KEY_CFBundleName` (all four host-app + extension configs), the host app's `PRODUCT_NAME` (Debug + Release only), and the README title — nothing else.

## Build & Test Commands

**Dev iteration loop — run this exact sequence every time you want to test a change:**

```bash
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  xcodebuild -project QuickLookCode/QuickLookCode.xcodeproj \
             -scheme QuickLookCode \
             -configuration Debug build

cp -R ~/Library/Developer/Xcode/DerivedData/QuickLookCode-*/Build/Products/Debug/Peekaboo.app /Applications/

killall Peekaboo 2>/dev/null; qlmanage -r && killall -HUP Finder
```

Why each step matters:
- **`DEVELOPER_DIR=...`** — forces `xcodebuild` to use full Xcode, not Command Line Tools. Without this, the build fails on a fresh shell with "xcodebuild requires Xcode". Always include it.
- **`cp -R .../Peekaboo.app /Applications/`** — the extension *must* live under `/Applications/` (not DerivedData) for LaunchServices to register the Quick Look plugin. Running from DerivedData silently fails to hook into Finder.
- **`killall Peekaboo; qlmanage -r; killall -HUP Finder`** — kills a running host app so it picks up the new binary, asks Quick Look to re-scan plugins, forces Finder to reload so the next Space-press uses the new extension. Omit any one and you'll be debugging yesterday's build.

**Other commands:**

```bash
# Test the extension on a file
qlmanage -p path/to/file.swift

# Check the extension is registered
pluginkit -m -v | grep quicklook

# Check extension logs (our code NSLogs under the [QuickLookCode] prefix)
log stream --predicate 'eventMessage CONTAINS "[QuickLookCode]"' --level default

# Rebuild the JS tokenizer bundle (after editing tokenizer/src/tokenizer-jsc.js)
cd tokenizer && pnpm run build
# Output goes directly to QuickLookCode/QuickLookCodeShared/Resources/tokenizer-jsc.js

# Produce a distributable zip (Release build) for non-Developer-ID distribution
./scripts/package.sh                    # uses MARKETING_VERSION from project.pbxproj
./scripts/package.sh 1.2.0              # or override the version in the zip filename
# Output: dist/Peekaboo-v<VERSION>.zip (contains Peekaboo.app)
```

## Distribution

There is **no paid Apple Developer account**. The app is signed by Xcode with the Personal Team (`DEVELOPMENT_TEAM = 97S4Q992W3`, automatic signing) and is **not notarized**. Do not try to add notarization steps — there is no Developer ID Application certificate available.

`scripts/package.sh` uses `xcodebuild archive` (not `build`) because `archive` has a stricter build graph that respects the cross-target Swift module dependency. Do not change it back to `build`.

**Ad-hoc re-sign step (critical)**: after `archive`, the script strips `embedded.provisionprofile` from the app and extension, then re-signs every bundle with `codesign -s -` (ad-hoc). Reason: the Personal Team embeds a development provisioning profile whose `ProvisionedDevices` list contains only the developer's Mac. On any other Mac the kernel refuses to launch with "QuickLookCode cannot be opened because of a problem". Ad-hoc signing has no team and no device list, so the binary runs anywhere.

The re-sign also strips the team-scoped entitlements: `com.apple.security.application-groups`, `com.apple.developer.team-identifier`, `com.apple.application-identifier`. These cannot be used with an ad-hoc signature — a sandboxed app with an `application-groups` entitlement but no matching team will fail to launch. Practical consequence: `CacheManager`'s L3 disk cache (shared group container) is unreachable on end-users' machines; L2 in-memory and L1 per-render layers still function. Do not try to keep the App Group — it will re-break distribution.

End-user install requires stripping the quarantine xattr — see the four-line Terminal block in `README.md`. This is the full install story; do not add installer scripts or DMG packaging without a specific reason (previously considered and rejected — DMG adds signing complications with zero UX benefit when there's no notarization).

To bump a release: edit `MARKETING_VERSION` in `project.pbxproj` → run `scripts/package.sh` → upload the resulting zip.

## Architecture

Three Xcode targets, all in `QuickLookCode/QuickLookCode.xcodeproj`:

- **QuickLookCode** — host macOS app (required by macOS to ship an extension). Minimal SwiftUI UI showing IDE detection status and active theme.
- **QuickLookCodeExtension** — the actual Quick Look preview extension (view-based `QLPreviewingController`). Entry point: `PreviewViewController.swift` — hosts a sandboxed `WKWebView` and calls `webView.loadHTMLString(...)` with the rendered HTML. Routes files through the full render pipeline; falls back to plain text on any failure.
- **QuickLookCodeShared** — framework linked into both targets above. Contains all IDE integration logic.

**Target dependencies**: `QuickLookCodeExtension` has an explicit `PBXTargetDependency` on `QuickLookCodeShared` even though it does not link the framework (the host app embeds it, resolved at runtime via `@rpath`). The dependency exists purely to force build ordering — without it, `xcodebuild archive` races and the extension's Swift compile can't find the shared module. Xcode GUI masks this via implicit inference, but CLI builds break. Do not remove this dependency.

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

**Sandbox**: Both app and extension run sandboxed. Read access to VS Code / Antigravity install locations and user config dirs is granted via a single entitlement exception list — `com.apple.security.temporary-exception.files.absolute-path.read-only` — containing `/Applications/` and `/Users/`.

**Why `/Users/` and not `home-relative-path` exceptions**: Apple's `com.apple.security.temporary-exception.files.home-relative-path.read-only` silently resolves paths against the *sandbox container home* (`~/Library/Containers/<bundle-id>/Data/`), not the user's real home — so `Library/Application Support/Code/` in that key grants access to a path that doesn't exist and the kernel denies the real read. The absolute-path `/Users/` prefix is resolved literally and covers every user's real home subtree. Do not switch back to home-relative paths.

**Why `getpwuid(getuid())->pw_dir` in `IDELocator.realHomeDirectory()`**: inside a sandboxed process, all Foundation home APIs (`FileManager.default.homeDirectoryForCurrentUser`, `NSHomeDirectory()`, `NSHomeDirectoryForUser(NSUserName())`) return the container path. The direct `getpwuid` syscall reads from Open Directory and bypasses the sandbox remap, returning `/Users/<username>/`. Do not replace this with a Foundation API — paths constructed from Foundation home will read from the sandbox container (which is empty) even though the entitlement would allow access to the real location.

Any new file paths the extension needs to read must be added to both `QuickLookCode.entitlements` and `QuickLookCodeExtension.entitlements`, and constructed in code from `realHomeDirectory()` rather than `FileManager.default.homeDirectoryForCurrentUser`.

**App Group**: `group.com.nehagupta.quicklookcode` — used for shared UserDefaults **and the disk cache** between app and extension. The cache lives at `<AppGroupContainer>/Library/Caches/quicklookcode/` and contains `manifest.json`, `ide.json`, `theme.json`, and `grammar-index.json`.

### IDE Abstraction

The project supports both **VS Code** and **Antigravity** (a VS Code fork). `IDEInfo` holds all paths for a given IDE. `IDELocator.preferred` returns the user's picker choice (stored in shared App Group `UserDefaults` under the `selectedIDE` key — visible to both host app and extension) when that IDE is installed; otherwise the first IDE found in catalog order. The host app's `ContentView` shows the picker only when ≥2 IDEs are installed. All downstream code (GrammarLoader, ThemeLoader) takes an `IDEInfo` — never hardcode VS Code paths.

**Theme dark/light classification** (`ThemeLoader.classifyIsDark`): prefers the theme JSON's own `type` field if present, otherwise falls back to the `uiTheme` field from the extension's `package.json` contribution (`"vs"`/`"hc-light"` = light, everything else = dark). VS Code's built-in themes (e.g. `light_modern.json`) omit `type` entirely and rely on `uiTheme` — a naive `type ?? "dark"` default would mis-classify every one of them as dark.

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

**CacheManager** (`Cache/CacheManager.swift`) orchestrates bootstrap and refresh. Call `CacheManager.bootstrap()` before every render — the hot path is a single atomic boolean check (`_loadedCacheVersion != nil && !_needsReload`), no disk I/O. The host app's **Refresh** button calls `CacheManager.refresh()` to force a full rebuild — use this after changing the IDE theme.

**Cross-process invalidation via Darwin notifications**: the host app and Quick Look extension are separate processes with separate L2 singletons. `CacheManager.refresh()` rebuilds L3 locally, then posts a Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`). Every process that called `bootstrap()` installs a `CFNotificationCenterAddObserver` on first call; the handler flips `_needsReload` so the next `bootstrap()` swaps L2 from the fresh L3 with one `loadFromDisk()`, then returns to the fast path. No polling, microsecond latency.

**Notification name must be app-group-prefixed**: sandboxed macOS processes silently drop Darwin notifications whose name is not prefixed with an app-group identifier the process belongs to. The constant `CacheManager.cacheUpdatedNotification` is built as `"\(DiskCacheSchema.appGroup).cache-refreshed"` — do not rename to something outside the `group.com.nehagupta.quicklookcode.*` namespace or cross-process invalidation will break silently.

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

`HTMLRenderer` composes the final document and uses `ToolbarRenderer` for the in-preview chrome.

### In-preview chrome (ToolbarRenderer)

`ToolbarRenderer` owns the two UI affordances that live inside the WKWebView:

- **Preview/Code pill** — markdown only. Sits in `#ql-toolbar` (a flex bar at the top of the page, emitted only by `MarkdownRenderer`). Drives the view toggle via hidden radio inputs + `:checked` sibling selectors.
- **Wrap overlay** — a floating `<label for="ql-wrap">` button, fed by a hidden checkbox. It uses `position: absolute; top: 6px; right: 6px` and is placed *inside* the content container (`#ql-content` for code files, `#ql-view-code` for markdown). One rule, two contexts — do not re-introduce per-context `top` overrides. In markdown, nesting inside `#ql-view-code` means the label inherits that subtree's `display: none` during preview mode, so it's only visible in code view without any extra CSS.

Because the label is no longer a DOM sibling of `#ql-wrap` (the checkbox stays at body level so `#ql-wrap:checked ~ #ql-content .line` still applies wrap styling), the checked-state rule uses `body:has(#ql-wrap:checked) .ql-wrap-btn { … }`. `:has()` is required — don't revert to `~`.

The wrap overlay's colors come from CSS custom properties (`--wrap-bg`, `--wrap-fg`, `--wrap-bg-checked`, `--wrap-shadow`, etc.) set per-render by `ToolbarRenderer.wrapColorVariables(for: theme)`, which both renderers inject into a `:root { … }` rule. The theme's `isDark` flag **only** picks between two fixed palettes — the palette values are *not* mixed from `theme.background` / `theme.foreground`. Do not re-introduce color mixing; that was tried and rejected.

The toolbar is hidden / scaled down in the Finder column-view preview and shown at full size in the dedicated Quick Look window.

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
