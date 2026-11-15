import Darwin
import Foundation
import XCTest
@testable import StandMixerCore

final class ClaudeConnectionTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var boundHome: URL { home.standardizedFileURL }
    private var support: URL { root.appendingPathComponent("support") }
    private var calls: URL { root.appendingPathComponent("calls") }
    private var signedIn: URL { root.appendingPathComponent("signed-in") }
    private var pipeHolderRecord: URL { root.appendingPathComponent("pipe-holder-pid") }
    private var preferenceURL: URL { support.appendingPathComponent("claude-connection.json") }
    private let connected = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"fixture@example.invalid","subscriptionType":"max"}"#

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("standmixer-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func emit(_ value: String, exit: Int = 0) -> String { "printf '%s\\n' \(quote(value))\nexit \(exit)\n" }
    @discardableResult private func fakeCLI(_ relative: String = ".local/bin/claude", version: String = "2.1.320", status: String,
                         login: String = "exit 99\n") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = """
        #!/bin/sh
        printf '%s|%s|%s|%s|%s\\n' \(quote(relative)) "$*" "$HOME" "${CLAUDE_CONFIG_DIR+set}" "${CLAUDE_CONFIG_DIR-}" >> \(quote(calls.path))
        case "$*" in
          '--version') printf '%s (Claude Code)\\n' \(quote(version)); exit 0 ;;
          'auth status --json')
        \(status)
            ;;
          'auth login')
        \(login)
            ;;
          *) exit 98 ;;
        esac
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func integration(environment: [String: String] = [:], active: [URL] = [], metadata: Bool = false) -> IntegrationService {
        let discovery = CLIDiscovery(home: home, environment: environment, applicationDirectories: [], commonDirectories: [],
                                     activeExecutables: { active })
        return IntegrationService(discovery: discovery, applicationSupport: support, metadataOnlyDiscovery: metadata)
    }
    private func service(environment: [String: String] = [:], active: [URL] = [], check: TimeInterval = 3,
                         login: TimeInterval = 2, probe: TimeInterval = 0.5) -> StandMixerClaudeConnectionService {
        .init(service: integration(environment: environment, active: active), checkDuration: check,
              loginDuration: login, probeDuration: probe)
    }
    private func recordedCalls() throws -> [String] {
        try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
    }
    private func waitForFile(_ url: URL, attempts: Int = 100) async throws {
        for _ in 0..<attempts {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture child did not start")
    }
    private func waitForStatusCalls(_ count: Int) async throws {
        for _ in 0..<250 {
            if let calls = try? recordedCalls(), calls.filter({ $0.contains("|auth status --json|") }).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture did not reach \(count) status calls")
    }
    private func assertHeartbeatStopped(_ url: URL) async throws {
        let count = try Data(contentsOf: url).count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try Data(contentsOf: url).count, count)
    }
    private func heartbeatChild(_ url: URL) -> String {
        let child = "trap '' TERM; while :; do printf x >> \(quote(url.path)); /bin/sleep 0.02; done"
        return "/bin/sh -c \(quote(child)) >/dev/null 2>&1 &\nwhile [ ! -s \(quote(url.path)) ]; do /bin/sleep 0.005; done\n"
    }

    private func detachedPipeHolder() -> String {
        // Shell job control assigns the background sleeper its own group. Both pipes stay open.
        """
        set -m
        /bin/sleep 8 &
        printf '%s\\n' "$!" > \(quote(pipeHolderRecord.path))
        exec /bin/sleep 8
        """
    }

    private func detachedPipeHolderPID() -> pid_t? {
        guard let text = try? String(contentsOf: pipeHolderRecord, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    private func waitForDetachedPipeHolder() async throws -> pid_t {
        for _ in 0..<100 {
            if detachedPipeHolderPID() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(detachedPipeHolderPID(), "The fake CLI did not record the pipe holder PID")
        XCTAssertEqual(getpgid(pid), pid, "The pipe holder must be in its own process group")
        return pid
    }

    private func stopDetachedPipeHolder() {
        if let pid = detachedPipeHolderPID(), getpgid(pid) == pid { _ = kill(pid, SIGKILL) }
    }

    func testAlreadyConnectedSkipsLoginAndStoresOnlyLaunchPreference() async throws {
        let cli = try fakeCLI(status: emit(connected))
        let connection = service(probe: 2)
        let report = try await connection.connect()
        XCTAssertEqual(report.state, .connected)
        XCTAssertEqual(report.cliPath, cli.path)
        XCTAssertFalse(try recordedCalls().contains { $0.contains("|auth login|") })
        let preference = try Data(contentsOf: preferenceURL)
        let invocation = try JSONDecoder().decode(StandMixerClaudeInvocation.self, from: preference)
        XCTAssertEqual(invocation.executable, cli)
        XCTAssertEqual(invocation.home, boundHome)
        XCTAssertNil(invocation.configDirectory)
        let text = String(decoding: preference, as: UTF8.self)
        for secret in ["fixture@example.invalid", "subscription", "loggedIn", "max", "authMethod"] { XCTAssertFalse(text.contains(secret)) }
        let attributes = try FileManager.default.attributesOfItem(atPath: preferenceURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testBusyLockKeepsExistingBindingUsableWithoutRewriting() async throws {
        let old = try fakeCLI(".local/share/claude/versions/2.1.320", status: emit(connected))
        let config = root.appendingPathComponent("linked profile").path
        let connection = service(environment: ["CLAUDE_CONFIG_DIR": config], check: 5, probe: 2)
        let initial = try await connection.check()
        XCTAssertEqual(initial.state, .connected)
        let originalBinding = try Data(contentsOf: preferenceURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: preferenceURL.path)
        let originalInode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)

        let locker = integration()
        try locker.acquireOperationLock()
        defer { locker.releaseOperationLock() }
        let check = try await connection.check()
        XCTAssertEqual(check.state, .connected)
        XCTAssertEqual(check.cliPath, old.path)

        try FileManager.default.removeItem(at: old)
        let replacement = try fakeCLI(".local/share/claude/versions/2.1.321", version: "2.1.321", status: emit(connected))
        let launch = try await connection.resolveInvocation()
        XCTAssertEqual(launch.executable, replacement)
        XCTAssertEqual(launch.configDirectory, config)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: preferenceURL.path)
        XCTAssertEqual(finalAttributes[.systemFileNumber] as? NSNumber, originalInode)
        XCTAssertEqual(try Data(contentsOf: preferenceURL), originalBinding)
    }

    func testConcurrentFirstLinksRetryLockWithoutSwitchingProfiles() async throws {
        let gate = root.appendingPathComponent("release-status")
        let waitForGate = "while [ ! -e \(quote(gate.path)) ]; do /bin/sleep 0.01; done\n"
        let cli = try fakeCLI(status: waitForGate + emit(connected))
        let locker = integration()
        try locker.acquireOperationLock()
        var lockHeld = true
        defer { if lockHeld { locker.releaseOperationLock() } }

        let profiles = [root.appendingPathComponent("first profile").path, root.appendingPathComponent("second profile").path]
        let operations = profiles.map { profile in
            let connection = service(environment: ["CLAUDE_CONFIG_DIR": profile], check: 5, probe: 2)
            return Task { try await connection.check() }
        }
        defer { operations.forEach { $0.cancel() } }
        try await waitForStatusCalls(2)
        try Data().write(to: gate)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferenceURL.path))
        locker.releaseOperationLock()
        lockHeld = false

        var linked: [String] = []
        for (profile, operation) in zip(profiles, operations) {
            do {
                let report = try await operation.value
                XCTAssertEqual(report.state, .connected)
                linked.append(profile)
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("selected Claude profile changed"))
            }
        }
        let binding = try JSONDecoder().decode(StandMixerClaudeInvocation.self, from: Data(contentsOf: preferenceURL))
        XCTAssertEqual(binding.executable, cli)
        XCTAssertEqual(linked, [try XCTUnwrap(binding.configDirectory)])
    }

    func testCancellingFirstLinkWhileLockIsBusyLeavesNoBinding() async throws {
        try fakeCLI(status: emit(connected))
        let locker = integration()
        try locker.acquireOperationLock()
        defer { locker.releaseOperationLock() }
        let connection = service(check: 5, probe: 2)
        let operation = Task { try await connection.check() }
        defer { operation.cancel() }
        try await waitForStatusCalls(1)
        try await Task.sleep(for: .milliseconds(100))
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation while waiting to save the binding") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferenceURL.path))
    }

    func testSignedOutUsesOfficialLoginThenExactProfilePostcheck() async throws {
        let config = root.appendingPathComponent("explicit profile").path
        let status = "if [ -f \(quote(signedIn.path)) ]; then\n\(emit(connected))fi\n" + emit(#"{"loggedIn":false}"#, exit: 1)
        let login = "printf '%s\\n' 'https://auth.invalid/private-code' >&2\n/usr/bin/touch \(quote(signedIn.path))\nexit 0\n"
        let cli = try fakeCLI(status: status, login: login)
        let connection = service(environment: ["HOME": "/wrong-home", "CLAUDE_CONFIG_DIR": config,
                                               "ANTHROPIC_API_KEY": "secret-key", "CLAUDE_CODE_OAUTH_TOKEN": "secret-token"])
        let report = try await connection.connect()
        XCTAssertEqual(report.state, .connected)
        XCTAssertEqual(report.cliPath, cli.path)
        let calls = try recordedCalls()
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { $0.hasSuffix("|\(boundHome.path)|set|\(config)") })
        XCTAssertEqual(calls.filter { $0.contains("|auth login|") }.count, 1)
        XCTAssertEqual(calls.filter { $0.contains("|auth status --json|") }.count, 2)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("private-code"))
        XCTAssertFalse(json.contains("secret-"))
    }

    func testUnsetAndExplicitDefaultProfilesRemainDifferent() async throws {
        let cli = try fakeCLI(status: emit(connected))
        let unset = StandMixerClaudeInvocation(executable: cli, home: home, configDirectory: nil)
        let explicit = StandMixerClaudeInvocation(executable: cli, home: home, configDirectory: home.appendingPathComponent(".claude").path)
        let empty = StandMixerClaudeInvocation(executable: cli, home: home, configDirectory: "")
        XCTAssertNil(unset.environment(from: ["CLAUDE_CONFIG_DIR": "/wrong"])["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(explicit.environment(from: [:])["CLAUDE_CONFIG_DIR"], home.appendingPathComponent(".claude").path)
        XCTAssertEqual(empty.environment(from: [:])["CLAUDE_CONFIG_DIR"], "")
        XCTAssertNotEqual(unset, explicit)
        let report = try await service().check()
        XCTAssertEqual(report.state, .connected)
        XCTAssertTrue(try recordedCalls().allSatisfy { $0.hasSuffix("|\(boundHome.path)||") })
    }

    func testBrokenOrSignedOutPreferredCopyFallsBackToWorkingKnownCLI() async throws {
        let broken = try fakeCLI("custom/bin/claude", version: "not-a-version", status: emit(connected))
        let signedOut = try fakeCLI(".local/share/claude/versions/2.1.400", version: "2.1.400", status: emit(#"{"loggedIn":false}"#, exit: 1))
        let healthy = try fakeCLI(".local/bin/claude", status: emit(connected))
        let report = try await service(active: [broken]).check()
        XCTAssertEqual(report.state, .connected)
        XCTAssertEqual(report.cliPath, healthy.path)
        let calls = try recordedCalls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("custom/bin/claude|--version|") })
        XCTAssertTrue(calls.contains { $0.contains("\(signedOut.lastPathComponent)|auth status --json|") })
        XCTAssertFalse(calls.contains { $0.contains("|auth login|") })
    }

    func testHealthySavedConnectionPrecedesNewerCLI() async throws {
        let first = try fakeCLI(status: emit(connected))
        _ = try await service().check()
        try fakeCLI(".local/share/claude/versions/2.9.999", version: "2.9.999", status: emit(connected))
        try FileManager.default.removeItem(at: calls)
        let report = try await service().check()
        XCTAssertEqual(report.cliPath, first.path)
        XCTAssertEqual(try recordedCalls().count, 2)
    }

    func testSavedProfileSurvivesMissingBinaryAndDifferentHostEnvironment() async throws {
        let old = try fakeCLI(".local/share/claude/versions/2.1.320", status: emit(connected))
        let config = root.appendingPathComponent("chosen profile").path
        _ = try await service(environment: ["CLAUDE_CONFIG_DIR": config]).check()
        try FileManager.default.removeItem(at: old)
        let replacement = try fakeCLI(".local/share/claude/versions/2.1.321", version: "2.1.321", status: emit(connected))
        try FileManager.default.removeItem(at: calls)
        let relaunched = service(environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("different profile").path])
        let report = try await relaunched.check()
        XCTAssertEqual(report.state, .connected)
        let invocation = try await relaunched.resolveInvocation()
        XCTAssertEqual(invocation.executable, replacement)
        XCTAssertEqual(invocation.configDirectory, config)
        XCTAssertTrue(try recordedCalls().allSatisfy { $0.hasSuffix("|\(boundHome.path)|set|\(config)") })
        let connectedAgain = try await relaunched.connect()
        XCTAssertEqual(connectedAgain.state, .connected)
        XCTAssertFalse(try recordedCalls().contains { $0.contains("|auth login|") })
    }

    func testLoginExitZeroRequiresSuccessfulExactStatus() async throws {
        try fakeCLI(status: emit(#"{"loggedIn":false}"#, exit: 1), login: "exit 0\n")
        let report = try await service().connect()
        XCTAssertEqual(report.state, .signInRequired)
        XCTAssertEqual(try recordedCalls().filter { $0.contains("|auth status --json|") }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("claude-connection.json").path))
    }

    func testUnexpectedExitAndUnknownStatusNeverStartLoginOrExposeOutput() async throws {
        for exitCode in [0, 1, 2, 7] {
            let body = exitCode < 2 ? #"{"error":"private-secret","authorizationURL":"https://auth.invalid/private-code"}"# : #"{"loggedIn":false,"accessToken":"private-secret"}"#
            try fakeCLI(status: emit(body, exit: exitCode), login: "exit 0\n")
            let report = try await service().connect()
            XCTAssertEqual(report.state, .unavailable)
            let serialized = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
            XCTAssertFalse(serialized.contains("private-secret"))
            XCTAssertFalse(serialized.contains("private-code"))
        }
        XCTAssertFalse(try recordedCalls().contains { $0.contains("|auth login|") })
    }

    func testStatusParserRequiresNativeSubscriptionAndIgnoresPrivateFields() throws {
        func parse(_ text: String, code: Int32? = 0, overflow: Bool = false) -> StandMixerClaudeConnectionReport {
            StandMixerClaudeConnectionService.parse(.init(output: Data(text.utf8), exitCode: code, overflow: overflow), cliPath: "/fixture/claude")
        }
        for text in [#"{"loggedIn":true,"authMethod":"api_key"}"#, #"{"loggedIn":true,"authMethod":"api_key_helper"}"#,
                     #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#, #"{"loggedIn":true}"#,
                     #"{"loggedIn":1,"authMethod":"claude.ai"}"#] {
            XCTAssertEqual(parse(text).state, .unavailable)
        }
        XCTAssertEqual(parse(connected, code: 1).state, .unavailable)
        XCTAssertEqual(parse(connected, code: nil).state, .unavailable)
        XCTAssertEqual(parse(connected, overflow: true).state, .unavailable)
        XCTAssertEqual(parse(#"{"loggedIn":true,"authMethod":"claude.ai","loginExpiresAt":1}"#).state, .signInRequired)
        let report = parse(#"{"loggedIn":true,"authMethod":"claude.ai","email":"fixture@example.invalid","subscriptionType":"max","accessToken":"private-token","authorizationURL":"https://auth.invalid/private-code"}"#)
        XCTAssertEqual(report.state, .connected)
        let encoded = try JSONEncoder().encode(report)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["state", "detail", "cliPath", "checkedAt"])
        let serialized = String(decoding: encoded, as: UTF8.self)
        for secret in ["max", "private-token", "private-code", "fixture@example.invalid"] { XCTAssertFalse(serialized.contains(secret)) }
    }

    func testSanitizedEnvironmentCannotOverrideNativeConnection() throws {
        let invocation = StandMixerClaudeInvocation(executable: home.appendingPathComponent(".local/bin/claude"), home: home, configDirectory: nil)
        let secrets = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
                       "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                       "NODE_OPTIONS", "NODE_PATH", "BASH_ENV", "CLAUDE_CODE_SETTINGS_PATH", "DYLD_INSERT_LIBRARIES", "CODEX_SESSION_ID"]
        var source = Dictionary(uniqueKeysWithValues: secrets.map { ($0, "private-secret") })
        source["HOME"] = "/wrong"; source["CLAUDE_CONFIG_DIR"] = "/wrong-profile"
        source["PATH"] = ":relative:/fixture/bin:/fixture/bin"; source["LANG"] = "en_US.UTF-8"
        source["LC_ALL"] = "fr_FR.UTF-8"
        source["LC_CTYPE"] = "ja_JP.UTF-8"
        source["LC_COLLATE"] = "invalid\0locale"
        let taskVariables = ["AWS_PROFILE", "AWS_ACCESS_KEY_ID", "GOOGLE_APPLICATION_CREDENTIALS", "AZURE_CLIENT_SECRET",
                             "OPENAI_API_KEY", "NODE_EXTRA_CA_CERTS", "HTTPS_PROXY", "SSL_CERT_FILE"]
        for key in taskVariables { source[key] = "fixture-task-value" }
        let probe = invocation.environment(from: source)
        let worker = invocation.workerEnvironment(from: source)
        for environment in [probe, worker] {
            XCTAssertTrue(secrets.allSatisfy { environment[$0] == nil })
            XCTAssertTrue(taskVariables.allSatisfy { environment[$0] == "fixture-task-value" })
            XCTAssertEqual(environment["HOME"], home.path)
            XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
            XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
            XCTAssertEqual(environment["LC_CTYPE"], "ja_JP.UTF-8")
            XCTAssertNil(environment["LC_COLLATE"])
            XCTAssertEqual(environment["PATH"]?.split(separator: ":").filter { $0 == "/fixture/bin" }.count, 1)
            XCTAssertFalse(environment["PATH"]?.contains("relative") == true)
        }
        XCTAssertEqual(probe["LC_ALL"], "C")
        XCTAssertEqual(worker["LC_ALL"], "fr_FR.UTF-8")
        XCTAssertNil(invocation.workerEnvironment(from: [:])["LC_ALL"])
        XCTAssertNil(invocation.workerEnvironment(from: ["LC_ALL": "invalid\0locale"])["LC_ALL"])
    }

    func testMissingAndMetadataModeDoNotLaunchCommands() async throws {
        let missing = try await service().check()
        XCTAssertEqual(missing.state, .missing)
        try fakeCLI(status: emit(connected))
        let fixture = StandMixerClaudeConnectionService(service: integration(metadata: true))
        let report = try await fixture.connect()
        XCTAssertEqual(report.state, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testResolveNeverStartsLoginAndGivesActionableFailure() async throws {
        try fakeCLI(status: emit(#"{"loggedIn":false}"#, exit: 1))
        do { _ = try await service().resolveInvocation(); XCTFail("Expected sign-in error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Connect Claude for Codex")) }
        XCTAssertFalse(try recordedCalls().contains { $0.contains("|auth login|") })
    }

    func testWorkerDirectoryProviderOverrideRejectsOtherwiseConnectedProfile() async throws {
        let project = root.appendingPathComponent("worker project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let providerMarker = project.appendingPathComponent("fixture-project-provider")
        try Data().write(to: providerMarker)
        let status = "if [ -f ./fixture-project-provider ]; then\n"
            + emit(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"bedrock","accessToken":"private-project-secret"}"#)
            + "fi\n" + emit(connected)
        let preferred = try fakeCLI(status: status)
        // A second healthy binary must not be tried after the exact worker directory rejects
        // the chosen connection, because that would mask project auth/provider settings.
        try fakeCLI(".local/share/claude/versions/2.1.319", version: "2.1.319", status: emit(connected))
        let connection = service(active: [preferred])
        let homeStatus = try await connection.check()
        XCTAssertEqual(homeStatus.state, .connected)
        try FileManager.default.removeItem(at: calls)
        do { _ = try await connection.resolveInvocation(workingDirectory: project); XCTFail("Expected project provider rejection") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("this project"))
            XCTAssertTrue(error.localizedDescription.contains("API or provider authentication"))
            XCTAssertTrue(error.localizedDescription.contains("No worker was started"))
            XCTAssertFalse(error.localizedDescription.contains("private-project-secret"))
        }
        let calls = try recordedCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.hasPrefix(".local/bin/claude|") })
        XCTAssertFalse(calls.contains { $0.contains("|auth login|") })
    }

    func testWorkerDirectoryTimeoutReportsVerificationTimeout() async throws {
        let project = root.appendingPathComponent("slow worker project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("fixture-project-slow"))
        try fakeCLI(status: "if [ -f ./fixture-project-slow ]; then exec /bin/sleep 8; fi\n" + emit(connected))
        let connection = service(check: 5, probe: 2)
        do { _ = try await connection.resolveInvocation(workingDirectory: project); XCTFail("Expected project verification timeout") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("verification timed out in this project"))
            XCTAssertTrue(error.localizedDescription.contains("Retry the worker launch"))
            XCTAssertTrue(error.localizedDescription.contains("No worker was started"))
        }
        let calls = try recordedCalls()
        XCTAssertEqual(calls.filter { $0.contains("|auth status --json|") }.count, 2)
        XCTAssertFalse(calls.contains { $0.contains("|auth login|") })
    }

    func testWorkerDirectoryUsesExactDirectoryAndSavedProfileWhenConnected() async throws {
        let project = root.appendingPathComponent("connected worker project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let observedDirectories = root.appendingPathComponent("status-directories")
        let status = "/bin/pwd -P >> \(quote(observedDirectories.path))\n" + emit(connected)
        let cli = try fakeCLI(status: status)
        let config = root.appendingPathComponent("chosen profile").path
        let connection = service(environment: ["CLAUDE_CONFIG_DIR": config])
        let invocation = try await connection.resolveInvocation(workingDirectory: project)
        XCTAssertEqual(invocation.executable, cli)
        XCTAssertEqual(invocation.home, boundHome)
        XCTAssertEqual(invocation.configDirectory, config)
        let observed = try String(contentsOf: observedDirectories, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(observed, [home.path, project.path])
        XCTAssertTrue(try recordedCalls().allSatisfy { $0.hasSuffix("|\(boundHome.path)|set|\(config)") })
    }

    func testUnreadableSavedProfileNeverSilentlySwitchesToCurrentProfile() async throws {
        try fakeCLI(status: emit(connected))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let preference = support.appendingPathComponent("claude-connection.json")
        try "private-invalid-preference".write(to: preference, atomically: true, encoding: .utf8)
        let connection = service(environment: ["CLAUDE_CONFIG_DIR": "/different-profile"])
        do { _ = try await connection.check(); XCTFail("Expected invalid saved connection") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("profile was not changed"))
            XCTAssertFalse(error.localizedDescription.contains("private-invalid-preference"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
    }

    func testCancellationDuringVersionProbeReapsOwnedGroup() async throws {
        let heartbeat = root.appendingPathComponent("version-heartbeat")
        let cli = try fakeCLI(status: emit(connected))
        try ("#!/bin/sh\n" + heartbeatChild(heartbeat) + "wait\n").write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let connection = service()
        let operation = Task { try await connection.check() }
        try await waitForFile(heartbeat)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await assertHeartbeatStopped(heartbeat)
    }

    func testMultipleCandidatesShareOneDeadline() async throws {
        try fakeCLI(status: "/bin/sleep 5\n")
        try fakeCLI(".local/share/claude/versions/2.1.400", version: "2.1.400", status: "/bin/sleep 5\n")
        try fakeCLI(".local/share/claude/versions/2.1.401", version: "2.1.401", status: "/bin/sleep 5\n")
        let started = ProcessInfo.processInfo.systemUptime
        let report = try await service(check: 0.25, probe: 0.1).check()
        XCTAssertEqual(report.state, .unavailable)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }

    func testStatusTimeoutIsUnknownAndReapsTermIgnoringDescendants() async throws {
        let heartbeat = root.appendingPathComponent("timeout-heartbeat")
        try fakeCLI(status: heartbeatChild(heartbeat) + "wait\n")
        let connection = service(check: 5, probe: 2)
        let started = ProcessInfo.processInfo.systemUptime
        let operation = Task { try await connection.connect() }
        defer { operation.cancel() }
        try await waitForFile(heartbeat, attempts: 350)
        let report = try await operation.value
        XCTAssertEqual(report.state, .unavailable)
        XCTAssertTrue(report.detail.contains("timeout"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
        XCTAssertFalse(try recordedCalls().contains { $0.contains("|auth login|") })
        try await assertHeartbeatStopped(heartbeat)
    }

    func testCancellationReapsOwnedLoginGroupAfterLeaderExit() async throws {
        let heartbeat = root.appendingPathComponent("login-heartbeat")
        try fakeCLI(status: emit(#"{"loggedIn":false}"#, exit: 1), login: heartbeatChild(heartbeat) + "exit 0\n")
        let connection = service()
        let operation = Task { try await connection.connect() }
        try await waitForFile(heartbeat)
        try await Task.sleep(nanoseconds: 40_000_000)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await assertHeartbeatStopped(heartbeat)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("claude-connection.json").path))
    }

    func testCancellationReapsOwnedStatusGroup() async throws {
        let heartbeat = root.appendingPathComponent("status-heartbeat")
        try fakeCLI(status: heartbeatChild(heartbeat) + "wait\n")
        let connection = service()
        let operation = Task { try await connection.check() }
        try await waitForFile(heartbeat)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await assertHeartbeatStopped(heartbeat)
    }

    func testCancellationFinishesWhileDetachedChildHoldsPipesOpen() async throws {
        try fakeCLI(status: detachedPipeHolder())
        let completed = XCTestExpectation(description: "Cancelled status check finished")
        let connection = service(probe: 2)
        let operation = Task {
            defer { completed.fulfill() }
            return try await connection.check()
        }
        defer {
            operation.cancel()
            stopDetachedPipeHolder()
        }
        let pid = try await waitForDetachedPipeHolder()
        operation.cancel()

        guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
            XCTFail("Cancellation blocked on pipes held by the detached child")
            return
        }
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(getpgid(pid), pid, "The pipe holder must still be alive until fixture cleanup")
    }

    func testLoginTimeoutFinishesWhileDetachedChildHoldsPipesOpen() async throws {
        try fakeCLI(status: emit(#"{"loggedIn":false}"#, exit: 1), login: detachedPipeHolder())
        let completed = XCTestExpectation(description: "Timed-out login finished")
        let connection = service(login: 0.5)
        let operation = Task {
            defer { completed.fulfill() }
            return try await connection.connect()
        }
        defer {
            operation.cancel()
            stopDetachedPipeHolder()
        }
        let pid = try await waitForDetachedPipeHolder()

        guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
            XCTFail("Login timeout blocked on pipes held by the detached child")
            return
        }
        let report = try await operation.value
        XCTAssertEqual(report.state, .unavailable)
        XCTAssertTrue(report.detail.contains("time limit"))
        XCTAssertEqual(getpgid(pid), pid, "The pipe holder must still be alive until fixture cleanup")
    }

    func testLoginTimeoutAndNormalExitCleanRemainingDescendants() async throws {
        let heartbeat = root.appendingPathComponent("login-timeout-heartbeat")
        try fakeCLI(status: emit(#"{"loggedIn":false}"#, exit: 1), login: heartbeatChild(heartbeat) + "wait\n")
        let report = try await service(login: 0.15).connect()
        XCTAssertEqual(report.state, .unavailable)
        XCTAssertTrue(report.detail.contains("time limit"))
        try await assertHeartbeatStopped(heartbeat)

        let completedHeartbeat = root.appendingPathComponent("completed-heartbeat")
        try fakeCLI(status: heartbeatChild(completedHeartbeat) + emit(connected))
        let connected = try await service(probe: 2).check()
        XCTAssertEqual(connected.state, .connected)
        try await assertHeartbeatStopped(completedHeartbeat)
    }
}
