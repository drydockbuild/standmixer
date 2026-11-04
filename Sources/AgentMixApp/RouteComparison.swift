import AgentMixCore

/// Only a fresh, reported field can establish a difference. Unknowns stay unknown.
struct RouteComparison {
    let current: ImportedRoute?
    let proposed: Route
    var previousTeamMode: RouteTeamMode? = nil
    var teamModeChanged: Bool { !proposed.additionalAgents.isEmpty && previousTeamMode.map { $0 != proposed.teamMode } == true }
    var countChanged: Bool { current?.additionalAgents.map { $0.count != proposed.additionalAgents.count } ?? false }
    var resultChanged: Bool { current?.resultMode.map { $0 != proposed.resultMode } ?? false }
    var judgeChanged: Bool {
        if proposed.resultMode == .ai {
            if let judge = current?.judgeModelID { return judge != proposed.judgeModelID }
            return current?.resultMode.map { $0 != .ai } ?? false
        }
        return current?.judgeModelID != nil
    }
    var hasModelChanges: Bool { (0...proposed.additionalAgents.count).contains(where: modelChanged) }
    var hasKnownChanges: Bool {
        teamModeChanged || countChanged || resultChanged || judgeChanged || hasModelChanges
            || (0...proposed.additionalAgents.count).contains(where: effortChanged)
    }
    func modelChanged(_ index: Int) -> Bool {
        if index == 0 { return current?.modelID.map { $0 != proposed.modelID } ?? false }
        guard let agents = current?.additionalAgents, proposed.additionalAgents.indices.contains(index - 1) else { return false }
        guard agents.indices.contains(index - 1) else { return true }
        return agents[index - 1].modelID != proposed.additionalAgents[index - 1].modelID
    }
    func effortChanged(_ index: Int) -> Bool {
        if proposed.isAutoController { return false }
        if index == 0 { return current?.effort.map { !$0.semanticallyMatches(proposed.effort) } ?? false }
        guard let agents = current?.additionalAgents, proposed.additionalAgents.indices.contains(index - 1) else { return false }
        guard agents.indices.contains(index - 1) else { return true }
        return agents[index - 1].effort.map { !$0.semanticallyMatches(proposed.additionalAgents[index - 1].effort) } ?? false
    }
}
