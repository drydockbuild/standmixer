import Foundation
import XCTest
@testable import StandMixerCore

final class ClaudeConnectionProtocolTests: XCTestCase {
    private enum Call: Sendable { case check, connect, logout, cancelled }

    private actor Calls {
        private(set) var values: [Call] = []
        func record(_ call: Call) { values.append(call) }
    }

    private struct Response: Decodable {
        let ok: Bool
        let state: StandMixerModState?
        let preview: StandMixerModPreview?
        let claudeConnection: StandMixerClaudeConnectionReport?
        let error: StandMixerModError?
    }

    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var support: URL { root.appendingPathComponent("support") }
    private let checkedAt = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("standmixer-connection-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testDisabledTransportRejectsConnectionActionsBeforeCallingAnyHandler() async throws {
        let calls = Calls()
        let api = interface(calls: calls, allowsClaudeConnection: false)
        let state = try await send(.init(action: .state), to: api)
        XCTAssertFalse(try XCTUnwrap(state.state).canConnectClaude)
        for action in [StandMixerModRequest.Action.checkClaudeConnection, .connectClaude, .logoutClaude] {
            let response = try await send(.init(action: action), to: api, exitCode: 1)
            XCTAssertEqual(response.error?.code, "connectionUnavailable", action.rawValue)
            XCTAssertNil(response.claudeConnection)
        }
        let recorded = await calls.values
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testMetadataFixtureDoesNotAdvertiseConnectionCapability() async throws {
        let calls = Calls()
        let api = interface(calls: calls, metadataOnlyDiscovery: true)
        let response = try await send(.init(action: .state), to: api)
        XCTAssertFalse(try XCTUnwrap(response.state).canConnectClaude)
        XCTAssertNil(response.claudeConnection)
        for action in [StandMixerModRequest.Action.checkClaudeConnection, .connectClaude, .logoutClaude] {
            let rejected = try await send(.init(action: action), to: api, exitCode: 1)
            XCTAssertEqual(rejected.error?.code, "connectionUnavailable")
            XCTAssertNil(rejected.claudeConnection)
        }
        let recorded = await calls.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testSettingsLifecycleDoesNotCallConnectionHandlersWhenEnabled() async throws {
        let calls = Calls()
        let api = interface(calls: calls)
        let state = try await send(.init(action: .state), to: api)
        XCTAssertTrue(try XCTUnwrap(state.state).canConnectClaude)
        XCTAssertNil(state.claudeConnection)

        let platforms: Set<AgentPlatform> = [.codex, .claude]
        let configuration = StandMixerConfiguration.preset(.fast, availablePlatforms: platforms)
        for request in [StandMixerModRequest(action: .saveDraft, configuration: configuration, platforms: platforms),
                        .init(action: .savePreset, configuration: configuration, platforms: platforms, name: "Fixture")] {
            let response = try await send(request, to: api)
            XCTAssertTrue(try XCTUnwrap(response.state).canConnectClaude)
            XCTAssertNil(response.claudeConnection, request.action.rawValue)
        }
        let review = try await send(.init(action: .preview, configuration: configuration, platforms: platforms), to: api)
        XCTAssertNil(review.claudeConnection)
        let preview = try XCTUnwrap(review.preview)
        let applied = try await send(.init(action: .apply, previewID: preview.id), to: api)
        XCTAssertNil(applied.claudeConnection)
        let recorded = await calls.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testExplicitActionsCallOnlyTheirOwnHandlerAndReturnItsReport() async throws {
        let calls = Calls()
        let api = interface(calls: calls)
        let checked = try await send(.init(action: .checkClaudeConnection), to: api)
        let checkReport = try XCTUnwrap(checked.claudeConnection)
        XCTAssertEqual(checkReport.state, .signInRequired)
        XCTAssertEqual(checkReport.detail, "Fixture requires sign-in.")
        XCTAssertEqual(checkReport.checkedAt, checkedAt)
        XCTAssertNil(checked.state)
        let afterCheck = await calls.values
        XCTAssertEqual(afterCheck, [.check])

        let connected = try await send(.init(action: .connectClaude), to: api)
        let connectReport = try XCTUnwrap(connected.claudeConnection)
        XCTAssertEqual(connectReport.state, .connected)
        XCTAssertEqual(connectReport.detail, "Fixture connected.")
        XCTAssertEqual(connectReport.cliPath, "/fixture/claude")
        XCTAssertEqual(connectReport.checkedAt, checkedAt)
        XCTAssertNil(connected.state)
        let afterConnect = await calls.values
        XCTAssertEqual(afterConnect, [.check, .connect])

        let loggedOut = try await send(.init(action: .logoutClaude), to: api)
        let logoutReport = try XCTUnwrap(loggedOut.claudeConnection)
        XCTAssertEqual(logoutReport.state, .signInRequired)
        XCTAssertEqual(logoutReport.detail, "Fixture signed out.")
        XCTAssertEqual(logoutReport.cliPath, "/fixture/claude")
        XCTAssertEqual(logoutReport.checkedAt, checkedAt)
        XCTAssertNil(loggedOut.state)
        let afterLogout = await calls.values
        XCTAssertEqual(afterLogout, [.check, .connect, .logout])
    }

    func testConnectionActionsRejectExtraRequestFieldsBeforeInvokingHandlers() async throws {
        let calls = Calls()
        let api = interface(calls: calls)
        let fields: [String: Any] = [
            "path": "/fixture/claude", "command": "auth login", "arguments": ["--console"],
            "configuration": NSNull(), "platforms": ["claude"], "unknown": NSNull()
        ]
        for action in [StandMixerModRequest.Action.checkClaudeConnection, .connectClaude, .logoutClaude] {
            for (key, value) in fields {
                let request = try JSONSerialization.data(withJSONObject: ["action": action.rawValue, key: value])
                let execution = await api.runJSON(request)
                let response = try decode(execution, exitCode: 1)
                XCTAssertEqual(response.error?.code, "invalidRequest", "\(action.rawValue) with \(key)")
                XCTAssertNil(response.claudeConnection)
            }
        }
        let recorded = await calls.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testCancellingConnectCancelsAnInFlightConnector() async throws {
        let calls = Calls()
        let started = expectation(description: "Connector started")
        let api = interface(calls: calls, connector: {
            await calls.record(.connect)
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(5))
                return .init(state: .unavailable, detail: "Connector reached its deadline.")
            } catch is CancellationError {
                await calls.record(.cancelled)
                throw CancellationError()
            }
        })
        let request = try JSONEncoder().encode(StandMixerModRequest(action: .connectClaude))
        let operation = Task { await api.runJSON(request) }
        await fulfillment(of: [started], timeout: 3)
        operation.cancel()

        let response = try decode(await operation.value, exitCode: 1)
        XCTAssertEqual(response.error?.code, "cancelled")
        XCTAssertNil(response.claudeConnection)
        let recorded = await calls.values
        XCTAssertEqual(recorded, [.connect, .cancelled])
    }

    func testCancellingLogoutCancelsAnInFlightLogoutHandler() async throws {
        let calls = Calls()
        let started = expectation(description: "Logout started")
        let api = interface(calls: calls, logout: {
            await calls.record(.logout)
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(5))
                return .init(state: .unavailable, detail: "Logout reached its deadline.")
            } catch is CancellationError {
                await calls.record(.cancelled)
                throw CancellationError()
            }
        })
        let request = try JSONEncoder().encode(StandMixerModRequest(action: .logoutClaude))
        let operation = Task { await api.runJSON(request) }
        await fulfillment(of: [started], timeout: 3)
        operation.cancel()

        let response = try decode(await operation.value, exitCode: 1)
        XCTAssertEqual(response.error?.code, "cancelled")
        XCTAssertNil(response.claudeConnection)
        let recorded = await calls.values
        XCTAssertEqual(recorded, [.logout, .cancelled])
    }

