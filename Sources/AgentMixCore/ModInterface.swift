import Darwin
import Foundation

/// A small local settings protocol for the native panels. Account checks use
/// public CLI status; Mac app installation invokes one fixed owned launcher.
/// Requests never supply file paths, commands, or writable preview contents.
public struct AgentMixModRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case state, inspect, saveDraft, savePreset, deletePreset, preview, apply, previewUninstall, uninstall, previewRestore, restore, installMac, openWeb, openMac, checkAccounts
    }
    public var action: Action
    public var configuration: AgentMixConfiguration?
    public var platforms: Set<AgentPlatform>?
    public var previewID: UUID?
    public var name: String?
    public var presetID: UUID?
    public var refresh: Bool?
    public init(action: Action, configuration: AgentMixConfiguration? = nil,
                platforms: Set<AgentPlatform>? = nil, previewID: UUID? = nil,
                name: String? = nil, presetID: UUID? = nil, refresh: Bool? = nil) {
        self.action = action; self.configuration = configuration
        self.platforms = platforms; self.previewID = previewID
        self.name = name; self.presetID = presetID
        self.refresh = refresh
    }
}

public struct AgentMixModExecution: Sendable {
    public var output: Data
    public var exitCode: Int32
}

public struct AgentMixModError: Codable, Sendable {
    public var code: String
    public var message: String
}

public struct AgentMixModResponse: Encodable, Sendable {
    public var ok: Bool
    public var state: AgentMixModState?
    public var preview: AgentMixModPreview?
    public var result: AgentMixModResult?
    public var inspection: AgentMixModInspection?
    public var accounts: AgentMixModAccounts?
    public var web: AgentMixWebOpening?
    public var error: AgentMixModError?
}

public struct AgentMixModResult: Codable, Sendable {
    public var message: String
    public var changedFiles: Int
    public var notes: [String]
}

public struct AgentMixModConnection: Codable, Sendable {
    public var platform: AgentPlatform
    public var path: String?
    public var version: String?
    public var detail: String
    public var isInstalled: Bool
    public var compatibilityWarning: String?
    init(_ connection: ConnectionStatus) {
        platform = connection.platform; path = connection.path; version = connection.version
        detail = connection.detail; isInstalled = connection.isInstalled
        compatibilityWarning = connection.compatibilityWarning
    }
}

public struct AgentMixModPreset: Codable, Sendable {
    public var id: AgentMixPreset
    public var title: String
    public var configuration: AgentMixConfiguration
}

public struct AgentMixModState: Codable, Sendable {
    public var configuration: AgentMixConfiguration
    public var hasSavedDraft: Bool
    public var previousDraft: AgentMixConfiguration?
    public var enabledPlatforms: Set<AgentPlatform>
    public var preferredPlatforms: Set<AgentPlatform>
    public var availablePlatforms: Set<AgentPlatform>
    public var presets: [AgentMixModPreset]
    public var catalog: [ModelSpec]
    public var connections: [AgentMixModConnection]
    public var installation: InstallationStatus
    public var savedPresets: [SavedRoutingPreset]
    /// Saved global primitive defaults only. No observer or active-session state.
    public var nativeSettings: [AgentMixModNativeSettings]
    public var inspection: AgentMixModInspection?
    public var canRestore: Bool
    public var installedMac: AgentMixInstalledMac?
    public var notes: [String]
}

public struct AgentMixModDiffLine: Codable, Sendable {
    public var kind: String
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
}

public struct AgentMixModDiffHunk: Codable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [AgentMixModDiffLine]
}

public struct AgentMixModDiff: Codable, Sendable {
    public var hunks: [AgentMixModDiffHunk]
    public var addedLineCount: Int
    public var removedLineCount: Int
    public var beforeEndsWithNewline: Bool
    public var afterEndsWithNewline: Bool
    public var hasFinalNewlineChange: Bool
    public var isCoarse: Bool
    public var isUnchanged: Bool
    init(_ diff: TextDiff) {
        hunks = diff.hunks.map { hunk in
            .init(oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: hunk.newStart, newCount: hunk.newCount,
                lines: hunk.lines.map { line in
                    .init(kind: line.kind == .context ? "context" : line.kind == .addition ? "addition" : "removal",
                          text: line.text, oldLineNumber: line.oldLineNumber, newLineNumber: line.newLineNumber)
                })
        }
        addedLineCount = diff.addedLineCount; removedLineCount = diff.removedLineCount
        beforeEndsWithNewline = diff.beforeEndsWithNewline; afterEndsWithNewline = diff.afterEndsWithNewline
        hasFinalNewlineChange = diff.hasFinalNewlineChange; isCoarse = diff.isCoarse; isUnchanged = diff.isUnchanged
    }
}

