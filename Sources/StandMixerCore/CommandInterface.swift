import Foundation

public struct StandMixerCommandResponse: Sendable {
    public var text: String
    public var exitCode: Int32
    public var openSettings: Bool
    public init(_ text: String, exitCode: Int32 = 0, openSettings: Bool = false) {
        self.text = text; self.exitCode = exitCode; self.openSettings = openSettings
    }
}

/// Headless, no-inference controls used by the installed skills and the Mac app executable.
public enum StandMixerCommandInterface {
    public static func run(arguments: [String], service: IntegrationService,
                           availablePlatforms: Set<AgentPlatform>? = nil) async -> StandMixerCommandResponse {
        let verb = arguments.first ?? "status"
        let tail = Array(arguments.dropFirst())
        if ["check-claude", "connect-claude", "logout-claude"].contains(verb.lowercased()) {
            let logout = verb.lowercased() == "logout-claude"
            if logout {
                guard tail.isEmpty || tail == ["--yes"] else {
                    return .init("Use standmixer logout-claude, or add --yes to confirm logout.", exitCode: 2)
                }
                guard tail == ["--yes"] else {
                    return .init("Sign out of the Claude Code profile used by StandMixer for Codex. Other Claude Code sessions sharing that profile may need to sign in again. StandMixer keeps the profile for reconnecting with another account.\nTo sign out: standmixer logout-claude --yes")
                }
            } else {
                guard tail.isEmpty else { return .init("Use standmixer \(verb) without additional arguments.", exitCode: 2) }
            }
            do {
                let connection = StandMixerClaudeConnectionService(service: service)
                let report: StandMixerClaudeConnectionReport
                if logout { report = try await connection.logout() }
                else if verb.lowercased() == "connect-claude" { report = try await connection.connect() }
                else { report = try await connection.check() }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
                let succeeded = logout ? report.state == .signInRequired : report.state == .connected
                return .init(String(decoding: try encoder.encode(report), as: UTF8.self), exitCode: succeeded ? 0 : 1)
            } catch is CancellationError { return .init("Claude connection cancelled.", exitCode: 130) }
            catch {
                if logout { return .init("Claude logout could not complete. Sign-in status is unknown. Recheck the connection in StandMixer.", exitCode: 1) }
                return .init("Claude connection could not be checked. Open Connect Claude for Codex in StandMixer.", exitCode: 1)
            }
        }
        if verb.lowercased() == "resolve-cli" {
            guard tail.count == 1, let platform = AgentPlatform(rawValue: tail[0]) else {
                return .init("Usage: standmixer resolve-cli <claude|codex>", exitCode: 2)
            }
            do { return .init(try await service.resolveCLI(platform).path) }
            catch { return .init("StandMixer: \(error.localizedDescription)", exitCode: 1) }
        }
        guard tail.isEmpty || tail == ["--yes"] else {
            return .init("Use one command, optionally followed by --yes.\n\n" + help, exitCode: 2)
        }
        let confirmed = tail == ["--yes"]
        do {
            switch verb.lowercased() {
            case "help", "--help", "-h": return .init(help)
            case "status", "doctor": return .init(try statusText(service.installationStatus()))
            case "settings", "open": return .init("Opening StandMixer settings.", openSettings: true)
            case "install-mac":
                let result = try await StandMixerMacInstaller.install(service: service)
                return .init(result.message)
            case "install":
                let platforms = try await enabledPlatforms(availablePlatforms, service: service)
                guard !platforms.isEmpty else {
                    return .init("No installed harness is enabled. Open StandMixer settings to check the connections and enabled tools.", exitCode: 1)
                }
                let preview = try service.previewCommands(platforms: platforms)
                guard confirmed else {
                    return .init("Install StandMixer commands only; no model defaults change.\n" + filePlan(preview.changes) + conflictText(preview.preservedConflicts) + "\nTo install: standmixer install --yes")
                }
                let result = try service.apply(preview: preview)
                return .init(result.message + "\nCommands installed. Existing model defaults were kept.")
            case "uninstall":
                let preview = try service.previewUninstall()
                let plan = uninstallText(preview)
                guard confirmed else { return .init(plan) }
                guard preview.hasInstallation else { return .init(plan) }
                let result = try service.uninstall(preview: preview)
                return .init(result.message + conflictText(preview.conflicts) + "\nThe Mac app and recovery backups remain.")
            case "fast", "optimized", "high":
                let preset = StandMixerPreset.allCases.first { $0.rawValue.lowercased() == verb.lowercased() }!
                let platforms = try await enabledPlatforms(availablePlatforms, service: service)
                guard !platforms.isEmpty else {
                    return .init("No installed harness is enabled. Open StandMixer settings to check the connections and enabled tools.", exitCode: 1)
                }
                let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: platforms)
                let preview = try service.preview(configuration: configuration, platforms: platforms)
                var text = preset.title + "\n" + table(configuration, platforms: platforms)
                if platforms.count == 1 { text += "\nOnly using \(platforms.first!.displayName); using native models.\n" }
                text += filePlan(preview.changes)
                guard confirmed else {
                    return .init(text + conflictText(preview.preservedConflicts) + "\nTo apply: standmixer \(verb.lowercased()) --yes\nOr open StandMixer for full file diffs.")
                }
                let result = try service.apply(preview: preview)
                return .init(text + "\n" + result.message)
            default: return .init("Unknown StandMixer command: \(verb)\n\n" + help, exitCode: 2)
            }
        } catch {
            return .init("StandMixer: \(error.localizedDescription)", exitCode: 1)
        }
    }

    public static let help = """
    StandMixer
      status                 Show what is applied (default; no agents launched).
      resolve-cli <claude|codex>  Print the freshly verified CLI path; no inference.
      check-claude            Check the Claude connection used by Codex; no model call.
      connect-claude          Connect Claude for Codex through the official browser login.
      logout-claude           Preview signing out of the shared Claude Code profile; add --yes.
      run-claude -- -p ...    Launch an explicit Claude worker with that same connection.
      fast | optimized | high  Preview a preset; add --yes to apply it.
      settings               Open settings in the invoking harness.
      install-mac            Build and open the optional Mac app locally.
      update [--mac]         Update plugins and source; optionally rebuild the Mac app.
      install                Preview installing commands without applying a preset.
      uninstall              Preview restoring your original settings.
      uninstall --yes        Remove StandMixer's integration and restore safely.

    Claude Code: /standmixer [command]
    Codex: $standmixer [command], or select StandMixer from the skill picker.
    Controller Auto keeps the model selected in your chat; it creates no extra agent.
    Apply takes effect in new agent sessions. Uninstall keeps the optional app and backups.
    """

    private static func enabledPlatforms(_ available: Set<AgentPlatform>?, service: IntegrationService) async throws -> Set<AgentPlatform> {
        let detected: Set<AgentPlatform>
        if let available { detected = available }
        else { detected = Set(await service.detect().filter(\.isInstalled).map(\.platform)) }
        let enabled = try service.loadConfiguration().enabledPlatforms ?? detected
        return detected.intersection(enabled)
    }

    public static func statusText(_ status: InstallationStatus) -> String {
        var text = "StandMixer — " + status.summary + "\n"
        if let configuration = status.appliedConfiguration {
            if let preset = matchingPreset(configuration, platforms: status.installedPlatforms) { text += "Preset: \(preset.title)\n" }
            else { text += "Preset: Custom\n" }
            text += table(configuration, platforms: status.installedPlatforms)
            if status.state != .applied { text += "\nThe table is the last applied recipe; current files differ or could not be verified.\n" }
        }
        if !status.details.isEmpty { text += "\n" + status.details.map { "• " + $0 }.joined(separator: "\n") + "\n" }
        if !status.hasInstallation { text += "\nChoose Fast, Optimized, or High-quality in StandMixer and apply it to install the routing and commands.\n" }
        text += "\nFile checks verify setup, not live model execution. Use a fresh session after applying."
        return text
    }

    public static func matchingPreset(_ configuration: StandMixerConfiguration, platforms: Set<AgentPlatform>) -> StandMixerPreset? {
        StandMixerPreset.allCases.first { preset in
            let candidate = StandMixerConfiguration.preset(preset, availablePlatforms: platforms)
            return !platforms.isEmpty && platforms.allSatisfy { platform in
                guard let draft = configuration.profile(for: platform), let template = candidate.profile(for: platform) else { return false }
                return WorkCategory.allCases.allSatisfy { category in
                    guard let stored = draft.route(for: category), let expected = template.route(for: category),
                          stored.inheritsModel == expected.inheritsModel, stored.inheritsEffort == expected.inheritsEffort,
                          stored.inheritsTeam == expected.inheritsTeam,
                          let lhs = draft.effectiveRoute(for: category), let rhs = template.effectiveRoute(for: category) else { return false }
                    return sameRoute(lhs, rhs)
                }
            }
        }
    }

    // Editor identity and dormant controls do not make the active recipe custom.
    private static func sameRoute(_ lhs: Route, _ rhs: Route) -> Bool {
        func sameEffort(_ a: EffortPolicy, _ b: EffortPolicy) -> Bool {
            guard a.mode == b.mode else { return false }
            switch a.mode {
            case .auto: return true
            case .fixed: return a.value == b.value
            case .range: return a.minimum == b.minimum && a.maximum == b.maximum
            }
        }
        func sameAssignments(_ a: [AgentAssignment], _ b: [AgentAssignment]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.modelID == $1.modelID && sameEffort($0.effort, $1.effort) }
        }
        guard lhs.modelID == rhs.modelID, sameEffort(lhs.effort, rhs.effort),
              sameAssignments(lhs.additionalAgents, rhs.additionalAgents),
              sameAssignments(lhs.stuckEscalation, rhs.stuckEscalation) else { return false }
        guard !lhs.additionalAgents.isEmpty else { return true }
        return lhs.teamMode == rhs.teamMode && lhs.resultMode == rhs.resultMode
            && (lhs.resultMode != .ai || lhs.judgeModelID == rhs.judgeModelID)
    }

    private static func table(_ configuration: StandMixerConfiguration, platforms: Set<AgentPlatform>) -> String {
        let catalog = Dictionary(uniqueKeysWithValues: ModelSpec.catalog(custom: configuration.customModels).map { ($0.id, $0) })
        let columns = AgentPlatform.allCases.filter(platforms.contains)
        var lines = ["| Task | " + columns.map(\.displayName).joined(separator: " | ") + " |",
                     "| --- | " + columns.map { _ in "---" }.joined(separator: " | ") + " |"]
        for category in WorkCategory.allCases {
            let cells = columns.map { platform -> String in
                guard let route = configuration.profile(for: platform)?.effectiveRoute(for: category) else { return "Unknown" }
                if route.isAutoController { return "Auto — current model" }
                func label(_ worker: AgentAssignment) -> String {
                    let model = catalog[worker.modelID]
                    let via = model.map { $0.platform == platform ? "" : " via " + $0.platform.displayName } ?? ""
                    let effort = worker.effort.mode == .auto ? "" : " (\(worker.effort.description))"
                    return (model?.label ?? worker.modelID).replacingOccurrences(of: "|", with: "\\|") + via + effort
                }
                let workers = [AgentAssignment(modelID: route.modelID, effort: route.effort)] + route.additionalAgents
                let primary = workers.map(label).joined(separator: "; ")
                guard !route.stuckEscalation.isEmpty else { return primary }
                return primary + " · When stuck: " + route.stuckEscalation.map(label).joined(separator: " → ")
            }
            let task = category.parent == nil ? category.title : "↳ \(category.title)"
            lines.append("| \(task) | " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\nEffort follows the caller unless shown.\n"
    }

    private static func uninstallText(_ preview: UninstallPreview) -> String {
        guard preview.hasInstallation else { return "StandMixer is not applied. There are no managed settings to remove.\nThe Mac app and saved drafts remain." }
        return "Remove StandMixer\n" + filePlan(preview.changes) + conflictText(preview.conflicts)
            + "\nTo remove: standmixer uninstall --yes\nThe Mac app and recovery backups remain."
    }

    private static func filePlan(_ changes: [FileChange]) -> String {
        let changed = changes.filter(\.isChanged)
        guard !changed.isEmpty else { return "\nNo file changes.\n" }
        return "\n" + changed.map { "\($0.isDeletion ? "Remove" : $0.before == nil ? "Create" : "Update") \($0.path) — \($0.reason)" }.joined(separator: "\n") + "\n"
    }

    private static func conflictText(_ conflicts: [String]) -> String {
        conflicts.isEmpty ? "" : "\nKept because they changed outside StandMixer:\n" + conflicts.map { "• " + $0 }.joined(separator: "\n") + "\n"
    }
}
