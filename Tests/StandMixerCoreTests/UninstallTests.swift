import Foundation
import XCTest
@testable import StandMixerCore

final class UninstallTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-uninstall-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = IntegrationService(home: home, applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func write(_ relative: String, _ text: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private func read(_ relative: String) throws -> String { try String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8) }
    private func json() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read(".claude/settings.json").utf8)) as? [String: Any]) }
    private func fixed(_ value: String) -> StandMixerConfiguration {
        pinnedControllers(effort: .fixed(value))
    }

    func testUnchangedReceiptOrderingPreservesPreviousRestorePoint() throws {
        _ = try service.apply(preview: service.preview(configuration: .defaults))
        let original = try XCTUnwrap(service.installationText())
        let backup = try XCTUnwrap(service.readText(service.receiptURL))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let platforms = try XCTUnwrap(object["platforms"] as? [String])
        object["platforms"] = Array(platforms.reversed())
        let reordered = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertNotEqual(original, reordered)
        let preview = try service.previewCommands()
        let result = try service.performTransaction(preview: preview, installationAfter: reordered, trackInstallation: true)
        XCTAssertEqual(result.changedFiles, 0)
        XCTAssertEqual(try service.readText(service.receiptURL), backup)
        XCTAssertEqual(try service.installationText(), original)
        XCTAssertTrue(service.canRestore)
        // A review remains an exact snapshot even when a concurrent edit only
        // changes serialization; semantic no-op detection does not relax it.
        try service.write(Data(reordered.utf8), to: service.installationURL, mode: 0o600)
        XCTAssertThrowsError(try service.apply(preview: preview))
    }

    func testDraftsDoNotClaimAppliedAndCommandsInstallSeparately() throws {
        try service.saveConfiguration(.preset(.high, availablePlatforms: [.codex, .claude]))
        XCTAssertEqual(try service.installationStatus().state, .notInstalled)
        let preview = try service.previewCommands()
        XCTAssertEqual(preview.changes.count, 2)
        XCTAssertTrue(preview.changes.contains { $0.path == home.appendingPathComponent(".agents/skills/standmixer/SKILL.md").path })
        _ = try service.apply(preview: preview)
        let status = try service.installationStatus()
        XCTAssertEqual(status.state, .applied)
        XCTAssertNil(status.appliedConfiguration)
        XCTAssertTrue(status.summary.contains("no routing preset"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
        let cleanup = try service.previewUninstall()
        XCTAssertEqual(cleanup.changes.count, 2)
        XCTAssertTrue(cleanup.conflicts.isEmpty)
        _ = try service.uninstall(preview: cleanup)
        XCTAssertEqual(try service.installationStatus().state, .notInstalled)
    }

    func testMultipleAppliesRestoreFirstNativeValuesAndEveryTouchedClaudeModel() throws {
        let codex = "# My preferences\nmodel = 'original-codex'\nmodel_reasoning_effort = 'medium'\n[features]\nkeep = true\n"
        let claude = """
        {"model":"original-claude","theme":"dark","modelSettings":{"claude-opus-5-5":{"effortLevel":"low","extra":true},"claude-haiku-5-5":{"effortLevel":"high"}}}
        """
        try write(".codex/config.toml", codex)
        try write(".claude/settings.json", claude)
        try write(".codex/AGENTS.md", "# My instructions\n")
        _ = try service.apply(preview: service.preview(configuration: fixed("high")))
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers(.preset(.fast, availablePlatforms: [.codex, .claude]), codex: "gpt-6-luna", claude: "claude-haiku-5-5")))
        try write(".codex/config.toml", read(".codex/config.toml") + "\n# Added after Apply\n")
        try write(".codex/AGENTS.md", read(".codex/AGENTS.md") + "\nNew preference stays.\n")
        var settings = try json(); settings["theme"] = "light"
        try write(".claude/settings.json", String(decoding: JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        let preview = try service.previewUninstall()
        XCTAssertTrue(preview.conflicts.isEmpty, preview.conflicts.joined(separator: "\n"))
        _ = try service.uninstall(preview: preview)
        let restored = try read(".codex/config.toml")
        XCTAssertTrue(restored.contains("model = 'original-codex'"))
        XCTAssertEqual(try ConfigEdits.nativeValue(restored, platform: .codex, path: ["model_reasoning_effort"]), ConfigEdits.tomlString("medium"))
        XCTAssertTrue(restored.contains("# Added after Apply"))
        XCTAssertTrue(restored.contains("keep = true"))
        let restoredJSON = try json()
        XCTAssertEqual(restoredJSON["model"] as? String, "original-claude")
        XCTAssertEqual(restoredJSON["theme"] as? String, "light")
        let models = try XCTUnwrap(restoredJSON["modelSettings"] as? [String: [String: Any]])
        XCTAssertEqual(models["claude-opus-5-5"]?["effortLevel"] as? String, "low")
        XCTAssertEqual(models["claude-haiku-5-5"]?["effortLevel"] as? String, "high")
        XCTAssertEqual(models["claude-opus-5-5"]?["extra"] as? Bool, true)
        XCTAssertEqual(try read(".codex/AGENTS.md"), "# My instructions\n\nNew preference stays.\n")
        XCTAssertEqual(try service.installationStatus().state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/standmixer/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/standmixer/SKILL.md").path))
    }

    func testLaterNativeEditsAndModifiedArtifactsAreKeptWhileOtherFieldsRestore() throws {
        try write(".codex/config.toml", "model = 'before'\nmodel_reasoning_effort = 'low'\n")
        try write(".claude/settings.json", "{\"model\":\"before\",\"modelSettings\":{\"claude-opus-5-5\":{\"effortLevel\":\"low\"}}}\n")
        _ = try service.apply(preview: service.preview(configuration: fixed("high")))
        try write(".codex/config.toml", read(".codex/config.toml").replacingOccurrences(of: "'gpt-6.1-sol'", with: "'user-choice'"))
        let claude = try ConfigEdits.claudeSettings(read(".claude/settings.json"), model: "claude-opus-5-5", effort: "medium")
        try write(".claude/settings.json", claude)
        let skill = ".agents/skills/standmixer/SKILL.md"
        try write(skill, read(skill) + "\nPersonal edit\n")
        let worker = ".claude/agents/standmixer-claude-opus-5-5-auto.md"
        try write(worker, read(worker) + "\nPersonal worker edit\n")
        let preview = try service.previewUninstall()
        XCTAssertEqual(preview.conflicts.count, 4, preview.conflicts.joined(separator: "\n"))
        _ = try service.uninstall(preview: preview)
        XCTAssertTrue(try read(".codex/config.toml").contains("'user-choice'"))
        XCTAssertTrue(try read(".codex/config.toml").contains("model_reasoning_effort = 'low'"))
        XCTAssertEqual(try json()["model"] as? String, "before")
        let models = try XCTUnwrap(try json()["modelSettings"] as? [String: [String: Any]])
        XCTAssertEqual(models["claude-opus-5-5"]?["effortLevel"] as? String, "medium")
        XCTAssertTrue(try read(skill).contains("Personal edit"))
        XCTAssertTrue(try read(worker).contains("Personal worker edit"))
        XCTAssertEqual(try service.installationStatus().state, .drifted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md").path))
    }


    func testEditedRoutingBlockIsKeptAndOutsidePreferencesRemain() throws {
        try write(".codex/AGENTS.md", "My original instructions\n")
        _ = try service.apply(preview: service.preview(configuration: .defaults))
        let changed = try read(".codex/AGENTS.md").replacingOccurrences(of: "BEGIN STANDMIXER ROUTING -->\n", with: "BEGIN STANDMIXER ROUTING -->\nMy edit inside the managed block.\n") + "\nMy later instructions.\n"
        try write(".codex/AGENTS.md", changed)
        let preview = try service.previewUninstall()
        XCTAssertTrue(preview.conflicts.contains { $0.contains("routing block changed") })
        XCTAssertFalse(preview.changes.contains { $0.path.hasSuffix(".codex/AGENTS.md") })
        _ = try service.uninstall(preview: preview)
        XCTAssertEqual(try read(".codex/AGENTS.md"), changed)
    }

    func testStaleUninstallRefusesAllWritesIncludingUnchangedInputs() throws {
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers()))
        let preview = try service.previewUninstall()
        let skill = ".agents/skills/standmixer/SKILL.md"
        let source = try read(skill)
        try write(skill, source + "\nChanged during review\n")
        XCTAssertThrowsError(try service.uninstall(preview: preview))
        XCTAssertTrue(try read(".codex/AGENTS.md").contains(ConfigEdits.begin))
        XCTAssertTrue(try read(".codex/config.toml").contains("gpt-6.1-sol"))
        XCTAssertEqual(try read(skill), source + "\nChanged during review\n")
    }

    func testAutoNeverClaimsContainersAddedLaterByUser() throws {
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers()))
        let path = ".claude/settings.json"
        var settings = try json()
        settings["modelSettings"] = ["claude-opus-5-5": [:]] as [String: [String: String]]
        try write(path, String(decoding: JSONSerialization.data(withJSONObject: settings), as: UTF8.self))
        let preview = try service.previewUninstall()
        XCTAssertTrue(preview.conflicts.isEmpty)
        _ = try service.uninstall(preview: preview)
        let result = try json()
        let containers = try XCTUnwrap(result["modelSettings"] as? [String: Any])
        XCTAssertNotNil(containers["claude-opus-5-5"])
    }

    func testCommandOnlyAdoptionDoesNotHideLegacyRoutingOrInventOriginalDefaults() throws {
        try write(".codex/config.toml", "model = 'legacy-default'\n")
        try write(".codex/AGENTS.md", "Mine\n\n\(ConfigEdits.begin)\nLegacy policy\n\(ConfigEdits.end)\n")
        try write(".codex/agents/standmixer-old.toml", "# \(ConfigEdits.ownership)\nunknown version\n")
        _ = try service.apply(preview: service.previewCommands())
        XCTAssertNil(try service.installationStatus().appliedConfiguration)
        let first = try service.previewUninstall()
        XCTAssertTrue(first.changes.contains { $0.path.hasSuffix(".codex/AGENTS.md") })
        XCTAssertTrue(first.conflicts.contains { $0.contains("standmixer-old.toml") })
        _ = try service.apply(preview: service.preview(configuration: .defaults, platforms: [.codex]))
        let cleanup = try service.previewUninstall()
        XCTAssertTrue(cleanup.conflicts.contains { $0.contains("original native settings") })
        _ = try service.uninstall(preview: cleanup)
        XCTAssertEqual(try service.installationStatus().state, .drifted)
        XCTAssertTrue(try service.installationStatus().summary.contains("incomplete"))
        XCTAssertTrue(try read(".codex/config.toml").contains("legacy-default"))
    }

    func testUnownedSkillCollisionAndSymlinksNeverOverwriteUserContent() throws {
        let skill = try write(".agents/skills/standmixer/SKILL.md", "My own command")
        XCTAssertThrowsError(try service.previewCommands())
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "My own command")
        try FileManager.default.removeItem(at: skill)
        let target = root.appendingPathComponent("private.txt")
        try "Private content".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: target)
        XCTAssertThrowsError(try service.previewCommands())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Private content")
    }

    func testSymlinkAddedAfterApplyIsAConflictWhileOtherOwnedFilesCanBeRemoved() throws {
        _ = try service.apply(preview: service.previewCommands())
        let skill = home.appendingPathComponent(".agents/skills/standmixer/SKILL.md")
        try FileManager.default.removeItem(at: skill)
        let target = root.appendingPathComponent("private.txt")
        try "Private content".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: skill, withDestinationURL: target)
        let preview = try service.previewUninstall()
        XCTAssertEqual(preview.conflicts.count, 1)
        XCTAssertEqual(preview.changes.count, 1)
        _ = try service.uninstall(preview: preview)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Private content")
    }

    func testFreshReinstallCapturesNewBaselineAndUndoRestoresInstallationState() throws {
        try write(".codex/config.toml", "model = 'first-baseline'\n")
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers(), platforms: [.codex]))
        let first = try service.installationStatus().appliedConfiguration
        _ = try service.apply(preview: service.preview(configuration: .preset(.fast, availablePlatforms: [.codex]), platforms: [.codex]))
        _ = try service.restoreLast()
        XCTAssertEqual(try service.installationStatus().appliedConfiguration, first)
        _ = try service.uninstall(preview: service.previewUninstall())
        XCTAssertTrue(try read(".codex/config.toml").contains("first-baseline"))
        try write(".codex/config.toml", "model = 'second-baseline'\n")
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers(), platforms: [.codex]))
        _ = try service.uninstall(preview: service.previewUninstall())
        XCTAssertTrue(try read(".codex/config.toml").contains("second-baseline"))
    }

    func testLegacyInstallationCleansMarkedInstructionsWithoutGuessingNativeDefaults() throws {
        try write(".codex/config.toml", "model = 'unknown-before-standmixer'\n")
        try write(".codex/AGENTS.md", "My instructions\n\n\(ConfigEdits.begin)\nOld StandMixer policy\n\(ConfigEdits.end)\n")
        try write(".codex/agents/standmixer-old.toml", "# \(ConfigEdits.ownership)\nlegacy body\n")
        XCTAssertEqual(try service.installationStatus().state, .unknown)
        let preview = try service.previewUninstall()
        XCTAssertTrue(preview.conflicts.contains { $0.contains("No original installation baseline") })
        XCTAssertTrue(preview.conflicts.contains { $0.contains("no unchanged owned version") })
        _ = try service.uninstall(preview: preview)
        XCTAssertEqual(try read(".codex/config.toml"), "model = 'unknown-before-standmixer'\n")
        XCTAssertTrue(try read(".codex/agents/standmixer-old.toml").contains("legacy body"))
        XCTAssertFalse(try read(".codex/AGENTS.md").contains(ConfigEdits.begin))
    }

    func testUninstallCoversPreviouslyInstalledHarnessEvenWhenCurrentDraftDisablesIt() throws {
        _ = try service.apply(preview: service.preview(configuration: .defaults))
        var draft = StandMixerConfiguration.defaults; draft.enabledPlatforms = [.codex]
        try service.saveConfiguration(draft)
        let preview = try service.previewUninstall()
        XCTAssertTrue(preview.changes.contains { $0.path.hasPrefix(service.claudeHome.path + "/") })
        XCTAssertTrue(preview.changes.contains { $0.path.hasPrefix(service.codexHome.path + "/") })
        _ = try service.uninstall(preview: preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.appendingPathComponent("config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.appendingPathComponent("settings.json").path))
        XCTAssertEqual(try service.installationStatus().state, .notInstalled)
    }
}
