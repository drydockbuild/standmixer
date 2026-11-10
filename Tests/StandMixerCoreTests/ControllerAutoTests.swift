import Foundation
import XCTest
@testable import StandMixerCore

final class ControllerAutoTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-controller-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func nativeURL(_ platform: AgentPlatform) -> URL {
        (platform == .codex ? service.codexHome : service.claudeHome).appendingPathComponent(platform == .codex ? "config.toml" : "settings.json")
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private let codex = "# exact saved native choices\r\nmodel = 'gpt-6.1-terra'\r\nmodel_reasoning_effort = 'ultra' # keep caller setting\r\n[profiles.work]\r\nmodel = 'gpt-6-astra'\r\n"
    private let claude = "{\n  \"model\" : \"fable[1m]\",\n  \"effortLevel\" : \"low\",\n  \"modelSettings\" : {\"fable[1m]\":{\"effortLevel\":\"xhigh\"},\"claude-opus-5-5\":{\"effortLevel\":\"high\"}},\n  \"theme\" : \"dark\"\n}\n"

    func testEveryFactoryPresetUsesAutoForAllAvailabilityCombinationsAndLeavesNativeBytesUntouched() throws {
        try write(codex, to: nativeURL(.codex))
        try write(claude, to: nativeURL(.claude))
        for available in [Set<AgentPlatform>([.codex]), [.claude], [.codex, .claude]] {
            for preset in StandMixerPreset.allCases {
                let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: available)
                for profile in configuration.profiles {
                    let controller = try XCTUnwrap(profile.route(for: .coordinator))
                    XCTAssertTrue(controller.isAutoController)
                    XCTAssertEqual(controller.effort, .auto)
                    XCTAssertTrue(controller.additionalAgents.isEmpty)
                }
                let preview = try service.preview(configuration: configuration, platforms: available)
                XCTAssertFalse(preview.changes.contains { $0.path == nativeURL(.codex).path || $0.path == nativeURL(.claude).path })
                XCTAssertFalse(preview.changes.contains { $0.path.contains("/agents/standmixer-auto") || $0.after.contains("model = \"auto\"") || $0.after.contains("model: auto\n") })
                _ = try service.apply(preview: preview)
                XCTAssertEqual(try read(nativeURL(.codex)), codex)
                XCTAssertEqual(try read(nativeURL(.claude)), claude)
            }
        }
        let receipt = try XCTUnwrap(service.loadInstallation(service.installationText()))
        XCTAssertFalse(receipt.records.contains { $0.kind == .native }, "Auto must never acquire a native-default lease.")
    }

    func testAutoDoesNotCreateOrParseNativeSettingsAndConfigEditorsCannotWriteSentinel() throws {
        let preview = try service.preview(configuration: .defaults)
        _ = try service.apply(preview: preview)
        for platform in AgentPlatform.allCases { XCTAssertFalse(FileManager.default.fileExists(atPath: nativeURL(platform).path)) }
        // Auto has no dependency on parsing a native file it does not manage.
        try write("this is intentionally invalid TOML", to: nativeURL(.codex))
        try write("this is intentionally invalid JSON", to: nativeURL(.claude))
        XCTAssertNoThrow(try service.preview(configuration: .defaults))
        XCTAssertEqual(try ConfigEdits.codexSettings(codex, model: Route.autoControllerModelID, effort: "low"), codex)
        XCTAssertEqual(try ConfigEdits.claudeSettings(claude, model: Route.autoControllerModelID, effort: "low"), claude)
        XCTAssertEqual(try ConfigEdits.claudeSettings(nil, model: Route.autoControllerModelID, effort: nil), "")
    }

    func testExistingSavedNativePinsAndCustomPinsDecodeAndLoadUnchanged() throws {
        var pinned = pinnedControllers(.preset(.high, availablePlatforms: [.codex, .claude]), codex: "my-native-alias", effort: .fixed("high"))
        pinned.customModels = [.init(id: "my-native-alias", label: "My native alias", platform: .codex)]
        let data = try JSONEncoder().encode(pinned)
        let decoded = try JSONDecoder().decode(StandMixerConfiguration.self, from: data)
        XCTAssertEqual(decoded, pinned)
        XCTAssertFalse(try XCTUnwrap(decoded.profile(for: .codex)?.route(for: .coordinator)).isAutoController)
        try service.saveConfiguration(decoded)
        try service.savePreviousDraft(decoded)
        _ = try service.savePreset(name: "Explicit pinned setup", configuration: decoded)
        XCTAssertEqual(try service.loadConfiguration(), pinned)
        XCTAssertEqual(try service.loadPreviousDraft(), pinned)
        XCTAssertEqual(try service.loadSavedPresets().first?.configuration, pinned)
        XCTAssertTrue(service.configurationRecoveryNotes.isEmpty)
        let preview = try service.preview(configuration: pinned)
        XCTAssertTrue(preview.changes.contains { $0.path == nativeURL(.codex).path && $0.after.contains("my-native-alias") })
        let policy = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".codex/AGENTS.md") }).after
        XCTAssertTrue(policy.contains("native default for future sessions"))
        XCTAssertTrue(policy.contains("never re-dispatches an existing chat"))
    }

    func testReservedAutoCannotBecomeConcreteWorkerOrJudgeOrOverrideControllerEffort() throws {
        let fake = ModelSpec(id: "auto", label: "Pretend model", platform: .codex)
        XCTAssertFalse(ModelSpec.catalog(discovered: [fake], custom: [fake]).contains { $0.id == "auto" })
        var reservedCustom = StandMixerConfiguration.defaults
        reservedCustom.customModels = [fake]
        XCTAssertThrowsError(try service.saveConfiguration(reservedCustom))
        for category in WorkCategory.allCases where category != .coordinator {
            var invalid = StandMixerConfiguration.defaults
            let index = invalid.profiles[0].routes.firstIndex { $0.category == category }!
            invalid.customModels = [fake]
            invalid.profiles[0].routes[index].modelID = "auto"
            XCTAssertThrowsError(try service.preview(configuration: invalid, platforms: [.codex]))
        }
        var invalid = StandMixerConfiguration.defaults
        invalid.profiles[0].routes[1].additionalAgents = [.init(modelID: "auto")]
        XCTAssertThrowsError(try service.preview(configuration: invalid, platforms: [.codex]))
        invalid = .defaults
        invalid.profiles[0].routes[2].resultMode = .ai
        invalid.profiles[0].routes[2].judgeModelID = "auto"
        XCTAssertThrowsError(try service.preview(configuration: invalid, platforms: [.codex]))
        invalid = .defaults
        invalid.profiles[0].routes[0].effort = .fixed("low")
        XCTAssertThrowsError(try service.saveConfiguration(invalid))
        XCTAssertThrowsError(try service.preview(configuration: invalid, platforms: [.codex]))
    }

    func testPresetAssignmentsDoNotManufactureReviewOrWorkflowRequirements() throws {
        for available in [Set<AgentPlatform>([.codex]), [.claude], [.codex, .claude]] {
            for preset in StandMixerPreset.allCases {
                let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: available)
                let preview = try service.preview(configuration: configuration, platforms: available)
                for platform in available {
                    let suffix = platform == .codex ? ".codex/AGENTS.md" : ".claude/CLAUDE.md"
                    let policy = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(suffix) }).after
                    XCTAssertTrue(policy.contains("work you already decide is needed"))
                    XCTAssertTrue(policy.contains("Explicitly configured teams apply only when that work is warranted"))
                    XCTAssertTrue(policy.contains("StandMixer itself adds no tasks, reviews, audits, or workflow stages"))
                    XCTAssertFalse(policy.contains("Do not add unconfigured critics"))
                    XCTAssertEqual(policy.components(separatedBy: "StandMixer selects models and effort").count - 1, 1)
                    XCTAssertTrue(policy.contains("- Review & Security:"), "The available review route stays configured; it does not mandate a review.")
                    XCTAssertTrue(policy.contains("Follow the user's, project's, and native harness's instructions"))
                    XCTAssertTrue(policy.contains("A single-model assignment neither requires delegation nor limits the number of workers"))
                    XCTAssertTrue(policy.contains("no extra identity checks"))
                    XCTAssertTrue(policy.contains("Routes select models, not worker personas"))
                    XCTAssertTrue(policy.contains("Give workers the concrete task, only relevant context/files, and actual constraints"))
                    XCTAssertTrue(policy.contains("omit role labels and unrelated narration about StandMixer, presets, or personal budgets"))
                    XCTAssertFalse(policy.contains("Pass the role"))
                    XCTAssertFalse(policy.contains("intensity in each delegation brief"))
                    let hasExternalGuide = preview.changes.contains { $0.path == service.externalWorkerGuideURL(platform).path }
                    XCTAssertEqual(policy.contains("Only when external delegation is warranted, read"), hasExternalGuide)
                    XCTAssertFalse(policy.contains("Caller-to-target mapping:"), "Per-model mechanics stay in the selected worker or on-demand recipe.")
                }
            }
        }
    }

    func testRoutingKeepsCurrentChatAsControllerAndDelegatesOnlyWarrantedCategories() throws {
        let preview = try service.preview(configuration: .preset(.high, availablePlatforms: [.codex, .claude]))
        for suffix in [".codex/AGENTS.md", ".claude/CLAUDE.md"] {
            let policy = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(suffix) }).after
            for guidance in ["current chat model remains the native controller", "Follow the user's, project's, and native harness's instructions", "A single-model assignment neither requires delegation nor limits the number of workers", "multiple warranted workers may use the same selector", "When this category warrants delegation, launch all", "Leave native model and effort settings untouched", "do not launch or hop to a controller model", "original caller's requested or effective reasoning intensity"] {
                XCTAssertTrue(policy.contains(guidance), guidance)
            }
            XCTAssertTrue(policy.contains("- Controller: Auto"))
            XCTAssertFalse(policy.contains("`auto`"))
        }
    }

    func testSwitchingPinToAutoPreservesSavedChoicesAndRetainsBaselineForExplicitCleanup() throws {
        try write(codex, to: nativeURL(.codex))
        try write(claude, to: nativeURL(.claude))
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers(effort: .fixed("high"))))
        let pinnedCodex = try read(nativeURL(.codex))
        let pinnedClaude = try read(nativeURL(.claude))
        let auto = try service.preview(configuration: .defaults)
        XCTAssertFalse(auto.changes.contains { $0.path == nativeURL(.codex).path || $0.path == nativeURL(.claude).path })
        _ = try service.apply(preview: auto)
        XCTAssertEqual(try read(nativeURL(.codex)), pinnedCodex)
        XCTAssertEqual(try read(nativeURL(.claude)), pinnedClaude)
        XCTAssertTrue(try XCTUnwrap(service.installationStatus().appliedConfiguration?.profile(for: .codex)?.route(for: .coordinator)).isAutoController)
        let cleanup = try service.previewUninstall()
        XCTAssertTrue(cleanup.conflicts.isEmpty)
        XCTAssertTrue(cleanup.changes.contains { $0.path == nativeURL(.codex).path })
        _ = try service.uninstall(preview: cleanup)
        XCTAssertEqual(try read(nativeURL(.codex)), codex)
        XCTAssertEqual(try read(nativeURL(.claude)), claude)
    }

    func testNativeChangesAfterReleasingPinToAutoAreUnmanagedAndKept() throws {
        try write(codex, to: nativeURL(.codex))
        _ = try service.apply(preview: service.preview(configuration: pinnedControllers(), platforms: [.codex]))
        _ = try service.apply(preview: service.preview(configuration: .defaults, platforms: [.codex]))
        let userChoice = "model = 'my-new-choice'\nmodel_reasoning_effort = 'max'\n"
        try write(userChoice, to: nativeURL(.codex))
        XCTAssertEqual(try service.installationStatus().state, .applied)
        _ = try service.apply(preview: service.preview(configuration: .defaults, platforms: [.codex]))
        XCTAssertEqual(try read(nativeURL(.codex)), userChoice)
        let cleanup = try service.previewUninstall()
        XCTAssertTrue(cleanup.conflicts.contains { $0.contains("model changed since Apply") })
        _ = try service.uninstall(preview: cleanup)
        XCTAssertEqual(try read(nativeURL(.codex)), userChoice)
    }
}
