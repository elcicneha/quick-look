# QuickLook Extension — Build Plan

## Core Idea

A macOS Quick Look extension that uses **VS Code's own tokenization engine and your active theme** to render code previews. The result is pixel-accurate coloring — identical to what you see in the editor — with zero manual theme configuration.

---

## Why This Approach

VS Code is open source (MIT). It uses `vscode-textmate` to tokenize code and TextMate grammars (JSON files) for 100+ languages. Both are available:

- `vscode-textmate` — published on npm, has a WASM build
- Grammar files — sitting at `/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/`
- Your active theme — JSON file in `~/.vscode/extensions/` or VS Code's built-in themes folder

Using the same engine + same grammars + same theme = identical output. No separate theme setup, no color mismatch.

---

## Architecture

### Rendering: HTML (not RTF)

Since `vscode-textmate` runs in JavaScript, we use a WKWebView to:
1. Load the WASM build of `vscode-textmate`
2. Load the grammar file for the target language
3. Tokenize the code
4. Apply theme colors to tokens
5. Return styled HTML to the Quick Look preview

RTF is out. HTML is the right call here since we're already in a JS context.

Markdown uses the same HTML path — `cmark-gfm` for parsing, code blocks tokenized by `vscode-textmate`.

### Three Xcode Targets

```
QuickLookApp/           — Host app (required by macOS to bundle the extension)
                          Minimal UI: shows active VS Code theme name, status
QuickLookExtension/     — QL Preview Extension (QLPreviewProvider)
                          Routes file to renderer, returns HTML reply
QuickLookShared/        — Framework with all rendering logic
                          Used by both app and extension
```

### Renderer Routing

```
file arrives
    ├── .md / .markdown  →  MarkdownRenderer  →  cmark-gfm + vscode-textmate for code blocks
    └── everything else  →  SourceCodeRenderer →  vscode-textmate tokenization
                                                   both → HTML → QLPreviewReply(.html)
```

---

## File Structure

```
quick-look/
├── QuickLook.xcodeproj
│
├── QuickLookApp/
│   ├── QuickLookApp.swift
│   ├── ContentView.swift           # Shows active theme, VS Code path status
│   ├── Info.plist
│   └── QuickLookApp.entitlements   # App Group
│
├── QuickLookExtension/
│   ├── PreviewProvider.swift        # Entry point, routing, .ts magic byte check
│   ├── Info.plist                   # QLSupportedContentTypes
│   └── QuickLookExtension.entitlements
│
├── QuickLookShared/
│   ├── Renderers/
│   │   ├── PreviewRenderer.swift        # Protocol: render(fileURL:) → Data
│   │   ├── SourceCodeRenderer.swift     # vscode-textmate → HTML
│   │   ├── MarkdownRenderer.swift       # cmark-gfm → HTML, code blocks via textmate
│   │   └── PlainTextRenderer.swift      # Fallback
│   ├── VSCode/
│   │   ├── VSCodeLocator.swift          # Finds VS Code installation path
│   │   ├── GrammarLoader.swift          # Loads .tmGrammar.json from VS Code's extensions
│   │   ├── ThemeLoader.swift            # Reads active VS Code theme JSON → token colors
│   │   └── TokenMapper.swift           # Maps vscode-textmate token scopes → colors
│   ├── FileTypeRegistry.swift          # Extension → renderer + grammar name mapping
│   ├── HTMLRenderer.swift              # Assembles final HTML from tokens + theme
│   ├── UserSettings.swift              # App Group UserDefaults (font, size, etc.)
│   └── Resources/
│       ├── vscode-textmate.wasm        # Compiled vscode-textmate WASM build
│       ├── tokenizer.js                # JS glue: loads WASM, exposes tokenize()
│       ├── markdown-styles.css         # GitHub-like markdown stylesheet
│       └── base-template.html          # HTML shell, all CSS inlined at render time
│
└── Tests/
    ├── GrammarLoaderTests.swift
    ├── ThemeLoaderTests.swift
    ├── RendererTests.swift
    └── Fixtures/
        ├── sample.swift
        ├── sample.py
        ├── sample.ts               # TypeScript (text)
        ├── sample-video.ts         # Actual MPEG-2 file for magic byte test
        └── README.md
```

