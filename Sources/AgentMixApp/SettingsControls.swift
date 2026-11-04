import SwiftUI
import AgentMixCore

struct SavePresetSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Save preset").font(.system(size: 22, weight: .semibold, design: .rounded))
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(AgentMixTheme.amber) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(AgentMixSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try store.saveCurrentPreset(name: name); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(AgentMixPrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(25).frame(width: 390).background(AgentMixTheme.background)
    }
}

struct ConnectionControl: View {
    @EnvironmentObject private var store: AppStore
    let platform: AgentPlatform
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 10))
                .foregroundStyle(AgentMixTheme.muted)
                .frame(width: 14, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(platform.displayName) connection and availability")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 9) {
                    ProviderMark(platform: platform)
                    Text(platform.displayName).font(.system(size: 15, weight: .semibold))
                }
                Toggle("Use for presets and apply", isOn: Binding(
                    get: { store.enabledPlatforms.contains(platform) },
                    set: { store.setPlatformEnabled(platform, enabled: $0) }))
                    .toggleStyle(.switch).font(.system(size: 12))
                    .disabled(!store.installedPlatforms.contains(platform))
                if let status = store.connection(for: platform) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status.version.map { "Version \($0)" } ?? (status.isInstalled ? "Version unavailable" : "Not detected"))
                            .font(.system(size: 11, weight: .medium))
                        if let path = status.path {
                            Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(status.detail).font(.system(size: 10)).foregroundStyle(AgentMixTheme.muted)
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("CLI detection does not verify your subscription or model access. Enable the tools you want StandMixer to use.")
                    .font(.system(size: 10)).foregroundStyle(AgentMixTheme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Refresh") { Task { await store.refreshConnections() } }
                    .buttonStyle(AgentMixSecondaryButtonStyle()).disabled(store.isChecking)
            }
            .padding(20).frame(width: 320).background(AgentMixTheme.background).foregroundStyle(AgentMixTheme.ink)
        }
    }
}

struct AgentCountControl: View {
    @EnvironmentObject private var store: AppStore
    let category: WorkCategory
    var platform: AgentPlatform? = nil
    var highlighted = false
    var body: some View {
        Picker("Agents", selection: Binding(
            get: { store.route(category, in: platform ?? store.selectedPlatform).additionalAgents.count + 1 },
            set: { count in store.editProfile(platform ?? store.selectedPlatform) { store.setAgentCount(count, for: category) } })) {
            ForEach(1...4, id: \.self) { count in
                Text("\(count) \(count == 1 ? "agent" : "agents")").tag(count)
            }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.mini)
        .font(.system(size: 10)).frame(width: 76)
        .tint(highlighted ? AgentMixTheme.accent : AgentMixTheme.ink)
        .accessibilityLabel("\(category.displayTitle) agent count")
    }
}

struct ResultModeControl: View {
    @EnvironmentObject private var store: AppStore
    let category: WorkCategory
    var platform: AgentPlatform? = nil
    var highlighted = false
    var body: some View {
        Picker("Result", selection: Binding(
            get: { store.route(category, in: platform ?? store.selectedPlatform).resultMode },
            set: { mode in store.editProfile(platform ?? store.selectedPlatform) { store.setResultMode(mode, for: category) } })) {
            ForEach(RouteResultMode.allCases) { Text($0.displayTitle).tag($0) }
        }
        .pickerStyle(.menu).controlSize(.mini).font(.system(size: 10)).frame(width: 134)
        .tint(highlighted ? AgentMixTheme.accent : AgentMixTheme.ink)
        .accessibilityLabel("\(category.displayTitle) result handling")
        .help(store.route(category, in: platform ?? store.selectedPlatform).resultMode.explanation)
    }
}

extension RouteResultMode {
    var displayTitle: String {
        switch self { case .coordinator: return "Controller"; case .user: return "User"; case .ai: return "AI" }
    }
    var explanation: String {
        switch self {
        case .coordinator: return "The controller combines the agents’ results."
        case .user: return "You choose which result to use."
        case .ai: return "The judge compares the agents’ results."
        }
    }
}
