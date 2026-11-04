import Foundation
import XCTest
@testable import AgentMixCore

final class TeamModeTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("agentmix-team-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = .init(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:], metadataOnlyDiscovery: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func change(_ configuration: inout AgentMixConfiguration, _ category: WorkCategory, _ edit: (inout Route) -> Void) {
        let profile = configuration.profiles.firstIndex { $0.platform == .codex }!
        let index = configuration.profiles[profile].routes.firstIndex { $0.category == category }!
        edit(&configuration.profiles[profile].routes[index])
    }
    private func policy(_ configuration: AgentMixConfiguration, platform: AgentPlatform = .codex) throws -> String {
        let preview = try service.preview(configuration: configuration, platforms: [platform])
        return try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(platform == .codex ? "/AGENTS.md" : "/CLAUDE.md") }).after
    }
    private func block(_ category: WorkCategory, in policy: String) throws -> String {
        let start = try XCTUnwrap(policy.range(of: "- " + category.title + ":"))
        let rest = policy[start.lowerBound...]
        return String(rest).components(separatedBy: "\n- ").first!
            .components(separatedBy: "\n\n").first!
    }

    func testFactoryAlgorithmsUseSingleApprovedLeadWithAutoEffort() throws {
        for available in [Set<AgentPlatform>([.codex, .claude]), [.codex], [.claude]] {
            let configuration = AgentMixConfiguration.preset(.optimized, availablePlatforms: available)
            let codex = try XCTUnwrap(configuration.profile(for: .codex)?.route(for: .algorithms))
            let claude = try XCTUnwrap(configuration.profile(for: .claude)?.route(for: .algorithms))
            XCTAssertEqual([codex.modelID] + codex.additionalAgents.map(\.modelID), ["gpt-6-astra"])
            XCTAssertEqual([claude.modelID] + claude.additionalAgents.map(\.modelID), ["claude-opus-5-5"])
            for profile in configuration.profiles {
                for route in profile.routes {
                    XCTAssertEqual(route.teamMode, route.category == .review ? .parallel : .leadReview)
                    XCTAssertEqual(route.effort, .auto)
                    XCTAssertTrue(route.additionalAgents.allSatisfy { $0.effort == .auto })
                }
            }
        }
        for profile in AgentMixConfiguration.preset(.high, availablePlatforms: [.codex, .claude]).profiles {
            XCTAssertTrue(profile.routes.allSatisfy { $0.teamMode == .parallel })
        }
    }

    func testLegacyMissingTeamModeRetainsIndependentManualSemanticsAndExplicitModesPersist() throws {
        let explicit = Route(category: .planning, modelID: "gpt-6-astra", effort: .fixed("high"),
            additionalAgents: [.init(modelID: "gpt-6.1-sol", effort: .auto)], resultMode: .user, teamMode: .leadReview)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(explicit)) as? [String: Any])
        object.removeValue(forKey: "teamMode")
        let legacy = try JSONDecoder().decode(Route.self, from: JSONSerialization.data(withJSONObject: object))
        var expected = explicit; expected.teamMode = .parallel
        XCTAssertEqual(legacy, expected)
        XCTAssertEqual(try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(explicit)), explicit)
        var manual = AgentMixConfiguration.defaults
        change(&manual, .ui) { $0.teamMode = .parallel }
        change(&manual, .planning) { $0 = explicit }
        try service.saveConfiguration(manual)
        _ = try service.savePreset(name: "My explicit stages", configuration: manual)
        XCTAssertEqual(try service.loadConfiguration(), manual)
        XCTAssertEqual(try service.loadSavedPresets().first?.configuration, manual)
    }

    func testOptimizedPlanningAndAlgorithmsStageReviewAfterSubstantiveWorkWithoutLoweringEffort() throws {
        var configuration = AgentMixConfiguration.defaults
        change(&configuration, .planning) { $0.additionalAgents = [.init(modelID: "gpt-6.1-sol"), .init(modelID: "gpt-6-luna")] }
        change(&configuration, .algorithms) { $0.additionalAgents = [.init(modelID: "claude-opus-5-5")] }
        let exported = try policy(configuration)
        let planning = try block(.planning, in: exported)
        XCTAssertTrue(planning.contains("first worker creates the substantive plan; then the remaining 2 workers give quick focused review of that plan"))
        XCTAssertTrue(planning.contains("not independent replacement plans"))
        let algorithms = try block(.algorithms, in: exported)
        XCTAssertTrue(algorithms.contains("1. Astra 6"))
        XCTAssertTrue(algorithms.contains("2. Opus 5.5 via Claude Code"))
        XCTAssertTrue(algorithms.contains("first worker does the substantive work; then the remaining worker gives quick focused review"))
        XCTAssertTrue(algorithms.contains("not full duplicate solves"))
        XCTAssertFalse(algorithms.contains("as independent instances"))
        XCTAssertTrue(exported.contains("Quick review means bounded scope, not lower effort"))
        XCTAssertTrue(exported.contains("original caller's requested or effective reasoning intensity"))
        let external = try service.preview(configuration: configuration, platforms: [.codex]).changes
        let opus = try XCTUnwrap(external.first { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") })
        XCTAssertTrue(opus.after.contains("--effort '<mapped-caller-effort>'"))
        XCTAssertFalse(opus.after.contains("--effort 'low'"))
    }

    func testOptimizedVisualKeepsImplementationWithPrimaryOrExplicitUserWinner() throws {
        let exported = try policy(.defaults)
        let visual = try block(.ui, in: exported)
        XCTAssertTrue(visual.contains("may make basic design passes concurrently"))
        XCTAssertTrue(visual.contains("helpers provide basic alternatives only, not full implementations"))
        XCTAssertTrue(visual.contains("Implementation and fixes stay with the primary, or a different winner explicitly selected by the user"))
        XCTAssertTrue(visual.contains("resume that worker when possible"))
        XCTAssertTrue(visual.contains("Do not rerun the design team for ordinary tweaks"))
        XCTAssertTrue(visual.contains("revisit helpers only for major changes or a new style direction"))
        XCTAssertFalse(visual.contains("as independent instances"))
    }

    func testTeamModeOnlyEditChangesRoutingWithoutRewritingModelsOrEffort() throws {
        var configuration = AgentMixConfiguration.defaults
        change(&configuration, .algorithms) { $0.additionalAgents = [.init(modelID: "claude-opus-5-5")] }
        _ = try service.apply(preview: service.preview(configuration: configuration, platforms: [.codex]))
        change(&configuration, .algorithms) { $0.teamMode = .parallel }
        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        let changed = preview.changes.filter(\.isChanged)
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(changed[0].path.hasSuffix("/AGENTS.md"))
        XCTAssertTrue(preview.changes.filter { $0.path.contains("/agents/") }.allSatisfy { !$0.isChanged })
        XCTAssertFalse(preview.changes.contains { $0.path.hasSuffix("/config.toml") })
        let algorithms = try block(.algorithms, in: changed[0].after)
        XCTAssertTrue(algorithms.contains("Parallel: Produce full independent solutions"))
        XCTAssertFalse(algorithms.contains("Lead + review"))
    }

    func testHighRetainsIndependentPassesAndReviewLeadConsolidatesWithoutUnconfiguredJudges() throws {
        let exported = try policy(.preset(.high, availablePlatforms: [.codex, .claude]))
        for (category, guidance) in [(WorkCategory.planning, "full independent plans"), (.ui, "full independent design alternatives"), (.algorithms, "full independent solutions"), (.review, "full independent checks")] {
            let route = try block(category, in: exported)
            XCTAssertTrue(route.contains("Parallel:"))
            XCTAssertTrue(route.contains(guidance))
            XCTAssertTrue(route.contains("as independent instances"))
            XCTAssertTrue(route.contains("first worker verifies and consolidates"))
            XCTAssertFalse(route.contains("compare-only"))
        }
        XCTAssertTrue(exported.contains("Do not add unconfigured critics, consensus votes, or review loops"))
        XCTAssertTrue(try block(.ui, in: exported).contains("agent/model that made it"))
        var configuredJudge = AgentMixConfiguration.defaults
        change(&configuredJudge, .algorithms) { $0.additionalAgents = [.init(modelID: "claude-opus-5-5")]; $0.resultMode = .ai; $0.judgeModelID = "gpt-6.1-sol" }
        XCTAssertTrue(try policy(configuredJudge).contains("launch a fresh `agentmix-gpt-6.1-sol-auto` instance with a compare-only brief"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
    }
}
