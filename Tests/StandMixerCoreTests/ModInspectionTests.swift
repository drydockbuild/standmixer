import CryptoKit
import Foundation
import XCTest
@testable import StandMixerCore

/// Regression coverage for retired observer/account actions and configuration-only workflows.
final class ModInspectionTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    private var launches: URL { root.appendingPathComponent("cli-launches") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-settings-only-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let discovery = CLIDiscovery(home: home, environment: [:], applicationDirectories: [], commonDirectories: [], activeExecutables: { [] }, probeTimeout: 2)
        service = IntegrationService(discovery: discovery, applicationSupport: root.appendingPathComponent("support"))
        for platform in AgentPlatform.allCases {
            let cli = home.appendingPathComponent(".local/bin/\(platform.rawValue)")
            try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
            let version = platform == .codex ? "codex-cli 0.137.0" : "2.1.309 (Claude Code)"
            // Log every invocation, including anything that accidentally attempts auth or inference.
            let script = """
            #!/bin/sh
            printf '%s\\n' "\(platform.rawValue) $*" >> '\(launches.path)'
            [ "$#" -eq 1 ] && [ "$1" = '--version' ] || exit 99
            printf '%s\\n' '\(version)'
            """
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        try FileManager.default.createDirectory(at: service.codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: service.claudeHome, withIntermediateDirectories: true)
        try "model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"high\"\n".write(to: service.codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "{\"model\":\"claude-opus-5-5\"}\n".write(to: service.claudeHome.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func send(_ request: StandMixerModRequest, to interface: StandMixerModInterface) async throws -> [String: Any] {
        let result = await interface.runJSON(try JSONEncoder().encode(request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    }

    func testRetiredActionsRejectOldCallersWithoutDiscoveryProcessesOrWrites() async throws {
        let interface = StandMixerModInterface(service: service)
        for request in [StandMixerModRequest(action: .inspect), .init(action: .inspect, platforms: [.codex, .claude], refresh: true), .init(action: .checkAccounts)] {
            let result = try await send(request, to: interface)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "retiredAction")
            XCTAssertTrue(((result["error"] as? [String: Any])?["message"] as? String)?.contains("routing settings only") == true)
            XCTAssertNil(result["inspection"])
            XCTAssertNil(result["accounts"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launches.path), "Legacy calls must not even run discovery.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testStateSavePresetReviewAndApplyOnlyLaunchVersionProbesWithoutCredentials() async throws {
        let interface = StandMixerModInterface(service: service)
        let initial = try await send(.init(action: .state), to: interface)
        XCTAssertEqual(initial["ok"] as? Bool, true)
        let state = try XCTUnwrap(initial["state"] as? [String: Any])
        let native = try XCTUnwrap(state["nativeSettings"] as? [[String: Any]])
        XCTAssertEqual(native.first { $0["platform"] as? String == "codex" }?["modelID"] as? String, "gpt-6.1-sol")
        XCTAssertNil(state["inspection"])
        var configuration = StandMixerConfiguration.preset(.fast, availablePlatforms: [.codex, .claude])
        configuration.enabledPlatforms = [.codex, .claude]
        for request in [StandMixerModRequest(action: .saveDraft, configuration: configuration, platforms: [.codex, .claude]),
                        .init(action: .savePreset, configuration: configuration, platforms: [.codex, .claude], name: "Offline fixture")] {
            let result = try await send(request, to: interface)
            XCTAssertEqual(result["ok"] as? Bool, true, String(describing: result))
        }
        let reviewed = try await send(.init(action: .preview, configuration: configuration, platforms: [.codex, .claude]), to: interface)
        let preview = try XCTUnwrap(reviewed["preview"] as? [String: Any])
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(preview["id"] as? String)))
        let applied = try await send(.init(action: .apply, previewID: id), to: interface)
        XCTAssertEqual(applied["ok"] as? Bool, true, String(describing: applied))
        let saved = try service.loadConfiguration()
        XCTAssertEqual(saved, configuration)
        let calls = try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(calls.isEmpty, "Exercise production-style CLI discovery, not just fixture metadata.")
        XCTAssertTrue(calls.allSatisfy { ["codex --version", "claude --version"].contains($0) }, calls.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.appendingPathComponent("mod-inspection.json").path))
    }

    func testStateIgnoresLegacyInspectionCacheAndKeepsSavedNativeDefaults() async throws {
        try FileManager.default.createDirectory(at: service.applicationSupport, withIntermediateDirectories: true)
        let cache = service.applicationSupport.appendingPathComponent("mod-inspection.json")
        let oldReport = "Cached observer report must never appear"
        let snapshot = AgentImportSnapshot.capture(platform: .codex, home: service.home,
            codexHome: service.codexHome, claudeHome: service.claudeHome, project: nil)
        let fingerprint = SHA256.hash(data: Data((snapshot.text + "\n" + snapshot.paths.joined(separator: "\n")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let date = ISO8601DateFormatter()
        let legacy: [String: Any] = ["version": 1, "fingerprint": ["codex": fingerprint], "inspection": [
            "createdAt": date.string(from: Date()), "expiresAt": date.string(from: Date().addingTimeInterval(600)), "fromCache": false,
            "reports": [["platform": "codex", "status": "complete", "summary": oldReport, "routes": [], "notes": [], "sources": []]]
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: cache)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        let connections = AgentPlatform.allCases.map { ConnectionStatus(platform: $0, path: "/fixture/\($0.rawValue)", version: nil, detail: "Fixture", isInstalled: true) }
        let interface = StandMixerModInterface(service: service, connections: connections)
        for symbolicLink in [false, true] {
            if symbolicLink {
                try FileManager.default.removeItem(at: cache)
                try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: root.appendingPathComponent("missing-cache-target"))
            }
            let result = await interface.runJSON(Data("{\"action\":\"state\"}".utf8))
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(String(decoding: result.output, as: UTF8.self).contains(oldReport))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
            let state = try XCTUnwrap(object["state"] as? [String: Any])
            XCTAssertNil(state["inspection"])
            let native = try XCTUnwrap(state["nativeSettings"] as? [[String: Any]])
            XCTAssertEqual(native.first { $0["platform"] as? String == "codex" }?["effort"] as? String, "high")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launches.path))
    }
}
