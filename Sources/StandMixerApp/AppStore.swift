import SwiftUI
import StandMixerCore

@MainActor
final class AppStore: ObservableObject {
    static private(set) var didFinishDiscovery = false
    static private(set) var didFinishSnapshotPreview = false
    static private(set) var didFinishSnapshotUninstall = false
    static var isReadyForSnapshot: Bool {
        didFinishDiscovery
            && (!ProcessInfo.processInfo.arguments.contains("--preview") || didFinishSnapshotPreview)
            && (!ProcessInfo.processInfo.arguments.contains("--uninstall") || didFinishSnapshotUninstall)
    }

    @Published private(set) var configuration: StandMixerConfiguration = .defaults
    @Published private(set) var isEditing = false
    @Published var selectedPlatform: AgentPlatform = .codex
    @Published private(set) var connections: [ConnectionStatus] = []
    @Published private(set) var discoveredModels: [ModelSpec] = []
    @Published private(set) var savedPresets: [SavedRoutingPreset] = []
    @Published private(set) var hasDetectedConnections = false
    @Published private(set) var isChecking = false
    @Published private(set) var isPreparingPreview = false
    @Published private(set) var isApplying = false
    @Published private(set) var isPreparingUninstall = false
    @Published private(set) var isUninstalling = false
    @Published private(set) var installationStatus: InstallationStatus?
    @Published private(set) var canRestore = false
    @Published private(set) var saveStatus = "Draft"
    @Published private(set) var previewPlatforms = Set<AgentPlatform>()
    @Published var preview: IntegrationPreview?
    @Published var uninstallPreview: UninstallPreview?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var noticeIsWarning = false
    @Published var showRestoreConfirmation = false
    @Published var claudeConnectionPresentation: ClaudeConnectionPresentation?
    var showsClaudeConnection: Bool { claudeConnectionPresentation != nil }
    @Published private(set) var claudeConnection: StandMixerClaudeConnectionReport?
    @Published private(set) var claudeConnectionActivity: ClaudeConnectionActivity?
    @Published private(set) var claudeConnectionError: String?
    @Published private(set) var claudeConnectionWasAutomatic = false
    private var claudePromptSuppressed = false
    // Confirmation belongs to this open/choice, never to the app's lifetime.
    private var claudeConnectionIntent = 0
    private var confirmedClaudeConnectionIntent: Int?
    private var needsOpeningClaudeCheck = true
    private var savedOpeningConfiguration: StandMixerConfiguration?
    private var usesOpeningClaudeRequirement = true
    private var openingRequiresClaude = false
    private var checkingClaudeQuietly = false
    private var claudePreviewConfiguration: StandMixerConfiguration?
    // Retain the identity after SwiftUI clears its binding, until that sheet's
    // onDisappear finishes cleanup. A newer check/presentation invalidates it.
    private var activeClaudeConnectionPresentationID: UUID?

    enum ClaudeConnectionActivity { case checking, connecting }
    struct ClaudeConnectionPresentation: Identifiable { let id = UUID() }
    let currentSettings: CurrentSettingsController

    private let service: IntegrationService
    private let claudeConnectionService: StandMixerClaudeConnectionService
    private var claudeConnectionTask: Task<Void, Never>?
    private var pendingClaudeConnectionTasks: [Int: Task<Void, Never>] = [:]
    private var claudeConnectionGeneration = 0
    private(set) var isTerminating = false
    private let isSnapshot = ProcessInfo.processInfo.arguments.contains("--snapshot")
    private var needsInitialPreset = true
    private var previewGeneration = 0
    private var preferredPresetKey: String?
    private var previousDraft: StandMixerConfiguration?
    private var draftNeedsPreserving = false
    private var noticeTask: Task<Void, Never>?
    private var lastDetection: Set<AgentPlatform>?
    private static let maximumDraftHistory = 50
    private struct DraftSnapshot {
        var configuration: StandMixerConfiguration
        var selectedPlatform: AgentPlatform
        var preferredPresetKey: String?
    }
    private var undoHistory: [DraftSnapshot] = []
    private var redoHistory: [DraftSnapshot] = []
    private struct EditSnapshot {
        var configuration: StandMixerConfiguration
        var selectedPlatform: AgentPlatform
        var preferredPresetKey: String?
        var previousDraft: StandMixerConfiguration?
        var draftNeedsPreserving: Bool
        var needsInitialPreset: Bool
        var saveStatus: String
        var errorMessage: String?
        var undoHistory: [DraftSnapshot]
        var redoHistory: [DraftSnapshot]
    }
    private var editSnapshot: EditSnapshot?

    init(service: IntegrationService = IntegrationService(executableURL: Bundle.main.executableURL)) {
        self.service = service
        claudeConnectionService = StandMixerClaudeConnectionService(service: service)
        currentSettings = CurrentSettingsController(service: service)
        if !isSnapshot {
            do {
                let loaded = try service.loadConfiguration()
                savedPresets = try service.loadSavedPresets()
                let preserved = try service.loadPreviousDraft()
                let hasDraft = FileManager.default.fileExists(atPath: service.applicationSupport.appendingPathComponent("configuration.json").path)
                // Launch is always a fresh Optimized proposal. Retain the actual saved draft,
                // custom model catalogue, and enabled tools without writing during launch.
                configuration.customModels = loaded.customModels
                configuration.enabledPlatforms = loaded.enabledPlatforms
                previousDraft = hasDraft ? loaded : preserved
                savedOpeningConfiguration = hasDraft ? loaded : nil
                draftNeedsPreserving = hasDraft && loaded != preserved
                if !service.configurationRecoveryNotes.isEmpty {
                    notice = service.configurationRecoveryNotes.joined(separator: " ")
                    noticeIsWarning = true
                }
            } catch { errorMessage = error.localizedDescription }
        }
        discoveredModels = service.discoveredModels()
        canRestore = service.canRestore
        refreshInstallationStatus()
    }

