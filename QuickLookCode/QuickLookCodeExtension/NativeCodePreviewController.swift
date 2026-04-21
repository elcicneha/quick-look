//
//  NativeCodePreviewController.swift
//  QuickLookCodeExtension
//
//  NSTextView-based preview controller for code files. Replaces the WKWebView
//  path from the pre-Phase-3 architecture.
//

import Cocoa
import QuickLookCodeShared

// Borderless button for the wrap toggle.
final class WrapButton: NSButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width  += 8
        size.height += 6
        return size
    }
}

final class NativeCodePreviewController: NSViewController {

    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var wrapButton: NSButton!
    private var isWrapping = false
    private var currentTheme: ThemeData?

    // MARK: - View setup

    override func loadView() {
        // TextKit layout stack: explicit NSTextStorage / NSLayoutManager / NSTextContainer
        // so we can control wrapping via the container size.
        let textStorage = NSTextStorage()
        let layoutMgr   = NSLayoutManager()
        textStorage.addLayoutManager(layoutMgr)

        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        layoutMgr.addTextContainer(textContainer)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable           = false
        textView.isSelectable         = true
        textView.isRichText           = false
        textView.drawsBackground      = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable   = true
        textView.textContainerInset   = NSSize(width: 20, height: 16)
        textView.maxSize              = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                               height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask     = []

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .noBorder
        scrollView.documentView          = textView

        // Wrap toggle button — borderless so we fully control colors via layer + attributedTitle.
        wrapButton = WrapButton(title: "Wrap", target: self, action: #selector(toggleWrap))
        wrapButton.isBordered = false
        wrapButton.font       = NSFont.systemFont(ofSize: 13, weight: .regular)
        wrapButton.wantsLayer = true
        wrapButton.layer?.cornerRadius = 4
        wrapButton.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        root.addSubview(wrapButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            wrapButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            wrapButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
        ])

        self.view = root
    }

    // MARK: - Content

    /// Shows a plain-text placeholder immediately while tokenization runs in background.
    func showPlainText(_ text: String, theme: ThemeData) {
        currentTheme = theme
        let font    = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bgColor = NSColor(cssHex: theme.background) ?? .textBackgroundColor
        let fgColor = NSColor(cssHex: theme.foreground) ?? .labelColor
        applyBackground(bgColor)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.4
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: fgColor,
            .backgroundColor: bgColor,
            .paragraphStyle:  paragraphStyle,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        textView.scrollToBeginningOfDocument(nil)
        styleWrapButton()
    }

    /// Replaces content with syntax-highlighted attributed string.
    func display(
        tokens: [[SourceCodeRenderer.RawToken]],
        theme: ThemeData,
        truncationNote: String?
    ) {
        currentTheme = theme
        let font    = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bgColor = NSColor(cssHex: theme.background) ?? .textBackgroundColor
        let attrStr = TextKitRenderer.attributedString(
            lines: tokens, theme: theme, font: font, truncationNote: truncationNote
        )
        applyBackground(bgColor)
        textView.textStorage?.setAttributedString(attrStr)
        textView.scrollToBeginningOfDocument(nil)
        styleWrapButton()
    }

    // MARK: - Wrap toggle

    @objc private func toggleWrap() {
        isWrapping.toggle()
        applyWrapState()
        styleWrapButton()
    }

    private func applyWrapState() {
        guard let container = textView.textContainer else { return }
        if isWrapping {
            let w = scrollView.contentSize.width
            container.widthTracksTextView    = true
            container.containerSize          = NSSize(width: w, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.autoresizingMask        = [.width]
            // Explicitly resize to the clip width so the layout manager re-wraps lines.
            textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView    = false
            container.containerSize          = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask        = []
            scrollView.hasHorizontalScroller = true
        }
        textView.sizeToFit()
    }

    // MARK: - Helpers

    private func applyBackground(_ color: NSColor) {
        textView.backgroundColor    = color
        scrollView.backgroundColor  = color
        view.layer?.backgroundColor = color.cgColor
        if let theme = currentTheme {
            view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        }
    }

    private func styleWrapButton() {
        let isDark = currentTheme?.isDark ?? true
        let bg: NSColor
        let fg: NSColor
        if isDark {
            bg = isWrapping ? NSColor(red: 0.10, green: 0.19, blue: 0.31, alpha: 1)
                            : NSColor(white: 0.27, alpha: 1)
            fg = isWrapping ? NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
                            : NSColor(white: 0.88, alpha: 1)
        } else {
            bg = isWrapping ? NSColor(red: 0.87, green: 0.92, blue: 0.99, alpha: 1)
                            : NSColor(white: 0.99, alpha: 1)
            fg = isWrapping ? NSColor(red: 0, green: 0.48, blue: 1, alpha: 1)
                            : NSColor(white: 0.25, alpha: 1)
        }
        wrapButton.layer?.backgroundColor = bg.cgColor
        // attributedTitle is the only reliable way to set text color on a borderless NSButton.
        wrapButton.attributedTitle = NSAttributedString(
            string: "Wrap",
            attributes: [
                .foregroundColor: fg,
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            ]
        )
    }
}
