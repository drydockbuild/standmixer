import SwiftUI
import AppKit
import Darwin

@main
enum StandMixerEntryPoint {
    static func main() {
        if let status = StandMixerCommandLine.runIfRequested() { exit(status) }
        StandMixerApp.main()
    }
}

struct StandMixerApp: App {
    @NSApplicationDelegateAdaptor(StandMixerApplicationDelegate.self) private var delegate
    @StateObject private var store = AppStore()

    private var snapshotAppearance: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--snapshot"), let index = arguments.firstIndex(of: "--snapshot-appearance"),
              arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup("StandMixer") {
            StandMixerWindow()
                .environmentObject(store)
                .frame(minWidth: 940, minHeight: 680)
                .preferredColorScheme(snapshotAppearance)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Settings") {
                Button("Refresh Connections") { Task { await store.refreshConnections() } }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Preview Changes…") { store.preparePreview() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.isPreparingPreview || !store.canPreview)
                Button("Read Preferences") { store.currentSettings.refreshAll(platforms: store.enabledPlatforms) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Restore Applied Settings…") { store.showRestoreConfirmation = true }
                    .disabled(!store.canRestore || store.isEditing)
                Divider()
                Button("Uninstall StandMixer…") { store.prepareUninstall() }
            }
        }
    }
}

final class StandMixerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
            let destination = arguments[index + 1]
            Task { @MainActor in
                // Render the actual window after read-only detection, with a bounded fallback.
                for _ in 0..<80 {
                    if AppStore.isReadyForSnapshot { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                let mainWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                // Ignore a restored window size from an older app version for reproducible UI QA.
                if mainWindow?.attachedSheet == nil {
                    mainWindow?.setContentSize(NSSize(width: 1000, height: 700))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // Advanced, team and effort editing now live in the main window.
                // Legacy editor flags still select Advanced mode for reproducible captures.
                let captureWindow = mainWindow?.attachedSheet ?? mainWindow
                guard let content = captureWindow?.contentView else {
                    exit(1)
                }
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: destination))
                    }
                }
                // An active sheet can defer NSApplication termination; capture mode has no live imports.
                exit(0)
            }
        } else {
            Task { @MainActor in
                let defaults = UserDefaults.standard
                let versionKey = "presetFirstLayoutVersion"
                guard defaults.integer(forKey: versionKey) < 2 else { return }
                var window: NSWindow?
                for _ in 0..<40 {
                    window = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                    if window != nil { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard let window, let screen = window.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                let size = NSSize(width: min(1000, max(940, visible.width - 40)),
                                  height: min(700, max(680, visible.height - 40)))
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                              y: visible.midY - window.frame.height / 2))
                defaults.set(2, forKey: versionKey)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
