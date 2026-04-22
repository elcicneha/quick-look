//
//  MarkdownRenderer.swift
//  QuickLookCodeShared
//
//  Renders Markdown files as styled HTML using cmark-gfm for parsing and
//  vscode-textmate (via SourceCodeRenderer) for syntax-highlighted code blocks.
//
//  Prose follows the system light/dark appearance (CSS custom properties +
//  @media prefers-color-scheme). Fenced code blocks are highlighted with the
//  active VS Code theme via inline style= attributes, so they always look like
//  the editor regardless of system appearance.
//

import Foundation
import Darwin
import CCmarkGFM

// MARK: - Public API

public enum MarkdownRenderer {

    public enum RendererError: LocalizedError {
        case cssNotFound
        case fileUnreadable

        public var errorDescription: String? {
            switch self {
            case .cssNotFound:    return "markdown-styles.css not found in framework bundle"
            case .fileUnreadable: return "Could not read Markdown file"
            }
        }
    }

    /// Fast-path render output. `html` is the full self-contained document ready
    /// for `WKWebView.loadHTMLString`. `markdown` is the raw source the caller
    /// feeds into `tokenizeSource` to populate the native Source tab asynchronously.
    public struct RenderResult {
        public let html: Data
        public let markdown: String
    }

    /// Fast path: renders a Markdown file to a self-contained prose-only HTML
    /// document. The Source tab is handled natively by MarkdownPreviewController.
    /// The returned `markdown` string is fed into `tokenizeSource` to populate
    /// the native Source tab asynchronously.
    public static func render(
        fileURL: URL,
        theme: ThemeData,
        fileName: String
    ) async throws -> RenderResult {
        // 1. Read source
        guard let markdown = readMarkdown(at: fileURL) else {
            throw RendererError.fileUnreadable
        }

        // 2. Strip leading YAML/TOML/JSON front matter before parsing.
        // cmark-gfm has no front-matter extension; without stripping, a `---`
        // delimited block renders as `<hr>` + heading. The source view still
        // receives the original markdown (including front matter).
        let body = stripFrontMatter(markdown)

        // 3. Parse → HTML via cmark-gfm
        let rawHTML = parseGFM(body)

        // 3a. Inject id="slug" on every heading so in-document [..](#anchor)
        // links resolve. cmark-gfm doesn't do this itself.
        let anchoredHTML = addHeadingAnchors(in: rawHTML)

        // 4. Highlight fenced code blocks with VS Code theme
        let highlightedHTML = await highlightCodeBlocks(in: anchoredHTML, theme: theme)

        // 5. Resolve relative images → data URIs
        let resolvedHTML = resolveImages(in: highlightedHTML, baseURL: fileURL.deletingLastPathComponent())

        // 6. Load stylesheet
        guard
            let cssURL = Bundle(for: BundleAnchor.self).url(forResource: "markdown-styles", withExtension: "css"),
            let css = try? String(contentsOf: cssURL, encoding: .utf8)
        else {
            throw RendererError.cssNotFound
        }

        // 7. Assemble prose-only document (no Source tab; handled natively)
        let html = assembleHTML(body: resolvedHTML, css: css, fileName: fileName, theme: theme)
        return RenderResult(html: Data(html.utf8), markdown: markdown)
    }

