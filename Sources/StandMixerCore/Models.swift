import Foundation

public enum AgentPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

public enum WorkCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case coordinator
    case planning, quickIdeas, algorithms
    case ui, uiImplementation = "uiBuild", uiReview
    case implementation, routineCoding, debugging
    case review, developmentSecurity, securityReview
    case research, draftingEditing, deepAnalysis
    case mechanical, computerUse

    public static let topLevelCases: [Self] = [.planning, .ui, .implementation, .review, .research, .mechanical]

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
        case .planning: return "Planning & algorithms"
        case .quickIdeas: return "Quick ideas"
        case .algorithms: return "Algorithms"
        case .ui: return "Design & UI"
        case .uiImplementation: return "UI implementation"
        case .uiReview: return "UI review"
        case .implementation: return "General coding"
        case .routineCoding: return "Routine coding"
        case .debugging: return "Debugging / root cause"
        case .review: return "Code review"
        case .developmentSecurity: return "Development security"
        case .securityReview: return "Release security"
        case .research: return "Research & writing"
        case .draftingEditing: return "Drafting & editing"
        case .deepAnalysis: return "Deep analysis"
        case .mechanical: return "Routine tasks"
        case .computerUse: return "Computer use"
        }
    }

    public var parent: Self? {
        switch self {
        case .quickIdeas, .algorithms: return .planning
        case .uiImplementation, .uiReview: return .ui
        case .routineCoding, .debugging: return .implementation
        case .developmentSecurity, .securityReview: return .review
        case .draftingEditing, .deepAnalysis: return .research
        case .computerUse: return .mechanical
        case .coordinator, .planning, .ui, .implementation, .review, .research, .mechanical: return nil
        }
    }

    public var children: [Self] { Self.allCases.filter { $0.parent == self } }

    public var description: String {
        switch self {
        case .coordinator: return "Current chat and coordination."
        case .planning: return "Technical plans, open design decisions, and feasibility tradeoffs."
        case .quickIdeas: return "Bounded nontechnical ideas such as names or rough options."
        case .algorithms: return "Unresolved algorithm or invention design, including experimental code that tests its assumptions."
        case .ui: return "Visual design, layout, styling, and interaction decisions."
        case .uiImplementation: return "Implementing visual and interaction changes."
        case .uiReview: return "Reviewing or judging visual and interaction quality."
        case .implementation: return "Coding once the approach is settled, including mapping unfamiliar code to implement a change."
        case .routineCoding: return "Implement bounded, well-specified work once the approach, interfaces, and acceptance checks are clear. Includes complete components, adapters, storage code, tests, and specific review fixes—not just mechanical edits."
        case .debugging: return "Diagnosing failures, tracing causes, and investigating uncertain behavior."
        case .review: return "Reviewing code for correctness, regressions, and maintainability."
        case .developmentSecurity: return "Bounded security checks during private development, including authentication, permissions, and secret handling."
        case .securityReview: return "Reviewing vulnerabilities early in public release preparation, including internet-reachable staging and test systems."
        case .research: return "Gathering evidence and developing written work."
        case .draftingEditing: return "Drafting and editing when the content and facts are settled."
        case .deepAnalysis: return "Drawing new conclusions, evaluating difficult claims, or resolving conflicting evidence."
        case .mechanical: return "Executing known procedures, such as running an existing test suite or formatting files."
        case .computerUse: return "Visually operating applications or browser interfaces."
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
        .init(id: "claude-fable-5-2", label: "Fable 5.2", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast()), defaultEffort: "medium"),
        .init(id: "claude-fable-5-1", label: "Fable 5.1", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast()), defaultEffort: "high"),
        .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast())),
        .init(id: "claude-haiku-5-5", label: "Haiku 5.5", platform: .claude, supportedEfforts: Array(EffortPolicy.levels.dropLast()), defaultEffort: "medium"),
    ]

    /// Ordered levels used to translate a caller's intensity in generated launch guidance.
    /// This describes the launch request; StandMixer does not enforce runtime effort.
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
    public var inheritsModel: Bool
    public var inheritsEffort: Bool
    public var inheritsTeam: Bool
    public var stuckEscalation: [AgentAssignment]
    public var id: String { category.rawValue }
    public var isAutoController: Bool { category == .coordinator && modelID == Self.autoControllerModelID }
    public init(category: WorkCategory, modelID: String, effort: EffortPolicy = .auto,
                additionalAgents: [AgentAssignment] = [], resultMode: RouteResultMode = .coordinator, judgeModelID: String? = nil,
                teamMode: RouteTeamMode = .parallel, inheritsModel: Bool = false, inheritsEffort: Bool = false,
                inheritsTeam: Bool = false, stuckEscalation: [AgentAssignment] = []) {
        self.category = category; self.modelID = modelID; self.effort = effort; self.additionalAgents = additionalAgents
        self.resultMode = resultMode; self.judgeModelID = judgeModelID; self.teamMode = teamMode
        self.inheritsModel = inheritsModel; self.inheritsEffort = inheritsEffort; self.inheritsTeam = inheritsTeam
        self.stuckEscalation = stuckEscalation
    }
    private enum CodingKeys: String, CodingKey {
        case category, modelID, effort, additionalAgents, resultMode, judgeModelID, teamMode
        case inheritsModel, inheritsEffort, inheritsTeam
        case stuckEscalation
    }
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
        inheritsModel = try values.decodeIfPresent(Bool.self, forKey: .inheritsModel) ?? false
        inheritsEffort = try values.decodeIfPresent(Bool.self, forKey: .inheritsEffort) ?? false
        inheritsTeam = try values.decodeIfPresent(Bool.self, forKey: .inheritsTeam) ?? false
        stuckEscalation = try values.decodeIfPresent([AgentAssignment].self, forKey: .stuckEscalation) ?? []
    }

    fileprivate func inheriting(from parent: Self) -> Self {
        var route = self
        if inheritsModel { route.modelID = parent.modelID }
        if inheritsEffort { route.effort = parent.effort }
        if inheritsTeam {
            route.additionalAgents = parent.additionalAgents
            route.teamMode = parent.teamMode
            route.resultMode = parent.resultMode
            route.judgeModelID = parent.judgeModelID
        }
        route.inheritsModel = false
        route.inheritsEffort = false
        route.inheritsTeam = false
        return route
    }

    fileprivate func child(_ category: WorkCategory, modelID: String? = nil, effort: EffortPolicy? = nil,
                           team: [AgentAssignment]? = nil) -> Self {
        // Keep concrete stored values for older editors and serialized drafts.
        .init(category: category, modelID: modelID ?? self.modelID, effort: effort ?? self.effort,
              additionalAgents: team ?? [], teamMode: teamMode,
              inheritsModel: modelID == nil, inheritsEffort: effort == nil, inheritsTeam: team == nil)
    }
}

