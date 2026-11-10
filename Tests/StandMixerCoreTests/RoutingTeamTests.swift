import Foundation
import XCTest
@testable import StandMixerCore

final class RoutingTeamTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-team-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = .init(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSingleHarnessPreviewIgnoresOtherHarnessAndUnselectedInvalidProfile() throws {
        var configuration = StandMixerConfiguration.preset(.fast, availablePlatforms: [.codex])
        configuration.profiles.removeAll { $0.platform == .claude }
        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        let codexSkillPaths = Set(service.controlURLs(.codex).map(\.path))
        XCTAssertTrue(preview.changes.allSatisfy { $0.path.hasPrefix(service.codexHome.path + "/") || codexSkillPaths.contains($0.path) })
        _ = try service.apply(preview: preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("home/.claude").path))
    }

    func testOptimizedRecipePreservesRequestedChoicesWithoutRestrictingProductFamilies() throws {
        let configuration = StandMixerConfiguration.defaults
        let codex = try XCTUnwrap(configuration.profile(for: .codex))
        let claude = try XCTUnwrap(configuration.profile(for: .claude))
        XCTAssertEqual(codex.route(for: .coordinator)?.modelID, "auto")
        XCTAssertEqual(codex.route(for: .coordinator)?.effort, .auto)
        XCTAssertEqual(codex.route(for: .ui)?.modelID, "gpt-6-astra")
        XCTAssertEqual(codex.route(for: .mechanical)?.modelID, "gpt-6-luna")
        XCTAssertEqual(claude.route(for: .coordinator)?.modelID, "auto")
        XCTAssertEqual(claude.route(for: .coordinator)?.effort, .auto)
        XCTAssertEqual(claude.route(for: .planning)?.modelID, "claude-opus-5-5")
        XCTAssertEqual(claude.route(for: .ui)?.modelID, "claude-opus-5-5")
        XCTAssertEqual(claude.route(for: .implementation)?.modelID, "gpt-6.1-sol")
        for profile in configuration.profiles {
            XCTAssertEqual(profile.route(for: .ui)?.additionalAgents.map(\.modelID), [profile.platform == .codex ? "claude-opus-5-5" : "claude-fable-5-1"])
            XCTAssertTrue(profile.routes.filter { $0.category != .ui }.allSatisfy { $0.additionalAgents.isEmpty })
        }
        XCTAssertEqual(StandMixerPreset.allCases.map(\.title), ["StandMixer Fast", "StandMixer Optimized", "StandMixer High"])
        let claudeOnly = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.claude])
        XCTAssertEqual(claudeOnly.profile(for: .claude)?.route(for: .planning)?.modelID, "claude-opus-5-5")
    }

    func testAvailabilityPresetsAreDeterministicAndNativeWhenOnlyOneHarnessAvailable() throws {
        for preset in StandMixerPreset.allCases {
            for platform in AgentPlatform.allCases {
                let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: [platform])
                XCTAssertEqual(configuration, StandMixerConfiguration.preset(preset, availablePlatforms: [platform]))
                let profile = try XCTUnwrap(configuration.profile(for: platform))
                let catalog = Dictionary(uniqueKeysWithValues: ModelSpec.builtIn.map { ($0.id, $0.platform) })
                XCTAssertTrue(profile.routes.allSatisfy { $0.isAutoController || catalog[$0.modelID] == platform })
                XCTAssertNoThrow(try service.preview(configuration: configuration, platforms: [platform]))
            }
        }
    }

    func testFourWorkersKeepIndividualEffortAndCanRestoreRemovedWorkers() throws {
        var configuration = StandMixerConfiguration.defaults
        let profile = try XCTUnwrap(configuration.profiles.firstIndex { $0.platform == .codex })
        let ui = try XCTUnwrap(configuration.profiles[profile].routes.firstIndex { $0.category == .ui })
        configuration.profiles[profile].routes[ui].teamMode = .parallel
        configuration.profiles[profile].routes[ui].additionalAgents = [
            .init(modelID: "gpt-6.1-sol", effort: .fixed("ultra")),
            .init(modelID: "claude-opus-5-5", effort: .fixed("xhigh")),
            .init(modelID: "gpt-6-astra", effort: .fixed("high"))
        ]
        configuration.profiles[profile].routes[ui].resultMode = .ai
        configuration.profiles[profile].routes[ui].judgeModelID = "claude-opus-5-5"
        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        let workerFiles = preview.changes.filter { $0.path.contains("/agents/") }
        XCTAssertEqual(workerFiles.count, 5, "Auto roles and the judge reuse matching definitions; explicit fixed overrides keep their own definitions.")
        XCTAssertTrue(workerFiles.contains { $0.path.hasSuffix("standmixer-gpt-6.1-sol-ultra.toml") && $0.after.contains("ultra") })
        XCTAssertFalse(workerFiles.contains { $0.path.hasSuffix("standmixer-claude-opus-5-5-xhigh.toml") })
        let guide = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") })
        XCTAssertTrue(guide.after.contains("--effort 'xhigh'"))
        XCTAssertTrue(preview.changes.contains { $0.after.contains("launch all 4 workers concurrently") })
        _ = try service.apply(preview: preview)
        configuration.profiles[profile].routes[ui].additionalAgents = []
        configuration.profiles[profile].routes[ui].resultMode = .coordinator
        let reduced = try service.preview(configuration: configuration, platforms: [.codex])
        XCTAssertEqual(reduced.changes.filter(\.isDeletion).count, 2, "Keep the shared Auto specs; remove the now-unused explicit effort variants.")
        _ = try service.apply(preview: reduced)
        XCTAssertFalse(try String(contentsOfFile: guide.path, encoding: .utf8).contains("--effort 'xhigh'"))
        _ = try service.restoreLast()
        XCTAssertEqual(try String(contentsOfFile: guide.path, encoding: .utf8), guide.after)
    }

    func testWorkerLimitAndForeignCoordinatorAreRejected() throws {
        var configuration = StandMixerConfiguration.defaults
        configuration.profiles[0].routes[0].additionalAgents = [.init(modelID: "gpt-6.1-sol")]
        XCTAssertThrowsError(try service.preview(configuration: configuration, platforms: [.codex]))
        configuration = .defaults
        configuration.profiles[0].routes[0].modelID = "claude-opus-5-5"
        configuration.profiles[0].routes[0].effort = .auto
        XCTAssertThrowsError(try service.preview(configuration: configuration, platforms: [.codex]))
    }

    func testVisualComparisonIsInitialOnlyAndFollowupsStayWithWinningAgent() throws {
        for platform in AgentPlatform.allCases {
            let preview = try service.preview(configuration: .defaults, platforms: [platform])
            let policy = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(platform == .codex ? "/AGENTS.md" : "/CLAUDE.md") }).after
            XCTAssertTrue(policy.contains("initial substantial visual design"))
            XCTAssertTrue(policy.contains("helpers provide basic alternatives only, not full implementations"))
            XCTAssertTrue(policy.contains("Prefer the selected design's model for visual follow-ups when useful"))
            XCTAssertTrue(policy.contains("use normal judgment about delegation"))
            XCTAssertTrue(policy.contains("changes of approach, or replacing workers"))
        }
    }

    func testDirectCrossProviderAutoPassesCallerIntentWithoutDriverEffort() throws {
        var configuration = StandMixerConfiguration.defaults
        let index = try XCTUnwrap(configuration.profiles.firstIndex { $0.platform == .claude })
        let route = try XCTUnwrap(configuration.profiles[index].routes.firstIndex { $0.category == .mechanical })
        configuration.profiles[index].routes[route].modelID = "gpt-6-luna"
        configuration.profiles[index].routes[route].effort = .auto
        let preview = try service.preview(configuration: configuration, platforms: [.claude])
        let worker = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".claude/skills/standmixer/references/external-workers.md") })
        XCTAssertTrue(worker.after.contains("model_reasoning_effort=\"<mapped-caller-effort>\""))
        XCTAssertFalse(worker.after.contains("model: claude-haiku-5-5"))
        XCTAssertTrue(worker.after.contains("Auto follows the original caller's reasoning intensity"))
        XCTAssertTrue(worker.after.contains("ultra -> max"))
        XCTAssertFalse(worker.after.contains("model_reasoning_effort=\"medium\""))
    }

    func testNamedPresetsPersistAndOverwriteOnlyMatchingName() throws {
        let first = try service.savePreset(name: "My team", configuration: .defaults)
        let replacement = try service.savePreset(name: "my team", configuration: .preset(.fast, availablePlatforms: [.claude]))
        XCTAssertEqual(first.id, replacement.id)
        XCTAssertEqual(try service.loadSavedPresets(), [replacement])
        try service.deletePreset(id: replacement.id)
        XCTAssertEqual(try service.loadSavedPresets(), [])
    }

    func testImporterPreservesUnknownAdditionalWorkersAndAcceptsExplicitMixedTeam() throws {
        let importer = AgentImportService(integration: service)
        let finding = AgentImportProposal(platform: .codex, workingDirectory: root.path, routes: [
            .init(category: .ui, additionalAgents: [.init(modelID: "claude-opus-5-5", effort: .fixed("high"), modelPlatform: .claude)], resultMode: .user)
        ])
        let merged = importer.merge(proposals: [finding], into: .defaults)
        XCTAssertEqual(merged.configuration.profile(for: .codex)?.route(for: .ui)?.additionalAgents.count, 1)
        XCTAssertEqual(merged.configuration.profile(for: .codex)?.route(for: .ui)?.resultMode, .user)
        let unknown = AgentImportProposal(platform: .codex, workingDirectory: root.path, routes: [.init(category: .ui)])
        XCTAssertEqual(importer.merge(proposals: [unknown], into: merged.configuration).configuration, merged.configuration)
    }

    func testImportedWorkerCountAndModelSurviveUnknownEffortWithoutChangingDraft() throws {
        let response: [String: Any] = ["routes": [["category": "ui", "modelID": NSNull(), "effort": NSNull(),
            "additionalAgents": [["modelID": "claude-opus-5-5", "modelPlatform": "claude", "effort": NSNull()]]]]]
        let proposal = try AgentImportService.decode(JSONSerialization.data(withJSONObject: response), platform: .codex, cwd: root)
        XCTAssertEqual(proposal.routes.first?.additionalAgents?.count, 1)
        XCTAssertEqual(proposal.routes.first?.additionalAgents?.first?.modelID, "claude-opus-5-5")
        XCTAssertNil(proposal.routes.first?.additionalAgents?.first?.effort)
        let result = AgentImportService(integration: service).merge(proposals: [proposal], into: .defaults)
        XCTAssertEqual(result.configuration, .defaults)
        XCTAssertFalse(result.notes.isEmpty)
    }
}
