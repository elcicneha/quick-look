//
//  LanguageIndex.swift
//  QuickLookCodeShared
//
//  Authoritative file-ext / filename / fence-tag / scope-name → grammar resolver.
//  Built by walking every extension's `package.json` and joining `contributes.languages`
//  with `contributes.grammars` — exactly how VS Code itself resolves grammars. Replaces
//  the earlier filename-stem fuzzy search.
//

import Foundation

public enum LanguageIndex {

    // MARK: - Public types

    /// One row per (language, grammar) pair. A language with multiple grammars
    /// produces multiple entries, but file-ext / filename / fence-tag lookups
    /// resolve to whichever grammar the language extension explicitly registered
    /// for that language id — i.e. the `contributes.grammars[].language == id` one.
    public struct Entry: Codable, Hashable {
        public let languageId: String
        public let displayName: String
        public let scopeName: String
        public let grammarPath: String
        public let extensionRoot: String
    }

    /// Serializable snapshot persisted to disk by CacheManager.
    struct Snapshot: Codable {
        /// file extension (lowercase, no leading dot) → entry
        let byExtension: [String: Entry]
        /// exact filename (lowercased) → entry  (e.g. "dockerfile", "makefile")
        let byFilename: [String: Entry]
        /// language id AND every alias, all lowercased → entry  (for markdown fence tags)
        let byLanguageId: [String: Entry]
        /// scope name → absolute grammar path; covers injection / include-only grammars too
        let byScopeName: [String: String]
        /// extensionRoot absolute path → absolute paths of every grammar declared by that
        /// extension. Used by `supportingGrammars` to include helper grammars bundled
        /// alongside the main one (e.g. yaml's `yaml-1.2`, `yaml-embedded`, …).
        let grammarsByExtension: [String: [String]]
        /// Reverse of `grammarsByExtension` — grammar path → owning extensionRoot.
        /// Needed to find an injection grammar's siblings without linear search.
        let pathToExtensionRoot: [String: String]
        /// Target scope name → scope names of injection grammars that declare
        /// `injectTo` for that target. vscode-textmate's Registry uses this to
        /// activate injections during tokenization (e.g. HTML inside JS template
        /// literals, shell inside Dockerfile RUN, JSDoc inside /** */ blocks).
        let injectionsForTarget: [String: [String]]
    }

    // MARK: - In-memory state (process lifetime, seeded by CacheManager)

    static var _snapshot: Snapshot?

    // MARK: - Query API

    public static func entry(forExtension ext: String) -> Entry? {
        _snapshot?.byExtension[ext.lowercased()]
    }

    public static func entry(forFilename name: String) -> Entry? {
        _snapshot?.byFilename[name.lowercased()]
    }

    /// Lookup for markdown fenced code blocks — matches language id and aliases.
    /// `` ```py `` resolves to Python because "py" is in Python's aliases array.
    public static func entry(forFenceTag tag: String) -> Entry? {
        _snapshot?.byLanguageId[tag.lowercased()]
    }

    public static func grammarPath(forScope scope: String) -> String? {
        _snapshot?.byScopeName[scope]
    }

