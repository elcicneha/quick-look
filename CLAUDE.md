# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build from command line
xcodebuild -project QuickLookCode/QuickLookCode.xcodeproj -scheme QuickLookCode -configuration Debug build

# Test the extension on a file
qlmanage -p path/to/file.swift

# Reload the extension after changes (run both)
qlmanage -r
killall -HUP Finder

# Check the extension is registered
pluginkit -m -v | grep quicklook

# Check extension logs
log stream --predicate 'subsystem contains "quicklookcode"' --level debug
```

## Architecture

Three Xcode targets, all in `QuickLookCode/QuickLookCode.xcodeproj`:

- **QuickLookCode** — host macOS app (required by macOS to ship an extension). Minimal SwiftUI UI showing IDE detection status and active theme.
- **QuickLookCodeExtension** — the actual Quick Look preview extension (`QLPreviewProvider`). Entry point: `PreviewProvider.swift`. Currently returns hardcoded HTML.
- **QuickLookCodeShared** — framework linked into both targets above. Contains all IDE integration logic.

### Data Flow

```
IDELocator.preferred → IDEInfo (app URL, settings URL, extension paths)
    ├── GrammarLoader(ide) → grammarData(for: "python") → Data (TextMate JSON)
    └── ThemeLoader.loadActiveTheme(from: ide) → ThemeData
            └── TokenMapper(theme) → color(forScopes: [...]) → "#rrggbb"
```

### Key Constraints

**Sandbox**: Both app and extension run sandboxed. Read access is granted via entitlement exceptions to:
- `/Applications/` (VS Code, Antigravity)
- `~/Applications/`
- `~/Library/Application Support/Code/` and `~/Library/Application Support/Antigravity/`
- `~/.vscode/` and `~/.antigravity/`

Any new file paths the extension needs to read must be added to both `QuickLookCode.entitlements` and `QuickLookCodeExtension.entitlements`.

**App Group**: `group.com.nehagupta.quicklookcode` — used for shared UserDefaults between app and extension.

### IDE Abstraction

The project supports both **VS Code** and **Antigravity** (a VS Code fork). `IDEInfo` holds all paths for a given IDE. `IDELocator.preferred` returns whichever is found first. All downstream code (GrammarLoader, ThemeLoader) takes an `IDEInfo` — never hardcode VS Code paths.

### Token Scope Matching

`TokenMapper` implements VS Code's exact matching algorithm: walks each token's scopes from most specific to least specific, finds the longest prefix match among theme rules. The rule with the longest matching scope string wins. This must stay in sync with how VS Code resolves colors or previews will differ from the editor.

### Quick Look Reply

The extension uses **data-based preview** (`QLIsDataBasedPreview: true`), not view-based. The reply is always `QLPreviewReply(dataOfContentType: .html, ...)` — rendering produces an HTML string, encoded as UTF-8 Data.

## Current Status

- **Phase 0** (Scaffolding) ✅ — extension loads, `qlmanage` works
- **Phase 1** (IDE Integration) ✅ — IDELocator, GrammarLoader, ThemeLoader, TokenMapper complete; ContentView shows live theme info
- **Phase 2** (WASM tokenization + HTML output) — next
- **Phase 3** (Markdown renderer with cmark-gfm) — planned
- **Phase 4** (`.ts` magic byte detection for MPEG-2 vs TypeScript) — planned
- **Phase 5** (FSEventStream theme watching, font sync, line numbers) — planned

See `PLAN.md` for full phase specifications.
