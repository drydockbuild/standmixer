import AppKit
import Foundation
import XCTest
@testable import StandMixerCore
@testable import StandMixerApp

@MainActor
final class ClaudeLogoutTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let service: IntegrationService
        let store: AppStore

        var calls: [String] {
            ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        var heartbeat: URL { root.appendingPathComponent("logout-heartbeat") }
        var statusCalls: Int { calls.filter { $0 == "auth status --json" }.count }
        var logoutCalls: Int { calls.filter { $0 == "auth logout" }.count }

        func status(_ value: String) throws {
            try value.write(to: root.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        }

        func logoutMode(_ value: String) throws {
            try value.write(to: root.appendingPathComponent("logout-mode"), atomically: true, encoding: .utf8)
        }
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func fixture(status: String = "connected", hasClaude: Bool = true) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("standmixer-app-logout-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\n[ \"$*\" = '--version' ] || exit 98\nprintf '%s\\n' 'codex-cli 0.120.0'\n"
            .write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        if hasClaude {
            let executable = bin.appendingPathComponent("claude")
            let statusPath = quote(root.appendingPathComponent("status").path)
            let child = "trap '' TERM; while :; do printf x >> \(quote(root.appendingPathComponent("logout-heartbeat").path)); /bin/sleep 0.02; done"
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> \(quote(root.appendingPathComponent("calls").path))
            case "$*" in
              '--version') printf '%s\\n' '2.1.320 (Claude Code)'; exit 0 ;;
              'auth status --json')
                case "$(/bin/cat \(statusPath))" in
                  connected) printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0 ;;
                  signed-out) printf '%s\\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'; exit 1 ;;
                  *) printf '%s\\n' 'network unavailable'; exit 2 ;;
                esac ;;
              'auth logout')
                case "$(/bin/cat \(quote(root.appendingPathComponent("logout-mode").path)))" in
                  failed) exit 2 ;;
                  unknown) printf unavailable > \(statusPath); exit 0 ;;
                  resistant)
                    trap '' TERM
                    /bin/sh -c \(quote(child)) >/dev/null 2>&1 &
                    while :; do /bin/sleep 1; done ;;
                  *) printf signed-out > \(statusPath); exit 0 ;;
                esac ;;
              'auth login') printf connected > \(statusPath); exit 0 ;;
              *) exit 98 ;;
            esac
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try status.write(to: root.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        try "success".write(to: root.appendingPathComponent("logout-mode"), atomically: true, encoding: .utf8)
        let discovery = CLIDiscovery(home: home, environment: [:], applicationDirectories: [], commonDirectories: [], activeExecutables: { [] })
        let service = IntegrationService(discovery: discovery, applicationSupport: root.appendingPathComponent("support"))
        try service.saveConfiguration(.defaults)
        return .init(root: root, service: service, store: AppStore(service: service))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The logout fixture did not reach its expected state")
        throw StandMixerError.invalid("Logout fixture timed out")
    }

    private func open(_ fixture: Fixture) async throws -> UUID {
        fixture.store.openClaudeConnection()
        try await waitUntil { fixture.store.claudeConnectionActivity == nil }
        return try XCTUnwrap(fixture.store.claudeConnectionPresentation).id
    }

    private func confirmLogout(_ fixture: Fixture, presentationID: UUID) {
        fixture.store.requestClaudeLogout(presentationID: presentationID)
        XCTAssertTrue(fixture.store.showsClaudeLogoutConfirmation)
        fixture.store.logoutClaude(presentationID: presentationID)
    }

    func testOpeningAndCancellingConfirmationNeverLogsOut() async throws {
        let fixture = try fixture()
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        let presentationID = try await open(fixture)
        let calls = fixture.calls
        let configuration = fixture.store.configuration
        XCTAssertTrue(fixture.store.canLogoutClaude)
        fixture.store.logoutClaude(presentationID: presentationID)
        XCTAssertEqual(fixture.calls, calls, "Confirmation is required before starting logout")
        fixture.store.requestClaudeLogout(presentationID: UUID())
        XCTAssertFalse(fixture.store.showsClaudeLogoutConfirmation)
        fixture.store.requestClaudeLogout(presentationID: presentationID)
        XCTAssertTrue(fixture.store.showsClaudeLogoutConfirmation)
        fixture.store.checkClaudeConnection()
        fixture.store.connectClaude()
        XCTAssertFalse(fixture.store.hasPendingClaudeConnectionCleanup, "A confirmation must not start or compete with authentication work")
        fixture.store.cancelClaudeLogoutConfirmation(presentationID: presentationID)
        XCTAssertFalse(fixture.store.showsClaudeLogoutConfirmation)
        XCTAssertEqual(fixture.store.claudeConnection?.state, .connected)
        XCTAssertEqual(fixture.calls, calls)
        XCTAssertEqual(fixture.store.configuration, configuration)
        fixture.store.requestClaudeLogout(presentationID: presentationID)
        fixture.store.dismissClaudeConnection(presentationID: presentationID)
        XCTAssertFalse(fixture.store.showsClaudeLogoutConfirmation)
        XCTAssertEqual(fixture.logoutCalls, 0)
        XCTAssertFalse(fixture.calls.contains("auth login"))
    }

    func testConfirmedLogoutRequiresExplicitLoginAndPreservesRouting() async throws {
        let fixture = try fixture()
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        let presentationID = try await open(fixture)
        let configuration = fixture.store.configuration
        let saved = try Data(contentsOf: fixture.service.applicationSupport.appendingPathComponent("configuration.json"))
        confirmLogout(fixture, presentationID: presentationID)
        XCTAssertEqual(fixture.store.claudeConnectionActivity, .loggingOut)
        XCTAssertFalse(fixture.store.showsClaudeLogoutConfirmation)
        XCTAssertFalse(fixture.store.canLogoutClaude)
        try await waitUntil { fixture.store.claudeConnectionActivity == nil }
        XCTAssertEqual(fixture.store.claudeConnection?.state, .signInRequired)
        XCTAssertEqual(fixture.logoutCalls, 1)
        XCTAssertFalse(fixture.calls.contains("auth login"), "A verified logout only offers Continue with Claude")
        XCTAssertEqual(fixture.store.configuration, configuration)
        XCTAssertEqual(try Data(contentsOf: fixture.service.applicationSupport.appendingPathComponent("configuration.json")), saved)
        fixture.store.connectClaude()
        try await waitUntil { fixture.store.claudeConnection?.state == .connected }
        XCTAssertEqual(fixture.calls.filter { $0 == "auth login" }.count, 1)
    }

    func testUnavailableConnectionCanLogOutButMissingAndSignedOutCannot() async throws {
        for initialStatus in ["unavailable", "signed-out", "missing"] {
            let fixture = try fixture(status: initialStatus, hasClaude: initialStatus != "missing")
            defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
            let presentationID = try await open(fixture)
            XCTAssertEqual(fixture.store.canLogoutClaude, initialStatus == "unavailable")
            fixture.store.requestClaudeLogout(presentationID: presentationID)
            XCTAssertEqual(fixture.store.showsClaudeLogoutConfirmation, initialStatus == "unavailable")
            fixture.store.logoutClaude(presentationID: presentationID)
            if initialStatus == "unavailable" {
                try await waitUntil { fixture.store.claudeConnectionActivity == nil }
                XCTAssertEqual(fixture.store.claudeConnection?.state, .signInRequired)
                XCTAssertEqual(fixture.logoutCalls, 1)
            } else {
                XCTAssertEqual(fixture.logoutCalls, 0)
            }
            XCTAssertFalse(fixture.calls.contains("auth login"))
        }
    }

    func testFailedAndUnverifiedLogoutStayUnknownAndAllowExplicitRetry() async throws {
        for mode in ["failed", "unknown"] {
            let fixture = try fixture()
            defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
            let presentationID = try await open(fixture)
            try fixture.logoutMode(mode)
            confirmLogout(fixture, presentationID: presentationID)
            try await waitUntil { fixture.store.claudeConnectionActivity == nil }
            XCTAssertEqual(fixture.store.claudeConnection?.state, .unavailable)
            XCTAssertTrue(fixture.store.canLogoutClaude)
            fixture.store.connectClaude()
            XCTAssertFalse(fixture.calls.contains("auth login"), "Unknown logout results must not offer a new login")
            try fixture.logoutMode("success")
            confirmLogout(fixture, presentationID: presentationID)
            try await waitUntil { fixture.store.claudeConnectionActivity == nil }
            XCTAssertEqual(fixture.store.claudeConnection?.state, .signInRequired)
            XCTAssertEqual(fixture.logoutCalls, 2)
        }
    }

    func testStaleConfirmationCannotChangeOrLogOutANewerPresentation() async throws {
        let fixture = try fixture()
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        let oldID = try await open(fixture)
        fixture.store.requestClaudeLogout(presentationID: oldID)
        fixture.store.dismissClaudeConnection(presentationID: oldID)
        let newID = try await open(fixture)
        XCTAssertNotEqual(newID, oldID)
        fixture.store.requestClaudeLogout(presentationID: newID)
        fixture.store.cancelClaudeLogoutConfirmation(presentationID: oldID)
        fixture.store.logoutClaude(presentationID: oldID)
        fixture.store.dismissClaudeConnection(presentationID: oldID)
        XCTAssertTrue(fixture.store.showsClaudeLogoutConfirmation)
        XCTAssertEqual(fixture.store.claudeConnectionPresentation?.id, newID)
        XCTAssertEqual(fixture.logoutCalls, 0)
        fixture.store.logoutClaude(presentationID: newID)
        try await waitUntil { fixture.store.claudeConnection?.state == .signInRequired }
        XCTAssertEqual(fixture.logoutCalls, 1)
    }

    func testCancelledLogoutCannotOverwriteANewerPresentationAndRejectsDuplicateActions() async throws {
        let fixture = try fixture()
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        let oldID = try await open(fixture)
        try fixture.logoutMode("resistant")
        confirmLogout(fixture, presentationID: oldID)
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.heartbeat.path) }
        fixture.store.requestClaudeLogout(presentationID: oldID)
        fixture.store.logoutClaude(presentationID: oldID)
        fixture.store.checkClaudeConnection()
        fixture.store.connectClaude()
        XCTAssertEqual(fixture.store.claudeConnectionActivity, .loggingOut)
        XCTAssertFalse(fixture.store.showsClaudeLogoutConfirmation)
        XCTAssertEqual(fixture.logoutCalls, 1)
        fixture.store.dismissClaudeConnection(presentationID: oldID)
        XCTAssertTrue(fixture.store.hasPendingClaudeConnectionCleanup)
        let newID = try await open(fixture)
        fixture.store.dismissClaudeConnection(presentationID: oldID)
        await fixture.store.waitForClaudeConnectionCleanup()
        XCTAssertEqual(fixture.store.claudeConnectionPresentation?.id, newID)
        XCTAssertEqual(fixture.store.claudeConnection?.state, .connected)
        XCTAssertNil(fixture.store.claudeConnectionError)
        XCTAssertFalse(fixture.store.hasPendingClaudeConnectionCleanup)
        let size = try Data(contentsOf: fixture.heartbeat).count
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(try Data(contentsOf: fixture.heartbeat).count, size)
    }

    func testSystemDismissalOfConfirmationCannotBlockANewerQuietCheck() async throws {
        let fixture = try fixture()
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        let oldID = try await open(fixture)
        fixture.store.requestClaudeLogout(presentationID: oldID)
        // SwiftUI clears its item binding before the old sheet's onDisappear.
        fixture.store.claudeConnectionPresentation = nil
        try fixture.status("signed-out")
        fixture.store.setModel("claude-opus-5-5", for: .planning)
        fixture.store.dismissClaudeConnection(presentationID: oldID)
        await fixture.store.waitForClaudeConnectionCleanup()
        XCTAssertFalse(fixture.store.showsClaudeLogoutConfirmation)
        XCTAssertTrue(fixture.store.showsClaudeConnection)
        XCTAssertEqual(fixture.store.claudeConnection?.state, .signInRequired)
        XCTAssertNotEqual(fixture.store.claudeConnectionPresentation?.id, oldID)
        XCTAssertEqual(fixture.logoutCalls, 0)
    }

    func testQuitWaitsForLogoutProcessCleanupAndPreventsAnotherJob() async throws {
        let fixture = try fixture()
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        let presentationID = try await open(fixture)
        try fixture.logoutMode("resistant")
        confirmLogout(fixture, presentationID: presentationID)
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.heartbeat.path) }
        let delegate = StandMixerApplicationDelegate()
        delegate.store = fixture.store
        var replies = 0
        XCTAssertEqual(delegate.terminationReply { replies += 1 }, .terminateLater)
        XCTAssertEqual(delegate.terminationReply { XCTFail("Quit must schedule only one reply") }, .terminateLater)
        fixture.store.requestClaudeLogout(presentationID: presentationID)
        fixture.store.logoutClaude(presentationID: presentationID)
        fixture.store.openClaudeConnection()
        XCTAssertFalse(fixture.store.showsClaudeConnection)
        XCTAssertFalse(fixture.store.showsClaudeLogoutConfirmation)
        try await waitUntil { replies == 1 }
        XCTAssertFalse(fixture.store.hasPendingClaudeConnectionCleanup)
        XCTAssertEqual(fixture.logoutCalls, 1)
        let size = try Data(contentsOf: fixture.heartbeat).count
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(try Data(contentsOf: fixture.heartbeat).count, size)
    }

    func testLogoutInvalidatesPreparedReviewAndCachedConnection() async throws {
        let fixture = try fixture()
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.refreshConnections()
        try await waitUntil { !fixture.store.hasPendingClaudeConnectionCleanup }
        fixture.store.preparePreview()
        try await waitUntil { fixture.store.preview != nil || fixture.store.errorMessage != nil }
        XCTAssertNotNil(fixture.store.preview, fixture.store.errorMessage ?? "The initial review should be available")
        let presentationID = try await open(fixture)
        confirmLogout(fixture, presentationID: presentationID)
        XCTAssertNil(fixture.store.preview)
        XCTAssertFalse(fixture.store.isPreparingPreview)
        XCTAssertTrue(fixture.store.previewPlatforms.isEmpty)
        try await waitUntil { fixture.store.claudeConnection?.state == .signInRequired }
        // Closing through cancellation leaves automatic prompts unsuppressed, so the
        // next explicit review must check again instead of reusing the old confirmation.
        fixture.store.cancelClaudeConnection()
        let statusCalls = fixture.statusCalls
        fixture.store.preparePreview()
        try await waitUntil { fixture.store.showsClaudeConnection }
        XCTAssertGreaterThan(fixture.statusCalls, statusCalls)
        XCTAssertEqual(fixture.store.claudeConnection?.state, .signInRequired)
        XCTAssertNil(fixture.store.preview)
        XCTAssertEqual(fixture.store.installationStatus?.state, .notInstalled)
    }

    func testLogoutDropsPendingReviewResumptionEvenAfterDialogDismissal() async throws {
        let fixture = try fixture(status: "unavailable")
        defer { fixture.store.beginTermination(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.refreshConnections()
        fixture.store.preparePreview()
        try await waitUntil { fixture.store.showsClaudeConnection }
        XCTAssertEqual(fixture.store.claudeConnection?.state, .unavailable)
        let presentationID = try XCTUnwrap(fixture.store.claudeConnectionPresentation).id
        confirmLogout(fixture, presentationID: presentationID)
        try await waitUntil { fixture.store.claudeConnection?.state == .signInRequired }
        fixture.store.dismissClaudeConnection(presentationID: presentationID)
        XCTAssertNil(fixture.store.preview)
        XCTAssertFalse(fixture.store.isPreparingPreview, "Finishing or dismissing logout must not resume an earlier review")
        XCTAssertFalse(fixture.store.hasPendingClaudeConnectionCleanup)
        XCTAssertEqual(fixture.store.installationStatus?.state, .notInstalled)
        XCTAssertFalse(fixture.calls.contains("auth login"))
    }
}
