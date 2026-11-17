import Foundation
import XCTest
@testable import StandMixerCore

final class CodexModelUpgradeTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("standmixer-model-upgrade-\(UUID().uuidString)")
        service = IntegrationService(home: root.appendingPathComponent("home"),
            applicationSupport: root.appendingPathComponent("support"), environment: [:])
        try FileManager.default.createDirectory(at: service.applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: service.codexHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testEditableDraftsAndNamedPresetReplaceOnlyExactModelReferences() throws {
        let previous = configuration(sol: "gpt-6.1-sol", astra: "gpt-6-astra")
        let expected = configuration(sol: "gpt-6.2-sol", astra: "gpt-6.2-astra")
        let preset = SavedRoutingPreset(name: "Sol 6.1 and Astra 6 test setup", configuration: previous)
        let expectedPreset = SavedRoutingPreset(id: preset.id, name: preset.name, configuration: expected)
        let encoder = JSONEncoder()
        let previousData = try encoder.encode(previous)
        let presetData = try encoder.encode([preset])
        let draftURL = service.applicationSupport.appendingPathComponent("configuration.json")
        let previousDraftURL = service.applicationSupport.appendingPathComponent("previous-draft.json")
        let presetURL = service.applicationSupport.appendingPathComponent("presets.json")
        try previousData.write(to: draftURL)
        try previousData.write(to: previousDraftURL)
        try presetData.write(to: presetURL)

        XCTAssertEqual(try service.loadConfiguration(), expected)
        XCTAssertEqual(try service.loadPreviousDraft(), expected)
        XCTAssertEqual(try service.loadSavedPresets(), [expectedPreset])
        XCTAssertTrue(service.configurationRecoveryNotes.isEmpty, "The upgraded native pin should not be reset to Auto.")
        XCTAssertEqual(try Data(contentsOf: draftURL), previousData)
        XCTAssertEqual(try Data(contentsOf: previousDraftURL), previousData)
        XCTAssertEqual(try Data(contentsOf: presetURL), presetData)

        try service.saveConfiguration(expected)
        try service.savePreviousDraft(expected)
        _ = try service.savePreset(name: preset.name, configuration: expected)
        XCTAssertEqual(try service.loadConfiguration(), expected)
        XCTAssertEqual(try service.loadPreviousDraft(), expected)
        XCTAssertEqual(try service.loadSavedPresets(), [expectedPreset])
    }

    func testInstalledRecordAndNativeBaselineKeepHistoricalModelIDs() throws {
        let previous = configuration(sol: "gpt-6.1-sol", astra: "gpt-6-astra")
        let configURL = service.codexHome.appendingPathComponent("config.toml")
        let baseline = "# Original native settings\nmodel = 'gpt-6-astra'\nmodel_reasoning_effort = 'ultra'\n"
        let applied = "# Original native settings\nmodel = 'gpt-6.1-sol'\nmodel_reasoning_effort = 'ultra'\n"
        try Data(applied.utf8).write(to: configURL)
        let lease = NativeSettingLease(path: ["model"], before: "\"gpt-6-astra\"", after: "\"gpt-6.1-sol\"", createdContainers: [])
        let record = InstallationRecord(path: configURL.path, platform: .codex, kind: .native,
            before: baseline, after: applied, fields: [lease], canRestoreNative: true)
        let receipt = InstallationReceipt(configuration: previous, platforms: [.codex], records: [record])
        let receiptText = try service.encodeInstallation(receipt)
        try service.storeInstallationText(receiptText)
        let change = FileChange(path: configURL.path, before: baseline, after: applied, reason: "Fixture")
        let backup = IntegrationService.Backup(id: UUID(), createdAt: Date(), records: [.init(change: change, mode: 0o600)],
            installationBefore: nil, installationAfter: receiptText, tracksInstallation: true)
        let backupData = try JSONEncoder().encode(backup)
        try backupData.write(to: service.receiptURL)

        XCTAssertEqual(try service.loadInstallation(service.installationText()), receipt)
        let status = try service.installationStatus()
        XCTAssertEqual(status.state, .applied)
        XCTAssertEqual(status.appliedConfiguration, previous)
        let decoded = try JSONDecoder().decode(InstallationStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.appliedConfiguration, previous)
        XCTAssertEqual(StandMixerModNativeSettings.capture(platform: .codex, service: service).modelID, "gpt-6.1-sol")
        XCTAssertEqual(try service.installationText(), receiptText)
        XCTAssertEqual(try Data(contentsOf: service.receiptURL), backupData)

        _ = try service.restoreLast()
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), baseline)
    }

    func testModelUpgradeKeepsFirstEscalationChoiceAndRepeatedTeamSlots() throws {
        var draft = StandMixerConfiguration.defaults
        let codex = try XCTUnwrap(draft.profiles.firstIndex { $0.platform == .codex })
        let debugging = try XCTUnwrap(draft.profiles[codex].routes.firstIndex { $0.category == .debugging })
        let older = AgentAssignment(modelID: "gpt-6-astra", effort: .fixed("high"), modelPlatform: .codex)
        let newer = AgentAssignment(modelID: "gpt-6.2-astra", effort: .fixed("max"), modelPlatform: .codex)
        let other = AgentAssignment(modelID: "gpt-6-luna", effort: .fixed("medium"))
        draft.profiles[codex].routes[debugging].stuckEscalation = [older, other, newer]
        draft.profiles[codex].routes[debugging].additionalAgents = [older, newer]
        draft.profiles[codex].routes[debugging].inheritsTeam = false
        try JSONEncoder().encode(draft).write(to: service.applicationSupport.appendingPathComponent("configuration.json"))

        var first = older
        first.modelID = newer.modelID
        let updated = try service.loadConfiguration()
        let route = try XCTUnwrap(updated.profile(for: .codex)?.route(for: .debugging))
        XCTAssertEqual(route.stuckEscalation, [first, other])
        XCTAssertEqual(route.additionalAgents, [first, newer])
        XCTAssertNoThrow(try service.preview(configuration: updated, platforms: [.codex]))
    }

    func testModelUpgradePreservesExistingRepeatedEscalationIDsInAnInactiveProfile() throws {
        var draft = StandMixerConfiguration.defaults
        draft.enabledPlatforms = [.codex]
        let claude = try XCTUnwrap(draft.profiles.firstIndex { $0.platform == .claude })
        let debugging = try XCTUnwrap(draft.profiles[claude].routes.firstIndex { $0.category == .debugging })
        let first = AgentAssignment(modelID: "claude-fable-5-2", effort: .fixed("max"))
        let second = AgentAssignment(modelID: first.modelID, effort: .fixed("high"))
        let astra = AgentAssignment(modelID: "gpt-6-astra", effort: .fixed("medium"))
        draft.profiles[claude].routes[debugging].stuckEscalation = [first, second, astra]
        try service.saveConfiguration(draft)

        var upgradedAstra = astra
        upgradedAstra.modelID = "gpt-6.2-astra"
        let upgraded = try service.loadConfiguration()
        XCTAssertEqual(upgraded.profile(for: .claude)?.route(for: .debugging)?.stuckEscalation,
                       [first, second, upgradedAstra])
    }

    func testCachedCatalogLabelsNewAndHistoricalModelsByExactID() throws {
        let labels = [
            "gpt-6.1-sol": "Sol 6.1", "gpt-6.2-sol": "Sol 6.2",
            "gpt-6-astra": "Astra 6", "gpt-6.2-astra": "Astra 6.2",
        ]
        let cacheRows = labels.keys.map { ["slug": $0, "display_name": "GPT"] }
        let data = try JSONSerialization.data(withJSONObject: ["models": cacheRows])
        try data.write(to: service.codexHome.appendingPathComponent("models_cache.json"))

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: service.discoveredModels().map { ($0.id, $0.label) }), labels)
        let builtIn = Set(ModelSpec.builtIn.map(\.id))
        XCTAssertTrue(builtIn.isSuperset(of: ["gpt-6.2-sol", "gpt-6.2-astra"]))
        XCTAssertTrue(builtIn.isDisjoint(with: ["gpt-6.1-sol", "gpt-6-astra"]))
    }

    private func configuration(sol: String, astra: String) -> StandMixerConfiguration {
        let customID = "gpt-6.1-sol-project"
        let workerID = UUID(uuidString: "00000000-0000-0000-0000-000000000521")!
        let customWorkerID = UUID(uuidString: "00000000-0000-0000-0000-000000000522")!
        let escalationID = UUID(uuidString: "00000000-0000-0000-0000-000000000523")!
        let codex: [Route] = [
            .init(category: .coordinator, modelID: sol, effort: .fixed("ultra")),
            .init(category: .planning, modelID: astra, effort: .range(minimum: "medium", maximum: "ultra"),
                additionalAgents: [
                    .init(id: workerID, modelID: sol, effort: .fixed("xhigh"), modelPlatform: .codex),
                    .init(id: customWorkerID, modelID: customID, modelPlatform: .codex),
                ],
                resultMode: .ai, judgeModelID: sol, teamMode: .leadReview),
            .init(category: .algorithms, modelID: sol, effort: .fixed("low"),
                inheritsModel: true, inheritsEffort: true, inheritsTeam: true),
            .init(category: .implementation, modelID: customID),
            .init(category: .debugging, modelID: customID,
                stuckEscalation: [.init(id: escalationID, modelID: astra, effort: .fixed("max"), modelPlatform: .codex)]),
        ]
        let claude: [Route] = [
            .init(category: .coordinator, modelID: Route.autoControllerModelID),
            .init(category: .planning, modelID: "claude-opus-5-5", effort: .fixed("high")),
            .init(category: .algorithms, modelID: astra, effort: .fixed("high")),
            .init(category: .research, modelID: "claude-fable-5-2", effort: .fixed("max")),
        ]
        return .init(profiles: [.init(platform: .codex, routes: codex), .init(platform: .claude, routes: claude)],
            customModels: [.init(id: customID, label: "Sol 6.1 project alias", platform: .codex)], enabledPlatforms: [.codex])
    }
}
