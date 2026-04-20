//
//  ToolbarRenderer.swift
//  QuickLookCodeShared
//
//  Generates the UI chrome injected into every Quick Look preview:
//    • Markdown pages get a top toolbar containing the Preview/Code pill.
//    • The word-wrap toggle is a fixed-position overlay pinned to the
//      top-right edge of the viewport — it sits over the content, not
//      inside the toolbar.
//
//  Toggle mechanism: CSS-only via hidden radio inputs + the general sibling
//  selector (~). Quick Look's WebView has JavaScript disabled, so all
//  interactivity must be driven by CSS :checked state.
//
//  The wrap overlay label is placed *inside* the content container so a
//  single `top: 6px; right: 6px` rule anchors it correctly in both cases —
//  no per-page offset needed. In markdown, the label nests inside
//  `#ql-view-code`, which means it naturally hides in preview mode (that
//  subtree is `display: none`) and reappears in code-view mode.
//
//  Required body structure for markdown:
//
//    <body>
//      [ToolbarRenderer.toggleInputsHTML]       <!-- radios -->
//      [ToolbarRenderer.wordWrapCheckboxHTML]   <!-- checkbox -->
//      [ToolbarRenderer.toolbarHTML]            <!-- pill -->
//      <div id="ql-content">
//        <div id="ql-view-preview">…</div>
//        <div id="ql-view-code">
//          [ToolbarRenderer.wordWrapOverlayHTML]
//          …
//        </div>
//      </div>
//    </body>
//
//  Required body structure for code files:
//
//    <body>
//      [ToolbarRenderer.wordWrapCheckboxHTML]
//      <div id="ql-content">
//        [ToolbarRenderer.wordWrapOverlayHTML]
//        …
//      </div>
//    </body>
//

import Foundation

public enum ToolbarRenderer {

    // MARK: - CSS

