import Foundation
import XCTest
@testable import StandMixerCore

final class ApprovedPresetMatrixTests: XCTestCase {
    private struct Worker: Equatable {
        let id: String
        let effort: String

        init(_ id: String, _ effort: String) {
            self.id = id
            self.effort = effort
        }
    }

    private let roles: [WorkCategory] = [.coordinator, .planning, .quickIdeas, .algorithms, .ui, .uiImplementation,
        .uiReview, .implementation, .routineCoding, .debugging, .review, .developmentSecurity, .securityReview, .research,
        .draftingEditing, .deepAnalysis, .mechanical, .computerUse]
    private let roleTitles = ["Controller", "Planning & algorithms", "Quick ideas", "Algorithms", "Design & UI",
        "UI implementation", "UI review", "General coding", "Routine coding", "Debugging / root cause", "Code review",
        "Development security", "Release security", "Research & writing", "Drafting & editing", "Deep analysis", "Routine tasks", "Computer use"]

    // Independent fixtures in visible category order, including fixed child
    // efforts and the ordered Codex security team.
    private func expectedTeams(_ preset: StandMixerPreset, _ platform: AgentPlatform) -> [[Worker]] {
        let astra = "gpt-6.2-astra", sol = "gpt-6.2-sol", luna = "gpt-6-luna"
        let fable = "claude-fable-5-2", opus = "claude-opus-5-5", haiku = "claude-haiku-5-5"
        let controller = [Worker("auto", "auto")]
        let planning: Worker
        let layout: Worker
        let coding: Worker
        let debugging: Worker
        let review: Worker
        let research: Worker
        let analysis: Worker
        let routine: Worker
        let computer: Worker
        let security = [Worker(astra, "max"), Worker(fable, "max")]
        switch (preset, platform) {
        case (.fast, .codex):
            planning = Worker(astra, "medium"); layout = Worker(astra, "low"); coding = Worker(astra, "medium"); debugging = Worker(astra, "max")
            review = Worker(astra, "medium"); research = Worker(astra, "medium"); analysis = Worker(astra, "max")
            routine = Worker(luna, "low"); computer = Worker(astra, "medium")
        case (.fast, .claude):
            planning = Worker(fable, "medium"); layout = Worker(fable, "low"); coding = Worker(opus, "medium"); debugging = Worker(opus, "max")
            review = Worker(opus, "medium"); research = Worker(opus, "medium"); analysis = Worker(opus, "max")
            routine = Worker(haiku, "low"); computer = Worker(opus, "medium")
        case (.optimized, .codex), (.high, .codex):
            let effort = preset == .optimized ? "xhigh" : "max"
            planning = Worker(astra, "max"); layout = Worker(astra, "max"); coding = Worker(astra, effort); debugging = Worker(astra, "max")
            review = Worker(astra, "max"); research = Worker(astra, effort); analysis = Worker(astra, "max")
            routine = Worker(luna, "medium"); computer = Worker(astra, "medium")
        case (.optimized, .claude), (.high, .claude):
            let effort = preset == .optimized ? "xhigh" : "max"
            let lead = preset == .optimized ? opus : fable
            planning = Worker(fable, "max"); layout = Worker(fable, "max"); coding = Worker(lead, effort); debugging = Worker(lead, "max")
            review = Worker(lead, "max"); research = Worker(lead, effort); analysis = Worker(lead, "max")
            routine = Worker(haiku, "medium"); computer = Worker(opus, "medium")
        }
        let planningAndDesignSupport = preset == .high ? [Worker(platform == .codex ? fable : astra, "max")] : []
        let otherSupport = preset == .high ? [Worker(platform == .codex ? fable : opus, "max")] : []
        let planningTeam = [planning] + planningAndDesignSupport
        let algorithmsTeam = preset == .fast ? [Worker(planning.id, "high")] : planningTeam
        let designTeam = [layout] + planningAndDesignSupport
        let development = Worker(platform == .codex ? astra : opus, "medium")
        return [controller, planningTeam, [Worker(platform == .claude ? opus : planning.id, "medium")], algorithmsTeam,
                designTeam, designTeam, designTeam, [coding] + otherSupport, [Worker(sol, "max")], [debugging],
                [review] + otherSupport, [development], security, [research] + otherSupport,
                [Worker(research.id, "medium")], [analysis] + otherSupport, [routine], [computer]]
    }

