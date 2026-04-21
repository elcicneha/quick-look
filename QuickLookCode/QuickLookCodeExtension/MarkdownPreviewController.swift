//
//  MarkdownPreviewController.swift
//  QuickLookCodeExtension
//
//  Container controller for Markdown files. Shows prose in a WKWebView (Preview
//  tab) and the raw markdown source in an NSTextView (Source tab). A native
//  NSSegmentedControl drives the switch — replacing the old CSS-only radio hack.
//

import Cocoa
import WebKit
import QuickLookCodeShared

final class MarkdownPreviewController: NSViewController {

    private var toolbarBar: NSView!
    private var toolbarSeparator: NSView!
    private var segmentedControl: NSSegmentedControl!
    private var webView: WKWebView!
    private var scrollView: NSScrollView!
    private var sourceTextView: NSTextView!
    private var wrapButton: NSButton!

    private var isSourceWrapping = false
    private var currentTheme: ThemeData?

    // MARK: - View setup

    override func loadView() {
        // ── NSSegmentedControl ────────────────────────────────────────────
        segmentedControl = NSSegmentedControl(
            labels: ["Preview", "Source"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabChanged)
        )
        segmentedControl.selectedSegment = 0
        segmentedControl.controlSize     = .small
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        // ── Toolbar bar ───────────────────────────────────────────────────
        toolbarBar = NSView()
        toolbarBar.wantsLayer = true
        toolbarBar.translatesAutoresizingMaskIntoConstraints = false
        toolbarBar.addSubview(segmentedControl)

        // Thin separator below the toolbar
        toolbarSeparator = NSView()
        toolbarSeparator.wantsLayer = true
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false

        // ── WKWebView (prose) ─────────────────────────────────────────────
        let config = WKWebViewConfiguration()
        config.processPool = SharedWebProcessPool.shared
        webView = WKWebView(frame: .zero, configuration: config)
        webView.wantsLayer = true
        webView.translatesAutoresizingMaskIntoConstraints = false

        // ── NSTextView (source) ───────────────────────────────────────────
        let textStorage   = NSTextStorage()
        let layoutMgr     = NSLayoutManager()
        textStorage.addLayoutManager(layoutMgr)
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        layoutMgr.addTextContainer(textContainer)

        sourceTextView = NSTextView(frame: .zero, textContainer: textContainer)
        sourceTextView.isEditable            = false
        sourceTextView.isSelectable          = true
        sourceTextView.isRichText            = false
        sourceTextView.drawsBackground       = true
        sourceTextView.isHorizontallyResizable = true
        sourceTextView.isVerticallyResizable   = true
        sourceTextView.textContainerInset    = NSSize(width: 20, height: 16)
        sourceTextView.maxSize               = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                      height: CGFloat.greatestFiniteMagnitude)
        sourceTextView.autoresizingMask      = []

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true
        scrollView.borderType            = .noBorder
        scrollView.documentView          = sourceTextView
        scrollView.isHidden              = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // ── Wrap button for source tab ────────────────────────────────────
        wrapButton = WrapButton(title: "Wrap", target: self, action: #selector(toggleWrap))
        wrapButton.isBordered = false
        wrapButton.font       = NSFont.systemFont(ofSize: 11, weight: .regular)
        wrapButton.wantsLayer = true
        wrapButton.layer?.cornerRadius = 4
        wrapButton.isHidden   = true
        wrapButton.translatesAutoresizingMaskIntoConstraints = false

        // ── Root layout ───────────────────────────────────────────────────
        let root = NSView()
        root.wantsLayer = true
        root.addSubview(toolbarBar)
        root.addSubview(toolbarSeparator)
        root.addSubview(webView)
        root.addSubview(scrollView)
        root.addSubview(wrapButton)

        NSLayoutConstraint.activate([
            // Toolbar
            toolbarBar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarBar.heightAnchor.constraint(equalToConstant: 34),

            segmentedControl.centerXAnchor.constraint(equalTo: toolbarBar.centerXAnchor),
            segmentedControl.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),

            // Separator
            toolbarSeparator.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor),
            toolbarSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarSeparator.heightAnchor.constraint(equalToConstant: 1),

            // WebView (prose)
            webView.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // ScrollView (source) — same slot as WebView
            scrollView.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Wrap button: top-right of source view
            wrapButton.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor, constant: 6),
            wrapButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
        ])

        self.view = root
    }

    // MARK: - Content

    /// Loads prose HTML into the WKWebView and applies theme colors to the toolbar.
    func showProse(html: String, theme: ThemeData) {
        currentTheme = theme
        webView.loadHTMLString(html, baseURL: nil)
        applyToolbarTheme(theme)
    }

    /// Shows plain-text in the source NSTextView while deferred tokenization runs.
    func showSourcePlaceholder(_ text: String, theme: ThemeData) {
        let font    = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bgColor = NSColor(cssHex: theme.background) ?? .textBackgroundColor
        let fgColor = NSColor(cssHex: theme.foreground) ?? .labelColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.4
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            font,
            .foregroundColor: fgColor,
            .backgroundColor: bgColor,
            .paragraphStyle:  paragraphStyle,
        ]
        sourceTextView.backgroundColor = bgColor
        scrollView.backgroundColor     = bgColor
        sourceTextView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: attrs)
        )
    }

    /// Replaces source tab content with syntax-highlighted attributed string.
    func showSource(tokens: [[SourceCodeRenderer.RawToken]], theme: ThemeData) {
        let font    = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bgColor = NSColor(cssHex: theme.background) ?? .textBackgroundColor
        let attrStr = TextKitRenderer.attributedString(lines: tokens, theme: theme, font: font)
        sourceTextView.backgroundColor = bgColor
        scrollView.backgroundColor     = bgColor
        sourceTextView.textStorage?.setAttributedString(attrStr)
        if segmentedControl.selectedSegment == 1 {
            sourceTextView.scrollToBeginningOfDocument(nil)
        }
    }

    // MARK: - Tab switching

    @objc private func tabChanged() {
        let showSource = segmentedControl.selectedSegment == 1
        webView.isHidden    = showSource
        scrollView.isHidden = !showSource
        wrapButton.isHidden = !showSource
        if !showSource { wrapButton.isHidden = true }
    }

    // MARK: - Wrap toggle (source tab only)

    @objc private func toggleWrap() {
        isSourceWrapping.toggle()
        applyWrapState()
        styleWrapButton()
    }

    private func applyWrapState() {
        guard let container = sourceTextView.textContainer else { return }
        if isSourceWrapping {
            let w = scrollView.contentSize.width
            container.widthTracksTextView          = true
            container.containerSize                = NSSize(width: w, height: .greatestFiniteMagnitude)
            sourceTextView.isHorizontallyResizable = false
            sourceTextView.autoresizingMask        = [.width]
            sourceTextView.setFrameSize(NSSize(width: w, height: sourceTextView.frame.height))
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView          = false
            container.containerSize                = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                             height: CGFloat.greatestFiniteMagnitude)
            sourceTextView.isHorizontallyResizable = true
            sourceTextView.autoresizingMask        = []
            scrollView.hasHorizontalScroller = true
        }
        sourceTextView.sizeToFit()
    }

    // MARK: - Styling

    private func applyToolbarTheme(_ theme: ThemeData) {
        let bg = NSColor(cssHex: theme.background) ?? (theme.isDark ? .black : .white)
        // Slightly separate toolbar from content using a small brightness shift
        let toolbarBg: NSColor = theme.isDark
            ? bg.blended(withFraction: 0.06, of: .white) ?? bg
            : bg.blended(withFraction: 0.04, of: .black) ?? bg
        let separatorColor: NSColor = theme.isDark
            ? bg.blended(withFraction: 0.12, of: .white) ?? bg
            : bg.blended(withFraction: 0.10, of: .black) ?? bg
        toolbarBar.layer?.backgroundColor       = toolbarBg.cgColor
        toolbarSeparator.layer?.backgroundColor = separatorColor.cgColor
        view.layer?.backgroundColor             = bg.cgColor
        // Force the whole view tree to use the matching appearance so the
        // segmented control (and any other system-drawn widgets) pick up dark/light
        // from the VS Code theme rather than the macOS system setting.
        view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        styleWrapButton()
    }

    private func styleWrapButton() {
        let isDark = currentTheme?.isDark ?? true
        let bg: NSColor
        let fg: NSColor
        if isDark {
            bg = isSourceWrapping ? NSColor(red: 0.10, green: 0.19, blue: 0.31, alpha: 1)
                                  : NSColor(white: 0.27, alpha: 1)
            fg = isSourceWrapping ? NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
                                  : NSColor(white: 0.88, alpha: 1)
        } else {
            bg = isSourceWrapping ? NSColor(red: 0.87, green: 0.92, blue: 0.99, alpha: 1)
                                  : NSColor(white: 0.99, alpha: 1)
            fg = isSourceWrapping ? NSColor(red: 0, green: 0.48, blue: 1, alpha: 1)
                                  : NSColor(white: 0.25, alpha: 1)
        }
        wrapButton.layer?.backgroundColor = bg.cgColor
        wrapButton.attributedTitle = NSAttributedString(
            string: "Wrap",
            attributes: [
                .foregroundColor: fg,
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            ]
        )
    }
}
