import CryptoKit
import Darwin
import Foundation

/// A bounded proof for one explicitly named local Codex plugin package. This
/// never enumerates the plugin store or edits native configuration.
struct InstallerPluginMigration {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Plan: Codable {
        let version: String
        let registeredRoot: String
        let cache: String
        let backup: String
        let digest: String
    }
    let home: URL
    let codexHome: URL
    private let files = FileManager.default
    private let maximumEntries = 1_024
    private let maximumBytes = 128 * 1_024 * 1_024
    private var support: URL { home.appendingPathComponent("Library/Application Support/AgentMix") }
    var expectedPackage: URL { support.appendingPathComponent(".source-install.lock/legacy-codex-expected") }
    var planURL: URL { support.appendingPathComponent(".source-install.lock/legacy-codex-plan.json") }
    private var backups: URL { support.appendingPathComponent("legacy-plugin-backups/codex-agentmix") }

    init(home: URL, codexHome: URL? = nil) {
        self.home = home
        self.codexHome = codexHome ?? home.appendingPathComponent(".codex")
    }

    func prepare(metadata: Data, registeredRoot: String) throws -> Plan {
        let version = try installedVersion(metadata, root: registeredRoot, legacy: true)
        let cache = cacheURL(version: version, legacy: true)
        let expected = try fingerprint(expectedPackage)
        try validateManifest(expectedPackage, name: "agentmix", version: version)
        guard try fingerprint(cache) == expected else { throw fail("The legacy Codex cache differs from the owned prior package. It was kept; no duplicate was installed.") }
        try safeAncestors(backups)
        try files.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ownedDirectory(backups)
        let backup = backups.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let package = backup.appendingPathComponent("package", isDirectory: true)
        // Copy the bounded private snapshot whose bytes just matched the cache.
        try files.copyItem(at: expectedPackage, to: package)
        guard try fingerprint(package) == expected, try fingerprint(cache) == expected,
              try fingerprint(expectedPackage) == expected else { throw fail("The legacy Codex package changed during backup. It was kept.") }
        try makePrivate(package)
        let plan = Plan(version: version, registeredRoot: registeredRoot, cache: cache.path, backup: package.path, digest: expected)
        let receipt = backup.appendingPathComponent("receipt.json")
        try JSONEncoder().encode(plan).write(to: receipt, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return plan
    }

    func recheck(metadata: Data, registeredRoot: String) throws {
        let plan = try JSONDecoder().decode(Plan.self, from: readOwnedFile(planURL, limit: 16_384))
        let version = try installedVersion(metadata, root: registeredRoot, legacy: true)
        let backup = URL(fileURLWithPath: plan.backup)
        let backupParent = backup.deletingLastPathComponent()
        guard plan.registeredRoot == registeredRoot, version == plan.version,
              plan.cache == cacheURL(version: version, legacy: true).path,
              backup.lastPathComponent == "package", backupParent.deletingLastPathComponent().path == backups.path,
              UUID(uuidString: backupParent.lastPathComponent) != nil,
              plan.digest.count == 64,
              try fingerprint(expectedPackage) == plan.digest,
              try fingerprint(backup) == plan.digest,
              try fingerprint(URL(fileURLWithPath: plan.cache)) == plan.digest else {
            throw fail("The legacy Codex cache changed before migration. All legacy files were kept.")
        }
    }

    func checkCanonical(metadata: Data, registeredRoot: String) throws {
        let version = try installedVersion(metadata, root: registeredRoot, legacy: false)
        let expected = URL(fileURLWithPath: registeredRoot).appendingPathComponent("Plugins/codex-agentmix")
        try validateManifest(expected, name: "standmixer", version: version)
        guard try fingerprint(expected) == fingerprint(cacheURL(version: version, legacy: false)) else {
            throw fail("The new Codex cache was modified. It was kept for explicit migration.")
        }
    }

    private func installedVersion(_ data: Data, root: String, legacy: Bool) throws -> String {
        guard data.count <= 1_048_576, lexicalPath(root),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = object["installed"] as? [[String: Any]], installed.count == 1 else {
            throw fail("The Codex plugin metadata is invalid or ambiguous. All legacy files were kept.")
        }
        let plugin = legacy ? "agentmix" : "standmixer"
        let marketplace = legacy ? "drydock-agentmix" : "drydock-standmixer"
        let item = installed[0]
        guard item["pluginId"] as? String == "\(plugin)@\(marketplace)",
              item["name"] as? String == plugin, item["marketplaceName"] as? String == marketplace,
              item["installed"] as? Bool == true, item["enabled"] is Bool,
              let version = item["version"] as? String,
              version.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              let source = item["source"] as? [String: Any], source["source"] as? String == "local",
              source["path"] as? String == root + "/Plugins/codex-agentmix",
              let origin = item["marketplaceSource"] as? [String: Any], origin["sourceType"] as? String == "local",
              origin["source"] as? String == root else {
            throw fail("The Codex plugin metadata does not prove the exact owned local package. All legacy files were kept.")
        }
        return version
    }

    private func cacheURL(version: String, legacy: Bool) -> URL {
        codexHome.appendingPathComponent(legacy ? "plugins/cache/drydock-agentmix/agentmix" : "plugins/cache/drydock-standmixer/standmixer").appendingPathComponent(version)
    }

    private func validateManifest(_ package: URL, name: String, version: String) throws {
        let object = try JSONSerialization.jsonObject(with: readOwnedFile(package.appendingPathComponent("plugin.json"), limit: 1_048_576)) as? [String: Any]
        guard object?["name"] as? String == name, object?["version"] as? String == version else {
            throw fail("The prior package manifest does not match the installed plugin. All legacy files were kept.")
        }
    }

    private func fingerprint(_ root: URL) throws -> String {
        try safeAncestors(root)
        var entries = 0
        var total = 0
        var manifest = Data()
        func visit(_ directory: URL, relative: String) throws {
            try ownedDirectory(directory)
            let children = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard children.count <= maximumEntries else { throw fail("The plugin package exceeds the migration limit. It was kept.") }
            for child in children {
                entries += 1
                let path = relative + child.lastPathComponent
                guard entries <= maximumEntries, path.utf8.count <= 1_024, !path.contains("\n") else { throw fail("The plugin package exceeds the migration limit. It was kept.") }
                let attributes = try files.attributesOfItem(atPath: child.path)
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    manifest.append(Data("d \(path)\n".utf8))
                    try visit(child, relative: path + "/")
                } else {
                    let bytes = try readOwnedFile(child, limit: min(32 * 1_024 * 1_024, maximumBytes - total))
                    total += bytes.count
                    manifest.append(Data("f \(path) \(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())\n".utf8))
                }
            }
        }
        try visit(root, relative: "")
        return SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
    }

