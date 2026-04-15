//
//  SourceCodeRenderer.swift
//  QuickLookCodeShared
//
//  Tokenizes source code via vscode-textmate running inside a JavaScriptCore
//  context, then builds a syntax-highlighted HTML page using the active VS Code theme.
//
//  JavaScriptCore (JSC) is used instead of WKWebView because:
//    • JSC runs in-process — no child process spawning, works in sandboxed extensions.
//    • The tokenizer-jsc.js bundle uses native JS regex (no WASM), so initialization
//      is fully synchronous.
//    • JSC automatically drains the microtask queue after each API call, which lets
//      us use vscode-textmate's Promise-based API without an async event loop.
//
//  Color resolution happens inside vscode-textmate via `tokenizeLine2` + the registry's
//  color map, so scope→color matching (descendant/parent/exclusion selectors,
//  specificity scoring) is handled by the library — identical to VS Code.
//

import Foundation
import JavaScriptCore

// MARK: - Public API

public enum SourceCodeRenderer {

    // MARK: Limits

    public static let maxBytes = 500 * 1024   // 500 KB
    public static let maxLines = 10_000

    // MARK: Errors

    public enum RendererError: LocalizedError {
        case resourceNotFound(String)
        case tokenizationFailed(String)
        case grammarNotUTF8
        case themeSerializationFailed

        public var errorDescription: String? {
            switch self {
            case .resourceNotFound(let r):      return "Resource not found: \(r)"
            case .tokenizationFailed(let r):    return "Tokenization failed: \(r)"
            case .grammarNotUTF8:               return "Grammar file is not valid UTF-8"
            case .themeSerializationFailed:    return "Could not serialize theme for tokenizer"
            }
        }
    }

    // MARK: Entry point

    /// Renders `fileURL` as a syntax-highlighted HTML page.
    /// Safe to call from any thread — JSC is used in-process.
    public static func render(
        fileURL: URL,
        grammarData: Data,
        siblingGrammars: [Data] = [],
        theme: ThemeData,
        languageInfo: FileTypeRegistry.LanguageInfo,
        fileName: String
    ) async throws -> Data {
        let (content, truncationNote) = readFile(at: fileURL)

        let rawLines = try tokenize(code: content, grammarData: grammarData, siblingGrammars: siblingGrammars, theme: theme)

        let spanLines: [[HTMLRenderer.TokenSpan]] = rawLines.map { line in
            line.map { raw in
                HTMLRenderer.TokenSpan(
                    text: raw.text,
                    color: raw.color,
                    fontStyle: raw.fontStyle
                )
            }
        }

        let html = HTMLRenderer.render(
            lines: spanLines,
            theme: theme,
            languageDisplayName: languageInfo.displayName,
            fileName: fileName,
            truncationNote: truncationNote
        )
        return Data(html.utf8)
    }

    // MARK: - File reading + size guard

    private static func readFile(at url: URL) -> (String, String?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attrs?[.size] as? Int) ?? 0

