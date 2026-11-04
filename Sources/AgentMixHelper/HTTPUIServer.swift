import AgentMixCore
import Foundation
import Network

struct AgentMixHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum ParseResult { case incomplete, invalid, complete(AgentMixHTTPRequest) }
    static let maximumHeaderBytes = 16 * 1024

    static func parse(_ data: Data) -> ParseResult {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderBytes ? .invalid : .incomplete
        }
        guard boundary.lowerBound <= maximumHeaderBytes,
              let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").components(separatedBy: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(first[0]),
              first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { return .invalid }
            let name = String(line[..<separator]).lowercased()
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[name] == nil else { return .invalid }
            headers[name] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .invalid }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(raw),
                  count <= AgentMixModInterface.maximumRequestBytes else { return .invalid }
            length = count
        } else {
            guard first[0] == "GET" else { return .invalid }
            length = 0
        }
        guard first[0] != "GET" || length == 0 else { return .invalid }
        let bodyStart = boundary.upperBound
        guard data.count >= bodyStart + length else { return .incomplete }
        guard data.count == bodyStart + length else { return .invalid }
        return .complete(.init(method: first[0], path: first[1], headers: headers, body: Data(data[bodyStart...])))
    }
}

struct AgentMixHTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
    var headers: [String: String] = [:]
    var wire: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 429: "Too Many Requests"][status] ?? "Error"
        var text = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\n"
        for key in headers.keys.sorted() { text += "\(key): \(headers[key]!)\r\n" }
        return Data((text + "\r\n").utf8) + body
    }
    static func failure(_ status: Int, _ code: String, _ message: String) -> AgentMixHTTPResponse {
        .init(status: status, contentType: "application/json; charset=utf-8", body: AgentMixUIEngine.failure(code, message))
    }
}

final class AgentMixHTTPRouter: @unchecked Sendable {
    let engine: AgentMixUIEngine
    let assets: AgentMixUIAssets
    let token: String
    let port: UInt16
    var origin: String { "http://127.0.0.1:\(port)" }
    init(engine: AgentMixUIEngine, assets: AgentMixUIAssets, token: String, port: UInt16) {
        self.engine = engine; self.assets = assets; self.token = token; self.port = port
    }

    func respond(_ request: AgentMixHTTPRequest) async -> AgentMixHTTPResponse {
        guard request.headers["host"] == "127.0.0.1:\(port)",
              request.headers["origin"] == nil || request.headers["origin"] == origin else {
            return .failure(403, "forbidden", "This panel accepts requests only from its own local session.")
        }
        if request.method == "GET" && ["/", "/index.html"].contains(request.path) {
            return .init(status: 200, contentType: "text/html; charset=utf-8", body: assets.html,
                         headers: ["Content-Security-Policy": assets.contentSecurityPolicy,
                                   "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()"])
        }
        guard request.path == "/api" else { return .failure(404, "notFound", "Unknown panel endpoint.") }
        guard request.method == "POST" else { return .failure(405, "invalidRequest", "Use the panel's JSON action API.") }
        // Browser POSTs must present both their exact Origin and the random
        // fragment capability. No CORS/OPTIONS support and no cookie authority.
        guard request.headers["origin"] == origin else { return .failure(403, "forbidden", "A matching local panel origin is required.") }
        guard constantTimeEqual(request.headers["authorization"] ?? "", "Bearer " + token) else {
            return .failure(401, "unauthorized", "This panel session is unavailable. Reopen AgentMix in Codex.")
        }
        guard request.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            return .failure(400, "invalidRequest", "Use application/json for panel actions.")
        }
        return .init(status: 200, contentType: "application/json; charset=utf-8", body: await engine.action(request.body))
    }

    private func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let a = Array(first.utf8), b = Array(second.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// A dependency-free loopback server for Codex's embedded browser. No system
/// browser is opened. Only the initial JSON stdout record contains its token.
final class AgentMixHTTPUIServer: @unchecked Sendable {
    static let idleLifetime: TimeInterval = 30 * 60
    private let listener: NWListener
    private let queue = DispatchQueue(label: "AgentMix.embedded-ui")
    private let engine: AgentMixUIEngine
    private let assets: AgentMixUIAssets
    private let token: String
    private var router: AgentMixHTTPRouter?
    private var connections: [UUID: NWConnection] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var timer: DispatchSourceTimer?
    private var lastActivity = Date()
    private var shutdown: CheckedContinuation<Void, Never>?
    private var stopped = false
    private var startResolved = false

    init(engine: AgentMixUIEngine, assets: AgentMixUIAssets) throws {
        self.engine = engine; self.assets = assets; token = try AgentMixUIAssets.makeToken()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    guard !startResolved, let port = listener.port?.rawValue else { return }
                    startResolved = true
                    router = .init(engine: engine, assets: assets, token: token, port: port)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + 30, repeating: 30)
                    timer.setEventHandler { [weak self] in
                        guard let self, Date().timeIntervalSince(lastActivity) >= Self.idleLifetime else { return }
                        stopOnQueue()
                    }
                    self.timer = timer; timer.resume()
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port)/#token=\(token)")!)
                case .waiting(let error), .failed(let error):
                    if !startResolved { startResolved = true; continuation.resume(throwing: error) }
                    stopOnQueue()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                guard !startResolved else { return }
                startResolved = true
                continuation.resume(throwing: NSError(domain: "AgentMixUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "The local panel listener did not become ready."]))
                stopOnQueue()
            }
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if stopped { continuation.resume() } else { shutdown = continuation }
            }
        }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        guard !stopped else { return }; stopped = true
        listener.cancel(); timer?.cancel(); timer = nil
        for operation in operations.values { operation.cancel() }; operations.removeAll()
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        shutdown?.resume(); shutdown = nil
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16, !stopped else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        // Incomplete requests cannot retain an unlimited number of sockets.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, operations[id] == nil else { return }
            close(id)
        }
        receive(connection, id: id, data: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] bytes, _, complete, error in
            guard let self, connections[id] != nil else { return }
            var buffer = data
            if let bytes { buffer.append(bytes) }
            guard buffer.count <= AgentMixHTTPRequest.maximumHeaderBytes + AgentMixModInterface.maximumRequestBytes + 4 else {
                send(.failure(413, "invalidRequest", "Panel request is too large."), to: connection, id: id); return
            }
            switch AgentMixHTTPRequest.parse(buffer) {
            case .invalid: send(.failure(400, "invalidRequest", "Invalid panel request."), to: connection, id: id)
            case .incomplete:
                if complete || error != nil { close(id) }
                else { receive(connection, id: id, data: buffer) }
            case .complete(let request):
                guard let router else { close(id); return }
                operations[id] = Task { [weak self] in
                    let response = await router.respond(request)
                    self?.queue.async { [weak self] in
                        guard let self, connections[id] != nil else { return }
                        // Only authenticated actions extend this session.
                        if response.status == 200 && request.method == "POST" { lastActivity = Date() }
                        send(response, to: connection, id: id)
                    }
                }
                // Keep a receive pending while explicit inspection runs. A
                // closed/aborted browser request cancels its owned observer.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] bytes, _, complete, error in
                    guard let self, connections[id] != nil else { return }
                    if complete || error != nil || bytes?.isEmpty == false { close(id) }
                }
            }
        }
    }
    private func send(_ response: AgentMixHTTPResponse, to connection: NWConnection, id: UUID) {
        connection.send(content: response.wire, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }
    private func close(_ id: UUID) {
        operations.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
