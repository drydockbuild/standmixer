import AppKit
import SwiftUI
import AgentMixCore

enum CurrentReadState {
    case idle, running(AgentImportPhase), completed, failed(String), cancelled
    var isRunning: Bool { if case .running = self { return true }; return false }
    var label: String {
        switch self {
        case .idle: return "Not read yet"
        case .running(.starting): return "Starting"
        case .running(.inspecting): return "Reading settings"
        case .running(.decoding), .running(.completed): return "Reading report"
        case .completed: return "Read complete"
        case .failed: return "Couldn’t read settings"
        case .cancelled: return "Stopped"
        }
    }
}

struct CurrentSettingsRun {
    var state: CurrentReadState = .idle
    var proposal: AgentImportProposal?
    var receivedAt: Date?
    var isPreviousReport: Bool {
        guard proposal != nil else { return false }
        if case .completed = state { return false }
        return true
    }
}

@MainActor
final class CurrentSettingsController: NSObject, ObservableObject {
    @Published var folderURL: URL?
    @Published private(set) var runs: [AgentPlatform: CurrentSettingsRun] = [:]
    @Published private(set) var isDemo = false
    private let service: AgentImportService
    private var tasks: [AgentPlatform: Task<Void, Never>] = [:]
    private var generations: [AgentPlatform: Int] = [:]
    private var lastScope: URL?

    init(service: AgentImportService) {
        self.service = service
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        tasks.values.forEach { $0.cancel() }
    }

    var scopeURL: URL { folderURL ?? FileManager.default.homeDirectoryForCurrentUser }
    func run(for platform: AgentPlatform) -> CurrentSettingsRun { runs[platform] ?? CurrentSettingsRun() }
    func finding(platform: AgentPlatform, category: WorkCategory) -> ImportedRoute? {
        let routes = runs[platform]?.proposal?.routes ?? []
        return Self.preferredFinding(in: routes, category: category)
    }

    static func preferredFinding(in routes: [ImportedRoute], category: WorkCategory) -> ImportedRoute? {
        let matches = routes.filter { $0.category == category }
        return matches.first { $0.scope == .current && $0.hasKnownSettings }
            ?? matches.first { $0.scope == .usual && $0.hasKnownSettings }
            ?? matches.first { $0.scope == .current }
            ?? matches.first
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = scopeURL
        panel.prompt = "Use folder"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.folderURL = url }
        }
    }

    func refreshAll(platforms: Set<AgentPlatform>) {
        guard !ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        for platform in AgentPlatform.allCases where !platforms.contains(platform) { cancel(platform) }
        if lastScope != scopeURL {
            for platform in AgentPlatform.allCases {
                cancel(platform)
                runs[platform] = CurrentSettingsRun()
            }
        }
        lastScope = scopeURL
        for platform in AgentPlatform.allCases where platforms.contains(platform) { refresh(platform) }
    }

    func refresh(_ platform: AgentPlatform) {
        guard !ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        tasks.removeValue(forKey: platform)?.cancel()
        generations[platform, default: 0] += 1
        let generation = generations[platform]!
        var next = run(for: platform)
        next.state = .running(.starting)
        runs[platform] = next
        let service = service
        let folder = scopeURL
        tasks[platform] = Task { [weak self] in
            do {
                let proposal = try await service.inspect(platform: platform, workingDirectory: folder) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.generations[platform] == generation, self.run(for: platform).state.isRunning else { return }
                        self.runs[platform]?.state = .running(phase)
                    }
                }
                guard let self, self.generations[platform] == generation, !Task.isCancelled else { return }
                self.runs[platform] = CurrentSettingsRun(state: .completed, proposal: proposal, receivedAt: Date())
                self.tasks.removeValue(forKey: platform)
            } catch {
                guard let self, self.generations[platform] == generation else { return }
                self.runs[platform]?.state = error is CancellationError || Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                self.tasks.removeValue(forKey: platform)
            }
        }
    }

    func cancel(_ platform: AgentPlatform) {
        guard run(for: platform).state.isRunning else { return }
        generations[platform, default: 0] += 1
        tasks.removeValue(forKey: platform)?.cancel()
        runs[platform]?.state = .cancelled
    }

    /// Configuration and scope changes invalidate evidence without starting inference.
    func invalidateReports(platforms: Set<AgentPlatform> = Set(AgentPlatform.allCases)) {
        for platform in platforms {
            cancel(platform)
            runs[platform]?.state = .idle
        }
    }

    func clearReports() {
        AgentPlatform.allCases.forEach(cancel)
        runs = [:]
        lastScope = nil
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        AgentPlatform.allCases.forEach(cancel)
    }

    func loadSnapshotDemo(configuration: AgentMixConfiguration, platforms: Set<AgentPlatform>) {
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
