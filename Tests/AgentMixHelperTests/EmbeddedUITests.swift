@testable import AgentMixCore
import Foundation
import XCTest
@testable import AgentMixHelper

final class EmbeddedUITests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var service: IntegrationService!
    private var engine: AgentMixUIEngine!
    private var assets: AgentMixUIAssets!
    private var router: AgentMixHTTPRouter!
    private let token = String(repeating: "a", count: 43)
    private let port: UInt16 = 18321
    private var origin: String { "http://127.0.0.1:\(port)" }
    private var connections: [ConnectionStatus] {
        AgentPlatform.allCases.map { .init(platform: $0, path: "/fixture/\($0.rawValue)", version: nil, detail: "Fixture", isInstalled: true) }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("agentmix-embedded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = root.appendingPathComponent("home")
        service = .init(home: home, applicationSupport: root.appendingPathComponent("support"), environment: [:],
                        executableURL: root.appendingPathComponent("support/bin/AgentMixHelper"), metadataOnlyDiscovery: true)
        let ui = root.appendingPathComponent("ui")
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        try "<!doctype html><html><style>body{color:#fff}</style><script>window.fixture=true;</script></html>".write(to: ui.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        assets = try .init(root: ui)
        engine = .init(interface: .init(service: service, connections: connections,
                                       inspectionReader: { _ in throw AgentImportError.failed("Fixture inspection is disabled.") }))
        router = .init(engine: engine, assets: assets, token: token, port: port)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func request(_ action: AgentMixModRequest, headers extra: [String: String] = [:]) throws -> AgentMixHTTPRequest {
        var headers = ["host": "127.0.0.1:\(port)", "origin": origin, "authorization": "Bearer \(token)", "content-type": "application/json"]
        for (key, value) in extra { headers[key] = value }
        return .init(method: "POST", path: "/api", headers: headers, body: try JSONEncoder().encode(action))
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func errorCode(_ response: AgentMixHTTPResponse) throws -> String? { (try object(response.body)["error"] as? [String: Any])?["code"] as? String }
    private func rpc(_ method: String, params: [String: Any] = [:], id: Int = 1) async throws -> [String: Any] {
        let server = AgentMixMCPServer(engine: engine, assets: assets)
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let response = await server.respond(data)
        return try object(XCTUnwrap(response))
    }

    func testOpenPanelAndStateHaveNoInferenceOrNativeWrites() async throws {
        actor Counter { var count = 0; func started() { count += 1 } }
        let counter = Counter()
        let noInferenceEngine = AgentMixUIEngine(interface: .init(service: service, connections: connections, inspectionReader: { _ in
            await counter.started(); throw AgentImportError.failed("Unexpected observer")
        }))
        let server = AgentMixMCPServer(engine: noInferenceEngine, assets: assets)
        let bytes = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"open_standmixer\",\"arguments\":{}}}".utf8)
        let response = await server.respond(bytes)
        let result = try XCTUnwrap(try object(XCTUnwrap(response))["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["ok"] as? Bool, true)
        XCTAssertNil(structured["state"])
        XCTAssertLessThan(try XCTUnwrap(response).count, 512)
        XCTAssertEqual(((result["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["resourceUri"] as? String, AgentMixUIAssets.resourceURI)
        // The embedded panel loads full state through its app-only tool instead.
        let stateRequest = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"standmixer_action\",\"arguments\":{\"action\":\"state\"}}}".utf8)
        let stateResponse = await server.respond(stateRequest)
        let stateResult = try XCTUnwrap(try object(XCTUnwrap(stateResponse))["result"] as? [String: Any])
        XCTAssertNotNil((stateResult["structuredContent"] as? [String: Any])?["state"])
        let starts = await counter.count
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testMCPInitializationToolsResourceAndNotificationShape() async throws {
        let initialized = try await rpc("initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:]])
        XCTAssertEqual((initialized["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let listed = try await rpc("tools/list")
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["open_standmixer", "standmixer_action"])
        let action = try XCTUnwrap(tools.first { $0["name"] as? String == "standmixer_action" })
        XCTAssertEqual(((action["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["visibility"] as? [String], ["app"])
        XCTAssertEqual((action["inputSchema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
        let resource = try await rpc("resources/read", params: ["uri": AgentMixUIAssets.resourceURI])
        let contents = try XCTUnwrap((resource["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["mimeType"] as? String, "text/html;profile=mcp-app")
        XCTAssertEqual(contents.first?["text"] as? String, String(decoding: assets.html, as: UTF8.self))
        let unknown = try await rpc("resources/read", params: ["uri": "file:///etc/passwd"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
        let server = AgentMixMCPServer(engine: engine, assets: assets)
        let notification = await server.respond(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
        XCTAssertNil(notification)
    }

    func testRemovedMCPAliasesAreRejectedWithoutOpeningOrReadingState() async throws {
        for name in ["open_agentmix", "agentmix_action"] {
            let response = try await rpc("tools/call", params: ["name": name, "arguments": [:]])
            XCTAssertNil(response["result"])
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testHTTPRequiresExactHostOriginAndRandomToken() async throws {
        for headers in [["host": "evil.test:\(port)"], ["host": "localhost:\(port)"], ["origin": "https://evil.test"], ["origin": "null"]] {
            let response = await router.respond(try request(.init(action: .state), headers: headers))
            XCTAssertEqual(response.status, 403)
        }
        for value in ["", "Bearer wrong", "Basic " + token] {
            let response = await router.respond(try request(.init(action: .state), headers: ["authorization": value]))
            XCTAssertEqual(response.status, 401)
        }
        let noOrigin = AgentMixHTTPRequest(method: "POST", path: "/api", headers: ["host": "127.0.0.1:\(port)", "authorization": "Bearer " + token, "content-type": "application/json"], body: Data("{\"action\":\"state\"}".utf8))
        let missing = await router.respond(noOrigin)
        XCTAssertEqual(missing.status, 403)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testHTTPServesOnlyBundledHTMLWithHashedScriptPolicyAndNoCookie() async throws {
        let page = await router.respond(.init(method: "GET", path: "/", headers: ["host": "127.0.0.1:\(port)"], body: Data()))
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.body, assets.html)
        let csp = try XCTUnwrap(page.headers["Content-Security-Policy"])
        XCTAssertTrue(csp.contains("script-src 'sha256-"))
        XCTAssertFalse(csp.contains("script-src 'unsafe-inline'"))
        XCTAssertTrue(csp.contains("connect-src 'self'"))
        XCTAssertNil(page.headers["Set-Cookie"])
        for path in ["/etc/passwd", "/../index.html", "/index.html?path=/etc/passwd", "/api?command=id"] {
            let unknown = await router.respond(.init(method: "GET", path: path, headers: ["host": "127.0.0.1:\(port)"], body: Data()))
            XCTAssertEqual(unknown.status, 404)
        }
    }

    func testActionRejectsUnknownFieldsAndMalformedDTOWithoutEchoingSecrets() async throws {
        for json in ["{\"action\":\"state\",\"path\":\"private-secret-123\"}", "{\"action\":\"shell\",\"command\":\"private-secret-123\"}", "{\"action\":\"apply\"}", "{\"action\":\"state\",\"configuration\":{}}"] {
            let response = await engine.action(Data(json.utf8))
            XCTAssertEqual(try object(response)["ok"] as? Bool, false)
            XCTAssertFalse(String(decoding: response, as: UTF8.self).contains("private-secret-123"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.path))
    }

    func testHTTPStaleReviewedPreviewCannotApplyOrChangeNativeFiles() async throws {
        var pinned = AgentMixConfiguration.defaults
        let codex = pinned.profiles.firstIndex { $0.platform == .codex }!
        let controller = pinned.profiles[codex].routes.firstIndex { $0.category == .coordinator }!
        pinned.profiles[codex].routes[controller].modelID = "gpt-6.1-sol"
        let preview = await router.respond(try request(.init(action: .preview, configuration: pinned, platforms: [.codex, .claude])))
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((try object(preview.body)["preview"] as? [String: Any])?["id"] as? String)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        let native = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = 'external-choice'\n".write(to: native, atomically: true, encoding: .utf8)
        let applied = await router.respond(try request(.init(action: .apply, previewID: id)))
        XCTAssertEqual(try errorCode(applied), "conflict")
        XCTAssertEqual(try String(contentsOf: native, encoding: .utf8), "model = 'external-choice'\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.receiptURL.path))
    }

    func testHTTPDraftAndFixtureInspectionDoNotChangeRouting() async throws {
        let saved = await router.respond(try request(.init(action: .saveDraft, configuration: .defaults, platforms: [.codex, .claude])))
        XCTAssertEqual(try object(saved.body)["ok"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.applicationSupport.appendingPathComponent("configuration.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        let inspected = await router.respond(try request(.init(action: .inspect, platforms: [.codex])))
        XCTAssertEqual(inspected.status, 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.receiptURL.path))
    }

    func testHTTPParserRejectsSmugglingOversizeDuplicateHeadersAndPartialBodies() {
        let valid = "POST /api HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 2\r\n\r\n{}"
        if case .complete(let parsed) = AgentMixHTTPRequest.parse(Data(valid.utf8)) { XCTAssertEqual(parsed.body, Data("{}".utf8)) }
        else { XCTFail("Expected a complete bounded request") }
        if case .incomplete = AgentMixHTTPRequest.parse(Data(valid.dropLast().utf8)) {} else { XCTFail("Partial body must wait") }
        let invalid = [valid + "GET / HTTP/1.1\r\n\r\n", valid.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 2\r\ncontent-length: 2"),
                       valid.replacingOccurrences(of: "Content-Length: 2", with: "Transfer-Encoding: chunked"),
                       valid.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 524289"),
                       "GET / HTTP/1.1\r\n" + String(repeating: "x", count: 16 * 1024 + 1)]
        for value in invalid {
            if case .invalid = AgentMixHTTPRequest.parse(Data(value.utf8)) {} else { XCTFail("Unsafe request was not rejected") }
        }
    }
}
