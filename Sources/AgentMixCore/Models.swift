import Foundation

public enum AgentPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

public enum WorkCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case coordinator, planning, ui, implementation, algorithms, review, mechanical
    public var id: String { rawValue }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "uiDesign" || value == "uiImplementation" { self = .ui }
        else if value == "algorithmReview" { self = .algorithms }
        else if let known = Self(rawValue: value) { self = known }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown work category")) }
    }
    public var title: String {
        switch self {
        case .coordinator: return "Controller"
        case .planning: return "Planning"
        case .ui: return "Visual"
        case .implementation: return "Implementation"
        case .algorithms: return "Algorithms"
        case .review: return "Review & Security"
        case .mechanical: return "Mechanical work"
        }
    }
}

public struct ModelSpec: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var platform: AgentPlatform
    public var supportedEfforts: [String]
    public var isDiscovered: Bool
    public var defaultEffort: String?
    public init(id: String, label: String, platform: AgentPlatform, supportedEfforts: [String]? = nil, isDiscovered: Bool = false, defaultEffort: String? = nil) {
        self.id = id; self.label = label; self.platform = platform
        self.supportedEfforts = supportedEfforts ?? (platform == .claude ? Array(EffortPolicy.levels.dropLast()) : EffortPolicy.levels)
        self.isDiscovered = isDiscovered
        self.defaultEffort = defaultEffort
    }
    private enum CodingKeys: String, CodingKey { case id, label, platform, supportedEfforts, isDiscovered, defaultEffort }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
            label: try values.decode(String.self, forKey: .label),
            platform: try values.decode(AgentPlatform.self, forKey: .platform),
            supportedEfforts: try values.decodeIfPresent([String].self, forKey: .supportedEfforts),
            isDiscovered: try values.decodeIfPresent(Bool.self, forKey: .isDiscovered) ?? false,
            defaultEffort: try values.decodeIfPresent(String.self, forKey: .defaultEffort))
    }
    public static let builtIn: [ModelSpec] = [
        .init(id: "gpt-6.1-sol", label: "Sol 6.1", platform: .codex, defaultEffort: "low"),
        .init(id: "gpt-6-astra", label: "Astra 6", platform: .codex, defaultEffort: "medium"),
        .init(id: "gpt-6.1-terra", label: "Terra 6.1", platform: .codex, defaultEffort: "low"),
        .init(id: "gpt-6-luna", label: "Luna 6", platform: .codex, supportedEfforts: Array(EffortPolicy.levels.dropLast()), defaultEffort: "medium"),
        .init(id: "claude-opus-5-5", label: "Opus 5.5", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast()), defaultEffort: "medium"),
        .init(id: "claude-fable-5-1", label: "Fable 5.1", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast()), defaultEffort: "high"),
        .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast())),
        .init(id: "claude-haiku-5-5", label: "Haiku 5.5", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast()), defaultEffort: "medium"),
    ]

    /// Ordered levels used to translate a caller's intensity in generated launch guidance.
    /// This describes the launch request; AgentMix does not enforce runtime effort.
    var callerEfforts: [String] {
        EffortPolicy.levels.filter { supportedEfforts.contains($0) && (platform != .claude || $0 != "ultra") }
    }
    func nearestSupportedEffort(to callerEffort: String) -> String? {
        guard let requested = EffortPolicy.levels.firstIndex(of: callerEffort) else { return nil }
        // Iterate in ascending order so an equal-distance tie uses the lower level.
        return callerEfforts.min {
            abs(EffortPolicy.levels.firstIndex(of: $0)! - requested) < abs(EffortPolicy.levels.firstIndex(of: $1)! - requested)
        }
    }

    /// Provider identity belongs to the installed/catalogued model, not a custom
    /// entry that happens to reuse its ID. Explicitly tagged new IDs remain valid.
    public static func catalog(discovered: [ModelSpec] = [], custom: [ModelSpec] = []) -> [ModelSpec] {
        var models = builtIn
        for model in discovered where model.id != Route.autoControllerModelID {
            if let index = models.firstIndex(where: { $0.id == model.id }) {
                if models[index].platform == model.platform { models[index] = model }
            } else { models.append(model) }
        }
        for model in custom where model.id != Route.autoControllerModelID && !models.contains(where: { $0.id == model.id }) { models.append(model) }
        return models
    }
}