---

## Phases

### Phase 0 — Xcode Scaffolding ✅
**Goal:** Build succeeds, extension visible in System Settings → Extensions → Quick Look

1. ✅ Created Xcode project `QuickLookCode`, macOS App target, deployment target **macOS 13.0**
2. ✅ Added Quick Look Preview Extension target (`QuickLookCodeExtension`)
3. ✅ Added Framework target (`QuickLookCodeShared`), linked into both App and Extension
4. ✅ Configured App Group entitlement: `group.com.nehagupta.quicklookcode`
5. ✅ `PreviewProvider` returns hardcoded HTML via `QLPreviewReply(dataOfContentType: .html)`
6. ✅ `Info.plist` — `QLIsDataBasedPreview: true`, `QLSupportedContentTypes: [public.swift-source]`
7. ✅ Built, launched app, confirmed `qlmanage -p test.swift` shows QuickLookCode preview

**Verified:** `qlmanage -p test.swift` shows dark HTML preview with filename — extension is live

---

### Phase 1 — VS Code / Antigravity Integration ✅
**Goal:** Read grammars and theme directly from the IDE installation

**Verified:** Host app shows `Antigravity · Default Dark Modern · Dark · #1F1F1F`

1. ✅ **IDELocator** (`QuickLookCodeShared/IDE/IDELocator.swift`) — finds VS Code (preferred) then Antigravity in `/Applications` and `~/Applications`. Returns all installed IDEs; `preferred` returns first found.

2. ✅ **GrammarLoader** (`QuickLookCodeShared/IDE/GrammarLoader.swift`) — searches built-in and user extensions for `.tmLanguage.json` / `.tmGrammar.json` by language name. In-memory URL cache.

3. ✅ **ThemeLoader** (`QuickLookCodeShared/IDE/ThemeLoader.swift`) — reads `workbench.colorTheme` from `settings.json`; falls back to `"Default Dark Modern"` when unset. Scans `themes/` folders in all extensions, matches by `"name"` key inside JSON. Returns `ThemeData` with background, foreground, and `[TokenColorRule]`.

4. ✅ **TokenMapper** (`QuickLookCodeShared/IDE/TokenMapper.swift`) — TextMate prefix-matching algorithm, most-specific scope wins.

5. ✅ **Entitlements** — added `temporary-exception` read-only access for `/Applications/`, `~/.vscode/`, `~/.antigravity/`, and both `Library/Application Support/` paths (app + extension).

6. ✅ **Host app status UI** (`ContentView.swift`) — live display of detected IDE, path, theme name, type, and background color swatch.

