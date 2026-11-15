import SwiftUI
import StandMixerCore

enum CurrentReadState {
    case idle, completed
    var isRunning: Bool { false }
    var label: String { self == .completed ? "Saved settings" : "Not recorded" }
}

struct CurrentSettingsRun {
    var state: CurrentReadState = .idle
    var proposal: AgentImportProposal?
    var receivedAt: Date?
    var isPreviousReport: Bool { false }
}

/// Deterministic comparisons from saved settings and verified installation records.
/// This controller never starts an agent, checks an account, or reads chat history.
@MainActor
final class CurrentSettingsController: ObservableObject {
    @Published private(set) var runs: [AgentPlatform: CurrentSettingsRun] = [:]
    @Published private(set) var nativeSettings: [AgentPlatform: StandMixerModNativeSettings] = [:]
    @Published private(set) var isDemo = false
    private let service: IntegrationService

    init(service: IntegrationService) {
        self.service = service
        refreshAll(platforms: Set(AgentPlatform.allCases))
    }

    var scopeURL: URL { service.home }
    func run(for platform: AgentPlatform) -> CurrentSettingsRun { runs[platform] ?? CurrentSettingsRun() }
    func finding(platform: AgentPlatform, category: WorkCategory) -> ImportedRoute? {
        runs[platform]?.proposal?.routes.first { $0.category == category }
    }

    func refreshAll(platforms: Set<AgentPlatform>) {
        guard !ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        let installed = try? service.installationStatus()
        for platform in platforms {
            let native = StandMixerModNativeSettings.capture(platform: platform, service: service)
            nativeSettings[platform] = native
            var routes: [ImportedRoute] = []
            if installed?.state == .applied, installed?.installedPlatforms.contains(platform) == true,
               let profile = installed?.appliedConfiguration?.profile(for: platform) {
                routes = WorkCategory.allCases.compactMap { category in
                    guard let route = profile.effectiveRoute(for: category) else { return nil }
                    return ImportedRoute(category: category, modelID: route.modelID, effort: route.effort,
                        evidence: [.init(path: "StandMixer installation record", explanation: "Verified applied routing configuration.")],
                        additionalAgents: route.additionalAgents.map(ImportedAgentAssignment.init),
                        resultMode: route.resultMode, judgeModelID: route.judgeModelID)
                }
            } else if let model = native.modelID {
                routes = [.init(category: .coordinator, modelID: model, modelPlatform: platform,
                    effort: native.effort.map(EffortPolicy.fixed),
                    evidence: [.init(path: native.sourcePath, explanation: native.detail)])]
            }
            runs[platform] = .init(state: .completed,
                proposal: .init(platform: platform, workingDirectory: service.home.path, routes: routes,
                    summary: "Saved local settings. Running sessions may use different choices."), receivedAt: Date())
        }
    }

    func invalidateReports(platforms: Set<AgentPlatform> = Set(AgentPlatform.allCases)) {
        refreshAll(platforms: platforms)
    }
    func clearReports() { runs = [:]; nativeSettings = [:] }

    func loadSnapshotDemo(configuration: StandMixerConfiguration, platforms: Set<AgentPlatform>) {
        guard ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        isDemo = true
        for platform in platforms {
            let profile = configuration.profile(for: platform)!
            let routes = profile.routes.filter { $0.category != .mechanical }.map { route in
                ImportedRoute(category: route.category, modelID: route.modelID,
                              modelPlatform: ModelSpec.builtIn.first { $0.id == route.modelID }?.platform,
                              effort: route.effort,
                              evidence: [.init(path: "Example configuration", explanation: "Synthetic UI capture data. No agent was started.")],
                              additionalAgents: route.additionalAgents.map(ImportedAgentAssignment.init), resultMode: route.resultMode, judgeModelID: route.judgeModelID)
            }
            runs[platform] = CurrentSettingsRun(state: .completed,
                proposal: .init(platform: platform, workingDirectory: scopeURL.path, routes: routes,
                                summary: "Synthetic UI capture data. No agent was started."), receivedAt: Date())
        }
    }
}

extension ImportedRoute {
    /// An observer can report an empty category placeholder. It must not hide a
    /// supported recent project preference for the same category.
    var hasKnownSettings: Bool {
        modelID != nil || effort != nil || additionalAgents != nil || resultMode != nil || judgeModelID != nil
    }
}
