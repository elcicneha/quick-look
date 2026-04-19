//
//  GrammarLoader.swift
//  QuickLookCodeShared

import Foundation

/// Locates and caches TextMate grammar files from an IDE installation.
public final class GrammarLoader {

    // MARK: - Process-lifetime static caches
    // Survive instance recreation; populated by CacheManager from the grammar index.

    private static var _urlCache: [String: URL] = [:]      // grammarSearch → file URL
    private static var _dataCache: [String: Data] = [:]    // grammarSearch → grammar Data
    private static var _siblingCache: [String: [Data]] = [:] // grammarSearch → sibling Data[]
    private static let _lock = NSLock()

    /// Seeds the URL cache from the on-disk grammar index (called by CacheManager).
    public static func seedURLIndex(_ index: [String: URL]) {
        _lock.lock()
        _urlCache = index
        _lock.unlock()
    }

    /// Drops all static caches (called by CacheManager.refresh()).
    public static func invalidateStaticCaches() {
        _lock.lock()
        _urlCache.removeAll()
        _dataCache.removeAll()
        _siblingCache.removeAll()
        _lock.unlock()
    }

    // MARK: - Instance state

    private let ide: IDEInfo
    private var instanceURLCache: [String: URL] = [:]  // fallback for languages not in static index

    public init(ide: IDEInfo) {
        self.ide = ide
    }

    // MARK: - Public API

    public func grammarData(for language: String) throws -> Data? {
        // 1. Static data cache (hot path)
        GrammarLoader._lock.lock()
        if let data = GrammarLoader._dataCache[language] {
            GrammarLoader._lock.unlock()
            return data
        }
        let staticURL = GrammarLoader._urlCache[language]
        GrammarLoader._lock.unlock()

        // 2. Resolve URL (static index → instance cache → directory walk)
        let resolvedURL: URL
        if let url = staticURL {
            resolvedURL = url
        } else if let url = instanceURLCache[language] {
            resolvedURL = url
        } else {
            guard let url = findGrammarFile(for: language) else { return nil }
            resolvedURL = url
            instanceURLCache[language] = url
            GrammarLoader._lock.lock()
            GrammarLoader._urlCache[language] = url
            GrammarLoader._lock.unlock()
        }

        // 3. Read and cache the data
        let data = try Data(contentsOf: resolvedURL)
        GrammarLoader._lock.lock()
        GrammarLoader._dataCache[language] = data
        GrammarLoader._lock.unlock()
        return data
    }

    public func grammarURL(for language: String) -> URL? {
        GrammarLoader._lock.lock()
        let staticURL = GrammarLoader._urlCache[language]
        GrammarLoader._lock.unlock()

        if let url = staticURL { return url }
        if let url = instanceURLCache[language] { return url }

        guard let url = findGrammarFile(for: language) else { return nil }
        instanceURLCache[language] = url
        GrammarLoader._lock.lock()
        GrammarLoader._urlCache[language] = url
        GrammarLoader._lock.unlock()
        return url
    }

    /// Returns Data for all sibling grammar files in the same extension folder
    /// as the resolved grammar for `language` (excluding the main file itself).
    /// These are used to satisfy cross-grammar `include` references (e.g. yaml-embedded).
    public func siblingGrammarData(for language: String) -> [Data] {
        GrammarLoader._lock.lock()
        if let cached = GrammarLoader._siblingCache[language] {
            GrammarLoader._lock.unlock()
            return cached
        }
        GrammarLoader._lock.unlock()

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

        GrammarLoader._lock.lock()
        GrammarLoader._siblingCache[language] = result
        GrammarLoader._lock.unlock()
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
        // Walk every extension's syntax dir and pick the GLOBALLY shortest
        // stem that contains the language substring. Early-returning after
        // the first matching extension picks the wrong grammar when another
        // extension contains the term only incidentally — e.g. a "html"
        // search against Razor's `cshtml.tmLanguage.json` before reaching
        // the real `html/syntaxes/html.tmLanguage.json`.
        var bestFile: URL? = nil
        var bestStemLength = Int.max
        for extDir in extensions {
            for syntaxDir in ["syntaxes", "grammars"] {
                let dir = extDir.appendingPathComponent(syntaxDir)
                guard let files = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else { continue }
                for file in files {
                    guard file.pathExtension == "json" else { continue }
                    let stem = file.deletingPathExtension().lastPathComponent.lowercased()
                    if stem.contains(langLower) && stem.count < bestStemLength {
                        bestFile = file
                        bestStemLength = stem.count
                    }
                }
            }
        }
        return bestFile
    }
}
