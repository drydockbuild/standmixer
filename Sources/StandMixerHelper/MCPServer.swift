import StandMixerCore
import CoreFoundation
import Darwin
import Foundation

final class StandMixerMCPServer: @unchecked Sendable {
    static let protocolVersion = "2025-11-25"
    let engine: StandMixerUIEngine
    let assets: StandMixerUIAssets
    init(engine: StandMixerUIEngine, assets: StandMixerUIAssets) { self.engine = engine; self.assets = assets }

    func respond(_ data: Data) async -> Data? {
        guard data.count <= StandMixerModInterface.maximumRequestBytes,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encodeError(id: NSNull(), code: -32700, message: "Invalid JSON-RPC request.")
        }
        let id = request["id"] ?? NSNull()
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              id is NSNull || id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()) else {
            return encodeError(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request.")
        }
        // Notifications never receive a response. Cancellation is handled by the
        // stdio runner for any outstanding settings operation.
        guard request.keys.contains("id") else { return nil }
        let parameters = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": Self.protocolVersion,
                      "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": false, "listChanged": false]],
                      "serverInfo": ["name": "standmixer", "version": StandMixerRelease.version, "icons": Self.icons],
                      "instructions": "Open StandMixer to review routing. Apply requires a stored reviewed preview ID. StandMixer manages configuration without inference or account checks. Optional local Mac app installation runs only from an explicit panel action."]
        case "ping": result = [:]
        case "tools/list": result = ["tools": tools]
        case "resources/list":
            result = ["resources": [["uri": assets.resourceURI, "name": "StandMixer", "description": "StandMixer routing settings inside Codex", "mimeType": StandMixerUIAssets.mimeType]]]
        case "resources/templates/list": result = ["resourceTemplates": []]
        case "resources/read":
            guard parameters["uri"] as? String == assets.resourceURI else {
                return encodeError(id: id, code: -32602, message: "Unknown StandMixer UI resource.")
            }
            result = ["contents": [["uri": assets.resourceURI, "mimeType": StandMixerUIAssets.mimeType,
                                     "text": String(decoding: assets.html, as: UTF8.self),
                                     "_meta": ["ui": ["csp": ["connectDomains": [], "resourceDomains": []], "prefersBorder": true]]]]]
        case "tools/call":
            guard let name = parameters["name"] as? String,
                  parameters["arguments"] == nil || parameters["arguments"] is [String: Any] else {
                return encodeError(id: id, code: -32602, message: "Use a supported StandMixer tool and JSON object arguments.")
            }
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            let response: Data
            if name == "open_standmixer" {
                guard arguments.isEmpty else { return encodeError(id: id, code: -32602, message: "\(name) takes no arguments.") }
                // The panel requests state through its app-only action after
                // connecting. Keep the model-visible opening result small.
                response = Data("{\"ok\":true,\"result\":{\"message\":\"StandMixer panel ready.\"}}".utf8)
            } else if name == "standmixer_action" {
                guard let encoded = try? JSONSerialization.data(withJSONObject: arguments) else {
                    return encodeError(id: id, code: -32602, message: "Use a supported StandMixer JSON action.")
                }
                response = await engine.action(encoded)
            } else { return encodeError(id: id, code: -32602, message: "Unknown StandMixer tool.") }
            let structured = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] ?? [:]
            var toolResult: [String: Any] = ["content": [["type": "text", "text": String(decoding: response, as: UTF8.self)]],
                                            "structuredContent": structured, "isError": structured["ok"] as? Bool != true]
            if name == "open_standmixer" { toolResult["_meta"] = ["ui": ["resourceUri": assets.resourceURI]] }
            result = toolResult
        default: return encodeError(id: id, code: -32601, message: "Method not found.")
        }
        return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])
    }

    private func encodeError(id: Any, code: Int, message: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], options: [.sortedKeys])
    }

    // Sidebar and thread entrypoints use MCP icons, independently of the plugin's marketplace logo.
    static let icons: [[String: Any]] = [("light", "#0E9488"), ("dark", "#6FB3B8")].map { theme, color in
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64"><g transform="translate(0 5)"><g fill="none" stroke="\(color)" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 46V23H10V19C10 13.5 14.5 9 20 9H42C47.5 9 52 13.5 52 19V23H23V46"/><path d="M28 29H51C50.2 37.5 46.4 42 39.5 42S29 37.5 28 29Z"/><path d="M39.5 23V33"/><path d="M10 46H53" stroke="#F59E0B"/></g><circle cx="18" cy="17" r="1.8" fill="\(color)"/></g></svg>
        """
        return ["src": "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString(),
                "mimeType": "image/svg+xml", "sizes": ["any"], "theme": theme]
    }

    var tools: [[String: Any]] {
        let actions = ["state", "saveDraft", "savePreset", "deletePreset", "preview", "apply", "previewUninstall", "uninstall", "previewRestore", "restore", "installMac", "openWeb", "openMac", "checkUpdates", "checkClaudeConnection", "connectClaude", "logoutClaude"]
        return [
            ["name": "open_standmixer", "title": "Open StandMixer", "description": "Open StandMixer routing settings inside Codex. Reads saved configuration without starting inference or changing routing.",
             "icons": Self.icons,
             "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
             "_meta": ["ui": ["resourceUri": assets.resourceURI, "visibility": ["model", "app"]],
                       "openai/ui": ["entrypoints": [["type": "thread"], ["type": "global"]], "preferredModelDisplayMode": "fullscreen"]]],
            ["name": "standmixer_action", "title": "StandMixer panel action", "description": "Routing settings, optional local app installation, and explicit Claude connection controls for Codex. Settings never run models or require login. Configured Codex-to-Claude routes may check public CLI sign-in status automatically; opening the official browser login or logging out requires an explicit request. Logout signs out the shared Claude Code profile. Apply, uninstall, and restore require a stored reviewed preview ID; paths and shell commands are never accepted.",
             "inputSchema": ["type": "object", "required": ["action"], "additionalProperties": false,
                             "properties": ["action": ["type": "string", "enum": actions], "configuration": ["type": "object"],
                                            "platforms": ["type": "array", "items": ["type": "string", "enum": ["codex", "claude"]], "uniqueItems": true],
                                            "previewID": ["type": "string", "format": "uuid"], "presetID": ["type": "string", "format": "uuid"],
                                            "name": ["type": "string"], "refresh": ["type": "boolean"]]],
             "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true],
             "_meta": ["ui": ["visibility": ["app"]]]],
        ]
    }
}

/// Newline-delimited stdio; stdout contains protocol messages exclusively.
final class StandMixerMCPStdio: @unchecked Sendable {
    let server: StandMixerMCPServer
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var operations: [String: Task<Void, Never>] = [:]
    private var connectionOperations = Set<String>()
    init(server: StandMixerMCPServer, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.server = server; self.input = input; self.output = output
    }

    func run() async throws {
        var pending = Data()
        var oversized = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            // MCP clients keep stdin open between requests. Read available
            // bytes instead of waiting for FileHandle to fill a pipe read.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            if count == 0 { break }
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    if oversized { write(Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request exceeds 512 KiB.\"}}".utf8)) }
                    else if !pending.isEmpty { submit(pending) }
                    pending.removeAll(keepingCapacity: true); oversized = false
                } else if !oversized {
                    if pending.count >= StandMixerModInterface.maximumRequestBytes { oversized = true; pending.removeAll(keepingCapacity: true) }
                    else { pending.append(byte) }
                }
            }
        }
        if !pending.isEmpty && !oversized { submit(pending) }
        // Closing an MCP connection must not leave a browser-login process behind.
        // Ordinary finite settings requests still complete for pipe-based clients.
        for operation in connectionSnapshot() { operation.cancel() }
        let tasks = snapshot()
        for operation in tasks { await operation.value }
    }

    private func submit(_ data: Data) {
        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if request?["method"] as? String == "notifications/cancelled",
           let params = request?["params"] as? [String: Any], let id = params["requestId"] {
            let key = Self.key(id)
            lock.lock(); let operation = operations[key]; lock.unlock()
            operation?.cancel(); return
        }
        let key = request?["id"].map(Self.key) ?? UUID().uuidString
        let action = ((request?["params"] as? [String: Any])?["arguments"] as? [String: Any])?["action"] as? String
        lock.lock()
        // Duplicate live IDs are invalid; never cancel or replace an earlier operation.
        if operations[key] != nil { lock.unlock(); write(Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Duplicate active request ID.\"}}".utf8)); return }
        if operations.count >= 8 { lock.unlock(); write(Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Too many active StandMixer requests.\"}}".utf8)); return }
        let task = Task { [self] in
            if let response = await server.respond(data) { write(response) }
            complete(key)
        }
        operations[key] = task
        if ["connectClaude", "checkClaudeConnection", "logoutClaude"].contains(action ?? "") { connectionOperations.insert(key) }
        lock.unlock()
    }
    private func complete(_ key: String) { lock.lock(); operations.removeValue(forKey: key); connectionOperations.remove(key); lock.unlock() }
    private func snapshot() -> [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return Array(operations.values) }
    private func connectionSnapshot() -> [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return connectionOperations.compactMap { operations[$0] } }
    func cancelAll() { for operation in snapshot() { operation.cancel() } }
    func cancelAllAndWait() async { let tasks = snapshot(); tasks.forEach { $0.cancel() }; for task in tasks { await task.value } }
    private func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? output.write(contentsOf: data + Data([10]))
    }
    private static func key(_ id: Any) -> String {
        if let value = id as? String { return "string:" + value }
        return "number:" + String(describing: id)
    }
}