public enum EffortMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto, fixed, range
    public var id: String { rawValue }
}

public struct EffortPolicy: Codable, Hashable, Sendable {
    public static let levels = ["low", "medium", "high", "xhigh", "max", "ultra"]
    public var mode: EffortMode
    public var value: String
    public var minimum: String
    public var maximum: String
    public init(mode: EffortMode = .auto, value: String = "high", minimum: String = "low", maximum: String = "high") {
        self.mode = mode; self.value = value; self.minimum = minimum; self.maximum = maximum
    }
    public static var auto: Self { .init() }
    public static func fixed(_ value: String) -> Self { .init(mode: .fixed, value: value) }
    public static func range(minimum: String, maximum: String) -> Self { .init(mode: .range, minimum: minimum, maximum: maximum) }
    public var description: String {
        switch mode {
        case .auto: return "follow caller"
        case .fixed: return value
        case .range: return "choose \(minimum) through \(maximum) for task complexity"
        }
    }
    /// Auto follows caller intent through native inheritance or launch guidance;
    /// fixed effort alone is saved as a native setting. Ranges guide future launches.
    public var nativeValue: String? { mode == .fixed ? value : nil }
}

public struct AgentAssignment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var modelID: String
    public var effort: EffortPolicy
    public var modelPlatform: AgentPlatform?
    public init(id: UUID = UUID(), modelID: String, effort: EffortPolicy = .auto, modelPlatform: AgentPlatform? = nil) {
        self.id = id; self.modelID = modelID; self.effort = effort; self.modelPlatform = modelPlatform
    }
}

public enum RouteResultMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case coordinator, user, ai
    public var id: String { rawValue }
}

public enum RouteTeamMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case leadReview, parallel
    public var id: String { rawValue }
}

public struct Route: Codable, Hashable, Identifiable, Sendable {
    /// Reserved controller selection, never an executable model ID. Keeping this
    /// in modelID preserves saved-route and settings DTO compatibility.
    public static let autoControllerModelID = "auto"
    public var category: WorkCategory
    public var modelID: String
    public var effort: EffortPolicy
    public var additionalAgents: [AgentAssignment]
    public var teamMode: RouteTeamMode
    public var resultMode: RouteResultMode
    public var judgeModelID: String?
    public var id: String { category.rawValue }
    public var isAutoController: Bool { category == .coordinator && modelID == Self.autoControllerModelID }
    public init(category: WorkCategory, modelID: String, effort: EffortPolicy = .auto,
                additionalAgents: [AgentAssignment] = [], resultMode: RouteResultMode = .coordinator, judgeModelID: String? = nil,
                teamMode: RouteTeamMode = .parallel) {
        self.category = category; self.modelID = modelID; self.effort = effort; self.additionalAgents = additionalAgents
        self.resultMode = resultMode; self.judgeModelID = judgeModelID; self.teamMode = teamMode
    }
    private enum CodingKeys: String, CodingKey { case category, modelID, effort, additionalAgents, resultMode, judgeModelID, teamMode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        category = try values.decode(WorkCategory.self, forKey: .category)
        modelID = try values.decode(String.self, forKey: .modelID)
        effort = try values.decode(EffortPolicy.self, forKey: .effort)
        additionalAgents = try values.decodeIfPresent([AgentAssignment].self, forKey: .additionalAgents) ?? []
        // Existing manual/saved teams ran independent passes. Absence is a
        // compatibility choice, not permission to replace them with new defaults.
        teamMode = try values.decodeIfPresent(RouteTeamMode.self, forKey: .teamMode) ?? .parallel
        resultMode = try values.decodeIfPresent(RouteResultMode.self, forKey: .resultMode) ?? .coordinator
        judgeModelID = try values.decodeIfPresent(String.self, forKey: .judgeModelID)
    }
}

