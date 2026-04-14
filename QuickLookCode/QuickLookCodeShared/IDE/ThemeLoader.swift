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
}

public struct TokenColorRule {
    public let scopes: [String]
    public let foreground: String?
    public let fontStyle: String?
}

// MARK: - Loader

public enum ThemeLoader {

    public enum LoadError: LocalizedError {
        case settingsNotFound
        case noThemeKey
        case themeFileNotFound(String)
        case parseError(String)

        public var errorDescription: String? {
            switch self {
            case .settingsNotFound:    return "IDE settings.json not found"
            case .noThemeKey:          return "No workbench.colorTheme in settings.json"
            case .themeFileNotFound(let name): return "Theme file not found for '\(name)'"
            case .parseError(let msg): return "Theme parse error: \(msg)"
            }
        }
    }

    /// The theme name used when the user has not customised their theme in VS Code / Antigravity.
    public static let defaultThemeName = "Default Dark Modern"

    // MARK: - Public API

    /// Load the active theme for the given IDE.
    public static func loadActiveTheme(from ide: IDEInfo) throws -> ThemeData {
        let themeName = readActiveThemeName(settingsURL: ide.settingsURL)
        let themeURL = try findThemeFile(named: themeName, in: ide)
        return try parseTheme(at: themeURL, fallbackName: themeName)
    }

    // MARK: - Steps

    private static func readActiveThemeName(settingsURL: URL) -> String {
        guard
            FileManager.default.fileExists(atPath: settingsURL.path),
            let data = try? Data(contentsOf: settingsURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let theme = json["workbench.colorTheme"] as? String,
            !theme.isEmpty
        else {
            // No theme configured — use the IDE's out-of-the-box default.
            return defaultThemeName
        }
        return theme
    }

    private static func findThemeFile(named themeName: String, in ide: IDEInfo) throws -> URL {
        let searchRoots = [ide.builtinExtensionsURL, ide.userExtensionsURL]
        for root in searchRoots {
            if let url = searchThemes(in: root, matching: themeName) {
                return url
            }
        }
        throw LoadError.themeFileNotFound(themeName)
    }

    private static func searchThemes(in root: URL, matching themeName: String) -> URL? {
        let fm = FileManager.default
        guard let extensions = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        for extDir in extensions {
            let themesDir = extDir.appendingPathComponent("themes")
            guard let themeFiles = try? fm.contentsOfDirectory(
                at: themesDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }

            for file in themeFiles where file.pathExtension == "json" {
                if matchesTheme(file: file, themeName: themeName) {
                    return file
                }
            }
        }
        return nil
    }

    private static func matchesTheme(file: URL, themeName: String) -> Bool {
        let stem = file.deletingPathExtension().lastPathComponent
        if stem.caseInsensitiveCompare(themeName) == .orderedSame {
            return true
        }
        guard
            let data = try? Data(contentsOf: file),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = json["name"] as? String
        else { return false }
        return name.caseInsensitiveCompare(themeName) == .orderedSame
    }

    // MARK: - Parsing

    private static func parseTheme(at url: URL, fallbackName: String) throws -> ThemeData {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.parseError("Root is not a JSON object")
        }

        let name = (json["name"] as? String) ?? fallbackName
        let themeType = (json["type"] as? String) ?? "dark"
        let isDark = themeType.lowercased() != "light"

        let colors = json["colors"] as? [String: String] ?? [:]
        let background = colors["editor.background"] ?? (isDark ? "#1e1e1e" : "#ffffff")
        let foreground = colors["editor.foreground"] ?? (isDark ? "#d4d4d4" : "#000000")

        var rules: [TokenColorRule] = []
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

        return ThemeData(
            name: name,
            isDark: isDark,
            background: background,
            foreground: foreground,
            tokenColors: rules
        )
    }
}
