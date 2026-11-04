import Darwin
import Foundation

/// Configuration-only integration. It never starts an inference run or opens account credentials.
public final class IntegrationService: @unchecked Sendable {
    public let home: URL
    public let applicationSupport: URL
    public let codexHome: URL
    public let claudeHome: URL
    public let executableURL: URL
    let environment: [String: String]
    let discoveryCache = ExecutableDiscoveryCache()
    let files = FileManager.default
    let lock = NSRecursiveLock()
    var operationLockDepth = 0
    var operationLockDescriptor: Int32 = -1
    let metadataOnlyDiscovery: Bool
    private var recoveryNotes: [String] = []
    public var configurationRecoveryNotes: [String] {
        lock.lock(); defer { lock.unlock() }
        return recoveryNotes
    }
    var receiptURL: URL { applicationSupport.appendingPathComponent("last-backup.json") }
    private var configurationURL: URL { applicationSupport.appendingPathComponent("configuration.json") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applicationSupport: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                executableURL: URL? = nil, metadataOnlyDiscovery: Bool = false) {
        self.home = home.standardizedFileURL
        self.applicationSupport = applicationSupport ?? home.appendingPathComponent("Library/Application Support/AgentMix", isDirectory: true)
        self.environment = environment
        self.metadataOnlyDiscovery = metadataOnlyDiscovery
        self.executableURL = executableURL ?? URL(fileURLWithPath: "/Applications/AgentMix.app/Contents/MacOS/AgentMix")
        self.codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex", isDirectory: true)
        self.claudeHome = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    public func loadConfiguration() throws -> AgentMixConfiguration {
        guard files.fileExists(atPath: configurationURL.path) else { return .defaults }
        return recoverNativeCoordinators(try JSONDecoder().decode(AgentMixConfiguration.self, from: Data(contentsOf: configurationURL)))
    }

    public func saveConfiguration(_ configuration: AgentMixConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        try configuration.validateNativeCoordinators(catalog: modelCatalog(configuration))
        try acquireOperationLock(); defer { releaseOperationLock() }
        try privateDirectory(applicationSupport)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(configuration), to: configurationURL, mode: 0o600)
    }

    public func loadPreviousDraft() throws -> AgentMixConfiguration? {
        let url = applicationSupport.appendingPathComponent("previous-draft.json")
        guard let text = try readText(url) else { return nil }
        return recoverNativeCoordinators(try JSONDecoder().decode(AgentMixConfiguration.self, from: Data(text.utf8)))
    }

