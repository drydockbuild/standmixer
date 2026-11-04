import Foundation
import XCTest
@testable import AgentMixCore

final class ApprovedPresetMatrixTests: XCTestCase {
    // Independently transcribed from the approved screenshots, including the later
    // Fast correction: native Visual, cross-provider Review & Security. These
    // literal teams do not derive their expectations from the preset factory.
    // The controller cells alone follow the later switch to native/invoking Auto.
    private struct ApprovedPreset {
        let preset: AgentMixPreset
        let codex: [[String]]
        let claude: [[String]]
        func teams(for platform: AgentPlatform) -> [[String]] { platform == .codex ? codex : claude }
    }

    private let approved: [ApprovedPreset] = [
        .init(preset: .fast, codex: [
            ["auto"],
            ["gpt-6.1-sol"],
            ["gpt-6.1-terra"],
            ["gpt-6-luna"],
            ["gpt-6.1-terra"],
            ["claude-opus-5-5"],
            ["gpt-6-luna"],
        ], claude: [
            ["auto"],
            ["claude-opus-5-5"],
            ["claude-sonnet-5-5"],
            ["claude-haiku-5-5"],
            ["claude-sonnet-5-5"],
            ["gpt-6.1-sol"],
            ["claude-haiku-5-5"],
        ]),
        .init(preset: .optimized, codex: [
            ["auto"],
            ["gpt-6-astra"],
            ["gpt-6-astra", "claude-opus-5-5"],
            ["gpt-6.1-sol"],
            ["gpt-6-astra"],
            ["claude-opus-5-5"],
            ["gpt-6-luna"],
        ], claude: [
            ["auto"],
            ["claude-opus-5-5"],
            ["claude-opus-5-5", "claude-fable-5-1"],
            ["gpt-6.1-sol"],
            ["claude-opus-5-5"],
            ["claude-opus-5-5"],
            ["claude-haiku-5-5"],
        ]),
        .init(preset: .high, codex: [
            ["auto"],
            ["gpt-6-astra", "claude-opus-5-5"],
            ["gpt-6-astra", "claude-opus-5-5", "claude-fable-5-1"],
            ["gpt-6-astra"],
            ["gpt-6-astra", "claude-fable-5-1", "claude-opus-5-5"],
            ["claude-opus-5-5", "gpt-6-astra"],
            ["gpt-6-luna"],
        ], claude: [
            ["auto"],
            ["claude-opus-5-5", "claude-fable-5-1"],
            ["claude-opus-5-5", "claude-fable-5-1", "gpt-6-astra"],
            ["claude-opus-5-5"],
            ["claude-fable-5-1", "gpt-6-astra", "claude-opus-5-5"],
            ["claude-opus-5-5", "gpt-6-astra"],
            ["claude-haiku-5-5"],
        ]),
    ]

    private let roles: [WorkCategory] = [.coordinator, .planning, .ui, .implementation, .algorithms, .review, .mechanical]
    private let roleTitles = ["Controller", "Planning", "Visual", "Implementation", "Algorithms", "Review & Security", "Mechanical work"]
    private let models: [String: (label: String, provider: AgentPlatform)] = [
        "gpt-6-astra": ("Astra 6", .codex),
        "gpt-6.1-sol": ("Sol 6.1", .codex),
        "gpt-6.1-terra": ("Terra 6.1", .codex),
        "gpt-6-luna": ("Luna 6", .codex),
        "claude-opus-5-5": ("Opus 5.5", .claude),
        "claude-fable-5-1": ("Fable 5.1", .claude),
        "claude-sonnet-5-5": ("Sonnet 5.5", .claude),
        "claude-haiku-5-5": ("Haiku 5.5", .claude),
    ]