    // Foundation's standardizedFileURL rewrites an existing /private/tmp path
    // to the /tmp alias on macOS. Check lexical components, then lstat every
    // actual ancestor so aliases and redirected roots remain rejected.
    private func lexicalPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\n") else { return false }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func safeAncestors(_ url: URL) throws {
        guard lexicalPath(url.path) else { throw fail("The plugin package path is unsafe. It was kept.") }
        var current = url
        while current.path != "/" {
            if files.fileExists(atPath: current.path) || (try? files.destinationOfSymbolicLink(atPath: current.path)) != nil {
                let attributes = try files.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw fail("A plugin package path is redirected or not a directory. It was kept.") }
                if current.path == home.path || current.path.hasPrefix(home.path + "/") || current.path == codexHome.path || current.path.hasPrefix(codexHome.path + "/") {
                    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw fail("A plugin package path is unowned. It was kept.") }
                }
            }
            current.deleteLastPathComponent()
        }
    }

    private func ownedDirectory(_ url: URL) throws {
        try safeAncestors(url)
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw fail("A plugin package directory is unsafe or unowned. It was kept.") }
    }

    private func readOwnedFile(_ url: URL, limit: Int) throws -> Data {
        try safeAncestors(url.deletingLastPathComponent())
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw fail("A plugin package file is unsafe or unavailable. It was kept.") }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1,
              status.st_size >= 0, status.st_size <= limit else { throw fail("A plugin package file is unsafe, unowned, linked, or too large. It was kept.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, data.count == status.st_size else { throw fail("A plugin package file changed during comparison. It was kept.") }
        return data
    }

    private func makePrivate(_ root: URL) throws {
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for child in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let attributes = try files.attributesOfItem(atPath: child.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { try makePrivate(child) }
            else {
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                try files.setAttributes([.posixPermissions: mode & 0o111 == 0 ? 0o600 : 0o700], ofItemAtPath: child.path)
            }
        }
    }

    private func fail(_ message: String) -> Failure { Failure(message: message) }
}
