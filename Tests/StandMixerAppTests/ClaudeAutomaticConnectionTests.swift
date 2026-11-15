import Foundation
import XCTest
@testable import StandMixerCore
@testable import StandMixerApp

@MainActor
final class ClaudeAutomaticConnectionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let service: IntegrationService
        let store: AppStore

        var calls: [String] {
            ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        var statusCalls: Int { calls.filter { $0 == "auth status --json" }.count }

        func status(_ value: String) throws {
            try value.write(to: root.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        }
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func fixture(status: String = "signed-out", saved: StandMixerConfiguration? = nil,
                         hasCodex: Bool = true, hasClaude: Bool = true) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("standmixer-automatic-connection-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if hasCodex {
            let executable = bin.appendingPathComponent("codex")
            try "#!/bin/sh\n[ \"$*\" = '--version' ] || exit 98\nprintf '%s\\n' 'codex-cli 0.120.0'\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        if hasClaude {
            let executable = bin.appendingPathComponent("claude")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> \(quote(root.appendingPathComponent("calls").path))
            case "$*" in
              '--version') printf '%s\\n' '2.1.320 (Claude Code)'; exit 0 ;;
              'auth status --json')
                case "$(/bin/cat \(quote(root.appendingPathComponent("status").path)))" in
                  connected) printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0 ;;
                  signed-out) printf '%s\\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'; exit 1 ;;
                  delayed) /bin/sleep 1; printf '%s\\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'; exit 1 ;;
                  *) printf '%s\\n' 'network unavailable'; exit 2 ;;
                esac ;;
              *) exit 98 ;;
            esac
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try status.write(to: root.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        let discovery = CLIDiscovery(home: home, environment: [:], applicationDirectories: [], commonDirectories: [], activeExecutables: { [] })
        let service = IntegrationService(discovery: discovery, applicationSupport: root.appendingPathComponent("support"))
        if let saved { try service.saveConfiguration(saved) }
        return .init(root: root, service: service, store: AppStore(service: service))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The fixture did not reach its expected state")
    }

    func testFirstOpenChecksRequiredClaudeAndPromptsWithoutLoginOrApply() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(fixture.statusCalls, 0)
        await fixture.store.refreshConnections()
        try await waitUntil { fixture.store.showsClaudeConnection }
        XCTAssertEqual(fixture.store.claudeConnection?.state, .signInRequired)
        XCTAssertTrue(fixture.store.claudeConnectionWasAutomatic)
        XCTAssertEqual(fixture.statusCalls, 1)
        XCTAssertFalse(fixture.calls.contains("auth login"))
        XCTAssertEqual(fixture.store.installationStatus?.state, .notInstalled)
        fixture.store.dismissClaudeConnection(presentationID: try XCTUnwrap(fixture.store.claudeConnectionPresentation).id)
        await fixture.store.refreshConnections()
        XCTAssertEqual(fixture.statusCalls, 1, "Not now suppresses automatic repeats during this open")
        XCTAssertFalse(fixture.store.showsClaudeConnection)
    }

    func testConnectedFirstOpenStaysQuietAndEachProviderReenableChecksFreshStatus() async throws {
        for platform in AgentPlatform.allCases {
            let fixture = try fixture(status: "connected")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            await fixture.store.refreshConnections()
            try await waitUntil { !fixture.store.hasPendingClaudeConnectionCleanup }
            XCTAssertEqual(fixture.statusCalls, 1)
            XCTAssertFalse(fixture.store.showsClaudeConnection)
            fixture.store.setPlatformEnabled(platform, enabled: false)
            try fixture.status("signed-out")
            fixture.store.setPlatformEnabled(platform, enabled: true)
            try await waitUntil { fixture.store.showsClaudeConnection }
            XCTAssertEqual(fixture.statusCalls, 2, "Re-enabling \(platform) must discard the earlier connected result")
            XCTAssertEqual(fixture.store.claudeConnection?.state, .signInRequired)
            XCTAssertFalse(fixture.calls.contains("auth login"))
            fixture.store.dismissClaudeConnection(presentationID: try XCTUnwrap(fixture.store.claudeConnectionPresentation).id)
        }
    }

    func testDisablingEitherProviderDuringQuietCheckPreventsLatePopup() async throws {
        for platform in AgentPlatform.allCases {
            let fixture = try fixture(status: "delayed")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            await fixture.store.refreshConnections()
            try await waitUntil { fixture.statusCalls == 1 }
            fixture.store.setPlatformEnabled(platform, enabled: false)
            await fixture.store.waitForClaudeConnectionCleanup()
            XCTAssertFalse(fixture.store.showsClaudeConnection)
            XCTAssertNil(fixture.store.claudeConnection)
            XCTAssertFalse(fixture.store.hasPendingClaudeConnectionCleanup)
        }
    }

    func testUnknownStatusOpensProblemStateAndRecheckCanRecover() async throws {
        let fixture = try fixture(status: "network-error")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.refreshConnections()
        try await waitUntil { fixture.store.showsClaudeConnection }
        XCTAssertEqual(fixture.store.claudeConnection?.state, .unavailable)
        XCTAssertTrue(fixture.store.claudeConnection?.detail.contains("does not mean you are signed out") == true)
        fixture.store.connectClaude()
        XCTAssertEqual(fixture.statusCalls, 1, "A problem state must not enable login")
        try fixture.status("connected")
        fixture.store.checkClaudeConnection()
        try await waitUntil { fixture.store.claudeConnection?.state == .connected }
        XCTAssertEqual(fixture.statusCalls, 2)
        XCTAssertFalse(fixture.calls.contains("auth login"))
        fixture.store.dismissClaudeConnection(presentationID: try XCTUnwrap(fixture.store.claudeConnectionPresentation).id)
    }

    func testThrownCheckFailureOpensProblemStateWithoutStartingLogin() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.service.applicationSupport, withIntermediateDirectories: true)
        let preference = fixture.service.applicationSupport.appendingPathComponent("claude-connection.json")
        try Data("invalid fixture".utf8).write(to: preference)
        await fixture.store.refreshConnections()
        guard fixture.store.installedPlatforms == Set(AgentPlatform.allCases) else {
            XCTFail("Fixture CLI discovery verified only \(fixture.store.installedPlatforms)")
            return
        }
        try await waitUntil { fixture.store.showsClaudeConnection }
        XCTAssertNil(fixture.store.claudeConnection)
        XCTAssertTrue(fixture.store.claudeConnectionError?.contains("could not read the saved Claude connection") == true)
        fixture.store.connectClaude()
        XCTAssertEqual(fixture.statusCalls, 0)
        try FileManager.default.removeItem(at: preference)
        fixture.store.checkClaudeConnection()
        try await waitUntil { fixture.store.claudeConnection?.state == .signInRequired }
        XCTAssertFalse(fixture.calls.contains("auth login"))
        fixture.store.dismissClaudeConnection(presentationID: try XCTUnwrap(fixture.store.claudeConnectionPresentation).id)
    }

    func testEscapeDismissalAllowsReviewWithoutAnotherAutomaticCheck() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.refreshConnections()
        try await waitUntil { fixture.store.showsClaudeConnection }
        let presentation = try XCTUnwrap(fixture.store.claudeConnectionPresentation)
        fixture.store.claudeConnectionPresentation = nil
        fixture.store.dismissClaudeConnection(presentationID: presentation.id)
        fixture.store.preparePreview()
        try await waitUntil { fixture.store.preview != nil || fixture.store.errorMessage != nil }
        XCTAssertNotNil(fixture.store.preview, fixture.store.errorMessage ?? "Review should remain available without signing in")
        XCTAssertEqual(fixture.statusCalls, 1)
        XCTAssertFalse(fixture.store.showsClaudeConnection)
        XCTAssertEqual(fixture.store.installationStatus?.state, .notInstalled)
    }

    func testSavedClaudeRequirementSurvivesNativeOnlyLaunchProposalWhenClaudeIsMissing() async throws {
        var saved = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.codex, .claude])
        saved.enabledPlatforms = [.codex, .claude]
        let fixture = try fixture(saved: saved, hasClaude: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.refreshConnections()
        try await waitUntil { fixture.store.showsClaudeConnection }
        XCTAssertTrue(ClaudeConnectionTrigger.usage(in: fixture.store.configuration, catalog: fixture.store.availableModels).isEmpty)
        XCTAssertEqual(fixture.store.claudeConnection?.state, .missing)
        fixture.store.dismissClaudeConnection(presentationID: try XCTUnwrap(fixture.store.claudeConnectionPresentation).id)
    }

    func testDisabledProvidersAndReverseOnlySetupDoNotCheckAuthentication() async throws {
        for platforms: Set<AgentPlatform> in [[.codex], [.claude]] {
            var saved = StandMixerConfiguration.preset(.optimized, availablePlatforms: [.codex, .claude])
            saved.enabledPlatforms = platforms
            let fixture = try fixture(saved: saved)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            await fixture.store.refreshConnections()
            XCTAssertEqual(fixture.statusCalls, 0)
            XCTAssertFalse(fixture.store.showsClaudeConnection)
            XCTAssertFalse(fixture.store.hasPendingClaudeConnectionCleanup)
        }
        let fixture = try fixture(hasCodex: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.refreshConnections()
        XCTAssertEqual(fixture.statusCalls, 0)
    }

    func testNewOpenAndExplicitClaudeChoiceRearmAfterDismissal() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.refreshConnections()
        try await waitUntil { fixture.store.showsClaudeConnection }
        fixture.store.dismissClaudeConnection(presentationID: try XCTUnwrap(fixture.store.claudeConnectionPresentation).id)
        fixture.store.setModel("claude-opus-5-5", for: .planning)
        try await waitUntil { fixture.store.showsClaudeConnection }
        XCTAssertEqual(fixture.statusCalls, 2)
        fixture.store.dismissClaudeConnection(presentationID: try XCTUnwrap(fixture.store.claudeConnectionPresentation).id)
        let reopened = AppStore(service: fixture.service)
        await reopened.refreshConnections()
        try await waitUntil { reopened.showsClaudeConnection }
        XCTAssertEqual(fixture.statusCalls, 3)
        reopened.dismissClaudeConnection(presentationID: try XCTUnwrap(reopened.claudeConnectionPresentation).id)
    }
}