    func testBothHarnessPresetsMatchAll42ApprovedCellsAndOrderedTeams() throws {
        XCTAssertEqual(Set(AgentMixPreset.allCases), Set(approved.map(\.preset)))
        XCTAssertEqual(approved.reduce(0) { $0 + $1.codex.count + $1.claude.count }, 42)
        let catalog = Dictionary(uniqueKeysWithValues: ModelSpec.builtIn.map { ($0.id, $0) })
        for (id, expected) in models {
            XCTAssertEqual(catalog[id]?.label, expected.label, id)
            XCTAssertEqual(catalog[id]?.platform, expected.provider, id)
        }
        for fixture in approved {
            let configuration = AgentMixConfiguration.preset(fixture.preset, availablePlatforms: [.codex, .claude])
            XCTAssertEqual(configuration.profiles.map(\.platform), [.codex, .claude])
            XCTAssertNoThrow(try configuration.validateNativeCoordinators(catalog: ModelSpec.builtIn))
            for platform in [AgentPlatform.codex, .claude] {
                let profile = try XCTUnwrap(configuration.profile(for: platform))
                XCTAssertEqual(profile.routes.map(\.category), roles)
                let expectedTeams = fixture.teams(for: platform)
                for (route, expectedTeam) in zip(profile.routes, expectedTeams) {
                    let context = "\(fixture.preset.rawValue)/\(platform.rawValue)/\(route.category.rawValue)"
                    XCTAssertEqual([route.modelID] + route.additionalAgents.map(\.modelID), expectedTeam, context)
                    XCTAssertEqual(route.effort, .auto, context)
                    XCTAssertTrue(route.additionalAgents.allSatisfy { $0.effort == .auto }, context)
                    XCTAssertEqual(route.teamMode, fixture.preset == .high || route.category == .review ? .parallel : .leadReview, context)
                    XCTAssertEqual(route.resultMode, .coordinator, context)
                    XCTAssertNil(route.judgeModelID, context)
                }
                let coordinator = try XCTUnwrap(profile.route(for: .coordinator))
                XCTAssertTrue(coordinator.additionalAgents.isEmpty)
                XCTAssertTrue(coordinator.isAutoController)
            }
        }
        XCTAssertEqual(AgentMixConfiguration.defaults, .preset(.optimized, availablePlatforms: [.codex, .claude]))
    }

