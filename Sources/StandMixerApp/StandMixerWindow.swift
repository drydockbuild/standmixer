import SwiftUI
import StandMixerCore

struct StandMixerWindow: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingSave = false
    @State private var previewFiles = false

    private var title: String { StandMixerPreset(rawValue: store.presetKey)?.rawValue.capitalized ?? store.presetName }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Text(title).font(.system(size: 24, weight: .semibold)).tracking(-0.6).lineLimit(1)
                    Text(store.installationLabel)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(StandMixerTheme.muted)
                        .lineLimit(1).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(StandMixerTheme.surface.opacity(0.65), in: Capsule())
                        .help(store.installationDetail)
                    Spacer(minLength: 10)
                    CurrentSettingsStatus(controller: store.currentSettings).frame(maxWidth: 160)
                    if store.hasDraftUndoHistory {
                        Button { store.undoDraft() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(StandMixerSecondaryButtonStyle()).disabled(!store.canUndoDraft)
                            .help("Undo the last draft change (⌘Z)")
                    }
                    if store.canRedoDraft {
                        Button { store.redoDraft() } label: { Image(systemName: "arrow.uturn.forward") }
                            .buttonStyle(.plain).frame(width: 24, height: 30)
                            .accessibilityLabel("Redo draft change").help("Redo draft change (⇧⌘Z)")
                    }
                    if store.isEditing {
                        Button("Cancel") { store.cancelEditing() }.buttonStyle(StandMixerSecondaryButtonStyle())
                        Button("Save") { store.saveEditing() }.buttonStyle(StandMixerPrimaryButtonStyle())
                    } else {
                        Button("Edit…") { store.beginEditing() }.buttonStyle(StandMixerSecondaryButtonStyle()).disabled(store.isChecking)
                    }
                }
                .frame(height: 44)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            if store.isEditing { RoutingView() }
                            else { PresetChangesView(controller: store.currentSettings) }
                        }
                        .padding(.bottom, 5)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .task(id: store.isEditing) {
                        let args = ProcessInfo.processInfo.arguments
                        guard store.isEditing, args.contains("--snapshot") else { return }
                        let target = ["--effort", "--team"].compactMap { flag -> String? in
                            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1),
                                  WorkCategory(rawValue: args[index + 1]) != nil else { return nil }
                            return store.selectedPlatform.rawValue + "-" + args[index + 1]
                        }.first
                        guard let target else { return }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        scroll.scrollTo(target, anchor: .center)
                    }
                }
                footer.padding(.top, 8)
            }
            .padding(.horizontal, 18).padding(.bottom, 10).padding(.top, 0)
        }
        .background(LinearGradient(colors: StandMixerTheme.windowGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(StandMixerTheme.ink).tint(StandMixerTheme.accent)
        .onCommand(Selector(("undo:")), perform: store.canUndoDraft ? { store.undoDraft() } : nil)
        .onCommand(Selector(("redo:")), perform: store.canRedoDraft ? { store.redoDraft() } : nil)
        .task {
            await store.refreshConnections()
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--snapshot"), ["--advanced", "--customize", "--team", "--effort"].contains(where: args.contains) { store.beginEditing() }
        }
        .sheet(item: $store.preview, onDismiss: { previewFiles = false }) {
            PreviewSheet(preview: $0, initiallyShowingFiles: previewFiles).environmentObject(store)
        }
        .sheet(isPresented: $showingSave) { SavePresetSheet().environmentObject(store) }
        .sheet(item: $store.uninstallPreview) { UninstallSheet(preview: $0).environmentObject(store) }
        .alert("StandMixer couldn’t finish", isPresented: Binding(get: { store.errorMessage != nil && store.preview == nil && store.uninstallPreview == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("Restore the last applied settings?", isPresented: $store.showRestoreConfirmation, titleVisibility: .visible) {
            Button("Restore") { store.restoreLast() }
        } message: { Text("The previous tool settings will be restored from StandMixer’s backup.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                StandMixerBrandMark().frame(width: 31, height: 31)
                Text("StandMixer").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.5)
            }
            .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 8)
            Text("Presets").font(.system(size: 11, weight: .semibold)).foregroundStyle(StandMixerTheme.muted)
                .padding(.horizontal, 10).padding(.bottom, 9)
            VStack(spacing: 7) {
                ForEach(StandMixerPreset.allCases) { preset in
                    SidebarPreset(preset: preset, selected: store.presetKey == preset.rawValue) { store.selectPreset(preset.rawValue) }
                }
            }
            HStack {
                Text("Saved").font(.system(size: 11, weight: .semibold)).foregroundStyle(StandMixerTheme.muted)
                Spacer()
                Button { showingSave = true } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).disabled(store.isEditing).help("Save current setup as a preset").accessibilityLabel("Save current preset")
            }
            .padding(.horizontal, 10).padding(.top, 23).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if store.hasPreviousDraft {
                        savedRow("Previous draft", key: "previous-draft", symbol: "clock.arrow.circlepath")
                    }
                    ForEach(store.savedPresets) { preset in
                        savedRow(preset.name, key: preset.id.uuidString, symbol: "bookmark")
                            .contextMenu {
                                Button("Delete preset", role: .destructive) { store.deleteSavedPreset(id: preset.id) }.disabled(store.isEditing)
                            }
                    }
                    if store.presetKey == "custom" {
                        savedRow("Custom draft", key: "custom", symbol: "slider.horizontal.3")
                    }
                    if store.savedPresets.isEmpty, !store.hasPreviousDraft, store.presetKey != "custom" {
                        Button("Save current preset…") { showingSave = true }.disabled(store.isEditing)
                            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(StandMixerTheme.muted)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 14)
            HStack {
                Text("Tools").font(.system(size: 11, weight: .semibold)).foregroundStyle(StandMixerTheme.muted)
                Spacer()
                Button { Task { await store.refreshConnections() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    .buttonStyle(.plain).disabled(store.isChecking).help("Refresh local CLI detection")
            }
            .padding(.horizontal, 10).padding(.bottom, 7)
            ForEach(AgentPlatform.allCases) { platform in
                HStack(spacing: 7) {
                    Circle().fill(StandMixerTheme.provider(platform)).frame(width: 7, height: 7)
                    Text(platform.displayName).font(.system(size: 11, weight: .medium))
                    ConnectionControl(platform: platform)
                    Spacer(minLength: 0)
                    Toggle("Enable \(platform.displayName)", isOn: Binding(
                        get: { store.enabledPlatforms.contains(platform) },
                        set: { store.setPlatformEnabled(platform, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .tint(StandMixerTheme.provider(platform)).disabled(!store.installedPlatforms.contains(platform))
                        .help(store.installedPlatforms.contains(platform) ? "Use \(platform.displayName) for this setup" : "Local CLI not detected")
                }
                .padding(.horizontal, 10).frame(height: 30)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
        .frame(width: 205)
        .background(LinearGradient(colors: StandMixerTheme.sidebarGradient, startPoint: .topTrailing, endPoint: .bottomLeading))
        .overlay(alignment: .trailing) { Rectangle().fill(StandMixerTheme.line.opacity(0.8)).frame(width: 1) }
    }

    private func savedRow(_ name: String, key: String, symbol: String) -> some View {
        let selected = store.presetKey == key
        return Button { if key != "custom" { store.selectPreset(key) } } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 15)
                Text(name).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
            }
            .padding(.horizontal, 10).frame(height: 31)
            .background(selected ? StandMixerTheme.surface.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).foregroundStyle(selected ? StandMixerTheme.accent : StandMixerTheme.ink)
        .help(name).accessibilityAddTraits(selected ? .isSelected : [])
    }


    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = store.notice {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: store.noticeIsWarning ? "info.circle" : "checkmark.circle.fill")
                        .foregroundStyle(store.noticeIsWarning ? StandMixerTheme.amber : StandMixerTheme.green)
                    Text(notice).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss notification")
                }
                .padding(.horizontal, 11)
            }
            HStack(spacing: 10) {
                KnownChangeSummary(controller: store.currentSettings)
                Spacer(minLength: 2)
                if store.isPreparingPreview {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { store.cancelPreparingPreview() }.buttonStyle(StandMixerSecondaryButtonStyle())
                } else {
                    Button { previewFiles = true; store.preparePreview() } label: {
                        Label("File diffs", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(StandMixerSecondaryButtonStyle()).disabled(!store.canPreview)
                }
                Button {
                    previewFiles = false
                    store.preparePreview()
                } label: { Text(store.isPreparingPreview ? "Preparing…" : "Review & apply") }
                    .buttonStyle(StandMixerPrimaryButtonStyle())
                    .disabled(store.isPreparingPreview || !store.canPreview)
                    .opacity(store.isPreparingPreview || !store.canPreview ? 0.5 : 1)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 15).frame(minHeight: 58)
            .background(StandMixerTheme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(StandMixerTheme.line, lineWidth: 1))
            .shadow(color: StandMixerTheme.accent.opacity(0.07), radius: 10, y: 5)
        }
    }
}

private struct SidebarPreset: View {
    let preset: StandMixerPreset
    let selected: Bool
    let action: () -> Void
    private var detail: String {
        switch preset {
        case .fast: return "Lighter models"
        case .optimized: return "Best fit for each task"
        case .high: return "Multiple agents"
        }
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(preset.rawValue.capitalized).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    if preset == .optimized {
                        Text("DEFAULT").font(.system(size: 6.5, weight: .bold)).tracking(0.6).foregroundStyle(StandMixerTheme.accent)
                    }
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 65)
            .background(selected ? StandMixerTheme.surface : StandMixerTheme.surface.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? StandMixerTheme.accent : StandMixerTheme.line.opacity(0.85), lineWidth: selected ? 1.6 : 1))
            .shadow(color: selected ? StandMixerTheme.accent.opacity(0.12) : .clear, radius: 7, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).accessibilityLabel(preset.title + ", " + detail).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct KnownChangeSummary: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var controller: CurrentSettingsController
    private var count: Int {
        store.enabledPlatforms.reduce(0) { total, platform in
            return total + WorkCategory.allCases.filter { category in
                let proposed = store.route(category, in: platform)
                let finding = controller.run(for: platform).isPreviousReport ? nil : controller.finding(platform: platform, category: category)
                let current = category == .coordinator
                    ? (store.appliedController(in: platform) ?? (proposed.isAutoController ? nil : finding)) : finding
                return RouteComparison(current: current, proposed: proposed, previousTeamMode: store.appliedRoute(category, in: platform)?.teamMode).hasKnownChanges
            }.count
        }
    }
    var body: some View {
        HStack(spacing: 9) {
            if count > 0 {
                Text(String(count)).font(.system(size: 17, weight: .semibold)).foregroundStyle(StandMixerTheme.accent)
                    .frame(width: 34, height: 34).background(StandMixerTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StandMixerTheme.accent.opacity(0.55), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(count > 0 ? "\(count == 1 ? "Task change" : "Task changes")" : "Preset ready")
                    .font(.system(size: 11, weight: .semibold))
                Text(count > 0 ? "Reported differences" : "Review before applying")
                    .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
            }
        }
    }
}

struct RoutingView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if store.enabledPlatforms.isEmpty {
            PresetChangesView(controller: store.currentSettings)
        } else {
            AssignmentTable(platforms: AgentPlatform.allCases.filter { store.enabledPlatforms.contains($0) }, detail: { _ in "" }) { platform, category in
                RouteRow(currentSettings: store.currentSettings, platform: platform, category: category)
            }
        }
    }
}
