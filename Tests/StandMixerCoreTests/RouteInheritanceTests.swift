import Foundation
import XCTest
@testable import StandMixerCore

final class RouteInheritanceTests: XCTestCase {
    private func edit(_ category: WorkCategory, in configuration: inout StandMixerConfiguration, _ edit: (inout Route) -> Void) {
        let index = configuration.profiles[0].routes.firstIndex { $0.category == category }!
        edit(&configuration.profiles[0].routes[index])
    }

    private func fixtureService() -> IntegrationService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-inheritance-\(UUID())")
        return IntegrationService(home: root, environment: [:], metadataOnlyDiscovery: true)
    }

    func testModelEffortAndTeamOverridesResolveIndependentlyAndSurviveRoundTrip() throws {
        var configuration = StandMixerConfiguration.defaults
        let assistant = AgentAssignment(modelID: "gpt-6-luna", effort: .fixed("high"))
        edit(.ui, in: &configuration) {
            $0.modelID = "gpt-6.1-sol"
            $0.effort = .fixed("xhigh")
            $0.additionalAgents = [assistant]
            $0.teamMode = .parallel
            $0.resultMode = .ai
            $0.judgeModelID = "gpt-6-astra"
        }
        edit(.uiImplementation, in: &configuration) {
            $0.inheritsEffort = false
            $0.effort = .fixed("medium")
        }
        edit(.uiReview, in: &configuration) {
            $0.inheritsModel = false
            $0.modelID = "gpt-6-astra"
            $0.inheritsTeam = false
            $0.teamMode = .leadReview
            $0.resultMode = .user
        }
        let profile = try XCTUnwrap(configuration.profile(for: .codex))
        let build = try XCTUnwrap(profile.effectiveRoute(for: .uiImplementation))
        XCTAssertEqual(build.modelID, "gpt-6.1-sol")
        XCTAssertEqual(build.effort, .fixed("medium"))
        XCTAssertEqual(build.additionalAgents, [assistant])
        XCTAssertEqual(build.teamMode, .parallel)
        XCTAssertEqual(build.resultMode, .ai)
        XCTAssertEqual(build.judgeModelID, "gpt-6-astra")
        let review = try XCTUnwrap(profile.effectiveRoute(for: .uiReview))
        XCTAssertEqual(review.modelID, "gpt-6-astra")
        XCTAssertEqual(review.effort, .fixed("xhigh"))
        XCTAssertEqual(review.additionalAgents, [])
        XCTAssertEqual(review.teamMode, .leadReview)
        XCTAssertEqual(review.resultMode, .user)
        XCTAssertNil(review.judgeModelID)

        let roundTrip = try JSONDecoder().decode(StandMixerConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(roundTrip, configuration)
        XCTAssertEqual(roundTrip.profile(for: .codex)?.effectiveRoute(for: .uiImplementation), build)
        edit(.ui, in: &configuration) {
            $0.modelID = "gpt-6-luna"
            $0.effort = .fixed("high")
            $0.additionalAgents = []
            $0.resultMode = .coordinator
            $0.judgeModelID = nil
        }
        let changed = try XCTUnwrap(configuration.profile(for: .codex))
        XCTAssertEqual(changed.effectiveRoute(for: .uiImplementation)?.modelID, "gpt-6-luna")
        XCTAssertEqual(changed.effectiveRoute(for: .uiImplementation)?.effort, .fixed("medium"))
        XCTAssertEqual(changed.effectiveRoute(for: .uiImplementation)?.additionalAgents, [])
        XCTAssertEqual(changed.effectiveRoute(for: .uiReview)?.modelID, "gpt-6-astra")
        XCTAssertEqual(changed.effectiveRoute(for: .uiReview)?.effort, .fixed("high"))
    }

    func testValidationAndPresetMatchingUseEffectiveValuesThenRejectInvalidEffectiveCombination() throws {
        let service = fixtureService()
        var configuration = StandMixerConfiguration.defaults
        edit(.uiImplementation, in: &configuration) {
            $0.modelID = "dormant-missing-model"
            $0.effort = .fixed("dormant-invalid-level")
            $0.additionalAgents = [.init(modelID: "dormant-missing-worker")]
            $0.resultMode = .ai
            $0.judgeModelID = "dormant-missing-judge"
        }
        XCTAssertEqual(StandMixerCommandInterface.matchingPreset(configuration, platforms: [.codex, .claude]), .optimized)
        XCTAssertNoThrow(try service.preview(configuration: configuration))
        var explicitlyPinned = configuration
        edit(.uiImplementation, in: &explicitlyPinned) { $0.inheritsModel = false; $0.modelID = "gpt-6-astra" }
        XCTAssertNil(StandMixerCommandInterface.matchingPreset(explicitlyPinned, platforms: [.codex, .claude]))
        var invalidParent = configuration
        edit(.ui, in: &invalidParent) { $0.inheritsEffort = true }
        XCTAssertThrowsError(try service.preview(configuration: invalidParent))
        edit(.ui, in: &configuration) { $0.effort = .fixed("ultra") }
        edit(.uiImplementation, in: &configuration) {
            $0.inheritsModel = false
            $0.modelID = "claude-fable-5-2"
        }
        XCTAssertThrowsError(try service.preview(configuration: configuration)) { error in
            XCTAssertEqual(error.localizedDescription, "Fable 5.2 does not support the selected effort.")
        }
        edit(.uiImplementation, in: &configuration) {
            $0.inheritsEffort = false
            $0.effort = .fixed("max")
        }
        XCTAssertNil(StandMixerCommandInterface.matchingPreset(configuration, platforms: [.codex, .claude]))
        XCTAssertNoThrow(try service.preview(configuration: configuration))
    }

    func testGeneratedInstructionsClassifyByReasoningAndSerializeEffectiveChildOverrides() throws {
        let service = fixtureService()
        var configuration = StandMixerConfiguration.defaults
        edit(.ui, in: &configuration) {
            $0.modelID = "gpt-6.1-sol"
            $0.effort = .fixed("high")
        }
        edit(.uiImplementation, in: &configuration) { $0.effort = .fixed("medium"); $0.inheritsEffort = false }
        let preview = try service.preview(configuration: configuration)
        let policy = try XCTUnwrap(preview.changes.first { $0.path == service.codexHome.appendingPathComponent("AGENTS.md").path }).after
        for guidance in ["Quick ideas covers bounded nontechnical suggestions", "experimental kernels, even when the request says brainstorm or asks for code",
                         "General coding once the approach is settled", "Diagnosing a failed suite belongs to Debugging / root cause",
                         "Running a known suite belongs to Routine tasks", "Drafting & editing applies when the content and facts are settled",
                         "When documentation requires checking code", "Judge visual quality through Design & UI", "Ordinary commands and tool calls keep the route",
                         "Use Development security for bounded private security checks", "early enough for several rounds of fixes",
                         "including for internet-reachable staging or test systems", "only if uncertainty materially changes the review choice or timing",
                         "repeat the full review when the scope or exposure changes materially"] {
            XCTAssertTrue(policy.contains(guidance), guidance)
        }
        XCTAssertTrue(policy.contains("- UI implementation: Implementing visual and interaction changes. Sol 6.1, medium, `standmixer-gpt-6.1-sol-medium`"))
        XCTAssertTrue(policy.contains("- UI review: Reviewing or judging visual and interaction quality. Sol 6.1, high, `standmixer-gpt-6.1-sol-high`"))
        XCTAssertTrue(policy.contains("- Debugging / root cause: Diagnosing failures, tracing causes, and investigating uncertain behavior. Astra 6, max"))
        XCTAssertTrue(preview.changes.contains { $0.path.hasSuffix("standmixer-gpt-6.1-sol-medium.toml") && $0.after.contains("model_reasoning_effort = \"medium\"") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
    }

    func testDebuggingEscalationExportsOrderedConditionalHandoffsAndValidatesEveryTarget() throws {
        let service = fixtureService()
        var configuration = StandMixerConfiguration.defaults
        let expected = ["claude-fable-5-2", "gpt-6-astra", "claude-opus-5-5"]
        for profile in configuration.profiles {
            let debugging = try XCTUnwrap(profile.effectiveRoute(for: .debugging))
            XCTAssertEqual(debugging.stuckEscalation.map(\.modelID), expected)
            XCTAssertTrue(debugging.stuckEscalation.allSatisfy { $0.effort == .fixed("max") })
            XCTAssertTrue(debugging.additionalAgents.isEmpty)
        }
        let preview = try service.preview(configuration: configuration)
        let codexExternal = try XCTUnwrap(preview.changes.first { $0.path == service.externalWorkerGuideURL(.codex).path }).after
        XCTAssertTrue(codexExternal.contains("--model 'claude-opus-5-5'"))
        XCTAssertTrue(codexExternal.contains("--effort 'max'"))
        for platform in AgentPlatform.allCases {
            let instructions = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(platform == .codex ? "/AGENTS.md" : "/CLAUDE.md") }).after
            let chain = try XCTUnwrap(instructions.split(separator: "\n").first { $0.contains("When debugging is stuck, try in order:") })
            let names = ["1. Fable 5.2", "2. Astra 6", "3. Opus 5.5"]
            let positions = try names.map { try XCTUnwrap(chain.range(of: $0)?.lowerBound) }
            XCTAssertEqual(positions, positions.sorted())
            XCTAssertTrue(instructions.contains("Two failed diagnostic cycles can be a signal"))
            XCTAssertTrue(instructions.contains("Skip the initial model and any model already exhausted"))
            XCTAssertTrue(instructions.contains("Hand off sequentially with the current diff, test evidence, and tested hypotheses"))
            XCTAssertTrue(instructions.contains("Try each eligible model once"))
        }
        edit(.debugging, in: &configuration) { $0.stuckEscalation.swapAt(0, 1) }
        XCTAssertNil(StandMixerCommandInterface.matchingPreset(configuration, platforms: [.codex, .claude]))
        edit(.debugging, in: &configuration) { $0.stuckEscalation[0].modelID = "unknown-target" }
        XCTAssertThrowsError(try service.preview(configuration: configuration))
        edit(.debugging, in: &configuration) { $0.stuckEscalation[0] = $0.stuckEscalation[1] }
        XCTAssertThrowsError(try service.preview(configuration: configuration))
        edit(.debugging, in: &configuration) { $0.stuckEscalation = [.init(modelID: "claude-fable-5-2", effort: .fixed("ultra"))] }
        XCTAssertThrowsError(try service.preview(configuration: configuration))
    }
}