public struct RoutingProfile: Codable, Hashable, Identifiable, Sendable {
    public var platform: AgentPlatform
    public var routes: [Route]
    public var id: String { platform.rawValue }
    public init(platform: AgentPlatform, routes: [Route]) { self.platform = platform; self.routes = routes }
    public func route(for category: WorkCategory) -> Route? { routes.first { $0.category == category } }
    private enum CodingKeys: String, CodingKey { case platform, routes }
    private struct StoredRoute: Decodable {
        let route: Route
        let wasCombined: Bool
        private enum Keys: String, CodingKey { case category }
        init(from decoder: Decoder) throws {
            route = try Route(from: decoder)
            wasCombined = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .category) == "algorithmReview"
        }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        platform = try values.decode(AgentPlatform.self, forKey: .platform)
        let decoded = try values.decode([StoredRoute].self, forKey: .routes)
        var byCategory: [WorkCategory: Route] = [:]
        for stored in decoded where !stored.wasCombined { byCategory[stored.route.category] = stored.route }
        // A legacy combined category applied to both jobs. Preserve its exact team,
        // effort and result handling; explicit new assignments take precedence.
        if let legacy = decoded.last(where: \.wasCombined)?.route {
            for category in [WorkCategory.algorithms, .review] where byCategory[category] == nil {
                var route = legacy
                route.category = category
                byCategory[category] = route
            }
        }
        routes = WorkCategory.allCases.compactMap { byCategory[$0] }
    }
}

public enum AgentMixPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case fast, optimized, high
    public var id: String { rawValue }
    public var title: String { "StandMixer " + rawValue.capitalized }
}

public struct SavedRoutingPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: AgentMixConfiguration
    public init(id: UUID = UUID(), name: String, configuration: AgentMixConfiguration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}

public struct AgentMixConfiguration: Codable, Hashable, Sendable {
    public var profiles: [RoutingProfile]
    public var customModels: [ModelSpec]
    public var enabledPlatforms: Set<AgentPlatform>?
    public init(profiles: [RoutingProfile], customModels: [ModelSpec] = [], enabledPlatforms: Set<AgentPlatform>? = nil) {
        self.profiles = profiles; self.customModels = customModels; self.enabledPlatforms = enabledPlatforms
    }
    public func profile(for platform: AgentPlatform) -> RoutingProfile? { profiles.first { $0.platform == platform } }

    public func validateNativeCoordinators(catalog: [ModelSpec], platforms: Set<AgentPlatform>? = nil) throws {
        guard !customModels.contains(where: { $0.id == Route.autoControllerModelID }) else {
            throw AgentMixError.invalid("Auto is reserved for the controller selection. Use a concrete model ID for custom model definitions.")
        }
        for profile in profiles where platforms?.contains(profile.platform) ?? true {
            let coordinators = profile.routes.filter { $0.category == .coordinator }
            guard coordinators.count == 1, let coordinator = coordinators.first,
                  coordinator.additionalAgents.isEmpty,
                  coordinator.isAutoController ? coordinator.effort.mode == .auto : catalog.first(where: { $0.id == coordinator.modelID })?.platform == profile.platform else {
                throw AgentMixError.invalid("The \(profile.platform.displayName) controller must be Auto or one known native \(profile.platform.displayName) model. Auto keeps the current chat model and effort; add a native model definition for a custom pin.")
            }
        }
    }

