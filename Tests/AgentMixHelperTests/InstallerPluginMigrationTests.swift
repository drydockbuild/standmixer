import Foundation
import XCTest
@testable import AgentMixHelper

final class InstallerPluginMigrationTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var migration: InstallerPluginMigration!
    private var expected: URL!
    private var cache: URL!
    private let manager = FileManager.default
    private var registered: String { home.appendingPathComponent("Library/Application Support/AgentMix/source").path }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("standmixer-migration-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        migration = InstallerPluginMigration(home: home)
        expected = migration.expectedPackage
        cache = home.appendingPathComponent(".codex/plugins/cache/drydock-agentmix/agentmix/0.1.8", isDirectory: true)
        try manager.createDirectory(at: expected, withIntermediateDirectories: true)
        try Data(#"{"name":"agentmix","version":"0.1.8"}"#.utf8).write(to: expected.appendingPathComponent("plugin.json"))
        try Data("owned package\n".utf8).write(to: expected.appendingPathComponent("payload"))
        try manager.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: expected, to: cache)
    }

    override func tearDownWithError() throws { try manager.removeItem(at: root) }

    private func metadata(version: String = "0.1.8", root: String? = nil, extra: Bool = false, legacy: Bool = true) throws -> Data {
        let origin = root ?? registered
        let name = legacy ? "agentmix" : "standmixer"
        let marketplace = legacy ? "drydock-agentmix" : "drydock-standmixer"
        let item: [String: Any] = ["pluginId": "\(name)@\(marketplace)", "name": name, "marketplaceName": marketplace,
                                  "version": version, "installed": true, "enabled": true,
                                  "source": ["source": "local", "path": origin + "/Plugins/codex-agentmix"],
                                  "marketplaceSource": ["sourceType": "local", "source": origin]]
        return try JSONSerialization.data(withJSONObject: ["installed": extra ? [item, item] : [item], "available": []])
    }

    func testExactOwnedPackageIsBackedUpAndRechecked() throws {
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: expected.appendingPathComponent("payload").path)
        let plan = try migration.prepare(metadata: metadata(), registeredRoot: registered)
        try JSONEncoder().encode(plan).write(to: migration.planURL)
        let backedUpPayload = try manager.attributesOfItem(atPath: URL(fileURLWithPath: plan.backup).appendingPathComponent("payload").path)
        XCTAssertEqual((backedUpPayload[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(manager.fileExists(atPath: URL(fileURLWithPath: plan.backup).deletingLastPathComponent().appendingPathComponent("receipt.json").path))
        try migration.recheck(metadata: metadata(), registeredRoot: registered)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: plan.backup).appendingPathComponent("payload")), Data("owned package\n".utf8))
        let attributes = try manager.attributesOfItem(atPath: plan.backup)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try Data("changed after backup".utf8).write(to: cache.appendingPathComponent("payload"))
        XCTAssertThrowsError(try migration.recheck(metadata: metadata(), registeredRoot: registered))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: plan.backup).appendingPathComponent("payload")), Data("owned package\n".utf8))
    }

    func testModifiedOrAdditionalCacheFilesArePreserved() throws {
        try Data("user change".utf8).write(to: cache.appendingPathComponent("payload"))
        XCTAssertThrowsError(try migration.prepare(metadata: metadata(), registeredRoot: registered))
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent("payload"), encoding: .utf8), "user change")
        try Data("owned package\n".utf8).write(to: cache.appendingPathComponent("payload"))
        try Data("extra".utf8).write(to: cache.appendingPathComponent("user-file"))
        XCTAssertThrowsError(try migration.prepare(metadata: metadata(), registeredRoot: registered))
    }

    func testSymlinksHardlinksAndRedirectedAncestorsAreRejected() throws {
        let payload = cache.appendingPathComponent("payload")
        try manager.removeItem(at: payload)
        try manager.createSymbolicLink(at: payload, withDestinationURL: expected.appendingPathComponent("payload"))
        XCTAssertThrowsError(try migration.prepare(metadata: metadata(), registeredRoot: registered))
        try manager.removeItem(at: payload)
        try manager.linkItem(at: expected.appendingPathComponent("payload"), to: payload)
        XCTAssertThrowsError(try migration.prepare(metadata: metadata(), registeredRoot: registered))
        try manager.removeItem(at: payload)
        try Data("owned package\n".utf8).write(to: payload)
        let moved = root.appendingPathComponent("redirected-cache")
        try manager.moveItem(at: cache, to: moved)
        try manager.createSymbolicLink(at: cache, withDestinationURL: moved)
        XCTAssertThrowsError(try migration.prepare(metadata: metadata(), registeredRoot: registered))
    }

    func testForeignAmbiguousAndUnsafeVersionMetadataAreRejected() throws {
        XCTAssertThrowsError(try migration.prepare(metadata: metadata(root: "/foreign"), registeredRoot: registered))
        XCTAssertThrowsError(try migration.prepare(metadata: metadata(extra: true), registeredRoot: registered))
        for version in ["../other", ".", "..", "v/0.1.8", "0.1.8\n"] {
            XCTAssertThrowsError(try migration.prepare(metadata: metadata(version: version), registeredRoot: registered))
        }
    }

    func testOnlyAnUnchangedCanonicalCacheCanBeRemovedForRollback() throws {
        let source = URL(fileURLWithPath: registered).appendingPathComponent("Plugins/codex-agentmix")
        try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: expected, to: source)
        try Data(#"{"name":"standmixer","version":"0.1.8"}"#.utf8).write(to: source.appendingPathComponent("plugin.json"))
        let canonical = home.appendingPathComponent(".codex/plugins/cache/drydock-standmixer/standmixer/0.1.8")
        try manager.createDirectory(at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: source, to: canonical)
        try migration.checkCanonical(metadata: metadata(legacy: false), registeredRoot: registered)
        try Data("user change".utf8).write(to: canonical.appendingPathComponent("payload"))
        XCTAssertThrowsError(try migration.checkCanonical(metadata: metadata(legacy: false), registeredRoot: registered))
    }

    func testTamperedPlanCannotSelectAnotherCacheOrBackup() throws {
        let plan = try migration.prepare(metadata: metadata(), registeredRoot: registered)
        let bad = InstallerPluginMigration.Plan(version: plan.version, registeredRoot: plan.registeredRoot, cache: expected.path, backup: plan.backup, digest: plan.digest)
        try JSONEncoder().encode(bad).write(to: migration.planURL)
        XCTAssertThrowsError(try migration.recheck(metadata: metadata(), registeredRoot: registered))
    }
}
