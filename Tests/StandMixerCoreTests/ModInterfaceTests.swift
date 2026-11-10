import Foundation
import XCTest
@testable import StandMixerCore

final class ModInterfaceTests: XCTestCase {
    func testVersionCheckAcceptsNoOverridesAndFixtureModeHasNoNetworkOrWrites() async throws {
        let fixture = IntegrationService(home: root.appendingPathComponent("version-fixture"), environment: [:], metadataOnlyDiscovery: true)
        let api = StandMixerModInterface(service: fixture, connections: connections)
        for extra in ["\"url\":\"https://example.invalid\"", "\"configuration\":{}"] {
            let response = await api.runJSON(Data("{\"action\":\"checkUpdates\",\(extra)}".utf8))
            XCTAssertEqual(response.exitCode, 1)
        }
        let result = try await send(.init(action: .checkUpdates, refresh: true), to: api)
        XCTAssertEqual(result.0.exitCode, 0)
        XCTAssertNil(result.1["update"])
        let stateResult = try await send(.init(action: .state), to: api)
        XCTAssertFalse(try state(stateResult.1).canCheckUpdates)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.applicationSupport.path))
    }

    func testExplicitInterfaceOpeningActionsHaveNoRequestPathsAndDoNotAlterSettings() async throws {
        actor Calls { var values: [String] = []; func add(_ value: String) { values.append(value) } }
        let calls = Calls()
        let api = StandMixerModInterface(service: service, connections: connections,
            webOpener: { await calls.add("web"); return .init(url: "http://127.0.0.1:12345/#token=" + String(repeating: "a", count: 43)) },
            macOpener: { await calls.add("mac"); return .init(message: "Opened StandMixer.", changedFiles: 0) })
        let opened = try await send(.init(action: .openWeb), to: api)
        XCTAssertEqual(opened.0.exitCode, 0)
        XCTAssertNotNil((opened.1["web"] as? [String: Any])?["url"])
        let openedMac = try await send(.init(action: .openMac), to: api)
        XCTAssertEqual(openedMac.0.exitCode, 0)
        for action in ["openWeb", "openMac"] {
            let bad = await api.runJSON(Data("{\"action\":\"\(action)\",\"path\":\"/private\"}".utf8))
            XCTAssertNotEqual(bad.exitCode, 0)
        }
        let values = await calls.values
        XCTAssertEqual(values, ["web", "mac"])
        let status = try await send(.init(action: .state), to: api)
        XCTAssertEqual(try state(status.1).installedMac?.isAvailable, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
    }
    private var root: URL!
    private var service: IntegrationService!
    private var connections: [ConnectionStatus] {
        AgentPlatform.allCases.map { .init(platform: $0, path: "/fixture/\($0.rawValue)", version: "1.0.0", detail: "Fixture only", isInstalled: true) }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-mod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = freshService()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func freshService() -> IntegrationService {
        .init(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:],
              executableURL: root.appendingPathComponent("support/bin/StandMixerHelper"), metadataOnlyDiscovery: true)
    }
    private func interface(_ service: IntegrationService? = nil) -> StandMixerModInterface {
        .init(service: service ?? self.service, connections: connections)
    }
    private func send(_ request: StandMixerModRequest, to api: StandMixerModInterface? = nil) async throws -> (StandMixerModExecution, [String: Any]) {
        let execution = await (api ?? interface()).runJSON(try JSONEncoder().encode(request))
        return (execution, try XCTUnwrap(JSONSerialization.jsonObject(with: execution.output) as? [String: Any]))
    }
    private func preview(_ preset: StandMixerPreset = .optimized, to api: StandMixerModInterface? = nil,
                         platforms: Set<AgentPlatform> = [.codex, .claude]) async throws -> [String: Any] {
        let result = try await send(.init(action: .preview, configuration: .preset(preset, availablePlatforms: platforms), platforms: platforms), to: api)
        XCTAssertEqual(result.0.exitCode, 0, String(decoding: result.0.output, as: UTF8.self))
        return try XCTUnwrap(result.1["preview"] as? [String: Any])
    }
    private func id(_ preview: [String: Any]) throws -> UUID { try XCTUnwrap(UUID(uuidString: try XCTUnwrap(preview["id"] as? String))) }
    private func write(_ relative: String, _ value: String) throws {
        let url = service.home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ relative: String) throws -> String { try String(contentsOf: service.home.appendingPathComponent(relative), encoding: .utf8) }
    private func state(_ response: [String: Any]) throws -> StandMixerModState {
        try JSONDecoder().decode(StandMixerModState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(response["state"])))
    }

    func testNamedPresetsUpsertDeleteAndNeverClaimToBeAppliedOrReplaceDraft() async throws {
        var draft = StandMixerConfiguration.preset(.fast, availablePlatforms: [.claude])
        draft.enabledPlatforms = [.claude]
        try service.saveConfiguration(draft)
        let nativeBefore = "{\"model\":\"sonnet\",\"env\":{\"PRIVATE_VALUE\":\"fixture-secret\"}}\n"
        try write(".claude/settings.json", nativeBefore)
        let preset = StandMixerConfiguration.preset(.high, availablePlatforms: [.claude])
        let saved = try await send(.init(action: .savePreset, configuration: preset, platforms: [.claude], name: "  Studio  "))
        XCTAssertEqual(saved.0.exitCode, 0, String(decoding: saved.0.output, as: UTF8.self))
        let first = try state(saved.1)
        XCTAssertEqual(first.savedPresets.map(\.name), ["Studio"])
        XCTAssertEqual(first.configuration, draft)
        XCTAssertNil(first.installation.appliedConfiguration)
        XCTAssertEqual(first.installation.state, .notInstalled)
        XCTAssertEqual(try read(".claude/settings.json"), nativeBefore)
        XCTAssertEqual((saved.1["result"] as? [String: Any])?["changedFiles"] as? Int, 0)

        let replaced = try await send(.init(action: .savePreset, configuration: .preset(.optimized, availablePlatforms: [.claude]), platforms: [.claude], name: "studio"))
        let updated = try state(replaced.1)
        XCTAssertEqual(updated.savedPresets.count, 1)
        XCTAssertEqual(updated.savedPresets.first?.id, first.savedPresets.first?.id)
        XCTAssertEqual(updated.savedPresets.first?.name, "studio")
        XCTAssertEqual(updated.configuration, draft)
        let deleted = try await send(.init(action: .deletePreset, presetID: XCTUnwrap(first.savedPresets.first?.id)))
        XCTAssertEqual(deleted.0.exitCode, 0)
        XCTAssertTrue(try state(deleted.1).savedPresets.isEmpty)
        XCTAssertEqual(try service.loadConfiguration(), draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.receiptURL.path))
    }

    func testSavingDraftPreservesPreviousAndStateReadsDoNotRewriteEitherDraft() async throws {
        var first = StandMixerConfiguration.preset(.fast, availablePlatforms: [.claude])
        first.enabledPlatforms = [.claude]
        let saved = try await send(.init(action: .saveDraft, configuration: first, platforms: [.claude]))
        XCTAssertEqual(saved.0.exitCode, 0, String(decoding: saved.0.output, as: UTF8.self))
        XCTAssertNil(try state(saved.1).previousDraft)
        var next = StandMixerConfiguration.preset(.high, availablePlatforms: [.claude])
        next.enabledPlatforms = [.claude]
        let changed = try await send(.init(action: .saveDraft, configuration: next, platforms: [.claude]))
        XCTAssertEqual(changed.0.exitCode, 0)
        XCTAssertEqual(try state(changed.1).configuration, next)
        XCTAssertEqual(try state(changed.1).previousDraft, first)
        let unchanged = try await send(.init(action: .saveDraft, configuration: next, platforms: [.claude]))
        XCTAssertEqual(try state(unchanged.1).previousDraft, first, "Saving the same draft must not erase the useful previous recipe.")
        let currentURL = service.applicationSupport.appendingPathComponent("configuration.json")
        let previousURL = service.applicationSupport.appendingPathComponent("previous-draft.json")
        let before = try [Data(contentsOf: currentURL), Data(contentsOf: previousURL)]
        let read = try await send(.init(action: .state, platforms: [.codex]))
        XCTAssertEqual(try state(read.1).previousDraft, first)
        XCTAssertEqual(try Data(contentsOf: currentURL), before[0])
        XCTAssertEqual(try Data(contentsOf: previousURL), before[1])
        XCTAssertNil(try state(read.1).installation.appliedConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
    }

    func testReviewedApplyPreservesTheEditableDraftWithoutInstallingItBeforeReview() async throws {
        var original = StandMixerConfiguration.preset(.fast, availablePlatforms: [.codex, .claude])
        original.enabledPlatforms = [.codex, .claude]
        try service.saveConfiguration(original)
        let plan = try await preview(.high)
        XCTAssertEqual(try service.loadConfiguration(), original)
        XCTAssertNil(try service.loadPreviousDraft())
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
        let applied = try await send(.init(action: .apply, previewID: id(plan)))
        XCTAssertEqual(applied.0.exitCode, 0, String(decoding: applied.0.output, as: UTF8.self))
        XCTAssertEqual(try service.loadPreviousDraft(), original)
        let current = try state(try await send(.init(action: .state)).1)
        XCTAssertEqual(current.previousDraft, original)
        XCTAssertEqual(current.configuration, current.installation.appliedConfiguration)
        XCTAssertEqual(current.installation.state, .applied)
    }

    func testCustomNativeIdentityDefaultsAndInvalidDraftsCannotBypassCanonicalCatalog() async throws {
        let minimal = Data("{\"id\":\"my-claude-alias\",\"label\":\"Custom Claude\",\"platform\":\"claude\"}".utf8)
        let custom = try JSONDecoder().decode(ModelSpec.self, from: minimal)
        XCTAssertEqual(custom.supportedEfforts, Array(EffortPolicy.levels.dropLast()))
        XCTAssertFalse(custom.isDiscovered)
        var draft = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.claude])
        draft.customModels = [custom]
        let profile = try XCTUnwrap(draft.profiles.firstIndex { $0.platform == .claude })
        let coordinator = try XCTUnwrap(draft.profiles[profile].routes.firstIndex { $0.category == .coordinator })
        draft.profiles[profile].routes[coordinator].modelID = custom.id
        let saved = try await send(.init(action: .saveDraft, configuration: draft, platforms: [.claude]))
        XCTAssertEqual(saved.0.exitCode, 0, String(decoding: saved.0.output, as: UTF8.self))
        XCTAssertEqual(try state(saved.1).catalog.first { $0.id == custom.id }?.platform, .claude)
        let persisted = try service.loadConfiguration()
        draft.customModels = [.init(id: "gpt-6.1-sol", label: "Pretend native Claude", platform: .claude)]
        draft.profiles[profile].routes[coordinator].modelID = "gpt-6.1-sol"
        for action in [StandMixerModRequest.Action.saveDraft, .savePreset, .preview] {
            let rejected = try await send(.init(action: action, configuration: draft, platforms: [.claude], name: action == .savePreset ? "Invalid" : nil))
            XCTAssertNotEqual(rejected.0.exitCode, 0)
            XCTAssertEqual((rejected.1["error"] as? [String: Any])?["code"] as? String, "invalidConfiguration")
        }
        XCTAssertEqual(try service.loadConfiguration(), persisted)
        XCTAssertTrue(try service.loadSavedPresets().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
    }

    func testNativeCoordinatorMetadataComesFromSavedGlobalPrimitivesWithoutLeakingSettings() async throws {
        try write(".claude/settings.json", "{\"model\":\"fable[1m]\",\"effortLevel\":\"low\",\"modelSettings\":{\"fable[1m]\":{\"effortLevel\":\"xhigh\"}},\"env\":{\"TOKEN\":\"fixture-claude-secret\"},\"permissions\":{\"allow\":[\"fixture-private-rule\"]}}")
        try write(".codex/config.toml", "model = \"gpt-6-luna\"\nmodel_reasoning_effort = \"low\"\nprofile = \"work\"\nprivate_key = \"fixture-codex-secret\"\n[profiles.work]\nmodel = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"ultra\"\n")
        let result = try await send(.init(action: .state))
        XCTAssertEqual(result.0.exitCode, 0)
        let current = try state(result.1)
        let claude = try XCTUnwrap(current.nativeSettings.first { $0.platform == .claude })
        XCTAssertEqual(claude.modelID, "fable[1m]")
        XCTAssertEqual(claude.effort, "xhigh")
        XCTAssertEqual(claude.status, "known")
        XCTAssertEqual(claude.sourcePath, service.claudeHome.appendingPathComponent("settings.json").path)
        let codex = try XCTUnwrap(current.nativeSettings.first { $0.platform == .codex })
        XCTAssertEqual(codex.modelID, "gpt-6.1-sol")
        XCTAssertEqual(codex.effort, "ultra")
        XCTAssertNil(current.installation.appliedConfiguration)
        let output = String(decoding: result.0.output, as: UTF8.self)
        for value in ["fixture-claude-secret", "fixture-private-rule", "fixture-codex-secret", "private_key"] { XCTAssertFalse(output.contains(value)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testNativeMetadataDoesNotFollowLinksOrClaimTruncatedSourcesAreKnown() async throws {
        let external = root.appendingPathComponent("external-settings.json")
        try "{\"model\":\"fixture-secret-model\"}".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: service.claudeHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: service.claudeHome.appendingPathComponent("settings.json"), withDestinationURL: external)
        try write(".codex/config.toml", "model = \"gpt-6.1-sol\"\n" + String(repeating: "# bounded metadata fixture\n", count: 4000))
        let result = try await send(.init(action: .state))
        XCTAssertEqual(result.0.exitCode, 0)
        let current = try state(result.1)
        for setting in current.nativeSettings { XCTAssertNil(setting.modelID); XCTAssertNotEqual(setting.status, "known") }
        XCTAssertFalse(String(decoding: result.0.output, as: UTF8.self).contains("fixture-secret-model"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testPresetAndDraftActionsValidateShapeAndHonorSharedProcessLock() async throws {
        for request in [StandMixerModRequest(action: .savePreset, configuration: .defaults, platforms: [.codex, .claude]),
                        .init(action: .deletePreset, configuration: .defaults, presetID: UUID()),
                        .init(action: .state, refresh: false),
                        .init(action: .saveDraft, configuration: .defaults, platforms: [.codex, .claude], previewID: UUID())] {
            let result = try await send(request)
            XCTAssertNotEqual(result.0.exitCode, 0)
            XCTAssertEqual((result.1["error"] as? [String: Any])?["code"] as? String, "invalidRequest")
        }
        let another = interface(freshService())
        let request = try JSONEncoder().encode(StandMixerModRequest(action: .savePreset, configuration: .defaults, platforms: [.codex, .claude], name: "Locked"))
        try service.acquireOperationLock()
        let lockedResult = await another.runJSON(request)
        service.releaseOperationLock()
        XCTAssertNotEqual(lockedResult.exitCode, 0)
        XCTAssertTrue(try service.loadSavedPresets().isEmpty)
        let independent = freshService()
        try service.withOperationLock {
            XCTAssertThrowsError(try independent.savePreset(name: "Blocked", configuration: .defaults))
            XCTAssertThrowsError(try independent.saveConfiguration(.defaults))
            XCTAssertThrowsError(try independent.deletePreset(id: UUID()))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
    }

    func testFreshStateIsOptimizedAndCreatesNoSettingsOrSupportFiles() async throws {
        let result = try await send(.init(action: .state))
        XCTAssertEqual(result.0.exitCode, 0)
        let state = try XCTUnwrap(result.1["state"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: state)
        let decoded = try JSONDecoder().decode(StandMixerModState.self, from: data)
        XCTAssertEqual(decoded.configuration.profiles, StandMixerConfiguration.defaults.profiles)
        XCTAssertEqual(decoded.enabledPlatforms, [.claude, .codex])
        XCTAssertFalse(decoded.hasSavedDraft)
        XCTAssertEqual(decoded.installation.state, .notInstalled)
        XCTAssertEqual(decoded.catalog.first { $0.id == "claude-opus-5-5" }?.platform, .claude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testSavedDraftAndProviderPreferenceStaySeparateFromAppliedStatus() async throws {
        var saved = StandMixerConfiguration.preset(.high, availablePlatforms: [.claude])
        saved.enabledPlatforms = [.claude]
        try service.saveConfiguration(saved)
        let result = try await send(.init(action: .state))
        let state = try JSONDecoder().decode(StandMixerModState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(result.1["state"])))
        XCTAssertEqual(state.configuration, saved)
        XCTAssertEqual(state.enabledPlatforms, [.claude])
        XCTAssertTrue(state.hasSavedDraft)
        XCTAssertNil(state.installation.appliedConfiguration)
        XCTAssertEqual(state.installation.state, .notInstalled)
        for preset in state.presets {
            XCTAssertEqual(preset.configuration.profile(for: .claude), StandMixerConfiguration.preset(preset.id, availablePlatforms: [.claude]).profile(for: .claude))
        }
        let override = try await send(.init(action: .state, platforms: [.codex]))
        let overridden = try JSONDecoder().decode(StandMixerModState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(override.1["state"])))
        XCTAssertEqual(overridden.enabledPlatforms, [.codex])
        XCTAssertEqual(try service.loadConfiguration(), saved)
    }

    func testCrossProcessApplyUsesExactPrivateReviewedPlanAndConsumesID() async throws {
        let plan = try await preview(.fast)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        let previewID = try id(plan)
        let directory = service.applicationSupport.appendingPathComponent("Previews")
        let path = directory.appendingPathComponent(previewID.uuidString + ".json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        let privatePlan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let otherProcess = interface(freshService())
        let result = try await send(.init(action: .apply, previewID: previewID), to: otherProcess)
        XCTAssertEqual(result.0.exitCode, 0, String(decoding: result.0.output, as: UTF8.self))
        for change in try XCTUnwrap(privatePlan["changes"] as? [[String: Any]]) {
            let target = try XCTUnwrap(change["path"] as? String)
            XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), change["after"] as? String)
        }
        XCTAssertEqual(try service.installationStatus().appliedConfiguration?.profiles,
                       StandMixerConfiguration.preset(.fast, availablePlatforms: [.codex, .claude]).profiles)
        XCTAssertTrue(try read(".claude/skills/standmixer/SKILL.md").contains("support/bin/standmixer"))
        let repeated = try await send(.init(action: .apply, previewID: previewID))
        XCTAssertNotEqual(repeated.0.exitCode, 0)
        XCTAssertEqual((repeated.1["error"] as? [String: Any])?["code"] as? String, "previewExpired")
    }

    func testUnavailableSavedProviderIsExcludedWithoutRewritingDraftAndPresetsUseNativeFallback() async throws {
        var saved = StandMixerConfiguration.preset(.high, availablePlatforms: [.codex, .claude])
        saved.enabledPlatforms = [.codex, .claude]
        try service.saveConfiguration(saved)
        let available = connections.map { connection -> ConnectionStatus in
            var value = connection; value.isInstalled = value.platform == .claude; return value
        }
        let api = StandMixerModInterface(service: service, connections: available)
        let result = try await send(.init(action: .state), to: api)
        let state = try JSONDecoder().decode(StandMixerModState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(result.1["state"])))
        XCTAssertEqual(state.enabledPlatforms, [.claude])
        XCTAssertEqual(state.preferredPlatforms, [.claude, .codex])
        XCTAssertEqual(state.configuration.profiles, saved.profiles)
        XCTAssertEqual(try service.loadConfiguration(), saved)
        XCTAssertFalse(state.notes.isEmpty)
        for preset in state.presets {
            XCTAssertEqual(preset.configuration.profile(for: .claude), StandMixerConfiguration.preset(preset.id, availablePlatforms: [.claude]).profile(for: .claude))
        }
    }

    func testPublicPreviewExposesChangedLinesWithoutUnrelatedSettingsAndRejectsOversizedOutput() async throws {
        let secret = "unrelated-secret-keep-out-of-review"
        try write(".claude/settings.json", "{\n\"private\":\"\(secret)\",\n" + String(repeating: "\n", count: 12) + "\"model\":\"before\"\n}\n")
        let planned = try await send(.init(action: .preview, configuration: pinnedControllers(), platforms: [.codex, .claude]))
        let plan = try XCTUnwrap(planned.1["preview"] as? [String: Any])
        let changes = try XCTUnwrap(plan["changes"] as? [[String: Any]])
        let native = try XCTUnwrap(changes.first { ($0["path"] as? String)?.hasSuffix(".claude/settings.json") == true })
        XCTAssertNil(native["before"])
        XCTAssertNil(native["after"])
        let encoded = try JSONSerialization.data(withJSONObject: native)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
        // A removed native Auto effort is one exact line. A huge removed line
        // must yield a complete bounded error, never a partial review with Apply.
        let large = String(repeating: "x", count: StandMixerModInterface.maximumResponseBytes + 4096)
        try write(".codex/config.toml", "model = 'before'\nmodel_reasoning_effort = '\(large)'\n")
        let result = try await send(.init(action: .preview, configuration: pinnedControllers(.preset(.optimized, availablePlatforms: [.codex])), platforms: [.codex]))
        XCTAssertNotEqual(result.0.exitCode, 0)
        XCTAssertLessThan(result.0.output.count, StandMixerModInterface.maximumResponseBytes)
        XCTAssertEqual((result.1["error"] as? [String: Any])?["code"] as? String, "previewTooLarge")
        XCTAssertTrue(try read(".codex/config.toml").contains(large))
    }

    func testPreviewRejectsDisabledWorkerProviderButAllowsTheSameRecipeWithBothProviders() async throws {
        var recipe = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.claude])
        let claude = try XCTUnwrap(recipe.profiles.firstIndex { $0.platform == .claude })
        let implementation = try XCTUnwrap(recipe.profiles[claude].routes.firstIndex { $0.category == .implementation })
        recipe.profiles[claude].routes[implementation].modelID = "gpt-6.1-sol"
        // Catalog identities remain authoritative even if a draft tries to
        // relabel a known Codex model as a Claude model.
        recipe.customModels.append(.init(id: "gpt-6.1-sol", label: "Claimed native", platform: .claude))
        let disabled = try await send(.init(action: .preview, configuration: recipe, platforms: [.claude]))
        XCTAssertNotEqual(disabled.0.exitCode, 0)
        let error = try XCTUnwrap(disabled.1["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalidConfiguration")
        XCTAssertTrue((error["message"] as? String)?.contains("Enable Codex") == true)
        XCTAssertTrue((error["message"] as? String)?.contains("Sol 6.1") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
        let enabled = try await send(.init(action: .preview, configuration: recipe, platforms: [.claude, .codex]))
        XCTAssertEqual(enabled.0.exitCode, 0, String(decoding: enabled.0.output, as: UTF8.self))
        XCTAssertNotNil(enabled.1["preview"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
    }

    func testPreviewRejectsDisabledAdditionalWorkersAndAIJudgesWhileIgnoringDisabledHostDrafts() async throws {
        var recipe = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.claude])
        let claude = try XCTUnwrap(recipe.profiles.firstIndex { $0.platform == .claude })
        let implementation = try XCTUnwrap(recipe.profiles[claude].routes.firstIndex { $0.category == .implementation })
        recipe.profiles[claude].routes[implementation].additionalAgents = [.init(modelID: "gpt-6.1-sol")]
        let worker = try await send(.init(action: .preview, configuration: recipe, platforms: [.claude]))
        XCTAssertNotEqual(worker.0.exitCode, 0)
        recipe.profiles[claude].routes[implementation].additionalAgents = [.init(modelID: "claude-haiku-5-5")]
        recipe.profiles[claude].routes[implementation].resultMode = .ai
        recipe.profiles[claude].routes[implementation].judgeModelID = "gpt-6.1-sol"
        let judge = try await send(.init(action: .preview, configuration: recipe, platforms: [.claude]))
        XCTAssertNotEqual(judge.0.exitCode, 0)
        XCTAssertTrue(((judge.1["error"] as? [String: Any])?["message"] as? String)?.contains("Enable Codex") == true)
        recipe.profiles[claude].routes[implementation].judgeModelID = "claude-opus-5-5"
        // The disabled Codex host keeps its own draft, including workers from
        // its currently disabled provider. That does not block active Claude.
        let codex = try XCTUnwrap(recipe.profiles.firstIndex { $0.platform == .codex })
        XCTAssertTrue(recipe.profiles[codex].routes.contains { $0.modelID.hasPrefix("gpt-") })
        let valid = try await send(.init(action: .preview, configuration: recipe, platforms: [.claude]))
        XCTAssertEqual(valid.0.exitCode, 0, String(decoding: valid.0.output, as: UTF8.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
    }

    func testStalePreviewRefusesBeforeChangingAnyHarnessFile() async throws {
        let planned = try await send(.init(action: .preview, configuration: pinnedControllers(), platforms: [.codex, .claude]))
        let plan = try XCTUnwrap(planned.1["preview"] as? [String: Any])
        try write(".codex/config.toml", "model = 'my-new-choice'\n")
        let result = try await send(.init(action: .apply, previewID: id(plan)))
        XCTAssertNotEqual(result.0.exitCode, 0)
        XCTAssertEqual((result.1["error"] as? [String: Any])?["code"] as? String, "conflict")
        XCTAssertEqual(try read(".codex/config.toml"), "model = 'my-new-choice'\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.appendingPathComponent("AGENTS.md").path))
    }

    func testChangedSavedDraftOrInstallationRejectsStoredPlan() async throws {
        let first = try await preview(.fast)
        try service.saveConfiguration(.defaults)
        let result = try await send(.init(action: .apply, previewID: id(first)))
        XCTAssertNotEqual(result.0.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        let second = try await preview(.fast)
        _ = try service.apply(preview: service.previewCommands(platforms: [.codex]))
        let stale = try await send(.init(action: .apply, previewID: id(second)))
        XCTAssertNotEqual(stale.0.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.appendingPathComponent("config.toml").path))
    }

    func testUninstallRestoresFirstBaselineAcrossMultipleReviewedApplies() async throws {
        let original = "model = 'original-model'\nmodel_reasoning_effort = 'medium'\nkeep = true\n"
        try write(".codex/config.toml", original)
        for preset in [StandMixerPreset.fast, .high] {
            let configuration = pinnedControllers(.preset(preset, availablePlatforms: [.codex, .claude]),
                                                  codex: preset == .fast ? "gpt-6-luna" : "gpt-6-astra",
                                                  claude: preset == .fast ? "claude-haiku-5-5" : "claude-opus-5-5")
            let planned = try await send(.init(action: .preview, configuration: configuration, platforms: [.codex, .claude]))
            let plan = try XCTUnwrap(planned.1["preview"] as? [String: Any])
            let result = try await send(.init(action: .apply, previewID: id(plan)))
            XCTAssertEqual(result.0.exitCode, 0)
        }
        let plan = try await send(.init(action: .previewUninstall))
        let uninstall = try XCTUnwrap(plan.1["preview"] as? [String: Any])
        XCTAssertTrue(try read(".codex/config.toml").contains("gpt-6-astra"))
        let result = try await send(.init(action: .uninstall, previewID: id(uninstall)), to: interface(freshService()))
        XCTAssertEqual(result.0.exitCode, 0, String(decoding: result.0.output, as: UTF8.self))
        let restored = try read(".codex/config.toml")
        XCTAssertEqual(try ConfigEdits.nativeValue(restored, platform: .codex, path: ["model"]), ConfigEdits.tomlString("original-model"))
        XCTAssertEqual(try ConfigEdits.nativeValue(restored, platform: .codex, path: ["model_reasoning_effort"]), ConfigEdits.tomlString("medium"))
        XCTAssertTrue(restored.contains("keep = true"))
        XCTAssertEqual(try service.installationStatus().state, .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.applicationSupport.appendingPathComponent("configuration.json").path))
    }

    func testRestoreReviewsLastOperationAndRefusesAChangedBackup() async throws {
        var plan = try await preview(.fast)
        _ = try await send(.init(action: .apply, previewID: id(plan)))
        plan = try await preview(.high)
        _ = try await send(.init(action: .apply, previewID: id(plan)))
        let restore = try await send(.init(action: .previewRestore))
        let restorePlan = try XCTUnwrap(restore.1["preview"] as? [String: Any])
        let result = try await send(.init(action: .restore, previewID: id(restorePlan)))
        XCTAssertEqual(result.0.exitCode, 0, String(decoding: result.0.output, as: UTF8.self))
        XCTAssertEqual(try service.installationStatus().appliedConfiguration?.profiles,
                       StandMixerConfiguration.preset(.fast, availablePlatforms: [.codex, .claude]).profiles)
        plan = try await preview(.high)
        _ = try await send(.init(action: .apply, previewID: id(plan)))
        let staleRestore = try await send(.init(action: .previewRestore))
        let stalePlan = try XCTUnwrap(staleRestore.1["preview"] as? [String: Any])
        plan = try await preview(.optimized)
        _ = try await send(.init(action: .apply, previewID: id(plan)))
        let staleResult = try await send(.init(action: .restore, previewID: id(stalePlan)))
        XCTAssertNotEqual(staleResult.0.exitCode, 0)
        XCTAssertEqual((staleResult.1["error"] as? [String: Any])?["code"] as? String, "conflict")
    }

    func testMalformedAndOversizedInputFailWithoutMutationOrEchoingInput() async throws {
        for input in [Data(), Data("{\"action\":\"private-secret-123\"}".utf8), Data(repeating: 65, count: StandMixerModInterface.maximumRequestBytes + 1)] {
            let result = await interface().runJSON(input)
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertFalse(String(decoding: result.output, as: UTF8.self).contains("private-secret-123"))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        }
        let invalid = try await send(.init(action: .apply, configuration: .defaults))
        XCTAssertNotEqual(invalid.0.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testPreviewExpiryEvictionAndActionMismatchDoNotMutateSettings() async throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let firstAPI = StandMixerModInterface(service: service, connections: connections, now: { fixed })
        let first = try await preview(to: firstAPI)
        let mismatch = try await send(.init(action: .uninstall, previewID: id(first)), to: firstAPI)
        XCTAssertNotEqual(mismatch.0.exitCode, 0)
        let laterAPI = StandMixerModInterface(service: service, connections: connections, now: { fixed.addingTimeInterval(StandMixerModInterface.previewLifetime + 1) })
        let expired = try await send(.init(action: .apply, previewID: id(first)), to: laterAPI)
        XCTAssertNotEqual(expired.0.exitCode, 0)
        for _ in 0...StandMixerModInterface.maximumPreviews { _ = try await preview(to: firstAPI) }
        let urls = try FileManager.default.contentsOfDirectory(atPath: service.applicationSupport.appendingPathComponent("Previews").path)
        XCTAssertEqual(urls.count, StandMixerModInterface.maximumPreviews)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
    }

    func testCrossProcessLockAndSymlinkedPreviewCannotWriteSettings() async throws {
        let plan = try await preview()
        let another = freshService()
        let candidate = try another.preview(configuration: .defaults)
        try service.withOperationLock {
            XCTAssertThrowsError(try another.apply(preview: candidate))
        }
        let path = service.applicationSupport.appendingPathComponent("Previews/\(try id(plan).uuidString).json")
        let copy = root.appendingPathComponent("untouched-preview.json")
        try FileManager.default.moveItem(at: path, to: copy)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: copy)
        let result = try await send(.init(action: .apply, previewID: id(plan)))
        XCTAssertNotEqual(result.0.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testInstallMacIsExplicitAndReturnsOnlyAResultWithoutAcquiringSettingsLock() async throws {
        actor Calls { var count = 0; func started() { count += 1 } }
        let calls = Calls()
        let other = freshService()
        let api = StandMixerModInterface(service: service, connections: connections,
            macInstaller: {
                await calls.started()
                // This is a different IntegrationService: a native transaction
                // lock held over the build would reject this fixture operation.
                try other.withOperationLock { }
                return .init(message: "Fixture Mac app installed.", changedFiles: 99)
            })
        _ = try await send(.init(action: .state), to: api)
        _ = try await preview(to: api)
        let before = await calls.count
        XCTAssertEqual(before, 0)
        let result = try await send(.init(action: .installMac), to: api)
        XCTAssertEqual(result.0.exitCode, 0, String(decoding: result.0.output, as: UTF8.self))
        XCTAssertEqual(Set(result.1.keys), ["ok", "result"])
        let installed = try XCTUnwrap(result.1["result"] as? [String: Any])
        XCTAssertEqual(installed["message"] as? String, "Fixture Mac app installed.")
        XCTAssertEqual(installed["changedFiles"] as? Int, 0)
        XCTAssertEqual(installed["notes"] as? [String], [])
        let after = await calls.count
        XCTAssertEqual(after, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
    }

    func testInstallMacRejectsEveryExtraFieldAndDoesNotStartInstaller() async throws {
        actor Calls { var count = 0; func started() { count += 1 } }
        let calls = Calls()
        let api = StandMixerModInterface(service: service, connections: connections, macInstaller: {
            await calls.started(); return .init(message: "Unexpected", changedFiles: 0)
        })
        for extra: [String: Any] in [["path": "/tmp/unsafe"], ["arguments": ["--destination", "/tmp/unsafe"]],
                                     ["platforms": ["codex"]], ["refresh": false], ["name": "value"],
                                     ["configuration": NSNull()], ["previewID": NSNull()], ["unknown": NSNull()]] {
            var request = extra; request["action"] = "installMac"
            let result = await api.runJSON(try JSONSerialization.data(withJSONObject: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "invalidRequest")
        }
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testInstallMacReportsActionableFailuresAndSupportsCancellation() async throws {
        let unavailable = StandMixerModInterface(service: service, connections: connections,
            macInstaller: { throw StandMixerMacInstallerError.failedWithDetails("Compiler error: ambiguous use of prefix") })
        let failed = try await send(.init(action: .installMac), to: unavailable)
        let error = try XCTUnwrap(failed.1["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "installMacFailed")
        XCTAssertTrue((error["message"] as? String)?.contains("Compiler error: ambiguous use of prefix") == true)
        XCTAssertTrue((error["message"] as? String)?.contains("\"$HOME/Library/Application Support/StandMixer/bin/standmixer\" install-mac") == true)
        let cancellable = StandMixerModInterface(service: service, connections: connections, macInstaller: {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return .init(message: "Unexpected", changedFiles: 0)
        })
        let data = try JSONEncoder().encode(StandMixerModRequest(action: .installMac))
        let operation = Task { await cancellable.runJSON(data) }
        operation.cancel()
        let result = await operation.value
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }


    func testAccountCheckIsExplicitEphemeralAndAcceptsNoExtraFields() async throws {
        actor Calls { var count = 0; func started() { count += 1 } }
        let calls = Calls()
        let api = StandMixerModInterface(service: service, connections: connections, accountChecker: {
            await calls.started()
            return .init(checkedAt: Date(timeIntervalSince1970: 1_800_000_000), providers: [
                .init(platform: .claude, status: .signedIn, email: "fixture@example.invalid", subscription: "max", detail: "Fixture public CLI status", cliPath: "/fixture/claude")
            ])
        })
        let initial = try await send(.init(action: .state), to: api)
        XCTAssertNil(initial.1["accounts"])
        let before = await calls.count
        XCTAssertEqual(before, 0)
        for extra: [String: Any] in [["platforms": ["claude"]], ["path": "/private/auth"], ["command": "login"], ["refresh": true], ["name": NSNull()]] {
            var request = extra; request["action"] = "checkAccounts"
            let result = await api.runJSON(try JSONSerialization.data(withJSONObject: request))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
            XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "invalidRequest")
        }
        let checked = try await send(.init(action: .checkAccounts), to: api)
        XCTAssertEqual(checked.0.exitCode, 0)
        XCTAssertEqual(Set(checked.1.keys), ["ok", "accounts"])
        let accounts = try XCTUnwrap(checked.1["accounts"] as? [String: Any])
        XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(accounts["checkedAt"] as? String)))
        let providers = try XCTUnwrap(accounts["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.first?["email"] as? String, "fixture@example.invalid")
        let count = await calls.count
        XCTAssertEqual(count, 1)
        let later = try await send(.init(action: .state), to: api)
        XCTAssertNil(later.1["accounts"], "Account identity must not be cached or persisted into state.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
    }
}