    /// Tokenizes the raw markdown source for the native Source tab.
    ///
    /// Call this after the initial prose render so the JSContext cold-start cost
    /// overlaps with WKWebView layout/paint. Returns nil on any failure so the
    /// caller can keep the plain-text placeholder.
    public static func tokenizeSource(
        markdown: String,
        theme: ThemeData
    ) async -> [[SourceCodeRenderer.RawToken]]? {
        guard let entry = LanguageIndex.entry(forExtension: "md") else { return nil }
        guard let grammarData = LanguageIndex.grammarData(for: entry) else { return nil }

        // Load supporting grammars for markdown (same-extension siblings + injections
        // targeting `text.html.markdown` + those injections' siblings), plus per-fence
        // grammars so embedded code blocks tokenize with per-language colors.
        var siblingGrammars = LanguageIndex.supportingGrammars(for: entry)
        var loadedScopes = Set<String>()
        loadedScopes.insert(entry.scopeName)
        for lang in extractFencedLanguages(from: markdown) {
            guard let fencedEntry = LanguageIndex.entry(forFenceTag: lang) else { continue }
            guard !loadedScopes.contains(fencedEntry.scopeName) else { continue }
            loadedScopes.insert(fencedEntry.scopeName)
            if let gData = LanguageIndex.grammarData(for: fencedEntry) {
                siblingGrammars.append(gData)
                siblingGrammars.append(contentsOf: LanguageIndex.supportingGrammars(for: fencedEntry))
            }
        }

        return try? await SourceCodeRenderer.tokenize(
            code: markdown,
            language: entry.languageId,
            grammarData: grammarData,
            siblingGrammars: siblingGrammars,
            injections: LanguageIndex.injectionsForTarget,
            theme: theme
        )
    }

}

// MARK: - File reading

private extension MarkdownRenderer {

    static func readMarkdown(at url: URL) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attrs?[.size] as? Int) ?? 0
        let cap = SourceCodeRenderer.maxBytes

        let rawData: Data
        if byteCount > cap {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            rawData = handle.readData(ofLength: cap)
        } else {
            guard let data = try? Data(contentsOf: url) else { return nil }
            rawData = data
        }

        return String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .isoLatin1)
    }

    /// Strips a leading YAML (`---`), TOML (`+++`), or JSON (`;;;`) front
    /// matter block if one is present, matching the Jekyll/Hugo/Astro
    /// convention: the file must start with the delimiter on its own line,
    /// and a matching closing delimiter must appear on its own line later.
    /// If either condition fails, the input is returned unchanged so a
    /// legitimate leading `<hr>` still renders.
    static func stripFrontMatter(_ markdown: String) -> String {
        let delim: String
        if      markdown.hasPrefix("---\n") { delim = "---" }
        else if markdown.hasPrefix("+++\n") { delim = "+++" }
        else if markdown.hasPrefix(";;;\n") { delim = ";;;" }
        else { return markdown }

        let afterOpen = markdown.index(markdown.startIndex, offsetBy: 4)
        let closing = "\n\(delim)\n"
        guard let range = markdown.range(of: closing, range: afterOpen..<markdown.endIndex) else {
            return markdown
        }
        return String(markdown[range.upperBound...])
    }
}

// MARK: - cmark-gfm parsing

private extension MarkdownRenderer {

    static func parseGFM(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        let opts = Int32(CMARK_OPT_UNSAFE | CMARK_OPT_SMART)
        let parser = cmark_parser_new(opts)
        defer { cmark_parser_free(parser) }

        // Attach GFM extensions and build the linked list for the render call.
        // cmark_find_syntax_extension returns cmark_syntax_extension* (OpaquePointer in Swift).
        // cmark_llist_append's third arg is void*, so we bridge via UnsafeMutableRawPointer.
        let mem = cmark_get_default_mem_allocator()
        var extList: UnsafeMutablePointer<cmark_llist>? = nil
        let extNames = ["table", "tasklist", "strikethrough", "autolink"]
        for name in extNames {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
                extList = cmark_llist_append(mem, extList, UnsafeMutableRawPointer(ext))
            }
        }

        markdown.withCString { ptr in
            cmark_parser_feed(parser, ptr, strlen(ptr))
        }