public struct AgentMixModFileChange: Codable, Sendable {
    public var path: String
    public var reason: String
    public var isDeletion: Bool
    public var isChanged: Bool
    public var diff: AgentMixModDiff
    init(_ change: FileChange) {
        path = change.path; reason = change.reason
        isDeletion = change.isDeletion; isChanged = change.isChanged
        diff = .init(TextDiff(before: change.before, after: change.expectedAfter))
    }
}

public struct AgentMixModPreview: Codable, Sendable {
    public var id: UUID
    public var kind: String
    public var createdAt: Date
    public var expiresAt: Date
    public var changes: [AgentMixModFileChange]
    public var conflicts: [String]
    public var hasInstallation: Bool
    public var changedFiles: Int
}

/// Shared by independent helper processes. Only a server-generated private ID
/// can select a reviewed plan; Apply never rebuilds it from a fresh request.
public final class AgentMixModInterface: @unchecked Sendable {
    public static let maximumRequestBytes = 512 * 1024
    /// Native Mods bounds each process stdout stream at 4 MiB. Leave room for
    /// host bookkeeping and fail explicitly instead of returning truncated JSON.
    public static let maximumResponseBytes = 3 * 1024 * 1024
    public static let maximumStoredPreviewBytes = 24 * 1024 * 1024
    public static let maximumPreviews = 8
    public static let previewLifetime: TimeInterval = 60 * 60
    let service: IntegrationService
    let inspectionReader: (@Sendable (AgentPlatform) async throws -> AgentImportProposal)?
    private let macInstaller: (@Sendable () async throws -> ApplyResult)?
    private let webOpener: (@Sendable () async throws -> AgentMixWebOpening)?
    private let macOpener: (@Sendable () async throws -> ApplyResult)?
    private let accountChecker: (@Sendable () async throws -> AgentMixModAccounts)?
    private let fixtureConnections: [ConnectionStatus]?
    private let now: @Sendable () -> Date
    private var directory: URL { service.applicationSupport.appendingPathComponent("Previews", isDirectory: true) }
    private var configurationURL: URL { service.applicationSupport.appendingPathComponent("configuration.json") }

    /// Connections can be injected by fixture tests; normal callers use bounded
    /// known-location discovery and isolated --version probes, never inference.
    public init(service: IntegrationService, connections: [ConnectionStatus]? = nil,
                inspectionReader: (@Sendable (AgentPlatform) async throws -> AgentImportProposal)? = nil,
                macInstaller: (@Sendable () async throws -> ApplyResult)? = nil,
                webOpener: (@Sendable () async throws -> AgentMixWebOpening)? = nil,
                macOpener: (@Sendable () async throws -> ApplyResult)? = nil,
                accountChecker: (@Sendable () async throws -> AgentMixModAccounts)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service; fixtureConnections = connections
        self.inspectionReader = inspectionReader; self.macInstaller = macInstaller
        self.webOpener = webOpener; self.macOpener = macOpener
        self.accountChecker = accountChecker; self.now = now
    }

