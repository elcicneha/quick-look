//
//  ThemeLoader.swift
//  QuickLookCodeShared
//

import Foundation

// MARK: - Public types

public struct ThemeData {
    public let name: String
    public let isDark: Bool
    public let background: String
    public let foreground: String
    public let tokenColors: [TokenColorRule]

    public init(name: String, isDark: Bool, background: String, foreground: String, tokenColors: [TokenColorRule]) {
        self.name = name
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.tokenColors = tokenColors
    }
}

public struct TokenColorRule {
    public let scopes: [String]
    public let foreground: String?
    public let fontStyle: String?
}

/// A theme as registered by a VS Code / Antigravity extension — the authoritative
/// mapping between the id stored in `workbench.colorTheme` and the theme JSON file.
struct ThemeContribution {
    /// Identifier stored in `workbench.colorTheme` when the user picks this theme.
    let id: String
    /// Human-readable name, NLS-resolved if possible (otherwise the raw label).
    let label: String
    /// Absolute path to the theme JSON file.
    let path: URL
    /// "vs" (light), "vs-dark" (dark), "hc-black", "hc-light".
    let uiTheme: String
}

// MARK: - Loader

public enum ThemeLoader {

    // MARK: - In-memory caches (process lifetime, populated by CacheManager)

    /// Parsed theme data; skips all disk I/O on the hot path when set.
    static var _cachedTheme: ThemeData?

    /// Pre-serialized IRawTheme JSON string ready to hand directly to initGrammar.
    static var _cachedSerializedTheme: String?

    public enum LoadError: LocalizedError {
        case noThemesFound
        case themeNotResolvable(String)
        case parseError(String)

        public var errorDescription: String? {
            switch self {
            case .noThemesFound:
                return "No themes found in the IDE's installed extensions"
            case .themeNotResolvable(let name):
                return "Could not resolve theme '\(name)' to a theme file"
            case .parseError(let msg):
                return "Theme parse error: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Load the active theme for the given IDE.
    /// Returns the in-memory cached theme if CacheManager has bootstrapped; otherwise
    /// does a full disk load (find settings.json → locate theme file → parse JSON).
    public static func loadActiveTheme(from ide: IDEInfo) throws -> ThemeData {
        if let cached = _cachedTheme { return cached }
        return try loadActiveThemeFromDisk(from: ide)
    }

    /// Full disk load — always reads from the filesystem. Used by CacheManager at build time.
    static func loadActiveThemeFromDisk(from ide: IDEInfo) throws -> ThemeData {
        let registry = loadThemeRegistry(from: ide)

        // 1. If the user has set workbench.colorTheme, resolve that name via the
        //    extension registry (id, label, or filename/JSON-name fallback for
        //    non-conforming themes).
        if let themeName = readActiveThemeName(settingsURL: ide.settingsURL) {
            if let contribution = resolveTheme(named: themeName, in: registry) {
                return try parseTheme(contribution: contribution)
            }
            throw LoadError.themeNotResolvable(themeName)
        }

        // 2. No preference set: pick the first dark theme from the IDE's bundled
        //    theme-defaults extension. The choice is structural (first vs-dark
        //    contribution in the IDE's own defaults) — no hardcoded theme name.
        let defaults = registry.filter { isThemeDefaults($0.path) }
        if let fallback = defaults.first(where: { $0.uiTheme == "vs-dark" }) ?? defaults.first {
            return try parseTheme(contribution: fallback)
        }

        throw LoadError.noThemesFound
    }

    // MARK: - Settings

    /// Returns the user's configured theme name, or nil if none is set.
    /// Never returns a hardcoded default — callers must fall back structurally.
    static func readActiveThemeName(settingsURL: URL) -> String? {
        let path = settingsURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[QuickLookCode] ThemeLoader: settings.json not found at %@", path)
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            NSLog("[QuickLookCode] ThemeLoader: cannot read settings.json at %@ (%@)",
                  path, error.localizedDescription)
            return nil
        }
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[QuickLookCode] ThemeLoader: settings.json root is not an object")
                return nil
            }
            json = parsed
        } catch {
            NSLog("[QuickLookCode] ThemeLoader: settings.json parse error (%@) — likely JSONC comments",
                  error.localizedDescription)
            return nil
        }
        guard let theme = json["workbench.colorTheme"] as? String, !theme.isEmpty else {
            NSLog("[QuickLookCode] ThemeLoader: workbench.colorTheme missing or empty")
            return nil
        }
        NSLog("[QuickLookCode] ThemeLoader: read active theme name = %@", theme)
        return theme
    }

    // MARK: - Registry

    /// Walks the IDE's built-in and user extension directories and returns all
    /// theme contributions (by reading each extension's package.json).
    static func loadThemeRegistry(from ide: IDEInfo) -> [ThemeContribution] {
        var entries: [ThemeContribution] = []
        for root in [ide.builtinExtensionsURL, ide.userExtensionsURL] {
            entries += loadContributions(rootExtensionsDir: root)
        }
        return entries
    }