        guard let doc = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(doc) }

        guard let rendered = cmark_render_html(doc, opts, extList) else { return "" }
        defer { free(rendered) }

        return String(cString: rendered)
    }

    /// Walks every `<h1>`…`<h6>` in the rendered HTML and injects
    /// `id="slug"` using GitHub's slug algorithm (lowercase, letters + digits
    /// + spaces + hyphens + underscores kept, everything else dropped, spaces
    /// → hyphens). Duplicates get `-1`, `-2` suffixes in document order.
    /// This is what makes in-document `[…](#anchor)` links resolve.
    static func addHeadingAnchors(in html: String) -> String {
        let pattern = #"<(h[1-6])>(.*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return html
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        // Forward pass to compute slugs; dedup counts must follow document order.
        var seen: [String: Int] = [:]
        let slugs: [String] = matches.map { match in
            let inner = ns.substring(with: match.range(at: 2))
            let plain = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let decoded = htmlEntityDecode(plain)
            var slug = slugify(decoded)
            if slug.isEmpty { slug = "section" }
            let count = seen[slug, default: 0]
            seen[slug] = count + 1
            return count == 0 ? slug : "\(slug)-\(count)"
        }

        // Inject in reverse so earlier NSRanges stay valid against `result`.
        var result = html
        for (i, match) in matches.enumerated().reversed() {
            let tagName = ns.substring(with: match.range(at: 1))
            let openingNSRange = NSRange(location: match.range.location, length: tagName.count + 2)
            guard let openingRange = Range(openingNSRange, in: result) else { continue }
            result.replaceSubrange(openingRange, with: "<\(tagName) id=\"\(slugs[i])\">")
        }
        return result
    }

    static func slugify(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else if ch.isWhitespace {
                out.append("-")
            }
        }
        return out
    }
}

// MARK: - Code block highlighting

private extension MarkdownRenderer {

    static func highlightCodeBlocks(
        in html: String,
        theme: ThemeData
    ) async -> String {
        // Match <pre><code class="language-LANG">...content...</code></pre>
        // cmark-gfm always emits this structure for fenced code blocks.
        let pattern = #"<pre><code(?:\s+class="language-([^"]*)")?>([\s\S]*?)</code></pre>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return html }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        // Process in reverse order so string replacement offsets stay valid
        var result = html

        for match in matches.reversed() {
            let fullRange   = Range(match.range,           in: result)!
            let langRange   = match.range(at: 1)
            let codeRange   = Range(match.range(at: 2),    in: result)!

            let lang = langRange.location != NSNotFound
                ? String(result[Range(langRange, in: result)!])
                : ""

            let escapedCode = String(result[codeRange])
            let code = htmlEntityDecode(escapedCode)

            let highlighted = await highlightSnippet(
                code: code,
                lang: lang,
                theme: theme
            )

            result.replaceSubrange(fullRange, with: highlighted)
        }

        return result
    }

    /// Returns a highlighted `<pre><code>` block, or the original plain block on failure.
    static func highlightSnippet(
        code: String,
        lang: String,
        theme: ThemeData
    ) async -> String {
        let plainFallback = makePlainBlock(code: code, lang: lang, theme: theme)

        guard !lang.isEmpty else { return plainFallback }
        guard let entry = LanguageIndex.entry(forFenceTag: lang) else { return plainFallback }
        guard let grammarData = LanguageIndex.grammarData(for: entry) else { return plainFallback }

        // Supporting grammars satisfy cross-grammar `include` references (yaml
        // splits into yaml.tmLanguage + yaml-1.x + yaml-embedded; without them
        // tokenization comes back empty for multi-file grammars) and carry
        // injection grammars targeting this fence language.
        let siblings = LanguageIndex.supportingGrammars(for: entry)

        // Tokenize via shared TokenizerEngine (reuses warm JSContext)
        guard let rawLines = try? await SourceCodeRenderer.tokenize(
            code: code,
            language: entry.languageId,
            grammarData: grammarData,
            siblingGrammars: siblings,
            injections: LanguageIndex.injectionsForTarget,
            theme: theme
        ) else { return plainFallback }

        let spanLines: [[HTMLRenderer.TokenSpan]] = rawLines.map { line in
            line.map { HTMLRenderer.TokenSpan(text: $0.text, color: $0.color, fontStyle: $0.fontStyle) }
        }

        // Build highlighted code HTML (line spans)
        let codeHTML = spanLines.map { spans in
            let content = spans.map { span in
                let escaped = escapeHTML(span.text)
                var styles: [String] = []
                if let c = span.color  { styles.append("color:\(c)") }
                if span.isBold         { styles.append("font-weight:bold") }
                if span.isItalic       { styles.append("font-style:italic") }
                if span.isUnderline    { styles.append("text-decoration:underline") }
                if styles.isEmpty { return escaped }
                return "<span style=\"\(styles.joined(separator: ";"))\">\(escaped)</span>"
            }.joined()
            return "<span class=\"line\">\(content)</span>"
        }.joined()

        return """
        <pre style="background:var(--md-code-bg);color:\(theme.foreground)"><code \
        class="language-\(lang)" style="display:block">\(codeHTML)</code></pre>
        """
    }

