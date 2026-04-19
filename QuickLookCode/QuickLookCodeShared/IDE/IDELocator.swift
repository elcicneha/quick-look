//
//  IDELocator.swift
//  QuickLookCodeShared
//

import Foundation
import Darwin

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

    // MARK: - In-memory cache (process lifetime)

    /// Set by CacheManager.bootstrap(); avoids filesystem scans on the hot path.
    static var _cached: IDEInfo?

    // MARK: - User preference

    private static let selectedIDEKey = "selectedIDE"

    /// Name of the IDE the user picked in the host app's picker, or nil for auto.
    /// Stored in App Group UserDefaults so the Quick Look extension sees the same value.
    public static var selectedIDEName: String? {
        get { sharedDefaults?.string(forKey: selectedIDEKey) }
        set {
            if let v = newValue, !v.isEmpty {
                sharedDefaults?.set(v, forKey: selectedIDEKey)
            } else {
                sharedDefaults?.removeObject(forKey: selectedIDEKey)
            }
        }
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: DiskCacheSchema.appGroup)
    }

    // MARK: - Public API

    /// Returns all IDEs found on the system, in catalog order.
    public static func installedIDEs() -> [IDEInfo] {
        let fm = FileManager.default
        // In a sandboxed app, all Foundation home APIs (`FileManager.homeDirectoryForCurrentUser`,
        // `NSHomeDirectory()`, even `NSHomeDirectoryForUser(NSUserName())`) are remapped to
        // the container home `~/Library/Containers/<bundle-id>/Data/`. The `home-relative-path`
        // entitlement exceptions, however, are resolved by the kernel against the user's REAL
        // home directory — so to construct paths that match the granted exceptions we have to
        // bypass Foundation and read `pw_dir` directly from the user record.
        let realHome = URL(fileURLWithPath: realHomeDirectory(), isDirectory: true)
        let appSupportBase = realHome.appendingPathComponent("Library/Application Support")

        var found: [IDEInfo] = []

        let searchBases: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            realHome.appendingPathComponent("Applications"),
        ]

        for candidate in catalog {
            guard let appURL = firstExisting(names: candidate.appNames, in: searchBases, fm: fm) else {
                continue
            }

            let userExtensionsURL = realHome
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

    /// The first (preferred) installed IDE, or nil if none found. Honors the user's
    /// picker selection (`selectedIDEName`) when that IDE is installed; otherwise falls
    /// back to the first installed IDE in catalog order.
    /// Returns the in-memory cached value if CacheManager has bootstrapped; falls back
    /// to a live filesystem scan otherwise.
    public static var preferred: IDEInfo? {
        if let cached = _cached { return cached }
        let all = installedIDEs()
        if let name = selectedIDEName,
           let match = all.first(where: { $0.name == name }) {
            return match
        }
        return all.first
    }

    // MARK: - Helpers

    /// Returns the current user's real home directory (e.g. `/Users/nehagupta`) even inside
    /// a sandboxed process where Foundation APIs return the container path. Uses `getpwuid`
    /// which reads directly from Open Directory / the user record, bypassing the sandbox
    /// remap. Falls back to `NSHomeDirectory()` on the extremely unlikely failure case.
    private static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let s = String(cString: dir)
            if !s.isEmpty { return s }
        }
        NSLog("[QuickLookCode] IDELocator: getpwuid returned no home — falling back to NSHomeDirectory")
        return NSHomeDirectory()
    }

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
