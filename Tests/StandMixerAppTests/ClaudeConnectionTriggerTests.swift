import XCTest
import StandMixerCore
@testable import StandMixerApp

final class ClaudeConnectionTriggerTests: XCTestCase {
    private func configuration() -> StandMixerConfiguration {
        .init(profiles: [
            .init(platform: .codex, routes: [.init(category: .planning, modelID: "gpt-6.2-astra")]),
            .init(platform: .claude, routes: [.init(category: .planning, modelID: "claude-opus-5-5")])
        ], enabledPlatforms: [.codex, .claude])
    }

    func testEveryActiveCodexRoleUsesTheCatalog() {
        let before = configuration()
        for role in ["lead", "team", "judge", "escalation"] {
            var after = before
            switch role {
            case "lead": after.profiles[0].routes[0].modelID = "claude-opus-5-5"
            case "team": after.profiles[0].routes[0].additionalAgents = [.init(modelID: "claude-opus-5-5")]
            case "judge":
                after.profiles[0].routes[0].resultMode = .ai
                after.profiles[0].routes[0].judgeModelID = "claude-opus-5-5"
            default: after.profiles[0].routes[0].stuckEscalation = [.init(modelID: "claude-opus-5-5")]
            }
            XCTAssertTrue(ClaudeConnectionTrigger.introducesClaude(before: before, after: after, catalog: ModelSpec.builtIn), role)
            XCTAssertFalse(ClaudeConnectionTrigger.introducesClaude(before: after, after: after, catalog: ModelSpec.builtIn), role)
        }
    }

    func testReverseNativeAndUnknownChangesDoNotTrigger() {
        let before = configuration()
        var after = before
        after.profiles[1].routes[0].modelID = "gpt-6.2-astra"
        XCTAssertFalse(ClaudeConnectionTrigger.introducesClaude(before: before, after: after, catalog: ModelSpec.builtIn))
        after.profiles[0].routes[0].modelID = "claude-looking-unknown"
        XCTAssertFalse(ClaudeConnectionTrigger.introducesClaude(before: before, after: after, catalog: ModelSpec.builtIn))
        after.profiles[0].routes[0].modelID = "claude-opus-5-5"
        after.enabledPlatforms = [.claude]
        XCTAssertFalse(ClaudeConnectionTrigger.introducesClaude(before: before, after: after, catalog: ModelSpec.builtIn))
        after.enabledPlatforms = [.codex]
        XCTAssertFalse(ClaudeConnectionTrigger.introducesClaude(before: before, after: after, catalog: ModelSpec.builtIn))
    }

    func testOpeningChecksSavedAndAppliedCodexRequirementsButRespectsDisabledProviders() {
        let proposal = configuration()
        var required = proposal
        required.profiles[0].routes[0].modelID = "claude-opus-5-5"
        let applied = InstallationStatus(state: .applied, summary: "Fixture", appliedConfiguration: required,
                                         installedPlatforms: [.codex])
        XCTAssertTrue(ClaudeConnectionTrigger.requiredOnOpen(configuration: proposal, savedConfiguration: required,
            installation: nil, catalog: ModelSpec.builtIn))
        XCTAssertTrue(ClaudeConnectionTrigger.requiredOnOpen(configuration: proposal, savedConfiguration: nil,
            installation: applied, catalog: ModelSpec.builtIn))
        for platform in AgentPlatform.allCases {
            var disabled = proposal
            disabled.enabledPlatforms = [platform]
            XCTAssertFalse(ClaudeConnectionTrigger.requiredOnOpen(configuration: disabled, savedConfiguration: required,
                installation: applied, catalog: ModelSpec.builtIn))
        }
        let reverse = InstallationStatus(state: .applied, summary: "Fixture", appliedConfiguration: required,
                                         installedPlatforms: [.claude])
        XCTAssertFalse(ClaudeConnectionTrigger.requiredOnOpen(configuration: proposal, savedConfiguration: nil,
            installation: reverse, catalog: ModelSpec.builtIn))
    }

    func testInheritedAndCustomClaudeAssignmentsAreRecognized() {
        var after = configuration()
        after.profiles[0].routes[0].modelID = "custom-provider"
        after.profiles[0].routes.append(.init(category: .algorithms, modelID: "unused", inheritsModel: true))
        let catalog = ModelSpec.builtIn + [.init(id: "custom-provider", label: "Custom Claude", platform: .claude)]
        XCTAssertTrue(ClaudeConnectionTrigger.introducesClaude(before: configuration(), after: after, catalog: catalog))
        XCTAssertEqual(ClaudeConnectionTrigger.usage(in: after, catalog: catalog).count, 2)
    }

    @MainActor
    func testPreviewIgnoresClaudeOnlyChangesWhenCodexMatchesItsAppliedProfile() {
        var baseline = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.codex, .claude])
        let codex = baseline.profiles.firstIndex { $0.platform == .codex }!
        let claude = baseline.profiles.firstIndex { $0.platform == .claude }!
        let planning = baseline.profiles[codex].routes.firstIndex { $0.category == .planning }!
        baseline.profiles[codex].routes[planning].modelID = "claude-opus-5-5"
        var draft = baseline
        let native = draft.profiles[claude].routes.firstIndex { $0.category == .planning }!
        draft.profiles[claude].routes[native].modelID = "claude-fable-5-2"
        let installation = InstallationStatus(state: .applied, summary: "Fixture", appliedConfiguration: baseline,
                                              installedPlatforms: [.codex, .claude])
        XCTAssertFalse(AppStore.needsClaudeCheckBeforePreview(configuration: draft, installation: installation, catalog: ModelSpec.builtIn))
        draft.profiles[codex].routes[planning].modelID = "claude-fable-5-2"
        XCTAssertTrue(AppStore.needsClaudeCheckBeforePreview(configuration: draft, installation: installation, catalog: ModelSpec.builtIn))
        XCTAssertTrue(AppStore.needsClaudeCheckBeforePreview(configuration: baseline, installation: nil, catalog: ModelSpec.builtIn))
        let claudeOnly = InstallationStatus(state: .applied, summary: "Fixture", appliedConfiguration: baseline, installedPlatforms: [.claude])
        XCTAssertTrue(AppStore.needsClaudeCheckBeforePreview(configuration: baseline, installation: claudeOnly, catalog: ModelSpec.builtIn))
    }
}
