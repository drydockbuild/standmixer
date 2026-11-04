import Foundation
import XCTest
@testable import AgentMixCore

final class IntegrationTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var service: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("agentmix-tests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = IntegrationService(home: home, applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult private func write(_ relative: String, _ text: String) throws -> URL {
        let path = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    func testMixedDefaultsKeepNativeCoordinators() throws {
        let defaults = AgentMixConfiguration.preset(.fast, availablePlatforms: Set(AgentPlatform.allCases))
        XCTAssertEqual(WorkCategory.allCases.count, 7)
        XCTAssertEqual(defaults.profile(for: .codex)?.route(for: .coordinator)?.modelID, "auto")
        XCTAssertEqual(defaults.profile(for: .claude)?.route(for: .coordinator)?.modelID, "auto")
        for profile in defaults.profiles {
            XCTAssertTrue(profile.routes.contains { $0.modelID.hasPrefix("gpt-") })
            XCTAssertTrue(profile.routes.contains { $0.modelID.hasPrefix("claude-") })
            XCTAssertNotNil(profile.route(for: .ui))
        }
    }

    func testPreviewDoesNotWriteAgentSettings() throws {
        let preview = try service.preview(configuration: .defaults)
        XCTAssertFalse(preview.changes.isEmpty)
        for file in preview.changes {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.path)
        }
    }

    func testApplyPreservesUnrelatedSettingsAndRestoreIsByteExact() throws {
        let codex = "# keep this comment\nmodel = \"old-model\"\nmodel_reasoning_effort = \"low\"\n\n[features]\nweb_search = false\n[example]\nmodel = \"nested-model\"\n"
        let claude = "{\n  \"model\": \"opus\",\n  \"permissions\": {\"deny\": [\"Bash(rm *)\"]},\n  \"theme\": \"dark\"\n}\n"
        let instructions = "# My existing preferences\n\nKeep my wording, spacing, and punctuation.\n"
        let codexURL = try write(".codex/config.toml", codex)
        let claudeURL = try write(".claude/settings.json", claude)
        let instructionsURL = try write(".codex/AGENTS.md", instructions)
        let preview = try service.preview(configuration: pinnedControllers())
        let result = try service.apply(preview: preview)
        XCTAssertGreaterThan(result.changedFiles, 2)
        XCTAssertTrue(service.canRestore)
        let newCodex = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertTrue(newCodex.contains("# keep this comment"))
        XCTAssertTrue(newCodex.contains("model = \"nested-model\""))
        XCTAssertTrue(newCodex.contains("web_search = false"))
        let newClaude = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        XCTAssertEqual(newClaude["theme"] as? String, "dark")
        XCTAssertNotNil(newClaude["permissions"])
        XCTAssertTrue(try String(contentsOf: instructionsURL, encoding: .utf8).hasPrefix(instructions))
        _ = try service.restoreLast()
        XCTAssertEqual(try String(contentsOf: codexURL, encoding: .utf8), codex)
        XCTAssertEqual(try String(contentsOf: claudeURL, encoding: .utf8), claude)
        XCTAssertEqual(try String(contentsOf: instructionsURL, encoding: .utf8), instructions)
        for file in preview.changes where file.before == nil {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.path)
        }
    }

    func testStalePreviewRefusesAllWrites() throws {
        let configURL = try write(".codex/config.toml", "model = \"old\"\n")
        let preview = try service.preview(configuration: pinnedControllers())
        let externallyChanged = "model = \"changed-by-other-app\"\n"
        try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.apply(preview: preview))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), externallyChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    func testStaleUnchangedTargetRefusesOtherPreviewWrites() throws {
        let configURL = try write(".codex/config.toml", "model = \"gpt-6.1-sol\"\n")
        let preview = try service.preview(configuration: pinnedControllers())
        let config = try XCTUnwrap(preview.changes.first { $0.path == configURL.path })
        XCTAssertFalse(config.isChanged)
        XCTAssertTrue(preview.changes.contains(where: \.isChanged))
        let externallyChanged = "model = \"changed-after-preview\"\n"
        try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.apply(preview: preview))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), externallyChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        XCTAssertFalse(service.canRestore)
    }

    func testNoChangePreviewStillRefusesStaleTarget() throws {
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers()))
        let preview = try service.preview(configuration: pinnedControllers())
        XCTAssertTrue(preview.changes.allSatisfy { !$0.isChanged })
        let configURL = home.appendingPathComponent(".codex/config.toml")
        let externallyChanged = "model = \"changed-after-preview\"\n"
        try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.apply(preview: preview))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), externallyChanged)
    }

    func testRestoreRefusesToClobberChangesMadeAfterApply() throws {
        let preview = try service.preview(configuration: pinnedControllers())
        _ = try service.apply(preview: preview)
        let configURL = home.appendingPathComponent(".codex/config.toml")
        let externallyChanged = (try String(contentsOf: configURL, encoding: .utf8)) + "\n# external change\n"
        try externallyChanged.write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.restoreLast())
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), externallyChanged)
    }

    func testFixedUnsupportedEffortIsRejected() throws {
        var config = AgentMixConfiguration.defaults
        let index = try XCTUnwrap(config.profiles.firstIndex { $0.platform == .codex })
        let route = try XCTUnwrap(config.profiles[index].routes.firstIndex { $0.category == .mechanical })
        config.profiles[index].routes[route].effort = .fixed("ultra")
        XCTAssertThrowsError(try service.preview(configuration: config))
    }

    func testInvertedEffortRangeIsRejected() throws {
        var config = AgentMixConfiguration.defaults
        config.profiles[0].routes[0].effort = .range(minimum: "high", maximum: "low")
        XCTAssertThrowsError(try service.preview(configuration: config))
    }

    func testBothHarnessesGenerateDirectOppositeProviderRecipes() throws {
        var configuration = AgentMixConfiguration.preset(.fast, availablePlatforms: Set(AgentPlatform.allCases))
        let codexIndex = try XCTUnwrap(configuration.profiles.firstIndex { $0.platform == .codex })
        let visualIndex = try XCTUnwrap(configuration.profiles[codexIndex].routes.firstIndex { $0.category == .ui })
        configuration.profiles[codexIndex].routes[visualIndex].modelID = "claude-haiku-5-5"
        let preview = try service.preview(configuration: configuration)
        let codexUI = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") })
        XCTAssertFalse(codexUI.after.contains("model = \"gpt-6-luna\""))
        XCTAssertTrue(codexUI.after.contains("claude-haiku-5-5"))
        XCTAssertTrue(codexUI.after.contains("--model"))
        let claudeReview = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".claude/skills/standmixer/references/external-workers.md") })
        XCTAssertFalse(claudeReview.after.contains("model: claude-haiku-5-5"))
        XCTAssertTrue(claudeReview.after.contains("gpt-6.1-sol"))
    }

    func testBothRoutingProfilesAreRequired() {
        var config = AgentMixConfiguration.defaults
        config.profiles.removeLast()
        XCTAssertThrowsError(try service.preview(configuration: config))
    }

    func testConfigurationPersistsBothProfilesAndEffortPolicy() throws {
        var config = AgentMixConfiguration.defaults
        config.profiles[0].routes[2].effort = .range(minimum: "medium", maximum: "ultra")
        config.profiles[1].routes[2].additionalAgents = [.init(modelID: "claude-opus-5-5", effort: .fixed("high"))]
        config.profiles[1].routes[2].resultMode = .user
        try service.saveConfiguration(config)
        XCTAssertEqual(try service.loadConfiguration(), config)
    }
}
