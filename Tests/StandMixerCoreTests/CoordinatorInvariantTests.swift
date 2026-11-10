import Foundation
import XCTest
@testable import StandMixerCore

final class CoordinatorInvariantTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-native-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func replacingCoordinator(_ modelID: String, for platform: AgentPlatform,
                                      in configuration: StandMixerConfiguration = .defaults) -> StandMixerConfiguration {
        var result = configuration
        let profile = result.profiles.firstIndex { $0.platform == platform }!
        let route = result.profiles[profile].routes.firstIndex { $0.category == .coordinator }!
        result.profiles[profile].routes[route].modelID = modelID
        result.profiles[profile].routes[route].effort = .auto
        return result
    }

    func testEveryPresetKeepsNativeCoordinatorForEveryAvailability() throws {
        for preset in StandMixerPreset.allCases {
            for platforms in [Set<AgentPlatform>([.codex]), [.claude], [.codex, .claude]] {
                let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: platforms)
                XCTAssertNoThrow(try configuration.validateNativeCoordinators(catalog: ModelSpec.builtIn))
            }
        }
    }

    func testSonnet55CanBeSavedAsClaudeCoordinatorAndUsedAcrossWorkerProviders() throws {
        let sonnet = try XCTUnwrap(ModelSpec.catalog().first { $0.id == "claude-sonnet-5-5" })
        XCTAssertEqual(sonnet.label, "Sonnet 5.5")
        XCTAssertEqual(sonnet.platform, .claude)
        var configuration = replacingCoordinator(sonnet.id, for: .claude)
        for platform in AgentPlatform.allCases {
            let profile = try XCTUnwrap(configuration.profiles.firstIndex { $0.platform == platform })
            let visual = try XCTUnwrap(configuration.profiles[profile].routes.firstIndex { $0.category == .ui })
            configuration.profiles[profile].routes[visual].modelID = sonnet.id
        }
        try service.saveConfiguration(configuration)
        XCTAssertEqual(try service.loadConfiguration(), configuration)
        let preview = try service.preview(configuration: configuration)
        XCTAssertTrue(preview.changes.contains { $0.path.hasSuffix(".claude/agents/standmixer-claude-sonnet-5-5-auto.md") && $0.after.contains("model: claude-sonnet-5-5") })
        XCTAssertTrue(preview.changes.contains { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") && $0.after.contains("--model 'claude-sonnet-5-5'") })
        XCTAssertThrowsError(try service.preview(configuration: replacingCoordinator(sonnet.id, for: .codex), platforms: [.codex]))
    }

    func testForeignAndUndefinedCoordinatorsCannotBePreviewedOrSaved() throws {
        try service.saveConfiguration(.defaults)
        for (platform, modelID) in [(AgentPlatform.codex, "claude-opus-5-5"), (.claude, "gpt-6.1-sol"), (.codex, "undefined-native-model"), (.claude, "undefined-native-model")] {
            let invalid = replacingCoordinator(modelID, for: platform)
            XCTAssertThrowsError(try service.preview(configuration: invalid, platforms: [platform]))
            XCTAssertThrowsError(try service.saveConfiguration(invalid))
            XCTAssertThrowsError(try service.savePreviousDraft(invalid))
            XCTAssertThrowsError(try service.savePreset(name: "Invalid", configuration: invalid))
        }
        XCTAssertEqual(try service.loadConfiguration(), .defaults)
    }

    func testCustomEntryCannotRelabelKnownProviderButNewNativeIDsRemainUsable() throws {
        var spoofed = replacingCoordinator("claude-opus-5-5", for: .codex)
        spoofed.customModels = [.init(id: "claude-opus-5-5", label: "Pretend native", platform: .codex)]
        XCTAssertEqual(ModelSpec.catalog(custom: spoofed.customModels).first { $0.id == "claude-opus-5-5" }?.platform, .claude)
        XCTAssertThrowsError(try service.preview(configuration: spoofed, platforms: [.codex]))
        XCTAssertThrowsError(try service.saveConfiguration(spoofed))

        let discovered = ModelSpec(id: "exact-installed-id", label: "Installed", platform: .claude)
        let conflicting = ModelSpec(id: discovered.id, label: "Wrong", platform: .codex)
        XCTAssertEqual(ModelSpec.catalog(discovered: [discovered], custom: [conflicting]).first { $0.id == discovered.id }?.platform, .claude)

        for platform in AgentPlatform.allCases {
            let id = "my-explicit-\(platform.rawValue)-alias"
            var native = replacingCoordinator(id, for: platform)
            native.customModels = [.init(id: id, label: "Native custom", platform: platform)]
            XCTAssertNoThrow(try service.preview(configuration: native, platforms: [platform]))
            try service.saveConfiguration(native)
            XCTAssertEqual(try service.loadConfiguration(), native)
        }
    }

    func testLegacyDraftsAndPresetsRepairOnlyCoordinatorAndReportRecovery() throws {
        var legacy = replacingCoordinator("gpt-6.1-sol", for: .claude, in: .preset(.high, availablePlatforms: [.codex, .claude]))
        legacy.enabledPlatforms = [.claude]
        legacy.customModels = [.init(id: "my-worker", label: "My worker", platform: .codex)]
        let support = service.applicationSupport
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(legacy).write(to: support.appendingPathComponent("configuration.json"))
        try encoder.encode(legacy).write(to: support.appendingPathComponent("previous-draft.json"))
        let preset = SavedRoutingPreset(name: "Kept preset", configuration: legacy)
        try encoder.encode([preset]).write(to: support.appendingPathComponent("presets.json"))

        let recovered = try service.loadConfiguration()
        XCTAssertEqual(recovered.profile(for: .claude)?.route(for: .coordinator), StandMixerConfiguration.defaults.profile(for: .claude)?.route(for: .coordinator))
        for category in WorkCategory.allCases where category != .coordinator {
            XCTAssertEqual(recovered.profile(for: .claude)?.route(for: category), legacy.profile(for: .claude)?.route(for: category))
        }
        XCTAssertEqual(recovered.profile(for: .codex), legacy.profile(for: .codex))
        XCTAssertEqual(recovered.customModels, legacy.customModels)
        XCTAssertEqual(recovered.enabledPlatforms, legacy.enabledPlatforms)
        XCTAssertEqual(try service.loadPreviousDraft(), recovered)
        let saved = try XCTUnwrap(service.loadSavedPresets().first)
        XCTAssertEqual(saved.id, preset.id)
        XCTAssertEqual(saved.name, preset.name)
        XCTAssertEqual(saved.configuration, recovered)
        XCTAssertFalse(service.configurationRecoveryNotes.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(StandMixerConfiguration.self, from: Data(contentsOf: support.appendingPathComponent("configuration.json"))), legacy, "Reading a legacy draft must not write it.")
    }

    func testImporterCannotSetForeignCoordinatorThroughSpoofedCustomCatalog() throws {
        var draft = StandMixerConfiguration.defaults
        draft.customModels = [.init(id: "claude-opus-5-5", label: "Wrong provider", platform: .codex)]
        let foreign = AgentImportProposal(platform: .codex, workingDirectory: root.path, routes: [
            .init(category: .coordinator, modelID: "claude-opus-5-5", modelPlatform: .codex, effort: .auto)
        ])
        let imported = AgentImportService(integration: service).merge(proposals: [foreign], into: draft)
        XCTAssertEqual(imported.configuration.profile(for: .codex)?.route(for: .coordinator), draft.profile(for: .codex)?.route(for: .coordinator))
        XCTAssertFalse(imported.notes.isEmpty)
    }
}
