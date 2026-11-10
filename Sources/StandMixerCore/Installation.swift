import Darwin
import Foundation

public enum InstallationState: String, Codable, Sendable {
    case notInstalled, applied, drifted, unknown
}

/// Describes files on disk from successful Apply operations, never the saved draft or a runtime probe.
public struct InstallationStatus: Codable, Sendable {
    public var state: InstallationState
    public var summary: String
    public var details: [String]
    public var appliedConfiguration: StandMixerConfiguration?
    public var installedPlatforms: Set<AgentPlatform>
    public var hasInstallation: Bool
    public var isInstalled: Bool { hasInstallation }
    public init(state: InstallationState, summary: String, details: [String] = [], appliedConfiguration: StandMixerConfiguration? = nil, installedPlatforms: Set<AgentPlatform> = [], hasInstallation: Bool = false) {
        self.state = state; self.summary = summary; self.details = details
        self.appliedConfiguration = appliedConfiguration; self.installedPlatforms = installedPlatforms; self.hasInstallation = hasInstallation
    }
}

public struct UninstallPreview: Identifiable, Sendable {
    public var id: UUID
    public var changes: [FileChange]
    public var conflicts: [String]
    public var hasInstallation: Bool
    public var preconditions: [FilePrecondition]
    var installationBefore: String?
    var installationAfter: InstallationReceipt?
    public init(id: UUID = UUID(), changes: [FileChange], conflicts: [String] = [], hasInstallation: Bool, preconditions: [FilePrecondition] = []) {
        self.id = id; self.changes = changes; self.conflicts = conflicts; self.hasInstallation = hasInstallation; self.preconditions = preconditions
    }
}

struct NativeSettingLease: Codable, Sendable, Equatable {
    var path: [String]
    var before: String?
    var after: String?
    var createdContainers: [[String]]
}
struct InstallationRecord: Codable, Sendable, Equatable {
    enum Kind: String, Codable { case native, routing, artifact }
    var path: String
    var platform: AgentPlatform
    var kind: Kind
    var before: String?
    var after: String?
    var fields: [NativeSettingLease]
    var canRestoreNative: Bool
}
struct InstallationReceipt: Codable, Sendable, Equatable {
    var version = 1
    var configuration: StandMixerConfiguration?
    var platforms: Set<AgentPlatform>
    var records: [InstallationRecord]
    var cleanupStarted: Bool?
}

extension ConfigEdits {
    static func nativeValue(_ source: String?, platform: AgentPlatform, path: [String]) throws -> String? {
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if platform == .codex {
            var result: String?
            _ = try codexEditing(source, requested: [:]) { key, value in
                if path == [key] { result = tomlString(value) }
            }
            return result
        }
        return try JSONSourceEditor(source).value(at: path).map(canonicalJSON)
    }

    static func settingNative(_ source: String, platform: AgentPlatform, path: [String], value: String?) throws -> String {
        if platform == .codex {
            let decoded = try value.map { raw -> String in
                guard let string = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as? String else { throw StandMixerError.invalid("Original Codex setting is not a string.") }
                return string
            }
            return try codexEditing(source, requested: [path[0]: decoded])
        }
        return try JSONSourceEditor(source).settingRaw(path, to: value)
    }

    static func canonicalJSON(_ raw: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return raw }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func routingBlock(_ source: String) throws -> String? {
        let starts = source.components(separatedBy: begin).count - 1
        let ends = source.components(separatedBy: end).count - 1
        guard starts == ends, starts <= 1 else { throw StandMixerError.invalid("Routing instructions contain duplicate or incomplete StandMixer markers.") }
        guard starts == 1 else { return nil }
        guard let start = source.range(of: begin), let finish = source.range(of: end), start.lowerBound < finish.lowerBound else { throw StandMixerError.invalid("StandMixer routing markers are reversed.") }
        return String(source[start.lowerBound..<finish.upperBound])
    }

