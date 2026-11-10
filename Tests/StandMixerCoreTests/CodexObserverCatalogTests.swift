import Foundation
import XCTest
@testable import StandMixerCore

final class CodexObserverCatalogTests: XCTestCase {
    func testProjectionPreservesPublicModelMetadataAndRemovesEveryExecutionTool() throws {
        let original: [String: Any] = ["models": [["slug": "gpt-fixture", "context_window": 196608,
            "base_instructions": "Public bundled instructions", "apply_patch_tool_type": "freeform",
            "experimental_supported_tools": ["exec_command", "apply_patch"], "tool_mode": "code"]]]
        let catalog = try CodexObserverCatalog(publicMetadata: JSONSerialization.data(withJSONObject: original))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: catalog.data) as? [String: Any])
        let model = try XCTUnwrap((root["models"] as? [[String: Any]])?.first)
        XCTAssertTrue(catalog.modelIDs.contains("gpt-fixture"))
        XCTAssertEqual(model["context_window"] as? Int, 196608)
        XCTAssertEqual(model["base_instructions"] as? String, "Public bundled instructions")
        XCTAssertTrue(model["apply_patch_tool_type"] is NSNull)
        XCTAssertTrue(model["tool_mode"] is NSNull)
        XCTAssertEqual(model["experimental_supported_tools"] as? [String], [])
    }

    func testManifestAllowsOnlyNonFilesystemInputToolAndRejectsUnknownCapabilities() throws {
        func manifest(_ tools: [[String: Any]], type: String = "additional_tools") throws -> Data {
            try JSONSerialization.data(withJSONObject: [["type": type, "tools": [["type": "namespace", "name": "functions", "tools": tools]]]])
        }
        XCTAssertNoThrow(try CodexObserverCatalog.validateToolManifest(manifest([["type": "function", "name": "request_user_input"]])))
        for name in ["exec", "apply_patch", "read_file", "exec_command", "mcp__fixture", "view_image"] {
            XCTAssertThrowsError(try CodexObserverCatalog.validateToolManifest(manifest([["type": "function", "name": name]])))
        }
        XCTAssertThrowsError(try CodexObserverCatalog.validateToolManifest(manifest([], type: "future_tool_transport")))
        XCTAssertThrowsError(try CodexObserverCatalog.validateToolManifest(Data("[]".utf8)))
    }
}
