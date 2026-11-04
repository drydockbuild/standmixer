import Foundation
import XCTest
@testable import AgentMixCore

private actor InspectionCalls {
    var platforms: [AgentPlatform] = []
    func add(_ platform: AgentPlatform) { platforms.append(platform) }
    var count: Int { platforms.count }
}

final class ModInspectionTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    private var connections: [ConnectionStatus]!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("agentmix-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:])
        try FileManager.default.createDirectory(at: service.codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: service.claudeHome, withIntermediateDirectories: true)
        try "model = \"gpt-6.1-sol\"\n".write(to: service.codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "{\"model\":\"claude-opus-5-5\"}\n".write(to: service.claudeHome.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        connections = AgentPlatform.allCases.map { .init(platform: $0, path: "/fixture/\($0.rawValue)", version: nil, detail: "Fixture metadata only.", isInstalled: true) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func response(_ interface: AgentMixModInterface, action: String = "inspect", refresh: Bool? = nil) async throws -> [String: Any] {
        var request: [String: Any] = ["action": action, "platforms": ["codex", "claude"]]
        if let refresh { request["refresh"] = refresh }
        let data = try JSONSerialization.data(withJSONObject: request)
        let result = await interface.runJSON(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    }
    private func proposal(_ platform: AgentPlatform) -> AgentImportProposal {
        .init(platform: platform, workingDirectory: "/fixture", routes: [
            .init(category: .planning, modelID: "claude-opus-5-5", modelPlatform: .claude,
                  evidence: [.init(path: "/fixture/recent/CLAUDE.md", explanation: "Saved project preference")], scope: .usual),
        ], sources: [.init(path: "/fixture/recent/CLAUDE.md", explanation: "Saved project preference")], summary: "Read a saved preference.", executionModelID: platform == .claude ? "claude-haiku-5-5" : "gpt-6-luna")
    }

    func testInspectionCachesEvidenceWithoutApplyingOrReplacingDraftAndRefreshIsExplicit() async throws {
        let calls = InspectionCalls()
        let interface = AgentMixModInterface(service: service, connections: connections, inspectionReader: { [self] platform in
            await calls.add(platform); return proposal(platform)
        })
        let codex = try Data(contentsOf: service.codexHome.appendingPathComponent("config.toml"))
        let claude = try Data(contentsOf: service.claudeHome.appendingPathComponent("settings.json"))
        let first = try await response(interface)
        XCTAssertEqual(first["ok"] as? Bool, true)
        let report = try XCTUnwrap(first["inspection"] as? [String: Any])
        XCTAssertEqual(report["fromCache"] as? Bool, false)
        let reports = try XCTUnwrap(report["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual((reports[0]["routes"] as? [[String: Any]])?.first?["scope"] as? String, "usual")
        let second = try await response(interface)
        XCTAssertEqual((second["inspection"] as? [String: Any])?["fromCache"] as? Bool, true)
        let cachedCalls = await calls.count
        XCTAssertEqual(cachedCalls, 2)
        _ = try await response(interface, refresh: true)
        let refreshedCalls = await calls.count
        XCTAssertEqual(refreshedCalls, 4)
        XCTAssertEqual(try Data(contentsOf: service.codexHome.appendingPathComponent("config.toml")), codex)
        XCTAssertEqual(try Data(contentsOf: service.claudeHome.appendingPathComponent("settings.json")), claude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.appendingPathComponent("configuration.json").path))
        XCTAssertFalse(try service.installationStatus().hasInstallation)
    }

    func testChangedSourcesInvalidateCacheAndFailedReadsDoNotEscalate() async throws {
        let calls = InspectionCalls()
        let interface = AgentMixModInterface(service: service, connections: connections, inspectionReader: { platform in
            await calls.add(platform); throw AgentImportError.modelUnavailable
        })
        let first = try await response(interface)
        let reports = try XCTUnwrap((first["inspection"] as? [String: Any])?["reports"] as? [[String: Any]])
        XCTAssertTrue(reports.allSatisfy { $0["status"] as? String == "failed" })
        XCTAssertTrue(reports.allSatisfy { ($0["routes"] as? [Any])?.isEmpty == true })
        _ = try await response(interface)
        let cachedCalls = await calls.count
        XCTAssertEqual(cachedCalls, 2, "No automatic alternate-model retry.")
        try "Use Astra for planning.\n".write(to: service.codexHome.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(try interface.loadCachedInspection())
        _ = try await response(interface)
        let changedCalls = await calls.count
        XCTAssertEqual(changedCalls, 4)
    }

    func testStateDoesNotStartInspectionAndPrivateCacheCannotFollowSymlinks() async throws {
        let calls = InspectionCalls()
        let interface = AgentMixModInterface(service: service, connections: connections, inspectionReader: { [self] platform in
            await calls.add(platform); return proposal(platform)
        })
        _ = try await response(interface, action: "state")
        let stateCalls = await calls.count
        XCTAssertEqual(stateCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
        try FileManager.default.createDirectory(at: service.applicationSupport, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("keep.txt")
        try "Unrelated data".write(to: unrelated, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: service.applicationSupport.appendingPathComponent("mod-inspection.json"), withDestinationURL: unrelated)
        let result = try await response(interface)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "Unrelated data")
        let refusedCalls = await calls.count
        XCTAssertEqual(refusedCalls, 0)
    }

    func testCancelledInspectionDoesNotPublishCache() async throws {
        let interface = AgentMixModInterface(service: service, connections: connections, inspectionReader: { [self] platform in
            try await Task.sleep(nanoseconds: 5_000_000_000); return proposal(platform)
        })
        let request = try JSONSerialization.data(withJSONObject: ["action": "inspect", "platforms": ["claude", "codex"]])
        let operation = Task { await interface.runJSON(request) }
        try await Task.sleep(nanoseconds: 100_000_000)
        operation.cancel()
        let result = await operation.value
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.appendingPathComponent("mod-inspection.json").path))
    }
}
