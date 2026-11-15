import Foundation
import StandMixerCore
import XCTest
@testable import StandMixerHelper

final class ClaudeConnectionMCPTests: XCTestCase {
    private actor Connector {
        private(set) var finishedCleanup = false

        func connect(started: XCTestExpectation) async throws -> StandMixerClaudeConnectionReport {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(4))
                return .init(state: .unavailable, detail: "Fixture timed out waiting for cancellation.")
            } catch is CancellationError {
                // This models process cleanup that must finish despite cancellation.
                await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                finishedCleanup = true
                throw CancellationError()
            }
        }
    }

    private struct Session {
        let input: FileHandle
        let transport: StandMixerMCPStdio
        let run: Task<Void, Error>
        let output: Task<Data, Error>

        func send(_ action: StandMixerModRequest.Action, newline: Bool = true) throws {
            var request = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "standmixer_action", "arguments": ["action": action.rawValue]]
            ])
            if newline { request.append(10) }
            try input.write(contentsOf: request)
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("standmixer-claude-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "<!doctype html><html><body>StandMixer fixture</body></html>"
            .write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testInputEOFWaitsForInFlightConnectorCleanup() async throws {
        let connector = Connector()
        let started = expectation(description: "Connector started")
        let session = try startSession(connector: { try await connector.connect(started: started) })
        defer { try? session.input.close() }
        try session.send(.connectClaude)
        await fulfillment(of: [started], timeout: 3)

        try session.input.close()
        try await session.run.value
        let finished = await connector.finishedCleanup
        XCTAssertTrue(finished)
        let response = try await structuredResponse(session)
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "cancelled")
    }

    func testExplicitShutdownWaitsForConnectorCleanupWhileInputIsOpen() async throws {
        let connector = Connector()
        let started = expectation(description: "Connector started")
        let session = try startSession(connector: { try await connector.connect(started: started) })
        defer { try? session.input.close() }
        try session.send(.connectClaude)
        await fulfillment(of: [started], timeout: 3)

        await session.transport.cancelAllAndWait()
        let finished = await connector.finishedCleanup
        XCTAssertTrue(finished)
        try session.input.close()
        try await session.run.value
        let response = try await structuredResponse(session)
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "cancelled")
    }

    func testInputEOFDrainsAnOrdinaryStateRequest() async throws {
        let session = try startSession()
        defer { try? session.input.close() }
        try session.send(.state, newline: false)
        try session.input.close()
        try await session.run.value
        let response = try await structuredResponse(session)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertNotNil(response["state"] as? [String: Any])
    }

    private func startSession(connector: (@Sendable () async throws -> StandMixerClaudeConnectionReport)? = nil) throws -> Session {
        let service = IntegrationService(home: root.appendingPathComponent("home"),
            applicationSupport: root.appendingPathComponent("support"), environment: [:], metadataOnlyDiscovery: true)
        let interface = StandMixerModInterface(service: service, connections: [], allowsClaudeConnection: connector != nil,
                                               claudeConnector: connector)
        let server = StandMixerMCPServer(engine: .init(interface: interface), assets: try .init(root: root))
        let input = Pipe()
        let output = Pipe()
        let outputReader = output.fileHandleForReading
        let outputWriter = output.fileHandleForWriting
        let transport = StandMixerMCPStdio(server: server, input: input.fileHandleForReading, output: outputWriter)
        let response = Task.detached { try outputReader.readToEnd() ?? Data() }
        let run = Task.detached {
            defer { try? outputWriter.close() }
            try await transport.run()
        }
        return .init(input: input.fileHandleForWriting, transport: transport, run: run, output: response)
    }

    private func structuredResponse(_ session: Session) async throws -> [String: Any] {
        let data = try await session.output.value
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["id"] as? Int, 1)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }
}
