import Foundation
import XCTest
@testable import StandMixerCore

final class AgentImportRootSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("standmixer-root-safety-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testExistingNormalRootAndMissingDescendantsAreAccepted() throws {
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertTrue(AgentImportRootSafety.isSafe(home))
        XCTAssertTrue(AgentImportRootSafety.isSafe(home.appendingPathComponent(".codex")))
        XCTAssertTrue(AgentImportRootSafety.isSafe(home.appendingPathComponent("custom/new/config/root")))
    }

    func testSymlinkRootAndSymlinkAncestorAreRejectedEvenForOrdinaryTargets() throws {
        let ordinary = root.appendingPathComponent("ordinary")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: ordinary)
        XCTAssertFalse(AgentImportRootSafety.isSafe(linked))
        XCTAssertFalse(AgentImportRootSafety.isSafe(linked.appendingPathComponent("missing/.codex")))
        XCTAssertTrue(AgentImportRootSafety.isSafe(ordinary.appendingPathComponent("missing/.codex")))
    }

    func testDanglingSymlinkAndExistingRegularFileAreRejected() throws {
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing-target"))
        let regular = root.appendingPathComponent("regular-file")
        try "not a directory".write(to: regular, atomically: true, encoding: .utf8)
        XCTAssertFalse(AgentImportRootSafety.isSafe(dangling))
        XCTAssertFalse(AgentImportRootSafety.isSafe(dangling.appendingPathComponent(".claude")))
        XCTAssertFalse(AgentImportRootSafety.isSafe(regular))
        XCTAssertFalse(AgentImportRootSafety.isSafe(regular.appendingPathComponent("missing")))
    }

    func testProtectedAndCloudComponentsAreRejectedBeforeOpeningMissingPaths() {
        let names = ["Music", "mUsIc", "Movies", "Pictures", "Photos", "Downloads", "Desktop", "Documents",
                     "Library", "lIbRaRy", "CloudStorage", "Mobile Documents", "mobile_documents",
                     "iCloud", "iCloud Drive", "GoogleDrive", "Google Drive", "GoogleDrive-user@example.invalid",
                     "Dropbox", "Dropbox (Personal)", "OneDrive", "OneDrive - Example"]
        for name in names {
            let candidate = root.appendingPathComponent("missing").appendingPathComponent(name).appendingPathComponent(".codex")
            XCTAssertFalse(AgentImportRootSafety.isSafe(candidate), "Protected component was accepted: \(name)")
        }
    }

    func testFixedSystemAliasesAreAcceptedWithoutPermittingNewAliases() throws {
        XCTAssertTrue(AgentImportRootSafety.isSafe(URL(fileURLWithPath: "/tmp")))
        XCTAssertTrue(AgentImportRootSafety.isSafe(URL(fileURLWithPath: "/var")))
        XCTAssertTrue(AgentImportRootSafety.isSafe(URL(fileURLWithPath: "/etc")))
        let temporaryDescendant = "/tmp/standmixer-missing-root-\(UUID().uuidString)/.codex"
        XCTAssertTrue(AgentImportRootSafety.isSafe(URL(fileURLWithPath: temporaryDescendant)))
        XCTAssertFalse(AgentImportRootSafety.isSafe(URL(fileURLWithPath: "/tmp/Downloads/.codex")))
        let customAlias = root.appendingPathComponent("temporary-alias")
        try FileManager.default.createSymbolicLink(at: customAlias, withDestinationURL: URL(fileURLWithPath: "/private/tmp"))
        XCTAssertFalse(AgentImportRootSafety.isSafe(customAlias))
    }

    func testNonFileURLsAndTraversalSpellingAreRejected() {
        XCTAssertFalse(AgentImportRootSafety.isSafe(URL(string: "https://example.invalid/.codex")!))
        XCTAssertFalse(AgentImportRootSafety.isSafe(URL(string: "file://remote.invalid/tmp/.codex")!))
        XCTAssertFalse(AgentImportRootSafety.isSafe(URL(fileURLWithPath: root.path + "/ordinary/../.codex")))
    }
}