    func testLegacyInspectionAndAccountActionsRemainRetiredWhenConnectionIsEnabled() async throws {
        let calls = Calls()
        let api = interface(calls: calls)
        for action in [StandMixerModRequest.Action.inspect, .checkAccounts] {
            let response = try await send(.init(action: action), to: api, exitCode: 1)
            XCTAssertEqual(response.error?.code, "retiredAction", action.rawValue)
            XCTAssertNil(response.claudeConnection)
        }
        let recorded = await calls.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testWorkerArgumentsRequirePrintModeAfterSeparatorAndPreserveLiteralArguments() throws {
        let prompt = "Review $HOME, $(printf fixture), and \"quoted\" text; keep * literal.\nSecond line."
        for mode in ["-p", "--print"] {
            let args = [mode, "--model", "claude-opus-5-5", "--effort", "max", "--", prompt]
            XCTAssertEqual(try StandMixerClaudeWorker.workerArguments(["--"] + args), args)
            XCTAssertThrowsError(try StandMixerClaudeWorker.workerArguments(args))
        }
        for args in [[], ["--"], ["--", "auth", "login"], ["--", "--model", "sonnet", "-p", prompt],
                     ["--", "-p", "embedded\0nul"]] {
            XCTAssertThrowsError(try StandMixerClaudeWorker.workerArguments(args), "\(args.debugDescription)")
        }
    }

    func testWorkerArgumentsRejectAuthenticationProviderAndSettingsOverrides() {
        for flag in ["--settings", "--setting-sources", "--api-key", "--auth-token", "--base-url", "--console"] {
            for option in [[flag, "fixture"], ["\(flag)=fixture"]] {
                XCTAssertThrowsError(try StandMixerClaudeWorker.workerArguments(["--", "-p"] + option + ["Prompt"]),
                                     "\(option)")
            }
        }
    }

    private func interface(calls: Calls, allowsClaudeConnection: Bool = true, metadataOnlyDiscovery: Bool = false,
                           connector: (@Sendable () async throws -> StandMixerClaudeConnectionReport)? = nil,
                           logout: (@Sendable () async throws -> StandMixerClaudeConnectionReport)? = nil) -> StandMixerModInterface {
        let discovery = CLIDiscovery(home: home, environment: [:], applicationDirectories: [], commonDirectories: [],
                                     activeExecutables: { [] })
        let service = IntegrationService(discovery: discovery, applicationSupport: support, metadataOnlyDiscovery: metadataOnlyDiscovery)
        let connections = AgentPlatform.allCases.map {
            ConnectionStatus(platform: $0, path: "/fixture/\($0.rawValue)", version: "1.0.0", detail: "Fixture only", isInstalled: true)
        }
        return StandMixerModInterface(service: service, connections: connections, allowsClaudeConnection: allowsClaudeConnection,
            claudeConnectionCheck: { [checkedAt] in
                await calls.record(.check)
                return .init(state: .signInRequired, detail: "Fixture requires sign-in.", checkedAt: checkedAt)
            },
            claudeConnector: connector ?? { [checkedAt] in
                await calls.record(.connect)
                return .init(state: .connected, detail: "Fixture connected.", cliPath: "/fixture/claude",
                             checkedAt: checkedAt)
            },
            claudeLogout: logout ?? { [checkedAt] in
                await calls.record(.logout)
                return .init(state: .signInRequired, detail: "Fixture signed out.", cliPath: "/fixture/claude",
                             checkedAt: checkedAt)
            })
    }

    private func send(_ request: StandMixerModRequest, to api: StandMixerModInterface, exitCode: Int32 = 0,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> Response {
        let execution = await api.runJSON(try JSONEncoder().encode(request))
        return try decode(execution, exitCode: exitCode, file: file, line: line)
    }

    private func decode(_ execution: StandMixerModExecution, exitCode: Int32,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Response {
        XCTAssertEqual(execution.exitCode, exitCode, String(decoding: execution.output, as: UTF8.self), file: file, line: line)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: execution.output)
        XCTAssertEqual(response.ok, exitCode == 0, file: file, line: line)
        return response
    }
}
