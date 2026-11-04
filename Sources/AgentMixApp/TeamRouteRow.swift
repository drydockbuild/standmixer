import SwiftUI
import AgentMixCore

/// Advanced edits the same role rows and keeps every worker visible.
struct RouteRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var currentSettings: CurrentSettingsController
    let platform: AgentPlatform
    let category: WorkCategory
    private var route: Route { store.route(category, in: platform) }
    private var current: ImportedRoute? {
        if store.isEditing { return nil }
        if category == .coordinator {
            if let applied = store.appliedController(in: platform) { return applied }
            if route.isAutoController { return nil }
        }
        return currentSettings.run(for: platform).isPreviousReport ? nil : currentSettings.finding(platform: platform, category: category)
    }
    private var comparison: RouteComparison {
        if let baseline = store.editBaselineRoute(category, in: platform) {
            let original = ImportedRoute(category: category, modelID: baseline.modelID, effort: baseline.effort,
                additionalAgents: baseline.additionalAgents.map(ImportedAgentAssignment.init),
                resultMode: baseline.resultMode, judgeModelID: baseline.judgeModelID)
            return RouteComparison(current: original, proposed: route, previousTeamMode: baseline.teamMode)
        }
        return RouteComparison(current: current, proposed: route, previousTeamMode: store.appliedRoute(category, in: platform)?.teamMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            worker(modelID: route.modelID, index: 0)
            ForEach(Array(route.additionalAgents.enumerated()), id: \.element.id) { index, assignment in
                worker(modelID: assignment.modelID, index: index + 1)
            }
            if let old = current?.additionalAgents, old.count > route.additionalAgents.count {
                ForEach(Array(old.dropFirst(route.additionalAgents.count).enumerated()), id: \.offset) { _, agent in
                    AssignmentChangeLine(platform: platform, modelID: agent.modelID, oldPlatform: agent.modelPlatform, removed: true)
                }
            }
            if !route.additionalAgents.isEmpty, route.resultMode == .ai {
                HStack(spacing: 7) {
                    Text("Judge").font(.system(size: 9)).foregroundStyle(AgentMixTheme.muted)
                    ModelPicker(modelID: route.judgeModelID ?? route.modelID,
                                routingPlatform: platform, highlighted: comparison.judgeChanged,
                                accessibilityTitle: "\(platform.displayName) \(category.displayTitle) judge model") { id in
                        store.editProfile(platform) { store.updateRoute(category) { $0.judgeModelID = id } }
                    }
                }
                if comparison.judgeChanged, let previousJudge = current?.judgeModelID {
                    previousModel(previousJudge, provider: nil, prefix: "Previous judge")
                }
            } else if let previousJudge = current?.judgeModelID {
                AssignmentChangeLine(platform: platform, modelID: previousJudge, prefix: "Judge:", removed: true)
            }
            if category != .coordinator {
                HStack(spacing: 7) {
                    AgentCountControl(category: category, platform: platform, highlighted: comparison.countChanged)
                    if !route.additionalAgents.isEmpty {
                        Picker("Team mode", selection: Binding(get: { route.teamMode }, set: { value in
                            store.editProfile(platform) { store.updateRoute(category) { $0.teamMode = value } }
                        })) {
                            Text("Lead + review").tag(RouteTeamMode.leadReview)
                            Text("Independent passes").tag(RouteTeamMode.parallel)
                        }.pickerStyle(.menu).labelsHidden().controlSize(.small).font(.system(size: 9))
                            .padding(1).background(comparison.teamModeChanged ? AgentMixTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .help("Lead + review uses a focused secondary pass. Independent passes give each worker the full task. Keep the chosen visual winner for follow-ups.")
                        ResultModeControl(category: category, platform: platform, highlighted: comparison.resultChanged)
                    }
                    Spacer(minLength: 0)
                }
                if !store.isEditing && (comparison.countChanged || comparison.resultChanged) {
                    Text(previousTeamSummary).font(.system(size: 8.5)).foregroundStyle(AgentMixTheme.muted)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .padding(.top, comparison.hasKnownChanges ? 4 : 0)
        .background(comparison.hasKnownChanges ? AgentMixTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(comparison.hasKnownChanges ? AgentMixTheme.accent.opacity(0.45) : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if comparison.hasKnownChanges { ChangedCellBadge(isEdited: store.isEditing).padding(.trailing, 9).offset(y: -4) }
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
    }

    private var previousTeamSummary: String {
        var pieces: [String] = []
        if let count = current?.additionalAgents?.count { pieces.append("\(count + 1) \(count == 0 ? "agent" : "agents")") }
        if let mode = current?.resultMode { pieces.append("Result: " + mode.displayTitle) }
        return (current?.scope == .usual ? "Usually " : "Currently ") + pieces.joined(separator: " · ")
    }
    private func previousModel(_ id: String, provider: AgentPlatform?, prefix: String? = nil) -> some View {
        InlineFlowLayout(spacing: 4, lineSpacing: 2) {
            Text(prefix ?? (current?.scope == .usual ? "Usually" : "Currently")).foregroundStyle(AgentMixTheme.muted)
            ModelIdentityLabel(modelID: id, reportedPlatform: provider, previous: true, showsMark: false)
            if let provider = store.model(id)?.platform ?? provider, provider != platform { ProviderBadge(platform: provider, subdued: true) }
        }
        .font(.system(size: 9)).padding(.leading, 22)
    }

    private func worker(modelID: String, index: Int) -> some View {
        let oldModel: String? = index == 0 ? current?.modelID : current?.additionalAgents.flatMap { $0.indices.contains(index - 1) ? $0[index - 1].modelID : nil }
        let oldProvider: AgentPlatform? = index == 0 ? current?.modelPlatform : current?.additionalAgents.flatMap { $0.indices.contains(index - 1) ? $0[index - 1].modelPlatform : nil }
        let oldEffort: EffortPolicy? = index == 0 ? current?.effort : current?.additionalAgents.flatMap { $0.indices.contains(index - 1) ? $0[index - 1].effort : nil }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if !route.additionalAgents.isEmpty {
                    Text(route.teamMode == .leadReview ? (index == 0 ? "Lead" : "Review") : "\(index + 1)").font(.system(size: 8, weight: .medium)).foregroundStyle(AgentMixTheme.muted).frame(width: route.teamMode == .leadReview ? 34 : 9)
                }
                ModelPicker(modelID: modelID, restrictedPlatform: category == .coordinator ? platform : nil,
                            routingPlatform: platform, allowsAutoController: category == .coordinator, highlighted: comparison.modelChanged(index),
                            accessibilityTitle: "\(platform.displayName) \(category.displayTitle) agent \(index + 1) model") { id in
                    store.editProfile(platform) { store.setModel(id, for: category, agentIndex: index) }
                }
            }
            if comparison.modelChanged(index), let oldModel { previousModel(oldModel, provider: oldProvider) }
            if route.isAutoController {
                Text("Keeps current model and effort").font(.system(size: 9)).foregroundStyle(AgentMixTheme.muted)
                    .help("Auto launches no extra controller. A pinned model changes the native default for new sessions.")
            } else {
                HStack(alignment: .top, spacing: 5) {
                    Text("Effort").font(.system(size: 9)).foregroundStyle(AgentMixTheme.muted).frame(width: 32, alignment: .leading).padding(.top, 5)
                    EffortControl(policy: effortBinding(index),
                                  levels: store.model(modelID)?.supportedEfforts ?? EffortPolicy.levels,
                                  isClaudeCoordinator: platform == .claude && category == .coordinator,
                                  isCoordinator: category == .coordinator, highlighted: comparison.effortChanged(index),
                                  categoryTitle: "\(platform.displayName) \(category.displayTitle) agent \(index + 1)",
                                  categoryID: index == 0 ? category.rawValue : "")
                }
            }
            if !route.isAutoController, comparison.effortChanged(index), let oldEffort {
                (Text(current?.scope == .usual ? "Usually " : "Currently ") + Text(oldEffort.shortLabel).strikethrough())
                    .font(.system(size: 9)).foregroundStyle(AgentMixTheme.muted).padding(.leading, 38)
            }
        }
    }

    private func effortBinding(_ index: Int) -> Binding<EffortPolicy> {
        Binding(get: {
            let value = store.route(category, in: platform)
            return index == 0 ? value.effort : value.additionalAgents.indices.contains(index - 1) ? value.additionalAgents[index - 1].effort : .auto
        }, set: { value in
            store.editProfile(platform) { store.effortBinding(for: category, agentIndex: index).wrappedValue = value }
        })
    }
}

/// Scope existing draft mutations to a visible profile without changing the selected profile.
/// This adapter preserves AppStore's normalization, validation, backup, and save behavior.
extension AppStore {
    func route(_ category: WorkCategory, in platform: AgentPlatform) -> Route {
        configuration.profile(for: platform)?.route(for: category)
            ?? AgentMixConfiguration.defaults.profile(for: platform)!.route(for: category)!
    }

    func editProfile(_ platform: AgentPlatform, _ action: () -> Void) {
        let previous = selectedPlatform
        if previous != platform { selectedPlatform = platform }
        defer { if selectedPlatform != previous { selectedPlatform = previous } }
        action()
    }
}
