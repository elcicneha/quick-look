//
//  PreviewViewController.swift
//  QuickLookCodeExtension
//

import Cocoa
import Quartz
import WebKit
import QuickLookCodeShared

class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!
    private var pendingHTML: String?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        webView = WKWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let html = pendingHTML {
            webView.loadHTMLString(html, baseURL: nil)
            pendingHTML = nil
        }
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let html = await renderHTML(fileURL: url, fileName: url.lastPathComponent, ext: url.pathExtension)
        await MainActor.run {
            pendingHTML = html
            if webView.window != nil {
                webView.loadHTMLString(html, baseURL: nil)
                pendingHTML = nil
            }
        }
    }

    // MARK: - Render pipeline

    /// Attempts syntax-highlighted rendering; falls back to plain text on any failure.
    private func renderHTML(fileURL: URL, fileName: String, ext: String) async -> String {
        if ext == "md" || ext == "markdown" {
            return await renderMarkdown(fileURL: fileURL, fileName: fileName)
        }

        guard let langInfo = FileTypeRegistry.language(forExtension: ext) else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Unsupported file type")
        }

        guard let ide = IDELocator.preferred else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "VS Code not found")
        }

        let grammarLoader = GrammarLoader(ide: ide)
        guard let grammar = (try? grammarLoader.grammarData(for: langInfo.grammarSearch)) ?? nil else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Grammar not found for \(langInfo.displayName)")
        }
        let siblingGrammars = grammarLoader.siblingGrammarData(for: langInfo.grammarSearch)

        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded")
        }

        do {
            let data = try await SourceCodeRenderer.render(
                fileURL: fileURL,
                grammarData: grammar,
                siblingGrammars: siblingGrammars,
                theme: theme,
                languageInfo: langInfo,
                fileName: fileName
            )
            return String(data: data, encoding: .utf8) ?? plainText(fileURL: fileURL, fileName: fileName, reason: "Render produced invalid UTF-8")
        } catch {
            return plainText(fileURL: fileURL, fileName: fileName, reason: error.localizedDescription)
        }
    }

    private func renderMarkdown(fileURL: URL, fileName: String) async -> String {
        guard let ide = IDELocator.preferred else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "VS Code not found")
        }
        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded")
        }
        do {
            let data = try await MarkdownRenderer.render(
                fileURL: fileURL,
                theme: theme,
                ide: ide,
                fileName: fileName
            )
            return String(data: data, encoding: .utf8) ?? plainText(fileURL: fileURL, fileName: fileName, reason: "Markdown render produced invalid UTF-8")
        } catch {
            return plainText(fileURL: fileURL, fileName: fileName, reason: error.localizedDescription)
        }
    }

    // MARK: - Plain text fallback

    private func plainText(fileURL: URL, fileName: String, reason: String) -> String {
        let content: String
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            let lines = text.components(separatedBy: "\n")
            let capped = lines.prefix(SourceCodeRenderer.maxLines).joined(separator: "\n")
            content = capped
                .replacingOccurrences(of: "&",  with: "&amp;")
                .replacingOccurrences(of: "<",  with: "&lt;")
                .replacingOccurrences(of: ">",  with: "&gt;")
        } else {
            content = "// Could not read file."
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <style>
        *, *::before, *::after { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; background: #1e1e1e; color: #d4d4d4; }
        body { font-family: ui-monospace, 'SF Mono', Menlo, Monaco, monospace; font-size: 13px; }
        pre { margin: 0; padding: 16px 20px; line-height: 1.6; overflow: auto; }
        .note { color: #6a9955; font-style: italic; margin-bottom: 12px; }
        </style>
        </head>
        <body>
        <pre><div class="note">// \(escapeHTML(reason)) — showing plain text</div>\(content)</pre>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
