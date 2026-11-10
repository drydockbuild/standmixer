import StandMixerCore

/// Native-edit lifecycle tests opt into Advanced pins; factory defaults use Auto.
func pinnedControllers(_ configuration: StandMixerConfiguration = .defaults,
                       codex: String = "gpt-6.1-sol", claude: String = "claude-opus-5-5",
                       effort: EffortPolicy = .auto) -> StandMixerConfiguration {
    var result = configuration
    for profile in result.profiles.indices {
        guard let route = result.profiles[profile].routes.firstIndex(where: { $0.category == .coordinator }) else { continue }
        result.profiles[profile].routes[route].modelID = result.profiles[profile].platform == .codex ? codex : claude
        result.profiles[profile].routes[route].effort = effort
    }
    return result
}