    /// Full toolbar CSS: layout, dark/light themes, and the CSS-only toggle.
    /// Embed inside a `<style>` block in `<head>`.
    public static let css = """
        html { height: 100%; }
        body {
            height: 100%;
            margin: 0;
            padding: 0;
            display: flex;
            flex-direction: column;
        }

        /* ── Radio/checkbox inputs: hidden but functional ─────────────── */
        #ql-radio-preview,
        #ql-radio-code,
        #ql-wrap { display: none; }

        /* ── CSS-only view toggle ─────────────────────────────────────── */
        /* Default: preview visible, code hidden */
        #ql-view-code { display: none; }

        /* When code radio is selected */
        #ql-radio-code:checked ~ #ql-content #ql-view-preview { display: none; }
        #ql-radio-code:checked ~ #ql-content #ql-view-code    { display: block; }

        /* ── Word wrap toggle ─────────────────────────────────────────── */
        /* Each .line has --line-indent set by Swift (leading whitespace width
           in ch units). padding-left + negative text-indent creates a hanging
           indent so continuation lines align with the first non-space character. */
        #ql-wrap:checked ~ #ql-content .line {
            white-space: pre-wrap;
            padding-left: var(--line-indent, 0ch);
            text-indent: calc(-1 * var(--line-indent, 0ch));
        }

        /* ── Toolbar ──────────────────────────────────────────────────── */
        /* Chrome shades derive from the active VS Code theme via color-mix:
           --md-bg and --md-fg are set by MarkdownRenderer on <body> from
           theme.background / theme.foreground. All toolbar colors are
           foreground-tinted overlays on the page bg, so they track any
           theme (light, dark, Solarized, Dracula, …) automatically. */
        #ql-toolbar {
            flex-shrink: 0;

            background: color-mix(in srgb, var(--md-fg) 6%, var(--md-bg));
            -webkit-backdrop-filter: blur(20px) saturate(180%);
            border-bottom: 1px solid color-mix(in srgb, var(--md-fg) 10%, var(--md-bg));
            display: flex;
            align-items: center;
            justify-content: flex-end;
            padding: 2px 8px 4px;
            gap: 8px;
        }
        #ql-content {
            flex: 1;
            overflow: auto;
            position: relative;  /* positioning context for .ql-wrap-btn */
        }
        #ql-view-code { position: relative; }

        /* ── Pill / segmented control ─────────────────────────────────── */
        .ql-pill {
            display: flex;
            background: color-mix(in srgb, var(--md-fg) 8%, transparent);
            border-radius: 6px;
            padding: 2px;
            gap: 1px;
        }
        .ql-pill label {
            display: inline-block;
            background: transparent;
            color: color-mix(in srgb, var(--md-fg) 50%, var(--md-bg));
            font-size: 12px;
            font-weight: 500;
            padding: 3px 12px;
            border-radius: 4px;
            cursor: pointer;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            letter-spacing: 0.01em;
            user-select: none;
        }

        /* Default active: Preview label */
        #ql-btn-preview {
            background: color-mix(in srgb, var(--md-fg) 14%, transparent);
            color: color-mix(in srgb, var(--md-fg) 92%, var(--md-bg));
        }

        /* When code radio is checked: Code becomes active, Preview becomes inactive */
        #ql-radio-code:checked ~ #ql-toolbar #ql-btn-preview {
            background: transparent;
            color: color-mix(in srgb, var(--md-fg) 50%, var(--md-bg));
        }
        #ql-radio-code:checked ~ #ql-toolbar #ql-btn-code {
            background: color-mix(in srgb, var(--md-fg) 14%, transparent);
            color: color-mix(in srgb, var(--md-fg) 92%, var(--md-bg));
        }

        /* Hover: only the inactive button gets a hover highlight */
        #ql-radio-preview:checked ~ #ql-toolbar #ql-btn-code:hover,
        #ql-radio-code:checked   ~ #ql-toolbar #ql-btn-preview:hover {
            background: color-mix(in srgb, var(--md-fg) 6%, transparent);
            color: color-mix(in srgb, var(--md-fg) 70%, var(--md-bg));
        }

        /* ── Wrap button (fixed overlay, top-right edge) ──────────────── */
        /* position: fixed anchors to the viewport so the button doesn't
           scroll with content. The element stays inside #ql-content /
           #ql-view-code so that markdown's `display:none` subtree hides it
           in preview mode without extra CSS.
           Dark vs light palette is chosen by the active code theme's isDark
           flag (see ToolbarRenderer.wrapColorVariables). */
        .ql-wrap-btn {
            position: fixed;
            top: 6px;
            right: 6px;
            z-index: 10;
            display: inline-flex;
            align-items: center;
            background: var(--wrap-bg);
            color: var(--wrap-fg);
            font-size: 13px;
            font-weight: 400;
            padding: 0px 5px;
            border-radius: 6px;
            border: 1px solid var(--wrap-border);
            box-shadow: var(--wrap-shadow);
            cursor: pointer;
            font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
            letter-spacing: 0.01em;
            user-select: none;
        }
        .ql-wrap-btn:hover {
            background: var(--wrap-bg-hover);
            box-shadow: var(--wrap-shadow-hover);
        }
        /* Checked state — :has() is used because, in markdown, the label
           lives inside #ql-view-code and is no longer a DOM sibling of the
           #ql-wrap checkbox, so the old `#ql-wrap:checked ~ .ql-wrap-btn`
           sibling selector wouldn't reach it. */
        body:has(#ql-wrap:checked) .ql-wrap-btn {
            background: var(--wrap-bg-checked);
            color: var(--wrap-fg-checked);
            border-color: var(--wrap-border-checked);
        }

        /* Markdown pages have a toolbar (~32px tall); push the button below it. */
        body:has(#ql-toolbar) .ql-wrap-btn { top: 40px; }

        /* ── Narrow viewport (Column View preview pane) ───────────────── */
        /* Shrink everything uniformly and drop the toolbar. Layout reflows
           at the zoomed scale, so wrapping and flex still work. */
        @media (max-width: 480px) {
            html { zoom: 0.5; }
            #ql-toolbar { display: none; }
            .ql-wrap-btn { display: none; }
        }
        """

    // MARK: - HTML

