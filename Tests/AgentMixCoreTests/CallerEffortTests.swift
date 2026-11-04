import Foundation
import XCTest
@testable import AgentMixCore

final class CallerEffortTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentmix-caller-effort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func edit(_ configuration: inout AgentMixConfiguration, platform: AgentPlatform, category: WorkCategory, _ change: (inout Route) -> Void) {
        let profile = configuration.profiles.firstIndex { $0.platform == platform }!
        let route = configuration.profiles[profile].routes.firstIndex { $0.category == category }!
        change(&configuration.profiles[profile].routes[route])
    }

    private func file(_ suffix: String, in preview: IntegrationPreview) throws -> String {
        try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(suffix) }).after
    }

    private func selectorDescription(_ source: String) throws -> String {
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.hasPrefix("description = ") || $0.hasPrefix("description: ") })
        let value = String(line.dropFirst(line.hasPrefix("description = ") ? "description = ".count : "description: ".count))
        return try JSONDecoder().decode(String.self, from: Data(value.utf8))
    }

    private func childInstructions(_ source: String) throws -> String {
        if let line = source.components(separatedBy: "\n").first(where: { $0.hasPrefix("developer_instructions = ") }) {
            return try JSONDecoder().decode(String.self, from: Data(line.dropFirst("developer_instructions = ".count).utf8))
        }
        return try XCTUnwrap(source.components(separatedBy: "---\n").last).replacingOccurrences(of: "<!-- \(ConfigEdits.ownership) -->\n\n", with: "")
    }

    func testAllPresetCoordinatorsAndWorkersFollowCallerUntilExplicitlyOverridden() throws {
        for available in [Set<AgentPlatform>([.codex]), [.claude], [.codex, .claude]] {
            for preset in AgentMixPreset.allCases {
                let configuration = AgentMixConfiguration.preset(preset, availablePlatforms: available)
                for profile in configuration.profiles {
                    for route in profile.routes {
                        XCTAssertEqual(route.effort, .auto, "\(preset) \(profile.platform) \(route.category)")
                        XCTAssertTrue(route.additionalAgents.allSatisfy { $0.effort == .auto })
                    }
                }
            }
        }
        XCTAssertEqual(EffortPolicy.auto.description, "follow caller")
        XCTAssertNil(EffortPolicy.auto.nativeValue)
    }

    func testCallerMappingUsesNearestSupportedLevelAndLowerTies() {
        let model = ModelSpec(id: "sparse", label: "Sparse", platform: .codex,
                              supportedEfforts: ["max", "low", "high"], defaultEffort: "max")
        XCTAssertEqual(model.callerEfforts, ["low", "high", "max"])
        XCTAssertEqual(EffortPolicy.levels.map { model.nearestSupportedEffort(to: $0) }, ["low", "low", "high", "high", "max", "max"])
        XCTAssertNil(model.nearestSupportedEffort(to: "unknown"))
        let claude = ModelSpec(id: "claude-exact", label: "Claude", platform: .claude, supportedEfforts: EffortPolicy.levels)
        XCTAssertEqual(claude.nearestSupportedEffort(to: "low"), "low")
        XCTAssertEqual(claude.nearestSupportedEffort(to: "ultra"), "max")
        XCTAssertFalse(claude.callerEfforts.contains("ultra"))
        let unknown = ModelSpec(id: "empty", label: "Empty", platform: .codex, supportedEfforts: [])
        XCTAssertNil(unknown.nearestSupportedEffort(to: "high"))
        XCTAssertTrue(WorkerSpec(model: unknown, effort: .auto).launchDescription(for: unknown).contains("not established; verify before launch"))
    }

    func testNativeAutoOmitsFixedEffortAndPreservesCallerLaunchGuidance() throws {
        let preview = try service.preview(configuration: .defaults)
        let codex = try file(".codex/agents/agentmix-gpt-6-astra-auto.toml", in: preview)
        XCTAssertTrue(codex.contains("model = \"gpt-6-astra\""))
        XCTAssertFalse(codex.contains("model_reasoning_effort ="))
        XCTAssertEqual(try selectorDescription(codex), "Model selector: Astra 6; effort: follow caller. Supported launch levels: low, medium, high, xhigh, max, ultra.")
        let claude = try file(".claude/agents/agentmix-claude-fable-5-1-auto.md", in: preview)
        XCTAssertTrue(claude.contains("model: claude-fable-5-1\n---"))
        XCTAssertFalse(claude.contains("\neffort:"))
        XCTAssertEqual(try selectorDescription(claude), "Model selector: Fable 5.1; effort: follow caller. Supported launch levels: low, medium, high, xhigh, max.")
        for artifact in [codex, claude] {
            let child = try childInstructions(artifact)
            XCTAssertTrue(child.contains("actual scope, permissions, and applicable project instructions"))
            for absent in ["effort", "caller", "mapping", "Role:", "Visual", "AgentMix", "preset", "budget", "report"] {
                XCTAssertFalse(child.contains(absent), "Launch bookkeeping and personas do not belong in the child body: \(absent)")
            }
        }
        XCTAssertFalse(preview.changes.contains { $0.path.hasSuffix(".codex/config.toml") || $0.path.hasSuffix(".claude/settings.json") })
        let policy = try file(".codex/AGENTS.md", in: preview)
        for guidance in ["original caller's requested or effective reasoning intensity", "Preserve explicit user/session requests", "If the caller intensity is unknown", "native inheritance", "not runtime enforcement"] {
            XCTAssertTrue(policy.contains(guidance))
        }
        XCTAssertTrue(policy.contains("selector description or external recipe"))
        XCTAssertTrue(policy.contains("nearest level in low, medium, high, xhigh, max, ultra order, with lower ties"))
        XCTAssertTrue(policy.contains("controller launch metadata, not worker prose"))
    }

    func testBothCrossCLIDirectionsMapCallerInsteadOfDriverOrCatalogDefault() throws {
        let preview = try service.preview(configuration: .defaults)
        let claudeTarget = try file(".agents/skills/standmixer/references/external-workers.md", in: preview)
        XCTAssertFalse(claudeTarget.contains("model = \"gpt-6-luna\""))
        XCTAssertTrue(claudeTarget.contains("--effort '<mapped-caller-effort>'"))
        XCTAssertFalse(claudeTarget.contains("--effort 'high'"))
        let codexTarget = try file(".claude/skills/standmixer/references/external-workers.md", in: preview)
        XCTAssertFalse(codexTarget.contains("model: claude-haiku-5-5"))
        XCTAssertTrue(codexTarget.contains("-c 'model_reasoning_effort=\"<mapped-caller-effort>\"'"))
        XCTAssertFalse(codexTarget.contains("model_reasoning_effort=\"low\""))
        for worker in [claudeTarget, codexTarget] {
            XCTAssertTrue(worker.contains("Auto follows the original caller's reasoning intensity"))
            XCTAssertTrue(worker.contains("original caller's reasoning intensity"))
            XCTAssertTrue(worker.contains("explicitly pass it to the real worker"))
            XCTAssertTrue(worker.contains("do not fall back to an intermediary model's effort or the target's catalog default"))
            XCTAssertTrue(worker.contains("Preserve the person's existing permissions and settings"))
        }
    }

    func testCustomAutoIgnoresCatalogDefaultAndFixedAndRangeRemainOverrides() throws {
        var configuration = AgentMixConfiguration.defaults
        configuration.customModels = [.init(id: "custom-caller", label: "Custom Caller", platform: .codex,
                                             supportedEfforts: ["low", "high"], defaultEffort: "high")]
        edit(&configuration, platform: .codex, category: .planning) { $0.modelID = "custom-caller" }
        edit(&configuration, platform: .codex, category: .ui) { $0.effort = .fixed("xhigh") }
        edit(&configuration, platform: .claude, category: .implementation) { $0.effort = .fixed("ultra") }
        edit(&configuration, platform: .claude, category: .ui) { $0.modelID = "claude-fable-5-1"; $0.effort = .range(minimum: "medium", maximum: "max") }
        let preview = try service.preview(configuration: configuration)
        let custom = try XCTUnwrap(preview.changes.first { $0.path.contains("agentmix-custom-caller-auto-") }).after
        XCTAssertFalse(custom.contains("model_reasoning_effort ="))
        XCTAssertTrue(try selectorDescription(custom).contains("Supported launch levels: low, high."))
        XCTAssertTrue(try file(".codex/agents/agentmix-gpt-6-astra-xhigh.toml", in: preview).contains("model_reasoning_effort = \"xhigh\""))
        let externalFixed = try file(".claude/skills/standmixer/references/external-workers.md", in: preview)
        XCTAssertTrue(externalFixed.contains("model_reasoning_effort=\"ultra\""))
        XCTAssertFalse(externalFixed.contains("<mapped-caller-effort>"))
        let range = try file(".claude/agents/agentmix-claude-fable-5-1-range-medium-max.md", in: preview)
        XCTAssertTrue(range.contains("choose medium through max for task complexity"))
        XCTAssertFalse(range.contains("\neffort:"))
        XCTAssertFalse(range.contains("Caller-to-target mapping:"))
    }
}