    /// Reads the grammar JSON for the given entry. Cached by path on the static
    /// data cache below so repeated previews don't re-read the same file.
    public static func grammarData(for entry: Entry) -> Data? {
        if let cached = _dataCache[entry.grammarPath] { return cached }
        let url = URL(fileURLWithPath: entry.grammarPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        _dataCache[entry.grammarPath] = data
        return data
    }

    /// All grammar data the tokenizer may need in addition to `entry`'s main grammar.
    /// Collects, in order (deduplicated by path):
    ///   1. `entry`'s same-extension siblings — cross-grammar `include` references
    ///      bundled with the main grammar (e.g. yaml's `yaml-1.2`, `yaml-embedded`).
    ///   2. Injection grammars that declare `injectTo` for `entry.scopeName` —
    ///      HTML-in-JS template literals, shell-in-Dockerfile RUN, JSDoc, etc.
    ///   3. Each injection's own same-extension siblings — so scope-name `include`s
    ///      inside the injection grammar resolve (the injection and its supporting
    ///      grammars are typically packaged in the same extension).
    /// Returned data is passed to `vscode-textmate`'s `Registry.loadGrammar` via the
    /// scopeName-keyed map built in the tokenizer JS.
    public static func supportingGrammars(for entry: Entry) -> [Data] {
        guard let snap = _snapshot else { return [] }

        var orderedPaths: [String] = []
        var seen = Set<String>()
        seen.insert(entry.grammarPath)

        // 1. Same-extension siblings
        for path in snap.grammarsByExtension[entry.extensionRoot] ?? [] {
            if seen.insert(path).inserted { orderedPaths.append(path) }
        }

        // 2 + 3. Injection grammars for this entry's scope + their same-extension siblings
        let injectionScopes = snap.injectionsForTarget[entry.scopeName] ?? []
        for injScope in injectionScopes {
            guard let injPath = snap.byScopeName[injScope] else { continue }
            if seen.insert(injPath).inserted { orderedPaths.append(injPath) }
            guard let injExtRoot = snap.pathToExtensionRoot[injPath] else { continue }
            for path in snap.grammarsByExtension[injExtRoot] ?? [] {
                if seen.insert(path).inserted { orderedPaths.append(path) }
            }
        }

        return orderedPaths.compactMap { path in
            if let cached = _dataCache[path] { return cached }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            _dataCache[path] = data
            return data
        }
    }

    /// The full target→injection-scopes map, to be passed to the tokenizer so
    /// `vscode-textmate`'s `Registry.getInjections` callback can resolve injections
    /// for any scope encountered during tokenization (not just the root scope).
    public static var injectionsForTarget: [String: [String]] {
        _snapshot?.injectionsForTarget ?? [:]
    }

    // MARK: - Bootstrap / invalidation (called by CacheManager)

    static func seed(_ snapshot: Snapshot) {
        _snapshot = snapshot
    }

    static func invalidate() {
        _snapshot = nil
        _dataCache.removeAll()
    }

    // MARK: - Build

    /// Walks the IDE's built-in and user extension directories, reads each
    /// `package.json`, and joins `contributes.languages` with `contributes.grammars`.
    /// Built-in extensions are processed first and win on collision — matching
    /// VS Code's own precedence.
    static func build(from ide: IDEInfo) -> Snapshot {
        var byExt: [String: Entry] = [:]
        var byFilename: [String: Entry] = [:]
        var byLangId: [String: Entry] = [:]
        var byScope: [String: String] = [:]
        var grammarsByExt: [String: [String]] = [:]
        var pathToExtRoot: [String: String] = [:]
        var injectionsForTarget: [String: [String]] = [:]

        let fm = FileManager.default
        for root in [ide.builtinExtensionsURL, ide.userExtensionsURL] {
            guard let extDirs = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for extDir in extDirs {
                process(
                    extDir: extDir,
                    byExtension: &byExt,
                    byFilename: &byFilename,
                    byLanguageId: &byLangId,
                    byScopeName: &byScope,
                    grammarsByExtension: &grammarsByExt,
                    pathToExtensionRoot: &pathToExtRoot,
                    injectionsForTarget: &injectionsForTarget
                )
            }
        }

        return Snapshot(
            byExtension: byExt,
            byFilename: byFilename,
            byLanguageId: byLangId,
            byScopeName: byScope,
            grammarsByExtension: grammarsByExt,
            pathToExtensionRoot: pathToExtRoot,
            injectionsForTarget: injectionsForTarget
        )
    }

    // MARK: - Per-extension processing

    private struct LanguageDecl {
        let id: String
        let displayName: String
        let extensions: [String]   // raw, with leading dot
        let filenames: [String]
        let aliases: [String]      // NLS-resolved
    }

    private static func process(
        extDir: URL,
        byExtension: inout [String: Entry],
        byFilename: inout [String: Entry],
        byLanguageId: inout [String: Entry],
        byScopeName: inout [String: String],
        grammarsByExtension: inout [String: [String]],
        pathToExtensionRoot: inout [String: String],
        injectionsForTarget: inout [String: [String]]
    ) {
        let pkgURL = extDir.appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: pkgURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contributes = root["contributes"] as? [String: Any]
        else { return }

        let nls = loadNLS(extDir: extDir)
        let extRoot = extDir.path

        // Pass 1: language contributions keyed by id.
        var langDecls: [String: LanguageDecl] = [:]
        if let languages = contributes["languages"] as? [[String: Any]] {
            for lang in languages {
                guard let id = lang["id"] as? String, !id.isEmpty else { continue }
                let rawAliases = (lang["aliases"] as? [String]) ?? []
                let aliases = rawAliases.map { resolveNLS($0, using: nls) }
                let displayName = aliases.first ?? id
                let extensions = (lang["extensions"] as? [String]) ?? []
                let filenames = (lang["filenames"] as? [String]) ?? []
                langDecls[id] = LanguageDecl(
                    id: id,
                    displayName: displayName,
                    extensions: extensions,
                    filenames: filenames,
                    aliases: aliases
                )
            }
        }

        // Pass 2: grammars. Every grammar with a scopeName registers under byScopeName
        // (so include-only / injection grammars participate in cross-grammar resolution).
        // Grammars that declare a `language` additionally produce an Entry pushed into
        // the file-ext / filename / language-id lookups.
        guard let grammars = contributes["grammars"] as? [[String: Any]] else { return }

        for g in grammars {
            guard
                let scopeName = g["scopeName"] as? String, !scopeName.isEmpty,
                let relPath = g["path"] as? String, !relPath.isEmpty
            else { continue }

            let absPath = extDir.appendingPathComponent(relPath).standardizedFileURL.path

            if byScopeName[scopeName] == nil {
                byScopeName[scopeName] = absPath
            }

            // Track this grammar under its owning extension for sibling lookup.
            var list = grammarsByExtension[extRoot] ?? []
            if !list.contains(absPath) {
                list.append(absPath)
                grammarsByExtension[extRoot] = list
            }
            if pathToExtensionRoot[absPath] == nil {
                pathToExtensionRoot[absPath] = extRoot
            }

            // Injection grammar? (`injectTo` declares which target scopes should
            // activate this grammar as an injection during tokenization.)
            if let injectTo = g["injectTo"] as? [String] {
                for target in injectTo where !target.isEmpty {
                    var targets = injectionsForTarget[target] ?? []
                    if !targets.contains(scopeName) {
                        targets.append(scopeName)
                        injectionsForTarget[target] = targets
                    }
                }
            }

            // Language-bound grammar?
            guard
                let langId = g["language"] as? String, !langId.isEmpty,
                let decl = langDecls[langId]
            else { continue }

            let entry = Entry(
                languageId: decl.id,
                displayName: decl.displayName,
                scopeName: scopeName,
                grammarPath: absPath,
                extensionRoot: extRoot
            )

            for rawExt in decl.extensions {
                var e = rawExt.lowercased()
                if e.hasPrefix(".") { e = String(e.dropFirst()) }
                guard !e.isEmpty else { continue }
                if byExtension[e] == nil { byExtension[e] = entry }
            }
            for fn in decl.filenames {
                let key = fn.lowercased()
                guard !key.isEmpty else { continue }
                if byFilename[key] == nil { byFilename[key] = entry }
            }
            let idKey = decl.id.lowercased()
            if byLanguageId[idKey] == nil { byLanguageId[idKey] = entry }
            for a in decl.aliases {
                let k = a.lowercased()
                if byLanguageId[k] == nil { byLanguageId[k] = entry }
            }
        }
    }

    // MARK: - Data cache (process lifetime, path → bytes)

    private static var _dataCache: [String: Data] = [:]

    // MARK: - NLS helpers (duplicated from ThemeLoader; kept private here to avoid
    // leaking an IDE-internal helper into the shared API surface).

    private static func loadNLS(extDir: URL) -> [String: String] {
        let url = extDir.appendingPathComponent("package.nls.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in json {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    private static func resolveNLS(_ label: String, using nls: [String: String]) -> String {
        guard label.hasPrefix("%"), label.hasSuffix("%"), label.count > 2 else {
            return label
        }
        let key = String(label.dropFirst().dropLast())
        return nls[key] ?? label
    }
}