    func testPresetWorkerIdentitiesAreUniqueDeterministicAndPersistWithoutReordering() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let availabilities: [Set<AgentPlatform>] = [[.codex, .claude], [.codex], [.claude], []]
        for fixture in approved {
            for available in availabilities {
                let first = AgentMixConfiguration.preset(fixture.preset, availablePlatforms: available)
                let second = AgentMixConfiguration.preset(fixture.preset, availablePlatforms: available)
                XCTAssertEqual(first, second, fixture.preset.rawValue)
                XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
                let ids = first.profiles.flatMap(\.routes).flatMap(\.additionalAgents).map(\.id)
                XCTAssertEqual(Set(ids).count, ids.count, "Each additional worker slot needs its own stable identity.")
                XCTAssertEqual(try JSONDecoder().decode(AgentMixConfiguration.self, from: encoder.encode(first)), first)
            }
            XCTAssertEqual(AgentMixConfiguration.preset(fixture.preset, availablePlatforms: []),
                           AgentMixConfiguration.preset(fixture.preset, availablePlatforms: [.codex, .claude]))
        }
    }

    func testSingleHarnessFallbackKeepsEveryActiveWorkerNativeAndPreviewsOnlyThatHarness() throws {
        try withFixtureService { service in
            for fixture in approved {
                for platform in [AgentPlatform.codex, .claude] {
                    let configuration = AgentMixConfiguration.preset(fixture.preset, availablePlatforms: [platform])
                    let profile = try XCTUnwrap(configuration.profile(for: platform))
                    XCTAssertEqual(profile.routes.map(\.category), roles)
                    for route in profile.routes where route.category != .coordinator {
                        let team = [route.modelID] + route.additionalAgents.map(\.modelID)
                        for id in team {
                            XCTAssertEqual(models[id]?.provider, platform, "\(fixture.preset.rawValue)/\(platform.rawValue)/\(route.category.rawValue)/\(id)")
                        }
                        XCTAssertEqual(route.effort, .auto)
                        XCTAssertTrue(route.additionalAgents.allSatisfy { $0.effort == .auto })
                        XCTAssertEqual(route.resultMode, .coordinator)
                        XCTAssertNil(route.judgeModelID)
                    }
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

    func testExportedPoliciesPreserveApprovedRoleTeamOrderAndExactConcurrentLaunchCounts() throws {
        try withFixtureService { service in
            for fixture in approved {
                let preview = try service.preview(configuration: .preset(fixture.preset, availablePlatforms: [.codex, .claude]))
                for platform in [AgentPlatform.codex, .claude] {
                    let root = platform == .codex ? service.codexHome : service.claudeHome
                    let suffix = platform == .codex ? "AGENTS.md" : "CLAUDE.md"
                    let policy = try XCTUnwrap(preview.changes.first { $0.path == root.appendingPathComponent(suffix).path })
                    let blocks = roleBlocks(policy.after)
                    XCTAssertEqual(blocks.map { String($0.prefix { $0 != ":" }) }, roleTitles.map { "- " + $0 })
                    XCTAssertEqual(blocks.count, 7)
                    let expectedTeams = fixture.teams(for: platform)
                    for (index, entry) in zip(blocks, expectedTeams).enumerated() {
                        let (block, team) = entry
                        let references = block.components(separatedBy: "`").enumerated().compactMap { $0.offset % 2 == 1 ? $0.element : nil }
                        XCTAssertEqual(references, index == 0 ? [] : team.map { (models[$0]?.provider == platform ? "agentmix-" : "external-") + "\($0)-auto" }, "\(fixture.preset.rawValue)/\(platform.rawValue)/\(roleTitles[index])")
                        if index == 0 { XCTAssertTrue(block.contains("Auto — use the currently selected native/invoking chat model and its effort.")) }
                        for (slot, id) in team.enumerated() where index != 0 {
                            let model = try XCTUnwrap(models[id])
                            let provider = model.provider == platform ? "" : model.provider == .codex ? " via Codex" : " via Claude Code"
                            let number = team.count > 1 ? "\(slot + 1). " : ""
                            let launch = model.provider == platform ? "`agentmix-\(id)-auto`" : "direct external CLI recipe `external-\(id)-auto`"
                            XCTAssertTrue(block.contains("\(number)\(model.label)\(provider), follow caller, \(launch)"))
                        }
                        if team.count > 1 {
                            if fixture.preset == .high || roles[index] == .review {
                                XCTAssertTrue(block.contains("Parallel:"))
                                XCTAssertTrue(block.contains("launch all \(team.count) workers concurrently as independent instances"))
                            } else {
                                XCTAssertTrue(block.contains("Lead + review:"))
                                XCTAssertFalse(block.contains("as independent instances"))
                            }
                            XCTAssertTrue(block.contains("The first worker verifies and consolidates"))
                        } else {
                            XCTAssertFalse(block.contains("launch all "))
                        }
                        XCTAssertFalse(block.contains("compare-only"))
                    }
                    let expectedWorkers = Set(expectedTeams.dropFirst().flatMap { $0 }.filter { models[$0]?.provider == platform }.map { "agentmix-\($0)-auto." + (platform == .codex ? "toml" : "md") })
                    let actualWorkers = preview.changes.filter { $0.path.hasPrefix(root.appendingPathComponent("agents").path + "/") }
                    XCTAssertEqual(Set(actualWorkers.map { URL(fileURLWithPath: $0.path).lastPathComponent }), expectedWorkers)
                    XCTAssertEqual(actualWorkers.count, expectedWorkers.count, "Roles must reuse shared definitions while preserving every launch slot.")
                }
            }
        }
    }

    func testAllPresetControllersLeaveNativeSettingsUnmanaged() throws {
        try withFixtureService { service in
            for preset in AgentMixPreset.allCases {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentmix-approved-matrix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = IntegrationService(home: root.appendingPathComponent("home"),
                                         applicationSupport: root.appendingPathComponent("support"), environment: [:])
        try body(service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path), "Golden exports are previews only; no user settings or CLIs are touched.")
    }
}
