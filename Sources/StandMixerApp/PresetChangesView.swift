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
            AssignmentTable(platforms: AgentPlatform.allCases.filter { selectedPlatforms.contains($0) }, detail: { _ in "" }) { platform, category in
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
        if category == .coordinator {
            if let applied = store.appliedController(in: platform) { return applied }
            if route.isAutoController { return nil }
        }
        guard !controller.run(for: platform).isPreviousReport else { return nil }
        let finding = controller.finding(platform: platform, category: category)
        return finding?.hasKnownSettings == true ? finding : nil
    }
    private var comparison: RouteComparison { RouteComparison(current: current, proposed: route, previousTeamMode: store.appliedRoute(category, in: platform)?.teamMode) }
    private var highlighted: Bool { comparison.hasKnownChanges }
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
                        if showEffort { ChangedCellBadge() }
                        else {
                            Button { showingDetails = true } label: { ChangedCellBadge(showsDisclosure: true) }
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
                     : current == nil ? "No current setting is reported. Proposed assignments are shown."
                     : "Compared with the reported current settings.")
                    .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                assignments(showsComparison: true)
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
    private var platforms: [AgentPlatform] { AgentPlatform.allCases.filter { store.enabledPlatforms.contains($0) } }
    private var isReading: Bool { platforms.contains { controller.run(for: $0).state.isRunning } }
    private var summary: String {
        if controller.isDemo { return "Demo comparison" }
        if isReading { return "Reading current settings…" }
        let runs = platforms.map { controller.run(for: $0) }
        if runs.contains(where: { if case .failed = $0.state { return true }; return false }) {
            return "Some settings couldn’t be read"
        }
        if runs.contains(where: { if case .cancelled = $0.state { return true }; return false }) {
            return "Reading stopped"
        }
        let reported = platforms.filter {
            let run = controller.run(for: $0)
            return run.proposal != nil && !run.isPreviousReport
        }
        if reported.count == platforms.count, !reported.isEmpty {
            let usual = reported.contains { controller.run(for: $0).proposal?.routes.contains { $0.scope == .usual } == true }
            return usual ? "Current + recent preferences" : "Current settings read"
        }
        if !reported.isEmpty { return "Some current settings read" }
        if runs.contains(where: \.isPreviousReport) {
            return "Previous reports available"
        }
        return "Current settings not read"
    }
    var body: some View {
        HStack(spacing: 8) {
            if isReading { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
            else if platforms.contains(where: { if case .failed = controller.run(for: $0).state { return true }; return false }) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(StandMixerTheme.amber)
            }
            Button("Sources") { showingSources = true }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(StandMixerTheme.accent)
            Button {
                if isReading { platforms.forEach(controller.cancel) }
                else { controller.refreshAll(platforms: store.enabledPlatforms) }
            } label: { Image(systemName: isReading ? "xmark" : "arrow.clockwise").font(.system(size: 10)) }
                .buttonStyle(.plain).help(isReading ? "Stop reading" : "Read preferences with the selected CLI accounts; uses model allowance")
                .disabled(platforms.isEmpty || controller.isDemo)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .foregroundStyle(StandMixerTheme.muted)
        .help(summary)
        .popover(isPresented: $showingSources, arrowEdge: .bottom) {
            SettingsSourcesPopover(controller: controller).environmentObject(store)
        }
        .onChange(of: controller.folderURL) { _, _ in controller.invalidateReports() }
    }
}

