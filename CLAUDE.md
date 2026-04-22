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

The re-sign also strips the team-scoped entitlements: `com.apple.security.application-groups`, `com.apple.developer.team-identifier`, `com.apple.application-identifier`. These cannot be used with an ad-hoc signature — a sandboxed app with an `application-groups` entitlement but no matching team will fail to launch. Practical consequence: the App Group *container* is unreachable on end-users' machines, so `CacheManager` falls back to per-process sandbox caches (see **Caching Architecture** below). Do not try to keep the App Group — it will re-break distribution.

End-user install requires stripping the quarantine xattr — see the four-line Terminal block in `README.md`. This is the full install story; do not add installer scripts or DMG packaging without a specific reason (previously considered and rejected — DMG adds signing complications with zero UX benefit when there's no notarization).

To bump a release: see the **Release Cadence** section below.

## Release Cadence

After completing a non-trivial batch of changes (a feature, a set of related fixes, a docs pass), **proactively ask the user whether it's time to cut a release** — but don't ask after every individual commit. Wait for natural checkpoints where a user would notice something new, improved, or fixed.

Current released version: see the latest tag on GitHub (`git tag --sort=-v:refname | head -1`). First release was `v1.0.0`.

**Version bump (SemVer — `MAJOR.MINOR.PATCH`):**
- **PATCH** (e.g. 1.0.0 → 1.0.1) — bug fixes only, no user-visible new capability.
- **MINOR** (e.g. 1.0.0 → 1.1.0) — new feature or user-visible improvement, backwards-compatible.
- **MAJOR** (e.g. 1.0.0 → 2.0.0) — breaking change to preview pipeline semantics, install procedure, or user-visible settings. Rare.

**When proposing a release, name the recommended version + one-line justification** (e.g. *"IDE picker added — v1.0.0 → v1.1.0"*). The user decides; don't assume.

**Release steps (once the user approves):**

1. Bump `MARKETING_VERSION` in `QuickLookCode/QuickLookCode.xcodeproj/project.pbxproj` — six occurrences (3 targets × Debug/Release). Use Edit with `replace_all`.
2. `git add` the pbxproj, commit as `chore: release vX.Y.Z`.
3. `git tag vX.Y.Z && git push origin main && git push origin vX.Y.Z`.
4. `./scripts/package.sh` → produces `dist/Peekaboo-vX.Y.Z.zip`.
5. Draft release notes in `RELEASE_NOTES_vX.Y.Z.md`. Sections: one-sentence pitch, install block (the four-line quarantine-strip sequence from README.md), highlights (3–6 bullets of what's new since last release), known limitations if any. **Skip the SHA-256 section** — it's ceremony for this setup (see git history of v1.0.0 for the reasoning). Add it back only if publishing to a package manager (Homebrew, etc.).
6. `gh release create vX.Y.Z dist/Peekaboo-vX.Y.Z.zip --draft --title "vX.Y.Z — <short summary>" --notes-file RELEASE_NOTES_vX.Y.Z.md`.
7. User reviews the draft in the browser and publishes manually. **Always pass `--draft`**; never publish on the user's behalf.

The `RELEASE_NOTES_vX.Y.Z.md` file is throwaway — it exists only to feed `gh release create`. Delete it or `.gitignore` the `RELEASE_NOTES_v*.md` pattern after publishing.

## Architecture

Three Xcode targets, all in `QuickLookCode/QuickLookCode.xcodeproj`:

- **QuickLookCode** — host macOS app (required by macOS to ship an extension). Minimal SwiftUI UI showing IDE detection status and active theme.
- **QuickLookCodeExtension** — the actual Quick Look preview extension (view-based `QLPreviewingController`). Entry point: `PreviewViewController.swift` — a thin router that installs either `NativeCodePreviewController` (NSTextView, for source files) or `MarkdownPreviewController` (WKWebView prose + NSTextView source tab, for `.md`/`.markdown`). Falls back to plain text on any failure.
- **QuickLookCodeShared** — framework linked into both targets above. Contains all IDE integration logic.

**Target dependencies**: `QuickLookCodeExtension` has an explicit `PBXTargetDependency` on `QuickLookCodeShared` even though it does not link the framework (the host app embeds it, resolved at runtime via `@rpath`). The dependency exists purely to force build ordering — without it, `xcodebuild archive` races and the extension's Swift compile can't find the shared module. Xcode GUI masks this via implicit inference, but CLI builds break. Do not remove this dependency.

### Renderer Routing

```
file extension
    ├── "md" / "markdown"  →  MarkdownPreviewController
    │                            ├── prose:  MarkdownRenderer (cmark-gfm + per-block highlight) → WKWebView.loadHTMLString
    │                            └── source: NSTextView ← TextKitRenderer ← SourceCodeRenderer (tokenized, deferred)
    └── everything else    →  NativeCodePreviewController
                                 └── NSTextView ← TextKitRenderer ← SourceCodeRenderer (JSC vscode-textmate)
```

### Data Flow

```
IDELocator.preferred → IDEInfo (app URL, settings URL, extension paths)
    ├── LanguageIndex (built once at bootstrap from every extension's package.json)
    │       entry(forExtension: "py") → Entry { languageId, scopeName, grammarPath, … }
    │       grammarData(for: entry) → Data (TextMate JSON)
    │       siblingGrammarData(for: entry) → [Data] (other grammars from the same extension)
    └── ThemeLoader.loadActiveTheme(from: ide) → ThemeData
            └── serializeTheme(ThemeData) → IRawTheme JSON → vscode-textmate registry.setTheme
```

### Key Constraints

**Sandbox**: Both app and extension run sandboxed. Read access to VS Code / Antigravity install locations and user config dirs is granted via a single entitlement exception list — `com.apple.security.temporary-exception.files.absolute-path.read-only` — containing `/Applications/` and `/Users/`.

**Why `/Users/` and not `home-relative-path` exceptions**: Apple's `com.apple.security.temporary-exception.files.home-relative-path.read-only` silently resolves paths against the *sandbox container home* (`~/Library/Containers/<bundle-id>/Data/`), not the user's real home — so `Library/Application Support/Code/` in that key grants access to a path that doesn't exist and the kernel denies the real read. The absolute-path `/Users/` prefix is resolved literally and covers every user's real home subtree. Do not switch back to home-relative paths.

**Why `getpwuid(getuid())->pw_dir` in `IDELocator.realHomeDirectory()`**: inside a sandboxed process, all Foundation home APIs (`FileManager.default.homeDirectoryForCurrentUser`, `NSHomeDirectory()`, `NSHomeDirectoryForUser(NSUserName())`) return the container path. The direct `getpwuid` syscall reads from Open Directory and bypasses the sandbox remap, returning `/Users/<username>/`. Do not replace this with a Foundation API — paths constructed from Foundation home will read from the sandbox container (which is empty) even though the entitlement would allow access to the real location.

Any new file paths the extension needs to read must be added to both `QuickLookCode.entitlements` and `QuickLookCodeExtension.entitlements`, and constructed in code from `realHomeDirectory()` rather than `FileManager.default.homeDirectoryForCurrentUser`.

**App Group**: `group.com.nehagupta.quicklookcode` — used for shared UserDefaults **and the disk cache** between app and extension *when the entitlement is present* (dev/Developer-ID builds). The cache lives at `<AppGroupContainer>/Library/Caches/quicklookcode/` and contains `manifest.json`, `ide.json`, `theme.json`, and `grammar-index.json`. On ad-hoc-signed builds the App Group is stripped and each process falls back to its own sandbox cache — see **Caching Architecture**.

### IDE Abstraction

The project supports both **VS Code** and **Antigravity** (a VS Code fork). `IDEInfo` holds all paths for a given IDE. `IDELocator.preferred` returns the user's picker choice (stored in shared App Group `UserDefaults` under the `selectedIDE` key — visible to both host app and extension) when that IDE is installed; otherwise the first IDE found in catalog order. The host app's `ContentView` shows the picker only when ≥2 IDEs are installed. `ThemeLoader` takes an `IDEInfo` directly; `LanguageIndex` is built once per IDE at cache bootstrap and queried globally thereafter. Never hardcode VS Code paths.

**Theme dark/light classification** (`ThemeLoader.classifyIsDark`): prefers the theme JSON's own `type` field if present, otherwise falls back to the `uiTheme` field from the extension's `package.json` contribution (`"vs"`/`"hc-light"` = light, everything else = dark). VS Code's built-in themes (e.g. `light_modern.json`) omit `type` entirely and rely on `uiTheme` — a naive `type ?? "dark"` default would mis-classify every one of them as dark.

### Token Scope Matching

Scope→color resolution is handled entirely by `vscode-textmate` internally via `tokenizeLine2`. The library's registry resolves descendant selectors, parent selectors, exclusion selectors, and specificity scoring identically to VS Code. `TokenMapper.swift` has been deleted — there is no Swift-side scope matching.

### Grammar Resolution (LanguageIndex)

Grammars are resolved the same way VS Code resolves them: by reading each extension's `package.json` contributions. At cache bootstrap `LanguageIndex.build(from:)` walks every directory under `builtinExtensionsURL` and `userExtensionsURL`, reads each `package.json`, and joins `contributes.languages[]` (id, aliases, extensions, filenames) with `contributes.grammars[]` (language, scopeName, path, injectTo). Built-ins are processed first and win on collision, matching VS Code's precedence.

The resulting snapshot is persisted to `language-index.json` and exposes four lookups — by file extension, by exact filename (Dockerfile / Makefile / zshrc), by markdown fence tag (matches language id OR alias, so `` ```py `` → Python, `` ```bash `` → Shell), and by scope name (for cross-grammar `include` resolution).

**Injection grammars** (`contributes.grammars[].injectTo`): grammars declared as injections into a target scope participate in tokenization of the target via vscode-textmate's `Registry.getInjections` callback. `LanguageIndex.Snapshot.injectionsForTarget` maps each target scope to the injection scope names registered for it. Passed through `SourceCodeRenderer.tokenize(..., injections:)` → `TokenizerEngine` → `initGrammar(…, injectionsJSON)` → `Registry`'s `getInjections`. The injection grammars' own `injectionSelector` field handles the fine-grained "inside strings, not comments" filtering. This is what makes HTML-in-JS-template-literals, shell-in-Dockerfile-RUN, and JSDoc inside `/** */` tokenize with their inner-language colors.

**Supporting grammars** passed per tokenize call (`LanguageIndex.supportingGrammars(for: entry)`): same-extension siblings of the main grammar (multi-grammar extensions like yaml split into `yaml-1.2`, `yaml-embedded`, etc.), plus injection grammars targeting the entry's scope, plus each injection's own same-extension siblings (so scope-name `include`s inside injection grammars resolve). Scoped per call rather than passing the full index, because `initGrammar` runs on every language change and the JSC parse cost isn't worth paying for grammars that can't possibly apply.

**Do not reintroduce filename fuzzy matching.** See DESIGN_DECISIONS.md — the earlier `FileTypeRegistry` + `GrammarLoader` fuzzy-search pair silently picked wrong grammars (PowerShell for shell, Razor for HTML). The `contributes.languages`/`contributes.grammars` join is the only correct resolver.

### Caching Architecture

Three layers eliminate redundant work between previews:

```
L3 — On-disk cache (survives process death)
     Primary location: App Group container (shared between host + extension)
     Fallback:         the calling process's own sandbox caches dir
     Files:            manifest.json, ide.json, theme.json, language-index.json
     CacheManager.bootstrap() reads or rebuilds on first call.
     Invalidated by: IDE app mtime change, settings.json mtime change, schema bump, Refresh button.

L2 — Process-lifetime in-memory singletons
     IDELocator._cached, ThemeLoader._cachedTheme / _cachedSerializedTheme,
     LanguageIndex._snapshot + path→data cache.
     Survive across space-bar presses while macOS keeps the extension host warm.

L1 — Per-render work (always runs)
     File read, tokenizeLine2, NSAttributedString build, NSTextView/WKWebView paint.
```

**CacheManager** (`Cache/CacheManager.swift`) orchestrates bootstrap and refresh. Call `CacheManager.bootstrap()` before every render — the hot path is a single atomic boolean check (`_loadedCacheVersion != nil && !_needsReload`), no disk I/O. The host app's **Refresh** button calls `CacheManager.refresh()` to force a full rebuild — use this after changing the IDE theme.

**L3 location**: `CacheManager.cacheDir` prefers the App Group container; on ad-hoc-signed builds (no App Group entitlement) `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil and it falls back to `FileManager.urls(for: .cachesDirectory, in: .userDomainMask)` — each sandboxed process's own `~/Library/Containers/<bundle-id>/Data/Library/Caches/quicklookcode/`. Without this fallback, end-users' extensions would rebuild from a full extension-directory walk on every cold launch (theme registry + language-index scan of every extension's `package.json`, 100–400 ms). Do not remove the fallback.

**Cross-process invalidation via Darwin notifications**: the host app and Quick Look extension are separate processes with separate L2 singletons. `CacheManager.refresh()` rebuilds L3 locally, then posts a Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`). Every process that called `bootstrap()` installs a `CFNotificationCenterAddObserver` on first call; the handler flips `_needsReload` so the next `bootstrap()` either swaps L2 from the fresh L3 via one `loadFromDisk()` (shared-cache path) or force-rebuilds its own L3 (unshared-cache path, because each process writes its own container). Behaviour is selected at runtime by `cacheIsShared`. No polling, microsecond latency. On ad-hoc builds the notification is silently dropped by the sandbox (the name is app-group-prefixed but the process isn't in the group), so `mtime` checks against IDE app + `settings.json` become the sole invalidation signal — still correct for theme changes since VS Code rewrites `settings.json` when the user picks a new theme.

**Notification name must be app-group-prefixed**: sandboxed macOS processes silently drop Darwin notifications whose name is not prefixed with an app-group identifier the process belongs to. The constant `CacheManager.cacheUpdatedNotification` is built as `"\(DiskCacheSchema.appGroup).cache-refreshed"` — do not rename to something outside the `group.com.nehagupta.quicklookcode.*` namespace or cross-process invalidation will break silently on the dev build too.

**TokenizerEngine** (`Cache/TokenizerEngine.swift`) is a Swift `actor` that owns one `JSContext` for the process lifetime. `tokenizer-jsc.js` is evaluated once (60–150 ms cold); oniguruma is bridged once. `initGrammar` is called only when language or theme changes between calls — browsing a folder of `.py` files hits `doTokenize` directly. Markdown code blocks all share the same warm context.

**Pre-warm hook**: `PreviewViewController.preparePreviewOfFile` launches `Task.detached { CacheManager.prewarmTokenizer() }` before calling `bootstrap()`. This overlaps the JSContext init + JS bundle eval with the bootstrap / theme-load / cmark-gfm work instead of serializing after them. `TokenizerEngine` itself is internal to the shared framework; `prewarmTokenizer()` is the public hook.

### Tokenization Pipeline

```
CacheManager.bootstrap()
    → IDELocator._cached / ThemeLoader._cachedTheme (L2 hit — no disk I/O)
    → LanguageIndex.entry(forExtension:) + grammarData(for:) (L2 hit after first use)

SourceCodeRenderer.tokenize(code:language:grammarData:theme:)
    → TokenizerEngine.shared.tokenize(...)  ← shared JSContext (actor)
        → initGrammar (only on language/theme change)
        → doTokenize(code) ← tokenizeLine2 → [{text, color, fontStyle}]

TextKitRenderer.attributedString(lines:theme:)  ← NSAttributedString for NSTextView
```

The JS bundle (`tokenizer-jsc.js`) is built via esbuild from `tokenizer/src/tokenizer-jsc.js`. The build output goes directly to `QuickLookCode/QuickLookCodeShared/Resources/tokenizer-jsc.js` — no manual copy needed. Run `pnpm run build` inside `tokenizer/` after changing JS source.

**TextKitRenderer** (`QuickLookCodeShared/TextKitRenderer.swift`) converts `[TokenLine]` to `NSAttributedString`. Key details:
- Line height: `lineHeightMultiple = 1.4` per `NSMutableParagraphStyle`.
- Word-wrap continuation indent: computed as `leadingWhitespaceCharCount × font.maximumAdvancement.width` — per-line paragraph styles so continuation lines align to the first non-whitespace character.
- Truncation notes rendered at 40% alpha foreground.

**NativeCodePreviewController** wraps an `NSScrollView + NSTextView` (TextKit1 stack with explicit `NSTextStorage / NSLayoutManager / NSTextContainer`). Wrap toggle changes `textContainer.size.width` between `CGFloat.greatestFiniteMagnitude` (no wrap) and the scroll view's content width (wrap). A native `NSButton` overlay in the top-right corner drives the toggle.

### In-preview chrome

Two affordances are rendered natively (no HTML/CSS toolbar):

- **Preview/Code pill** (`NSSegmentedControl`) — native AppKit control in `MarkdownPreviewController`; switches between `WKWebView` (prose) and `NSTextView` (source) visibility.
- **Wrap overlay** (`WrapButton: NSButton` subclass) — inside `NativeCodePreviewController` and `MarkdownPreviewController`'s source `NSTextView` container. Colors are set as hardcoded light/dark `NSColor` values keyed on `theme.isDark` — deliberately not theme-derived so the button reads as a distinct floating chrome control. The WKWebView prose tab has no wrap button.

The pill and wrap button are hidden / scaled down in the Finder column-view preview and shown at full size in the dedicated Quick Look window.

### Theme color propagation

Both markdown previews and code previews use the active VS Code theme's colors for every surface (prose, code blocks, toolbar pill). The plumbing is spread across three files; here is the map:

1. **`<body class="dark">` toggle** — added by both `MarkdownRenderer.assembleHTML` and `HTMLRenderer.render` when `theme.isDark` is true. Picks the GitHub-blue link-color variant in `markdown-styles.css` and the `color-scheme: dark;` hint.
2. **`<body style="--md-bg: …; --md-fg: …">`** — `MarkdownRenderer` sets these CSS custom properties from `theme.background` / `theme.foreground`. Every other prose shade (`--md-border`, `--md-muted`, `--md-code-bg`, `--md-table-alt`, `--md-hr`, `--md-blockquote`, `--md-heading-border`) is derived in `markdown-styles.css` via `color-mix(in srgb, var(--md-fg) N%, var(--md-bg))`. The CSS file contains *fallback* values for `--md-bg`/`--md-fg` only; normal operation uses the inline style.
3. **Toolbar pill** (`NSSegmentedControl` in `MarkdownPreviewController`) — AppKit adapts segment control appearance to the window's `NSAppearance` (set from `theme.isDark`); no custom CSS needed.
4. **Wrap overlay button** (`WrapButton` in `NativeCodePreviewController`) — deliberately NOT theme-derived. Uses hardcoded `NSColor` light/dark palettes picked by `theme.isDark`. Intentional: the overlay is meant to read as a floating chrome control that's distinct from the code bg in every theme. Color-mixing the wrap overlay was tried and rejected.

**Link color** stays GitHub blue (`#0969da` light / `#58a6ff` dark, gated by `body.dark`) — theme-derived link colors too often land on shades that are unreadable against the prose bg.

**When adding new rendered surfaces**, use `color-mix(in srgb, var(--md-fg) N%, var(--md-bg))` rather than hardcoded rgba or per-theme lookup tables. The only non-theme-derived shades in the codebase are the wrap overlay palettes (above) and the GitHub-blue link color.

**Xcode 16+ `fileSystemSynchronizedGroups`**: The project uses this feature, so adding or removing source files on disk is sufficient — no `project.pbxproj` edits are needed.

**Vendored C libraries**: Two C libraries are vendored under `QuickLookCodeShared/Vendor/`:

- **`Oniguruma/`** — 48 `.c` files. The `COniguruma` module (`module.modulemap`) is imported by `OnigScanner.swift`. Provides native regex for vscode-textmate.
- **`cmark-gfm/`** — ~60 `.c` files (cmark core + GFM extensions). The `CCmarkGFM` module is imported by `MarkdownRenderer.swift`. Four CMake-generated headers are hand-crafted for macOS (`config.h`, `cmark-gfm_version.h`, `cmark-gfm_export.h`, `cmark-gfm-extensions_export.h`). Two data-only `.inc` files from upstream are renamed to `.h` (`case_fold_switch_data.h`, `entities_data.h`) so `PBXFileSystemSynchronizedRootGroup` treats them as headers rather than attempting to compile them.

Both vendor directories are added to `SWIFT_INCLUDE_PATHS` and `USER_HEADER_SEARCH_PATHS` in `project.pbxproj`.

### Quick Look Reply

The extension uses **view-based preview** (`QLIsDataBasedPreview: false` in `Info.plist`). View-based was chosen to enable keyboard shortcut support (the earlier data-based path using `QLPreviewReply(.html)` has been removed). `PreviewViewController` installs the appropriate child view controller into its container `NSView`.

**WKWebView entitlement**: the sandboxed `WKWebView` (used for markdown prose) requires `com.apple.security.network.client` in both entitlement files even when only loading local HTML strings — without it the web content process crashes silently and the preview renders blank.

### Markdown two-phase render

`MarkdownPreviewController` hosts an `NSSegmentedControl` (Preview / Source toggle), a `WKWebView` for prose, and an `NSTextView` for the highlighted source.

1. **Fast phase** — `MarkdownRenderer.render(...)` returns `RenderResult { html: Data, markdown: String }`. `MarkdownPreviewController.showProse(html:theme:)` calls `WKWebView.loadHTMLString` immediately. `showSourcePlaceholder(_:theme:)` populates the NSTextView with a plain-text `NSAttributedString` so it's not blank if the user switches tabs before tokenization finishes.
2. **Deferred phase** — after `renderCode` returns, `MarkdownRenderer.tokenizeSource(markdown:theme:ide:)` runs on a `Task`, then `showSource(tokens:theme:)` replaces the NSTextView content with the fully tokenized `NSAttributedString`.

**Task cancellation**: `preparePreviewOfFile` and its sub-renderers check `Task.isCancelled` at each await-boundary. Silent early-return (`if Task.isCancelled { return }`, not `try Task.checkCancellation()`) avoids the QL "Failed to load preview" error banner. Do not drop these checks — they prevent stacked tokenize requests from blocking the actor queue during rapid space-bar presses.

### Design decisions reference

`DESIGN_DECISIONS.md` documents load-bearing constraints that look like dead code but must not be removed:
- **Horizontal scroll JS fix** — reads `#ql-content.offsetHeight` and sets it as inline `minHeight` on `<pre>`. Without this, scroll events are dropped in short files. (WKWebView / markdown prose only.)
- **Right-edge padding** — CSS trailing padding does not extend WebKit scroll extent; the issue is unfixed and documented as a known limitation.
- **JS availability** — `evaluateJavaScript` works in Quick Look's WKWebView; the old comment claiming JS was disabled was incorrect.
- **L3 cache fallback on ad-hoc builds** — do not gate cache writes on App Group availability; the per-process caches-dir fallback is speed-critical for end users.
- **Task cancellation pattern** — see above; silent return over throwing is intentional.

## Current Status

- **Phase 0** (Scaffolding) ✅ — extension loads, `qlmanage` works
- **Phase 1** (IDE Integration) ✅ — IDELocator, GrammarLoader, ThemeLoader complete; ContentView shows live theme info
- **Phase 2** (Tokenization + HTML output) ✅ — JSC-based vscode-textmate pipeline, HTMLRenderer, FileTypeRegistry
- **Phase 2.5** (Native library migration) ✅ — `tokenizeLine2` for internal color resolution; native oniguruma C library replacing JS regex shim; `TokenMapper` deleted
- **Phase 3** (NSTextView renderer) ✅ — `NativeCodePreviewController` + `TextKitRenderer` replace WKWebView for code files; `MarkdownPreviewController` hosts WKWebView prose + NSTextView source with native `NSSegmentedControl` tab switcher; `MarkdownRenderer.swift`, `markdown-styles.css`, cmark-gfm vendored
- **Phase 4** (`.ts` TypeScript preview) — **not achievable** via QL extension API; see PLAN.md
- **Phase 4.5** (Performance — multi-layer caching) ✅ — `CacheManager`, `TokenizerEngine` actor, `SharedWebProcessPool`, grammar index, pre-serialized theme JSON, host app Refresh button
- **Phase 5** (FSEventStream theme watching, font sync, line numbers) — planned

See `PLAN.md` for full phase specifications.
