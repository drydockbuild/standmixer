import Foundation
import XCTest
@testable import AgentMixHelper

final class EngineBootstrapTests: XCTestCase {
    private var root: URL!
    // SwiftPM builds this signed executable dependency beside the test bundle.
    private var source: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AgentMixHelper") }
    private var receipt: URL { root.appendingPathComponent("Library/Application Support/AgentMix/runtime/.engine.sha256") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("agentmix-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMatchingReceiptPreservesFileAndModificationTime() throws {
        let target = try EngineBootstrap.install(source: source, home: root)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: receipt.path)
        let before = try FileManager.default.attributesOfItem(atPath: receipt.path)
        XCTAssertEqual(try EngineBootstrap.install(source: source, home: root), target)
        let after = try FileManager.default.attributesOfItem(atPath: receipt.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(after[.modificationDate] as? Date, earlier)
    }

    func testLegacyBootstrapCannotReplaceCanonicalRuntime() throws {
        let legacy = root.appendingPathComponent("Library/Application Support/AgentMix/bin/AgentMixHelper")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("older-plugin-engine".utf8).write(to: legacy)
        let target = try EngineBootstrap.install(source: source, home: root)
        XCTAssertEqual(target.deletingLastPathComponent().lastPathComponent, "runtime")
        let installed = try Data(contentsOf: target)
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "older-plugin-engine")
        // A previously shipped bootstrap still writes this old fixed location.
        try Data("older-plugin-bootstrap-again".utf8).write(to: legacy)
        XCTAssertEqual(try Data(contentsOf: target), installed)
        XCTAssertEqual(try EngineBootstrap.install(source: source, home: root), target)
    }

    func testMatchingPayloadRepairsMissingCorruptAndNonprivateReceipt() throws {
        _ = try EngineBootstrap.install(source: source, home: root)
        let original = try Data(contentsOf: receipt)
        try FileManager.default.removeItem(at: receipt)
        _ = try EngineBootstrap.install(source: source, home: root)
        XCTAssertEqual(try Data(contentsOf: receipt), original)
        try Data("interrupted-receipt\n".utf8).write(to: receipt)
        _ = try EngineBootstrap.install(source: source, home: root)
        XCTAssertEqual(try Data(contentsOf: receipt), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receipt.path)
        _ = try EngineBootstrap.install(source: source, home: root)
        let permissions = try FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testUnsafeReceiptLinksAndModifiedPayloadArePreserved() throws {
        let target = try EngineBootstrap.install(source: source, home: root)
        let originalReceipt = try Data(contentsOf: receipt)
        let unrelated = root.appendingPathComponent("unrelated")
        try originalReceipt.write(to: unrelated)
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: unrelated)
        XCTAssertThrowsError(try EngineBootstrap.install(source: source, home: root))
        XCTAssertEqual(try Data(contentsOf: unrelated), originalReceipt)
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.linkItem(at: unrelated, to: receipt)
        XCTAssertThrowsError(try EngineBootstrap.install(source: source, home: root))
        try FileManager.default.removeItem(at: receipt)
        try originalReceipt.write(to: receipt)
        let modified = Data("user-modified-engine".utf8)
        try modified.write(to: target)
        XCTAssertThrowsError(try EngineBootstrap.install(source: source, home: root))
        XCTAssertEqual(try Data(contentsOf: target), modified)
    }
}
