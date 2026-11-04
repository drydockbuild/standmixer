import Foundation
import XCTest
@testable import AgentMixCore

final class StandMixerCompatibilityTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("standmixer-compat-\(UUID().uuidString)")
        service = .init(home: root, environment: [:], metadataOnlyDiscovery: true)
        try service.saveConfiguration(.defaults)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func legacySetup() throws -> (URL, String) {
        let skill = service.legacySkillURL(.codex)
        let content = "<!-- \(ConfigEdits.ownership) -->\n# AgentMix\nOld controls.\n"
        let guide = service.legacyGuideURL(.codex)
        let guideContent = "<!-- \(ConfigEdits.ownership) -->\nExisting exact external recipes.\n"
        try service.privateDirectory(guide.deletingLastPathComponent())
        try service.write(Data(content.utf8), to: skill, mode: 0o600)
        try service.write(Data(guideContent.utf8), to: guide, mode: 0o600)
        XCTAssertEqual(service.recordPlatform(skill), .codex)
        XCTAssertEqual(service.recordPlatform(guide), .codex)
        XCTAssertEqual(service.recordKind(skill), .artifact)
        XCTAssertEqual(service.recordKind(guide), .artifact)
        let receipt = InstallationReceipt(configuration: .defaults, platforms: [.codex], records: [
            .init(path: skill.path, platform: .codex, kind: .artifact, before: nil, after: content, fields: [], canRestoreNative: false),
            .init(path: guide.path, platform: .codex, kind: .artifact, before: nil, after: guideContent, fields: [], canRestoreNative: false)])
        try service.write(JSONEncoder().encode(receipt), to: service.installationURL, mode: 0o600)
        return (skill, content)
    }

    func testControlOnlyAliasRetirementPreservesDifferentDraftAppliedRecipeAndRecovery() throws {
        let (legacy, original) = try legacySetup()
        var draft = AgentMixConfiguration.defaults
        let codex = try XCTUnwrap(draft.profiles.firstIndex { $0.platform == .codex })
        let review = try XCTUnwrap(draft.profiles[codex].routes.firstIndex { $0.category == .review })
        draft.profiles[codex].routes[review].modelID = "gpt-6-astra"
        try service.saveConfiguration(draft)
        let preset = try service.savePreset(name: "My saved mix", configuration: .preset(.fast, availablePlatforms: [.codex]))
        let applied = try XCTUnwrap(service.loadInstallation(service.installationText())).configuration
        XCTAssertEqual(applied?.profile(for: .codex)?.route(for: .review)?.modelID, "claude-opus-5-5")
        let guideBefore = try service.readText(service.legacyGuideURL(.codex))
        let preview = try service.previewCommands(platforms: [.codex])
        XCTAssertNil(preview.appliedConfiguration)
        XCTAssertTrue(preview.changes.allSatisfy { $0.path == legacy.path || $0.path == service.skillURL(.codex).path })
        XCTAssertTrue(preview.changes.contains { $0.path == legacy.path && $0.isDeletion })
        _ = try service.apply(preview: preview)
        XCTAssertEqual(service.applicationSupport.standardizedFileURL.path, root.appendingPathComponent("Library/Application Support/AgentMix").standardizedFileURL.path)
        XCTAssertEqual(try service.loadConfiguration(), draft)
        XCTAssertEqual(try service.loadSavedPresets(), [preset])
        XCTAssertEqual(try service.readText(service.legacyGuideURL(.codex)), guideBefore)
        XCTAssertNil(try service.readText(legacy))
        XCTAssertNil(try service.readText(service.externalWorkerGuideURL(.codex)))
        let receipt = try XCTUnwrap(service.loadInstallation(service.installationText()))
        XCTAssertFalse(receipt.records.contains { $0.path == legacy.path })
        XCTAssertEqual(receipt.configuration, applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.appendingPathComponent("config.toml").path))
        _ = try service.restoreLast()
        XCTAssertEqual(try service.readText(legacy), original)
        XCTAssertEqual(try service.loadConfiguration(), draft)
        XCTAssertEqual(try service.loadSavedPresets(), [preset])
        XCTAssertEqual(try service.loadInstallation(service.installationText())?.configuration, applied)
    }

    func testModifiedLegacySkillIsPreservedWithoutDuplicatingItsInstructions() throws {
        let (legacy, source) = try legacySetup()
        let modified = source + "Personal changes.\n"
        try service.write(Data(modified.utf8), to: legacy, mode: 0o600)
        let preview = try service.previewCommands(platforms: [.codex])
        XCTAssertTrue(preview.preservedConflicts.contains { $0.contains(legacy.path) })
        _ = try service.apply(preview: preview)
        XCTAssertEqual(try service.readText(legacy), modified)
        XCTAssertTrue(try XCTUnwrap(service.readText(service.skillURL(.codex))).contains("name: standmixer"))
    }

    func testUnprovenOrLinkedLegacyFilesAreNotRetired() throws {
        let (legacy, _) = try legacySetup()
        let other = root.appendingPathComponent("other-command")
        try FileManager.default.linkItem(at: legacy, to: other)
        let linked = try service.previewCommands(platforms: [.codex])
        XCTAssertFalse(linked.changes.contains { $0.path == legacy.path })
        XCTAssertTrue(linked.preservedConflicts.contains { $0.contains(legacy.path) })
        try FileManager.default.removeItem(at: other)
        try FileManager.default.removeItem(at: service.installationURL)
        let unproven = try service.previewCommands(platforms: [.codex])
        XCTAssertFalse(unproven.changes.contains { $0.path == legacy.path })
        XCTAssertTrue(unproven.preservedConflicts.contains { $0.contains(legacy.path) })
    }
}
