import Foundation

// Legacy response DTOs remain decodable for old saved data. StandMixer no longer
// starts preference inspections or reads and publishes observer caches.

public struct StandMixerModObservedWorker: Codable, Sendable {
    public var id: UUID
    public var modelID: String
    public var modelPlatform: AgentPlatform?
    public var effort: EffortPolicy?
    init(_ worker: ImportedAgentAssignment) {
        id = worker.id; modelID = worker.modelID; modelPlatform = worker.modelPlatform; effort = worker.effort
    }
}

public struct StandMixerModObservedRoute: Codable, Sendable {
    public var category: WorkCategory
    public var modelID: String?
    public var modelPlatform: AgentPlatform?
    public var effort: EffortPolicy?
    public var evidence: [ImportEvidence]
    public var uncertainties: [String]
    public var additionalAgents: [StandMixerModObservedWorker]?
    public var resultMode: RouteResultMode?
    public var judgeModelID: String?
    public var scope: String
    init(_ route: ImportedRoute) {
        category = route.category; modelID = route.modelID; modelPlatform = route.modelPlatform
        effort = route.effort; evidence = route.evidence; uncertainties = route.uncertainties
        additionalAgents = route.additionalAgents?.map(StandMixerModObservedWorker.init)
        resultMode = route.resultMode; judgeModelID = route.judgeModelID; scope = route.scope.rawValue
    }
}

public struct StandMixerModInspectionReport: Codable, Sendable {
    public var platform: AgentPlatform
    public var status: String
    public var summary: String
    public var routes: [StandMixerModObservedRoute]
    public var notes: [String]
    public var sources: [ImportEvidence]
    public var executionModelID: String?
    public var error: String?
}

public struct StandMixerModInspection: Codable, Sendable {
    public var createdAt: Date
    public var expiresAt: Date
    public var reports: [StandMixerModInspectionReport]
    public var fromCache: Bool
}
