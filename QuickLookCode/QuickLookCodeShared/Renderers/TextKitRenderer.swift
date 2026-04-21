//
//  TextKitRenderer.swift
//  QuickLookCodeShared
//
//  Converts tokenized source-code lines into an NSAttributedString for display
//  in an NSTextView. This is the TextKit counterpart to HTMLRenderer — it
//  produces native attributed text instead of an HTML document.
//

import AppKit

// MARK: - TextKitRenderer

public enum TextKitRenderer {

    /// Builds an NSAttributedString from tokenized lines.
    ///
    /// - Parameters:
    ///   - lines: One array of RawToken per source line.
    ///   - theme: Active VS Code theme supplying background / foreground colors.
    ///   - font: Monospaced font to use for all text.
    ///   - truncationNote: When non-nil, appended as a muted trailing line.
    public static func attributedString(
        lines: [[SourceCodeRenderer.RawToken]],
        theme: ThemeData,
        font: NSFont,
        truncationNote: String? = nil
    ) -> NSAttributedString {
        let defaultFg = NSColor(cssHex: theme.foreground) ?? .labelColor
        let bgColor   = NSColor(cssHex: theme.background) ?? .textBackgroundColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.4

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: defaultFg,
            .backgroundColor: bgColor,
            .paragraphStyle:  paragraphStyle,
        ]

        let result = NSMutableAttributedString()

        for (lineIdx, tokens) in lines.enumerated() {
            // Build a per-line paragraph style that sets headIndent to the visual
            // width of the line's leading whitespace, so wrapped continuation lines
            // align with the first non-space character (matching the CSS
            // padding-left / text-indent hanging-indent from the old WebView path).
            let indent = leadingIndentWidth(tokens: tokens, font: font)
            let lineStyle: NSParagraphStyle
            if indent > 0 {
                let ps = NSMutableParagraphStyle()
                ps.lineHeightMultiple  = 1.4
                ps.firstLineHeadIndent = 0
                ps.headIndent          = indent
                lineStyle = ps
            } else {
                lineStyle = paragraphStyle
            }

            for token in tokens {
                var attrs = baseAttrs
                attrs[.paragraphStyle] = lineStyle
                if let hex = token.color, let color = NSColor(cssHex: hex) {
                    attrs[.foregroundColor] = color
                }
                applyFontStyle(token.fontStyle, baseFont: font, to: &attrs)
                result.append(NSAttributedString(string: token.text, attributes: attrs))
            }
            if lineIdx < lines.count - 1 {
                var newlineAttrs = baseAttrs
                newlineAttrs[.paragraphStyle] = lineStyle
                result.append(NSAttributedString(string: "\n", attributes: newlineAttrs))
            }
        }

        if let note = truncationNote {
            var mutedAttrs = baseAttrs
            let muted = defaultFg.withAlphaComponent(0.4)
            mutedAttrs[.foregroundColor] = muted
            result.append(NSAttributedString(string: "\n", attributes: baseAttrs))
            result.append(NSAttributedString(string: note, attributes: mutedAttrs))
        }

        return result
    }

    // MARK: - Helpers

    /// Returns the visual width in points of a line's leading whitespace.
    /// Spaces = 1 character width, tabs = 4 character widths (matching tab-size: 4).
    private static func leadingIndentWidth(
        tokens: [SourceCodeRenderer.RawToken],
        font: NSFont
    ) -> CGFloat {
        let charWidth = font.maximumAdvancement.width
        var width: CGFloat = 0
        outer: for token in tokens {
            for ch in token.text {
                switch ch {
                case " ":  width += charWidth
                case "\t": width += charWidth * 4
                default:   break outer
                }
            }
        }
        return width
    }

    private static func applyFontStyle(
        _ style: String?,
        baseFont: NSFont,
        to attrs: inout [NSAttributedString.Key: Any]
    ) {
        guard let style else { return }
        let fm = NSFontManager.shared
        var font = baseFont
        if style.contains("bold")   { font = fm.convert(font, toHaveTrait: .boldFontMask) }
        if style.contains("italic") { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        if font !== baseFont { attrs[.font] = font }
        if style.contains("underline") { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    }
}

// MARK: - NSColor hex initializer

public extension NSColor {

    /// Creates an NSColor from a CSS hex string: #RGB, #RRGGBB, or #RRGGBBAA.
    convenience init?(cssHex hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 3 {
            h = h.flatMap { [$0, $0] }.map(String.init).joined()
        }
        guard (h.count == 6 || h.count == 8), let n = UInt64(h, radix: 16) else { return nil }
        if h.count == 8 {
            self.init(
                red:   CGFloat((n >> 24) & 0xff) / 255,
                green: CGFloat((n >> 16) & 0xff) / 255,
                blue:  CGFloat((n >>  8) & 0xff) / 255,
                alpha: CGFloat( n        & 0xff) / 255
            )
        } else {
            self.init(
                red:   CGFloat((n >> 16) & 0xff) / 255,
                green: CGFloat((n >>  8) & 0xff) / 255,
                blue:  CGFloat( n        & 0xff) / 255,
                alpha: 1
            )
        }
    }
}