    /// Two hidden radio inputs that power the CSS-only view toggle.
    /// Must appear before `#ql-toolbar` and `#ql-content` in `<body>` so the
    /// `~` sibling selector can reach them. Markdown only.
    public static let toggleInputsHTML = """
        <input type="radio" name="ql-view" id="ql-radio-preview" checked>
        <input type="radio" name="ql-view" id="ql-radio-code">
        """

    /// Hidden checkbox that powers the CSS-only word-wrap toggle.
    /// Must appear before `.ql-wrap-btn` and `#ql-content` in `<body>`.
    public static let wordWrapCheckboxHTML =
        "<input type=\"checkbox\" id=\"ql-wrap\">"

    /// Fixed-position wrap button pinned to the top-right of the viewport.
    /// Place after `wordWrapCheckboxHTML` so the `~` selector can style it.
    public static let wordWrapOverlayHTML =
        "<label for=\"ql-wrap\" class=\"ql-wrap-btn\">Wrap</label>"

    /// The top toolbar with the Preview/Code pill. Markdown only.
    public static let toolbarHTML = """
        <div id="ql-toolbar">
          <div class="ql-pill" role="group" aria-label="View mode">
            <label for="ql-radio-preview" id="ql-btn-preview">Preview</label>
            <label for="ql-radio-code" id="ql-btn-code">Code</label>
          </div>
        </div>
        """

    // MARK: - Theme-driven wrap overlay colors

    /// Returns the wrap overlay's `--wrap-*` CSS custom properties. The
    /// active code theme's `isDark` flag picks between the dark and light
    /// palettes — the palettes themselves are fixed. Embed inside a
    /// `:root { … }` (or `body { … }`) rule so the CSS in
    /// `ToolbarRenderer.css` can resolve `var(--wrap-*)`.
    public static func wrapColorVariables(for theme: ThemeData) -> String {
        let vars: [String]
        if theme.isDark {
            vars = [
                // Lifted well above typical dark code backgrounds (≈ rgb 20–40)
                // so the overlay never blends in. Checked state uses a
                // subtle blue tint so the accent-blue text stays readable.
                "--wrap-bg:rgb(68,68,72)",
                "--wrap-bg-hover:rgb(84,84,88)",
                "--wrap-bg-checked:rgb(26,48,78)",
                "--wrap-fg:rgb(225,225,225)",
                "--wrap-fg-checked:#0a84ff",
                "--wrap-border:rgb(96,96,100)",
                "--wrap-border-checked:rgb(40,100,170)",
                // Subtle white rim + soft dark seat below — black-only drops
                // disappear against dark surfaces, so we add a hairline light
                // rim for elevation. Hover bumps both.
                "--wrap-shadow:0 0 0 1px rgba(255,255,255,0.06), 0 3px 12px rgba(0,0,0,0.5)",
                "--wrap-shadow-hover:0 0 0 1px rgba(255,255,255,0.1), 0 5px 18px rgba(0,0,0,0.6)"
            ]
        } else {
            vars = [
                // Near-white tile with a soft drop shadow — on light code
                // backgrounds the shadow does the lifting, not bg contrast.
                // Checked = subtle blue tint + accent-blue text.
                "--wrap-bg:rgb(252,252,253)",
                "--wrap-bg-hover:rgb(242,242,244)",
                "--wrap-bg-checked:rgb(222,234,252)",
                "--wrap-fg:rgb(64,64,64)",
                "--wrap-fg-checked:#007aff",
                "--wrap-border:rgb(210,210,214)",
                "--wrap-border-checked:rgb(141,190,243)",
                // Whisper-soft: two layered, low-opacity drops. Just enough
                // to separate the tile from the page without visible smudge.
                "--wrap-shadow:0 1px 2px rgba(0,0,0,0.06), 0 2px 8px rgba(0,0,0,0.06)",
                "--wrap-shadow-hover:0 1px 3px rgba(0,0,0,0.08), 0 4px 12px rgba(0,0,0,0.08)"
            ]
        }
        return vars.joined(separator: ";")
    }
}
