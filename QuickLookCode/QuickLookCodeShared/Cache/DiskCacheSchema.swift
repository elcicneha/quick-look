//
//  DiskCacheSchema.swift
//  QuickLookCodeShared
//
//  Codable types for the on-disk cache stored in the App Group container.
//  Bump schemaVersion whenever any struct changes in a breaking way.
//

import Foundation

enum DiskCacheSchema {

    // Increment this when any Codable struct below changes OR when a grammar-
    // index rebuild is needed (e.g. after fixing GrammarLoader's search logic).
    static let schemaVersion = 2

    static let appGroup = "group.com.nehagupta.quicklookcode"
    static let dirName  = "quicklookcode"

    // File names inside the cache directory.
    static let manifestFile     = "manifest.json"
    static let ideFile          = "ide.json"
    static let themeFile        = "theme.json"
    static let grammarIndexFile = "grammar-index.json"

    // MARK: - Manifest

    /// Written last during a rebuild; its presence + validity signals a complete cache.
    struct Manifest: Codable {
        let schemaVersion: Int
        let cacheVersion: String      // UUID bumped on every refresh
        let builtAt: Double           // Date.timeIntervalSinceReferenceDate
        let ideAppPath: String
        let ideAppMtime: Double       // detect IDE app update (new built-in grammars/themes)
        let settingsFileMtime: Double // detect active-theme name change in settings.json
    }

    // MARK: - IDE

    struct CachedIDE: Codable {
        let name: String
        let appPath: String
        let userExtensionsPath: String
        let settingsPath: String

        func toIDEInfo() -> IDEInfo {
            IDEInfo(
                name: name,
                appURL: URL(fileURLWithPath: appPath),
                userExtensionsURL: URL(fileURLWithPath: userExtensionsPath),
                settingsURL: URL(fileURLWithPath: settingsPath)
            )
        }
    }

    // MARK: - Theme

    struct CachedTheme: Codable {
        let themeData: ThemeRecord
        let serializedThemeJSON: String  // pre-built IRawTheme JSON for initGrammar
    }

    struct ThemeRecord: Codable {
        let name: String
        let isDark: Bool
        let background: String
        let foreground: String
        let tokenColors: [TokenColorRecord]

        func toThemeData() -> ThemeData {
            ThemeData(
                name: name,
                isDark: isDark,
                background: background,
                foreground: foreground,
                tokenColors: tokenColors.map {
                    TokenColorRule(scopes: $0.scopes, foreground: $0.foreground, fontStyle: $0.fontStyle)
                }
            )
        }
    }

    struct TokenColorRecord: Codable {
        let scopes: [String]
        let foreground: String?
        let fontStyle: String?
    }
}