    public func savePreviousDraft(_ configuration: AgentMixConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        try configuration.validateNativeCoordinators(catalog: modelCatalog(configuration))
        try acquireOperationLock(); defer { releaseOperationLock() }
        try privateDirectory(applicationSupport)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(configuration), to: applicationSupport.appendingPathComponent("previous-draft.json"), mode: 0o600)
    }

    public func loadSavedPresets() throws -> [SavedRoutingPreset] {
        let url = applicationSupport.appendingPathComponent("presets.json")
        guard let text = try readText(url) else { return [] }
        return try JSONDecoder().decode([SavedRoutingPreset].self, from: Data(text.utf8)).map { preset in
            var recovered = preset
            recovered.configuration = recoverNativeCoordinators(preset.configuration)
            return recovered
        }
    }

    @discardableResult public func savePreset(name: String, configuration: AgentMixConfiguration) throws -> SavedRoutingPreset {
        lock.lock(); defer { lock.unlock() }
        try configuration.validateNativeCoordinators(catalog: modelCatalog(configuration))
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else { throw AgentMixError.invalid("Use a preset name from 1 to 80 characters.") }
        try acquireOperationLock(); defer { releaseOperationLock() }
        var presets = try loadSavedPresets()
        let existing = presets.firstIndex { $0.name.caseInsensitiveCompare(title) == .orderedSame }
        let saved = SavedRoutingPreset(id: existing.map { presets[$0].id } ?? UUID(), name: title, configuration: configuration)
        if let existing { presets[existing] = saved } else { presets.append(saved) }
        try storePresets(presets)
        return saved
    }

    public func deletePreset(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try acquireOperationLock(); defer { releaseOperationLock() }
        var presets = try loadSavedPresets()
        presets.removeAll { $0.id == id }
        try storePresets(presets)
    }

    private func storePresets(_ presets: [SavedRoutingPreset]) throws {
        try privateDirectory(applicationSupport)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(presets), to: applicationSupport.appendingPathComponent("presets.json"), mode: 0o600)
    }

    public var canRestore: Bool { files.fileExists(atPath: receiptURL.path) }

    private func modelCatalog(_ configuration: AgentMixConfiguration) -> [ModelSpec] {
        ModelSpec.catalog(discovered: discoveredModels(), custom: configuration.customModels)
    }

    private func recoverNativeCoordinators(_ configuration: AgentMixConfiguration) -> AgentMixConfiguration {
        lock.lock(); defer { lock.unlock() }
        let recovery = configuration.repairingNativeCoordinators(catalog: modelCatalog(configuration))
        for note in recovery.notes where !recoveryNotes.contains(note) { recoveryNotes.append(note) }
        return recovery.configuration
    }

    public func preview(configuration: AgentMixConfiguration, platforms: Set<AgentPlatform> = Set(AgentPlatform.allCases)) throws -> IntegrationPreview {
        lock.lock(); defer { lock.unlock() }
        let installationBefore = try installationText()
        let catalog = Dictionary(uniqueKeysWithValues: modelCatalog(configuration).map { ($0.id, $0) })
        try validate(configuration, catalog: catalog, platforms: platforms)
        var changes: [FileChange] = []
        var preconditions: [FilePrecondition] = []
        var preservedConflicts: [String] = []
        let knownArtifacts = try expectedArtifactContents(installationBefore: installationBefore)
        for profile in configuration.profiles where platforms.contains(profile.platform) {
            let root = profile.platform == .codex ? codexHome : claudeHome
            var activeArtifacts = Set<String>()
            let coordinator = profile.route(for: .coordinator)!
            // Auto releases management of native defaults. It never writes the
            // sentinel or guesses a previous model/effort, including after a pin.
            if !coordinator.isAutoController && profile.platform == .codex {
                let path = root.appendingPathComponent("config.toml")
                let before = try readText(path)
                changes.append(.init(path: path.path, before: before,
                    after: try ConfigEdits.codexSettings(before ?? "", model: coordinator.modelID, effort: coordinator.effort.nativeValue),
                    reason: "Pin the native default for future Codex sessions; current chats keep their model."))
            } else if !coordinator.isAutoController {
                let path = root.appendingPathComponent("settings.json")
                let before = try readText(path)
                changes.append(.init(path: path.path, before: before,
                    after: try ConfigEdits.claudeSettings(before, model: coordinator.modelID, effort: coordinator.effort.nativeValue),
                    reason: "Pin the native default for future Claude sessions; current chats keep their model."))
            }
            let instructionURL: URL
            if profile.platform == .codex {
                let override = root.appendingPathComponent("AGENTS.override.md")
                let overrideBody = try readText(override)
                preconditions.append(.init(path: override.path, before: overrideBody))
                instructionURL = overrideBody?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? override : root.appendingPathComponent("AGENTS.md")
            } else { instructionURL = root.appendingPathComponent("CLAUDE.md") }
            let instructions = try readText(instructionURL)
            changes.append(.init(path: instructionURL.path, before: instructions,
                after: try ConfigEdits.managedBlock(in: instructions ?? "", body: policy(profile, catalog: catalog)),
                reason: "Replace only StandMixer's marked routing instructions."))
            let specs = workerSpecs(profile, catalog: catalog)
            guard Set(specs.map(\.name)).count == specs.count else { throw AgentMixError.invalid("Shared worker names collided. Choose distinct exact model IDs before applying.") }
            for spec in specs where spec.provider == profile.platform {
                let suffix = profile.platform == .codex ? "toml" : "md"
                let path = root.appendingPathComponent("agents/\(spec.name).\(suffix)")
                activeArtifacts.insert(path.path)
                let before = try readText(path)
                if let before, !before.contains(ConfigEdits.ownership) {
                    throw AgentMixError.conflict("\(path.path) already exists and is not owned by StandMixer. Rename it before applying.")
                }
                changes.append(.init(path: path.path, before: before,
                    after: agent(spec, platform: profile.platform, catalog: catalog),
                    reason: "Shared worker: \(catalog[spec.modelID]!.label) · \(spec.effort.description)"))
            }
            let externalSpecs = specs.filter { $0.provider != profile.platform }
            let externalGuide = externalWorkerGuideURL(profile.platform)
            if !externalSpecs.isEmpty {
                activeArtifacts.insert(externalGuide.path)
                let before = try readText(externalGuide)
                if let before, !before.contains(ConfigEdits.ownership) {
                    throw AgentMixError.conflict("\(externalGuide.path) already exists and is not owned by StandMixer. Keep or rename it before applying.")
                }
                changes.append(.init(path: externalGuide.path, before: before,
                    after: externalWorkerGuide(externalSpecs, platform: profile.platform, catalog: catalog),
                    reason: "Direct external CLI recipes; the current controller launches the requested provider without a native model wrapper."))
            }
            let commandSkill = skillURL(profile.platform)
            let previousSkill = try readText(commandSkill)
            if let previousSkill, !previousSkill.contains(ConfigEdits.ownership) {
                throw AgentMixError.conflict("\(commandSkill.path) already exists and is not owned by StandMixer. Keep or rename that skill before applying.")
            }
            changes.append(.init(path: commandSkill.path, before: previousSkill,
                after: AgentMixCommandSkill.contents(platform: profile.platform, executableURL: executableURL, applicationSupport: applicationSupport),
                reason: "Install /standmixer for status, presets, settings, help, and uninstall."))
            try retireLegacySkill(profile.platform, installationBefore: installationBefore,
                changes: &changes, preconditions: &preconditions, conflicts: &preservedConflicts)
            for artifact in try artifactURLs(profile.platform) + [externalGuide, legacyGuideURL(profile.platform)] where !activeArtifacts.contains(artifact.path) {
                if let before = try readText(artifact), before.contains(ConfigEdits.ownership) {
                    if knownArtifacts[artifact.path] == before {
                        changes.append(.init(path: artifact.path, before: before, after: "",
                            reason: "Remove an unchanged obsolete StandMixer worker or external recipe guide.", isDeletion: true))
                    } else {
                        preservedConflicts.append("\(artifact.path): changed or no unchanged owned version can be established; kept.")
                        preconditions.append(.init(path: artifact.path, before: before))
                    }
                }
            }
        }
        var preview = IntegrationPreview(changes: changes, preconditions: preconditions, appliedConfiguration: configuration, platforms: platforms, preservedConflicts: preservedConflicts)
        preview.installationBefore = installationBefore
        return preview
    }

    public func apply(preview: IntegrationPreview) throws -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        // Reject stale inputs without creating a support directory. Check again
        // inside the shared process lock before the first transaction write.
        try checkPreviewInputs(preview)
        try acquireOperationLock(); defer { releaseOperationLock() }
        let previous = try installationText()
        guard previous == preview.installationBefore else { throw AgentMixError.conflict("StandMixer installation changed after preview. Generate a fresh preview before applying.") }
        let installation = try updatedInstallation(for: preview, previous: loadInstallation(previous))
        return try performTransaction(preview: preview, installationAfter: encodeInstallation(installation), trackInstallation: true)
    }

    func performTransaction(preview: IntegrationPreview, installationAfter: String?, trackInstallation: Bool) throws -> ApplyResult {
        let installationBefore = try installationText()
        if trackInstallation, installationBefore != preview.installationBefore { throw AgentMixError.conflict("StandMixer installation changed after preview. Generate a fresh preview before applying.") }
        for condition in preview.preconditions {
            let url = URL(fileURLWithPath: condition.path)
            try checkAllowed(url)
            guard try readText(url) == condition.before else {
                throw AgentMixError.conflict("\(condition.path) changed after preview and may change which instructions load. Generate a fresh preview before applying.")
            }
        }
        guard Set(preview.changes.map(\.path)).count == preview.changes.count else { throw AgentMixError.invalid("Preview contains duplicate files.") }
        var records: [BackupRecord] = []
        // Unchanged targets are also part of the reviewed setup. Refuse a stale
        // preview before writing anything, even if that target needed no edit.
        for change in preview.changes {
            let url = URL(fileURLWithPath: change.path)
            try checkAllowed(url)
            guard try readText(url) == change.before else {
                throw AgentMixError.conflict("\(change.path) changed after preview. Generate a fresh preview before applying.")
            }
            if change.isChanged { records.append(.init(change: change, mode: try fileMode(url))) }
        }
        guard !records.isEmpty || (trackInstallation && installationBefore != installationAfter) else { return .init(message: "Everything already matches this profile." + preservedConflictText(preview), changedFiles: 0) }
        let backup = Backup(id: preview.id, createdAt: Date(), records: records, installationBefore: installationBefore, installationAfter: installationAfter, tracksInstallation: trackInstallation)
        let directory = applicationSupport.appendingPathComponent("Backups/\(preview.id.uuidString)", isDirectory: true)
        try privateDirectory(directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(backup), to: directory.appendingPathComponent("manifest.json"), mode: 0o600)
        var written: [BackupRecord] = []
        do {
            for record in records {
                // Recheck immediately before each replacement as well as before making the backup.
                let url = URL(fileURLWithPath: record.change.path)
                try checkAllowed(url)
                if trackInstallation, try installationText() != installationBefore { throw AgentMixError.conflict("StandMixer installation changed during the operation. Generate a fresh preview.") }
                guard try readText(url) == record.change.before else { throw AgentMixError.conflict("\(url.path) changed during Apply. Nothing will overwrite that change.") }
                try privateDirectory(url.deletingLastPathComponent())
                try applyFile(record.change, to: url, mode: record.mode ?? 0o600)
                written.append(record)
            }
            if trackInstallation {
                guard try installationText() == installationBefore else { throw AgentMixError.conflict("StandMixer installation changed during the operation. Generate a fresh preview.") }
                try storeInstallationText(installationAfter)
            }
            try write(encoder.encode(backup), to: receiptURL, mode: 0o600)
        } catch {
            if trackInstallation, (try? installationText()) == installationAfter { try? storeInstallationText(installationBefore) }
            var rollbackFailures: [String] = []
            for record in written.reversed() {
                do {
                    let url = URL(fileURLWithPath: record.change.path)
                    guard try readText(url) == record.change.expectedAfter else { rollbackFailures.append(url.path); continue }
                    try restore(record)
                } catch { rollbackFailures.append(record.change.path) }
            }
            if !rollbackFailures.isEmpty {
                throw AgentMixError.conflict("Apply stopped, and some files changed again before rollback: \(rollbackFailures.joined(separator: ", ")). Originals are in \(directory.path).")
            }
            throw error
        }
        return .init(message: "Applied \(records.count) files. Start new CLI sessions to load routing instructions and agents." + preservedConflictText(preview), changedFiles: records.count)
    }

    private func preservedConflictText(_ preview: IntegrationPreview) -> String {
        preview.preservedConflicts.isEmpty ? "" : "\nKept because they changed or ownership could not be verified:\n" + preview.preservedConflicts.joined(separator: "\n")
    }

    public func restoreLast() throws -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        guard canRestore else { throw AgentMixError.invalid("There is no StandMixer backup to restore.") }
        try acquireOperationLock(); defer { releaseOperationLock() }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: receiptURL))
        if backup.tracksInstallation == true, try installationText() != backup.installationAfter { throw AgentMixError.conflict("StandMixer installation record changed since the last operation. Restore stopped before changing files.") }
        for record in backup.records {
            let url = URL(fileURLWithPath: record.change.path)
            try checkAllowed(url)
            guard try readText(url) == record.change.expectedAfter else {
                throw AgentMixError.conflict("\(url.path) changed since StandMixer applied it. Restore stopped before changing any files.")
            }
        }
        var restored: [BackupRecord] = []
        do {
            for record in backup.records {
                let url = URL(fileURLWithPath: record.change.path)
                try checkAllowed(url)
                guard try readText(url) == record.change.expectedAfter else { throw AgentMixError.conflict("\(url.path) changed during Restore.") }
                try restore(record); restored.append(record)
            }
            if backup.tracksInstallation == true { try storeInstallationText(backup.installationBefore) }
            try files.removeItem(at: receiptURL)
        } catch {
            if backup.tracksInstallation == true, (try? installationText()) == backup.installationBefore { try? storeInstallationText(backup.installationAfter) }
            // Keep the receipt until a complete restore succeeds. Reapply only values still equal to the originals.
            for record in restored.reversed() {
                let url = URL(fileURLWithPath: record.change.path)
                if (try? readText(url)) == record.change.before {
                    try? applyFile(record.change, to: url, mode: record.mode ?? 0o600)
                }
            }
            throw error
        }
        return .init(message: "Restored the files from the last Apply.", changedFiles: backup.records.count)
    }

    func validate(_ configuration: AgentMixConfiguration, catalog: [String: ModelSpec], platforms: Set<AgentPlatform>) throws {
        guard !platforms.isEmpty else { throw AgentMixError.invalid("Select at least one installed agent to apply.") }
        try configuration.validateNativeCoordinators(catalog: Array(catalog.values), platforms: platforms)
        for platform in platforms {
            let selected = configuration.profiles.filter { $0.platform == platform }
            guard selected.count == 1 else { throw AgentMixError.invalid("Each selected agent needs one profile.") }
            let profile = selected[0]
            guard Set(profile.routes.map(\.category)) == Set(WorkCategory.allCases), profile.routes.count == WorkCategory.allCases.count else { throw AgentMixError.invalid("Each profile needs exactly one route for every category.") }
            for route in profile.routes {
                guard route.additionalAgents.count <= 3, route.category != .coordinator || route.additionalAgents.isEmpty else {
                    throw AgentMixError.invalid("Use one coordinator and one to four workers per category.")
                }
                if route.isAutoController { continue }
                let workers = [(route.modelID, route.effort)] + route.additionalAgents.map { ($0.modelID, $0.effort) }
                for (id, policy) in workers {
                    guard id != Route.autoControllerModelID, let model = catalog[id], validIdentifier(id) else { throw AgentMixError.invalid("Add a concrete model definition for \(id) before applying. Auto is available only for the controller.") }
                    if route.category == .coordinator && model.platform != platform { throw AgentMixError.invalid("The coordinator must be a native \(platform.displayName) model.") }
                    let chosen = policy.mode == .fixed ? [policy.value] : policy.mode == .range ? [policy.minimum, policy.maximum] : []
                    guard chosen.allSatisfy({ model.supportedEfforts.contains($0) && EffortPolicy.levels.contains($0) && (model.platform != .claude || $0 != "ultra") }) else { throw AgentMixError.invalid("\(model.label) does not support the selected effort.") }
                    if policy.mode == .range, let lower = EffortPolicy.levels.firstIndex(of: policy.minimum), let upper = EffortPolicy.levels.firstIndex(of: policy.maximum), lower > upper { throw AgentMixError.invalid("Minimum effort must be at or below maximum effort for \(route.category.title).") }
                    if platform == .claude && route.category == .coordinator && policy.nativeValue == "max" { throw AgentMixError.invalid("Claude cannot save max effort in user settings. Choose xhigh, or launch with --effort max.") }
                }
                if route.resultMode == .ai {
                    guard let judge = route.judgeModelID, judge != Route.autoControllerModelID, catalog[judge] != nil, validIdentifier(judge) else { throw AgentMixError.invalid("Choose an AI judge for \(route.category.title).") }
                }
            }
        }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 180 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/[]").contains($0) }
    }

    private func assignmentSpecs(_ route: Route, catalog: [String: ModelSpec]) -> [WorkerSpec] {
        [(route.modelID, route.effort)].map { WorkerSpec(model: catalog[$0.0]!, effort: $0.1) }
            + route.additionalAgents.map { WorkerSpec(model: catalog[$0.modelID]!, effort: $0.effort) }
    }

    private func workerSpecs(_ profile: RoutingProfile, catalog: [String: ModelSpec]) -> [WorkerSpec] {
        var specs = Set<WorkerSpec>()
        for route in profile.routes where route.category != .coordinator {
            specs.formUnion(assignmentSpecs(route, catalog: catalog))
            if !route.additionalAgents.isEmpty, route.resultMode == .ai, let judge = route.judgeModelID {
                specs.insert(WorkerSpec(model: catalog[judge]!, effort: .auto))
            }
        }
        return specs.sorted { $0.name < $1.name }
    }

    private func policy(_ profile: RoutingProfile, catalog: [String: ModelSpec]) -> String {
        var text = "# StandMixer routing for \(profile.platform.displayName)\n\nThe current chat model remains the native controller. Handle simple and mechanical work directly unless delegation is requested or useful. A single-agent route is a model preference, not a requirement to spawn a worker. Do not add intake, mandatory planning, or redundant same-model hops.\n\n"
        text += "Presets select models only for independently warranted work or user/project requirements. A category assignment, including Review & Security, does not require that work. Do not manufacture reviews, security audits, approval/critic loops, or reporting stages. Preserve ordinary verification and required reviews.\n\n"
        text += "The first listed worker is the lead. Quick review means bounded scope, not lower effort. Do not add unconfigured critics, consensus votes, or review loops; use a judge only when this route explicitly configures one.\n\n"
        if workerSpecs(profile, catalog: catalog).contains(where: { $0.provider != profile.platform }) {
            text += "Only when external delegation is warranted, read `\(externalWorkerGuideURL(profile.platform).path)` for the selected recipe and native completion protocol. Launch it directly; no native wrapper or model watcher.\n\n"
        }
        for route in profile.routes {
            let scope: String
            switch route.category {
            case .ui: scope = "Website/app design, layout, styling, and frontend implementation. "
            case .implementation: scope = "Nonvisual/backend implementation and surrounding code. "
            case .algorithms: scope = "Algorithm design and high-intelligence reasoning. "
            case .review: scope = "Code correctness and vulnerabilities, including authentication, permissions, and secret handling. "
            default: scope = ""
            }
            text += "- \(route.category.title): \(scope)"
            if route.category == .coordinator {
                if route.isAutoController {
                    text += "Auto — use the currently selected native/invoking chat model and its effort. Leave native model and effort settings untouched; do not launch or hop to a controller model.\n"
                } else {
                    text += "\(catalog[route.modelID]!.label) (`\(route.modelID)`), \(route.effort.description). This explicit pin sets only the native default for future sessions; it never re-dispatches an existing chat.\n"
                }
                continue
            }
            let workers = assignmentSpecs(route, catalog: catalog)
            text += workers.enumerated().map { index, spec in
                let model = catalog[spec.modelID]!
                let provider = spec.provider == profile.platform ? "" : " via \(spec.provider.displayName)"
                let slot = workers.count > 1 ? "\(index + 1). " : ""
                let launch = spec.provider == profile.platform ? "`\(spec.name)`" : "direct external CLI recipe `\(spec.externalReferenceID)`"
                return "\(slot)\(model.label)\(provider), \(spec.effort.description), \(launch)"
            }.joined(separator: "; ") + ".\n"
            if workers.count > 1 {
                text += teamInstructions(route, count: workers.count)
                switch route.resultMode {
                case .coordinator: text += "The first worker verifies and consolidates; the controller presents the verified result.\n"
                case .user: text += "Present labeled results and wait for the user's selection.\n"
                case .ai:
                    let judge = WorkerSpec(model: catalog[route.judgeModelID!]!, effort: .auto)
                    let launch = judge.provider == profile.platform ? "`\(judge.name)` instance" : "external CLI job from recipe `\(judge.externalReferenceID)`"
                    text += "After the workers finish, launch a fresh \(launch) with a compare-only brief to judge their results against the task and verification evidence.\n"
                }
            }
            if route.category == .ui {
                if route.teamMode == .leadReview {
                    text += "  Implementation and fixes stay with the primary, or a different winner explicitly selected by the user. Carry that implementation owner's identity and accepted design forward; resume that worker when possible. Do not rerun the design team for ordinary tweaks; revisit helpers only for major changes or a new style direction.\n"
                } else {
                    text += "  After a winning design is selected, keep follow-up design and frontend implementation with the agent/model that made it; resume that worker when possible. Carry its identity and accepted design forward in the task context. Do not rerun the design team for ordinary tweaks; reopen comparison only when requested or the design direction materially changes.\n"
                }
            }
        }
        return text + "\nRoutes select models, not worker personas. Give workers the concrete task, only relevant context/files, and actual constraints; omit role labels and unrelated narration about StandMixer, presets, or personal budgets. Keep the original caller's requested or effective reasoning intensity in controller launch metadata, not worker prose. For Auto, use the supported levels in the selector description or external recipe: choose the nearest level in low, medium, high, xhigh, max, ultra order, with lower ties. Use native inheritance when suitable or pass the mapped launch override; external CLI jobs must explicitly pass the target effort flag. Preserve explicit user/session requests. If the caller intensity is unknown, choose from task complexity and constraints before launch. Fixed effort stays fixed; for ranges choose and explicitly pass a supported effort within the stated bounds at launch. These are launch instructions, not runtime enforcement. Respect project permissions and managed settings. Wait for launched workers, verify results proportionately, and surface failures without substitution. Label delegated jobs with the requested model/provider. Do not claim verified model or effort without exposed execution metadata; no extra identity checks or routine identity report.\n"
    }

    private func teamInstructions(_ route: Route, count: Int) -> String {
        if route.teamMode == .leadReview {
            let reviewers = count - 1
            let reviewTeam = reviewers == 1 ? "the remaining worker gives" : "the remaining \(reviewers) workers give"
            switch route.category {
            case .ui:
                return "  Lead + review: for an initial substantial visual design, the primary and helpers may make basic design passes concurrently; helpers provide basic alternatives only, not full implementations. "
            case .planning:
                return "  Lead + review: the first worker creates the substantive plan; then \(reviewTeam) quick focused review of that plan, not independent replacement plans. "
            case .review:
                return "  Lead + review: the first worker performs the substantive check; then \(reviewTeam) quick focused review of its findings. "
            default:
                return "  Lead + review: the first worker does the substantive work; then \(reviewTeam) quick focused review of that result, not full duplicate solves. "
            }
        }
        let scope: String
        switch route.category {
        case .planning: scope = "Produce full independent plans. "
        case .ui: scope = "For an initial substantial visual design or an explicitly requested fresh comparison, produce full independent design alternatives. "
        case .review: scope = "Perform full independent checks. "
        default: scope = "Produce full independent solutions. "
        }
        return "  Parallel: \(scope)When this category warrants delegation, launch all \(count) workers concurrently as independent instances, including repeated slots using the same definition; keep edits isolated. "
    }

    private func externalWorkerGuide(_ specs: [WorkerSpec], platform: AgentPlatform, catalog: [String: ModelSpec]) -> String {
        var text = """
        <!-- \(ConfigEdits.ownership) -->
        # Direct external workers for \(platform.displayName)

        The current controller launches these CLIs directly. These recipe identifiers are reference sections, not native agent types. Do not create a native bridge agent, a second controller, an LLM watcher, or a workflow agent pretending to be another provider. A native Claude workflow agent runs a Claude model; it is not a shell execution API.

        ## Launch and completion

        Write the concrete task in an approved private task file, with only relevant context/files, approved working directory, writable roots, actual constraints, and task-appropriate verification. Omit role labels and unrelated routing, preset, or budget narration. Effort translation belongs to the controller before launch; include caller intensity in task prose only if the task itself needs it. Replace every command placeholder with a properly quoted value or use an argument array. Keep task files and caches inside host-approved roots. CLI sign-in may differ from a desktop login; never read credentials or switch accounts.

        """ + "\n"
        if platform == .claude {
            text += "Launch the recipe once with the native Bash tool using run_in_background: true and a target-first description such as `Sol 6.1 via Codex · implement the requested change`. Retain the real returned task ID and output_file. Continue independent work; wait for the native completion notice, then use Read on that output file and the recipe's result file. A background task ID or a queued/start response is not completion. Do not create a second agent to launch or watch it.\n\n"
        } else {
            text += "Launch the recipe once through this Codex host's native command/execution tool with its background or session support. Use a target-first visible label such as `Opus 5.5 via Claude Code · review the requested change` when the tool supports a description. Retain the real returned job/session handle and output path. Use the host's native completion/wait mechanism (for exec_command sessions, write_stdin waits) until the process exits, then read the captured output and result file. Do not invent Claude workflow API calls or use another model to wait for this process.\n\n"
        }
        text += """
        Background launch is not completion. If an approved project runner returns early, use its documented deterministic wait/completion command and real run ID; the startup process exiting is not the worker finishing. Wait for a terminal exit state and inspect the final result and diagnostics; verify the requested outputs. Surface failed, cancelled, timed-out, sign-in, permission, and quota states as incomplete. Never fabricate a job ID, execution model, completion, or successful fallback. The visible job label names the requested target; claim verified model and effort only when exposed by CLI execution metadata. If asked and unavailable, say unverified. Do not substitute providers or blindly retry. If an existing deterministic native monitor is available, it stays quiet while unchanged and reports only completion or required attention; never create an LLM watcher, daemon, or recurring monitor.

        ## Permissions and effort

        Preserve the person's existing permissions and settings. For Codex recipes replace <task-sandbox> with workspace-write for authorized implementation, edits, and builds; use read-only for review and inspection or when changes are not authorized. A model selector does not make an implementation task read-only. Check effective sandbox metadata when exposed. Add --add-dir only for necessary roots already authorized by the user/project/host, never to defeat a denial. For linked worktrees identify the actual git directory and common directory with git rev-parse before commits; locks, objects, and refs may need a separately authorized root. Prefer task-local caches and temporary outputs. CLI flags do not grant host filesystem or network permissions. If the host is read-only or a needed root is not authorized, report the exact missing permission instead of widening scope. Keep Claude's normal launch permissions; surface any unavailable approval instead of broadening access.

        When the user or project has explicitly authorized an existing execution wrapper with external confinement, use that exact runner within its approved scope and retain its fence. Describe its actual guarantees; do not assume a full workspace sandbox. Do not invent an unrestricted runner, add bypass flags yourself, weaken a fence, change global permissions, or retry a denied operation with broader access.

        Auto follows the original caller's reasoning intensity, never an intermediary model or a catalog default. Translate it using the recipe's supported mapping and explicitly pass it to the real worker. If absent, choose from task complexity and constraints and record the choice. Fixed effort remains fixed; a range requires choosing a supported level inside its bounds before launch. Each team slot or judge launches a fresh CLI job even when it uses the same recipe. Carry the accepted implementation owner's provider/model and native job/session identity forward for follow-up work; do not rerun a design team for ordinary tweaks.

        ## Recipes

        """ + "\n"
        for spec in specs {
            let model = catalog[spec.modelID]!
            let fallback = model.platform == .codex ? "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" : home.appendingPathComponent(".local/bin/claude").path
            // Executable metadata only: preview must never run a provider CLI.
            let cli = detectMetadata().first(where: { $0.platform == model.platform })?.path ?? fallback
            text += "<a id=\"\(spec.externalReferenceID)\"></a>\n### \(model.label) via \(model.platform.displayName) — \(spec.effort.description)\n\nRequested model: `\(model.id)`. Requested provider: \(model.platform.displayName). Native job description: `\(model.label) via \(model.platform.displayName) · <task>`.\n\n"
            let effort: String
            switch spec.effort.mode {
            case .auto:
                let mapping = EffortPolicy.levels.compactMap { caller in model.nearestSupportedEffort(to: caller).map { "\(caller) -> \($0)" } }.joined(separator: "; ")
                text += "Use the original caller's reasoning intensity before launch, not as a required child prompt. Supported target levels: \(model.callerEfforts.joined(separator: ", ")). Caller-to-target mapping: \(mapping.isEmpty ? "not established; verify supported levels before launch" : mapping). Replace <mapped-caller-effort> and explicitly pass it to the real worker; do not fall back to an intermediary model's effort or the target's catalog default.\n\n"
                effort = "<mapped-caller-effort>"
            case .fixed: effort = spec.effort.value
            case .range:
                text += "Choose a supported effort between \(spec.effort.minimum) and \(spec.effort.maximum) before launch. Replace <chosen-range-effort> with that choice.\n\n"
                effort = "<chosen-range-effort>"
            }
            text += "```sh\n"
            if model.platform == .codex {
                text += "\(shellQuote(cli)) exec --json --sandbox <task-sandbox> -C <approved-working-directory> -m \(shellQuote(model.id)) -c \(shellQuote("model_reasoning_effort=\"\(effort)\"")) -o <temporary-result-file> - < <temporary-brief-file>\n"
            } else {
                text += "cd <approved-working-directory> && \(shellQuote(cli)) -p --model \(shellQuote(model.id)) --output-format json --effort \(shellQuote(effort)) < <temporary-brief-file> > <temporary-result-file>\n"
            }
            text += "```\n\nRead the native job output for completion/diagnostics and the temporary result file for the final response. Requested \(model.label) is not proof that \(model.label) ran.\n\n"
        }
        return text
    }

    private func agent(_ spec: WorkerSpec, platform: AgentPlatform, catalog: [String: ModelSpec]) -> String {
        let model = catalog[spec.modelID]!
        let name = spec.name
        let instructions = "Complete the supplied task using only relevant context and files. Follow its actual scope, permissions, and applicable project instructions; verify as appropriate to the task. Do not recursively invoke this same worker."
        let executionModel = model.id
        let effort = spec.effort.nativeValue
        let description = spec.launchDescription(for: model)

        if platform == .codex {
            var result = "# \(ConfigEdits.ownership)\nname = \(ConfigEdits.tomlString(name))\ndescription = \(ConfigEdits.tomlString(description))\nmodel = \(ConfigEdits.tomlString(executionModel))\n"
            if let effort { result += "model_reasoning_effort = \(ConfigEdits.tomlString(effort))\n" }
            return result + "developer_instructions = \(ConfigEdits.tomlString(instructions))\n"
        }
        var result = "---\nname: \(name)\ndescription: \(ConfigEdits.tomlString(description))\nmodel: \(executionModel)\n"
        if let effort { result += "effort: \(effort)\n" }
        return result + "---\n\n<!-- \(ConfigEdits.ownership) -->\n\n\(instructions)\n"
    }

    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    struct BackupRecord: Codable {
        var change: FileChange
        var mode: Int?
    }
    struct Backup: Codable {
        var id: UUID
        var createdAt: Date
        var records: [BackupRecord]
        var installationBefore: String?
        var installationAfter: String?
        var tracksInstallation: Bool?
    }

    func storeInstallationText(_ text: String?) throws {
        if let text {
            try privateDirectory(applicationSupport)
            try write(Data(text.utf8), to: installationURL, mode: 0o600)
        } else if files.fileExists(atPath: installationURL.path) { try files.removeItem(at: installationURL) }
    }

    func restore(_ record: BackupRecord) throws {
        let url = URL(fileURLWithPath: record.change.path)
        if let before = record.change.before { try write(Data(before.utf8), to: url, mode: record.mode ?? 0o600) }
        else if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    func applyFile(_ change: FileChange, to url: URL, mode: Int) throws {
        if change.isDeletion { try files.removeItem(at: url) }
        else { try write(Data(change.after.utf8), to: url, mode: mode) }
    }

    func fileMode(_ url: URL) throws -> Int? {
        guard files.fileExists(atPath: url.path) else { return nil }
        return try files.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func readText(_ url: URL) throws -> String? {
        try checkNoSymlink(url)
        guard files.fileExists(atPath: url.path) else { return nil }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4_000_000 else { throw AgentMixError.invalid("\(url.path) is not a regular configuration file under 4 MB.") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw AgentMixError.invalid("\(url.path) is not UTF-8; StandMixer will not rewrite it.") }
        return text
    }

    func checkAllowed(_ url: URL, checkSymlinks: Bool = true) throws {
        let path = url.standardizedFileURL.path
        let nativeNames: [URL] = [codexHome.appendingPathComponent("config.toml"), codexHome.appendingPathComponent("AGENTS.md"), codexHome.appendingPathComponent("AGENTS.override.md"), claudeHome.appendingPathComponent("settings.json"), claudeHome.appendingPathComponent("CLAUDE.md")]
        guard nativeNames.contains(where: { $0.standardizedFileURL.path == path })
                || AgentPlatform.allCases.contains(where: { isWorkerArtifact(url, platform: $0) || controlURLs($0).contains(where: { $0.path == path }) }) else {
            throw AgentMixError.invalid("Preview contains a file outside StandMixer's configuration targets: \(path).")
        }
        if checkSymlinks { try checkNoSymlink(url) }
    }

    private func isWorkerArtifact(_ url: URL, platform: AgentPlatform) -> Bool {
        let root = platform == .codex ? codexHome : claudeHome
        guard url.standardizedFileURL.deletingLastPathComponent().path == root.appendingPathComponent("agents").standardizedFileURL.path else { return false }
        let name = url.lastPathComponent
        let suffix = platform == .codex ? "toml" : "md"
        return name.hasPrefix("agentmix-") && name.hasSuffix(".\(suffix)") && name.utf8.count <= 200
            && name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }
    }

    /// Only direct, safely named AgentMix candidates in this harness's agents folder
    /// are inspected. Ownership is checked before any obsolete file is proposed for removal.
    func artifactURLs(_ platform: AgentPlatform) throws -> [URL] {
        let root = platform == .codex ? codexHome : claudeHome
        let directory = root.appendingPathComponent("agents")
        try checkNoSymlink(directory)
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return [] }
            throw AgentMixError.invalid("StandMixer could not inspect the direct worker folder at \(directory.path).")
        }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw AgentMixError.invalid("StandMixer could not inspect the direct worker folder at \(directory.path).")
        }
        defer { closedir(stream) }
        var urls: [URL] = []
        var entries = 0
        while let entry = readdir(stream) {
            guard entries < 2048 else { throw AgentMixError.invalid("The worker folder exceeds StandMixer's 2048-entry inspection limit; no worker cleanup was applied.") }
            entries += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            let url = directory.appendingPathComponent(name)
            if isWorkerArtifact(url, platform: platform) { urls.append(url) }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func checkNoSymlink(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let attributes = try? files.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // macOS exposes these root-owned aliases even when callers hand Foundation a resolved /private path.
                let systemAliases = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]
                let destination = try? files.destinationOfSymbolicLink(atPath: current.path)
                if let expected = systemAliases[current.path], destination == expected || destination == "/\(expected)" {
                    current.deleteLastPathComponent()
                    continue
                }
                throw AgentMixError.invalid("StandMixer will not follow the symbolic link at \(current.path). Choose a direct configuration directory.")
            }
            current.deleteLastPathComponent()
        }
    }

    func privateDirectory(_ url: URL) throws {
        try checkNoSymlink(url)
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    func write(_ data: Data, to url: URL, mode: Int) throws {
        try checkNoSymlink(url)
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