    private let models: [String: (label: String, provider: AgentPlatform)] = [
        "gpt-6.2-astra": ("Astra 6.2", .codex),
        "gpt-6.2-sol": ("Sol 6.2", .codex),
        "gpt-6.1-terra": ("Terra 6.1", .codex),
        "gpt-6-luna": ("Luna 6", .codex),
        "claude-opus-5-5": ("Opus 5.5", .claude),
        "claude-fable-5-2": ("Fable 5.2", .claude),
        "claude-sonnet-5-5": ("Sonnet 5.5", .claude),
        "claude-haiku-5-5": ("Haiku 5.5", .claude),
    ]

    func testBothHarnessPresetsMatchApprovedModelsFixedEffortsAndOrderedTeams() throws {
        let catalog = Dictionary(uniqueKeysWithValues: ModelSpec.builtIn.map { ($0.id, $0) })
        for (id, expected) in models {
            XCTAssertEqual(catalog[id]?.label, expected.label, id)
            XCTAssertEqual(catalog[id]?.platform, expected.provider, id)
        }
        for preset in StandMixerPreset.allCases {
            let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: [.codex, .claude])
            XCTAssertEqual(configuration.profiles.map(\.platform), [.codex, .claude])
            XCTAssertNoThrow(try configuration.validateNativeCoordinators(catalog: ModelSpec.builtIn))
            for platform in [AgentPlatform.codex, .claude] {
                let profile = try XCTUnwrap(configuration.profile(for: platform))
                XCTAssertEqual(profile.routes.map(\.category), roles)
                let teams = expectedTeams(preset, platform)
                for (route, expectedTeam) in zip(profile.effectiveRoutes, teams) {
                    let context = "\(preset.rawValue)/\(platform.rawValue)/\(route.category.rawValue)"
                    XCTAssertEqual([Worker(route.modelID, route.effort.nativeValue ?? "auto")]
                        + route.additionalAgents.map { Worker($0.modelID, $0.effort.nativeValue ?? "auto") }, expectedTeam, context)
                    if expectedTeam.count > 1 {
                        XCTAssertEqual(route.teamMode, route.category == .implementation ? .leadReview : .parallel, context)
                    }
                    XCTAssertEqual(route.resultMode, .coordinator, context)
                    XCTAssertNil(route.judgeModelID, context)
                }
                let coordinator = try XCTUnwrap(profile.route(for: .coordinator))
                XCTAssertTrue(coordinator.additionalAgents.isEmpty)
                XCTAssertTrue(coordinator.isAutoController)
            }
        }
        XCTAssertEqual(StandMixerConfiguration.defaults, .preset(.optimized, availablePlatforms: [.codex, .claude]))
    }

    func testPresetWorkerIdentitiesAreUniqueDeterministicAndPersistWithoutReordering() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let availabilities: [Set<AgentPlatform>] = [[.codex, .claude], [.codex], [.claude], []]
        for preset in StandMixerPreset.allCases {
            for available in availabilities {
                let first = StandMixerConfiguration.preset(preset, availablePlatforms: available)
                let second = StandMixerConfiguration.preset(preset, availablePlatforms: available)
                XCTAssertEqual(first, second, preset.rawValue)
                XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
                let ids = first.profiles.flatMap(\.routes).flatMap { $0.additionalAgents + $0.stuckEscalation }.map(\.id)
                XCTAssertEqual(Set(ids).count, ids.count, "Each additional worker slot needs its own stable identity.")
                XCTAssertEqual(try JSONDecoder().decode(StandMixerConfiguration.self, from: encoder.encode(first)), first)
            }
            XCTAssertEqual(StandMixerConfiguration.preset(preset, availablePlatforms: []),
                           StandMixerConfiguration.preset(preset, availablePlatforms: [.codex, .claude]))
        }
    }

    func testSingleHarnessFallbackKeepsEveryActiveWorkerNativeAndPreviewsOnlyThatHarness() throws {
        try withFixtureService { service in
            for preset in StandMixerPreset.allCases {
                for platform in [AgentPlatform.codex, .claude] {
                    let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: [platform])
                    let profile = try XCTUnwrap(configuration.profile(for: platform))
                    XCTAssertEqual(profile.routes.map(\.category), roles)
                    for route in profile.effectiveRoutes where route.category != .coordinator {
                        let team = [route.modelID] + (route.additionalAgents + route.stuckEscalation).map(\.modelID)
                        for id in team {
                            XCTAssertEqual(models[id]?.provider, platform, "\(preset.rawValue)/\(platform.rawValue)/\(route.category.rawValue)/\(id)")
                        }
                        XCTAssertEqual(route.effort.mode, .fixed)
                        if !route.additionalAgents.isEmpty {
                            XCTAssertEqual(preset, .high)
                            XCTAssertEqual(route.additionalAgents.map(\.modelID), [platform == .codex ? "gpt-6.2-sol" : "claude-opus-5-5"])
                            XCTAssertEqual(route.additionalAgents.map(\.effort), [.fixed("max")])
                        }
                        XCTAssertEqual(route.resultMode, .coordinator)
                        XCTAssertNil(route.judgeModelID)
                    }
                    let routineCoding = try XCTUnwrap(profile.effectiveRoute(for: .routineCoding))
                    XCTAssertEqual(routineCoding.modelID, platform == .codex ? "gpt-6.2-sol" : "claude-opus-5-5")
                    XCTAssertEqual(routineCoding.effort, .fixed("max"))
                    let planning = try XCTUnwrap(profile.effectiveRoute(for: .planning))
                    XCTAssertEqual(planning.additionalAgents.count, preset == .high ? 1 : 0)
                    let security = try XCTUnwrap(profile.effectiveRoute(for: .securityReview))
                    XCTAssertTrue(security.additionalAgents.isEmpty)
                    let reviewer = platform == .codex ? "gpt-6.2-astra" : "claude-fable-5-2"
                    XCTAssertEqual(security.modelID, reviewer)
                    XCTAssertEqual(security.effort, .fixed("max"))
                    let debugging = try XCTUnwrap(profile.effectiveRoute(for: .debugging))
                    XCTAssertTrue(debugging.additionalAgents.isEmpty)
                    XCTAssertEqual(debugging.stuckEscalation.map(\.modelID),
                                   platform == .codex ? ["gpt-6.2-astra"] : ["claude-fable-5-2", "claude-opus-5-5"])
                    XCTAssertTrue(debugging.stuckEscalation.allSatisfy { $0.effort == .fixed("max") })
                    let coordinator = try XCTUnwrap(profile.route(for: .coordinator))
                    XCTAssertTrue(coordinator.additionalAgents.isEmpty)
                    let preview = try service.preview(configuration: configuration, platforms: [platform])
                    let prefix = (platform == .codex ? service.codexHome : service.claudeHome).path + "/"
                    let codexSkillPaths = Set(service.controlURLs(.codex).map(\.path))
                    XCTAssertTrue(preview.changes.allSatisfy { $0.path.hasPrefix(prefix) || (platform == .codex && codexSkillPaths.contains($0.path)) })
                    let workers = preview.changes.filter { $0.path.contains("/agents/") }
                    XCTAssertFalse(workers.isEmpty)
                    XCTAssertTrue(workers.allSatisfy { !$0.after.contains("<mapped-caller-effort>") }, "Native-only fallbacks must not export cross-CLI drivers.")
                }
            }
        }
    }

    func testExportedPoliciesUseExactEffectiveAssignmentsAndSharedDefinitions() throws {
        try withFixtureService { service in
            for preset in StandMixerPreset.allCases {
                let preview = try service.preview(configuration: .preset(preset, availablePlatforms: [.codex, .claude]))
                for platform in [AgentPlatform.codex, .claude] {
                    let root = platform == .codex ? service.codexHome : service.claudeHome
                    let suffix = platform == .codex ? "AGENTS.md" : "CLAUDE.md"
                    let policy = try XCTUnwrap(preview.changes.first { $0.path == root.appendingPathComponent(suffix).path })
                    let blocks = roleBlocks(policy.after)
                    XCTAssertEqual(blocks.map { String($0.prefix { $0 != ":" }) }, roleTitles.map { "- " + $0 })
                    XCTAssertEqual(blocks.count, roles.count)
                    let teams = expectedTeams(preset, platform)
                    for (index, entry) in zip(blocks, teams).enumerated() {
                        let (block, team) = entry
                        let firstLine = try XCTUnwrap(block.split(separator: "\n").first)
                        let references = firstLine.components(separatedBy: "`").enumerated().compactMap { $0.offset % 2 == 1 ? $0.element : nil }
                        XCTAssertEqual(references, index == 0 ? [] : team.map { (models[$0.id]?.provider == platform ? "standmixer-" : "external-") + "\($0.id)-\($0.effort)" }, "\(preset.rawValue)/\(platform.rawValue)/\(roleTitles[index])")
                        if index == 0 { XCTAssertTrue(block.contains("Auto — use the currently selected native/invoking chat model and its effort.")) }
                        for (slot, worker) in team.enumerated() where index != 0 {
                            let id = worker.id
                            let model = try XCTUnwrap(models[id])
                            let provider = model.provider == platform ? "" : model.provider == .codex ? " via Codex" : " via Claude Code"
                            let number = team.count > 1 ? "\(slot + 1). " : ""
                            let launch = model.provider == platform ? "`standmixer-\(id)-\(worker.effort)`" : "direct external CLI recipe `external-\(id)-\(worker.effort)`"
                            XCTAssertTrue(block.contains("\(number)\(model.label)\(provider), \(worker.effort), \(launch)"))
                        }
                        if team.count > 1 {
                            if roles[index] == .implementation {
                                XCTAssertTrue(block.contains("Lead + review:"))
                                XCTAssertFalse(block.contains("launch all "))
                            } else {
                                XCTAssertTrue(block.contains("Parallel:"))
                                XCTAssertTrue(block.contains("launch all 2 workers concurrently as independent instances"))
                            }
                            XCTAssertFalse(block.contains("The first worker verifies and consolidates"))
                        } else {
                            XCTAssertFalse(block.contains("launch all "))
                        }
                        XCTAssertFalse(block.contains("compare-only"))
                    }
                    let escalation = [Worker("claude-fable-5-2", "max"), Worker("gpt-6.2-astra", "max"), Worker("claude-opus-5-5", "max")]
                    let expectedWorkers = Set((teams.dropFirst().flatMap { $0 } + escalation).filter { models[$0.id]?.provider == platform }.map { "standmixer-\($0.id)-\($0.effort)." + (platform == .codex ? "toml" : "md") })
                    let actualWorkers = preview.changes.filter { $0.path.hasPrefix(root.appendingPathComponent("agents").path + "/") }
                    XCTAssertEqual(Set(actualWorkers.map { URL(fileURLWithPath: $0.path).lastPathComponent }), expectedWorkers)
                    XCTAssertEqual(actualWorkers.count, expectedWorkers.count, "Roles must reuse shared definitions while preserving every launch slot.")
                }
            }
        }
    }

    func testAllPresetControllersLeaveNativeSettingsUnmanaged() throws {
        try withFixtureService { service in
            for preset in StandMixerPreset.allCases {
                let preview = try service.preview(configuration: .preset(preset, availablePlatforms: [.codex, .claude]))
                XCTAssertFalse(preview.changes.contains { $0.path.hasSuffix("config.toml") || $0.path.hasSuffix("settings.json") })
                XCTAssertFalse(preview.changes.contains { $0.after.contains("model = \"auto\"") || $0.after.contains("model: auto") })
            }
        }
    }

    private func roleBlocks(_ policy: String) -> [String] {
        policy.components(separatedBy: "\n- ").dropFirst().map { block in
            // The final role is followed by general delegation guidance, which
            // contains its own examples and is outside the role's launch policy.
            "- " + block.components(separatedBy: "\n\n")[0]
        }
    }

    private func withFixtureService(_ body: (IntegrationService) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-approved-matrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = IntegrationService(home: root.appendingPathComponent("home"),
                                         applicationSupport: root.appendingPathComponent("support"), environment: [:])
        try body(service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path), "Golden exports are previews only; no user settings or CLIs are touched.")
    }
}