    public func runJSON(_ data: Data) async -> AgentMixModExecution {
        let response: AgentMixModResponse
        var exitCode: Int32
        do {
            guard !data.isEmpty, data.count <= Self.maximumRequestBytes else {
                throw ProtocolError("invalidRequest", "Send one JSON request under 512 KiB.")
            }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let object,
               let action = object["action"] as? String,
               [AgentMixModRequest.Action.installMac.rawValue, AgentMixModRequest.Action.openWeb.rawValue,
                AgentMixModRequest.Action.openMac.rawValue, AgentMixModRequest.Action.checkAccounts.rawValue].contains(action),
               Set(object.keys) != ["action"] {
                throw ProtocolError("invalidRequest", "\(action) takes no fields other than action. Paths and commands are not accepted.")
            }
            let request: AgentMixModRequest
            do { request = try JSONDecoder().decode(AgentMixModRequest.self, from: data) }
            catch { throw ProtocolError("invalidRequest", "The request is not a valid StandMixer JSON action.") }
            try validateShape(request)
            response = try await execute(request)
            exitCode = 0
        } catch {
            let failure: AgentMixModError
            if let error = error as? ProtocolError { failure = .init(code: error.code, message: error.message) }
            else if let error = error as? AgentMixMacInstallerError { failure = .init(code: error.code, message: error.localizedDescription) }
            else if let error = error as? AgentMixAppOpeningError { failure = .init(code: error.code, message: error.localizedDescription) }
            else if error is CancellationError { failure = .init(code: "cancelled", message: "The StandMixer operation was cancelled.") }
            else if let error = error as? AgentMixError {
                switch error {
                case .conflict(let message): failure = .init(code: "conflict", message: message)
                case .invalid(let message): failure = .init(code: "invalidConfiguration", message: message)
                }
            } else {
                // Decode and filesystem errors can contain native settings or
                // implementation details. Keep the public error concise.
                failure = .init(code: "io", message: "StandMixer could not read or safely update its configuration. Check file permissions and generate a fresh preview.")
            }
            response = .init(ok: false, error: failure)
            exitCode = 1
        }
        let encoder = Self.encoder()
        var output = (try? encoder.encode(response)) ?? Data("{\"ok\":false,\"error\":{\"code\":\"io\",\"message\":\"StandMixer could not encode its response.\"}}".utf8)
        if output.count > Self.maximumResponseBytes {
            let failure = AgentMixModResponse(ok: false, error: .init(code: "previewTooLarge",
                message: "This StandMixer review cannot fit within the native panel's output limit. No routing changes were made. Reduce the configuration size before reviewing again."))
            output = try! encoder.encode(failure)
            exitCode = 1
        }
        return .init(output: output, exitCode: exitCode)
    }

    func connections() async -> [ConnectionStatus] {
        if let fixtureConnections { return fixtureConnections }
        return await service.detect()
    }