    /// Returns the unique set of language tags from fenced code blocks (``` or ~~~).
    static func extractFencedLanguages(from markdown: String) -> [String] {
        let pattern = #"^(?:```|~~~)(\w\S*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            guard match.range(at: 1).location != NSNotFound else { continue }
            let lang = ns.substring(with: match.range(at: 1)).lowercased()
            if seen.insert(lang).inserted { result.append(lang) }
        }
        return result
    }

    static func makePlainBlock(code: String, lang: String, theme: ThemeData) -> String {
        let escaped = escapeHTML(code)
        let classAttr = lang.isEmpty ? "" : " class=\"language-\(lang)\""
        return """
        <pre style="background:var(--md-code-bg);color:\(theme.foreground)"><code\
        \(classAttr)>\(escaped)</code></pre>
        """
    }

    static func htmlEntityDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;",  with: "'")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Image resolution

private extension MarkdownRenderer {

    static let maxImageBytes = 2 * 1024 * 1024  // 2 MB

    static func resolveImages(in html: String, baseURL: URL) -> String {
        // Match src="..." that aren't already absolute or data URIs
        let pattern = #"src="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var result = html
        for match in matches.reversed() {
            let srcRange  = Range(match.range(at: 1), in: result)!
            let src = String(result[srcRange])

            // Skip absolute URLs and existing data URIs
            guard !src.hasPrefix("http://"),
                  !src.hasPrefix("https://"),
                  !src.hasPrefix("data:")
            else { continue }

            // Percent-decode so URL-encoded spaces etc. (`%20` → ` `) resolve
            // to real filenames on disk. `appendingPathComponent` treats its
            // argument as literal, so `%20` would otherwise stay as-is.
            let decoded = src.removingPercentEncoding ?? src
            let fileURL = baseURL.appendingPathComponent(decoded)
            guard
                let data = try? Data(contentsOf: fileURL),
                data.count <= maxImageBytes
            else { continue }

            let mime = mimeType(for: fileURL.pathExtension.lowercased())
            let b64  = data.base64EncodedString()
            let dataURI = "data:\(mime);base64,\(b64)"

            // Replace just the src value (not the whole attribute)
            let attrRange = Range(match.range(at: 1), in: result)!
            result.replaceSubrange(attrRange, with: dataURI)
        }

        return result
    }

    static func mimeType(for ext: String) -> String {
        switch ext {
        case "png":              return "image/png"
        case "jpg", "jpeg":      return "image/jpeg"
        case "gif":              return "image/gif"
        case "svg":              return "image/svg+xml"
        case "webp":             return "image/webp"
        case "ico":              return "image/x-icon"
        default:                 return "image/png"
        }
    }
}

// MARK: - HTML assembly

private extension MarkdownRenderer {

    /// Assembles a prose-only HTML document. No Source tab, no CSS toggle machinery —
    /// those are handled natively by MarkdownPreviewController in Phase 3+.
    static func assembleHTML(body: String, css: String, fileName: String, theme: ThemeData) -> String {
        let escapedTitle = fileName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        \(css)
        </style>
        </head>
        <body\(theme.isDark ? " class=\"dark\"" : "") style="--md-bg: \(theme.background); --md-fg: \(theme.foreground)">
        <div class="markdown-body">
        \(body)
        </div>
        </body>
        </html>
        """
    }
}
