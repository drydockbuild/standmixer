import AgentMixCore
import Darwin
import Foundation
import XCTest
@testable import AgentMixHelper

final class MCPStdioTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("standmixer-stdio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testInteractivePipeRespondsWithoutPaddingOrClosingStdin() throws {
        let session = try Session(root: root)
        defer { session.stop() }
        let requests: [(String, [String: Any])] = [
            ("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:]]),
            ("tools/list", [:]),
            ("resources/read", ["uri": AgentMixUIAssets.resourceURI]),
            ("tools/call", ["name": "open_standmixer", "arguments": [:]]),
            ("tools/call", ["name": "standmixer_action", "arguments": ["action": "state"]])]
        var replies: [[String: Any]] = []
        for (index, request) in requests.enumerated() {
            let bytes = try message(index + 1, request.0, params: request.1)
            XCTAssertLessThan(bytes.count, 1024)
            try session.send(bytes + Data([10]))
            let response = try session.receive()
            XCTAssertEqual(response["id"] as? Int, index + 1)
            XCTAssertNil(response["error"])
            replies.append(try XCTUnwrap(response["result"] as? [String: Any]))
        }
        XCTAssertEqual(replies[0]["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual((replies[1]["tools"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((replies[2]["contents"] as? [[String: Any]])?.first?["mimeType"] as? String, AgentMixUIAssets.mimeType)
        XCTAssertEqual(((replies[3]["structuredContent"] as? [String: Any])?["result"] as? [String: Any])?["message"] as? String, "StandMixer panel ready.")
        XCTAssertNotNil((replies[4]["structuredContent"] as? [String: Any])?["state"])
        XCTAssertTrue(session.process.isRunning)
        XCTAssertGreaterThanOrEqual(fcntl(session.input.fileHandleForWriting.fileDescriptor, F_GETFD), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.home.appendingPathComponent("Library/Application Support/AgentMix").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.home.appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.home.appendingPathComponent(".claude").path))
    }

    func testExactFrameLimitOversizeRecoveryAndCancellationNotification() throws {
        let session = try Session(root: root)
        defer { session.stop() }
        var exact = try message(10, "ping")
        exact.append(Data(repeating: 32, count: AgentMixModInterface.maximumRequestBytes - exact.count))
        try session.send(exact + Data([10]))
        XCTAssertEqual(try session.receive()["id"] as? Int, 10)
        let cancelled = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 999]])
        try session.send(exact + Data([32, 10]) + cancelled + Data([10]) + message(11, "ping") + Data([10]))
        let rejected = try session.receive()
        XCTAssertTrue(rejected["id"] is NSNull)
        XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(try session.receive()["id"] as? Int, 11)
    }

    func testNewlineBatchAndFinalEOFRequestDrainBeforeExit() throws {
        let session = try Session(root: root)
        defer { session.stop() }
        try session.send(message(21, "ping") + Data([10]) + message(22, "ping") + Data([10]) + message(23, "ping"))
        try session.input.fileHandleForWriting.close()
        var ids: Set<Int> = []
        for _ in 0..<3 { ids.insert(try XCTUnwrap(session.receive()["id"] as? Int)) }
        XCTAssertEqual(ids, [21, 22, 23])
        session.process.waitUntilExit()
        XCTAssertEqual(session.process.terminationStatus, 0)
    }

    private func message(_ id: Int, _ method: String, params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private final class Session {
        enum Failure: Error { case timeout, closed, oversized }
        let process = Process()
        let input = Pipe()
        private let output = Pipe()
        let home: URL
        private var pending = Data()

        init(root: URL) throws {
            home = root.appendingPathComponent("home")
            let ui = root.appendingPathComponent("ui")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
            try "<!doctype html><html><body>StandMixer fixture</body></html>".write(to: ui.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            process.executableURL = Bundle(for: MCPStdioTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AgentMixHelper")
            process.arguments = ["--test-home", home.path, "--ui-root", ui.path, "--mcp"]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.currentDirectoryURL = root
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
        }

        func send(_ bytes: Data) throws { try input.fileHandleForWriting.write(contentsOf: bytes) }

        func receive() throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(5)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                if let end = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: end)
                    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
                    pending.removeSubrange(...end)
                    return value
                }
                guard pending.count <= 4 * 1024 * 1024 else { throw Failure.oversized }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw Failure.timeout }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, Int32(remaining * 1000))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { throw Failure.timeout }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.closed }
                pending.append(contentsOf: buffer.prefix(count))
            }
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
    }
}