public struct RoutingProfile: Codable, Hashable, Identifiable, Sendable {
    public var platform: AgentPlatform
    public var routes: [Route]
    public var id: String { platform.rawValue }
    public init(platform: AgentPlatform, routes: [Route]) { self.platform = platform; self.routes = routes }
    public func route(for category: WorkCategory) -> Route? { routes.first { $0.category == category } }

    /// Resolve the active assignment without mutating the child's stored overrides.
    public func effectiveRoute(for category: WorkCategory) -> Route? {
        guard let assignment = route(for: category) else { return nil }
        guard let parent = category.parent else { return assignment }
        guard let parentRoute = route(for: parent) else { return nil }
        return assignment.inheriting(from: parentRoute)
    }

    public var effectiveRoutes: [Route] { WorkCategory.allCases.compactMap(effectiveRoute(for:)) }

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
    public init(from decoder: Decoder) throws { try self.init(from: decoder, migrate: true) }

    fileprivate struct AppliedSnapshot: Decodable {
        let profile: RoutingProfile
        init(from decoder: Decoder) throws { profile = try RoutingProfile(from: decoder, migrate: false) }
    }

    private init(from decoder: Decoder, migrate: Bool) throws {
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
        let decodedCategories = Set(byCategory.keys)
        let legacyCategories: Set<WorkCategory> = [.coordinator, .planning, .ui, .implementation, .algorithms, .review, .mechanical]
        let previewCategories = Set(WorkCategory.allCases).subtracting([.developmentSecurity])
        if migrate && decodedCategories.isSubset(of: legacyCategories) {
            // v0.1.8 had no research slot. Use a native default for this new
            // group while preserving every pre-existing route as entered.
            byCategory[.research] = StandMixerConfiguration.presetTopLevel(.optimized, platform: platform)[.research]
            for category in WorkCategory.allCases where byCategory[category] == nil {
                if let parent = category.parent, let parentRoute = byCategory[parent] {
                    byCategory[category] = parentRoute.child(category)
                }
            }
        } else if migrate && decodedCategories == previewCategories && decoded.count == previewCategories.count,
                  let review = byCategory[.review] {
            // Earlier 0.2 drafts used the ordinary review route for this work.
            byCategory[.developmentSecurity] = review.child(.developmentSecurity)
        }
        routes = WorkCategory.allCases.compactMap { byCategory[$0] }
    }
}

public enum StandMixerPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case fast, optimized, high
    public var id: String { rawValue }
    public var title: String { "StandMixer " + (self == .high ? "High-quality" : rawValue.capitalized) }
}