    private static func loadContributions(rootExtensionsDir: URL) -> [ThemeContribution] {
        let fm = FileManager.default
        guard let extensions = try? fm.contentsOfDirectory(
            at: rootExtensionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var entries: [ThemeContribution] = []
        for extDir in extensions {
            entries += parseExtensionContributions(extDir: extDir)
        }
        return entries
    }

    private static func parseExtensionContributions(extDir: URL) -> [ThemeContribution] {
        let packageURL = extDir.appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: packageURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contributes = root["contributes"] as? [String: Any],
            let themes = contributes["themes"] as? [[String: Any]]
        else { return [] }

        let nls = loadNLS(extDir: extDir)

        var entries: [ThemeContribution] = []
        for theme in themes {
            guard
                let id = (theme["id"] as? String) ?? (theme["label"] as? String),
                let relPath = theme["path"] as? String,
                !relPath.isEmpty
            else { continue }

            let rawLabel = (theme["label"] as? String) ?? id
            let label = resolveNLS(rawLabel, using: nls)
            let uiTheme = (theme["uiTheme"] as? String) ?? "vs-dark"
            let absPath = extDir.appendingPathComponent(relPath).standardizedFileURL

            entries.append(ThemeContribution(
                id: id,
                label: label,
                path: absPath,
                uiTheme: uiTheme
            ))
        }
        return entries
    }

    /// Reads an extension's package.nls.json (if present) for NLS placeholder resolution.
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

    /// Resolves a "%placeholder%" label against an NLS dictionary. Returns the input
    /// unchanged if it isn't a placeholder or can't be resolved.
    private static func resolveNLS(_ label: String, using nls: [String: String]) -> String {
        guard label.hasPrefix("%"), label.hasSuffix("%"), label.count > 2 else {
            return label
        }
        let key = String(label.dropFirst().dropLast())
        return nls[key] ?? label
    }

    /// Path-based check that an entry lives inside the IDE's `theme-defaults` extension.
    private static func isThemeDefaults(_ url: URL) -> Bool {
        url.pathComponents.contains("theme-defaults")
    }

    // MARK: - Resolution

    /// Tries multiple match strategies, in order of authoritativeness:
    /// 1. Exact id match (what VS Code stores in settings)
    /// 2. Label match (what the user sees in the picker)
    /// 3. Filename stem match (legacy / non-conforming themes)
    /// 4. Theme file's internal `name` field (same fallback)
    private static func resolveTheme(
        named themeName: String,
        in registry: [ThemeContribution]
    ) -> ThemeContribution? {
        if let hit = registry.first(where: { $0.id.caseInsensitiveCompare(themeName) == .orderedSame }) {
            return hit
        }
        if let hit = registry.first(where: { $0.label.caseInsensitiveCompare(themeName) == .orderedSame }) {
            return hit
        }
        if let hit = registry.first(where: {
            $0.path.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(themeName) == .orderedSame
        }) {
            return hit
        }
        for entry in registry {
            if let name = readThemeNameField(at: entry.path),
               name.caseInsensitiveCompare(themeName) == .orderedSame {
                return entry
            }
        }
        return nil
    }

    private static func classifyIsDark(themeType: String?, uiTheme: String) -> Bool {
        if let t = themeType?.lowercased() {
            if t == "light" { return false }
            if t == "dark"  { return true  }
        }
        // VS Code classification: "vs"/"hc-light" are light, everything else dark.
        return !(uiTheme == "vs" || uiTheme == "hc-light")
    }

    private static func readThemeNameField(at url: URL) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = json["name"] as? String
        else { return nil }
        return name
    }

    // MARK: - Parsing

    /// Parses a theme file, classifying light vs dark via (in order):
    /// 1. The theme JSON's own `type` field, if present.
    /// 2. The registered `uiTheme` from the extension's package.json — VS Code's
    ///    built-in themes (e.g. `light_modern.json`) often omit `type` entirely and
    ///    rely on `uiTheme` being `"vs"`/`"vs-dark"`/`"hc-light"`/`"hc-black"`.
    private static func parseTheme(contribution: ThemeContribution) throws -> ThemeData {
        let url = contribution.path
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.parseError("Root is not a JSON object")
        }

        let name = (json["name"] as? String) ?? contribution.label
        let isDark = classifyIsDark(
            themeType: json["type"] as? String,
            uiTheme: contribution.uiTheme
        )

        let colors = json["colors"] as? [String: String] ?? [:]
        let background = colors["editor.background"] ?? (isDark ? "#1e1e1e" : "#ffffff")
        let foreground = colors["editor.foreground"] ?? (isDark ? "#d4d4d4" : "#000000")

        let rules = parseTokenColors(from: json, fileURL: url)

        return ThemeData(
            name: name,
            isDark: isDark,
            background: background,
            foreground: foreground,
            tokenColors: rules
        )
    }

    /// Recursively resolves `include` and collects tokenColors from a JSON object.
    private static func parseTokenColors(from json: [String: Any], fileURL: URL) -> [TokenColorRule] {
        var rules: [TokenColorRule] = []

        // Follow nested includes depth-first (included rules come first, current file overrides).
        if let includePath = json["include"] as? String {
            let includedURL = fileURL.deletingLastPathComponent().appendingPathComponent(includePath)
            if let includedData = try? Data(contentsOf: includedURL),
               let includedJSON = try? JSONSerialization.jsonObject(with: includedData) as? [String: Any] {
                rules += parseTokenColors(from: includedJSON, fileURL: includedURL)
            }
        }

        if let tokenColors = json["tokenColors"] as? [[String: Any]] {
            for entry in tokenColors {
                let scopeValue = entry["scope"]
                let scopes: [String]
                if let arr = scopeValue as? [String] {
                    scopes = arr
                } else if let str = scopeValue as? String {
                    scopes = str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    scopes = []
                }
                let settings = entry["settings"] as? [String: String] ?? [:]
                rules.append(TokenColorRule(
                    scopes: scopes,
                    foreground: settings["foreground"],
                    fontStyle: settings["fontStyle"]
                ))
            }
        }

        return rules
    }
}
