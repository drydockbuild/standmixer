import Foundation
import XCTest
@testable import StandMixerCore

final class SharedWorkerTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-shared-workers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func workers(_ preview: IntegrationPreview) -> [FileChange] {
        preview.changes.filter { $0.path.contains("/agents/") && !$0.isDeletion }
    }
    private func edit(_ configuration: inout StandMixerConfiguration, _ category: WorkCategory, platform: AgentPlatform = .codex, _ update: (inout Route) -> Void) {
        let profile = configuration.profiles.firstIndex { $0.platform == platform }!
        let route = configuration.profiles[profile].routes.firstIndex { $0.category == category }!
        update(&configuration.profiles[profile].routes[route])
    }

    func testDefaultPresetsGenerateOnlyUniqueLaunchDefinitions() throws {
        let optimized = try service.preview(configuration: .defaults)
        XCTAssertEqual(optimized.changes.count, 12)
        XCTAssertEqual(workers(optimized).count, 6)
        for worker in workers(optimized) {
            XCTAssertTrue(worker.after.contains("verify as appropriate to the task"))
            XCTAssertTrue(worker.after.contains("Model selector:"))
            XCTAssertFalse(worker.after.contains("Start visible task labels"), "Native job labels belong to controller launch metadata, not a required child report.")
        }
        for preset in StandMixerPreset.allCases {
            let both = try service.preview(configuration: .preset(preset, availablePlatforms: [.codex, .claude]))
            XCTAssertEqual(both.changes.count, preset == .high ? 11 : 12, preset.rawValue)
            XCTAssertEqual(workers(both).count, preset == .high ? 5 : 6, preset.rawValue)
            for platform in AgentPlatform.allCases {
                let preview = try service.preview(configuration: .preset(preset, availablePlatforms: [platform]), platforms: [platform])
                XCTAssertEqual(preview.changes.count, 5, "\(preset) \(platform)")
                XCTAssertEqual(workers(preview).count, 3, "\(preset) \(platform)")
            }
        }
        let codex = workers(optimized).filter { $0.path.hasPrefix(service.codexHome.path + "/") }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(Set(codex), ["standmixer-gpt-6-astra-auto.toml", "standmixer-gpt-6.1-sol-auto.toml", "standmixer-gpt-6-luna-auto.toml"])
    }

    func testRoleOnlyChangeUpdatesRoutingWithoutRewritingSharedWorkersOrSettings() throws {
        var configuration = StandMixerConfiguration.defaults
        _ = try service.apply(preview: service.preview(configuration: configuration, platforms: [.codex]))
        edit(&configuration, .planning) { $0.modelID = "gpt-6.1-sol" }
        edit(&configuration, .implementation) { $0.modelID = "gpt-6-astra" }
        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        let changed = preview.changes.filter(\.isChanged)
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(changed[0].path.hasSuffix("AGENTS.md"))
        XCTAssertTrue(workers(preview).allSatisfy { !$0.isChanged })
        XCTAssertFalse(preview.changes.contains(where: \.isDeletion))
        XCTAssertFalse(try service.preview(configuration: .defaults, platforms: [.codex]).changes.contains(where: \.isChanged))
    }

    func testRepeatedTeamSlotsAndJudgeReuseOneDefinitionButRequestFreshInstances() throws {
        var configuration = StandMixerConfiguration.defaults
        edit(&configuration, .ui) {
            $0.teamMode = .parallel
            $0.effort = .auto
            $0.additionalAgents = [.init(modelID: $0.modelID, effort: .auto), .init(modelID: $0.modelID, effort: .auto)]
            $0.resultMode = .ai
            $0.judgeModelID = $0.modelID
        }
        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        let matching = workers(preview).filter { $0.path.hasSuffix("standmixer-gpt-6-astra-auto.toml") }
        XCTAssertEqual(matching.count, 1)
        XCTAssertFalse(matching[0].after.contains("compare-only"), "Judge purpose belongs to the fresh task brief, not the reusable worker.")
        let policy = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix("AGENTS.md") })
        XCTAssertTrue(policy.after.contains("launch all 3 workers concurrently as independent instances"))
        XCTAssertTrue(policy.after.contains("including repeated slots using the same definition"))
        XCTAssertTrue(policy.after.contains("launch a fresh `standmixer-gpt-6-astra-auto` instance with a compare-only brief"))
        XCTAssertEqual(policy.after.components(separatedBy: "`standmixer-gpt-6-astra-auto`").count - 1, 6, "Planning, Algorithms, three Visual slots, and the judge share one Auto definition.")
        XCTAssertEqual(configuration.profile(for: .codex)?.route(for: .ui)?.additionalAgents.count, 2)
    }

    func testCanonicalEffortIgnoresInactiveFieldsButAutoFixedAndRangesStayDistinct() throws {
        var configuration = StandMixerConfiguration.defaults
        var auto = EffortPolicy.auto
        auto.value = "ultra"; auto.minimum = "xhigh"
        var range = EffortPolicy.range(minimum: "low", maximum: "high")
        range.value = "ultra"
        edit(&configuration, .planning) { $0.modelID = "gpt-6-astra"; $0.effort = auto }
        edit(&configuration, .ui) { $0.modelID = "gpt-6-astra"; $0.effort = .fixed("medium") }
        edit(&configuration, .algorithms) { $0.modelID = "gpt-6-astra"; $0.effort = range }
        edit(&configuration, .review) { $0.modelID = "gpt-6-astra"; $0.effort = .range(minimum: "low", maximum: "high") }
        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        let astra = workers(preview).filter { $0.path.contains("standmixer-gpt-6-astra-") }
        XCTAssertEqual(astra.count, 3)
        XCTAssertEqual(Set(astra.map { URL(fileURLWithPath: $0.path).lastPathComponent }), ["standmixer-gpt-6-astra-auto.toml", "standmixer-gpt-6-astra-medium.toml", "standmixer-gpt-6-astra-range-low-high.toml"])
        XCTAssertFalse(try XCTUnwrap(astra.first { $0.path.contains("-auto.") }).after.contains("model_reasoning_effort ="))
        XCTAssertTrue(try XCTUnwrap(astra.first { $0.path.contains("-medium.") }).after.contains("model_reasoning_effort = \"medium\""))
        let policy = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix("AGENTS.md") })
        XCTAssertTrue(policy.after.contains("choose and explicitly pass a supported effort within the stated bounds at launch"))
        XCTAssertTrue(policy.after.contains("launch instructions, not runtime enforcement"))
    }

    func testCustomNamesAreStableBoundedAndDistinguishCaseAndPunctuation() throws {
        var configuration = StandMixerConfiguration.defaults
        let ids = ["case/model", "case:model", "CASE/model"]
        configuration.customModels = ids.map { .init(id: $0, label: $0, platform: .codex, defaultEffort: "medium") }
        for (category, id) in zip([WorkCategory.planning, .ui, .algorithms], ids) {
            edit(&configuration, category) { $0.modelID = id; $0.effort = .auto }
        }
        let first = try service.preview(configuration: configuration, platforms: [.codex])
        configuration.profiles[0].routes.reverse()
        let second = try service.preview(configuration: configuration, platforms: [.codex])
        let firstWorkers = Dictionary(uniqueKeysWithValues: workers(first).map { ($0.path, $0.after) })
        XCTAssertEqual(firstWorkers, Dictionary(uniqueKeysWithValues: workers(second).map { ($0.path, $0.after) }))
        let custom = workers(first).filter { $0.path.contains("standmixer-case-model-auto-") }
        XCTAssertEqual(custom.count, 3)
        XCTAssertEqual(Set(custom.map(\.path)).count, 3)
        for file in custom {
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            XCTAssertNotNil(name.range(of: #"^standmixer-case-model-auto-[0-9a-f]{12}\.toml$"#, options: .regularExpression))
            XCTAssertTrue(file.reason.hasPrefix("Shared worker: "))
        }
    }

    func testNativeAndExternalWorkersKeepExactModelsEffortAndActualAttribution() throws {
        var configuration = StandMixerConfiguration.defaults
        edit(&configuration, .ui) { $0.effort = .fixed("ultra") }
        edit(&configuration, .implementation, platform: .claude) { $0.effort = .fixed("ultra") }
        let preview = try service.preview(configuration: configuration)
        let native = try XCTUnwrap(workers(preview).first { $0.path.hasSuffix(".codex/agents/standmixer-gpt-6-astra-ultra.toml") })
        XCTAssertTrue(native.after.contains("model = \"gpt-6-astra\""))
        XCTAssertTrue(native.after.contains("model_reasoning_effort = \"ultra\""))
        XCTAssertFalse(native.after.contains("Do not recursively invoke this same worker"))
        let claudeTarget = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") })
        XCTAssertFalse(claudeTarget.after.contains("model = \"gpt-6-luna\""))
        XCTAssertFalse(claudeTarget.after.contains("model_reasoning_effort = \"medium\""))
        XCTAssertTrue(claudeTarget.after.contains("--model 'claude-opus-5-5'"))
        XCTAssertTrue(claudeTarget.after.contains("--effort '<mapped-caller-effort>'"))
        XCTAssertTrue(claudeTarget.after.contains("Opus 5.5 via Claude Code"))
        let codexTarget = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".claude/skills/standmixer/references/external-workers.md") })
        XCTAssertFalse(codexTarget.after.contains("model: claude-haiku-5-5"))
        XCTAssertTrue(codexTarget.after.contains("-m 'gpt-6.1-sol'"))
        XCTAssertTrue(codexTarget.after.contains("model_reasoning_effort=\"ultra\""))
        XCTAssertTrue(codexTarget.after.contains("Sol 6.1 via Codex"))
        XCTAssertTrue(codexTarget.after.contains("Background launch is not completion"))
    }

    func testMigrationRemovesOnlyOwnedDirectObsoleteFilesAndRestoresExactContents() throws {
        let directory = service.codexHome.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldNames = ["standmixer-planning.toml", "standmixer-ui-2.toml", "standmixer-review-judge.toml", "standmixer-algorithm-review.toml", "standmixer-gpt-6-astra-high.toml"]
        var originals: [String: String] = [:]
        for (index, name) in oldNames.enumerated() {
            let body = "# \(ConfigEdits.ownership)\noriginal \(index)\n"
            originals[name] = body
            try body.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let unowned = directory.appendingPathComponent("standmixer-user-owned.toml")
        try "User content kept exactly".write(to: unowned, atomically: true, encoding: .utf8)
        let nested = directory.appendingPathComponent("nested/standmixer-owned.toml")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigEdits.ownership.write(to: nested, atomically: true, encoding: .utf8)
        try recordOwnedArtifactsFixture(service, contents: Dictionary(uniqueKeysWithValues: originals.map { (directory.appendingPathComponent($0.key), $0.value) }))
        let preview = try service.preview(configuration: .defaults, platforms: [.codex])
        XCTAssertEqual(preview.changes.filter(\.isDeletion).count, oldNames.count)
        XCTAssertFalse(preview.changes.contains { $0.path == unowned.path || $0.path == nested.path })
        _ = try service.apply(preview: preview)
        for name in oldNames { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
        XCTAssertEqual(try String(contentsOf: unowned, encoding: .utf8), "User content kept exactly")
        XCTAssertEqual(try String(contentsOf: nested, encoding: .utf8), ConfigEdits.ownership)
        _ = try service.restoreLast()
        for (name, body) in originals { XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8), body) }
        for change in workers(preview) { XCTAssertFalse(FileManager.default.fileExists(atPath: change.path)) }
    }

    func testNewSharedWorkerCollisionAndCandidateSymlinkCannotOverwriteUserData() throws {
        let directory = service.codexHome.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let collision = directory.appendingPathComponent("standmixer-gpt-6-astra-auto.toml")
        try "Unowned exact-name collision".write(to: collision, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.preview(configuration: .defaults, platforms: [.codex]))
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "Unowned exact-name collision")
        try FileManager.default.removeItem(at: collision)
        let target = root.appendingPathComponent("private-data.txt")
        try "Keep outside target".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("standmixer-old-link.toml"), withDestinationURL: target)
        XCTAssertThrowsError(try service.preview(configuration: .defaults, platforms: [.codex]))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Keep outside target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.appendingPathComponent("config.toml").path))
    }
}
