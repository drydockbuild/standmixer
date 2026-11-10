import SwiftUI
import StandMixerCore

struct ModelPicker: View {
    @EnvironmentObject private var store: AppStore
    let modelID: String
    var restrictedPlatform: AgentPlatform? = nil
    var routingPlatform: AgentPlatform? = nil
    var allowsAutoController = false
    var highlighted = false
    var accessibilityTitle = "Model"
    let onSelect: (String) -> Void
    @State private var addingCustom = false
    @State private var customPlatform: AgentPlatform = .codex
    @State private var customID = ""

    private enum Selection: Hashable {
        case model(String)
        case custom
    }

    private var platforms: [AgentPlatform] {
        AgentPlatform.allCases.filter { (restrictedPlatform == nil || $0 == restrictedPlatform) && store.modelPlatforms.contains($0) }
    }
    private var selectableModels: [ModelSpec] {
        store.availableModels.filter { platforms.contains($0.platform) }
    }
    private var trimmedID: String { customID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var customValidation: String? {
        guard !trimmedID.isEmpty else { return nil }
        if trimmedID == Route.autoControllerModelID { return "Auto is reserved for the Controller setting." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/[]")
        guard trimmedID.count <= 180, trimmedID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Use an exact model ID: letters, numbers, - _ . : / [ ]."
        }
        if let known = store.model(trimmedID), known.platform != customPlatform {
            return "This model ID belongs to \(known.platform.displayName)."
        }
        return nil
    }
    private var canAddCustom: Bool {
        !trimmedID.isEmpty && customValidation == nil && platforms.contains(customPlatform)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if modelID != Route.autoControllerModelID {
                    ModelFamilyMark(identity: ModelIdentity(id: modelID, label: store.model(modelID)?.label,
                                                           provider: store.model(modelID)?.platform))
                }
                Picker(accessibilityTitle, selection: Binding<Selection>(
                    get: { addingCustom ? .custom : .model(modelID) },
                    set: select
                )) {
                    if allowsAutoController {
                        Text("Auto · Current model").tag(Selection.model(Route.autoControllerModelID))
                        Divider()
                    }
                    if modelID != Route.autoControllerModelID && !selectableModels.contains(where: { $0.id == modelID }) {
                        Text(store.modelName(modelID)).tag(Selection.model(modelID))
                            .disabled(!isAllowed(modelID))
                        Divider()
                    }
                    ForEach(platforms) { platform in
                        Section(platform.displayName) {
                            ForEach(selectableModels.filter { $0.platform == platform }) { model in
                                Text(model.label).tag(Selection.model(model.id))
                            }
                        }
                    }
                    Divider()
                    Text("Custom ID…").tag(Selection.custom)
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small)
                .font(.system(size: 11)).frame(maxWidth: .infinity)
                .tint(ModelIdentity(id: modelID, label: store.model(modelID)?.label, provider: store.model(modelID)?.platform).color)
                .padding(1)
                .background(highlighted ? StandMixerTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(qualifiedName(id: modelID) + ", " + modelID)
                .help(allowsAutoController ? "Auto keeps the current native model and effort. A pinned model applies to new sessions; this chat continues with its current model." : modelID)
                if !addingCustom, let provider = store.model(modelID)?.platform,
                   provider != (routingPlatform ?? store.selectedPlatform) {
                    ProviderBadge(platform: provider)
                }
            }

            if addingCustom {
                if platforms.count > 1 {
                    Picker("Model provider", selection: $customPlatform) {
                        ForEach(platforms) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().controlSize(.small)
                    .accessibilityLabel("Custom model provider")
                }
                HStack(spacing: 6) {
                    TextField("Exact model ID", text: $customID)
                        .font(.system(size: 10, design: .monospaced)).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Exact model ID").onSubmit(addCustomModel)
                    Button("Add", action: addCustomModel).controlSize(.small).disabled(!canAddCustom)
                    Button { cancelCustomModel() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(StandMixerTheme.muted)
                    .accessibilityLabel("Cancel custom model")
                }
                if let message = customValidation {
                    Text(message).font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: modelID) { _, _ in cancelCustomModel() }
        .onChange(of: routingPlatform ?? store.selectedPlatform) { _, _ in cancelCustomModel() }
        .onChange(of: platforms) { _, choices in
            if !choices.contains(customPlatform) { customPlatform = choices.first ?? .codex }
            if choices.isEmpty { cancelCustomModel() }
        }
    }

    private func isAllowed(_ id: String) -> Bool {
        if id == Route.autoControllerModelID { return allowsAutoController }
        guard let restrictedPlatform else { return true }
        return store.model(id)?.platform == restrictedPlatform
    }

    private func qualifiedName(id: String) -> String {
        store.routedModelName(id, in: routingPlatform ?? store.selectedPlatform)
    }

    private func select(_ selection: Selection) {
        switch selection {
        case .model(let id):
            guard isAllowed(id) else { return }
            cancelCustomModel()
            onSelect(id)
        case .custom:
            let currentProvider = store.model(modelID)?.platform
            customPlatform = currentProvider.flatMap { platforms.contains($0) ? $0 : nil } ?? platforms.first ?? .codex
            customID = ""
            addingCustom = true
        }
    }

    private func cancelCustomModel() {
        addingCustom = false
        customID = ""
    }

    private func addCustomModel() {
        guard canAddCustom else { return }
        let id = trimmedID
        if store.model(id) == nil {
            store.addCustomModel(ModelSpec(id: id, label: id, platform: customPlatform,
                supportedEfforts: customPlatform == .codex ? EffortPolicy.levels : Array(EffortPolicy.levels.dropLast())))
        }
        // A failed local save must not leave a route referring to an unsaved model.
        guard store.model(id)?.platform == customPlatform else { return }
        onSelect(id)
        cancelCustomModel()
    }
}

struct EffortControl: View {
    @Binding var policy: EffortPolicy
    let levels: [String]
    var isClaudeCoordinator = false
    var isCoordinator = false
    var highlighted = false
    let categoryTitle: String
    var categoryID = ""

    private var availableLevels: [String] { EffortPolicy.levels.filter { levels.contains($0) } }
    private var fixedLevels: [String] {
        isClaudeCoordinator ? availableLevels.filter { $0 != "max" && $0 != "ultra" } : availableLevels
    }
    private var selection: String {
        switch policy.mode {
        case .auto: return "auto"
        case .fixed: return policy.value
        case .range: return "range"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Picker("Reasoning effort", selection: Binding(get: { selection }, set: select)) {
                Text("Auto").tag("auto")
                ForEach(fixedLevels, id: \.self) { Text($0.effortLabel).tag($0) }
                if policy.mode == .fixed, !fixedLevels.contains(policy.value) {
                    Text(policy.value.effortLabel + " (unavailable)").tag(policy.value).disabled(true)
                }
                Divider()
                Text("Range…").tag("range").disabled(availableLevels.isEmpty)
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small)
            .font(.system(size: 10)).frame(width: policy.mode == .range ? 87 : 80)
            .padding(1)
            .background(highlighted ? StandMixerTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("\(categoryTitle) reasoning effort")
            .accessibilityValue(policy.shortLabel)
                .help("Auto follows the caller's effort, mapped to a supported level. Fixed and ranged settings override that intent.")
                EffortMeter(policy: policy, supportedLevels: availableLevels)
                Spacer(minLength: 0)
            }

            if policy.mode == .range {
                HStack(spacing: 4) {
                    rangePicker(isMinimum: true)
                    Text("to").font(.system(size: 9)).foregroundStyle(StandMixerTheme.muted)
                    rangePicker(isMinimum: false)
                }
            }
        }
    }

    private func select(_ value: String) {
        var next = policy
        if value == "auto" {
            next.mode = .auto
        } else if value == "range" {
            guard !availableLevels.isEmpty else { return }
            next.mode = .range
            normalizeRange(&next)
        } else {
            guard fixedLevels.contains(value) else { return }
            next.mode = .fixed
            next.value = value
        }
        policy = next
    }

    private func rangePicker(isMinimum: Bool) -> some View {
        let current = isMinimum ? policy.minimum : policy.maximum
        return Picker(isMinimum ? "Minimum effort" : "Maximum effort", selection: Binding(
            get: { isMinimum ? policy.minimum : policy.maximum },
            set: { value in
                guard availableLevels.contains(value) else { return }
                var next = policy
                normalizeRange(&next)
                if isMinimum { next.minimum = value } else { next.maximum = value }
                if let minimum = availableLevels.firstIndex(of: next.minimum),
                   let maximum = availableLevels.firstIndex(of: next.maximum), minimum > maximum {
                    if isMinimum { next.maximum = value } else { next.minimum = value }
                }
                policy = next
            }
        )) {
            ForEach(availableLevels, id: \.self) { Text($0.effortLabel).tag($0) }
            if !availableLevels.contains(current) { Text(current.effortLabel + " (unavailable)").tag(current).disabled(true) }
        }
        .pickerStyle(.menu).labelsHidden().controlSize(.small)
        .font(.system(size: 10)).frame(maxWidth: .infinity)
        .accessibilityLabel("\(categoryTitle) \(isMinimum ? "minimum" : "maximum") reasoning effort")
    }

    private func normalizeRange(_ value: inout EffortPolicy) {
        if !availableLevels.contains(value.minimum) { value.minimum = availableLevels.first ?? "low" }
        if !availableLevels.contains(value.maximum) { value.maximum = availableLevels.last ?? "high" }
        if let minimum = availableLevels.firstIndex(of: value.minimum),
           let maximum = availableLevels.firstIndex(of: value.maximum), minimum > maximum {
            value.maximum = value.minimum
        }
    }
}

/// The same six global levels remain legible even when a model supports fewer.
struct EffortMeter: View {
    let policy: EffortPolicy
    let supportedLevels: [String]
    private var lower: Int? { EffortPolicy.levels.firstIndex(of: policy.minimum) }
    private var upper: Int? { EffortPolicy.levels.firstIndex(of: policy.maximum) }
    private func fill(_ index: Int) -> Color {
        guard policy.mode != .auto else { return StandMixerTheme.muted.opacity(0.24) }
        let level = EffortPolicy.levels[index]
        if policy.mode == .fixed { return level == policy.value ? StandMixerTheme.accent : StandMixerTheme.muted.opacity(0.19) }
        guard let lower, let upper, (lower...max(lower, upper)).contains(index) else { return StandMixerTheme.muted.opacity(0.16) }
        return StandMixerTheme.accent.opacity(index == lower || index == upper ? 1 : 0.45)
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(EffortPolicy.levels.enumerated()), id: \.offset) { index, level in
                RoundedRectangle(cornerRadius: 0.8).fill(fill(index))
                    .frame(width: 3, height: CGFloat(4 + index * 2))
                    .opacity(supportedLevels.contains(level) || policy.value == level && policy.mode == .fixed ? 1 : 0.35)
            }
        }
        .frame(width: 28, height: 16, alignment: .bottom)
        .help("Low · Medium · High · X-high · Max · Ultra\n" + (policy.mode == .auto ? "Auto follows caller" : policy.shortLabel))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort meter")
        .accessibilityValue(policy.mode == .auto ? "Auto, follows caller" : policy.shortLabel)
    }
}
