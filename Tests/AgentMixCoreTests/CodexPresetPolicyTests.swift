import Foundation
import XCTest
@testable import AgentMixCore

final class CodexPresetPolicyTests: XCTestCase {
    private let codexAvailabilities: [Set<AgentPlatform>] = [[.codex], [.codex, .claude]]

    func testApprovedCodexRecipesPreserveNativeCoordinatorAndCallerEffort() throws {
        let catalog = Dictionary(uniqueKeysWithValues: ModelSpec.builtIn.map { ($0.id, $0) })
        for available in codexAvailabilities {
            for preset in AgentMixPreset.allCases {
                let configuration = AgentMixConfiguration.preset(preset, availablePlatforms: available)
                let profile = try XCTUnwrap(configuration.profile(for: .codex))
                XCTAssertEqual(profile.routes.map(\.category), WorkCategory.allCases)
                for route in profile.routes {
                    let context = "\(preset) \(available) \(route.category)"
                    let team = [route.modelID] + route.additionalAgents.map(\.modelID)
                    XCTAssertEqual(Set(team).count, team.count, context)
                    for id in team where !route.isAutoController {
                        let model = try XCTUnwrap(catalog[id], context)
                        XCTAssertTrue(available.contains(model.platform), context)
                    }
                    XCTAssertEqual(route.effort, .auto, context)
                    XCTAssertTrue(route.additionalAgents.allSatisfy { $0.effort == .auto }, context)
                    XCTAssertEqual(route.resultMode, .coordinator, context)
                    XCTAssertNil(route.judgeModelID, context)
                }
                let coordinator = try XCTUnwrap(profile.route(for: .coordinator))
                XCTAssertTrue(coordinator.isAutoController)
                XCTAssertTrue(coordinator.additionalAgents.isEmpty)
                XCTAssertNoThrow(try configuration.validateNativeCoordinators(catalog: ModelSpec.builtIn))
            }
        }
    }

    func testFastCodexUsesApprovedSpecialistsAndNativeFallback() throws {
        for available in codexAvailabilities {
            let profile = try XCTUnwrap(AgentMixConfiguration.preset(.fast, availablePlatforms: available).profile(for: .codex))
            XCTAssertEqual(profile.routes.map(\.modelID), [
                "auto", "gpt-6.1-sol", "gpt-6.1-terra",
                "gpt-6-luna", "gpt-6.1-terra", available.contains(.claude) ? "claude-opus-5-5" : "gpt-6.1-sol", "gpt-6-luna",
            ])
            XCTAssertTrue(profile.routes.allSatisfy { $0.additionalAgents.isEmpty })
        }
    }

    func testOptimizedCodexAddsOpusToVisualAndKeepsAstraAlgorithms() throws {
        for available in codexAvailabilities {
            let profile = try XCTUnwrap(AgentMixConfiguration.preset(.optimized, availablePlatforms: available).profile(for: .codex))
            XCTAssertEqual(profile.route(for: .coordinator)?.modelID, "auto")
            XCTAssertEqual(profile.route(for: .ui)?.modelID, "gpt-6-astra")
            XCTAssertEqual(profile.route(for: .ui)?.additionalAgents.map(\.modelID),
                           [available.contains(.claude) ? "claude-opus-5-5" : "gpt-6.1-sol"])
            XCTAssertEqual(profile.route(for: .algorithms)?.modelID, "gpt-6-astra")
            XCTAssertTrue(profile.route(for: .algorithms)?.additionalAgents.isEmpty == true)
            XCTAssertEqual(profile.route(for: .algorithms)?.teamMode, .leadReview)
            XCTAssertEqual(profile.route(for: .review)?.modelID, available.contains(.claude) ? "claude-opus-5-5" : "gpt-6-astra")
            XCTAssertTrue(profile.routes.filter { ![.ui, .algorithms].contains($0.category) }.allSatisfy { $0.additionalAgents.isEmpty })
        }
    }

    func testHighCodexPreservesApprovedTeamOrderAndNativeFallback() throws {
        for available in codexAvailabilities {
            let profile = try XCTUnwrap(AgentMixConfiguration.preset(.high, availablePlatforms: available).profile(for: .codex))
            let hasClaude = available.contains(.claude)
            let expected: [[String]] = [
                ["auto"],
                ["gpt-6-astra", hasClaude ? "claude-opus-5-5" : "gpt-6.1-sol"],
                hasClaude ? ["gpt-6-astra", "claude-opus-5-5", "claude-fable-5-1"] : ["gpt-6-astra", "gpt-6.1-sol"],
                ["gpt-6-astra"],
                hasClaude ? ["gpt-6-astra", "claude-fable-5-1", "claude-opus-5-5"] : ["gpt-6-astra", "gpt-6.1-sol"],
                hasClaude ? ["claude-opus-5-5", "gpt-6-astra"] : ["gpt-6-astra", "gpt-6.1-sol"],
                ["gpt-6-luna"],
            ]
            XCTAssertEqual(profile.routes.map { [$0.modelID] + $0.additionalAgents.map(\.modelID) }, expected)
        }
    }

    func testClaudeOptimizedAlgorithmsUseSingleOpus() throws {
        for available in [Set<AgentPlatform>([.claude]), [.codex, .claude]] {
            let profile = try XCTUnwrap(AgentMixConfiguration.preset(.optimized, availablePlatforms: available).profile(for: .claude))
            XCTAssertEqual(profile.route(for: .algorithms)?.modelID, "claude-opus-5-5")
            XCTAssertTrue(profile.route(for: .algorithms)?.additionalAgents.isEmpty == true)
            XCTAssertEqual(profile.route(for: .algorithms)?.teamMode, .leadReview)
            XCTAssertEqual(profile.route(for: .review)?.modelID, "claude-opus-5-5")
        }
    }

    func testManualCodexVisualCrossProviderWorkersRemainValid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentmix-codex-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = IntegrationService(home: root.appendingPathComponent("home"),
                                         applicationSupport: root.appendingPathComponent("support"), environment: [:])
        var configuration = AgentMixConfiguration.preset(.optimized, availablePlatforms: [.codex, .claude])
        let profileIndex = try XCTUnwrap(configuration.profiles.firstIndex { $0.platform == .codex })
        let routeIndex = try XCTUnwrap(configuration.profiles[profileIndex].routes.firstIndex { $0.category == .ui })
        configuration.profiles[profileIndex].routes[routeIndex].modelID = "claude-fable-5-1"
        configuration.profiles[profileIndex].routes[routeIndex].additionalAgents = [
            .init(modelID: "claude-haiku-5-5", modelPlatform: .claude),
        ]

        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        for id in ["claude-fable-5-1", "claude-haiku-5-5"] {
            XCTAssertFalse(preview.changes.contains { $0.path.hasSuffix(".codex/agents/agentmix-\(id)-auto.toml") })
            XCTAssertTrue(preview.changes.contains { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") && $0.after.contains("--model '\(id)'") })
        }
        XCTAssertEqual(configuration.profile(for: .codex)?.route(for: .coordinator)?.modelID, "auto")
    }
}
