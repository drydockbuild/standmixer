import SwiftUI
import AgentMixCore

/// Model intensity is independent of the tool hosting the route.
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
        case .codex: families = [("luna", 1), ("terra", 2), ("sol", 3), ("astra", 4)]
        case .claude: families = [("haiku", 1), ("sonnet", 2), ("fable", 4), ("opus", 4)]
        case nil: families = []
        }
        let match = families.first { item in
            // Fable 5.1 is the established tier; new versions are not auto-rated.
            if item.name == "fable", candidate != "claude-fable-5-1", labelCandidate != "fable 5.1" { return false }
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
        case 1: return AgentMixTheme.adaptive(0x347757, 0x8AC7A0)
        case 2: return AgentMixTheme.adaptive(0x876719, 0xD3B86A)
        case 3: return AgentMixTheme.adaptive(0xB05D28, 0xE3A06B)
        case 4: return AgentMixTheme.adaptive(0xA94B50, 0xE49AA9)
        default: return AgentMixTheme.muted
        }
    }
    var help: String {
        guard let family else { return "Unrated model family" }
        return "\(family) · model level \(level) of 4"
    }
}

struct ModelFamilyMark: View {
    let identity: ModelIdentity
    var subdued = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(subdued ? AgentMixTheme.muted.opacity(index < identity.level ? 0.55 : 0.14)
                          : index < identity.level ? identity.color : AgentMixTheme.ink.opacity(0.12))
                    .frame(width: 2.7, height: CGFloat(4 + index * 3))
            }
        }
        .frame(width: 16, height: 14, alignment: .bottomLeading)
        .help(identity.help).accessibilityHidden(true)
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
                .foregroundStyle(previous ? AgentMixTheme.muted.opacity(0.85) : identity.color)
                .fontWeight(emphasized && !previous ? .semibold : .medium)
                .fixedSize(horizontal: false, vertical: true)
            if modelID == Route.autoControllerModelID {
                Text("Current model").font(.system(size: 10)).foregroundStyle(AgentMixTheme.muted)
            }
        }
        .help(modelID == Route.autoControllerModelID ? "Keeps the current native model and effort. Saved defaults stay unchanged; no extra controller is launched." : modelID + " · " + identity.help)
    }
}
