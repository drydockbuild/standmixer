import Foundation
import XCTest
@testable import StandMixerCore

final class Fable52Tests: XCTestCase {
    func testCatalogAndNativeAndExternalRecipesPreserveExactModelAndEffort() throws {
        let spec = try XCTUnwrap(ModelSpec.builtIn.first { $0.id == "claude-fable-5-2" })
        XCTAssertEqual(spec.label, "Fable 5.2")
        XCTAssertEqual(spec.platform, .claude)
        XCTAssertEqual(spec.supportedEfforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(spec.nearestSupportedEffort(to: "ultra"), "max")
        XCTAssertNotNil(ModelSpec.builtIn.first { $0.id == "claude-fable-5-1" })
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-fable52-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = IntegrationService(home: home, environment: [:], metadataOnlyDiscovery: true)
        var config = StandMixerConfiguration.defaults
        for i in config.profiles.indices {
            let j = config.profiles[i].routes.firstIndex { $0.category == .algorithms }!
            config.profiles[i].routes[j].modelID = spec.id
        }
        let preview = try service.preview(configuration: config)
        let native = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix("/agents/standmixer-claude-fable-5-2-auto.md") })
        XCTAssertTrue(native.after.contains("model: claude-fable-5-2"))
        let external = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".agents/skills/standmixer/references/external-workers.md") })
        XCTAssertTrue(external.after.contains("--model 'claude-fable-5-2'"))
        XCTAssertTrue(external.after.contains("--effort '<mapped-caller-effort>'"))
        XCTAssertTrue(external.after.contains("ultra -> max"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }
}
