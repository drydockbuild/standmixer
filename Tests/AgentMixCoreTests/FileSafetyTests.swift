import Foundation
import XCTest
@testable import AgentMixCore

final class FileSafetyTests: XCTestCase {
    func testConfigurationSymlinksAreRefusedWithoutReadingTheirTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentmix-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let directory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("unrelated.txt")
        try "keep exactly".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("config.toml"), withDestinationURL: target)
        let service = IntegrationService(home: home, applicationSupport: root.appendingPathComponent("support"), environment: [:])
        XCTAssertThrowsError(try service.preview(configuration: pinnedControllers()))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep exactly")
    }

    func testApplyKeepsOriginalModeAndNewArtifactsPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentmix-modes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let directory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("config.toml")
        try "model = 'old'\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)
        let support = root.appendingPathComponent("support")
        let service = IntegrationService(home: home, applicationSupport: support, environment: [:])
        let preview = try service.preview(configuration: pinnedControllers())
        _ = try service.apply(preview: preview)
        XCTAssertEqual(try permissions(config), 0o640)
        XCTAssertEqual(try permissions(home.appendingPathComponent(".claude/settings.json")), 0o600)
        XCTAssertEqual(try permissions(support), 0o700)
        XCTAssertEqual(try permissions(support.appendingPathComponent("last-backup.json")), 0o600)
        _ = try service.restoreLast()
        XCTAssertEqual(try permissions(config), 0o640)
    }

    func testEscapedTargetKeysAndTargetTablesAreRefused() {
        for source in [#""mo\u0064el" = "old""#, #"[model]"#, #""model".nested = "old""#] {
            XCTAssertThrowsError(try ConfigEdits.codexSettings(source, model: "gpt-6.1-sol", effort: "ultra"))
        }
    }

    func testNewOverrideAfterPreviewRefusesBeforeAnySettingsWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentmix-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let settings = codex.appendingPathComponent("config.toml")
        let original = "model = 'keep-original'\n"
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let support = root.appendingPathComponent("support")
        let service = IntegrationService(home: home, applicationSupport: support, environment: [:])
        let preview = try service.preview(configuration: pinnedControllers())
        let override = codex.appendingPathComponent("AGENTS.override.md")
        let externallyAdded = "# Override added by another application\n"
        try externallyAdded.write(to: override, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.apply(preview: preview))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: override, encoding: .utf8), externallyAdded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.appendingPathComponent("AGENTS.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    private func permissions(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }
}
