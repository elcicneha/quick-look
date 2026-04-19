//
//  ContentView.swift
//  QuickLookCode
//

import SwiftUI
import QuickLookCodeShared

struct ContentView: View {

    @State private var status: StatusInfo = .loading
    @State private var lastRefreshed: Date? = nil
    @State private var isRefreshing = false
    @State private var installedIDEs: [IDEInfo] = []
    @State private var selectedIDEName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Peekaboo", systemImage: "doc.text.magnifyingglass")
                    .font(.title2.bold())
                Spacer()
                Button(action: refresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .help("Reload IDE, theme, and grammar caches. Use after changing your theme in the IDE.")
            }

            Divider()

            switch status {
            case .loading:
                ProgressView("Detecting IDE…")

            case .noIDE:
                Label("No supported IDE found", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
                Text("Install VS Code or Antigravity to enable syntax-highlighted previews.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

            case .ready(let info):
                if installedIDEs.count > 1 {
                    Picker("IDE", selection: $selectedIDEName) {
                        ForEach(installedIDEs, id: \.name) { ide in
                            Text(ide.name).tag(ide.name)
                        }
                    }
                    .onChange(of: selectedIDEName) { newValue in
                        selectIDE(newValue)
                    }
                } else {
                    LabeledContent("IDE", value: info.ideName)
                }
                LabeledContent("Path", value: info.idePath)
                LabeledContent("Active Theme", value: info.themeName)
                LabeledContent("Theme Type", value: info.isDark ? "Dark" : "Light")
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: info.background))
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                    Text(info.background)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

            case .themeError(let ideName, let error):
                Label(ideName, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Label("Could not load theme: \(error)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if let date = lastRefreshed {
                Divider()
                Text("Cache last refreshed \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 180)
        .task { await loadStatus() }
    }

    // MARK: - Loading

    private func loadStatus() async {
        // Bootstrap the cache (builds it if missing; no-op if already current).
        await Task.detached(priority: .userInitiated) {
            _ = CacheManager.bootstrap()
        }.value

        lastRefreshed = CacheManager.lastBuiltAt
        installedIDEs = IDELocator.installedIDEs()

        guard let ide = IDELocator.preferred else {
            status = .noIDE
            return
        }
        selectedIDEName = ide.name
        do {
            let theme = try ThemeLoader.loadActiveTheme(from: ide)
            status = .ready(ReadyInfo(
                ideName: ide.name,
                idePath: ide.appURL.path,
                themeName: theme.name,
                isDark: theme.isDark,
                background: theme.background
            ))
        } catch {
            status = .themeError(ideName: ide.name, error: error.localizedDescription)
        }
    }

    private func refresh() {
        isRefreshing = true
        status = .loading
        Task {
            // Rebuild runs on a background thread; state updates stay on MainActor.
            await Task.detached(priority: .userInitiated) {
                CacheManager.refresh()
            }.value
            isRefreshing = false
            lastRefreshed = CacheManager.lastBuiltAt
            await loadStatus()
        }
    }

    /// Persists the user's IDE pick in App Group defaults and rebuilds the cache so
    /// the new IDE's theme / grammars take effect in both the host app and the extension.
    private func selectIDE(_ name: String) {
        guard name != (IDELocator.selectedIDEName ?? "") else { return }
        IDELocator.selectedIDEName = name
        refresh()
    }

    // MARK: - State

    enum StatusInfo {
        case loading
        case noIDE
        case ready(ReadyInfo)
        case themeError(ideName: String, error: String)
    }

    struct ReadyInfo {
        let ideName: String
        let idePath: String
        let themeName: String
        let isDark: Bool
        let background: String
    }
}

// MARK: - Color from hex

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    ContentView()
}
