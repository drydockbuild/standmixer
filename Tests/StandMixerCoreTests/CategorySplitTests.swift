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

    func testCurrentHierarchyHasSixWorkGroupsAndRetainsLegacyAlgorithmRoute() {
        XCTAssertEqual(WorkCategory.topLevelCases, [.planning, .ui, .implementation, .review, .research, .mechanical])
        XCTAssertEqual(WorkCategory.coordinator.children, [])
        XCTAssertNil(WorkCategory.coordinator.parent)
        XCTAssertEqual(WorkCategory.planning.children, [.quickIdeas, .algorithms])
        XCTAssertEqual(WorkCategory.ui.children, [.uiImplementation, .uiReview])
        XCTAssertEqual(WorkCategory.implementation.children, [.routineCoding, .debugging])
        XCTAssertEqual(WorkCategory.review.children, [.developmentSecurity, .securityReview])
        XCTAssertEqual(WorkCategory.research.children, [.draftingEditing, .deepAnalysis])
        XCTAssertEqual(WorkCategory.mechanical.children, [.computerUse])
        XCTAssertEqual(WorkCategory.topLevelCases.flatMap { [$0] + $0.children }, WorkCategory.allCases.dropFirst().map { $0 })
    }

    func testV018ProfilePreservesExplicitRoutesAndAddsInheritedChildren() throws {
        let oldRoutes: [Route] = [
            .init(category: .coordinator, modelID: "gpt-6.1-sol", effort: .fixed("high")),
            .init(category: .planning, modelID: "gpt-6-astra", effort: .auto),
            .init(category: .ui, modelID: "gpt-6.1-terra", effort: .fixed("medium"),
                  additionalAgents: [.init(modelID: "claude-fable-5-1", effort: .fixed("xhigh"))], resultMode: .user),
            .init(category: .implementation, modelID: "gpt-6.1-sol", effort: .range(minimum: "medium", maximum: "ultra")),
            legacyTeam,
            .init(category: .review, modelID: "claude-opus-5-5", effort: .fixed("max")),
            .init(category: .mechanical, modelID: "gpt-6-luna", effort: .fixed("low")),
        ]
        let encoded = try JSONEncoder().encode(RoutingProfile(platform: .codex, routes: oldRoutes))
        var rawProfile = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let originalRows = try XCTUnwrap(rawProfile["routes"] as? [[String: Any]])
        rawProfile["routes"] = originalRows.map { row in
            row.filter { !["inheritsModel", "inheritsEffort", "inheritsTeam"].contains($0.key) }
        }
        let source = try JSONSerialization.data(withJSONObject: rawProfile)
        let current = try JSONDecoder().decode(RoutingProfile.self, from: source)
        XCTAssertEqual(current.routes.map(\.category), WorkCategory.allCases)
        for route in oldRoutes {
            XCTAssertEqual(current.route(for: route.category), route)
            XCTAssertEqual(current.effectiveRoute(for: route.category), route)
        }
        for route in current.routes where route.category.parent != nil && route.category != .algorithms {
            XCTAssertTrue(route.inheritsModel)
            XCTAssertTrue(route.inheritsEffort)
            XCTAssertTrue(route.inheritsTeam)
            XCTAssertTrue(route.stuckEscalation.isEmpty)
            let parent = try XCTUnwrap(route.category.parent)
            var expected = try XCTUnwrap(current.route(for: parent))
            expected.category = route.category
            XCTAssertEqual(current.effectiveRoute(for: route.category), expected)
        }
        XCTAssertEqual(current.route(for: .research)?.modelID, "gpt-6-astra")
        XCTAssertEqual(try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(current)), current)
    }

    func testCompletePreviewProfileGainsDevelopmentSecurityWithoutRepairingMissingOtherRoutes() throws {
        var earlier = try XCTUnwrap(StandMixerConfiguration.defaults.profile(for: .codex))
        earlier.routes.removeAll { $0.category == .developmentSecurity }
        let reviewIndex = try XCTUnwrap(earlier.routes.firstIndex { $0.category == .review })
        earlier.routes[reviewIndex].modelID = "gpt-6.1-sol"
        earlier.routes[reviewIndex].effort = .fixed("high")
        earlier.routes[reviewIndex].additionalAgents = [.init(modelID: "gpt-6-luna", effort: .fixed("low"))]
        earlier.routes[reviewIndex].resultMode = .user
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let migrated = try decoder.decode(RoutingProfile.self, from: encoder.encode(earlier))
        XCTAssertEqual(migrated.routes.filter { $0.category != .developmentSecurity }, earlier.routes)
        let child = try XCTUnwrap(migrated.route(for: .developmentSecurity))
        XCTAssertTrue(child.inheritsModel && child.inheritsEffort && child.inheritsTeam)
        var expected = earlier.routes[reviewIndex]
        expected.category = .developmentSecurity
        XCTAssertEqual(migrated.effectiveRoute(for: .developmentSecurity), expected)

        earlier.routes.removeAll { $0.category == .deepAnalysis }
        let incomplete = try decoder.decode(RoutingProfile.self, from: encoder.encode(earlier))
        XCTAssertNil(incomplete.route(for: .developmentSecurity))
        XCTAssertNil(incomplete.route(for: .deepAnalysis))
        XCTAssertThrowsError(try service.preview(configuration: .init(profiles: [incomplete]), platforms: [.codex]))
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
            rows = rows.filter { row in
                ["coordinator", "planning", "ui", "implementation", "mechanical"].contains(row["category"] as? String ?? "")
            }.map { row in
                row.filter { !["inheritsModel", "inheritsEffort", "inheritsTeam"].contains($0.key) }
            }
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
            XCTAssertEqual(profile.routes.count, WorkCategory.allCases.count)
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

    func testLegacyAppliedReceiptKeepsTheRecordedRoutesWhileDraftMigrates() throws {
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyConfigurationData()) as? [String: Any])
        let source = try JSONSerialization.data(withJSONObject: ["version": 1, "configuration": legacy, "platforms": ["codex"], "records": []])
        let receipt = try XCTUnwrap(service.loadInstallation(String(decoding: source, as: UTF8.self)))
        let recorded = try XCTUnwrap(receipt.configuration)
        let platform = try XCTUnwrap(recorded.profile(for: .codex))
        XCTAssertEqual(platform.routes.count, 7)
        XCTAssertEqual(platform.effectiveRoute(for: .algorithms), legacyTeam)
        XCTAssertNil(platform.effectiveRoute(for: .debugging))
        XCTAssertNil(platform.effectiveRoute(for: .research))
        let status = InstallationStatus(state: .applied, summary: "Fixture", appliedConfiguration: recorded, installedPlatforms: [.codex], hasInstallation: true)
        let roundTrip = try JSONDecoder().decode(InstallationStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(roundTrip.appliedConfiguration, recorded)
        XCTAssertNotNil(try JSONDecoder().decode(StandMixerConfiguration.self, from: legacyConfigurationData()).profile(for: .codex)?.effectiveRoute(for: .debugging))
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
        let algorithm = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix("standmixer-gpt-6-astra-max.toml") })
        let review = try XCTUnwrap(preview.changes.first { $0.path == service.externalWorkerGuideURL(.codex).path })
        XCTAssertTrue(algorithm.after.contains("gpt-6-astra"))
        XCTAssertNotEqual(algorithm.path, review.path, "Optimized Algorithms stays native; Security review uses Fable.")
        XCTAssertTrue(review.after.contains("claude-fable-5-2"))
        let instructions = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix("AGENTS.md") })
        XCTAssertTrue(instructions.after.contains("- Algorithms:"))
        XCTAssertTrue(instructions.after.contains("- Code review:"))
        XCTAssertTrue(instructions.after.contains("- Design & UI:"))
        XCTAssertTrue(instructions.after.contains("Unresolved algorithm or invention design"))
        XCTAssertTrue(instructions.after.contains("- Development security: Bounded security checks during private development, including authentication, permissions, and secret handling."))
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
