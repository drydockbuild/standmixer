import Foundation
import XCTest
@testable import StandMixerCore

final class DriverPermissionsTests: XCTestCase {
    func testDirectCodexRecipeCarriesTaskScopedPermissionsInsteadOfImplicitReadOnly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let service = IntegrationService(home: home, environment: [:], metadataOnlyDiscovery: true)
        let preview = try service.preview(configuration: .defaults)
        let driver = try XCTUnwrap(preview.changes.first { $0.path.hasSuffix(".claude/skills/standmixer/references/external-workers.md") }).after
        XCTAssertTrue(driver.contains("--sandbox <task-sandbox>"))
        XCTAssertTrue(driver.contains("workspace-write for authorized implementation"))
        XCTAssertTrue(driver.contains("read-only for review"))
        XCTAssertTrue(driver.contains("already authorized"))
        XCTAssertTrue(driver.contains("existing controller perform the Git operations through its normal approval flow"))
        XCTAssertTrue(driver.contains("do not launch another agent for this handoff"))
        XCTAssertFalse(driver.contains("separately authorized root"))
        XCTAssertTrue(driver.contains("<approved-extra-dir-args>"))
        XCTAssertTrue(driver.contains("explicitly pass --add-dir for BOTH absolute paths"))
        XCTAssertTrue(driver.contains("Keep both entries even when one contains the other"))
        XCTAssertTrue(driver.contains("nothing for read-only or ordinary workspace jobs"))
        XCTAssertTrue(driver.contains("report the exact missing permission instead of widening scope"))
        XCTAssertTrue(driver.contains("explicitly authorized an existing execution wrapper"))
        XCTAssertTrue(driver.contains("retain its fence"))
        XCTAssertFalse(driver.contains("--dangerously"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testOptionalAppGeneratesDurableUIFirstControlSkills() {
        let support = URL(fileURLWithPath: "/fixture/Library/Application Support/StandMixer")
        for platform in AgentPlatform.allCases {
            let text = StandMixerCommandSkill.contents(platform: platform,
                executableURL: URL(fileURLWithPath: "/Applications/StandMixer.app/Contents/MacOS/StandMixer"), applicationSupport: support)
            XCTAssertFalse(text.contains("/Applications/StandMixer.app/Contents/MacOS/StandMixer"))
            XCTAssertTrue(text.contains("bin/standmixer"))
            XCTAssertFalse(text.contains("bin/StandMixerHelper"))
            XCTAssertTrue(text.contains("install-mac"))
            XCTAssertTrue(text.contains("update --mac"))
            XCTAssertTrue(text.contains("never check for"))
            XCTAssertTrue(text.contains("Controller Auto"))
            XCTAssertTrue(text.contains(platform == .codex ? "OPEN THE INTERACTIVE UI" : "open the native StandMixer plugin pane"))
        }
    }
}