    /// Recover legacy/external drafts without replacing their worker assignments.
    /// Callers surface the notes before the repaired configuration becomes editable.
    public func repairingNativeCoordinators(catalog: [ModelSpec]) -> (configuration: Self, notes: [String]) {
        var repaired = self
        var notes: [String] = []
        for index in repaired.profiles.indices {
            let profile = repaired.profiles[index]
            let coordinators = profile.routes.filter { $0.category == .coordinator }
            if coordinators.count == 1, let coordinator = coordinators.first,
               coordinator.additionalAgents.isEmpty,
               coordinator.isAutoController ? coordinator.effort.mode == .auto : catalog.first(where: { $0.id == coordinator.modelID })?.platform == profile.platform { continue }
            let fallback = Self.defaults.profile(for: profile.platform)!.route(for: .coordinator)!
            repaired.profiles[index].routes.removeAll { $0.category == .coordinator }
            repaired.profiles[index].routes.insert(fallback, at: 0)
            notes.append("Reset \(profile.platform.displayName)’s incompatible controller to Auto; other assignments were kept.")
        }
        return (repaired, notes)
    }
    public static var defaults: Self { preset(.optimized, availablePlatforms: Set(AgentPlatform.allCases)) }
    public static func preset(_ preset: AgentMixPreset, availablePlatforms: Set<AgentPlatform>) -> Self {
        let available = availablePlatforms.isEmpty ? Set(AgentPlatform.allCases) : availablePlatforms
        return .init(profiles: AgentPlatform.allCases.map { platform in
            // A disabled profile keeps its own native fallback. An active single
            // harness never depends on the absent provider.
            let teams = presetTeams(preset, platform: platform, nativeOnly: available.count == 1)
            let routes = zip(WorkCategory.allCases, teams).enumerated().map { categoryIndex, entry in
                let (category, team) = entry
                let mode: RouteTeamMode = preset == .high || category == .review ? .parallel : .leadReview
                if category == .coordinator { return Route(category: category, modelID: Route.autoControllerModelID, teamMode: mode) }
                let extras = team.dropFirst().enumerated().map { extraIndex, model in
                    let serial = (platform == .codex ? 100 : 200) + categoryIndex + extraIndex * 1_000
                    let id = UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", serial))!
                    return AgentAssignment(id: id, modelID: model.rawValue, effort: .auto)
                }
                return Route(category: category, modelID: team[0].rawValue, effort: .auto,
                             additionalAgents: extras, resultMode: .coordinator, judgeModelID: nil, teamMode: mode)
            }
            return RoutingProfile(platform: platform, routes: routes)
        })
    }

    private enum PresetModel: String {
        case luna = "gpt-6-luna", sol = "gpt-6.1-sol", terra = "gpt-6.1-terra", astra = "gpt-6-astra"
        case haiku = "claude-haiku-5-5", sonnet = "claude-sonnet-5-5", opus = "claude-opus-5-5", fable = "claude-fable-5-1"
    }

    /// Rows follow WorkCategory.allCases: coordinator, planning, Visual,
    /// implementation, algorithms, Review & Security, mechanical. Team order is
    /// part of the approved recipe and is preserved in generated routing. The
    /// historical first row is ignored: every factory controller is now Auto.
    private static func presetTeams(_ preset: AgentMixPreset, platform: AgentPlatform, nativeOnly: Bool) -> [[PresetModel]] {
        switch (preset, platform, nativeOnly) {
        case (.fast, .codex, false):
            return [[.luna], [.sol], [.terra], [.luna], [.terra], [.opus], [.luna]]
        case (.fast, .claude, false):
            return [[.haiku], [.opus], [.sonnet], [.haiku], [.sonnet], [.sol], [.haiku]]
        case (.optimized, .codex, false):
            return [[.sol], [.astra], [.astra, .opus], [.sol], [.astra], [.opus], [.luna]]
        case (.optimized, .claude, false):
            return [[.opus], [.opus], [.opus, .fable], [.sol], [.opus], [.opus], [.haiku]]
        case (.high, .codex, false):
            return [[.astra], [.astra, .opus], [.astra, .opus, .fable], [.astra], [.astra, .fable, .opus], [.opus, .astra], [.luna]]
        case (.high, .claude, false):
            return [[.opus], [.opus, .fable], [.opus, .fable, .astra], [.opus], [.fable, .astra, .opus], [.opus, .astra], [.haiku]]
        case (.fast, .codex, true):
            return [[.luna], [.sol], [.terra], [.luna], [.terra], [.sol], [.luna]]
        case (.fast, .claude, true):
            return [[.haiku], [.opus], [.sonnet], [.haiku], [.sonnet], [.opus], [.haiku]]
        case (.optimized, .codex, true):
            return [[.sol], [.astra], [.astra, .sol], [.sol], [.astra], [.astra], [.luna]]
        case (.optimized, .claude, true):
            return [[.opus], [.opus], [.opus, .fable], [.fable], [.opus], [.opus], [.haiku]]
        case (.high, .codex, true):
            return [[.astra], [.astra, .sol], [.astra, .sol], [.astra], [.astra, .sol], [.astra, .sol], [.luna]]
        case (.high, .claude, true):
            return [[.opus], [.opus, .fable], [.opus, .fable], [.opus], [.fable, .opus], [.opus, .fable], [.haiku]]
        }
    }
}

