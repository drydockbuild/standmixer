import Foundation
import XCTest
@testable import StandMixerCore

final class CodexPresetPolicyTests: XCTestCase {
    func testManualCodexVisualCrossProviderWorkersRemainValid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-codex-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = IntegrationService(home: root.appendingPathComponent("home"),
                                         applicationSupport: root.appendingPathComponent("support"), environment: [:])
        var configuration = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.codex, .claude])
        let profileIndex = try XCTUnwrap(configuration.profiles.firstIndex { $0.platform == .codex })
        let routeIndex = try XCTUnwrap(configuration.profiles[profileIndex].routes.firstIndex { $0.category == .ui })
        configuration.profiles[profileIndex].routes[routeIndex].modelID = "claude-fable-5-1"
        configuration.profiles[profileIndex].routes[routeIndex].additionalAgents = [
            .init(modelID: "claude-haiku-5-5", modelPlatform: .claude),
        ]

        let preview = try service.preview(configuration: configuration, platforms: [.codex])
        for id in ["claude-fable-5-1", "claude-haiku-5-5"] {
            XCTAssertFalse(preview.changes.contains { $0.path.contains(".codex/agents/standmixer-\(id)-") })
            XCTAssertTrue(preview.changes.contains { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") && $0.after.contains("--model '\(id)'") })
        }
        XCTAssertEqual(configuration.profile(for: .codex)?.route(for: .coordinator)?.modelID, "auto")
    }
}
