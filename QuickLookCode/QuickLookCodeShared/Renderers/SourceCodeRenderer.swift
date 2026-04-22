//
//  SourceCodeRenderer.swift
//  QuickLookCodeShared
//
//  Tokenizes source code via vscode-textmate (running inside a shared TokenizerEngine
//  actor). Callers receive [[RawToken]] and feed them to TextKitRenderer for NSTextView
//  display.
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

    // MARK: - File reading + size guard

    public static func readFile(at url: URL) -> (String, String?) {
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

    // MARK: - Tokenization (via shared TokenizerEngine)

    /// Tokenizes `code` using the shared JSContext. Async because it awaits the actor.
    /// The `language` key is used to detect grammar changes between calls so the engine
    /// can skip re-initializing when the same language is tokenized twice in a row.
    public static func tokenize(
        code: String,
        language: String,
        grammarData: Data,
        siblingGrammars: [Data] = [],
        injections: [String: [String]] = [:],
        theme: ThemeData
    ) async throws -> [[RawToken]] {
        guard let grammarJSON = String(data: grammarData, encoding: .utf8) else {
            throw RendererError.grammarNotUTF8
        }

        // Use pre-serialized theme JSON from cache if available; otherwise build it now.
        let themeJSON: String
        if let cached = ThemeLoader._cachedSerializedTheme {
            themeJSON = cached
        } else {
            themeJSON = try serializeTheme(theme)
        }

        let siblingJSONStrings = siblingGrammars.compactMap { String(data: $0, encoding: .utf8) }
        let siblingGrammarsJSON = (try? JSONSerialization.data(withJSONObject: siblingJSONStrings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let injectionsJSON = (try? JSONSerialization.data(withJSONObject: injections))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return await TokenizerEngine.shared.tokenize(
            code: code,
            language: language,
            grammarJSON: grammarJSON,
            siblingGrammarsJSON: siblingGrammarsJSON,
            injectionsJSON: injectionsJSON,
            themeJSON: themeJSON
        )
    }

    static func parseResult(_ value: JSValue) -> [[RawToken]] {
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
    static func serializeTheme(_ theme: ThemeData) throws -> String {
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
    public struct RawToken {
        public let text: String
        public let color: String?
        public let fontStyle: String?
    }
}

/// Used only as a `Bundle(for:)` anchor to locate the framework's resources.
final class BundleAnchor {}
