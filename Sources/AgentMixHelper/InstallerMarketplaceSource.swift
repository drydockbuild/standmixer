import AgentMixCore
import Foundation

/// Parses only local marketplace-list metadata. No paths are read or created.
/// nil means absent; malformed, remote, or duplicate target registrations fail.
enum AgentMixInstallerMarketplaceSource {
    static let maximumInputBytes = 1024 * 1024
    enum Invalid: Error { case metadata }

    static func source(in data: Data, platform: AgentPlatform, marketplace: String = "drydock-agentmix") throws -> String? {
        guard ["drydock-agentmix", "drydock-standmixer"].contains(marketplace) else { throw Invalid.metadata }
        guard !data.isEmpty, data.count <= maximumInputBytes else { throw Invalid.metadata }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw Invalid.metadata }
        let entries: [[String: Any]]
        if platform == .claude {
            guard let array = object as? [[String: Any]] else { throw Invalid.metadata }
            entries = array
        } else {
            guard let dictionary = object as? [String: Any], let array = dictionary["marketplaces"] as? [[String: Any]] else { throw Invalid.metadata }
            entries = array
        }
        guard entries.count <= 4096, entries.allSatisfy({ $0["name"] is String }) else { throw Invalid.metadata }
        let matches = entries.filter { $0["name"] as? String == marketplace }
        guard matches.count <= 1 else { throw Invalid.metadata }
        guard let entry = matches.first else { return nil }
        if platform == .claude {
            guard entry["source"] as? String == "directory", let path = entry["path"] as? String else { throw Invalid.metadata }
            return try localPath(path)
        }
        guard let root = entry["root"] as? String,
              let source = entry["marketplaceSource"] as? [String: Any],
              source["sourceType"] as? String == "local", let path = source["source"] as? String else { throw Invalid.metadata }
        let registered = try localPath(root)
        guard registered == (try localPath(path)) else { throw Invalid.metadata }
        return registered
    }

    private static func localPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Invalid.metadata }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
