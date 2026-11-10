import Foundation
import XCTest
@testable import StandMixerCore

final class CategorySplitTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-category-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRecipesSeparateAlgorithmsFromReviewForBothAndSingleHarnesses() throws {
        XCTAssertEqual(WorkCategory.allCases.map(\.rawValue), ["coordinator", "planning", "ui", "implementation", "algorithms", "review", "mechanical"])
        for available in [Set<AgentPlatform>([.codex]), [.claude], [.codex, .claude]] {
            for preset in StandMixerPreset.allCases {
                let configuration = StandMixerConfiguration.preset(preset, availablePlatforms: available)
                XCTAssertNoThrow(try service.preview(configuration: configuration, platforms: available))
                for platform in available {
                    let profile = try XCTUnwrap(configuration.profile(for: platform))
                    let algorithms = try XCTUnwrap(profile.route(for: .algorithms))
                    let review = try XCTUnwrap(profile.route(for: .review))
                    XCTAssertEqual(algorithms.effort, .auto)
                    XCTAssertEqual(review.effort, .auto)
                    for route in [algorithms, review] {
                        let team = [route.modelID] + route.additionalAgents.map(\.modelID)
                        XCTAssertEqual(Set(team).count, team.count)
                        XCTAssertEqual(route.resultMode, .coordinator)
                        XCTAssertNil(route.judgeModelID)
                    }
                    if preset == .optimized {
                        XCTAssertEqual(algorithms.modelID, platform == .codex ? "gpt-6-astra" : "claude-opus-5-5")
                        XCTAssertEqual(review.modelID, available == [.codex] ? "gpt-6-astra" : "claude-opus-5-5")
                        XCTAssertTrue(algorithms.additionalAgents.isEmpty)
                        XCTAssertEqual(algorithms.teamMode, .leadReview)
                        XCTAssertTrue(review.additionalAgents.isEmpty)
                    } else if preset == .fast {
                        XCTAssertEqual(algorithms.modelID, platform == .codex ? "gpt-6.1-terra" : "claude-sonnet-5-5")
                        let reviewer = available.count == 2
                            ? (platform == .codex ? "claude-opus-5-5" : "gpt-6.1-sol")
                            : (platform == .codex ? "gpt-6.1-sol" : "claude-opus-5-5")
                        XCTAssertEqual(review.modelID, reviewer)
                        XCTAssertTrue(algorithms.additionalAgents.isEmpty)
                        XCTAssertTrue(review.additionalAgents.isEmpty)
                    } else {
                        XCTAssertEqual(algorithms.additionalAgents.count, available.count == 2 ? 2 : 1)
                        XCTAssertEqual(review.additionalAgents.count, 1)
                        XCTAssertEqual(algorithms.modelID, platform == .codex ? "gpt-6-astra" : "claude-fable-5-1")
                        XCTAssertEqual(review.modelID, platform == .codex && available.count == 1 ? "gpt-6-astra" : "claude-opus-5-5")
                    }
                    if available.count == 1 {
                        let catalog = ModelSpec.catalog()
                        for route in [algorithms, review] {
                            let ids = [route.modelID] + route.additionalAgents.map(\.modelID)
                            XCTAssertTrue(ids.allSatisfy { id in catalog.first { $0.id == id }?.platform == platform })
                        }
                    }
                }
            }
        }
    }

    func testFastUsesSingleWorkersWithApprovedSpecialistsForEveryAvailability() throws {
        for available in [Set<AgentPlatform>([.codex]), [.claude], [.codex, .claude]] {
            let configuration = StandMixerConfiguration.preset(.fast, availablePlatforms: available)
            for profile in configuration.profiles where available.contains(profile.platform) {
                XCTAssertEqual(Set(profile.routes.filter { $0.category != .coordinator }.map(\.modelID)).count, available.count == 2 ? 4 : 3)
                for route in profile.routes {
                    XCTAssertTrue(route.additionalAgents.isEmpty)
                    XCTAssertEqual(route.resultMode, .coordinator)
                    XCTAssertNil(route.judgeModelID)
                }
            }
            XCTAssertNoThrow(try service.preview(configuration: configuration, platforms: available))
        }
    }

    private var legacyTeam: Route {
        .init(category: .algorithms, modelID: "my-custom-algorithm-model", effort: .range(minimum: "medium", maximum: "high"),
              additionalAgents: [.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000009999")!, modelID: "gpt-6.1-sol", effort: .fixed("ultra"), modelPlatform: .codex)],
              resultMode: .ai, judgeModelID: "claude-opus-5-5")
    }

    private func legacyConfigurationData(explicitReview: Route? = nil, legacyLast: Bool = false) throws -> Data {
        var configuration = StandMixerConfiguration.defaults
        configuration.customModels = [.init(id: legacyTeam.modelID, label: "My algorithm model", platform: .claude)]
        configuration.enabledPlatforms = [.codex, .claude]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        let encoder = JSONEncoder()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacyTeam)) as? [String: Any])
        legacy["category"] = "algorithmReview"
        for index in profiles.indices {
            var rows = try XCTUnwrap(profiles[index]["routes"] as? [[String: Any]])
            rows.removeAll { ["algorithms", "review"].contains($0["category"] as? String ?? "") }
            var added = [legacy]
            if let explicitReview {
                let explicit = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(explicitReview)) as? [String: Any])
                if legacyLast { added.insert(explicit, at: 0) } else { added.append(explicit) }
            }
            rows += added
            profiles[index]["routes"] = rows
        }
        object["profiles"] = profiles
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testLegacyStoredCombinedRoleClonesExactCustomTeamIntoBothRoles() throws {
        let decoded = try JSONDecoder().decode(StandMixerConfiguration.self, from: legacyConfigurationData())
        for profile in decoded.profiles {
            var expectedReview = legacyTeam
            expectedReview.category = .review
            XCTAssertEqual(profile.routes.count, 7)
            XCTAssertEqual(profile.route(for: .algorithms), legacyTeam)
            XCTAssertEqual(profile.route(for: .review), expectedReview)
        }
        XCTAssertEqual(decoded.customModels.first?.id, legacyTeam.modelID)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("algorithmReview"))
        XCTAssertEqual(try JSONDecoder().decode(StandMixerConfiguration.self, from: Data(encoded.utf8)), decoded)
    }

    func testExplicitNewReviewWinsOverLegacyCombinedRoleInEitherOrder() throws {
        let explicit = Route(category: .review, modelID: "claude-opus-5-5", effort: .fixed("xhigh"), resultMode: .user)
        for legacyLast in [false, true] {
            let decoded = try JSONDecoder().decode(StandMixerConfiguration.self, from: legacyConfigurationData(explicitReview: explicit, legacyLast: legacyLast))
            for profile in decoded.profiles {
                XCTAssertEqual(profile.route(for: .algorithms), legacyTeam)
                XCTAssertEqual(profile.route(for: .review), explicit)
            }
        }
    }

    func testPreviousDraftAndNamedPresetMigrateWithoutWritingDuringRead() throws {
        let data = try legacyConfigurationData()
        let support = service.applicationSupport
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        for name in ["configuration.json", "previous-draft.json"] { try data.write(to: support.appendingPathComponent(name)) }
        let configurationObject = try JSONSerialization.jsonObject(with: data)
        let id = UUID()
        let saved = try JSONSerialization.data(withJSONObject: [["id": id.uuidString, "name": "My preserved custom team", "configuration": configurationObject]])
        try saved.write(to: support.appendingPathComponent("presets.json"))
        let expected = try JSONDecoder().decode(StandMixerConfiguration.self, from: data)
        XCTAssertEqual(try service.loadConfiguration(), expected)
        XCTAssertEqual(try service.loadPreviousDraft(), expected)
        let preset = try XCTUnwrap(service.loadSavedPresets().first)
        XCTAssertEqual(preset.id, id)
        XCTAssertEqual(preset.name, "My preserved custom team")
        XCTAssertEqual(preset.configuration, expected)
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("configuration.json")), data)
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("presets.json")), saved)
    }

    func testLegacyObserverFindingPreservesScopeEvidenceAndTeamForBothRoles() throws {
        let evidence: [[String: String]] = [["path": "/recent/project/CLAUDE.md", "explanation": "Combined saved routing preference"]]
        let raw: [String: Any] = ["category": "algorithmReview", "scope": "usual", "modelID": "claude-fable-5-1", "modelPlatform": "claude",
            "effort": ["mode": "range", "minimum": "medium", "maximum": "high"], "evidence": evidence, "uncertainties": ["Project exception retained"],
            "additionalAgents": [["modelID": "gpt-6.1-sol", "modelPlatform": "codex", "effort": ["mode": "fixed", "value": "ultra"]]],
            "resultMode": "ai", "judgeModelID": "claude-opus-5-5"]
        let payload = try JSONSerialization.data(withJSONObject: ["routes": [raw]])
        let proposal = try AgentImportService.decode(payload, platform: .codex, cwd: root)
        XCTAssertEqual(Set(proposal.routes.map(\.category)), [.algorithms, .review])
        for route in proposal.routes {
            XCTAssertEqual(route.scope, .usual)
            XCTAssertEqual(route.modelID, "claude-fable-5-1")
            XCTAssertEqual(route.effort, .range(minimum: "medium", maximum: "high"))
            XCTAssertEqual(route.evidence.first?.path, "/recent/project/CLAUDE.md")
            XCTAssertEqual(route.additionalAgents?.first?.modelID, "gpt-6.1-sol")
            XCTAssertEqual(route.additionalAgents?.first?.effort, .fixed("ultra"))
            XCTAssertEqual(route.resultMode, .ai)
            XCTAssertEqual(route.judgeModelID, "claude-opus-5-5")
            XCTAssertTrue(route.uncertainties.contains("Project exception retained"))
            XCTAssertTrue(route.uncertainties.contains { $0.contains("does not establish distinct preferences") })
        }
    }

    func testExplicitObserverReviewWinsOverLegacyWithinTheSameScope() throws {
        let legacy: [String: Any] = ["category": "algorithmReview", "scope": "usual", "modelID": "claude-fable-5-1", "evidence": [["path": "legacy", "explanation": "Combined"]]]
        let explicit: [String: Any] = ["category": "review", "scope": "usual", "modelID": "claude-opus-5-5", "evidence": [["path": "explicit", "explanation": "Review only"]]]
        for rows in [[legacy, explicit], [explicit, legacy]] {
            let proposal = try AgentImportService.decode(JSONSerialization.data(withJSONObject: ["routes": rows]), platform: .claude, cwd: root)
            XCTAssertEqual(proposal.routes.first { $0.category == .algorithms }?.modelID, "claude-fable-5-1")
            XCTAssertEqual(proposal.routes.first { $0.category == .review }?.modelID, "claude-opus-5-5")
            XCTAssertEqual(proposal.routes.first { $0.category == .review }?.evidence.first?.path, "explicit")
        }
    }

    func testSplitWorkerFilesAndInstructionsReplaceOwnedLegacyArtifactsAndRestore() throws {
        let agents = service.codexHome.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let legacyNames = ["standmixer-algorithm-review", "standmixer-algorithm-review-2", "standmixer-algorithm-review-3", "standmixer-algorithm-review-4", "standmixer-algorithm-review-judge"]
        let oldBody = ConfigEdits.ownership + "\nLegacy combined role\n"
        for name in legacyNames { try oldBody.write(to: agents.appendingPathComponent(name + ".toml"), atomically: true, encoding: .utf8) }
        try recordOwnedArtifactsFixture(service, contents: Dictionary(uniqueKeysWithValues: legacyNames.map { (agents.appendingPathComponent($0 + ".toml"), oldBody) }))
        let preview = try service.preview(configuration: .defaults, platforms: [.codex])
        let codexSkillPaths = Set(service.controlURLs(.codex).map(\.path))
        XCTAssertTrue(preview.changes.allSatisfy { $0.path.hasPrefix(service.codexHome.path + "/") || codexSkillPaths.contains($0.path) || $0.path == service.externalWorkerGuideURL(.codex).path })
        XCTAssertEqual(preview.changes.filter(\.isDeletion).count, legacyNames.count)
        let algorithm = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix("standmixer-gpt-6-astra-auto.toml") })
        let review = try XCTUnwrap(preview.changes.first { $0.path == service.externalWorkerGuideURL(.codex).path })
        XCTAssertTrue(algorithm.after.contains("gpt-6-astra"))
        XCTAssertNotEqual(algorithm.path, review.path, "Optimized Algorithms stays native; Review uses Opus.")
        XCTAssertTrue(review.after.contains("claude-opus-5-5"))
        let instructions = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix("AGENTS.md") })
        XCTAssertTrue(instructions.after.contains("- Algorithms:"))
        XCTAssertTrue(instructions.after.contains("- Review & Security:"))
        XCTAssertTrue(instructions.after.contains("- Visual:"))
        XCTAssertTrue(instructions.after.contains("Algorithm design and high-intelligence reasoning"))
        XCTAssertTrue(instructions.after.contains("vulnerabilities, including authentication, permissions, and secret handling"))
        XCTAssertFalse(instructions.after.contains("Algorithm review:"))
        _ = try service.apply(preview: preview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: algorithm.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.path))
        for name in legacyNames { XCTAssertFalse(FileManager.default.fileExists(atPath: agents.appendingPathComponent(name + ".toml").path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
        _ = try service.restoreLast()
        for name in legacyNames { XCTAssertEqual(try String(contentsOf: agents.appendingPathComponent(name + ".toml"), encoding: .utf8), oldBody) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: algorithm.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: review.path))
    }

    func testUnownedLegacyWorkerIsNeverDeleted() throws {
        let path = service.claudeHome.appendingPathComponent("agents/standmixer-algorithm-review.md")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "User-owned combined worker".write(to: path, atomically: true, encoding: .utf8)
        let preview = try service.preview(configuration: .defaults, platforms: [.claude])
        XCTAssertFalse(preview.changes.contains { $0.path == path.path })
        _ = try service.apply(preview: preview)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "User-owned combined worker")
    }

    func testSnapshotAndObserverSchemaKeepSeparateRolesAndLegacyCompatibility() throws {
        try FileManager.default.createDirectory(at: service.codexHome, withIntermediateDirectories: true)
        let settings = "[routing]\nalgorithms = \"my-algorithm-setting\"\nreview = \"my-review-setting\"\nalgorithmReview = \"legacy-combined-setting\"\napi_key = \"FORBIDDEN_SECRET\"\n"
        try settings.write(to: service.codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let snapshot = AgentImportSnapshot.capture(platform: .codex, home: service.home, codexHome: service.codexHome, claudeHome: service.claudeHome, project: nil)
        for value in ["my-algorithm-setting", "my-review-setting", "legacy-combined-setting"] { XCTAssertTrue(snapshot.text.contains(value)) }
        XCTAssertFalse(snapshot.text.contains("FORBIDDEN_SECRET"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentImportService.responseSchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let routes = try XCTUnwrap(properties["routes"] as? [String: Any])
        let items = try XCTUnwrap(routes["items"] as? [String: Any])
        let routeProperties = try XCTUnwrap(items["properties"] as? [String: Any])
        let category = try XCTUnwrap(routeProperties["category"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(category["enum"] as? [String])), Set(WorkCategory.allCases.map(\.rawValue) + ["algorithmReview"]))
    }
}
