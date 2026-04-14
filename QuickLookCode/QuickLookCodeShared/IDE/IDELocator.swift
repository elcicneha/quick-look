//
//  IDELocator.swift
//  QuickLookCodeShared
//

import Foundation

/// Finds VS Code–compatible IDEs installed on this machine.
public enum IDELocator {

    // MARK: - Catalog

    private struct Candidate {
        let name: String
        let appNames: [String]
        let userExtensionsDirName: String
        let appSupportDirName: String
    }

    // VS Code is listed first — it is the primary target and preferred when both are installed.
    // Antigravity (Google's VS Code fork) shares the same internal structure and is a
    // supported fallback.
    private static let catalog: [Candidate] = [
        Candidate(
            name: "VS Code",
            appNames: ["Visual Studio Code.app"],
            userExtensionsDirName: ".vscode",
            appSupportDirName: "Code"
        ),
        Candidate(
            name: "Antigravity",
            appNames: ["Antigravity.app"],
            userExtensionsDirName: ".antigravity",
            appSupportDirName: "Antigravity"
        ),
    ]

    // MARK: - Public API

    /// Returns all IDEs found on the system, in catalog order.
    public static func installedIDEs() -> [IDEInfo] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupportBase = home.appendingPathComponent("Library/Application Support")

        var found: [IDEInfo] = []

        let searchBases: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
        ]

        for candidate in catalog {
            guard let appURL = firstExisting(names: candidate.appNames, in: searchBases, fm: fm) else {
                continue
            }

            let userExtensionsURL = home
                .appendingPathComponent(candidate.userExtensionsDirName)
                .appendingPathComponent("extensions", isDirectory: true)

            let settingsURL = appSupportBase
                .appendingPathComponent(candidate.appSupportDirName)
                .appendingPathComponent("User/settings.json")

            found.append(IDEInfo(
                name: candidate.name,
                appURL: appURL,
                userExtensionsURL: userExtensionsURL,
                settingsURL: settingsURL
            ))
        }

        return found
    }

    /// The first (preferred) installed IDE, or nil if none found.
    public static var preferred: IDEInfo? {
        installedIDEs().first
    }

    // MARK: - Helpers

    private static func firstExisting(names: [String], in bases: [URL], fm: FileManager) -> URL? {
        for base in bases {
            for name in names {
                let candidate = base.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