    var profile: RoutingProfile { configuration.profile(for: selectedPlatform) ?? StandMixerConfiguration.defaults.profile(for: selectedPlatform)! }
    var installedPlatforms: Set<AgentPlatform> { Set(connections.filter(\.isInstalled).map(\.platform)) }
    var enabledPlatforms: Set<AgentPlatform> { installedPlatforms.intersection(configuration.enabledPlatforms ?? installedPlatforms) }
    var modelPlatforms: Set<AgentPlatform> { enabledPlatforms.isEmpty ? Set(AgentPlatform.allCases) : enabledPlatforms }
    var canPreview: Bool { !isEditing && !enabledPlatforms.isEmpty && !isChecking && !isPreparingUninstall && !isUninstalling && uninstallPreview == nil }
    var hasPreviousDraft: Bool { previousDraft != nil }
    var hasDraftUndoHistory: Bool { !undoHistory.isEmpty }
    var canUndoDraft: Bool { canChangeDraftHistory && !undoHistory.isEmpty }
    var canRedoDraft: Bool { canChangeDraftHistory && !redoHistory.isEmpty }
    private var canChangeDraftHistory: Bool { !isApplying && !isUninstalling && !isPreparingUninstall && uninstallPreview == nil }
    var availableModels: [ModelSpec] {
        ModelSpec.catalog(discovered: discoveredModels, custom: configuration.customModels)
    }
    var presetKey: String {
        if let preferredPresetKey, let candidate = presetConfiguration(preferredPresetKey), matches(candidate) { return preferredPresetKey }
        for preset in StandMixerPreset.allCases {
            if matches(.preset(preset, availablePlatforms: modelPlatforms)) { return preset.rawValue }
        }
        for saved in savedPresets.reversed() where matches(saved.configuration) { return saved.id.uuidString }
        return "custom"
    }
    var presetName: String {
        if let preset = StandMixerPreset(rawValue: presetKey) { return preset.title }
        if presetKey == "previous-draft" { return "Previous draft" }
        return savedPresets.first { $0.id.uuidString == presetKey }?.name ?? "Custom"
    }
    var installationLabel: String {
        guard let status = installationStatus else { return "Status unavailable" }
        switch status.state {
        case .notInstalled: return "Not applied"
        case .applied:
            guard let applied = status.appliedConfiguration else { return "No preset applied" }
            let matchesApplied = status.installedPlatforms == enabledPlatforms
                && enabledPlatforms.allSatisfy { Self.sameProfile(configuration.profile(for: $0), applied.profile(for: $0)) }
            return matchesApplied ? "Applied" : "Unapplied changes"
        case .drifted: return "Changed since apply"
        case .unknown: return "Existing setup"
        }
    }
    var installationDetail: String {
        guard let status = installationStatus else { return "StandMixer couldn’t read its installation status. Refresh connections to try again." }
        return ([status.summary] + (status.appliedConfiguration == nil ? [] : ["Applied preset: " + appliedPresetName]) + status.details).joined(separator: "\n")
    }
    private var appliedPresetName: String {
        guard let status = installationStatus, let applied = status.appliedConfiguration else { return "Custom" }
        if let preset = StandMixerCommandInterface.matchingPreset(applied, platforms: status.installedPlatforms) {
            return preset.rawValue.capitalized
        }
        func sameProfiles(_ other: StandMixerConfiguration) -> Bool {
            !status.installedPlatforms.isEmpty && status.installedPlatforms.allSatisfy {
                Self.sameProfile(applied.profile(for: $0), other.profile(for: $0))
            }
        }
        return savedPresets.reversed().first { sameProfiles($0.configuration) }?.name ?? "Custom"
    }

    func connection(for platform: AgentPlatform) -> ConnectionStatus? { connections.first { $0.platform == platform } }
    func integrationPlatform(for path: String) -> AgentPlatform {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(service.claudeHome.standardizedFileURL.path + "/") ? .claude : .codex
    }
    func model(_ id: String) -> ModelSpec? { availableModels.first { $0.id == id } }
    func modelName(_ id: String) -> String { id == Route.autoControllerModelID ? "Auto" : model(id)?.label ?? id }
    func routedModelName(_ id: String, in platform: AgentPlatform, reportedPlatform: AgentPlatform? = nil) -> String {
        let name = modelName(id)
        guard let provider = model(id)?.platform ?? reportedPlatform, provider != platform else { return name }
        return name + " · via " + provider.displayName
    }
    /// An applied policy is distinct from the saved native model observed on disk.
    func appliedRoute(_ category: WorkCategory, in platform: AgentPlatform) -> Route? {
        guard let status = installationStatus, status.state == .applied, status.installedPlatforms.contains(platform) else { return nil }
        return status.appliedConfiguration?.profile(for: platform)?.effectiveRoute(for: category)
    }
    func appliedController(in platform: AgentPlatform) -> ImportedRoute? {
        guard let status = installationStatus, status.state == .applied, status.installedPlatforms.contains(platform),
              let route = status.appliedConfiguration?.profile(for: platform)?.route(for: .coordinator) else { return nil }
        return ImportedRoute(category: .coordinator, modelID: route.modelID, modelPlatform: platform, effort: route.effort,
            evidence: [.init(path: "StandMixer installation record", explanation: "Verified controller policy; the current chat model may differ from saved native defaults.")],
            additionalAgents: [], resultMode: .coordinator)
    }
    func route(_ category: WorkCategory) -> Route { route(category, in: selectedPlatform) }
    func editBaselineRoute(_ category: WorkCategory, in platform: AgentPlatform) -> Route? {
        guard isEditing else { return nil }
        return editSnapshot?.configuration.profile(for: platform)?.effectiveRoute(for: category)
    }


