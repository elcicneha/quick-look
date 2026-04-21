# Native Stack Migration — Phased Plan

Target end state:
- **Two tokenizer modes.** *IDE-faithful* = a native Swift port of `vscode-textmate` (keeps bit-for-bit parity with VS Code's coloring). *Fast* = `tree-sitter` with our own curated theme system.
- **Native rendering via TextKit 2** for all code files and the markdown Source tab. `WKWebView` stays only for markdown prose.
- **Live editing** on the native renderer, driven by whichever tokenizer the user picked.
- Cold first-paint for any code file bounded by macOS extension spawn (~100–250 ms).

Each phase below is executable in a dedicated chat. Phases are sequential — do not start phase N until phase N−1 is merged and green. Every phase ends with a named deliverable and a verifiable acceptance check.

> The previous build plan — JS vscode-textmate in a WKWebView, IDE integration, cmark-gfm markdown renderer, multi-layer caching — has shipped (see `ROADMAP.md` for the history). This document replaces it.

---

## Phase 1 — Tokenizer Protocol + Bench Harness

**Goal:** abstract the tokenizer behind a protocol and freeze today's output as a golden corpus, so later phases can swap implementations without regression.

**Depends on:** nothing.

**Scope in:**
- Define `protocol Tokenizer` in `QuickLookCodeShared` exposing `tokenize(source:language:grammarData:siblingGrammars:theme:) async -> [[RawToken]]` (mirrors today's signature).
- Refactor `SourceCodeRenderer.tokenize` and `MarkdownRenderer.highlightSnippet` / `generateSourceHTML` to depend on `Tokenizer`, not on the concrete `TokenizerEngine`.
- Make today's JSC implementation the first conformer: `JSTokenizer: Tokenizer` wrapping `TokenizerEngine`.
- Add a factory `TokenizerRegistry.current()` that returns the active tokenizer. For now it always returns `JSTokenizer`.
- Build a bench+diff harness (new target or a `swift run` executable in `tokenizer/bench/`) that:
  - Walks a test corpus of ~50 small and ~10 large files (Swift, Python, YAML, TS, JSON, Markdown, etc.).
  - Tokenizes each via the current JSC engine.
  - Writes the `[RawToken]` stream as JSON to `tokenizer/bench/golden/<filename>.json`.
  - On re-run, compares new output against golden and prints diffs.
- Commit the golden files.

**Scope out:** no algorithm port, no renderer changes, no user-visible changes.

**Acceptance:**
- All existing previews behave identically.
- `swift run bench --verify` against golden corpus passes with zero diffs.
- `TokenizerEngine` is no longer referenced directly from any renderer — only through `Tokenizer`.

**Risks:** the JSC output is not fully deterministic across runs (unlikely but possible with object-key ordering). If so, canonicalize the JSON output before comparison.

**Handoff notes for next phase:** the golden corpus is the contract. Phase 2's success criterion is "matches golden" — that's the whole point of building this phase first.

---

## Phase 2 — Native `vscode-textmate` Port (Swift)

**Goal:** replace the JavaScriptCore tokenizer with a pure-Swift implementation that produces bit-for-bit identical output. Keeps all IDE-integration behavior (user's grammars, user's theme). This is the single biggest speed win without changing fidelity.

**Depends on:** Phase 1.

**Scope in:**
- New module directory: `QuickLookCodeShared/NativeTokenizer/`.
- Port the following pieces of `vscode-textmate`:
  - **Grammar loader** — parse `.tmLanguage.json` into an in-memory rule tree. Resolve `include` references (local, external-scope, base-scope, self).
  - **Rule compiler** — compile patterns into `OnigScanner`-backed matchers (reuses existing `OnigScanner.swift`).
  - **Rule stack** — the push/pop state machine that drives line-by-line tokenization.
  - **Scope stack** — hierarchical scope tracking (`source.python meta.function-call string.quoted.double`).
  - **Injection selector** — resolves `injectionSelector` patterns.
  - **Theme matcher** — CSS-like selector matching with specificity scoring; returns `foreground`/`fontStyle` for each scope stack. This is the trickiest piece to match exactly.
  - **Tokenizer** — the per-line entry point that combines all of the above.
- Implement `NativeTokenizer: Tokenizer` conforming to the protocol from Phase 1.
- Add a hidden dev setting (`UserDefaults` key) to switch between JS and native engines; default still JS at this phase.
- Run the bench harness with `--engine=native` and enumerate every divergence from golden. Target: zero diffs. If a specific construct is genuinely underspecified in upstream docs, document the divergence in `DESIGN_DECISIONS.md`, note it in code, and get sign-off before moving on.
- Flip default to native once diff count is zero (or zero excluding documented-and-accepted items).

**Scope out:** no renderer change. Still handing HTML to `WKWebView`. No tree-sitter yet.

**Acceptance:**
- `swift run bench --verify --engine=native` passes against golden on full corpus.
- Throughput on `pnpm-lock.yaml` improves by ≥5× vs JS baseline (measured in bench harness).
- All existing previews behave indistinguishably from Phase 1 end state.
- The JS tokenizer and `tokenizer-jsc.js` bundle are still present but unused by default.

**Risks:**
- **Theme matcher specificity ties.** `vscode-textmate` has idiosyncratic tiebreaking that isn't fully documented. Read the upstream TS source, not just docs. If a tie rule changes output on exotic themes, reproduce upstream exactly even if the rule seems weird.
- **Injection selectors.** Rarely-used but present in several popular grammars. Plan a dedicated sub-sprint here.
- **Cross-grammar includes.** Many grammars (YAML, TS, Markdown) pull scopes from each other. The grammar loader needs a resolver that can pull from `siblingGrammars` — follow the Phase 1 protocol signature.

**Handoff notes:** after this phase, `TokenizerEngine`, `OnigJSBridge`, and `tokenizer-jsc.js` are dead code on the default path. Keep them for one release cycle as a fallback, then remove.

---

## Phase 3 — NSTextView Code Renderer

**Goal:** replace `WKWebView` with `NSTextView`/TextKit 2 for every code-file preview and for the markdown Source tab. `WKWebView` remains only for markdown prose.

**Depends on:** Phase 2 (not strictly required, but tokenizer speed should be landed before measuring renderer improvement).

**Scope in:**
- New `NativeCodePreviewController: NSViewController, QLPreviewingController` in `QuickLookCodeExtension/`.
  - Hosts an `NSScrollView` containing an `NSTextView` with TextKit 2 enabled.
  - `NSTextStorage` populated from `[RawToken]` → `NSAttributedString` attribute runs (`foregroundColor`, `font`, italic/bold/underline traits).
  - Theme colors applied directly; no CSS.
- Wrap toggle:
  - `NSButton` overlay pinned top-right of the scroll view.
  - Toggles `textContainer.widthTracksTextView` + container size.
  - Drops every `:has()` / `position: fixed` workaround from the current WebView CSS.
- Markdown split:
  - `MarkdownPreviewController` remains a view controller but hosts a container with two child views: `WKWebView` (Preview tab) and `NSTextView` (Source tab).
  - `NSSegmentedControl` drives the swap — no more CSS-only radio hack.
- Routing in `PreviewViewController` (or a new dispatcher): by file extension, instantiate the right controller.
- Keep progressive color fill-in within TextKit 2: start with plain-text attribute run (just bg/fg), then as tokenizer results stream back, replace attribute runs on the relevant ranges via `NSTextStorage.setAttributes(_:range:)`. TextKit 2 invalidates only the affected line fragments.

**Scope out:** no editing yet — `isEditable = false`. No tree-sitter. No live-highlight-on-edit.

**Acceptance:**
- Cold first-paint for code files drops to roughly macOS extension spawn + ~50 ms of our work.
- `pnpm-lock.yaml` renders with colors in under 250 ms total.
- Selection, keyboard nav, and copy work natively without extra wiring.
- Wrap toggle works; markdown Preview/Code toggle works.
- No regressions in rendered appearance vs Phase 2 end state. Spot-check: take screenshots of 10 representative files pre/post, visually diff.

**Risks:**
- **Font and line-height.** TextKit 2 line metrics won't match CSS `line-height: 1.6` out of the box. Tune `NSParagraphStyle.lineHeightMultiple` until visual parity with the WebView preview.
- **Monospace font fallback.** WebView's `ui-monospace` resolves to SF Mono on macOS; pin to `NSFont.monospacedSystemFont` explicitly.
- **Dark-mode system chrome.** `NSTextView`'s selection highlight pulls from `NSColor.selectedTextBackgroundColor`. Make sure it reads sensibly against the theme's background.

**Handoff notes:** `WKWebView` shows up in only one place after this phase — the markdown-preview tab. `HTMLRenderer` becomes markdown-only and should be renamed or scoped to `MarkdownPrefixedRenderer` to make that explicit.

---

## Phase 4 — Tree-sitter Integration (Fast Mode)

**Goal:** introduce tree-sitter as a second tokenizer behind a user-facing setting. IDE-faithful remains default; Fast is opt-in.

**Depends on:** Phase 1 (for the tokenizer protocol), Phase 3 (because Fast mode's value only materializes when rendering is also native).

**Scope in:**
- Vendor `tree-sitter` core (C) under `QuickLookCodeShared/Vendor/tree-sitter/`, alongside `Oniguruma/` and `cmark-gfm/`.
- Vendor per-language parsers — initial set: Swift, Python, JavaScript, TypeScript, TSX, Rust, Go, YAML, JSON, HTML, CSS, SCSS, Bash, Markdown, C, C++, Ruby, Java, Kotlin, Dart, PHP, SQL, TOML. ~25 parsers to start; extend later.
- Swift wrapper module: `TreeSitterEngine` conforming to `Tokenizer`.
- Ship curated `.scm` highlight query files per language under `QuickLookCodeShared/Resources/tree-sitter-queries/`.
- Capture-name-based theme format: `Theme` struct mapping capture names (`@keyword`, `@string`, `@function`, …) → color + style. Serialized as JSON.
- Two bundled native themes initially: one dark, one light — visually tuned to look good out of the box.
- Host app UI: new "Rendering" section with a segmented control (`IDE-faithful` / `Fast`). Persisted in App Group `UserDefaults` so the extension sees it.
- When Fast is selected, `TokenizerRegistry.current()` returns `TreeSitterEngine`; when IDE-faithful is selected, returns `NativeTokenizer` from Phase 2.

**Scope out:** no VS Code theme importer yet. No live editing. Coverage for languages outside the initial ~25 falls through to a plain-text fallback in Fast mode — document this as a known limitation to resolve in Phase 5.

**Acceptance:**
- Toggling modes in the host app switches the extension's rendering on the next preview. No relaunch required.
- Throughput on `pnpm-lock.yaml` in Fast mode: <20 ms tokenize.
- Throughput on a 1 MB JS lockfile: <80 ms tokenize.
- Rendered appearance in Fast mode looks coherent (not necessarily matching IDE) — reviewer sign-off that it's "professionally colored" on the top ~10 languages.

**Risks:**
- **Install size.** 25 parsers might add 10–20 MB. Audit per-parser size; consider deferring rare ones.
- **Query quality.** Upstream community-maintained `.scm` files vary. For each language, compare output visually to an authoritative source (Zed or Neovim) and tweak queries as needed. Commit our curated forks under our resources dir.
- **Markdown code blocks.** In Fast mode inside markdown, fenced blocks should also use tree-sitter. Make sure the markdown path routes through `TokenizerRegistry.current()` so Fast mode takes effect there too.

**Handoff notes:** `NativeTokenizer` from Phase 2 stays wired in. Fast mode is additive, never replaces the default. Users who set it back to IDE-faithful should see zero difference from Phase 3 end state.

---

## Phase 5 — Theme System + VS Code Importer

**Goal:** make Fast mode comfortable for users who want their IDE's look without paying IDE-faithful mode's speed cost.

**Depends on:** Phase 4.

**Scope in:**
- Expand bundled theme set to 8–10 carefully curated choices (Dracula, Tokyo Night, Solarized Light/Dark, GitHub Light/Dark, Monokai, Nord, One Dark).
- Host-app theme picker UI: grid of theme previews (small snippet rendered in each theme), click to select.
- VS Code theme importer tool in the host app:
  - Accept a `.json` VS Code theme via file picker or drop.
  - Parse `tokenColors` array.
  - Apply a scope → capture mapping table (ship a best-effort mapping — e.g., `keyword.control` → `@keyword.control`, `string` → `@string`, etc.).
  - Write the result as a native theme JSON file to the app's cache dir.
  - Preview side-by-side: the user's IDE preview vs our imported-theme preview on a sample file. Show a "visual diff" highlight so they can see where coloring will differ.
  - Allow per-capture manual override.
- User themes stored in `~/Library/Application Support/Peekaboo/themes/` and picked up by the extension.
- "Reset to bundled" button to discard imports.

**Scope out:** no theme editor GUI (capture-by-capture color picker) yet — user either accepts the import or edits the JSON manually.

**Acceptance:**
- Importing a VS Code theme produces a usable, aesthetically coherent Fast-mode theme.
- Side-by-side preview shows differences transparently; user is never surprised.
- Persists across launches without cache-clear.

**Risks:**
- **Scope → capture mapping coverage.** The mapping table needs to handle dozens of scope prefixes. Start with a conservative subset, expand iteratively.
- **Theme JSON dialects.** VS Code themes ship variations (JSONC comments, `semanticTokenColors`, `include` references). Support the common shape, warn on the rest.

**Handoff notes:** after this phase, Fast mode is ready to be promoted as the default in a future release. Keep IDE-faithful as the fallback for users whose grammars or themes aren't covered by the tree-sitter set.

---

## Phase 6 — Live Editing

**Goal:** turn the preview into a real editor. Edit, undo, re-highlight as you type, save.

**Depends on:** Phase 3 (the NSTextView renderer) and Phase 4 (tree-sitter for incremental re-highlight in Fast mode). Phase 5 is nice-to-have but not required.

**Scope in:**
- Add "Edit" toggle to the preview toolbar (new `NSButton`). Default is read-only; click to enter edit mode.
- In edit mode:
  - `NSTextView.isEditable = true`.
  - Text input, selection, undo/redo all come from NSTextView's built-ins.
- `NSTextStorage` delegate handles `processEditing(_:range:changeInLength:)`:
  - **Fast mode (tree-sitter):** compute the edit as a `TSInputEdit`, call `ts_parser_parse` with the previous tree → tree-diff → recompute highlights only for ranges that changed → apply attribute deltas.
  - **IDE-faithful mode (native vscode-textmate):** re-tokenize from the edit's start line to EOF (cheaper than full-file but still linear); apply attribute deltas. Size-gate: above some threshold (say 20 k lines), debounce to avoid re-tokenizing on every keystroke.
- Save flow:
  - "Save" button commits to the original file via `NSDocument`-style save (user confirms first time; remember consent per file).
  - "Revert" button discards unsaved edits.
  - Unsaved-edit indicator in the preview chrome.
- Handle concurrent external file changes — if file mtime changes while editing, prompt on save.

**Scope out:** collaborative editing, multi-cursor, find-and-replace, autocomplete. This phase is "it edits and saves" — not a full IDE.

**Acceptance:**
- One-char edit in a 10 k-line file in Fast mode: re-highlight latency <5 ms.
- One-char edit in IDE-faithful mode on a 5 k-line file: re-highlight <200 ms.
- Undo/redo works natively.
- Save round-trips through the filesystem; mtime updates.
- No crashes on rapid editing, rapid save, rapid mode switching.

**Risks:**
- **File permissions.** Quick Look extensions run sandboxed. Writing back to the original file requires `com.apple.security.files.user-selected.read-write` (currently read-only in the manifest). Verify that user-initiated saves work inside the sandbox.
- **Data loss.** Unsaved edits when the preview is dismissed need prompting. QL extensions have limited lifecycle hooks — investigate whether we can intercept dismissal, or make autosave default with a local draft.
- **Tree-sitter edit conversion.** `TSInputEdit` takes byte offsets and row/column; NSTextStorage edits are in UTF-16 units. Conversion needs care to get right.

**Handoff notes:** after this phase, Peekaboo is no longer "just a Quick Look extension." Re-scope the README accordingly.

---

## Cross-phase working agreements

- **Every phase keeps the previous phase's acceptance criteria green.** No regressions allowed.
- **Bench harness runs in CI** from Phase 1 onward. Bench output diffs fail the build.
- **`DESIGN_DECISIONS.md` gets an entry per phase** documenting any non-obvious trade-off chosen inside the phase.
- **`CLAUDE.md` gets updated incrementally** — the caching architecture section, tokenizer section, and renderer routing diagrams all drift as phases land.
- **No feature flags left behind.** Once a phase is the default, the old code path is retired on the next phase boundary.

## Post-phase candidates (not scheduled)

- Code folding via tree-sitter AST ranges.
- Symbol outline panel.
- Multi-file search.
- A custom theme editor with live preview.
- Remove IDE-faithful mode entirely once Fast mode coverage is universal (unlikely — keep both).
