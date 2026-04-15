//
//  GrammarLoader.swift
//  QuickLookCodeShared

import Foundation

/// Locates and caches TextMate grammar files from an IDE installation.
public final class GrammarLoader {

    private let ide: IDEInfo
    private var cache: [String: URL] = [:]
    private var siblingCache: [String: [Data]] = [:]

    public init(ide: IDEInfo) {
        self.ide = ide
    }

    // MARK: - Public API

    public func grammarData(for language: String) throws -> Data? {
        if let url = cache[language] {
            return try Data(contentsOf: url)
        }
        guard let url = findGrammarFile(for: language) else {
            return nil
        }
        cache[language] = url
        return try Data(contentsOf: url)
    }

    public func grammarURL(for language: String) -> URL? {
        if let cached = cache[language] { return cached }
        let url = findGrammarFile(for: language)
        if let url { cache[language] = url }
        return url
    }

    /// Returns Data for all sibling grammar files in the same extension folder
    /// as the resolved grammar for `language` (excluding the main file itself).
    /// These are used to satisfy cross-grammar `include` references (e.g. yaml-embedded).
    public func siblingGrammarData(for language: String) -> [Data] {
        if let cached = siblingCache[language] { return cached }
        guard let mainURL = grammarURL(for: language) else { return [] }
        let syntaxDir = mainURL.deletingLastPathComponent()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: syntaxDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }
        let result = files.compactMap { url -> Data? in
            guard url.pathExtension == "json", url != mainURL else { return nil }
            return try? Data(contentsOf: url)
        }
        siblingCache[language] = result
        return result
    }

    // MARK: - Search

    private func findGrammarFile(for language: String) -> URL? {
        let roots = [ide.builtinExtensionsURL, ide.userExtensionsURL]
        for root in roots {
            if let url = search(root: root, language: language) {
                return url
            }
        }
        return nil
    }

    private func search(root: URL, language: String) -> URL? {
        let fm = FileManager.default
        guard let extensions = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let langLower = language.lowercased()
        for extDir in extensions {
            for syntaxDir in ["syntaxes", "grammars"] {
                let dir = extDir.appendingPathComponent(syntaxDir)
                guard let files = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else { continue }

                var bestFile: URL? = nil
                var bestStemLength = Int.max
                for file in files {
                    guard file.pathExtension == "json" else { continue }
                    let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                    if stem.contains(langLower) && stem.count < bestStemLength {
                        bestFile = file
                        bestStemLength = stem.count
                    }
                }
                if let bestFile { return bestFile }
            }
        }
        return nil
    }
}
