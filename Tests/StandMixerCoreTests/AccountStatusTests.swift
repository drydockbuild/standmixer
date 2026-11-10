import Foundation
import XCTest
@testable import StandMixerCore

final class AccountStatusTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = .init(home: root.appendingPathComponent("home"), applicationSupport: root.appendingPathComponent("support"), environment: [:], metadataOnlyDiscovery: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func capture(_ stdout: String = "", stderr: String = "", exit: Int32 = 0) -> InspectionProcess.Capture {
        .init(output: Data(stdout.utf8), diagnostics: Data(stderr.utf8), waitStatus: exit << 8,
              outputOverflow: false, diagnosticsOverflow: false)
    }
    private func encoded(_ value: StandMixerCLIAccount) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }

    func testClaudeWhitelistsPublicIdentityAndRecognizesSignedOutExitOne() throws {
        let raw = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"fixture@example.invalid","subscriptionType":"max","configDirectory":"/private/config-secret","orgId":"org-secret","accessToken":"token-secret"}"#
        let account = StandMixerAccountChecker.parse(capture(raw), platform: .claude, cliPath: "/fixture/claude")
        XCTAssertEqual(account.status, .signedIn)
        XCTAssertEqual(account.email, "fixture@example.invalid")
        XCTAssertEqual(account.subscription, "max")
        let json = try encoded(account)
        for secret in ["config-secret", "org-secret", "token-secret", "configDirectory", "orgId", "accessToken", "apiProvider"] { XCTAssertFalse(json.contains(secret)) }
        let signedOut = StandMixerAccountChecker.parse(capture(#"{"loggedIn":false,"email":"stale@example.invalid","subscriptionType":"max"}"#, exit: 1), platform: .claude, cliPath: "/fixture/claude")
        XCTAssertEqual(signedOut.status, .signedOut)
        XCTAssertNil(signedOut.email)
        XCTAssertNil(signedOut.subscription)
        let apiKey = StandMixerAccountChecker.parse(capture(#"{"loggedIn":true,"authMethod":"api_key","email":"stale@example.invalid","subscriptionType":"max"}"#), platform: .claude, cliPath: "/fixture/claude")
        XCTAssertEqual(apiKey.status, .signedIn)
        XCTAssertNil(apiKey.email)
        XCTAssertNil(apiKey.subscription)
    }

    func testCodexReadsBothStreamsWithoutReturningCredentialTextOrInventingIdentity() throws {
        for text in ["Logged in using ChatGPT\n", "Logged in using an API key - sk-fixture-secret\n", "Logged in using API key: sk-fixture-secret\n"] {
            for output in [capture(text), capture(stderr: text)] {
                let account = StandMixerAccountChecker.parse(output, platform: .codex, cliPath: "/fixture/codex")
                XCTAssertEqual(account.status, .signedIn)
                XCTAssertNil(account.email)
                XCTAssertNil(account.subscription)
                XCTAssertFalse(try encoded(account).contains("sk-fixture-secret"))
                XCTAssertTrue(account.detail.contains("public status command does not provide"))
            }
        }
        let signedOut = StandMixerAccountChecker.parse(capture(stderr: "Not logged in\n", exit: 1), platform: .codex, cliPath: "/fixture/codex")
        XCTAssertEqual(signedOut.status, .signedOut)
        let error = StandMixerAccountChecker.parse(capture(stderr: "Unsupported command. token=private-secret", exit: 2), platform: .codex, cliPath: "/fixture/codex")
        XCTAssertEqual(error.status, .unknown)
        XCTAssertFalse(try encoded(error).contains("private-secret"))
    }

    func testMalformedUnsafeAndOversizedMetadataRemainUnknownOrOmitUnsafeIdentity() {
        for text in ["", "not JSON", #"{"loggedIn":1}"#, #"{"email":"fixture@example.invalid"}"#] {
            XCTAssertEqual(StandMixerAccountChecker.parse(capture(text), platform: .claude, cliPath: "/fixture/claude").status, .unknown)
        }
        let unsafe = StandMixerAccountChecker.parse(capture(#"{"loggedIn":true,"email":"bad\nprivate-secret@example.invalid","subscriptionType":"sk-private-secret"}"#), platform: .claude, cliPath: "/fixture/claude")
        XCTAssertEqual(unsafe.status, .signedIn)
        XCTAssertNil(unsafe.email)
        XCTAssertNil(unsafe.subscription)
        var overflow = capture(#"{"loggedIn":true}"#); overflow.outputOverflow = true
        XCTAssertEqual(StandMixerAccountChecker.parse(overflow, platform: .claude, cliPath: "/fixture/claude").status, .unknown)
        let oversized = capture(String(repeating: "x", count: StandMixerAccountChecker.maximumOutputBytes + 1))
        XCTAssertEqual(StandMixerAccountChecker.parse(oversized, platform: .codex, cliPath: "/fixture/codex").status, .unknown)
    }

    func testChecksRunConcurrentlyWithExactPublicArgumentsAndPreservePartialStatuses() async throws {
        actor Calls {
            var calls: [(AgentPlatform, [String])] = []
            var waiter: CheckedContinuation<Void, Never>?
            func started(_ platform: AgentPlatform, _ arguments: [String]) async {
                calls.append((platform, arguments))
                if calls.count == 2 { waiter?.resume(); waiter = nil }
                else { await withCheckedContinuation { waiter = $0 } }
            }
        }
        let calls = Calls()
        let report = try await StandMixerAccountChecker.check(service: service,
            executables: [.codex: URL(fileURLWithPath: "/fixture/codex"), .claude: URL(fileURLWithPath: "/fixture/claude")],
            runner: { platform, executable, arguments, environment, cwd, timeout in
                await calls.started(platform, arguments)
                XCTAssertEqual(executable.path, "/fixture/" + platform.rawValue)
                XCTAssertEqual(environment["HOME"], self.service.home.path)
                XCTAssertEqual(timeout, 10)
                XCTAssertTrue(FileManager.default.fileExists(atPath: cwd.path))
                if platform == .codex { throw AgentImportError.timedOut(timeout) }
                return self.capture(#"{"loggedIn":false}"#, exit: 1)
            })
        XCTAssertEqual(report.providers.map(\.platform), [.codex, .claude])
        XCTAssertEqual(report.providers.map(\.status), [.unknown, .signedOut])
        let recorded = await calls.calls
        XCTAssertEqual(recorded.first { $0.0 == .codex }?.1, ["login", "status"])
        XCTAssertEqual(recorded.first { $0.0 == .claude }?.1, ["auth", "status", "--json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
    }

    func testFixtureDefaultNeverStartsCommandsOrPersistsIdentity() async throws {
        let report = try await StandMixerAccountChecker.check(service: service)
        XCTAssertEqual(report.providers.map(\.status), [.unknown, .unknown])
        XCTAssertTrue(report.providers.allSatisfy { $0.email == nil && $0.subscription == nil && $0.cliPath == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testCancellationStopsOwnedStatusDescendantsWithoutReadingCredentials() async throws {
        let heartbeat = root.appendingPathComponent("heartbeat")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let child = "trap '' TERM; while :; do /usr/bin/printf x >> " + quote(heartbeat.path) + "; /bin/sleep 0.05; done"
        let executable = root.appendingPathComponent("fake-codex")
        try ("#!/bin/sh\n/bin/sh -c " + quote(child) + " &\nwait\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let liveFixtureService = IntegrationService(home: service.home, applicationSupport: service.applicationSupport, environment: [:])
        let operation = Task {
            try await StandMixerAccountChecker.check(service: liveFixtureService, executables: [.codex: executable], runner: nil)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: heartbeat.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = try Data(contentsOf: heartbeat).count
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try Data(contentsOf: heartbeat).count, count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }
}
