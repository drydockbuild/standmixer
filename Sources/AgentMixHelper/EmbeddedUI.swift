import AgentMixCore
import CryptoKit
import Foundation
import Security
import Darwin

enum AgentMixPanelSession {
    static func url(in data: Data) throws -> String {
        guard data.count <= 2048,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["url", "pid", "idleTimeoutSeconds"],
              let value = object["url"] as? String, let parts = URLComponents(string: value),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.path == "/", parts.query == nil, parts.user == nil, parts.password == nil,
              let fragment = parts.fragment, fragment.hasPrefix("token="),
              fragment.dropFirst(6).count == 43,
              fragment.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let pid = object["pid"] as? Int, pid > 0 else {
            throw NSError(domain: "AgentMixSession", code: 1)
        }
        return value
    }

    static func read(_ path: String) throws -> String {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: "AgentMixSession", code: 1) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(), status.st_nlink == 1, status.st_size <= 2048,
              status.st_mode & mode_t(0o077) == 0 else { throw NSError(domain: "AgentMixSession", code: 1) }
        return try url(in: handle.read(upToCount: 2049) ?? Data())
    }
}

/// Both Codex transports delegate to the same stored-preview configuration API.
/// No transport accepts a filename, executable, or the contents of a reviewed plan.
final class AgentMixUIEngine: @unchecked Sendable {
    let interface: AgentMixModInterface
    init(interface: AgentMixModInterface) { self.interface = interface }

    func action(_ data: Data) async -> Data {
        let fields: Set<String> = ["action", "configuration", "platforms", "previewID", "name", "presetID", "refresh"]
        guard data.count <= AgentMixModInterface.maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: fields) else {
            return Self.failure("invalidRequest", "Send a supported StandMixer action. Paths and commands are not accepted.")
        }
        return await interface.runJSON(data).output
    }

    static func failure(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": ["code": code, "message": message]], options: [.sortedKeys])) ?? Data()
    }
}

struct AgentMixUIAssets {
    static let resourceURI = "ui://standmixer/settings.html"
    static let mimeType = "text/html;profile=mcp-app"
    let html: Data
    let contentSecurityPolicy: String

    /// This directory comes only from a trusted process argument, never a web or
    /// tool request. Load once; HTTP requests cannot select arbitrary local files.
    init(root: URL) throws {
        let url = root.appendingPathComponent("index.html")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024 * 1024 else {
            throw Self.failure("The bundled StandMixer panel is missing or too large.")
        }
        html = try Data(contentsOf: url)
        guard let source = String(data: html, encoding: .utf8), source.contains("<html") else {
            throw Self.failure("The bundled StandMixer panel is invalid.")
        }
        // The distributable is a self-contained HTML document. Hash its scripts
        // rather than allowing inline handlers, eval, or scripts from the network.
        let expression = try NSRegularExpression(pattern: "<script\\b[^>]*>([\\s\\S]*?)</script>", options: [.caseInsensitive])
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let hashes = expression.matches(in: source, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return "'sha256-" + Data(SHA256.hash(data: Data(source[range].utf8))).base64EncodedString() + "'"
        }
        contentSecurityPolicy = "default-src 'none'; script-src " + (hashes.isEmpty ? "'none'" : hashes.joined(separator: " ")) + "; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'"
    }

    static func resolve(explicitPath: String?, executable: URL) throws -> AgentMixUIAssets {
        if let explicitPath {
            guard explicitPath.hasPrefix("/") else { throw failure("Use --ui-root with an absolute bundled UI directory.") }
            return try .init(root: URL(fileURLWithPath: explicitPath, isDirectory: true))
        }
        // Development binary or packaged plugin binary. Stable bootstrap copies
        // receive --ui-root from their plugin launcher.
        let roots = [executable.deletingLastPathComponent().appendingPathComponent("../ui"),
                     executable.deletingLastPathComponent().appendingPathComponent("../../../Plugins/codex-agentmix/ui")]
        for root in roots {
            if let assets = try? AgentMixUIAssets(root: root.standardizedFileURL) { return assets }
        }
        throw failure("StandMixer could not find its bundled panel. Use the plugin launcher or pass --ui-root.")
    }

    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw failure("StandMixer could not create a private panel session.")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AgentMixUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