    static func removingRouting(_ source: String, original: String?) throws -> String {
        guard try routingBlock(source) != nil, let start = source.range(of: begin), let finish = source.range(of: end) else { return source }
        var prefix = String(source[..<start.lowerBound])
        var suffix = String(source[finish.upperBound...])
        // Strip only the separator and terminator we added when first appending
        // a block. Changes elsewhere in the instructions are retained verbatim.
        if let original, try routingBlock(original) == nil {
            let separator = original.isEmpty || original.hasSuffix("\n\n") ? "" : original.hasSuffix("\n") ? "\n" : "\n\n"
            if prefix == original + separator { prefix = original }
            if suffix.hasPrefix("\n") { suffix.removeFirst() }
        } else if original == nil {
            if suffix.hasPrefix("\n") { suffix.removeFirst() }
        }
        return prefix + suffix
    }
}

extension IntegrationService {
    var installationURL: URL { applicationSupport.appendingPathComponent("installation.json") }

    func installationText() throws -> String? { try readText(installationURL) }
    func encodeInstallation(_ receipt: InstallationReceipt) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(receipt), as: UTF8.self)
    }
    func loadInstallation(_ text: String?) throws -> InstallationReceipt? {
        guard let text else { return nil }
        let receipt = try JSONDecoder().decode(InstallationReceipt.self, from: Data(text.utf8))
        guard receipt.version == 1, receipt.records.count <= 4096,
              Set(receipt.records.map(\.path)).count == receipt.records.count else { throw StandMixerError.invalid("StandMixer installation record is not a supported, bounded record. No files were changed.") }
        for record in receipt.records {
            let url = URL(fileURLWithPath: record.path)
            try checkAllowed(url, checkSymlinks: false)
            guard record.kind == recordKind(url), record.platform == recordPlatform(url) else { throw StandMixerError.invalid("StandMixer installation record contains an unexpected file type.") }
            for field in record.fields {
                let valid = record.platform == .codex ? (field.path == ["model"] || field.path == ["model_reasoning_effort"]) : (field.path == ["model"] || (field.path.count == 3 && field.path[0] == "modelSettings" && field.path[2] == "effortLevel"))
                guard record.kind == .native, valid, field.createdContainers.allSatisfy({ $0 == ["modelSettings"] || ($0.count == 2 && $0[0] == "modelSettings" && field.path.count == 3 && $0[1] == field.path[1]) }) else { throw StandMixerError.invalid("StandMixer installation record contains an unexpected native setting.") }
            }
        }
        return receipt
    }
    func recordPlatform(_ url: URL) -> AgentPlatform {
        let path = url.standardizedFileURL.path
        return controlURLs(.codex).contains(where: { $0.path == path }) || path.hasPrefix(codexHome.standardizedFileURL.path + "/") ? .codex : .claude
    }
    func recordKind(_ url: URL) -> InstallationRecord.Kind {
        if AgentPlatform.allCases.contains(where: { controlURLs($0).contains(where: { $0.path == url.standardizedFileURL.path }) }) { return .artifact }
        if url.path == codexHome.appendingPathComponent("config.toml").path || url.path == claudeHome.appendingPathComponent("settings.json").path { return .native }
        return url.pathExtension == "toml" || url.deletingLastPathComponent().lastPathComponent == "agents" || url.lastPathComponent == "SKILL.md" ? .artifact : .routing
    }
    func skillURL(_ platform: AgentPlatform) -> URL {
        (platform == .codex ? home.appendingPathComponent(".agents") : claudeHome).appendingPathComponent("skills/standmixer/SKILL.md")
    }

    func controlURLs(_ platform: AgentPlatform) -> [URL] {
        [skillURL(platform), externalWorkerGuideURL(platform)].map(\.standardizedFileURL)
    }

    func externalWorkerGuideURL(_ platform: AgentPlatform) -> URL {
        skillURL(platform).deletingLastPathComponent().appendingPathComponent("references/external-workers.md")
    }

    /// A marker finds a candidate; only a recorded exact installed version
    /// permits retirement. Never adopt modified obsolete content as managed.
    func expectedArtifactContents(installationBefore: String?) throws -> [String: String] {
        let receipt = try loadInstallation(installationBefore)
        var expected: [String: String] = [:]
        let recordedPaths = Set(receipt?.records.map(\.path) ?? [])
        for record in receipt?.records ?? [] where record.kind == .artifact {
            if let after = record.after { expected[record.path] = after }
        }
        if let source = try readText(receiptURL), let backup = try? JSONDecoder().decode(Backup.self, from: Data(source.utf8)) {
            for record in backup.records where !recordedPaths.contains(record.change.path) {
                if let after = record.change.expectedAfter { expected[record.change.path] = after }
            }
        }
        return expected
    }

    func updatedInstallation(for preview: IntegrationPreview, previous: InstallationReceipt?) throws -> InstallationReceipt {
        var receipt = try previous ?? adoptingLegacyInstallation()
        let legacyPlatforms = Set(receipt.records.filter { $0.kind == .native && !$0.canRestoreNative }.map(\.platform))
        for change in preview.changes {
            let url = URL(fileURLWithPath: change.path)
            if change.isDeletion {
                receipt.records.removeAll { $0.path == change.path }
                continue
            }
            let platform = recordPlatform(url)
            let index = receipt.records.firstIndex { $0.path == change.path }
            var record = index.map { receipt.records[$0] } ?? .init(path: change.path, platform: platform, kind: recordKind(url), before: change.before, after: change.expectedAfter, fields: [], canRestoreNative: !legacyPlatforms.contains(platform))
            record.after = change.expectedAfter
            if record.kind == .native {
                var paths = [["model"]]
                if platform == .codex { paths.append(["model_reasoning_effort"]) }
                else if let raw = try ConfigEdits.nativeValue(change.after, platform: platform, path: ["model"]), let model = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as? String {
                    paths.append(["modelSettings", model, "effortLevel"])
                }
                for path in paths {
                    let after = try ConfigEdits.nativeValue(change.after, platform: platform, path: path)
                    if let field = record.fields.firstIndex(where: { $0.path == path }) { record.fields[field].after = after }
                    else {
                        var containers: [[String]] = []
                        if platform == .claude, path.count > 1 {
                            for count in 1..<path.count {
                                let parent = Array(path.prefix(count))
                                if try ConfigEdits.nativeValue(change.before, platform: platform, path: parent) == nil,
                                   try ConfigEdits.nativeValue(change.after, platform: platform, path: parent) != nil { containers.append(parent) }
                            }
                        }
                        record.fields.append(.init(path: path, before: try ConfigEdits.nativeValue(change.before, platform: platform, path: path), after: after, createdContainers: containers))
                    }
                }
            }
            if let index { receipt.records[index] = record } else { receipt.records.append(record) }
        }
        receipt.platforms.formUnion(preview.platforms)
        if let configuration = preview.appliedConfiguration {
            if receipt.platforms.isSubset(of: preview.platforms) { receipt.cleanupStarted = nil }
            if var current = receipt.configuration {
                current.profiles.removeAll { preview.platforms.contains($0.platform) }
                current.profiles.append(contentsOf: configuration.profiles.filter { preview.platforms.contains($0.platform) })
                current.customModels = configuration.customModels
                receipt.configuration = current
            } else {
                var selected = configuration
                selected.profiles = configuration.profiles.filter { preview.platforms.contains($0.platform) }
                receipt.configuration = selected
            }
        }
        return receipt
    }

    /// A commands-only installation must not hide integrations left by an older
    /// StandMixer. Import only bounded, visibly owned targets and mark native
    /// settings as unrestorable; their pre-StandMixer values are unavailable.
    func adoptingLegacyInstallation() throws -> InstallationReceipt {
        let legacy = try previewLegacyUninstall()
        var records: [InstallationRecord] = []
        var platforms = Set<AgentPlatform>()
        for condition in legacy.preconditions {
            guard let source = condition.before else { continue }
            let url = URL(fileURLWithPath: condition.path)
            let kind = recordKind(url)
            let owned = kind == .routing ? source.contains(ConfigEdits.begin) || source.contains(ConfigEdits.end) : source.contains(ConfigEdits.ownership)
            guard owned else { continue }
            let platform = recordPlatform(url)
            platforms.insert(platform)
            // Only the old backup's exact artifact versions can be deleted. A
            // marker alone identifies a candidate, but never proves unchanged.
            let knownArtifact = legacy.changes.contains { $0.path == condition.path && $0.isDeletion }
            records.append(.init(path: condition.path, platform: platform, kind: kind, before: nil, after: kind == .artifact && !knownArtifact ? nil : source, fields: [], canRestoreNative: false))
        }
        let guidePaths = Set(AgentPlatform.allCases.flatMap { [externalWorkerGuideURL($0).path] })
        let unknownNativePlatforms = Set(records.filter { $0.kind == .routing || ($0.kind == .artifact && URL(fileURLWithPath: $0.path).lastPathComponent != "SKILL.md" && !guidePaths.contains($0.path)) }.map(\.platform))
        for platform in unknownNativePlatforms {
            let url = (platform == .codex ? codexHome : claudeHome).appendingPathComponent(platform == .codex ? "config.toml" : "settings.json")
            records.append(.init(path: url.path, platform: platform, kind: .native, before: nil, after: nil, fields: [], canRestoreNative: false))
        }
        return .init(configuration: nil, platforms: platforms, records: records)
    }

    public func previewCommands(platforms: Set<AgentPlatform> = Set(AgentPlatform.allCases)) throws -> IntegrationPreview {
        lock.lock(); defer { lock.unlock() }
        guard !platforms.isEmpty else { throw StandMixerError.invalid("Select at least one agent for the /standmixer command.") }
        let before = try installationText()
        var changes: [FileChange] = []
        let preservedConflicts: [String] = []
        let preconditions: [FilePrecondition] = []
        for platform in AgentPlatform.allCases where platforms.contains(platform) {
            let url = skillURL(platform)
            let source = try readText(url)
            if let source, !source.contains(ConfigEdits.ownership) { throw StandMixerError.conflict("\(url.path) already exists and is not owned by StandMixer. Keep or rename it before installing /standmixer.") }
            changes.append(.init(path: url.path, before: source, after: StandMixerCommandSkill.contents(platform: platform, executableURL: executableURL, applicationSupport: applicationSupport), reason: "Install /standmixer commands without applying a routing preset."))
        }
        var preview = IntegrationPreview(changes: changes, preconditions: preconditions, platforms: platforms, preservedConflicts: preservedConflicts)
        preview.installationBefore = before
        return preview
    }

    public func installationStatus() throws -> InstallationStatus {
        lock.lock(); defer { lock.unlock() }
        guard let receipt = try loadInstallation(installationText()) else {
            let legacy = try previewLegacyUninstall()
            return .init(state: legacy.hasInstallation ? .unknown : .notInstalled,
                         summary: legacy.hasInstallation ? "Existing StandMixer setup; original settings are unknown." : "StandMixer has not been applied.",
                         details: legacy.hasInstallation ? ["No persistent installation baseline is available. Native model and effort settings cannot be restored automatically.", "Runtime routing has not been verified."] : ["Saved drafts are not active routing."], hasInstallation: legacy.hasInstallation)
        }
        var drift: [String] = []
        for record in receipt.records {
            // Auto releases native-default management without restoring an
            // invented current-chat model. Keep historical leases only for
            // an explicit uninstall; user changes are no longer drift.
            if record.kind == .native,
               receipt.configuration?.profile(for: record.platform)?.route(for: .coordinator)?.isAutoController == true { continue }
            let current = try readText(URL(fileURLWithPath: record.path))
            if record.kind == .native {
                for field in record.fields where try ConfigEdits.nativeValue(current, platform: record.platform, path: field.path) != field.after { drift.append("\(record.path): \(field.path.joined(separator: ".")) changed since Apply.") }
            } else if record.kind == .routing {
                if try current.flatMap({ try ConfigEdits.routingBlock($0) }) != record.after.flatMap({ try ConfigEdits.routingBlock($0) }) { drift.append("\(record.path): routing block changed since Apply.") }
            } else if current != record.after { drift.append("\(record.path): managed file changed since Apply.") }
        }
        let unknownOriginals = receipt.records.contains { $0.kind == .native && !$0.canRestoreNative }
        let incomplete = receipt.cleanupStarted == true
        let state: InstallationState = !drift.isEmpty || incomplete ? .drifted : unknownOriginals ? .unknown : .applied
        let summary = incomplete ? "StandMixer uninstall is incomplete; some settings or files were kept." : !drift.isEmpty ? "StandMixer files changed since Apply." : unknownOriginals ? "StandMixer files are installed; original native settings are unknown." : receipt.configuration == nil ? "Commands installed; no routing preset has been applied." : "StandMixer configuration is applied."
        var details = drift
        if unknownOriginals { details.append("Native settings predate the original baseline and cannot be restored automatically.") }
        if incomplete { details.append("Uninstall removed the safe managed sections. Review the remaining conflicts before completing cleanup.") }
        return .init(state: state, summary: summary,
                     details: details + ["Configuration on disk only; runtime routing has not been verified."], appliedConfiguration: receipt.configuration, installedPlatforms: receipt.platforms, hasInstallation: !receipt.records.isEmpty)
    }

    public func previewUninstall() throws -> UninstallPreview {
        lock.lock(); defer { lock.unlock() }
        let text = try installationText()
        guard var receipt = try loadInstallation(text) else { return try previewLegacyUninstall() }
        let hadInstallation = !receipt.records.isEmpty
        var changes: [FileChange] = []
        var conflicts: [String] = []
        var conditions: [FilePrecondition] = []
        var remaining: [InstallationRecord] = []
        for var record in receipt.records {
            let url = URL(fileURLWithPath: record.path)
            let source: String?
            do { source = try readText(url) }
            catch {
                conflicts.append("\(record.path): \(error.localizedDescription) Skipped.")
                remaining.append(record); continue
            }
            conditions.append(.init(path: record.path, before: source))
            guard let source else { continue }
            if record.kind == .artifact {
                if source == record.after, source.contains(ConfigEdits.ownership) {
                    changes.append(.init(path: record.path, before: source, after: "", reason: "Remove the unchanged StandMixer worker or control skill.", isDeletion: true))
                } else { conflicts.append("\(record.path): changed or unowned file; kept."); remaining.append(record) }
            } else if record.kind == .routing {
                do {
                    let currentBlock = try ConfigEdits.routingBlock(source)
                    let expectedBlock = try record.after.flatMap { try ConfigEdits.routingBlock($0) }
                    if let currentBlock, currentBlock != expectedBlock {
                        conflicts.append("\(record.path): StandMixer routing block changed since Apply; kept.")
                        remaining.append(record)
                        continue
                    }
                    let after = try ConfigEdits.removingRouting(source, original: record.before)
                    if after != source { changes.append(.init(path: record.path, before: source, after: after, reason: "Remove only the marked StandMixer routing block.", isDeletion: record.before == nil && after.isEmpty)) }
                } catch { conflicts.append("\(record.path): \(error.localizedDescription) Kept."); remaining.append(record) }
            } else if !record.canRestoreNative {
                conflicts.append("\(record.path): original native settings predate the installation record; kept. Review model and effort manually.")
                remaining.append(record)
            } else {
                var after = source
                var skipped: [NativeSettingLease] = []
                var prune: [[String]] = []
                for field in record.fields {
                    do {
                        let current = try ConfigEdits.nativeValue(after, platform: record.platform, path: field.path)
                        if current == field.after {
                            after = try ConfigEdits.settingNative(after, platform: record.platform, path: field.path, value: field.before)
                            prune.append(contentsOf: field.createdContainers)
                        } else if current != field.before {
                            conflicts.append("\(record.path): \(field.path.joined(separator: ".")) changed since Apply; kept.")
                            skipped.append(field)
                        }
                    } catch { conflicts.append("\(record.path): \(field.path.joined(separator: ".")): \(error.localizedDescription) Kept."); skipped.append(field) }
                }
                if record.platform == .claude {
                    for path in prune.sorted(by: { $0.count > $1.count }) {
                        if try ConfigEdits.nativeValue(after, platform: .claude, path: path) == "{}" { after = try ConfigEdits.settingNative(after, platform: .claude, path: path, value: nil) }
                    }
                }
                let empty = record.platform == .codex ? after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : ConfigEdits.canonicalJSON(after) == "{}"
                if after != source || (record.before == nil && empty) {
                    changes.append(.init(path: record.path, before: source, after: after, reason: "Restore original model and effort fields; preserve other settings and later edits.", isDeletion: record.before == nil && empty))
                }
                if !skipped.isEmpty { record.fields = skipped; record.after = after; remaining.append(record) }
            }
        }
        receipt.records = remaining
        receipt.cleanupStarted = !remaining.isEmpty
        receipt.platforms = Set(remaining.map(\.platform))
        var preview = UninstallPreview(changes: changes, conflicts: conflicts, hasInstallation: hadInstallation, preconditions: conditions)
        preview.installationBefore = text
        preview.installationAfter = remaining.isEmpty ? nil : receipt
        return preview
    }

    /// Legacy cleanup never guesses pre-StandMixer model or effort values.
    func previewLegacyUninstall() throws -> UninstallPreview {
        var changes: [FileChange] = [], conflicts: [String] = []
        var conditions: [FilePrecondition] = []
        let legacyBackup = try readText(receiptURL).flatMap { try JSONDecoder().decode(Backup.self, from: Data($0.utf8)) }
        let expected = Dictionary(uniqueKeysWithValues: (legacyBackup?.records ?? []).map { ($0.change.path, $0.change.expectedAfter) })
        var hasInstallation = false
        for platform in AgentPlatform.allCases {
            let root = platform == .codex ? codexHome : claudeHome
            let instructionNames = platform == .codex ? ["AGENTS.md", "AGENTS.override.md"] : ["CLAUDE.md"]
            for name in instructionNames {
                let url = root.appendingPathComponent(name)
                let source = try readText(url)
                conditions.append(.init(path: url.path, before: source))
                guard let source, source.contains(ConfigEdits.begin) || source.contains(ConfigEdits.end) else { continue }
                hasInstallation = true
                do {
                    let after = try ConfigEdits.removingRouting(source, original: nil)
                    changes.append(.init(path: url.path, before: source, after: after, reason: "Remove the legacy StandMixer routing block; preserve other instructions."))
                } catch { conflicts.append("\(url.path): \(error.localizedDescription) Kept.") }
            }
            for url in try artifactURLs(platform) + controlURLs(platform) {
                guard let source = try readText(url), source.contains(ConfigEdits.ownership) else { continue }
                hasInstallation = true; conditions.append(.init(path: url.path, before: source))
                if let wrapped = expected[url.path], let owned = wrapped, owned == source {
                    changes.append(.init(path: url.path, before: source, after: "", reason: "Remove a legacy StandMixer file that exactly matches its backup record.", isDeletion: true))
                } else { conflicts.append("\(url.path): no unchanged owned version can be established; kept.") }
            }
        }
        if hasInstallation { conflicts.append("No original installation baseline is available. Native model and effort settings are kept; review them manually.") }
        return .init(changes: changes, conflicts: conflicts, hasInstallation: hasInstallation, preconditions: conditions)
    }

    public func uninstall(preview: UninstallPreview) throws -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        try acquireOperationLock(); defer { releaseOperationLock() }
        guard try installationText() == preview.installationBefore else { throw StandMixerError.conflict("StandMixer installation changed after preview. Review a fresh uninstall preview.") }
        // Reuse the same backed-up transaction and stale checks as Apply, without
        // interpreting cleanup as a new configuration installation.
        var operation = IntegrationPreview(id: preview.id, changes: preview.changes, preconditions: preview.preconditions)
        operation.installationBefore = preview.installationBefore
        let result = try performTransaction(preview: operation, installationAfter: preview.installationAfter.map(encodeInstallation), trackInstallation: true)
        return .init(message: preview.conflicts.isEmpty ? "StandMixer was uninstalled. Original model and effort settings were restored where unchanged. Start new CLI sessions." : "Removed \(result.changedFiles) files or managed sections. \(preview.conflicts.count) conflicts were kept for review.", changedFiles: result.changedFiles)
    }
}
