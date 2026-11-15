import SwiftUI
import StandMixerCore

/// A shared task row connects its label and both assignments.
struct PresetChangesView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var controller: CurrentSettingsController
    var platforms: Set<AgentPlatform>? = nil
    var showEffort = false
    private var selectedPlatforms: Set<AgentPlatform> { platforms ?? store.enabledPlatforms }

    var body: some View {
        if selectedPlatforms.isEmpty {
            ContentUnavailableView(store.isChecking ? "Finding local tools" : "Enable a tool", systemImage: "switch.2",
                                   description: Text("Choose an installed tool in the sidebar to see its assignments."))
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            AssignmentTable(platforms: AgentPlatform.allCases.filter { selectedPlatforms.contains($0) }, detail: { _ in "" }, allowsEditing: !showEffort) { platform, category in
                PresetAssignmentRow(controller: controller, platform: platform, category: category, showEffort: showEffort)
            }
        }
    }
}

private struct PresetAssignmentRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var controller: CurrentSettingsController
    let platform: AgentPlatform
    let category: WorkCategory
    var showEffort = false
    @State private var showingDetails = false
    private var route: Route { store.route(category, in: platform) }
    private var current: ImportedRoute? {
        if let baseline = store.editBaselineRoute(category, in: platform) {
            return ImportedRoute(category: category, modelID: baseline.modelID, effort: baseline.effort,
                additionalAgents: baseline.additionalAgents.map(ImportedAgentAssignment.init),
                resultMode: baseline.resultMode, judgeModelID: baseline.judgeModelID)
        }
        if category == .coordinator {
            if let applied = store.appliedController(in: platform) { return applied }
            if route.isAutoController { return nil }
        }
        guard !controller.run(for: platform).isPreviousReport else { return nil }
        let finding = controller.finding(platform: platform, category: category)
        return finding?.hasKnownSettings == true ? finding : nil
    }
    private var comparison: RouteComparison { RouteComparison(current: current, proposed: route, previousTeamMode: store.editBaselineRoute(category, in: platform)?.teamMode ?? store.appliedRoute(category, in: platform)?.teamMode) }
    private var highlighted: Bool { comparison.hasKnownChanges || !store.inheritanceChanges(category, in: platform).isEmpty || store.hasEscalationChanges(category, in: platform) }
    private var previousLabel: String { current?.scope == .usual ? "Usually" : "Currently" }

    var body: some View {
        assignments(showsComparison: showEffort)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, route.additionalAgents.isEmpty ? 6 : 3)
            .padding(.top, highlighted ? 4 : 0)
            .background(highlighted ? StandMixerTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(highlighted ? StandMixerTheme.accent.opacity(0.55) : .clear, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if highlighted {
                    Group {
                        if showEffort { ChangedCellBadge(isEdited: store.isEditing) }
                        else {
                            Button { showingDetails = true } label: { ChangedCellBadge(showsDisclosure: true, isEdited: store.isEditing) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Review \(category.displayTitle) changes for \(platform.displayName)")
                                .help("Compare proposed settings with the reported \(current?.scope == .usual ? "recent preference" : "current settings")")
                        }
                    }
                    .padding(.trailing, 9).offset(y: -4)
                }
            }
            .shadow(color: highlighted ? StandMixerTheme.accent.opacity(0.09) : .clear, radius: 4, y: 2)
            .padding(.horizontal, 5).padding(.vertical, route.additionalAgents.isEmpty ? 4 : 2)
            .help(comparisonTooltip)
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) { changeDetails }
    }

    private func assignments(showsComparison: Bool) -> some View {
        VStack(alignment: .leading, spacing: showsComparison ? 2 : 4) {
            assignment(modelID: route.modelID, effort: route.effort,
                       oldModel: current?.modelID, oldPlatform: current?.modelPlatform,
                       oldEffort: current?.effort, number: 1, showsComparison: showsComparison)
            ForEach(Array(route.additionalAgents.enumerated()), id: \.element.id) { index, agent in
                let old = current?.additionalAgents.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                assignment(modelID: agent.modelID, effort: agent.effort,
                           oldModel: old?.modelID, oldPlatform: old?.modelPlatform,
                           oldEffort: old?.effort, number: index + 2,
                           added: current?.additionalAgents.map { !$0.indices.contains(index) } ?? false,
                           showsComparison: showsComparison)
            }
            if category == .debugging {
                StuckEscalationSummary(platform: platform, category: category, showsComparison: showsComparison)
            }
            if showsComparison {
                if let old = current?.additionalAgents, old.count > route.additionalAgents.count {
                    ForEach(Array(old.dropFirst(route.additionalAgents.count).enumerated()), id: \.offset) { _, agent in
                        AssignmentChangeLine(platform: platform, modelID: agent.modelID,
                                             oldPlatform: agent.modelPlatform, removed: true)
                    }
                }
                if route.resultMode == .ai, let judge = route.judgeModelID {
                    AssignmentChangeLine(platform: platform, modelID: judge,
                                         oldModelID: current?.judgeModelID, prefix: "Judge:", previousLabel: previousLabel)
                } else if let judge = current?.judgeModelID {
                    AssignmentChangeLine(platform: platform, modelID: judge, prefix: "Judge:", removed: true)
                }
                if showsMetadata {
                    InlineFlowLayout(spacing: 4, lineSpacing: 2) {
                        if current?.scope == .usual { Text("Recent preference").foregroundStyle(StandMixerTheme.muted) }
                        if showsCount { countText }
                        if showsResult {
                            Text("· Result:")
                            difference(old: current?.resultMode?.displayTitle, new: route.resultMode.displayTitle)
                        }
                    }
                    .font(.system(size: 8.5)).foregroundStyle(StandMixerTheme.muted)
                    .padding(.leading, 22)
                }
            }
        }
    }

    private var changeDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(category.displayTitle + " · " + platform.displayName).font(.system(size: 13, weight: .semibold))
                Text(current?.scope == .usual
                     ? "Compared with a recent project preference, not an installed global setting."
                     : current == nil ? (store.hasEscalationChanges(category, in: platform)
                        ? "No current model or effort is reported. The sequence is compared with the verified applied policy."
                        : "No current setting is reported. Proposed assignments are shown.")
                     : "Compared with the reported current settings.")
                    .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                assignments(showsComparison: true)
                ForEach(store.inheritanceChanges(category, in: platform), id: \.self) { change in
                    Text(change).font(.system(size: 10)).foregroundStyle(StandMixerTheme.accent)
                }
                if !route.additionalAgents.isEmpty {
                    Text(route.teamMode == .leadReview ? "Team: Lead + focused review" : "Team: Independent passes")
                        .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                }
                if let current {
                    ForEach(Array(current.evidence.enumerated()), id: \.offset) { _, evidence in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(evidence.path).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                            Text(evidence.explanation).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                        }
                    }
                    ForEach(Array(current.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                        Text(uncertainty).font(.system(size: 10)).foregroundStyle(StandMixerTheme.amber)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380).frame(maxHeight: 460)
        .background(StandMixerTheme.background).foregroundStyle(StandMixerTheme.ink)
    }

    private var comparisonTooltip: String {
        if route.isAutoController { return "Controller · Auto\nKeeps the current native model and effort. Saved defaults stay unchanged. No extra intake or controller agent is launched." }
        var lines = ["\(category.displayTitle) · \(platform.displayName)", "Proposed: " + store.routedModelName(route.modelID, in: platform) + " · " + route.effort.shortLabel]
        for agent in route.additionalAgents {
            lines.append("Proposed worker: " + store.routedModelName(agent.modelID, in: platform) + " · " + agent.effort.shortLabel)
        }
        if !route.stuckEscalation.isEmpty {
            lines.append("When stuck, in order: " + route.stuckEscalation.map {
                store.routedModelName($0.modelID, in: platform) + " · " + $0.effort.shortLabel
            }.joined(separator: " → "))
        }
        lines.append("\(route.additionalAgents.count + 1) \(route.additionalAgents.isEmpty ? "agent" : "agents") · Result: " + route.resultMode.displayTitle)
        if route.resultMode == .ai, let judge = route.judgeModelID { lines.append("Proposed judge: " + store.routedModelName(judge, in: platform)) }
        if let current {
            lines.append(current.scope == .usual ? "Recent project preference (not an installed global setting):" : "Reported current setting:")
            if let model = current.modelID { lines.append(store.routedModelName(model, in: platform, reportedPlatform: current.modelPlatform)) }
            if let effort = current.effort { lines.append("Effort: " + effort.shortLabel) }
            if let agents = current.additionalAgents {
                lines.append("\(agents.count + 1) \(agents.isEmpty ? "agent" : "agents")")
                for agent in agents { lines.append(store.routedModelName(agent.modelID, in: platform, reportedPlatform: agent.modelPlatform) + (agent.effort.map { " · " + $0.shortLabel } ?? "")) }
            }
            if let mode = current.resultMode { lines.append("Result: " + mode.displayTitle) }
            if let judge = current.judgeModelID { lines.append("Judge: " + store.modelName(judge)) }
        } else {
            lines.append(controller.run(for: platform).isPreviousReport ? "Previous report available in Sources; no fresh comparison." : "Current settings not reported.")
        }
        return lines.joined(separator: "\n")
    }

    private var showsCount: Bool { !route.additionalAgents.isEmpty || comparison.countChanged }
    private var showsResult: Bool { !route.additionalAgents.isEmpty || comparison.resultChanged }
    private var showsMetadata: Bool { current?.scope == .usual || showsCount || showsResult }
    private var countText: Text {
        let count = route.additionalAgents.count + 1
        let old = current?.additionalAgents.map { $0.count + 1 }
        let label = "\(count) \(count == 1 ? "agent" : "agents")"
        if let old, old != count {
            return Text(String(old)).strikethrough() + Text(" → ")
                + Text(label).foregroundColor(StandMixerTheme.accent)
        }
        return Text(label)
    }
    private func assignment(modelID: String, effort: EffortPolicy, oldModel: String?,
                            oldPlatform: AgentPlatform?, oldEffort: EffortPolicy?, number: Int, added: Bool = false,
                            showsComparison: Bool) -> some View {
        AssignmentChangeLine(platform: platform, modelID: modelID, effort: effort,
                             oldModelID: oldModel, oldPlatform: oldPlatform, oldEffort: oldEffort,
                             prefix: showsComparison && !route.additionalAgents.isEmpty ? "\(number)." : nil,
                             added: added, previousLabel: previousLabel, showEffort: showsComparison,
                             showsComparison: showsComparison)
    }
    private func difference(old: String?, new: String) -> Text {
        if let old, old != new {
            return Text(old).strikethrough().foregroundColor(StandMixerTheme.muted)
                + Text(" → ").foregroundColor(StandMixerTheme.muted)
                + Text(new).foregroundColor(StandMixerTheme.accent).fontWeight(.medium)
        }
        return Text(new).foregroundColor(StandMixerTheme.muted)
    }
}

