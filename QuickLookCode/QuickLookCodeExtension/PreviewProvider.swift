//
//  PreviewProvider.swift
//  QuickLookCodeExtension
//

import Cocoa
import Quartz
import QuickLookCodeShared

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url      = request.fileURL
        let fileName = url.lastPathComponent
        let ext      = url.pathExtension

        let htmlData = await renderHTML(fileURL: url, fileName: fileName, ext: ext)

        // Content size is used as the initial window size; HTML content is scrollable.
        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 900, height: 600)
        ) { _ in htmlData }

        return reply
    }

    // MARK: - Render pipeline

    /// Attempts syntax-highlighted rendering; falls back to plain text on any failure.
    private func renderHTML(fileURL: URL, fileName: String, ext: String) async -> Data {
        // Markdown short-circuit — before FileTypeRegistry lookup
        if ext == "md" || ext == "markdown" {
            return await renderMarkdown(fileURL: fileURL, fileName: fileName)
        }

        // 1. Identify language
        guard let langInfo = FileTypeRegistry.language(forExtension: ext) else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Unsupported file type")
        }

        // 2. Find IDE
        guard let ide = IDELocator.preferred else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "VS Code not found")
        }

        // 3. Load grammar
        let grammarLoader = GrammarLoader(ide: ide)
        guard let grammar = (try? grammarLoader.grammarData(for: langInfo.grammarSearch)) ?? nil else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Grammar not found for \(langInfo.displayName)")
        }
        let siblingGrammars = grammarLoader.siblingGrammarData(for: langInfo.grammarSearch)

        // 4. Load theme
        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded")
        }

        // 5. Tokenize + render
        do {
            return try await SourceCodeRenderer.render(
                fileURL: fileURL,
                grammarData: grammar,
                siblingGrammars: siblingGrammars,
                theme: theme,
                languageInfo: langInfo,
                fileName: fileName
            )
        } catch {
            // Tokenizer failed (e.g. bundle not yet built) — fall back gracefully.
            return plainText(fileURL: fileURL, fileName: fileName, reason: error.localizedDescription)
        }
    }

    // MARK: - Markdown rendering

    private func renderMarkdown(fileURL: URL, fileName: String) async -> Data {
        guard let ide = IDELocator.preferred else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "VS Code not found")
        }
        guard let theme = try? ThemeLoader.loadActiveTheme(from: ide) else {
            return plainText(fileURL: fileURL, fileName: fileName, reason: "Theme could not be loaded")
        }
        do {
            return try await MarkdownRenderer.render(
                fileURL: fileURL,
                theme: theme,
                ide: ide,
                fileName: fileName
            )
        } catch {
            return plainText(fileURL: fileURL, fileName: fileName, reason: error.localizedDescription)
        }
    }

    // MARK: - Plain text fallback

    private func plainText(fileURL: URL, fileName: String, reason: String) -> Data {
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

        let html = """
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
        return Data(html.utf8)
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
