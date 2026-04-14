//
//  IDEInfo.swift
//  QuickLookCodeShared
//

import Foundation

/// Describes a single installed VS Code–compatible IDE.
public struct IDEInfo {
    public let name: String

    /// The .app bundle URL, e.g. /Applications/Antigravity.app
    public let appURL: URL

    /// Built-in extension grammars/themes shipped with the app.
    /// <app>/Contents/Resources/app/extensions/
    public var builtinExtensionsURL: URL {
        appURL
            .appendingPathComponent("Contents/Resources/app/extensions", isDirectory: true)
    }

    /// User-installed extensions directory, e.g. ~/.antigravity/extensions
    public let userExtensionsURL: URL

    /// User settings file, e.g. ~/Library/Application Support/Antigravity/User/settings.json
    public let settingsURL: URL
}
