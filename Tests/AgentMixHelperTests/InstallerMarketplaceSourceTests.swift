import AgentMixCore
import Foundation
import XCTest
@testable import AgentMixHelper

final class InstallerMarketplaceSourceTests: XCTestCase {
    func testCanonicalAndLegacyMarketplacesRemainSeparateAndStrict() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            ["name": "drydock-agentmix", "source": "directory", "path": "/fixture/legacy"],
            ["name": "drydock-standmixer", "source": "directory", "path": "/fixture/current"]])
        XCTAssertEqual(try AgentMixInstallerMarketplaceSource.source(in: data, platform: .claude), "/fixture/legacy")
        XCTAssertEqual(try AgentMixInstallerMarketplaceSource.source(in: data, platform: .claude, marketplace: "drydock-standmixer"), "/fixture/current")
        XCTAssertThrowsError(try AgentMixInstallerMarketplaceSource.source(in: data, platform: .claude, marketplace: "other"))
    }
    private func parse(_ object: Any, _ platform: AgentPlatform) throws -> String? {
        try AgentMixInstallerMarketplaceSource.source(in: JSONSerialization.data(withJSONObject: object), platform: platform)
    }
    private func codex(_ root: String, source: String? = nil, sourceType: String = "local") -> [String: Any] {
        ["name": "drydock-agentmix", "root": root, "marketplaceSource": ["sourceType": sourceType, "source": source ?? root]]
    }
    func testExactClaudeAndCodexSchemasReturnOnlyLocalAbsoluteRoots() throws {
        let path = "/Users/fixture/Library/Application Support/AgentMix/source"
        XCTAssertEqual(try parse([["name": "other", "source": "github", "path": "owner/repo"],
                                  ["name": "drydock-agentmix", "source": "directory", "path": path]], .claude), path)
        XCTAssertEqual(try parse(["marketplaces": [codex(path)]], .codex), path)
        XCTAssertEqual(try parse(["marketplaces": [codex(path + "/../source", source: path)]], .codex), path)
        XCTAssertNil(try parse([], .claude))
        XCTAssertNil(try parse(["marketplaces": [["name": "other", "root": "/other"]]], .codex))
    }
    func testDuplicatesRemoteAndConflictingCodexSourcesAreRejected() throws {
        let local = ["name": "drydock-agentmix", "source": "directory", "path": "/fixture/source"]
        for object: Any in [[local, local], [["name": "drydock-agentmix", "source": "github", "path": "/fixture/source"]],
                            [["name": "drydock-agentmix", "source": "directory", "path": "https://example.invalid/repo"]]] {
            XCTAssertThrowsError(try parse(object, .claude))
        }
        for entries in [[codex("/fixture/source"), codex("/fixture/source")],
                        [codex("/fixture/source", source: "/another/source")],
                        [codex("/fixture/source", sourceType: "git")]] {
            XCTAssertThrowsError(try parse(["marketplaces": entries], .codex))
        }
    }
    func testInvalidAndControlCharacterPathsNeverBecomeShellOutput() throws {
        for path in ["relative/path", "file:///fixture/source", "//server/share", "/fixture\nsource", "/fixture\rsource", "/fixture\0source", String(repeating: "/", count: 4097)] {
            XCTAssertThrowsError(try parse([["name": "drydock-agentmix", "source": "directory", "path": path]], .claude))
            XCTAssertThrowsError(try parse(["marketplaces": [codex(path)]], .codex))
        }
        for object: Any in [[:], ["marketplaces": [:]], ["marketplaces": [["root": "/fixture"]]],
                            ["marketplaces": [["name": "drydock-agentmix", "root": "/fixture"]]]] {
            XCTAssertThrowsError(try parse(object, .codex))
        }
        XCTAssertThrowsError(try parse(["marketplaces": []], .claude))
        for data in [Data(), Data("invalid JSON".utf8), Data(repeating: 32, count: AgentMixInstallerMarketplaceSource.maximumInputBytes + 1)] {
            XCTAssertThrowsError(try AgentMixInstallerMarketplaceSource.source(in: data, platform: .codex))
        }
    }
}
