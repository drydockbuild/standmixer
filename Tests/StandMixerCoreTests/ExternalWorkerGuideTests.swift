import Foundation
import XCTest
@testable import StandMixerCore

/// Represents an installed older artifact with an exact recovery record.
/// A marker alone is deliberately insufficient to authorize its retirement.
func recordOwnedArtifactsFixture(_ service: IntegrationService, contents: [URL: String]) throws {
    let records = contents.sorted { $0.key.path < $1.key.path }.map { url, source in
        IntegrationService.BackupRecord(change: .init(path: url.path, before: nil, after: source,
                                                      reason: "Previously installed fixture artifact."), mode: 0o600)
    }
    let backup = IntegrationService.Backup(id: UUID(), createdAt: Date(), records: records,
                                           installationBefore: nil, installationAfter: nil, tracksInstallation: false)
    try FileManager.default.createDirectory(at: service.applicationSupport, withIntermediateDirectories: true)
    try JSONEncoder().encode(backup).write(to: service.receiptURL)
}

final class ExternalWorkerGuideTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-external-guide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = IntegrationService(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:], metadataOnlyDiscovery: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ source: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
    }
    private func guide(_ platform: AgentPlatform, in preview: IntegrationPreview) throws -> FileChange {
        try XCTUnwrap(preview.changes.first { $0.path == service.externalWorkerGuideURL(platform).path && !$0.isDeletion })
    }
    private var oldBridge: URL { service.claudeHome.appendingPathComponent("agents/standmixer-gpt-6.1-sol-auto.md") }
    private var oldSource: String { "---\nmodel: claude-haiku-5-5\neffort: medium\n---\n<!-- \(ConfigEdits.ownership) -->\nOld external bridge.\n" }
    private func installOldBridgeRecord() throws {
        try write(oldSource, to: oldBridge)
        let receipt = InstallationReceipt(configuration: .defaults, platforms: [.claude], records: [
            .init(path: oldBridge.path, platform: .claude, kind: .artifact, before: nil, after: oldSource, fields: [], canRestoreNative: true)
        ])
        try service.storeInstallationText(service.encodeInstallation(receipt))
    }

    func testCrossRoutesExportOnlyNativeAgentsAndDirectRecipesWithHonestCompletion() throws {
        let preview = try service.preview(configuration: .defaults)
        XCTAssertFalse(preview.changes.contains { $0.path.contains(".codex/agents/standmixer-claude-") || $0.path.contains(".claude/agents/standmixer-gpt-") })
        let claude = try guide(.claude, in: preview).after
        let codex = try guide(.codex, in: preview).after
        for guide in [claude, codex] {
            XCTAssertTrue(guide.contains("The current controller launches these CLIs directly"))
            XCTAssertTrue(guide.contains("Background launch is not completion"))
            XCTAssertTrue(guide.contains("terminal exit state"))
            XCTAssertTrue(guide.contains("startup process exiting is not the worker finishing"))
            XCTAssertTrue(guide.contains("Requested model:"))
            XCTAssertTrue(guide.contains("claim verified model and effort only when exposed by CLI execution metadata"))
            XCTAssertTrue(guide.contains("If asked and unavailable, say unverified"))
            XCTAssertTrue(guide.contains("failed, cancelled, timed-out"))
            XCTAssertTrue(guide.contains("StandMixer adds no monitoring task"))
            XCTAssertFalse(guide.contains("TaskOutput"))
            XCTAssertTrue(guide.contains("concrete task"))
            XCTAssertTrue(guide.contains("only relevant context/files"))
            XCTAssertTrue(guide.contains("Effort translation belongs to the controller before launch"))
            XCTAssertFalse(guide.contains("directory: role,"))
            XCTAssertFalse(guide.contains("reasoning intensity must be carried in the brief"))
            XCTAssertFalse(guide.contains("--dangerously"))
            XCTAssertFalse(guide.contains("model: claude-haiku-5-5"))
            XCTAssertFalse(guide.contains("model = \"gpt-6-luna\""))
        }
        XCTAssertTrue(claude.contains("run_in_background: true"))
        XCTAssertTrue(claude.contains("real returned task ID and output_file"))
        XCTAssertTrue(claude.contains("native completion notice, then use Read"))
        XCTAssertTrue(claude.contains("Sol 6.1 via Codex · <task>"))
        XCTAssertTrue(claude.contains("-m 'gpt-6.1-sol'"))
        XCTAssertTrue(codex.contains("exec_command sessions, write_stdin waits"))
        XCTAssertTrue(codex.contains("Opus 5.5 via Claude Code · <task>"))
        XCTAssertTrue(codex.contains("--model 'claude-opus-5-5'"))
        let policy = try XCTUnwrap(preview.changes.first { $0.path == service.claudeHome.appendingPathComponent("CLAUDE.md").path }).after
        XCTAssertTrue(policy.contains("direct external CLI recipe `external-gpt-6.1-sol-auto`"))
        XCTAssertFalse(policy.contains("standmixer-gpt-6.1-sol-auto"))
    }

    func testExactGuideAllowlistRejectsSiblingAndCustomRootsClassifyCorrectly() throws {
        let custom = IntegrationService(home: service.home, applicationSupport: service.applicationSupport,
                                        environment: ["CODEX_HOME": root.appendingPathComponent("custom codex").path,
                                                      "CLAUDE_CONFIG_DIR": root.appendingPathComponent("custom claude").path], metadataOnlyDiscovery: true)
        for platform in AgentPlatform.allCases {
            let url = custom.externalWorkerGuideURL(platform)
            XCTAssertNoThrow(try custom.checkAllowed(url))
            XCTAssertEqual(custom.recordPlatform(url), platform)
            XCTAssertEqual(custom.recordKind(url), .artifact)
            let sibling = url.deletingLastPathComponent().appendingPathComponent("other.md")
            XCTAssertThrowsError(try custom.checkAllowed(sibling))
            let forged = IntegrationPreview(changes: [.init(path: sibling.path, before: nil, after: "unrelated", reason: "forged")])
            XCTAssertThrowsError(try custom.apply(preview: forged))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
        }
        XCTAssertEqual(custom.externalWorkerGuideURL(.codex).path, service.home.appendingPathComponent(".agents/skills/standmixer/references/external-workers.md").path)
    }

    func testUnownedGuideAndRedirectedReferencesCannotOverwriteUserFiles() throws {
        let url = service.externalWorkerGuideURL(.codex)
        try write("My own guide", to: url)
        XCTAssertThrowsError(try service.preview(configuration: .defaults, platforms: [.codex]))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "My own guide")
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        let outside = root.appendingPathComponent("outside")
        try write("Private content kept", to: outside.appendingPathComponent("external-workers.md"))
        try FileManager.default.createSymbolicLink(at: url.deletingLastPathComponent(), withDestinationURL: outside)
        XCTAssertThrowsError(try service.preview(configuration: .defaults, platforms: [.codex]))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("external-workers.md"), encoding: .utf8), "Private content kept")
    }

    func testUnchangedBridgeIsRetiredAndRestoreRestoresBridgeAndRemovesGuide() throws {
        try installOldBridgeRecord()
        let preview = try service.preview(configuration: .defaults, platforms: [.claude])
        XCTAssertTrue(preview.changes.contains { $0.path == oldBridge.path && $0.isDeletion })
        XCTAssertTrue(preview.preservedConflicts.isEmpty)
        _ = try service.apply(preview: preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBridge.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.externalWorkerGuideURL(.claude).path))
        _ = try service.restoreLast()
        XCTAssertEqual(try String(contentsOf: oldBridge, encoding: .utf8), oldSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.externalWorkerGuideURL(.claude).path))
    }

    func testModifiedBridgeIsKeptWithoutReadoptingItAndRemainsAnUninstallConflict() throws {
        try installOldBridgeRecord()
        let modified = oldSource + "User changes.\n"
        try write(modified, to: oldBridge)
        let preview = try service.preview(configuration: .defaults, platforms: [.claude])
        XCTAssertFalse(preview.changes.contains { $0.path == oldBridge.path })
        XCTAssertTrue(preview.preservedConflicts.contains { $0.contains(oldBridge.path) })
        let applied = try service.apply(preview: preview)
        XCTAssertTrue(applied.message.contains(oldBridge.path))
        let receipt = try XCTUnwrap(service.loadInstallation(service.installationText()))
        XCTAssertEqual(receipt.records.first { $0.path == oldBridge.path }?.after, oldSource)
        let uninstall = try service.previewUninstall()
        XCTAssertTrue(uninstall.conflicts.contains { $0.contains(oldBridge.path) })
        _ = try service.uninstall(preview: uninstall)
        XCTAssertEqual(try String(contentsOf: oldBridge, encoding: .utf8), modified)
    }

    func testOwnershipMarkerWithoutExactRecordNeverAuthorizesBridgeDeletion() throws {
        try write(oldSource, to: oldBridge)
        let preview = try service.preview(configuration: .defaults, platforms: [.claude])
        XCTAssertFalse(preview.changes.contains { $0.path == oldBridge.path })
        XCTAssertTrue(preview.preservedConflicts.contains { $0.contains(oldBridge.path) })
        _ = try service.apply(preview: preview)
        XCTAssertEqual(try String(contentsOf: oldBridge, encoding: .utf8), oldSource)
        XCTAssertNil(try service.loadInstallation(service.installationText())?.records.first { $0.path == oldBridge.path }?.after)
        XCTAssertTrue(try service.previewUninstall().conflicts.contains { $0.contains(oldBridge.path) })
    }

    func testGuideRemovalRestoresExactlyAndModifiedGuideIsPreservedOnRemovalAndUninstall() throws {
        _ = try service.apply(preview: service.preview(configuration: .defaults, platforms: [.codex]))
        let url = service.externalWorkerGuideURL(.codex)
        let original = try String(contentsOf: url, encoding: .utf8)
        let nativeOnly = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.codex])
        let removal = try service.preview(configuration: nativeOnly, platforms: [.codex])
        XCTAssertTrue(removal.changes.contains { $0.path == url.path && $0.isDeletion })
        _ = try service.apply(preview: removal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        _ = try service.restoreLast()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        let modified = original + "My guide note.\n"
        try write(modified, to: url)
        let kept = try service.preview(configuration: nativeOnly, platforms: [.codex])
        XCTAssertFalse(kept.changes.contains { $0.path == url.path })
        XCTAssertTrue(kept.preservedConflicts.contains { $0.contains(url.path) })
        _ = try service.apply(preview: kept)
        let uninstall = try service.previewUninstall()
        XCTAssertTrue(uninstall.conflicts.contains { $0.contains(url.path) })
        _ = try service.uninstall(preview: uninstall)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), modified)
    }

    func testGuideChangedAfterReviewRejectsApplyBeforeAnyOtherTargetChanges() throws {
        _ = try service.apply(preview: service.preview(configuration: .defaults))
        let preview = try service.preview(configuration: .preset(.high, availablePlatforms: [.codex, .claude]))
        let url = service.externalWorkerGuideURL(.codex)
        let modified = try String(contentsOf: url, encoding: .utf8) + "Later edit.\n"
        try write(modified, to: url)
        let receipt = try service.installationText()
        XCTAssertThrowsError(try service.apply(preview: preview))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), modified)
        XCTAssertEqual(try service.installationText(), receipt)
    }

    func testStoredPreviewKeepsPreservedConflictsAcrossInterfaces() async throws {
        try installOldBridgeRecord()
        let modified = oldSource + "User changes.\n"
        try write(modified, to: oldBridge)
        let connections = AgentPlatform.allCases.map { ConnectionStatus(platform: $0, path: "/fixture/\($0.rawValue)", version: nil, detail: "Fixture", isInstalled: true) }
        let api = StandMixerModInterface(service: service, connections: connections)
        let request = StandMixerModRequest(action: .preview, configuration: .defaults, platforms: [.codex, .claude])
        let response = await api.runJSON(try JSONEncoder().encode(request))
        XCTAssertEqual(response.exitCode, 0, String(decoding: response.output, as: UTF8.self))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.output) as? [String: Any])
        let review = try XCTUnwrap(json["preview"] as? [String: Any])
        XCTAssertTrue((review["conflicts"] as? [String] ?? []).contains { $0.contains(oldBridge.path) })
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(review["id"] as? String)))
        let fresh = StandMixerModInterface(service: service, connections: connections)
        let applied = await fresh.runJSON(try JSONEncoder().encode(StandMixerModRequest(action: .apply, previewID: id)))
        XCTAssertEqual(applied.exitCode, 0, String(decoding: applied.output, as: UTF8.self))
        XCTAssertTrue(String(decoding: applied.output, as: UTF8.self).contains("kept"))
        XCTAssertEqual(try String(contentsOf: oldBridge, encoding: .utf8), modified)
    }
}
