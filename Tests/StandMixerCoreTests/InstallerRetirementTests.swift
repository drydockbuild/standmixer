import Foundation
import XCTest
@testable import StandMixerCore

final class InstallerRetirementTests: XCTestCase {
    private var home: URL!
    private var old: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-retirement-\(UUID())")
        old = home.appendingPathComponent("Library/Application Support/AgentMix")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("source"), withIntermediateDirectories: true)
        try Data("AgentMix source checkout v1\n".utf8).write(to: old.appendingPathComponent("source/.agentmix-source"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    func testNativeDefaultsNeverChangeAndOtherRecordsAndOriginalReceiptSurvive() throws {
        let native = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        let defaults = Data("model = 'my-current-model'\n".utf8); try defaults.write(to: native)
        let artifact: [String: Any] = ["kind": "artifact", "path": home.appendingPathComponent(".codex/agents/old-worker.toml").path]
        let before = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [
            ["kind": "native", "platform": "codex", "path": native.path], artifact]])
        let receipt = old.appendingPathComponent("installation.json"); try before.write(to: receipt)
        XCTAssertEqual(try InstallerRetirement.keepNativeDefaults(home: home, environment: [:]), 1)
        XCTAssertEqual(try Data(contentsOf: native), defaults)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0]["path"] as? String, artifact["path"] as? String)
        let backups = try FileManager.default.contentsOfDirectory(at: old.appendingPathComponent("Retirement"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), before)
        XCTAssertEqual(try InstallerRetirement.keepNativeDefaults(home: home, environment: [:]), 0)
    }

    func testUnknownNativeRootAndRedirectedReceiptAreKept() throws {
        let before = try JSONSerialization.data(withJSONObject: ["version": 1, "records": [
            ["kind": "native", "platform": "codex", "path": "/unrelated/config.toml"]]])
        let receipt = old.appendingPathComponent("installation.json"); try before.write(to: receipt)
        XCTAssertThrowsError(try InstallerRetirement.keepNativeDefaults(home: home, environment: [:]))
        XCTAssertEqual(try Data(contentsOf: receipt), before)
        let target = home.appendingPathComponent("unrelated.json"); try FileManager.default.moveItem(at: receipt, to: target)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: target)
        XCTAssertThrowsError(try InstallerRetirement.keepNativeDefaults(home: home, environment: [:]))
        XCTAssertEqual(try Data(contentsOf: target), before)
    }
}