private struct SettingsSourcesPopover: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: CurrentSettingsController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Settings sources").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Choose project…") { controller.chooseFolder() }.buttonStyle(.plain).foregroundStyle(StandMixerTheme.accent)
                        .font(.system(size: 10))
                }
                Text("Recent project preferences describe your usual choices; they are not installed global settings.")
                    .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(store.isCheckingAccounts ? "Checking CLI accounts…" : "Check CLI accounts") { store.checkAccounts() }
                        .buttonStyle(StandMixerSecondaryButtonStyle()).disabled(store.isCheckingAccounts)
                    if store.isCheckingAccounts { ProgressView().controlSize(.mini) }
                }
                Text("Reads public CLI sign-in status without model calls. StandMixer does not switch accounts or log you out.")
                    .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let error = store.accountError {
                    Text(error).font(.system(size: 10)).foregroundStyle(StandMixerTheme.amber).textSelection(.enabled)
                }
                Button("Read preferences") { controller.refreshAll(platforms: store.enabledPlatforms) }
                    .buttonStyle(StandMixerSecondaryButtonStyle()).disabled(store.enabledPlatforms.isEmpty)
                Text("Reading preferences uses the selected CLIs’ quick models and account allowance. CLI-launched workers use those sign-ins; Claude Desktop may use a different account.")
                    .font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let folder = controller.folderURL {
                    HStack {
                        Text(folder.path).font(.system(size: 9, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button("Clear") { controller.folderURL = nil }.buttonStyle(.plain).font(.system(size: 10))
                    }
                }
                ForEach(AgentPlatform.allCases.filter { store.enabledPlatforms.contains($0) }) { platform in
                    sourceSection(platform)
                }
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
    @ViewBuilder private func sourceSection(_ platform: AgentPlatform) -> some View {
        let run = controller.run(for: platform)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(platform.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(run.state.label).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
            }
            let account = store.accounts?.providers.first { $0.platform == platform }
            let accountLabel = account.map { value in
                switch value.status { case .signedIn: "Signed in"; case .signedOut: "Signed out"; case .unknown: "Unknown" }
            } ?? (store.accountError == nil ? "Not checked" : "Unknown")
            Text("CLI account · " + accountLabel).font(.system(size: 10, weight: .medium))
            if account?.status == .signedIn {
                Text(account?.email ?? "Identity not reported").font(.system(size: 10)).textSelection(.enabled)
            }
            if let subscription = account?.subscription {
                Text("Plan: " + subscription).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
            }
            if let detail = account?.detail { Text(detail).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted) }
            if let checkedAt = store.accounts?.checkedAt {
                Text("Checked " + checkedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
            }
            if let cliPath = account?.cliPath {
                Text(cliPath).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
            }
            if let receivedAt = run.receivedAt {
                Text("Report received " + receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
            }
            if run.state.isRunning {
                Button("Stop reading \(platform.displayName)") { controller.cancel(platform) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(StandMixerTheme.accent)
            }
            if run.isPreviousReport { Text("Previous report").font(.system(size: 10)).foregroundStyle(StandMixerTheme.amber) }
            if case .failed(let message) = run.state {
                Text(message).font(.system(size: 10)).foregroundStyle(StandMixerTheme.amber).textSelection(.enabled)
                Button("Retry \(platform.displayName)") { controller.refresh(platform) }.buttonStyle(StandMixerSecondaryButtonStyle())
            }
            if let report = run.proposal {
                if !report.summary.isEmpty { Text(report.summary).font(.system(size: 10)).lineSpacing(3) }
                ForEach(report.routes) { route in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(route.modelID.map(store.modelName) ?? "Model not reported").font(.system(size: 10, weight: .medium))
                            if let effort = route.effort { Text("Effort: \(effort.shortLabel)").font(.system(size: 10)) }
                            if let agents = route.additionalAgents {
                                Text("\(agents.count + 1) \(agents.isEmpty ? "agent" : "agents")").font(.system(size: 10))
                                ForEach(agents) { agent in Text(store.modelName(agent.modelID) + (agent.effort.map { " · " + $0.shortLabel } ?? "")).font(.system(size: 10)) }
                            }
                            if let mode = route.resultMode { Text("Result: " + mode.displayTitle).font(.system(size: 10)) }
                            if let judge = route.judgeModelID { Text("Judge: " + store.modelName(judge)).font(.system(size: 10)) }
                            evidence(route.evidence)
                            ForEach(Array(route.uncertainties.enumerated()), id: \.offset) { _, value in Text(value).font(.system(size: 10)).foregroundStyle(StandMixerTheme.amber) }
                        }.padding(.top, 8)
                    } label: {
                        HStack {
                            Text(route.category.displayTitle)
                            Spacer()
                            Text(route.scope == .usual ? "Recent preference" : "Current setting").foregroundStyle(StandMixerTheme.muted)
                        }.font(.system(size: 10))
                    }
                }
                if !report.sources.isEmpty { DisclosureGroup("Report sources") { evidence(report.sources).padding(.top, 8) }.font(.system(size: 10)) }
                ForEach(Array(report.uncertainties.enumerated()), id: \.offset) { _, value in Text(value).font(.system(size: 10)).foregroundStyle(StandMixerTheme.amber) }
                Text("Reported by \(platform.displayName); source claims are not independently verified.")
                    .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    private func evidence(_ sources: [ImportEvidence]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.path).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                    Text(source.explanation).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
                }
            }
        }
    }
}
