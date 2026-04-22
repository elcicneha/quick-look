//
//  PreviewViewController.swift
//  QuickLookCodeExtension
//

import Cocoa
import Quartz
import QuickLookCodeShared

class PreviewViewController: NSViewController, QLPreviewingController {

    private var activeChild: NSViewController?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        self.view = container
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        // Pre-warm TokenizerEngine in parallel with the render path so the
        // 60–150 ms JSContext + bundle eval cost overlaps with bootstrap /
        // theme load instead of serializing behind them.
        Task.detached(priority: .userInitiated) { CacheManager.prewarmTokenizer() }

        // Ensure the cache is populated before rendering. No-op on hot paths.
        CacheManager.bootstrap()

        if Task.isCancelled { return }

        let ext = url.pathExtension.lowercased()

        if ext == "md" || ext == "markdown" {
            await renderMarkdown(fileURL: url, fileName: url.lastPathComponent)
        } else {
            await renderCode(fileURL: url, fileName: url.lastPathComponent, ext: ext)
        }
    }

    // MARK: - Child VC management

    private func installChild(_ vc: NSViewController) {
        activeChild?.view.removeFromSuperview()
        activeChild?.removeFromParent()
        activeChild = vc

        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.width, .height]
        view.addSubview(vc.view)
    }

    // MARK: - Code render path

    private func renderCode(fileURL: URL, fileName: String, ext: String) async {
        // Resolve by file extension; fall back to exact filename match (Dockerfile, Makefile, ...).
        let entry = LanguageIndex.entry(forExtension: ext)
            ?? LanguageIndex.entry(forFilename: fileURL.lastPathComponent)
        guard let entry else {
            await showPlainTextFallback(fileURL: fileURL, fileName: fileName, reason: "Unsupported file type")
            return
        }
        guard let ide = IDELocator.preferred else {
            await showPlainTextFallback(fileURL: fileURL, fileName: fileName, reason: "VS Code not found")
            return
        }
        guard let grammar = LanguageIndex.grammarData(for: entry) else {
            await showPlainTextFallback(fileURL: fileURL, fileName: fileName, reason: "Grammar not found for \(entry.displayName)")
            return
        }
        let siblingGrammars = LanguageIndex.supportingGrammars(for: entry)
        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            await showPlainTextFallback(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded")
            return
        }

        if Task.isCancelled { return }

        let (content, truncationNote) = SourceCodeRenderer.readFile(at: fileURL)

        let codeVC = NativeCodePreviewController()
        await MainActor.run {
            installChild(codeVC)
            codeVC.showPlainText(content, theme: theme)
        }

        if Task.isCancelled { return }

        guard let tokens = try? await SourceCodeRenderer.tokenize(
            code: content,
            language: entry.languageId,
            grammarData: grammar,
            siblingGrammars: siblingGrammars,
            injections: LanguageIndex.injectionsForTarget,
            theme: theme
        ) else { return }

        if Task.isCancelled { return }

        await MainActor.run { [weak codeVC] in
            codeVC?.display(tokens: tokens, theme: theme, truncationNote: truncationNote)
        }
    }

    // MARK: - Markdown render path

    private func renderMarkdown(fileURL: URL, fileName: String) async {
        guard let ide = IDELocator.preferred else {
            await showPlainTextFallback(fileURL: fileURL, fileName: fileName, reason: "VS Code not found")
            return
        }
        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            await showPlainTextFallback(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded")
            return
        }

        if Task.isCancelled { return }

        guard
            let result = try? await MarkdownRenderer.render(
                fileURL: fileURL,
                theme: theme,
                fileName: fileName
            ),
            let html = String(data: result.html, encoding: .utf8)
        else {
            await showPlainTextFallback(fileURL: fileURL, fileName: fileName, reason: "Markdown render failed")
            return
        }

        let mdVC = MarkdownPreviewController()
        let markdown = result.markdown
        await MainActor.run {
            installChild(mdVC)
            mdVC.showProse(html: html, theme: theme)
            mdVC.showSourcePlaceholder(markdown, theme: theme)
        }

        if Task.isCancelled { return }

        // Deferred: tokenize the markdown source for the native Source tab.
        if let tokens = await MarkdownRenderer.tokenizeSource(markdown: markdown, theme: theme) {
            if Task.isCancelled { return }
            await MainActor.run { [weak mdVC] in
                mdVC?.showSource(tokens: tokens, theme: theme)
            }
        }
    }

    // MARK: - Plain-text fallback

    private func showPlainTextFallback(fileURL: URL, fileName: String, reason: String) async {
        let content: String
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let lines = text.components(separatedBy: "\n")
            content = lines.prefix(SourceCodeRenderer.maxLines).joined(separator: "\n")
        } else {
            content = "// Could not read file."
        }

        let fallbackTheme = ThemeData(
            name: "Fallback",
            isDark: true,
            background: "#1e1e1e",
            foreground: "#d4d4d4",
            tokenColors: []
        )

        let codeVC = NativeCodePreviewController()
        await MainActor.run {
            installChild(codeVC)
            codeVC.showPlainText("// \(reason) — showing plain text\n\n\(content)", theme: fallbackTheme)
        }
    }
}
