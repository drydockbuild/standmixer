import AppKit
import Darwin
import Foundation
import XCTest
@testable import StandMixerCore
@testable import StandMixerApp

@MainActor
final class ClaudeConnectionLifecycleTests: XCTestCase {
    private func fixture() throws -> (URL, AppStore) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("standmixer-app-connection-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let discovery = CLIDiscovery(home: home, environment: [:], applicationDirectories: [], commonDirectories: [], activeExecutables: { [] })
        let service = IntegrationService(discovery: discovery, applicationSupport: root.appendingPathComponent("support"))
        return (root, AppStore(service: service))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The fixture did not reach its expected state")
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func installResistantLogin(in root: URL, connected: Bool = false) throws -> URL {
        let executable = root.appendingPathComponent("home/.local/bin/claude")
        let heartbeat = root.appendingPathComponent("login-heartbeat")
        let child = "trap '' TERM; while :; do printf x >> \(quote(heartbeat.path)); /bin/sleep 0.02; done"
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(quote(root.appendingPathComponent("calls").path))
        case "$*" in
          '--version') printf '%s\\n' '2.1.320 (Claude Code)'; exit 0 ;;
          'auth status --json') printf '%s\\n' '\(connected ? "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\"}" : "{\"loggedIn\":false,\"authMethod\":\"none\",\"apiProvider\":\"firstParty\"}")'; exit \(connected ? 0 : 1) ;;
          'auth login')
            trap '' TERM
            /bin/sh -c \(quote(child)) >/dev/null 2>&1 &
            while :; do /bin/sleep 1; done ;;
          *) exit 98 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return heartbeat
    }

    func testOrdinaryStartupAndTerminationPerformNoAuthentication() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installResistantLogin(in: root)
        let delegate = StandMixerApplicationDelegate()
        delegate.store = store
        XCTAssertFalse(store.hasPendingClaudeConnectionCleanup)
        XCTAssertEqual(delegate.terminationReply { XCTFail("No deferred reply is needed") }, .terminateNow)
        store.openClaudeConnection()
        XCTAssertFalse(store.showsClaudeConnection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
    }

    func testQuitWaitsForDismissedLoginAndItsResistantChildBeforeReplying() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let heartbeat = try installResistantLogin(in: root)
        store.openClaudeConnection()
        try await waitUntil { store.claudeConnection?.state == .signInRequired }
        store.connectClaude()
        try await waitUntil { FileManager.default.fileExists(atPath: heartbeat.path) }
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
        XCTAssertFalse(store.showsClaudeConnection)
        XCTAssertNil(store.claudeConnectionActivity)
        XCTAssertTrue(store.hasPendingClaudeConnectionCleanup, "Dismissal must retain the cancelled task until its child is reaped")
        store.beginEditing()
        XCTAssertTrue(store.saveEditing(), "Cancelled authentication must not block saving settings")
        XCTAssertFalse(store.isEditing)

        let delegate = StandMixerApplicationDelegate()
        delegate.store = store
        var replies = 0
        XCTAssertEqual(delegate.terminationReply { replies += 1 }, .terminateLater)
        XCTAssertEqual(delegate.terminationReply { XCTFail("A second quit must not schedule another reply") }, .terminateLater)
        XCTAssertEqual(replies, 0)
        store.openClaudeConnection()
        XCTAssertFalse(store.showsClaudeConnection, "Shutdown must not permit another authentication task")
        try await waitUntil { replies == 1 }
        XCTAssertFalse(store.hasPendingClaudeConnectionCleanup)
        let size = try Data(contentsOf: heartbeat).count
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(try Data(contentsOf: heartbeat).count, size, "The TERM-resistant login child must stop before termination is approved")
    }

    func testSIGTERMRequestsTheNormalTerminationPathWithoutLaunchingAppKit() async throws {
        var requested = false
        let watcher = StandMixerTerminationSignal { requested = true }
        defer { watcher.stop() }
        XCTAssertEqual(Darwin.kill(getpid(), SIGTERM), 0)
        try await waitUntil { requested }
        XCTAssertTrue(requested)
        watcher.stop()
        watcher.stop()
    }

    func testOnlyCodexClaudeSelectionPromptsAndDismissalAllowsSavingWithoutRepeatedChecks() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installResistantLogin(in: root)
        store.selectedPlatform = .claude
        store.beginEditing()
        store.setModel("gpt-6-astra", for: .planning)
        XCTAssertTrue(store.saveEditing())
        XCTAssertFalse(store.hasPendingClaudeConnectionCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
        store.selectedPlatform = .codex
        store.setModel("claude-opus-5-5", for: .planning)
        XCTAssertFalse(store.showsClaudeConnection, "The initial check must stay quiet")
        try await waitUntil { store.showsClaudeConnection }
        XCTAssertTrue(store.claudeConnectionWasAutomatic)
        XCTAssertEqual(store.claudeConnection?.state, .signInRequired)
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        store.beginEditing()
        XCTAssertTrue(store.saveEditing())
        XCTAssertFalse(store.hasPendingClaudeConnectionCleanup)
        XCTAssertFalse(store.showsClaudeConnection)
        XCTAssertEqual(store.route(.planning).modelID, "claude-opus-5-5")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), calls)
        XCTAssertFalse(calls.contains("auth login"))
        store.setModel("claude-fable-5-2", for: .planning)
        try await waitUntil { store.showsClaudeConnection }
        XCTAssertEqual(store.claudeConnection?.state, .signInRequired, "A new Claude choice re-arms the optional dialog")
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
    }

    func testExistingClaudeConnectionStaysQuietAndAnotherClaudeChoiceChecksAgain() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installResistantLogin(in: root, connected: true)
        store.setModel("claude-opus-5-5", for: .planning)
        try await waitUntil { !store.hasPendingClaudeConnectionCleanup }
        XCTAssertFalse(store.showsClaudeConnection)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        _ = try installResistantLogin(in: root, connected: false)
        store.setModel("claude-fable-5-2", for: .planning)
        try await waitUntil { store.showsClaudeConnection }
        XCTAssertNotEqual(try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), calls)
        XCTAssertEqual(store.claudeConnection?.state, .signInRequired)
        XCTAssertFalse(calls.contains("auth login"))
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
    }

    func testLateDialogDismissalDoesNotCancelANewerQuietCheck() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installResistantLogin(in: root)
        store.openClaudeConnection()
        try await waitUntil { store.claudeConnection?.state == .signInRequired }
        let oldPresentation = try XCTUnwrap(store.claudeConnectionPresentation)
        let lateDismissal = { store.dismissClaudeConnection(presentationID: oldPresentation.id) }
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
        store.setModel("claude-opus-5-5", for: .planning)
        lateDismissal()
        await store.waitForClaudeConnectionCleanup()
        lateDismissal()
        XCTAssertTrue(store.showsClaudeConnection, "The old dialog's onDisappear must not cancel the new choice's quiet check")
        XCTAssertEqual(store.claudeConnection?.state, .signInRequired)
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
    }

    func testLateDialogDismissalDoesNotCancelANewerManualDialog() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installResistantLogin(in: root)
        store.openClaudeConnection()
        try await waitUntil { store.claudeConnection?.state == .signInRequired }
        let oldPresentation = try XCTUnwrap(store.claudeConnectionPresentation)
        let lateDismissal = { store.dismissClaudeConnection(presentationID: oldPresentation.id) }
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
        store.openClaudeConnection()
        lateDismissal()
        await store.waitForClaudeConnectionCleanup()
        lateDismissal()
        XCTAssertTrue(store.showsClaudeConnection, "The old dialog's late dismissal must not close a new presentation")
        XCTAssertEqual(store.claudeConnection?.state, .signInRequired)
        store.dismissClaudeConnection(presentationID: try XCTUnwrap(store.claudeConnectionPresentation).id)
    }

    func testSystemDismissalBeforeANewQuietCheckCannotCancelItsReplacement() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installResistantLogin(in: root)
        store.openClaudeConnection()
        try await waitUntil { store.claudeConnection?.state == .signInRequired }
        let oldPresentation = try XCTUnwrap(store.claudeConnectionPresentation)
        // SwiftUI clears item binding before the old content's onDisappear.
        store.claudeConnectionPresentation = nil
        store.setModel("claude-opus-5-5", for: .planning)
        store.dismissClaudeConnection(presentationID: oldPresentation.id)
        await store.waitForClaudeConnectionCleanup()
        XCTAssertTrue(store.showsClaudeConnection)
        XCTAssertEqual(store.claudeConnection?.state, .signInRequired)
        let replacement = try XCTUnwrap(store.claudeConnectionPresentation)
        XCTAssertNotEqual(replacement.id, oldPresentation.id)
        store.dismissClaudeConnection(presentationID: oldPresentation.id)
        XCTAssertEqual(store.claudeConnectionPresentation?.id, replacement.id)
        store.dismissClaudeConnection(presentationID: replacement.id)
    }
}
