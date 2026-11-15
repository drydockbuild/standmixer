import SwiftUI
import StandMixerCore

/// The three model tiers are separate from reasoning effort and the routing host.
struct ModelIdentity {
    let provider: AgentPlatform?
    let family: String?
    let level: Int

    init(id: String, label: String? = nil, provider: AgentPlatform?) {
        self.provider = provider
        let candidate = id.lowercased().components(separatedBy: "[")[0]
        let labelCandidate = (label ?? "").lowercased()
        let families: [(name: String, level: Int)]
        switch provider {
        case .codex: families = [("luna", 1), ("terra", 1), ("sol", 2), ("astra", 3)]
        case .claude: families = [("haiku", 1), ("sonnet", 2), ("fable", 3), ("opus", 3)]
        case nil: families = []
        }
        let match = families.first { item in
            let identifierPattern = provider == .claude
                ? "^claude-(?:[0-9][a-z0-9.]*-)*" + item.name + "(?:[-._][a-z0-9]+)*$"
                : "^gpt-[0-9][a-z0-9.]*-" + item.name + "(?:[-._][a-z0-9]+)*$"
            let labelPattern = "^(?:claude )?" + item.name + "(?: [0-9][a-z0-9. -]*)?$"
            return candidate == item.name || candidate.range(of: identifierPattern, options: .regularExpression) != nil
                || labelCandidate.range(of: labelPattern, options: .regularExpression) != nil
        }
        family = match?.name.capitalized
        level = match?.level ?? 0
    }

    var color: Color { Self.color(for: level) }
    static func color(for level: Int) -> Color {
        switch level {
        case 1: return StandMixerTheme.adaptive(0xB05D28, 0xE3A06B)
        case 2: return StandMixerTheme.adaptive(0x876719, 0xD3B86A)
        case 3: return StandMixerTheme.adaptive(0x347757, 0x8AC7A0)
        default: return StandMixerTheme.muted
        }
    }
    var help: String {
        guard family != nil else { return "Model tier unavailable" }
        return "Model tier \(level) of 3"
    }
}

struct ModelFamilyMark: View {
    let identity: ModelIdentity
    var subdued = false
    var body: some View {
        VStack(spacing: 2) {
            ForEach((0..<3).reversed(), id: \.self) { index in
                Circle()
                    .fill(index < identity.level
                          ? (subdued ? StandMixerTheme.muted.opacity(0.55) : identity.color)
                          : StandMixerTheme.ink.opacity(0.12))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 5, height: 16)
        .help(identity.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.help)
    }
}

struct ModelIdentityLabel: View {
    @EnvironmentObject private var store: AppStore
    let modelID: String
    var reportedPlatform: AgentPlatform? = nil
    var previous = false
    var emphasized = false
    var showsMark = true
    private var identity: ModelIdentity {
        ModelIdentity(id: modelID, label: store.model(modelID)?.label,
                      provider: store.model(modelID)?.platform ?? reportedPlatform)
    }
    var body: some View {
        HStack(spacing: 6) {
            if showsMark && modelID != Route.autoControllerModelID { ModelFamilyMark(identity: identity, subdued: previous) }
            Text(store.modelName(modelID))
                .strikethrough(previous)
                .foregroundStyle(previous ? StandMixerTheme.muted.opacity(0.85) : identity.color)
                .fontWeight(emphasized && !previous ? .semibold : .medium)
                .fixedSize(horizontal: false, vertical: true)
            if modelID == Route.autoControllerModelID {
                Text("Current model").font(.system(size: 10)).foregroundStyle(StandMixerTheme.muted)
            }
        }
        .help(modelID == Route.autoControllerModelID ? "Keeps the current native model and effort. Saved defaults stay unchanged; no extra controller is launched." : modelID + " · " + identity.help)
    }
}
