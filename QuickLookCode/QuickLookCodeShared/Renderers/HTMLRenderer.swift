//
//  HTMLRenderer.swift
//  QuickLookCodeShared
//

import Foundation

/// Assembles the final syntax-highlighted HTML page from token spans and theme data.
public enum HTMLRenderer {

    // MARK: - Public Types

    public struct TokenSpan {
        public let text: String
        public let color: String?       // hex e.g. "#569cd6", nil = use foreground default
        public let isBold: Bool
        public let isItalic: Bool
        public let isUnderline: Bool

        public init(text: String, color: String?, fontStyle: String?) {
            self.text = text
            self.color = color
            let style = fontStyle ?? ""
            self.isBold      = style.contains("bold")
            self.isItalic    = style.contains("italic")
            self.isUnderline = style.contains("underline")
        }
    }

    // MARK: - Public API

    /// Renders token lines into a complete, self-contained HTML document.
    ///
    /// - Parameters:
    ///   - lines: One entry per source line; each entry is the ordered token spans for that line.
    ///   - theme: Active VS Code theme supplying background / foreground colors.
    ///   - languageDisplayName: Shown in the `<title>` tag (purely cosmetic).
    ///   - fileName: Shown in the `<title>` tag.
    ///   - font: CSS font-family stack for the `<pre>` block.
    ///   - fontSize: Font size in pixels.
    ///   - showLineNumbers: When true, a right-aligned, non-selectable gutter column is rendered.
    ///   - truncationNote: When non-nil, appended as a styled comment after the last code line.
    public static func render(
        lines: [[TokenSpan]],
        theme: ThemeData,
        languageDisplayName: String,
        fileName: String,
        font: String = "ui-monospace, 'SF Mono', Menlo, Monaco, Consolas, 'Courier New', monospace",
        fontSize: Int = 13,
        showLineNumbers: Bool = false,
        truncationNote: String? = nil
    ) -> String {
        let bg = theme.background
        let fg = theme.foreground

        let gutterColor = mutedColor(over: bg, isDark: theme.isDark)

        // Build all <span class="line">…</span> blocks
        var lineBlocks: [String] = lines.enumerated().map { (index, spans) in
            let content = spans.map { spanHTML($0) }.joined()
            let indent = leadingIndentWidth(spans)
            let indentStyle = indent > 0 ? " style=\"--line-indent:\(indent)ch\"" : ""
            if showLineNumbers {
                let num = index + 1
                return "<span class=\"line\"\(indentStyle)><span class=\"ln\" aria-hidden=\"true\">\(num)</span>\(content)</span>"
            }
            return "<span class=\"line\"\(indentStyle)>\(content)</span>"
        }

        if let note = truncationNote {
            let escaped = escapeHTML(note)
            lineBlocks.append("<span class=\"line\"><span class=\"trunc\">\(escaped)</span></span>")
        }

        let codeHTML = lineBlocks.joined(separator: "")

        let lineNumberCSS: String
        if showLineNumbers {
            lineNumberCSS = """
                .ln {
                    display: inline-block;
                    min-width: 2.5em;
                    margin-right: 1.5em;
                    text-align: right;
                    color: \(gutterColor);
                    user-select: none;
                    pointer-events: none;
                }
                """
        } else {
            lineNumberCSS = ""
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(fileName)) — \(escapeHTML(languageDisplayName))</title>
        <style>
        *, *::before, *::after { box-sizing: border-box; }
        \(ToolbarRenderer.css)
        :root { \(ToolbarRenderer.wrapColorVariables(for: theme)) }
        body {
            font-family: \(font);
            font-size: \(fontSize)px;
            line-height: 1.6;
            background: \(bg);
            color: \(fg);
        }
        #ql-content {
            background: \(bg);
            color: \(fg);
        }
        pre {
            margin: 0;
            padding: 16px 20px;
            tab-size: 4;
            -moz-tab-size: 4;
        }
        code { display: block; }
        .line {
            display: block;
            min-height: 1.6em;
            white-space: pre;
        }
        .trunc {
            color: \(gutterColor);
            font-style: italic;
        }
        \(lineNumberCSS)
        </style>
        </head>
        <body>
        \(ToolbarRenderer.wordWrapCheckboxHTML)
        <div id="ql-content">
        \(ToolbarRenderer.wordWrapOverlayHTML)
        <pre><code>\(codeHTML)</code></pre>
        </div>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    /// Counts the visual width of leading whitespace in character units (ch).
    /// Spaces = 1ch each, tabs = 4ch each (matching `tab-size: 4` in CSS).
    private static func leadingIndentWidth(_ spans: [TokenSpan]) -> Int {
        var width = 0
        outer: for span in spans {
            for ch in span.text {
                switch ch {
                case " ":  width += 1
                case "\t": width += 4
                default:   break outer
                }
            }
        }
        return width
    }

    private static func spanHTML(_ span: TokenSpan) -> String {
        let escaped = escapeHTML(span.text)
        guard span.color != nil || span.isBold || span.isItalic || span.isUnderline else {
            return escaped
        }
        var styles: [String] = []
        if let c = span.color            { styles.append("color:\(c)") }
        if span.isBold                   { styles.append("font-weight:bold") }
        if span.isItalic                 { styles.append("font-style:italic") }
        if span.isUnderline              { styles.append("text-decoration:underline") }
        return "<span style=\"\(styles.joined(separator: ";"))\">\(escaped)</span>"
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Returns a muted hex color for gutter / truncation text over `bg`.
    private static func mutedColor(over bg: String, isDark: Bool) -> String {
        // Try to parse the background and mix toward the midpoint.
        var h = bg.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        if h.count == 6, let rgb = UInt64(h, radix: 16) {
            let r = (rgb >> 16) & 0xff
            let g = (rgb >> 8)  & 0xff
            let b =  rgb        & 0xff
            // Mix 50% toward mid-grey (128)
            let mr = (r + 128) / 2
            let mg = (g + 128) / 2
            let mb = (b + 128) / 2
            return String(format: "#%02x%02x%02x", mr, mg, mb)
        }
        return isDark ? "#555566" : "#aaaaaa"
    }
}
