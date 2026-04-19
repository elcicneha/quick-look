//
//  CacheManager.swift
//  QuickLookCodeShared
//
//  Manages a three-layer cache for the preview render pipeline:
//
//    L3 — App Group disk cache (survives process death).
//         Invalidated by: mtime mismatch on IDE app / settings.json, schema bump, Refresh.
//    L2 — Process-lifetime in-memory singletons (static vars on IDELocator/ThemeLoader/GrammarLoader).
//         Populated from L3 on first bootstrap(); survive across space-bar presses while
//         macOS keeps the QL extension host warm.
//    L1 — Per-render work: file read, tokenizeLine2 call, HTML build, WKWebView paint.
//         Only this runs on the hot path after the first preview.
//
//  Call bootstrap() before every render. The hot path is a single boolean check
//  (`_loadedCacheVersion != nil && !_needsReload`) — no disk I/O, no JSON parse.
//
//  Cross-process invalidation: when refresh() is called in the host app it rebuilds
//  L3 on disk and posts a Darwin notification. The Quick Look extension runs in a
//  separate process with its own in-memory L2; it registers a notify_register_dispatch
//  observer on first bootstrap, and the handler flips _needsReload. The extension's
//  next preview does one loadFromDisk() to swap its in-memory copy for the fresh one,
//  then returns to the fast path. macOS delivers Darwin notifications in microseconds,
//  with no polling and no disk reads on preview-to-preview calls.
//

import Foundation

public enum CacheManager {

    // MARK: - State

    /// Darwin notification posted by refresh(); observed in every process that called
    /// bootstrap(). Sandboxed macOS apps silently drop Darwin notifications whose name
    /// is NOT prefixed with an app-group the app belongs to, so the name lives under
    /// the same `group.*` prefix as `DiskCacheSchema.appGroup`.
    private static let cacheUpdatedNotification = "\(DiskCacheSchema.appGroup).cache-refreshed"

    /// cacheVersion UUID from the manifest we last loaded into L2. nil until first load.
    private static var _loadedCacheVersion: String?

    /// Set by the Darwin notification handler when another process (typically the host
    /// app's Refresh button) rewrites L3. The next bootstrap() reloads L2 from disk.
    private static var _needsReload = false

    /// One-time guard so we register the Darwin observer exactly once per process.
    private static var _observerInstalled = false

    private static let _lock = NSLock()

    /// C callback for the Darwin notification observer. @convention(c) closures cannot
    /// capture local context — it only touches `CacheManager`'s statics, which are
    /// globals under the hood.
    private static let notificationCallback: CFNotificationCallback = { _, _, _, _, _ in
        CacheManager._lock.lock()
        CacheManager._needsReload = true
        CacheManager._lock.unlock()
        NSLog("[QuickLookCode] CacheManager: received cross-process refresh notification")
    }

    // MARK: - Public API

    /// Ensures the cache is populated and fresh.
    ///
    /// Hot path (after the first successful bootstrap, no refresh in flight):
    /// one boolean check under a lock, ~nanoseconds. No disk I/O.
    ///
    /// Slow path (first call, or after a refresh notification): one loadFromDisk()
    /// or a full rebuildAndLoad() if the on-disk cache is invalid.
    ///
    /// Blocks the calling thread while loading / rebuilding; should be called on a
    /// background thread (e.g. inside preparePreviewOfFile or at app launch).
    @discardableResult
    public static func bootstrap() -> Bool {
        ensureObserverInstalled()

        _lock.lock()
        let isPopulated = _loadedCacheVersion != nil
        let needsReload = _needsReload
        if needsReload { _needsReload = false }
        _lock.unlock()

        // Fast path: L2 is populated and no refresh has been signalled since.
        if isPopulated && !needsReload {
            return true
        }

        // First bootstrap in this process, or a refresh notification arrived.
        let reason = isPopulated ? "reload-after-notification" : "first-bootstrap"
        let ok: Bool
        if cacheIsValid() {
            ok = loadFromDisk()
            NSLog("[QuickLookCode] CacheManager: %@ → loadFromDisk ok=%d theme=%@",
                  reason, ok ? 1 : 0, ThemeLoader._cachedTheme?.name ?? "nil")
        } else {
            clearInMemoryCaches()
            ok = rebuildAndLoad()
            NSLog("[QuickLookCode] CacheManager: %@ → rebuildAndLoad ok=%d theme=%@",
                  reason, ok ? 1 : 0, ThemeLoader._cachedTheme?.name ?? "nil")
        }

        if ok {
            // Drop tokenizer state after a cross-process refresh so the next tokenize
            // re-runs initGrammar with the new theme. (TokenizerEngine also auto-
            // detects theme changes via themeJSON string compare, so this is defense
            // in depth.)
            if isPopulated {
                Task { await TokenizerEngine.shared.invalidate() }
            }
            _lock.lock()
            _loadedCacheVersion = readManifestCacheVersion()
            _lock.unlock()
        }
        return ok
    }