        let rawData: Data
        if byteCount > maxBytes {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return ("// Could not read file.", nil)
            }
            defer { try? handle.close() }
            rawData = handle.readData(ofLength: maxBytes)
        } else {
            guard let data = try? Data(contentsOf: url) else {
                return ("// Could not read file.", nil)
            }
            rawData = data
        }

        let content = String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .isoLatin1)
            ?? "// File could not be decoded."

        let lines = content.components(separatedBy: "\n")
        if lines.count > maxLines {
            let truncated = lines.prefix(maxLines).joined(separator: "\n")
            return (truncated, "// [Preview truncated — file exceeds \(maxLines) lines]")
        }

        if byteCount > maxBytes {
            return (content, "// [Preview truncated — file exceeds 500 KB]")
        }

        return (content, nil)
    }

    // MARK: - JSC tokenization

    static func tokenize(code: String, grammarData: Data, siblingGrammars: [Data] = [], theme: ThemeData) throws -> [[RawToken]] {
        guard let grammarJSON = String(data: grammarData, encoding: .utf8) else {
            throw RendererError.grammarNotUTF8
        }

        let themeJSON = try serializeTheme(theme)

        let bundle = Bundle(for: BundleAnchor.self)
        guard let bundleURL = bundle.url(forResource: "tokenizer-jsc", withExtension: "js") else {
            throw RendererError.resourceNotFound(
                "tokenizer-jsc.js not found in QuickLookCodeShared.framework — run `pnpm run build` in tokenizer/"
            )
        }

        let bundleScript: String
        do {
            bundleScript = try String(contentsOf: bundleURL, encoding: .utf8)
        } catch {
            throw RendererError.resourceNotFound("Could not read tokenizer-jsc.js: \(error.localizedDescription)")
        }

        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            guard let msg = exception?.toString() else { return }
            NSLog("[QuickLookCode] JSC exception: %@", msg)
        }

        // Bridge console.error → NSLog so JS diagnostics appear in the system log.
        let nslogBlock: @convention(block) (String) -> Void = { msg in
            NSLog("[QuickLookCode] JS: %@", msg)
        }
        context.setObject(nslogBlock, forKeyedSubscript: "__nslog" as NSString)
        context.evaluateScript(
            "console.error = function() { try { __nslog(Array.prototype.slice.call(arguments).join(' ')); } catch(e) {} };"
        )

        // JSC has no `window`; shim it to globalThis so the iife bundle works.
        context.evaluateScript("var window = globalThis;")

        // Install native oniguruma as `globalThis.onigLib` BEFORE loading the
        // bundle — vscode-textmate picks it up from there. Native oniguruma
        // replaces the previous JS regex approximation entirely.
        OnigJSBridge.install(in: context)

        // Load the vscode-textmate bundle.
        context.evaluateScript(bundleScript)

        // Step 1 — init grammar + theme.
        // After this call, JSC drains its microtask queue automatically, so
        // _grammar is set before doTokenize runs.
        let siblingJSONStrings = siblingGrammars.compactMap { String(data: $0, encoding: .utf8) }
        let siblingGrammarsJSON = (try? JSONSerialization.data(withJSONObject: siblingJSONStrings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let initFn = context.objectForKeyedSubscript("initGrammar")
        initFn?.call(withArguments: [grammarJSON, themeJSON, siblingGrammarsJSON])

        // Step 2 — tokenize. Returns Array<Array<{text, color, fontStyle}>> or null.
        let tokenizeFn = context.objectForKeyedSubscript("doTokenize")
        let result = tokenizeFn?.call(withArguments: [code])

        guard let result, !result.isNull, !result.isUndefined else {
            throw RendererError.tokenizationFailed(
                "doTokenize returned null — grammar may not have loaded (check grammar JSON)"
            )
        }

        return parseResult(result)
    }

    private static func parseResult(_ value: JSValue) -> [[RawToken]] {
        guard let lines = value.toArray() else { return [] }
        return lines.compactMap { lineAny -> [RawToken]? in
            guard let line = lineAny as? [Any] else { return [] }
            return line.compactMap { tokenAny -> RawToken? in
                guard
                    let token = tokenAny as? [String: Any],
                    let text  = token["text"] as? String
                else { return nil }
                let color = token["color"] as? String
                let fontStyle = token["fontStyle"] as? String
                return RawToken(text: text, color: color, fontStyle: fontStyle)
            }
        }
    }

    // MARK: - Theme serialization

    /// Builds an `IRawTheme`-shaped JSON blob for `vscode-textmate`'s `Registry.setTheme`.
    ///
    /// The first settings entry carries the theme's default foreground/background so
    /// tokens with no matching rule still get the correct default. Remaining entries
    /// mirror the theme's `tokenColors` array one-for-one.
    private static func serializeTheme(_ theme: ThemeData) throws -> String {
        var settings: [[String: Any]] = []

        settings.append([
            "settings": [
                "foreground": theme.foreground,
                "background": theme.background,
            ],
        ])

        for rule in theme.tokenColors {
            var tokenSettings: [String: String] = [:]
            if let fg = rule.foreground { tokenSettings["foreground"] = fg }
            if let fs = rule.fontStyle { tokenSettings["fontStyle"] = fs }
            if tokenSettings.isEmpty { continue }

            var entry: [String: Any] = ["settings": tokenSettings]
            if !rule.scopes.isEmpty {
                entry["scope"] = rule.scopes
            }
            settings.append(entry)
        }

        let themeObj: [String: Any] = [
            "name": theme.name,
            "settings": settings,
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: themeObj),
            let json = String(data: data, encoding: .utf8)
        else {
            throw RendererError.themeSerializationFailed
        }
        return json
    }
}

// MARK: - Internals

extension SourceCodeRenderer {
    struct RawToken {
        let text: String
        let color: String?
        let fontStyle: String?
    }
}

/// Used only as a `Bundle(for:)` anchor to locate the framework's resources.
final class BundleAnchor {}