    private func execute(_ request: AgentMixModRequest) async throws -> AgentMixModResponse {
        switch request.action {
        case .openWeb:
            try Task.checkCancellation()
            let opened: AgentMixWebOpening
            if let webOpener { opened = try await webOpener() }
            else { opened = try await AgentMixAppOpening.openWeb(service: service) }
            try Task.checkCancellation()
            return .init(ok: true, web: opened)
        case .openMac:
            try Task.checkCancellation()
            let opened: ApplyResult
            if let macOpener { opened = try await macOpener() }
            else { opened = try await AgentMixAppOpening.openMac(service: service) }
            try Task.checkCancellation()
            return .init(ok: true, result: .init(message: opened.message, changedFiles: 0, notes: []))
        case .checkAccounts:
            try Task.checkCancellation()
            let accounts: AgentMixModAccounts
            if let accountChecker { accounts = try await accountChecker() }
            else { accounts = try await AgentMixAccountChecker.check(service: service) }
            try Task.checkCancellation()
            return .init(ok: true, accounts: accounts)
        case .installMac:
            // Building is independent of native settings transactions. Never
            // hold their operation lock or discover/start an observer here.
            try Task.checkCancellation()
            let installed: ApplyResult
            if let macInstaller { installed = try await macInstaller() }
            else { installed = try await AgentMixMacInstaller.install(service: service) }
            try Task.checkCancellation()
            return .init(ok: true, result: .init(message: installed.message, changedFiles: 0, notes: []))
        case .state:
            let connections = await connections()
            return .init(ok: true, state: try readState(connections: connections, requestedPlatforms: request.platforms))
        case .inspect:
            return try await inspectPreferences(platforms: request.platforms, refresh: request.refresh ?? false)
        case .saveDraft, .savePreset:
            let connections = await connections()
            let configuration = try validatedDraft(request, connections: connections)
            return try service.withOperationLock {
                if request.action == .saveDraft {
                    try saveEditableDraft(configuration)
                } else {
                    try service.savePreset(name: request.name!, configuration: configuration)
                }
                return .init(ok: true, state: try readState(connections: connections, requestedPlatforms: request.platforms),
                    result: .init(message: request.action == .saveDraft ? "Draft saved. Review and Apply to update routing." : "Preset saved. Routing is unchanged.", changedFiles: 0, notes: []))
            }
        case .deletePreset:
            let connections = await connections()
            return try service.withOperationLock {
                try service.deletePreset(id: request.presetID!)
                return .init(ok: true, state: try readState(connections: connections, requestedPlatforms: nil),
                    result: .init(message: "Preset deleted. Routing is unchanged.", changedFiles: 0, notes: []))
            }
        case .preview:
            let available = Set(await connections().filter(\.isInstalled).map(\.platform))
            let selected = request.platforms!
            guard !selected.isEmpty, selected.isSubset(of: available) else {
                throw ProtocolError("invalidConfiguration", "Select at least one available CLI. Check connections before applying.")
            }
            try validateCustomModels(request.configuration!)
            try validateEnabledModelProviders(request.configuration!, platforms: selected)
            return try service.withOperationLock {
                var configuration = request.configuration!
                configuration.enabledPlatforms = selected
                let preview = try service.preview(configuration: configuration, platforms: selected)
                let stored = StoredPreview(preview: preview, configurationBefore: try service.readText(configurationURL), now: now())
                try store(stored)
                return .init(ok: true, preview: stored.review)
            }
        case .previewUninstall:
            return try service.withOperationLock {
                let preview = try service.previewUninstall()
                let stored = StoredPreview(uninstall: preview, now: now())
                try store(stored)
                return .init(ok: true, preview: stored.review)
            }
        case .previewRestore:
            return try service.withOperationLock {
                guard let source = try service.readText(service.receiptURL) else {
                    throw ProtocolError("invalidConfiguration", "There is no StandMixer backup to restore.")
                }
                let backup = try JSONDecoder().decode(IntegrationService.Backup.self, from: Data(source.utf8))
                guard backup.records.count <= 256 else { throw ProtocolError("invalidConfiguration", "The last backup exceeds the preview limit.") }
                if backup.tracksInstallation == true, try service.installationText() != backup.installationAfter {
                    throw ProtocolError("conflict", "The StandMixer installation changed since the last operation. Restore stopped before changing files.")
                }
                for record in backup.records {
                    let url = URL(fileURLWithPath: record.change.path)
                    try service.checkAllowed(url)
                    guard try service.readText(url) == record.change.expectedAfter else {
                        throw ProtocolError("conflict", "\(url.path) changed since the last operation. Restore stopped before changing files.")
                    }
                }
                let stored = StoredPreview(backup: backup, source: source, now: now())
                try store(stored)
                return .init(ok: true, preview: stored.review)
            }
        case .apply, .uninstall, .restore:
            return try service.withOperationLock {
                let stored = try load(request.previewID!)
                guard stored.kind == request.action.rawValue else {
                    throw ProtocolError("invalidRequest", "This preview belongs to a different StandMixer action.")
                }
                let applied: ApplyResult
                var notes: [String] = []
                if request.action == .apply {
                    guard try service.readText(configurationURL) == stored.configurationBefore else {
                        throw ProtocolError("conflict", "The saved draft changed after preview. Generate a fresh preview before applying.")
                    }
                    applied = try service.apply(preview: stored.integrationPreview)
                    if let configuration = stored.configuration {
                        do { try saveEditableDraft(configuration) }
                        catch { notes.append("The routing was applied, but the editable draft could not be saved. Check StandMixer's file permissions.") }
                    }
                } else if request.action == .uninstall {
                    applied = try service.uninstall(preview: stored.uninstallPreview)
                } else {
                    guard try service.readText(service.receiptURL) == stored.restoreSource else {
                        throw ProtocolError("conflict", "The last backup changed after preview. Review a fresh restore preview.")
                    }
                    applied = try service.restoreLast()
                }
                try? service.files.removeItem(at: previewURL(stored.id))
                return .init(ok: true, result: .init(message: applied.message, changedFiles: applied.changedFiles, notes: notes))
            }
        }
    }