    /// Forces a full cache rebuild. Call from the host app's Refresh button.
    /// Clears this process's L2 singletons, rewrites L3 on disk, and broadcasts a
    /// Darwin notification so other processes (i.e. the Quick Look extension) reload
    /// their in-memory copy on their next bootstrap().
    public static func refresh() {
        _lock.lock()
        _loadedCacheVersion = nil
        _needsReload = false
        _lock.unlock()

        clearInMemoryCaches()
        _ = rebuildAndLoad()

        _lock.lock()
        _loadedCacheVersion = readManifestCacheVersion()
        _lock.unlock()

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(cacheUpdatedNotification as CFString),
            nil, nil, true
        )
        NSLog("[QuickLookCode] CacheManager: refresh complete, posted notification (theme=%@)",
              ThemeLoader._cachedTheme?.name ?? "nil")
    }

    // MARK: - Darwin notification observer

    /// Registers a one-shot observer for the cross-process refresh notification.
    /// Handler flips _needsReload so the next bootstrap() takes the slow path
    /// exactly once, then returns to the fast path.
    private static func ensureObserverInstalled() {
        _lock.lock()
        if _observerInstalled { _lock.unlock(); return }
        _observerInstalled = true
        _lock.unlock()

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            notificationCallback,
            cacheUpdatedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - L2 invalidation

    private static func clearInMemoryCaches() {
        IDELocator._cached = nil
        ThemeLoader._cachedTheme = nil
        ThemeLoader._cachedSerializedTheme = nil
        GrammarLoader.invalidateStaticCaches()
        Task { await TokenizerEngine.shared.invalidate() }
    }

    /// Reads just the cacheVersion UUID from the on-disk manifest.
    /// Returns nil if there is no App Group container (ad-hoc distribution build)
    /// or no cache has been written yet.
    private static func readManifestCacheVersion() -> String? {
        guard let dir = cacheDir else { return nil }
        let url = dir.appendingPathComponent(DiskCacheSchema.manifestFile)
        guard
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(DiskCacheSchema.Manifest.self, from: data)
        else { return nil }
        return manifest.cacheVersion
    }

    // MARK: - Cache directory

    /// Shared App Group container path for cache files.
    public static var cacheDir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DiskCacheSchema.appGroup)?
            .appendingPathComponent("Library/Caches/\(DiskCacheSchema.dirName)", isDirectory: true)
    }

    /// Timestamp of the last successful cache build, or nil if no cache exists.
    public static var lastBuiltAt: Date? {
        guard let dir = cacheDir else { return nil }
        let url = dir.appendingPathComponent(DiskCacheSchema.manifestFile)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(DiskCacheSchema.Manifest.self, from: data)
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: manifest.builtAt)
    }

    // MARK: - Validity check

    private static func cacheIsValid() -> Bool {
        guard let dir = cacheDir else { return false }
        let manifestURL = dir.appendingPathComponent(DiskCacheSchema.manifestFile)
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(DiskCacheSchema.Manifest.self, from: data)
        else { return false }

        guard manifest.schemaVersion == DiskCacheSchema.schemaVersion else { return false }

        let fm = FileManager.default

        // IDE app must still exist at the same path with the same mtime.
        guard
            fm.fileExists(atPath: manifest.ideAppPath),
            let ideAttrs = try? fm.attributesOfItem(atPath: manifest.ideAppPath),
            let ideMtime = (ideAttrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate,
            abs(ideMtime - manifest.ideAppMtime) < 2.0
        else { return false }

        // settings.json mtime must match (detects theme-name change).
        let settingsPath = dir.appendingPathComponent(DiskCacheSchema.ideFile)
        if let ideData = try? Data(contentsOf: settingsPath),
           let cachedIDE = try? JSONDecoder().decode(DiskCacheSchema.CachedIDE.self, from: ideData),
           fm.fileExists(atPath: cachedIDE.settingsPath) {
            if let attrs = try? fm.attributesOfItem(atPath: cachedIDE.settingsPath),
               let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate,
               abs(mtime - manifest.settingsFileMtime) > 2.0 {
                return false
            }
        }

        return true
    }

    // MARK: - Load from disk

    @discardableResult
    private static func loadFromDisk() -> Bool {
        guard let dir = cacheDir else { return false }

        // IDE
        let ideURL = dir.appendingPathComponent(DiskCacheSchema.ideFile)
        if let data = try? Data(contentsOf: ideURL),
           let cached = try? JSONDecoder().decode(DiskCacheSchema.CachedIDE.self, from: data) {
            IDELocator._cached = cached.toIDEInfo()
        }

        // Theme
        let themeURL = dir.appendingPathComponent(DiskCacheSchema.themeFile)
        if let data = try? Data(contentsOf: themeURL),
           let cached = try? JSONDecoder().decode(DiskCacheSchema.CachedTheme.self, from: data) {
            ThemeLoader._cachedTheme = cached.themeData.toThemeData()
            ThemeLoader._cachedSerializedTheme = cached.serializedThemeJSON
        }

        // Grammar index
        let indexURL = dir.appendingPathComponent(DiskCacheSchema.grammarIndexFile)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode([String: String].self, from: data) {
            let urlIndex = Dictionary(
                uniqueKeysWithValues: index.map { ($0.key, URL(fileURLWithPath: $0.value)) }
            )
            GrammarLoader.seedURLIndex(urlIndex)
        }

        return IDELocator._cached != nil && ThemeLoader._cachedTheme != nil
    }

    // MARK: - Rebuild

    @discardableResult
    private static func rebuildAndLoad() -> Bool {
        guard let dir = cacheDir else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. Detect IDE.
        guard let ide = IDELocator.installedIDEs().first else {
            NSLog("[QuickLookCode] CacheManager: no IDE found, cache not built")
            return false
        }

        // 2. Load theme from disk.
        guard let theme = try? ThemeLoader.loadActiveThemeFromDisk(from: ide) else {
            NSLog("[QuickLookCode] CacheManager: could not load theme, cache not built")
            return false
        }
        guard let serializedTheme = try? SourceCodeRenderer.serializeTheme(theme) else {
            NSLog("[QuickLookCode] CacheManager: could not serialize theme")
            return false
        }

        // 3. Build grammar index (one-time directory walk for all known languages).
        let grammarIndex = buildGrammarIndex(ide: ide)

        // 4. Determine mtimes for manifest.
        let ideAppMtime    = mtime(of: ide.appURL.path)
        let settingsMtime  = mtime(of: ide.settingsURL.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Write ide.json
        let cachedIDE = DiskCacheSchema.CachedIDE(
            name: ide.name,
            appPath: ide.appURL.path,
            userExtensionsPath: ide.userExtensionsURL.path,
            settingsPath: ide.settingsURL.path
        )
        if let data = try? encoder.encode(cachedIDE) {
            try? data.write(to: dir.appendingPathComponent(DiskCacheSchema.ideFile), options: .atomic)
        }

        // Write theme.json
        let tokenColorRecords = theme.tokenColors.map {
            DiskCacheSchema.TokenColorRecord(
                scopes: $0.scopes,
                foreground: $0.foreground,
                fontStyle: $0.fontStyle
            )
        }
        let themeRecord = DiskCacheSchema.ThemeRecord(
            name: theme.name,
            isDark: theme.isDark,
            background: theme.background,
            foreground: theme.foreground,
            tokenColors: tokenColorRecords
        )
        let cachedTheme = DiskCacheSchema.CachedTheme(
            themeData: themeRecord,
            serializedThemeJSON: serializedTheme
        )
        if let data = try? encoder.encode(cachedTheme) {
            try? data.write(to: dir.appendingPathComponent(DiskCacheSchema.themeFile), options: .atomic)
        }

        // Write grammar-index.json
        let indexStrings = grammarIndex.mapValues { $0.path }
        if let data = try? encoder.encode(indexStrings) {
            try? data.write(
                to: dir.appendingPathComponent(DiskCacheSchema.grammarIndexFile),
                options: .atomic
            )
        }

        // Write manifest.json last — its presence signals a complete cache.
        let manifest = DiskCacheSchema.Manifest(
            schemaVersion: DiskCacheSchema.schemaVersion,
            cacheVersion: UUID().uuidString,
            builtAt: Date().timeIntervalSinceReferenceDate,
            ideAppPath: ide.appURL.path,
            ideAppMtime: ideAppMtime,
            settingsFileMtime: settingsMtime
        )
        if let data = try? encoder.encode(manifest) {
            try? data.write(
                to: dir.appendingPathComponent(DiskCacheSchema.manifestFile),
                options: .atomic
            )
        }

        // 5. Populate L2 in-memory singletons.
        IDELocator._cached = ide
        ThemeLoader._cachedTheme = theme
        ThemeLoader._cachedSerializedTheme = serializedTheme
        GrammarLoader.seedURLIndex(grammarIndex)

        NSLog("[QuickLookCode] CacheManager: cache rebuilt for %@ (%d grammar entries)",
              ide.name, grammarIndex.count)
        return true
    }

    // MARK: - Grammar index

    private static func buildGrammarIndex(ide: IDEInfo) -> [String: URL] {
        let loader = GrammarLoader(ide: ide)
        var index: [String: URL] = [:]
        for term in FileTypeRegistry.allGrammarSearchTerms {
            if let url = loader.grammarURL(for: term) {
                index[term] = url
            }
        }
        return index
    }

    // MARK: - Helpers

    private static func mtime(of path: String) -> Double {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let date  = attrs[.modificationDate] as? Date
        else { return 0 }
        return date.timeIntervalSinceReferenceDate
    }
}
