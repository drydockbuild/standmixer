import SwiftUI
import StandMixerCore

/// Sequential debugging attempts are a separate policy from concurrent team members.
struct StuckEscalationEditor: View {
    @EnvironmentObject private var store: AppStore
    let platform: AgentPlatform
    let category: WorkCategory
    private var route: Route { store.route(category, in: platform) }
    private var available: [ModelSpec] {
        store.selectableModels.filter { model in
            store.modelPlatforms.contains(model.platform)
                && !route.stuckEscalation.contains { $0.modelID == model.id }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("When stuck").font(.system(size: 11, weight: .semibold))
            Text("Try these models in order when debugging remains unresolved. Skip models already tried.")
                .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(route.stuckEscalation.enumerated()), id: \.element.id) { index, assignment in
                StuckEscalationStep(platform: platform, category: category, assignment: assignment, index: index)
            }
            if route.stuckEscalation.isEmpty {
                Text("No escalation sequence").font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
            }
            Menu("Add step") {
                ForEach(available) { model in
                    Button(store.routedModelName(model.id, in: platform)) {
                        store.editProfile(platform) {
                            store.updateRoute(category) { route in
                                guard route.stuckEscalation.count < 3 else { return }
                                route.stuckEscalation.append(.init(modelID: model.id, effort: .auto, modelPlatform: model.platform))
                            }
                        }
                    }
                }
            }.controlSize(.small).disabled(route.stuckEscalation.count >= 3 || available.isEmpty)
                .accessibilityLabel(platform.displayName + " debugging: add sequential escalation step")
        }
    }
}

private struct StuckEscalationStep: View {
    @EnvironmentObject private var store: AppStore
    let platform: AgentPlatform
    let category: WorkCategory
    let assignment: AgentAssignment
    let index: Int
    private var chain: [AgentAssignment] { store.route(category, in: platform).stuckEscalation }
    private var effort: Binding<EffortPolicy> {
        Binding<EffortPolicy>(get: { assignment.effort }, set: { value in update { $0.effort = value } })
    }
    private var otherModels: Set<String> { Set(chain.filter { $0.id != assignment.id }.map(\.modelID)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Step \(index + 1)").font(.system(size: 9, weight: .medium))
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).accessibilityLabel("Move escalation step \(index + 1) earlier")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == chain.count - 1).accessibilityLabel("Move escalation step \(index + 1) later")
                Button {
                    store.editProfile(platform) { store.updateRoute(category) { $0.stuckEscalation.removeAll { $0.id == assignment.id } } }
                } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove escalation step \(index + 1)")
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
            ModelPicker(modelID: assignment.modelID, routingPlatform: platform, excludedModelIDs: otherModels,
                        accessibilityTitle: platform.displayName + " debugging escalation step \(index + 1) model") { modelID in
                update { value in
                    value.modelID = modelID
                    value.modelPlatform = store.model(modelID)?.platform
                }
            }
            EffortControl(policy: effort, levels: store.model(assignment.modelID)?.supportedEfforts ?? EffortPolicy.levels,
                          categoryTitle: platform.displayName + " debugging escalation step \(index + 1)")
        }
        .padding(7).background(StandMixerTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }
    private func update(_ change: (inout AgentAssignment) -> Void) {
        store.editProfile(platform) {
            store.updateRoute(category) { route in
                guard let target = route.stuckEscalation.firstIndex(where: { $0.id == assignment.id }) else { return }
                change(&route.stuckEscalation[target])
            }
        }
    }
    private func move(_ offset: Int) {
        store.editProfile(platform) {
            store.updateRoute(category) { route in
                guard let current = route.stuckEscalation.firstIndex(where: { $0.id == assignment.id }),
                      route.stuckEscalation.indices.contains(current + offset) else { return }
                route.stuckEscalation.swapAt(current, current + offset)
            }
        }
    }
}

struct StuckEscalationSummary: View {
    @EnvironmentObject private var store: AppStore
    let platform: AgentPlatform
    let category: WorkCategory
    var showsComparison = false
    private var chain: [AgentAssignment] { store.route(category, in: platform).stuckEscalation }
    private func summary(_ values: [AgentAssignment]) -> String {
        values.isEmpty ? "Off" : values.map {
            store.routedModelName($0.modelID, in: platform) + " · " + $0.effort.shortLabel
        }.joined(separator: " → ")
    }
    var body: some View {
        if !chain.isEmpty || showsComparison && store.hasEscalationChanges(category, in: platform) {
            VStack(alignment: .leading, spacing: 2) {
                Text("When stuck: " + summary(chain))
                    .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
                if showsComparison, store.hasEscalationChanges(category, in: platform),
                   let previous = store.previousEscalation(category, in: platform) {
                    (Text("Previously: ") + Text(summary(previous)).strikethrough())
                        .font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
                }
            }.fixedSize(horizontal: false, vertical: true)
                .help("Sequential debugging attempts; skip models already tried. These are not simultaneous team members or quota fallbacks.")
        }
    }
}