struct CurrentSettingsStatus: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var controller: CurrentSettingsController
    @State private var showingSources = false

    var body: some View {
        Button("Sources") { showingSources = true }
            .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
            .foregroundStyle(StandMixerTheme.accent)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("Saved local settings and installed tools")
            .popover(isPresented: $showingSources, arrowEdge: .bottom) {
                SettingsSourcesPopover(controller: controller).environmentObject(store)
            }
            .sheet(item: $store.claudeConnectionPresentation) { presentation in
                ClaudeConnectionSheet(presentationID: presentation.id).environmentObject(store)
            }
    }
}

private struct SettingsSourcesPopover: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: CurrentSettingsController
    @State private var showingToolDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Settings sources").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Refresh") { Task { await store.refreshConnections() } }
                        .buttonStyle(StandMixerSecondaryButtonStyle()).disabled(store.isChecking)
                }
                Text("Read-only view of existing global defaults. Opening Sources changes nothing; a chat or project may use different settings.")
                    .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(AgentPlatform.allCases.filter { store.enabledPlatforms.contains($0) }) { platform in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(platform.displayName).font(.system(size: 12, weight: .semibold))
                        if let saved = controller.nativeSettings[platform] {
                            Text("Existing global default").font(.system(size: 10, weight: .medium))
                            Text(saved.modelID.map(store.modelName) ?? "Unknown")
                                .font(.system(size: 11))
                            if let effort = saved.effort {
                                Text("Effort: " + effort.effortLabel).font(.system(size: 10))
                            }
                            Text(saved.sourcePath).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                            if saved.status != "known" {
                                Text(saved.detail).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let Codex launch Claude Code workers.")
                        .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                    Button("Connect Claude for Codex") {
                        dismiss()
                        DispatchQueue.main.async { store.openClaudeConnection() }
                    }
                    .buttonStyle(StandMixerSecondaryButtonStyle())
                }
                DisclosureGroup("Local tool details", isExpanded: $showingToolDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(AgentPlatform.allCases.filter { store.enabledPlatforms.contains($0) }) { platform in
                            if let connection = store.connection(for: platform) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(platform.displayName).font(.system(size: 11, weight: .medium))
                                    Text(connection.version.map { "Version \($0)" } ?? "Version unavailable")
                                    if let path = connection.path {
                                        Text(path).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                                    }
                                    Text(connection.detail)
                                    if let warning = connection.compatibilityWarning {
                                        Text(warning).foregroundStyle(StandMixerTheme.amber)
                                    }
                                }
                            }
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 7)
                }
                .font(.system(size: 11, weight: .medium))
                Text(store.installationDetail).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restore applied settings…") {
                    dismiss()
                    DispatchQueue.main.async { store.showRestoreConfirmation = true }
                }.buttonStyle(StandMixerSecondaryButtonStyle()).disabled(!store.canRestore || store.isEditing)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StandMixerTheme.background)
        .frame(width: 470).frame(maxHeight: 560).foregroundStyle(StandMixerTheme.ink)
    }
}