public struct SavedRoutingPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: StandMixerConfiguration
    public init(id: UUID = UUID(), name: String, configuration: StandMixerConfiguration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}

public struct StandMixerConfiguration: Codable, Hashable, Sendable {
    public var profiles: [RoutingProfile]
    public var customModels: [ModelSpec]
    public var enabledPlatforms: Set<AgentPlatform>?
    public init(profiles: [RoutingProfile], customModels: [ModelSpec] = [], enabledPlatforms: Set<AgentPlatform>? = nil) {
        self.profiles = profiles; self.customModels = customModels; self.enabledPlatforms = enabledPlatforms
    }
    public func profile(for platform: AgentPlatform) -> RoutingProfile? { profiles.first { $0.platform == platform } }

    struct AppliedSnapshot: Decodable {
        let configuration: StandMixerConfiguration
        private enum CodingKeys: String, CodingKey { case profiles, customModels, enabledPlatforms }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let profiles = try values.decode([RoutingProfile.AppliedSnapshot].self, forKey: .profiles).map(\.profile)
            configuration = .init(profiles: profiles,
                                  customModels: try values.decode([ModelSpec].self, forKey: .customModels),
                                  enabledPlatforms: try values.decodeIfPresent(Set<AgentPlatform>.self, forKey: .enabledPlatforms))
        }
    }

    public func validateNativeCoordinators(catalog: [ModelSpec], platforms: Set<AgentPlatform>? = nil) throws {
        guard !customModels.contains(where: { $0.id == Route.autoControllerModelID }) else {
            throw StandMixerError.invalid("Auto is reserved for the controller selection. Use a concrete model ID for custom model definitions.")
        }
        for profile in profiles where platforms?.contains(profile.platform) ?? true {
            let coordinators = profile.routes.filter { $0.category == .coordinator }
            guard coordinators.count == 1, let coordinator = coordinators.first,
                  coordinator.additionalAgents.isEmpty,
                  coordinator.isAutoController ? coordinator.effort.mode == .auto : catalog.first(where: { $0.id == coordinator.modelID })?.platform == profile.platform else {
                throw StandMixerError.invalid("The \(profile.platform.displayName) controller must be Auto or one known native \(profile.platform.displayName) model. Auto keeps the current chat model and effort; add a native model definition for a custom pin.")
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
    public static func preset(_ preset: StandMixerPreset, availablePlatforms: Set<AgentPlatform>) -> Self {
        // A single available harness uses only its native models. Give the
        // inactive profile its own native fallback as well.
        let nativeOnly = availablePlatforms.count == 1
        return .init(profiles: AgentPlatform.allCases.map { platform in
            let topLevel = presetTopLevel(preset, platform: platform, nativeOnly: nativeOnly)
            let controller = Route(category: .coordinator, modelID: Route.autoControllerModelID, teamMode: .leadReview)
            let routes = [controller] + WorkCategory.topLevelCases.flatMap { category -> [Route] in
                let parent = topLevel[category]!
                return [parent] + category.children.map {
                    presetChild($0, parent: parent, preset: preset, platform: platform, nativeOnly: nativeOnly)
                }
            }
            return RoutingProfile(platform: platform, routes: routes)
        })
    }

    private enum PresetModel: String {
        case luna = "gpt-6-luna", sol = "gpt-6.1-sol", astra = "gpt-6-astra"
        case haiku = "claude-haiku-5-5", opus = "claude-opus-5-5", fable = "claude-fable-5-2"
    }

    fileprivate static func presetTopLevel(_ preset: StandMixerPreset, platform: AgentPlatform, nativeOnly: Bool = false) -> [WorkCategory: Route] {
        let assignments: [WorkCategory: (PresetModel, String)]
        switch (preset, platform) {
        case (.fast, .codex):
            assignments = [.planning: (.astra, "medium"), .ui: (.astra, "low"), .implementation: (.astra, "medium"),
                           .review: (.astra, "medium"), .research: (.astra, "medium"), .mechanical: (.luna, "low")]
        case (.fast, .claude):
            assignments = [.planning: (.fable, "medium"), .ui: (.fable, "low"), .implementation: (.opus, "medium"),
                           .review: (.opus, "medium"), .research: (.opus, "medium"), .mechanical: (.haiku, "low")]
        case (.optimized, .codex):
            assignments = [.planning: (.astra, "max"), .ui: (.astra, "max"), .implementation: (.astra, "xhigh"),
                           .review: (.astra, "max"), .research: (.astra, "xhigh"), .mechanical: (.luna, "medium")]
        case (.optimized, .claude):
            assignments = [.planning: (.fable, "max"), .ui: (.fable, "max"), .implementation: (.opus, "xhigh"),
                           .review: (.opus, "max"), .research: (.opus, "xhigh"), .mechanical: (.haiku, "medium")]
        case (.high, .codex):
            assignments = [.planning: (.astra, "max"), .ui: (.astra, "max"), .implementation: (.astra, "max"),
                           .review: (.astra, "max"), .research: (.astra, "max"), .mechanical: (.luna, "medium")]
        case (.high, .claude):
            assignments = [.planning: (.fable, "max"), .ui: (.fable, "max"), .implementation: (.fable, "max"),
                           .review: (.fable, "max"), .research: (.fable, "max"), .mechanical: (.haiku, "medium")]
        }
        return Dictionary(uniqueKeysWithValues: WorkCategory.topLevelCases.enumerated().map { index, category in
            let assignment = assignments[category]!
            var route = Route(category: category, modelID: assignment.0.rawValue, effort: .fixed(assignment.1), teamMode: .leadReview)
            if preset == .high && category != .mechanical {
                let partner: PresetModel = platform == .codex ? (nativeOnly ? .sol : .fable)
                    : (!nativeOnly && (category == .planning || category == .ui) ? .astra : .opus)
                let serial = (platform == .codex ? 120 : 220) + index
                route.additionalAgents = [.init(id: presetWorkerID(serial), modelID: partner.rawValue, effort: .fixed("max"))]
                route.teamMode = category == .implementation ? .leadReview : .parallel
            }
            return (category, route)
        })
    }

    private static func presetChild(_ category: WorkCategory, parent: Route, preset: StandMixerPreset,
                                    platform: AgentPlatform, nativeOnly: Bool) -> Route {
        let strongNative: PresetModel = platform == .codex ? .astra : .opus
        switch category {
        case .algorithms where preset == .fast:
            return parent.child(category, effort: .fixed("high"))
        case .quickIdeas:
            return parent.child(category, modelID: platform == .claude ? PresetModel.opus.rawValue : nil,
                                effort: .fixed("medium"), team: preset == .high ? [] : nil)
        case .draftingEditing:
            return parent.child(category, effort: .fixed("medium"), team: preset == .high ? [] : nil)
        case .developmentSecurity:
            return parent.child(category, modelID: preset == .high && platform == .claude ? PresetModel.opus.rawValue : nil,
                                effort: .fixed("medium"), team: preset == .high ? [] : nil)
        case .deepAnalysis:
            return parent.child(category, modelID: preset == .fast ? strongNative.rawValue : nil, effort: .fixed("max"))
        case .debugging:
            var route = parent.child(category, modelID: preset == .fast ? strongNative.rawValue : nil,
                                     effort: .fixed("max"), team: preset == .high ? [] : nil)
            let targets: [PresetModel] = !nativeOnly ? [.fable, .astra, .opus] : platform == .codex ? [.astra] : [.fable, .opus]
            let stableOrder: [PresetModel] = [.fable, .astra, .opus]
            route.stuckEscalation = targets.map { model in
                let index = stableOrder.firstIndex(of: model)!
                let serial = (platform == .codex ? 110 : 210) + index
                return AgentAssignment(id: presetWorkerID(serial), modelID: model.rawValue, effort: .fixed("max"))
            }
            return route
        case .routineCoding:
            let model: PresetModel = nativeOnly && platform == .claude ? .opus : .sol
            return parent.child(category, modelID: model.rawValue, effort: .fixed("max"), team: preset == .high ? [] : nil)
        case .securityReview:
            let lead: PresetModel = nativeOnly && platform == .claude ? .fable : .astra
            let team: [AgentAssignment] = nativeOnly ? [] : [
                .init(id: presetWorkerID(platform == .codex ? 109 : 209), modelID: PresetModel.fable.rawValue, effort: .fixed("max"))
            ]
            var route = parent.child(category, modelID: lead.rawValue, effort: .fixed("max"), team: team)
            route.teamMode = .parallel
            return route
        case .computerUse:
            return parent.child(category, modelID: strongNative.rawValue, effort: .fixed("medium"))
        default:
            return parent.child(category)
        }
    }

    private static func presetWorkerID(_ serial: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", serial))!
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
    public var appliedConfiguration: StandMixerConfiguration?
    public var platforms: Set<AgentPlatform>
    public var preservedConflicts: [String]
    var installationBefore: String?
    public init(id: UUID = UUID(), createdAt: Date = Date(), changes: [FileChange], preconditions: [FilePrecondition] = [], appliedConfiguration: StandMixerConfiguration? = nil, platforms: Set<AgentPlatform> = [], preservedConflicts: [String] = []) {
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

public enum StandMixerError: LocalizedError {
    case invalid(String), conflict(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .conflict(let message): return message }
    }
}
