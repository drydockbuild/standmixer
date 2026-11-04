import Foundation
import XCTest
@testable import AgentMixCore

final class CommandInterfaceTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("agentmix-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testDefaultStatusDoesNotMistakeSavedDraftForAppliedRecipeOrCreateFiles() async throws {
        try service.saveConfiguration(.preset(.high, availablePlatforms: [.codex, .claude]))
        let before = try FileManager.default.contentsOfDirectory(atPath: service.applicationSupport.path)
        let result = await AgentMixCommandInterface.run(arguments: [], service: service)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try service.installationStatus().state, .notInstalled)
        XCTAssertFalse(result.text.contains("Preset: StandMixer High"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: service.applicationSupport.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
    }

    func testPresetPreviewIsReadOnlyAndApplyRecordsActualRecipeWithCrossProviderLabels() async throws {
        let preview = await AgentMixCommandInterface.run(arguments: ["fast"], service: service, availablePlatforms: [.codex, .claude])
        XCTAssertEqual(preview.exitCode, 0)
        XCTAssertTrue(preview.text.contains("Terra 6.1"))
        XCTAssertTrue(preview.text.contains("Opus 5.5 via Claude Code"))
        XCTAssertTrue(preview.text.contains("Sol 6.1 via Codex"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
        let apply = await AgentMixCommandInterface.run(arguments: ["fast", "--yes"], service: service, availablePlatforms: [.codex, .claude])
        XCTAssertEqual(apply.exitCode, 0, apply.text)
        let result = await AgentMixCommandInterface.run(arguments: ["status"], service: service)
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertTrue(result.text.contains("Preset: StandMixer Fast"))
        XCTAssertTrue(result.text.contains("not live model execution"))
        XCTAssertFalse(result.text.contains("runtime verified"))
    }

    func testStatusRecognizesPresetAfterEditorChangesOnlyInstanceIDsAndDormantControls() throws {
        var configuration = AgentMixConfiguration.defaults
        for profile in configuration.profiles.indices {
            for route in configuration.profiles[profile].routes.indices {
                if configuration.profiles[profile].routes[route].category != .coordinator {
                    configuration.profiles[profile].routes[route].effort.value = "high"
                }
                for index in configuration.profiles[profile].routes[route].additionalAgents.indices {
                    configuration.profiles[profile].routes[route].additionalAgents[index].id = UUID()
                    configuration.profiles[profile].routes[route].additionalAgents[index].modelPlatform = .claude
                }
                if configuration.profiles[profile].routes[route].additionalAgents.isEmpty {
                    configuration.profiles[profile].routes[route].teamMode = .parallel
                }
            }
        }
        _ = try service.apply(preview: service.preview(configuration: configuration))
        XCTAssertTrue(AgentMixCommandInterface.statusText(try service.installationStatus()).contains("Preset: StandMixer Optimized"))
    }

    func testUninstallRequiresExplicitApplyAndRestoresOriginalSettings() async throws {
        let original = "model = \"my-original-model\"\nmodel_reasoning_effort = \"high\"\n"
        try FileManager.default.createDirectory(at: service.codexHome, withIntermediateDirectories: true)
        let file = service.codexHome.appendingPathComponent("config.toml")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let apply = await AgentMixCommandInterface.run(arguments: ["fast", "--yes"], service: service, availablePlatforms: [.codex])
        XCTAssertEqual(apply.exitCode, 0, apply.text)
        let applied = try String(contentsOf: file, encoding: .utf8)
        let preview = await AgentMixCommandInterface.run(arguments: ["uninstall"], service: service)
        XCTAssertEqual(preview.exitCode, 0, preview.text)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), applied)
        let uninstall = await AgentMixCommandInterface.run(arguments: ["uninstall", "--yes"], service: service)
        XCTAssertEqual(uninstall.exitCode, 0, uninstall.text)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        XCTAssertFalse(try service.installationStatus().hasInstallation)
    }

    func testNativeOnlyPreviewReportsSingleProviderAndDoesNotUseMissingProvider() async {
        let result = await AgentMixCommandInterface.run(arguments: ["fast"], service: service, availablePlatforms: [.codex])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.text.contains("Only using Codex"))
        XCTAssertFalse(result.text.contains("via Claude Code"))
        XCTAssertFalse(result.text.contains(".claude/"))
    }

    func testPresetCommandRespectsDisabledProviderEvenWhenBothCLIsAreDetected() async throws {
        var configuration = AgentMixConfiguration.defaults
        configuration.enabledPlatforms = [.codex]
        try service.saveConfiguration(configuration)
        let result = await AgentMixCommandInterface.run(arguments: ["fast", "--yes"], service: service, availablePlatforms: [.codex, .claude])
        XCTAssertEqual(result.exitCode, 0, result.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
        XCTAssertEqual(try service.installationStatus().installedPlatforms, [.codex])
        XCTAssertFalse(result.text.contains("via Claude Code"))
    }

    func testInstallingCommandsDoesNotApplyADraftOrCreateNativeSettings() async throws {
        let response = await AgentMixCommandInterface.run(arguments: ["install", "--yes"], service: service, availablePlatforms: [.codex, .claude])
        XCTAssertEqual(response.exitCode, 0, response.text)
        let status = try service.installationStatus()
        XCTAssertTrue(status.hasInstallation)
        XCTAssertNil(status.appliedConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.appendingPathComponent("config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.appendingPathComponent("settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.home.appendingPathComponent(".agents/skills/standmixer/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.claudeHome.appendingPathComponent("skills/standmixer/SKILL.md").path))
    }

    func testInvalidArgumentsCannotTriggerMutationAndSettingsOnlyRequestsOpeningApp() async {
        for arguments in [["fast", "--yes", "unexpected"], ["uninstall", "--yess"], ["made-up"]] {
            let response = await AgentMixCommandInterface.run(arguments: arguments, service: service, availablePlatforms: [.codex, .claude])
            XCTAssertEqual(response.exitCode, 2, response.text)
        }
        let response = await AgentMixCommandInterface.run(arguments: ["settings"], service: service)
        XCTAssertTrue(response.openSettings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }
}
