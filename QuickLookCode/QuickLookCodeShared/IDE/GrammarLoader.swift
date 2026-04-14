//
//  GrammarLoader.swift
//  QuickLookCodeShared
//

import Foundation

/// Locates and caches TextMate grammar files from an IDE installation.
public final class GrammarLoader {

    private let ide: IDEInfo
    private var cache: [String: URL] = [:]

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

        for extDir in extensions {
            for syntaxDir in ["syntaxes", "grammars"] {
                let dir = extDir.appendingPathComponent(syntaxDir)
                guard let files = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else { continue }

                for file in files {
                    let ext = file.pathExtension
                    guard ext == "json" else { continue }
                    let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                    if stem.contains(language.lowercased()) {
                        return file
                    }
                }
            }
        }
        return nil
    }
}