    func previousEscalation(_ category: WorkCategory, in platform: AgentPlatform) -> [AgentAssignment]? {
        if isEditing { return editBaselineRoute(category, in: platform)?.stuckEscalation }
        return appliedRoute(category, in: platform)?.stuckEscalation
    }
    func hasEscalationChanges(_ category: WorkCategory, in platform: AgentPlatform) -> Bool {
        guard let previous = previousEscalation(category, in: platform) else { return false }
        return !Self.sameAssignments(previous, route(category, in: platform).stuckEscalation)
    }
    private static func sameAssignments(_ lhs: [AgentAssignment], _ rhs: [AgentAssignment]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.modelID == pair.1.modelID && pair.0.modelPlatform == pair.1.modelPlatform && pair.0.effort.semanticallyMatches(pair.1.effort)
        }
    }

    func inheritanceChanges(_ category: WorkCategory, in platform: AgentPlatform) -> [String] {
        guard category.parent != nil, isEditing,
              let baseline = editSnapshot?.configuration.profile(for: platform)?.route(for: category) else { return [] }
        let current = storedRoute(category, in: platform)
        let fields: [(String, Bool, Bool)] = [
            ("Model", baseline.inheritsModel, current.inheritsModel),
            ("Effort", baseline.inheritsEffort, current.inheritsEffort),
            ("Team", baseline.inheritsTeam, current.inheritsTeam)
        ]
        return fields.compactMap { name, before, after in
            before == after ? nil : name + (after ? ": use parent" : ": custom")
        }
    }

    // Authentication is optional and starts only from the explicit connection dialog.
    func openClaudeConnection() {
        guard !isTerminating, !showsClaudeConnection else { return }
        cancelClaudeConnection()
        rearmAutomaticClaudeConnection()
        claudeConnectionWasAutomatic = false
        presentClaudeConnection()
        checkClaudeConnection()
    }

    func checkClaudeConnection() { runClaudeConnection(connect: false) }

    func connectClaude() {
        guard claudeConnection?.state == .signInRequired else { return }
        runClaudeConnection(connect: true)
    }

    func dismissClaudeConnection(presentationID: UUID) {
        guard activeClaudeConnectionPresentationID == presentationID else { return }
        let resume = claudePreviewConfiguration == configuration
        if claudeConnection?.state != .connected { claudePromptSuppressed = true }
        cancelClaudeConnection()
        if resume && !isTerminating { preparePreview(skipClaudeCheck: true) }
    }

    private func presentClaudeConnection() {
        let presentation = ClaudeConnectionPresentation()
        activeClaudeConnectionPresentationID = presentation.id
        claudeConnectionPresentation = presentation
    }

    func cancelClaudeConnection() {
        activeClaudeConnectionPresentationID = nil
        claudePreviewConfiguration = nil
        checkingClaudeQuietly = false
        claudeConnectionGeneration += 1
        claudeConnectionTask?.cancel()
        claudeConnectionTask = nil
        claudeConnectionActivity = nil
        claudeConnection = nil
        claudeConnectionError = nil
        claudeConnectionPresentation = nil
        claudeConnectionWasAutomatic = false
    }

    var hasPendingClaudeConnectionCleanup: Bool { !pendingClaudeConnectionTasks.isEmpty }

    func beginTermination() {
        isTerminating = true
        cancelClaudeConnection()
        for task in pendingClaudeConnectionTasks.values { task.cancel() }
    }

    func waitForClaudeConnectionCleanup() async {
        // Dismissing the dialog cancels immediately but retains ownership until the
        // core has killed and reaped its process group, including resistant children.
        let pending = Array(pendingClaudeConnectionTasks.values)
        for task in pending { await task.value }
    }

    @discardableResult
    private func offerClaudeConnection(beforePreview: Bool = false) -> Bool {
        guard !isSnapshot, !isTerminating, !claudePromptSuppressed,
              confirmedClaudeConnectionIntent != claudeConnectionIntent,
              requiresClaudeConnection else { return false }
        if claudeConnectionTask != nil {
            if checkingClaudeQuietly && beforePreview { claudePreviewConfiguration = configuration }
            return checkingClaudeQuietly || showsClaudeConnection
        }
        guard !showsClaudeConnection, preview == nil, uninstallPreview == nil else { return false }
        if beforePreview { claudePreviewConfiguration = configuration }
        runClaudeConnection(connect: false, quietly: true)
        return true
    }

    private var requiresClaudeConnection: Bool {
        guard configuration.enabledPlatforms?.contains(.codex) != false,
              configuration.enabledPlatforms?.contains(.claude) != false,
              !hasDetectedConnections || installedPlatforms.contains(.codex) else { return false }
        return openingRequiresClaude || !ClaudeConnectionTrigger.usage(in: configuration, catalog: availableModels).isEmpty
    }

    private func rearmAutomaticClaudeConnection() {
        claudeConnectionIntent += 1
        claudePromptSuppressed = false
        if checkingClaudeQuietly { cancelClaudeConnection() }
    }

    private func runClaudeConnection(connect: Bool, quietly: Bool = false) {
        guard !isTerminating, (showsClaudeConnection || quietly), claudeConnectionTask == nil else { return }
        if quietly { activeClaudeConnectionPresentationID = nil }
        claudeConnectionGeneration += 1
        let generation = claudeConnectionGeneration
        let intent = claudeConnectionIntent
        checkingClaudeQuietly = quietly
        claudeConnectionActivity = quietly ? nil : connect ? .connecting : .checking
        claudeConnection = nil
        claudeConnectionError = nil
        let task = Task { [weak self, claudeConnectionService] in
            defer { self?.pendingClaudeConnectionTasks.removeValue(forKey: generation) }
            do {
                let report = try await (connect ? claudeConnectionService.connect() : claudeConnectionService.check())
                guard let self, !Task.isCancelled, self.claudeConnectionGeneration == generation else { return }
                self.claudeConnection = report
                if report.state == .connected {
                    self.confirmedClaudeConnectionIntent = intent
                    self.claudePromptSuppressed = false
                }
                if quietly && report.state != .connected && self.requiresClaudeConnection && !self.claudePromptSuppressed {
                    self.claudeConnectionWasAutomatic = true
                    self.presentClaudeConnection()
                }
            } catch {
                guard let self, !Task.isCancelled, self.claudeConnectionGeneration == generation else { return }
                self.claudeConnectionError = error.localizedDescription
                if quietly && self.requiresClaudeConnection && !self.claudePromptSuppressed {
                    self.claudeConnectionWasAutomatic = true
                    self.presentClaudeConnection()
                }
            }
            guard let self, self.claudeConnectionGeneration == generation else { return }
            self.checkingClaudeQuietly = false
            self.claudeConnectionActivity = nil
            self.claudeConnectionTask = nil
            if quietly && !self.showsClaudeConnection {
                let resume = self.claudePreviewConfiguration == self.configuration
                self.claudePreviewConfiguration = nil
                if resume { self.preparePreview(skipClaudeCheck: true) }
            }
        }
        claudeConnectionTask = task
        pendingClaudeConnectionTasks[generation] = task
    }

    func refreshConnections() async {
        guard !isChecking else { return }
        isChecking = true
        currentSettings.invalidateReports()
        connections = await service.detect()
        if isSnapshot, let only = snapshotArgument("--only"), let platform = AgentPlatform(rawValue: only) {
            connections = connections.map { status in
                status.platform == platform ? status : ConnectionStatus(platform: status.platform, path: nil, version: nil, detail: "Snapshot-only unavailable tool", isInstalled: false)
            }
        }
        discoveredModels = service.discoveredModels()
        hasDetectedConnections = true
        isChecking = false
        canRestore = service.canRestore
        refreshInstallationStatus()
        if needsInitialPreset {
            var proposal = StandMixerConfiguration.preset(.optimized, availablePlatforms: modelPlatforms)
            proposal.customModels = configuration.customModels
            proposal.enabledPlatforms = configuration.enabledPlatforms
            configuration = proposal
            preferredPresetKey = StandMixerPreset.optimized.rawValue
            needsInitialPreset = false
        }
        if !enabledPlatforms.contains(selectedPlatform), let first = AgentPlatform.allCases.first(where: enabledPlatforms.contains) { selectedPlatform = first }
        if lastDetection != installedPlatforms {
            if installedPlatforms.count == 1, let only = installedPlatforms.first { showNotice("Only detected \(only.displayName).", warning: true) }
            else if installedPlatforms.isEmpty { showNotice("No local agent tool detected.", warning: true) }
            lastDetection = installedPlatforms
        }
        if isSnapshot { configureSnapshot() }
        Self.didFinishDiscovery = true
        if needsOpeningClaudeCheck {
            needsOpeningClaudeCheck = false
            if usesOpeningClaudeRequirement {
                openingRequiresClaude = ClaudeConnectionTrigger.requiredOnOpen(configuration: configuration,
                    savedConfiguration: savedOpeningConfiguration, installation: installationStatus, catalog: availableModels)
            }
            offerClaudeConnection()
        }
        if isSnapshot && ProcessInfo.processInfo.arguments.contains("--preview") { preparePreview() }
        if isSnapshot && ProcessInfo.processInfo.arguments.contains("--uninstall") { prepareUninstall() }
    }

    /// Edit is a local transaction. Existing review tokens never survive a
    /// transaction boundary, even when Cancel returns to identical settings.
    func beginEditing() {
        guard !isEditing, !isApplying, !isUninstalling, !isPreparingUninstall else { return }
        editSnapshot = .init(configuration: configuration, selectedPlatform: selectedPlatform,
            preferredPresetKey: preferredPresetKey, previousDraft: previousDraft,
            draftNeedsPreserving: draftNeedsPreserving, needsInitialPreset: needsInitialPreset,
            saveStatus: saveStatus, errorMessage: errorMessage,
            undoHistory: undoHistory, redoHistory: redoHistory)
        invalidateEditingPreview()
        // A late initial discovery must not replace an in-memory edit proposal.
        needsInitialPreset = false
        isEditing = true
        saveStatus = "Editing"
    }

    @discardableResult
    func saveEditing() -> Bool {
        guard isEditing, editSnapshot != nil else { return false }
        do {
            try validateDraft(configuration)
            if !isSnapshot { try writeDraft(configuration) }
            invalidateEditingPreview()
            editSnapshot = nil
            isEditing = false
            saveStatus = "Saved"
            errorMessage = nil
            return true
        } catch {
            // Keep both the staged configuration and its Cancel snapshot. A
            // failed Save never becomes a successful exit from edit mode.
            saveStatus = "Couldn’t save"
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelEditing() {
        guard isEditing, let snapshot = editSnapshot else { return }
        invalidateEditingPreview()
        configuration = snapshot.configuration
        selectedPlatform = snapshot.selectedPlatform
        preferredPresetKey = snapshot.preferredPresetKey
        previousDraft = snapshot.previousDraft
        draftNeedsPreserving = snapshot.draftNeedsPreserving
        needsInitialPreset = snapshot.needsInitialPreset
        saveStatus = snapshot.saveStatus
        errorMessage = snapshot.errorMessage
        undoHistory = snapshot.undoHistory
        redoHistory = snapshot.redoHistory
        editSnapshot = nil
        isEditing = false
    }

    func undoDraft() { moveDraftHistory(undo: true) }
    func redoDraft() { moveDraftHistory(undo: false) }

    private var draftSnapshot: DraftSnapshot {
        .init(configuration: configuration, selectedPlatform: selectedPlatform, preferredPresetKey: preferredPresetKey)
    }

    private func moveDraftHistory(undo: Bool) {
        guard undo ? canUndoDraft : canRedoDraft,
              let target = undo ? undoHistory.last : redoHistory.last else { return }
        let current = draftSnapshot
        guard persist(target.configuration, recordHistory: false) else { return }
        if undo {
            undoHistory.removeLast()
            Self.appendHistory(current, to: &redoHistory)
        } else {
            redoHistory.removeLast()
            Self.appendHistory(current, to: &undoHistory)
        }
        selectedPlatform = target.selectedPlatform
        preferredPresetKey = target.preferredPresetKey
        objectWillChange.send()
    }

    private static func appendHistory(_ snapshot: DraftSnapshot, to history: inout [DraftSnapshot]) {
        history.append(snapshot)
        if history.count > maximumDraftHistory { history.removeFirst(history.count - maximumDraftHistory) }
    }

    private func clearDraftHistory() {
        undoHistory.removeAll()
        redoHistory.removeAll()
        objectWillChange.send()
    }

    private func invalidateEditingPreview() {
        cancelPreparingPreview()
        preview = nil
        previewPlatforms = []
        uninstallPreview = nil
    }

    func setPlatformEnabled(_ platform: AgentPlatform, enabled: Bool) {
        guard installedPlatforms.contains(platform) else { return }
        let activePreset = StandMixerPreset(rawValue: presetKey)
        var chosen = enabledPlatforms
        if enabled { chosen.insert(platform) } else { chosen.remove(platform) }
        var next = configuration
        next.enabledPlatforms = chosen
        if let activePreset, !chosen.isEmpty {
            let adapted = StandMixerConfiguration.preset(activePreset, availablePlatforms: chosen)
            for index in next.profiles.indices where chosen.contains(next.profiles[index].platform) {
                next.profiles[index] = adapted.profile(for: next.profiles[index].platform)!
            }
        }
        guard persist(next) else { return }
        if !chosen.contains(selectedPlatform), let first = AgentPlatform.allCases.first(where: chosen.contains) { selectedPlatform = first }
        currentSettings.invalidateReports(platforms: [platform])
    }

    func selectPreset(_ key: String) {
        guard let replacement = presetConfiguration(key) else { return }
        var next = configuration
        for index in next.profiles.indices where modelPlatforms.contains(next.profiles[index].platform) {
            if let profile = replacement.profile(for: next.profiles[index].platform) { next.profiles[index] = profile }
        }
        for model in replacement.customModels {
            next.customModels.removeAll { $0.id == model.id }
            next.customModels.append(model)
        }
        if persist(next, forceClaudeCheck: true) {
            preferredPresetKey = key
            objectWillChange.send()
        }
    }

    func saveCurrentPreset(name: String) throws {
        guard !isEditing else { throw StandMixerError.invalid("Save or cancel edits before saving a named preset.") }
        let saved: SavedRoutingPreset
        if isSnapshot { saved = SavedRoutingPreset(name: name, configuration: configuration) }
        else { saved = try service.savePreset(name: name, configuration: configuration) }
        savedPresets.removeAll { $0.id == saved.id }
        savedPresets.append(saved)
        preferredPresetKey = saved.id.uuidString
        objectWillChange.send()
    }

    func deleteSavedPreset(id: UUID) {
        guard !isEditing else { errorMessage = "Save or cancel edits before deleting a named preset."; return }
        guard savedPresets.contains(where: { $0.id == id }) else { return }
        do {
            if !isSnapshot { try service.deletePreset(id: id) }
            savedPresets.removeAll { $0.id == id }
            if preferredPresetKey == id.uuidString { preferredPresetKey = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    func updateRoute(_ category: WorkCategory, forceClaudeCheck: Bool = false, _ update: (inout Route) -> Void) {
        var next = configuration
        guard let profileIndex = next.profiles.firstIndex(where: { $0.platform == selectedPlatform }),
              let routeIndex = next.profiles[profileIndex].routes.firstIndex(where: { $0.category == category }) else { return }
        let effective = route(category)
        var editable = next.profiles[profileIndex].routes[routeIndex]
        // A newly customized field starts from what the person can currently see.
        if editable.inheritsModel { editable.modelID = effective.modelID }
        if editable.inheritsEffort { editable.effort = effective.effort }
        if editable.inheritsTeam {
            editable.additionalAgents = effective.additionalAgents
            editable.teamMode = effective.teamMode
            editable.resultMode = effective.resultMode
            editable.judgeModelID = effective.judgeModelID
        }
        let before = editable
        update(&editable)
        if editable.modelID != before.modelID { editable.inheritsModel = false }
        if editable.effort != before.effort { editable.inheritsEffort = false }
        if editable.additionalAgents != before.additionalAgents || editable.teamMode != before.teamMode
            || editable.resultMode != before.resultMode || editable.judgeModelID != before.judgeModelID {
            editable.inheritsTeam = false
        }
        next.profiles[profileIndex].routes[routeIndex] = editable
        persist(next, forceClaudeCheck: forceClaudeCheck)
    }

    func setModel(_ id: String, for category: WorkCategory, agentIndex: Int = 0) {
        updateRoute(category, forceClaudeCheck: selectedPlatform == .codex && model(id)?.platform == .claude) { route in
            if agentIndex == 0 {
                route.inheritsModel = false
                route.modelID = id
                if !route.inheritsEffort { route.effort = route.isAutoController ? .auto : normalized(route.effort, for: id) }
            } else if route.additionalAgents.indices.contains(agentIndex - 1) {
                route.inheritsTeam = false
                route.additionalAgents[agentIndex - 1].modelID = id
                route.additionalAgents[agentIndex - 1].modelPlatform = model(id)?.platform
                route.additionalAgents[agentIndex - 1].effort = normalized(route.additionalAgents[agentIndex - 1].effort, for: id)
            }
        }
    }

    func effortBinding(for category: WorkCategory, agentIndex: Int = 0) -> Binding<EffortPolicy> {
        Binding(get: {
            let route = self.route(category)
            return agentIndex == 0 ? route.effort : route.additionalAgents.indices.contains(agentIndex - 1) ? route.additionalAgents[agentIndex - 1].effort : .auto
        }, set: { value in
            self.updateRoute(category) {
                if agentIndex == 0 { $0.inheritsEffort = false; $0.effort = $0.isAutoController ? .auto : value }
                else if $0.additionalAgents.indices.contains(agentIndex - 1) { $0.inheritsTeam = false; $0.additionalAgents[agentIndex - 1].effort = value }
            }
        })
    }

    func setAgentCount(_ count: Int, for category: WorkCategory) {
        guard category != .coordinator else { return }
        let requested = min(4, max(1, count)) - 1
        guard requested != route(category).additionalAgents.count else { return }
        updateRoute(category) { route in
            while route.additionalAgents.count < requested {
                route.additionalAgents.append(.init(modelID: route.modelID, effort: route.effort, modelPlatform: model(route.modelID)?.platform))
            }
            if route.additionalAgents.count > requested { route.additionalAgents.removeLast(route.additionalAgents.count - requested) }
            if requested == 0 { route.resultMode = .coordinator; route.judgeModelID = nil }
        }
    }

    func setResultMode(_ mode: RouteResultMode, for category: WorkCategory) {
        let defaultJudge = route(.coordinator).isAutoController ? route(category).modelID : route(.coordinator).modelID
        updateRoute(category) {
            $0.resultMode = mode
            if mode == .ai && $0.judgeModelID == nil { $0.judgeModelID = defaultJudge }
        }
    }

    func addCustomModel(_ model: ModelSpec) {
        var next = configuration
        next.customModels.removeAll { $0.id == model.id }
        next.customModels.append(model)
        persist(next)
    }

    static func needsClaudeCheckBeforePreview(configuration: StandMixerConfiguration,
                                              installation: InstallationStatus?, catalog: [ModelSpec]) -> Bool {
        guard !ClaudeConnectionTrigger.usage(in: configuration, catalog: catalog).isEmpty else { return false }
        guard let installation, installation.installedPlatforms.contains(.codex),
              let baseline = installation.appliedConfiguration?.profile(for: .codex) else { return true }
        return !sameProfile(configuration.profile(for: .codex), baseline)
    }

    func preparePreview(skipClaudeCheck: Bool = false) {
        guard !isEditing else { showNotice("Save or cancel edits before reviewing changes.", warning: true); return }
        guard !isPreparingPreview, !isPreparingUninstall, !isUninstalling, uninstallPreview == nil else { return }
        let platforms = enabledPlatforms
        guard !platforms.isEmpty else { showNotice("Enable an installed tool first.", warning: true); Self.didFinishSnapshotPreview = true; return }
        for profile in configuration.profiles where platforms.contains(profile.platform) {
            for route in profile.effectiveRoutes {
                let ids = [route.modelID] + route.additionalAgents.map(\.modelID) + route.stuckEscalation.map(\.modelID) + (route.resultMode == .ai ? [route.judgeModelID].compactMap { $0 } : [])
                if let unavailable = ids.compactMap({ model($0)?.platform }).first(where: { !platforms.contains($0) }) {
                    errorMessage = "\(profile.platform.displayName) → \(route.category.title) uses \(unavailable.displayName), which is not enabled. Enable it or change this assignment."
                    Self.didFinishSnapshotPreview = true
                    return
                }
            }
        }
        if !skipClaudeCheck && Self.needsClaudeCheckBeforePreview(configuration: configuration,
            installation: installationStatus, catalog: availableModels) && offerClaudeConnection(beforePreview: true) { return }
        isPreparingPreview = true
        previewGeneration += 1
        let generation = previewGeneration
        let requested = configuration
        let service = service
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try service.preview(configuration: requested, platforms: platforms) } }.value
            guard generation == previewGeneration else { return }
            isPreparingPreview = false
            guard requested == configuration && platforms == enabledPlatforms else {
                showNotice("Settings changed. Prepare a new preview.")
                Self.didFinishSnapshotPreview = true
                return
            }
            switch result {
            case .success(let prepared): previewPlatforms = platforms; preview = prepared
            case .failure(let error): errorMessage = error.localizedDescription
            }
            Self.didFinishSnapshotPreview = true
        }
    }

    func cancelPreparingPreview() { previewGeneration += 1; isPreparingPreview = false }
    func applyPreview() {
        guard !isEditing else { errorMessage = "Save or cancel edits before applying changes."; return }
        guard !isSnapshot, let preview, !isApplying, !previewPlatforms.isEmpty else { return }
        guard previewPlatforms.isSubset(of: enabledPlatforms) else { errorMessage = "Tool availability changed. Prepare a new preview."; return }
        isApplying = true
        defer { isApplying = false }
        do {
            let result = try service.apply(preview: preview)
            clearDraftHistory()
            self.preview = nil
            canRestore = service.canRestore
            refreshInstallationStatus()
            showNotice(result.message)
            currentSettings.invalidateReports()
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreLast() {
        guard !isEditing else { errorMessage = "Save or cancel edits before restoring settings."; return }
        guard !isSnapshot else { return }
        do {
            let result = try service.restoreLast()
            clearDraftHistory()
            invalidateEditingPreview()
            canRestore = service.canRestore
            refreshInstallationStatus()
            showNotice(result.message)
            currentSettings.invalidateReports()
        } catch { errorMessage = error.localizedDescription }
    }

    func prepareUninstall() {
        guard !isEditing else { showNotice("Save or cancel edits before reviewing removal.", warning: true); return }
        guard !isPreparingUninstall, !isApplying, !isUninstalling else { return }
        cancelPreparingPreview()
        preview = nil
        previewPlatforms = []
        if isSnapshot, ProcessInfo.processInfo.arguments.contains("--uninstall-demo") {
            uninstallPreview = snapshotUninstallPreview()
            Self.didFinishSnapshotUninstall = true
            return
        }
        isPreparingUninstall = true
        let service = service
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try service.previewUninstall() } }.value
            isPreparingUninstall = false
            switch result {
            case .success(let prepared): uninstallPreview = prepared
            case .failure(let error): errorMessage = error.localizedDescription
            }
            Self.didFinishSnapshotUninstall = true
        }
    }

    func uninstall() {
        guard !isEditing else { errorMessage = "Save or cancel edits before removing settings."; return }
        guard !isSnapshot, let uninstallPreview, !isApplying, !isUninstalling else { return }
        isUninstalling = true
        defer { isUninstalling = false }
        do {
            let result = try service.uninstall(preview: uninstallPreview)
            clearDraftHistory()
            self.uninstallPreview = nil
            preview = nil
            previewPlatforms = []
            currentSettings.clearReports()
            canRestore = service.canRestore
            refreshInstallationStatus()
            showNotice(result.message, warning: installationStatus?.hasInstallation == true)
        } catch {
            refreshInstallationStatus()
            errorMessage = error.localizedDescription
        }
    }

    private func refreshInstallationStatus() {
        installationStatus = try? service.installationStatus()
    }

    private func snapshotUninstallPreview() -> UninstallPreview {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let changes = [
            FileChange(path: home + "/.codex/config.toml",
                       before: "model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"medium\"\n",
                       after: "model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"low\"\n",
                       reason: "Restore the defaults from before the first apply."),
            FileChange(path: home + "/.codex/agents/standmixer-worker.toml",
                       before: "name = \"standmixer-worker\"\nmodel = \"gpt-6.1-sol\"\n",
                       after: "", reason: "Remove an unchanged StandMixer worker.", isDeletion: true),
            FileChange(path: home + "/.claude/skills/standmixer/SKILL.md",
                       before: "Open StandMixer to choose a preset or uninstall.\n",
                       after: "", reason: "Remove the StandMixer command.", isDeletion: true)
        ]
        let conflicts = ProcessInfo.processInfo.arguments.contains("--uninstall-conflicts")
            ? ["~/.claude/settings.json: model was edited after StandMixer applied. Your current value will be kept."] : []
        return UninstallPreview(changes: changes, conflicts: conflicts, hasInstallation: true)
    }

    func showNotice(_ message: String, warning: Bool = false) {
        noticeTask?.cancel()
        noticeIsWarning = warning
        notice = message
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            self?.notice = nil
        }
    }

    @discardableResult
    private func persist(_ next: StandMixerConfiguration, recordHistory: Bool = true, forceClaudeCheck: Bool = false) -> Bool {
        let changed = next != configuration
        let introducedClaude = ClaudeConnectionTrigger.introducesClaude(before: configuration, after: next,
            catalog: ModelSpec.catalog(discovered: discoveredModels, custom: next.customModels))
        let reenabledProvider = AgentPlatform.allCases.contains {
            configuration.enabledPlatforms?.contains($0) == false && next.enabledPlatforms?.contains($0) != false
        }
        do {
            try validateDraft(next)
            if !isEditing && !isSnapshot { try writeDraft(next) }
            if changed && recordHistory {
                Self.appendHistory(draftSnapshot, to: &undoHistory)
                redoHistory.removeAll()
            }
            if changed {
                invalidateEditingPreview()
                usesOpeningClaudeRequirement = false
                openingRequiresClaude = false
            }
            configuration = next
            if !requiresClaudeConnection {
                confirmedClaudeConnectionIntent = nil
                if checkingClaudeQuietly || claudeConnectionWasAutomatic { cancelClaudeConnection() }
            }
            if introducedClaude || reenabledProvider || forceClaudeCheck {
                rearmAutomaticClaudeConnection()
                offerClaudeConnection()
            }
            saveStatus = isEditing ? (editSnapshot?.configuration == next ? "Editing" : "Unsaved changes") : "Saved"
            errorMessage = nil
            return true
        } catch {
            saveStatus = "Couldn’t save"
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func validateDraft(_ draft: StandMixerConfiguration) throws {
        try draft.validateNativeCoordinators(catalog: ModelSpec.catalog(discovered: discoveredModels, custom: draft.customModels))
    }

    /// The configuration file is written once per explicit Save. Preserve the
    /// launch baseline before that write, without changing bookkeeping on error.
    private func writeDraft(_ draft: StandMixerConfiguration) throws {
        if draftNeedsPreserving, let previousDraft { try service.savePreviousDraft(previousDraft) }
        try service.saveConfiguration(draft)
        draftNeedsPreserving = false
    }

    private func normalized(_ effort: EffortPolicy, for id: String) -> EffortPolicy {
        guard let model = model(id) else { return effort }
        if effort.mode == .fixed && !model.supportedEfforts.contains(effort.value) { return .auto }
        if effort.mode == .range && (!model.supportedEfforts.contains(effort.minimum) || !model.supportedEfforts.contains(effort.maximum)) { return .auto }
        return effort
    }

    private func presetConfiguration(_ key: String) -> StandMixerConfiguration? {
        if let preset = StandMixerPreset(rawValue: key) { return .preset(preset, availablePlatforms: modelPlatforms) }
        if key == "previous-draft" { return previousDraft }
        return savedPresets.first { $0.id.uuidString == key }?.configuration
    }
    private func matches(_ other: StandMixerConfiguration) -> Bool {
        modelPlatforms.allSatisfy { Self.sameProfile(configuration.profile(for: $0), other.profile(for: $0)) }
    }
    private static func sameProfile(_ lhs: RoutingProfile?, _ rhs: RoutingProfile?) -> Bool {
        guard let lhs, let rhs else { return false }
        return WorkCategory.allCases.allSatisfy { category in
            guard let storedA = lhs.route(for: category), let storedB = rhs.route(for: category),
                  storedA.inheritsModel == storedB.inheritsModel,
                  storedA.inheritsEffort == storedB.inheritsEffort,
                  storedA.inheritsTeam == storedB.inheritsTeam,
                  let a = lhs.effectiveRoute(for: category), let b = rhs.effectiveRoute(for: category),
                  a.modelID == b.modelID, a.effort.semanticallyMatches(b.effort),
                  a.additionalAgents.count == b.additionalAgents.count,
                  Self.sameAssignments(a.stuckEscalation, b.stuckEscalation),
                  zip(a.additionalAgents, b.additionalAgents).allSatisfy({ pair in pair.0.modelID == pair.1.modelID && pair.0.effort.semanticallyMatches(pair.1.effort) }) else { return false }
            return a.additionalAgents.isEmpty || (a.teamMode == b.teamMode && a.resultMode == b.resultMode && (a.resultMode != .ai || a.judgeModelID == b.judgeModelID))
        }
    }
    private func snapshotArgument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
    private func configureSnapshot() {
        if let key = snapshotArgument("--preset"), StandMixerPreset(rawValue: key) != nil { selectPreset(key) }
        if let value = snapshotArgument("--profile"), let platform = AgentPlatform(rawValue: value), enabledPlatforms.contains(platform) { selectedPlatform = platform }
        if let categoryID = snapshotArgument("--effort"), let category = WorkCategory(rawValue: categoryID), snapshotArgument("--effort-mode") == "range" {
            let levels = model(route(category).modelID)?.supportedEfforts ?? EffortPolicy.levels
            updateRoute(category) { $0.effort = .range(minimum: levels.first ?? "low", maximum: levels.last ?? "high") }
        }
        if ProcessInfo.processInfo.arguments.contains("--current-demo") {
            currentSettings.loadSnapshotDemo(configuration: .preset(.fast, availablePlatforms: modelPlatforms), platforms: enabledPlatforms)
        }
    }
}