**Note:** IDE catalog supports VS Code + Antigravity (Google's VS Code fork). VS Code is preferred; Antigravity is fallback. Both share identical internal structure.

---

### Phase 2 — WASM Tokenization + HTML Output
**Goal:** Code files render with correct colors in Quick Look

1. **vscode-textmate WASM** — bundle the compiled WASM build
   - Write `tokenizer.js` glue: initializes WASM, loads grammar JSON, exposes `tokenizeLine(code, grammar)` → array of `{startIndex, endIndex, scopes}`

2. **SourceCodeRenderer**:
   - Determine language from file extension
   - Load grammar via GrammarLoader
   - Load token colors via ThemeLoader
   - Spin up WKWebView (offscreen), load `tokenizer.js` + WASM
   - Pass file content line by line → get token spans back
   - Build HTML: each token becomes a `<span style="color:#xxxxxx">` 
   - Wrap in `<pre>` with theme background color
   - Return complete HTML to `QLPreviewReply`

3. **HTMLRenderer** — shared helper that assembles the final HTML shell:
   - Inlines all CSS (sandbox blocks external loads)
   - Sets background to theme's `editor.background` color
   - Sets font to user's preferred monospace font + size
   - Handles dark/light mode (reads theme type)

4. **FileTypeRegistry** — maps file extensions to grammar names:
   - `.py` → `"python"`, `.swift` → `"swift"`, `.js` → `"javascript"`, `.ts` → `"typescript"`, etc.
   - 40+ mappings to start

5. **UTType declarations** in `Info.plist`:
   - All standard system UTTypes (Swift, Python, JS, C, C++, JSON, XML, Shell, Ruby, etc.)
   - Exported custom UTTypes for: YAML, TOML, Go, Rust, Kotlin, TypeScript (tsx), Dockerfile, GraphQL, etc.

6. **File size guard** — cap at 500KB / 10,000 lines, truncate with message

**Verify:** `qlmanage -p` on .py, .swift, .js, .json — colors match VS Code exactly

---

### Phase 3 — Markdown Renderer
**Goal:** `.md` files render as full GitHub-flavored Markdown

1. Add `cmark-gfm` via Swift Package Manager
2. **MarkdownRenderer**:
   - Parse `.md` → HTML via cmark-gfm (GFM tables, task lists, strikethrough)
   - Fenced code blocks: extract language + content, run through vscode-textmate, replace with highlighted HTML
   - Inline images: convert relative paths to data URIs where possible
3. **markdown-styles.css** — GitHub-like stylesheet, inlined into HTML output
4. Dark/light mode: two CSS blocks, `@media (prefers-color-scheme: dark)` switches between them

**Verify:** `qlmanage -p README.md` — tables, task lists, syntax-highlighted code blocks render correctly

---

### Phase 4 — TypeScript `.ts` Fix (Magic Byte Detection)
**Goal:** `.ts` TypeScript files render correctly; actual MPEG-2 video files pass through

**The problem:** macOS registers `.ts` as `public.mpeg-2-transport-stream` at the system level.

**The solution:** Declare our extension as the handler for `public.mpeg-2-transport-stream`, then inspect the file content to decide what to do.

MPEG-2 Transport Stream signature:
- Byte 0 = `0x47`
- Byte 188 = `0x47`
- Byte 376 = `0x47`
- (sync byte at every 188-byte packet boundary)

```swift
func isMPEG2(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    let data = handle.readData(ofLength: 565)
    guard data.count >= 376 else { return false }
    return data[0] == 0x47 && data[188] == 0x47 && data[376] == 0x47
}
```

- If MPEG-2 → throw `QLPreviewError.notSupported` (system handles it)
- If text → render as TypeScript

**Verify:** TypeScript files render. A real `.ts` video file falls through to system handler.

---

### Phase 5 — Polish & Auto-Update
**Goal:** Zero maintenance, always in sync with VS Code

1. **Theme auto-detection** — watch `~/Library/Application Support/Code/User/settings.json` for changes using `FSEventStream`. When theme changes in VS Code, next Quick Look preview automatically uses the new theme. No restart needed.

2. **Font sync** — read `"editor.fontFamily"` and `"editor.fontSize"` from VS Code settings, use those in previews

3. **Line numbers** — optional toggle (reads VS Code's `"editor.lineNumbers"` setting)

4. **Host app UI** — simple status view:
   - "VS Code found at: /Applications/..."
   - "Active theme: GitHub Dark"
   - Override toggles: font size, line numbers, word wrap

---

## Key Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| `vscode-textmate` (WASM) | npm / build step | Code tokenization |
| TextMate grammars | VS Code installation | Language definitions |
| User's VS Code theme | VS Code installation | Token colors |
| `cmark-gfm` | Swift Package Manager | Markdown parsing |

---

## Testing

```bash
# Test a file
qlmanage -p path/to/file.py

# Reload extension after changes
qlmanage -r
killall -HUP Finder

# Check extension is registered
pluginkit -m -v | grep quicklook

# Verify .ts magic byte detection
qlmanage -p sample.ts        # should render TypeScript
qlmanage -p sample-video.ts  # should fall through
```

---

## Out of Scope

- Mac App Store distribution
- Notarization / public release
- Bracket pair colorization (VS Code UI feature, not tokenization)
- Jupyter notebooks
- CSV / table rendering