    private func validatedDraft(_ request: AgentMixModRequest, connections: [ConnectionStatus]) throws -> AgentMixConfiguration {
        let selected = request.platforms!
        let available = Set(connections.filter(\.isInstalled).map(\.platform))
        guard !selected.isEmpty, selected.isSubset(of: available) else {
            throw ProtocolError("invalidConfiguration", "Select at least one available CLI before saving a draft or preset.")
        }
        var configuration = request.configuration!
        configuration.enabledPlatforms = selected
        try validateCustomModels(configuration)
        try validateEnabledModelProviders(configuration, platforms: selected)
        let catalog = ModelSpec.catalog(discovered: service.discoveredModels(), custom: configuration.customModels)
        try service.validate(configuration, catalog: Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) }), platforms: selected)
        // Inactive host profiles are retained, but their coordinators must still
        // have an explicit native identity before the draft can be persisted.
        try configuration.validateNativeCoordinators(catalog: catalog)
        return configuration
    }

    private func validateCustomModels(_ configuration: AgentMixConfiguration) throws {
        guard configuration.customModels.count <= 128,
              Set(configuration.customModels.map(\.id)).count == configuration.customModels.count else {
            throw ProtocolError("invalidConfiguration", "Use at most 128 custom models, each with a distinct exact model ID.")
        }
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/[]")
        for model in configuration.customModels {
            guard !model.id.isEmpty, model.id.count <= 180,
                  model.id.unicodeScalars.allSatisfy(identifierCharacters.contains),
                  !model.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.label.count <= 120,
                  !model.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !model.supportedEfforts.isEmpty,
                  Set(model.supportedEfforts).count == model.supportedEfforts.count,
                  model.supportedEfforts.allSatisfy({ EffortPolicy.levels.contains($0) && (model.platform != .claude || $0 != "ultra") }),
                  model.defaultEffort.map(model.supportedEfforts.contains) ?? true else {
                throw ProtocolError("invalidConfiguration", "Custom models need a valid exact ID, a label, and supported effort levels for their provider.")
            }
            // Catalog identities remain authoritative when a custom entry
            // repeats an installed ID. The duplicate cannot relabel a provider.
        }
    }

    /// Saving a recipe never implies that it is installed. Preserve the actual
    /// previous editable draft, rather than a factory recipe or native defaults.
    private func saveEditableDraft(_ configuration: AgentMixConfiguration) throws {
        if try service.readText(configurationURL) != nil {
            let previous = try service.loadConfiguration()
            if previous != configuration { try service.savePreviousDraft(previous) }
        }
        try service.saveConfiguration(configuration)
    }

    /// A disabled provider is unavailable to this mod's active recipe, including
    /// cross-provider workers and judges. Keep inactive host drafts untouched.
    /// The generic integration service retains its existing manual semantics.
    private func validateEnabledModelProviders(_ configuration: AgentMixConfiguration, platforms: Set<AgentPlatform>) throws {
        let catalog = Dictionary(uniqueKeysWithValues:
            ModelSpec.catalog(discovered: service.discoveredModels(), custom: configuration.customModels).map { ($0.id, $0) })
        for profile in configuration.profiles where platforms.contains(profile.platform) {
            for route in profile.routes where route.category != .coordinator {
                var selectedModels = [route.modelID] + route.additionalAgents.map(\.modelID)
                if route.resultMode == .ai, let judge = route.judgeModelID { selectedModels.append(judge) }
                for id in selectedModels {
                    guard let model = catalog[id], !platforms.contains(model.platform) else { continue }
                    throw ProtocolError("invalidConfiguration", "\(profile.platform.displayName) \(route.category.title) uses \(model.label) from disabled \(model.platform.displayName). Enable \(model.platform.displayName) or choose a different model.")
                }
            }
        }
    }

    private func readState(connections: [ConnectionStatus], requestedPlatforms: Set<AgentPlatform>?) throws -> AgentMixModState {
        service.lock.lock(); defer { service.lock.unlock() }
        let available = Set(connections.filter(\.isInstalled).map(\.platform))
        let hasDraft = try service.readText(configurationURL) != nil
        let previousDraft = try service.loadPreviousDraft()
        var configuration = hasDraft ? try service.loadConfiguration()
            : .preset(.optimized, availablePlatforms: available)
        let preferred = requestedPlatforms ?? configuration.enabledPlatforms ?? available
        let enabled = preferred.intersection(available)
        configuration.enabledPlatforms = enabled
        let presets = AgentMixPreset.allCases.map { preset -> AgentMixModPreset in
            var recipe = AgentMixConfiguration.preset(preset, availablePlatforms: available.intersection(enabled))
            recipe.enabledPlatforms = enabled
            return .init(id: preset, title: preset.title, configuration: recipe)
        }
        var notes = service.configurationRecoveryNotes
        let missing = preferred.subtracting(available)
        if !missing.isEmpty {
            notes.append("Saved provider choices include unavailable CLIs: " + AgentPlatform.allCases.filter(missing.contains).map(\.displayName).joined(separator: ", ") + ". Only available CLIs are selected; the saved preference is kept until Apply.")
        }
        return .init(configuration: configuration, hasSavedDraft: hasDraft, previousDraft: previousDraft,
            enabledPlatforms: enabled, preferredPlatforms: preferred, availablePlatforms: available, presets: presets,
            catalog: ModelSpec.catalog(discovered: service.discoveredModels(), custom: configuration.customModels),
            connections: connections.map(AgentMixModConnection.init), installation: try service.installationStatus(),
            savedPresets: try service.loadSavedPresets(),
            nativeSettings: AgentPlatform.allCases.map { AgentMixModNativeSettings.capture(platform: $0, service: service) },
            inspection: try? loadCachedInspection(),
            canRestore: service.canRestore,
            installedMac: AgentMixAppOpening.installedMac(service: service),
            notes: notes)
    }

    private func validateShape(_ request: AgentMixModRequest) throws {
        let valid: Bool
        let noMetadata = request.name == nil && request.presetID == nil && request.refresh == nil
        switch request.action {
        case .saveDraft, .preview:
            valid = request.configuration != nil && request.platforms != nil && request.previewID == nil && noMetadata
        case .savePreset:
            valid = request.configuration != nil && request.platforms != nil && request.previewID == nil && request.name != nil && request.presetID == nil && request.refresh == nil
        case .deletePreset:
            valid = request.presetID != nil && request.configuration == nil && request.platforms == nil && request.previewID == nil && request.name == nil && request.refresh == nil
        case .apply, .uninstall, .restore:
            valid = request.previewID != nil && request.configuration == nil && request.platforms == nil && noMetadata
        case .state: valid = request.configuration == nil && request.previewID == nil && noMetadata
        case .inspect: valid = request.configuration == nil && request.previewID == nil && request.name == nil && request.presetID == nil
        default: valid = request.configuration == nil && request.platforms == nil && request.previewID == nil && noMetadata
        }
        guard valid else { throw ProtocolError("invalidRequest", "Supply only the fields required for this StandMixer action.") }
    }

    private func previewURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func store(_ preview: StoredPreview) throws {
        guard preview.changes.count <= 256, preview.preconditions.count <= 256 else {
            throw ProtocolError("invalidConfiguration", "This plan exceeds StandMixer's bounded preview limit.")
        }
        let data = try Self.encoder().encode(preview)
        guard data.count <= Self.maximumStoredPreviewBytes else {
            throw ProtocolError("invalidConfiguration", "This plan is too large to review safely in StandMixer.")
        }
        try service.privateDirectory(directory)
        try service.files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // The directory is private and only direct UUID.json children qualify.
        let urls = try service.files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard urls.count <= 512 else { throw ProtocolError("io", "StandMixer's preview folder has too many entries. No configuration was changed.") }
        var retained: [(URL, Date)] = []
        for url in urls where url.pathExtension == "json" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            guard let candidate = try? loadFile(url), candidate.expiresAt > now() else {
                try? service.files.removeItem(at: url); continue
            }
            retained.append((url, candidate.createdAt))
        }
        for item in retained.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maximumPreviews - 1) {
            try service.files.removeItem(at: item.0)
        }
        try service.write(data, to: previewURL(preview.id), mode: 0o600)
    }

    private func load(_ id: UUID) throws -> StoredPreview {
        let stored: StoredPreview
        do { stored = try loadFile(previewURL(id)) }
        catch { throw ProtocolError("previewExpired", "This preview is unavailable. Generate and review a fresh preview.") }
        guard stored.id == id, stored.version == 1, stored.expiresAt > now(), stored.createdAt <= now().addingTimeInterval(60),
              stored.expiresAt.timeIntervalSince(stored.createdAt) <= Self.previewLifetime,
              stored.changes.count <= 256, stored.preconditions.count <= 256 else {
            throw ProtocolError("previewExpired", "This preview expired or is invalid. Generate and review a fresh preview.")
        }
        return stored
    }

    private func loadFile(_ url: URL) throws -> StoredPreview {
        // Reuse the core's no-symlink and regular-file check, with a larger
        // aggregate bound because a plan contains several 4 MB source files.
        try service.privateDirectory(directory)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProtocolError("previewExpired", "The private preview is unavailable.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_uid == getuid(),
              information.st_size <= Self.maximumStoredPreviewBytes,
              information.st_mode & mode_t(0o077) == 0 else {
            throw ProtocolError("previewExpired", "The private preview is invalid.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try handle.read(upToCount: Self.maximumStoredPreviewBytes + 1) ?? Data()
        guard data.count <= Self.maximumStoredPreviewBytes else { throw ProtocolError("previewExpired", "The private preview exceeds the size limit.") }
        return try decoder.decode(StoredPreview.self, from: data)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private struct ProtocolError: Error {
        let code: String
        let message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }

    private struct StoredPreview: Codable {
        var version = 1
        var id: UUID
        var kind: String
        var createdAt: Date
        var expiresAt: Date
        var changes: [FileChange]
        var preconditions: [FilePrecondition]
        var configuration: AgentMixConfiguration?
        var platforms: Set<AgentPlatform>
        var installationBefore: String?
        var installationAfter: InstallationReceipt?
        var configurationBefore: String?
        var conflicts: [String]
        var hasInstallation: Bool
        var restoreSource: String?

        init(preview: IntegrationPreview, configurationBefore: String?, now: Date) {
            id = preview.id; kind = "apply"; createdAt = now; expiresAt = now.addingTimeInterval(AgentMixModInterface.previewLifetime)
            changes = preview.changes; preconditions = preview.preconditions
            configuration = preview.appliedConfiguration; platforms = preview.platforms
            installationBefore = preview.installationBefore; self.configurationBefore = configurationBefore
            conflicts = preview.preservedConflicts; hasInstallation = true
        }

        init(uninstall: UninstallPreview, now: Date) {
            id = uninstall.id; kind = "uninstall"; createdAt = now; expiresAt = now.addingTimeInterval(AgentMixModInterface.previewLifetime)
            changes = uninstall.changes; preconditions = uninstall.preconditions; platforms = []
            installationBefore = uninstall.installationBefore; installationAfter = uninstall.installationAfter
            conflicts = uninstall.conflicts; hasInstallation = uninstall.hasInstallation
        }

        init(backup: IntegrationService.Backup, source: String, now: Date) {
            id = UUID(); kind = "restore"; createdAt = now; expiresAt = now.addingTimeInterval(AgentMixModInterface.previewLifetime)
            changes = backup.records.map { record in
                .init(path: record.change.path, before: record.change.expectedAfter, after: record.change.before ?? "",
                      reason: "Restore this file to its value before the last StandMixer operation.", isDeletion: record.change.before == nil)
            }
            preconditions = []; platforms = []; conflicts = []; hasInstallation = true; restoreSource = source
        }

        var integrationPreview: IntegrationPreview {
            var preview = IntegrationPreview(id: id, createdAt: createdAt, changes: changes, preconditions: preconditions,
                                             appliedConfiguration: configuration, platforms: platforms, preservedConflicts: conflicts)
            preview.installationBefore = installationBefore
            return preview
        }

        var uninstallPreview: UninstallPreview {
            var preview = UninstallPreview(id: id, changes: changes, conflicts: conflicts,
                                           hasInstallation: hasInstallation, preconditions: preconditions)
            preview.installationBefore = installationBefore; preview.installationAfter = installationAfter
            return preview
        }

        var review: AgentMixModPreview {
            .init(id: id, kind: kind, createdAt: createdAt, expiresAt: expiresAt,
                  changes: changes.map(AgentMixModFileChange.init), conflicts: conflicts,
                  hasInstallation: hasInstallation, changedFiles: changes.filter(\.isChanged).count)
        }
    }
}