public struct ConnectionStatus: Identifiable, Sendable {
    public var platform: AgentPlatform
    public var path: String?
    public var version: String?
    public var detail: String
    public var isInstalled: Bool
    public var compatibilityWarning: String?
    public var id: String { platform.rawValue }
    public init(platform: AgentPlatform, path: String?, version: String?, detail: String, isInstalled: Bool, compatibilityWarning: String? = nil) {
        self.platform = platform; self.path = path; self.version = version; self.detail = detail; self.isInstalled = isInstalled
        self.compatibilityWarning = compatibilityWarning
    }
}

public struct FileChange: Identifiable, Codable, Sendable {
    public var id: String { path }
    public var path: String
    public var before: String?
    public var after: String
    public var reason: String
    public var isDeletion: Bool
    public var isChanged: Bool { isDeletion ? before != nil : before != after }
    var expectedAfter: String? { isDeletion ? nil : after }
    public init(path: String, before: String?, after: String, reason: String, isDeletion: Bool = false) {
        self.path = path; self.before = before; self.after = after; self.reason = reason; self.isDeletion = isDeletion
    }
    private enum CodingKeys: String, CodingKey { case path, before, after, reason, isDeletion }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path); before = try values.decodeIfPresent(String.self, forKey: .before)
        after = try values.decode(String.self, forKey: .after); reason = try values.decode(String.self, forKey: .reason)
        isDeletion = try values.decodeIfPresent(Bool.self, forKey: .isDeletion) ?? false
    }
}

public struct IntegrationPreview: Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var changes: [FileChange]
    public var preconditions: [FilePrecondition]
    public var appliedConfiguration: AgentMixConfiguration?
    public var platforms: Set<AgentPlatform>
    public var preservedConflicts: [String]
    var installationBefore: String?
    public init(id: UUID = UUID(), createdAt: Date = Date(), changes: [FileChange], preconditions: [FilePrecondition] = [], appliedConfiguration: AgentMixConfiguration? = nil, platforms: Set<AgentPlatform> = [], preservedConflicts: [String] = []) {
        self.id = id; self.createdAt = createdAt; self.changes = changes; self.preconditions = preconditions
        self.appliedConfiguration = appliedConfiguration; self.platforms = platforms
        self.preservedConflicts = preservedConflicts
    }
}

/// A read-only input that selected a configuration target, including a file that did not yet exist.
public struct FilePrecondition: Codable, Hashable, Sendable {
    public var path: String
    public var before: String?
    public init(path: String, before: String?) { self.path = path; self.before = before }
}

public struct ApplyResult: Sendable {
    public var message: String
    public var changedFiles: Int
    public init(message: String, changedFiles: Int) { self.message = message; self.changedFiles = changedFiles }
}

public enum AgentMixError: LocalizedError {
    case invalid(String), conflict(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .conflict(let message): return message }
    }
}
