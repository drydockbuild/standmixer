import Foundation

/// One-time installer cleanup. Replacing the integration must not roll back
/// native defaults: Auto belongs to the caller, not a historical installation.
public enum InstallerRetirement {
    public static func keepNativeDefaults(home: URL, environment: [String: String]) throws -> Int {
        let old = home.appendingPathComponent("Library/Application Support/AgentMix")
        let service = IntegrationService(home: home, applicationSupport: old, environment: environment)
        let receipt = old.appendingPathComponent("installation.json")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return 0 }
        let marker = old.appendingPathComponent("source/.agentmix-source")
        try service.checkNoSymlink(marker)
        guard String(decoding: try StandMixerMacInstaller.readOwned(marker, maximum: 128), as: UTF8.self)
            == "AgentMix source checkout v1\n" else {
            throw StandMixerError.conflict("The old installation is unrecognized; it was kept.")
        }
        return try service.withOperationLock {
            try service.checkNoSymlink(receipt)
            let before = try StandMixerMacInstaller.readOwned(receipt, maximum: 4_000_000)
            guard var object = try JSONSerialization.jsonObject(with: before) as? [String: Any],
                  object["version"] as? Int == 1, let records = object["records"] as? [[String: Any]],
                  records.count <= 4096 else { throw StandMixerError.invalid("The old installation receipt could not be safely retired.") }
            let native = records.filter { $0["kind"] as? String == "native" }
            guard !native.isEmpty else { return 0 }
            let allowed = ["codex": service.codexHome.appendingPathComponent("config.toml").path,
                           "claude": service.claudeHome.appendingPathComponent("settings.json").path]
            for record in native {
                guard let platform = record["platform"] as? String, let expected = allowed[platform],
                      record["path"] as? String == expected else {
                    throw StandMixerError.conflict("An old native setting record belongs to another configuration root; it was kept.")
                }
            }
            // Save the original baseline verbatim before relinquishing ownership.
            // No native configuration file is opened or modified here.
            let backup = old.appendingPathComponent("Retirement/\(UUID().uuidString).json")
            try service.privateDirectory(backup.deletingLastPathComponent())
            try service.write(before, to: backup, mode: 0o600)
            guard try StandMixerMacInstaller.readOwned(receipt, maximum: 4_000_000) == before else {
                throw StandMixerError.conflict("The old receipt changed during retirement; retry after the active operation finishes.")
            }
            object["records"] = records.filter { $0["kind"] as? String != "native" }
            try service.write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: receipt, mode: 0o600)
            return native.count
        }
    }
}
