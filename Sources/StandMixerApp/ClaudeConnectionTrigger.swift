import StandMixerCore

enum ClaudeConnectionTrigger {
    static func usage(in configuration: StandMixerConfiguration, catalog: [ModelSpec]) -> [String: Int] {
        guard configuration.enabledPlatforms?.contains(.codex) != false,
              configuration.enabledPlatforms?.contains(.claude) != false,
              let profile = configuration.profile(for: .codex) else { return [:] }
        var result: [String: Int] = [:]
        for route in profile.effectiveRoutes {
            func add(_ role: String, _ id: String) {
                guard catalog.first(where: { $0.id == id })?.platform == .claude else { return }
                result[route.category.rawValue + "|" + role + "|" + id, default: 0] += 1
            }
            add("lead", route.modelID)
            for agent in route.additionalAgents { add("team", agent.modelID) }
            for agent in route.stuckEscalation { add("escalation", agent.modelID) }
            if route.resultMode == .ai, let judge = route.judgeModelID { add("judge", judge) }
        }
        return result
    }

    static func introducesClaude(before: StandMixerConfiguration, after: StandMixerConfiguration,
                                 catalog: [ModelSpec]) -> Bool {
        let previous = usage(in: before, catalog: catalog)
        return usage(in: after, catalog: catalog).contains { key, count in count > previous[key, default: 0] }
    }

    /// Opening presents a fresh preset proposal, which can omit an unavailable
    /// provider even though the saved or applied Codex routes still require it.
    static func requiredOnOpen(configuration: StandMixerConfiguration,
                               savedConfiguration: StandMixerConfiguration?,
                               installation: InstallationStatus?, catalog: [ModelSpec]) -> Bool {
        guard configuration.enabledPlatforms?.contains(.codex) != false,
              configuration.enabledPlatforms?.contains(.claude) != false else { return false }
        let applied = installation?.installedPlatforms.contains(.codex) == true
            ? installation?.appliedConfiguration : nil
        return [configuration, savedConfiguration, applied].compactMap { $0 }.contains { candidate in
            let candidateCatalog = ModelSpec.catalog(discovered: catalog, custom: candidate.customModels)
            return !usage(in: candidate, catalog: candidateCatalog).isEmpty
        }
    }
}
