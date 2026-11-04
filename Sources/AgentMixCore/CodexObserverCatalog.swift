import Foundation

/// Copies the CLI's public bundled model metadata, changing only observer tool capabilities.
/// A native model that is absent from the bounded catalogue cannot safely use generic defaults.
struct CodexObserverCatalog {
    var data: Data
    var modelIDs: Set<String>

    init(publicMetadata: Data) throws {
        guard var root = try? JSONSerialization.jsonObject(with: publicMetadata) as? [String: Any],
              let models = root["models"] as? [[String: Any]], !models.isEmpty, models.count <= 500 else {
            throw AgentImportError.failed("This Codex CLI cannot provide its public model metadata for a tool-free observer. Update the CLI and retry. No model was started.")
        }
        var identifiers: Set<String> = []
        var observers: [[String: Any]] = []
        for var model in models {
            guard let slug = model["slug"] as? String, !slug.isEmpty, slug.count <= 180,
                  slug.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/[]").contains($0) }),
                  identifiers.insert(slug).inserted else {
                throw AgentImportError.failed("Codex returned an unsupported public model catalogue. No model was started.")
            }
            model["apply_patch_tool_type"] = NSNull()
            model["experimental_supported_tools"] = [] as [String]
            model["tool_mode"] = NSNull()
            // These fields are model-side instruction boilerplate, never routing preferences.
            model["include_skills_usage_instructions"] = false
            model["include_plugin_usage_instructions"] = false
            model["include_apps_usage_instructions"] = false
            observers.append(model)
        }
        root["models"] = observers
        data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        modelIDs = identifiers
    }

    static func validateToolManifest(_ metadata: Data) throws {
        guard let records = try? JSONSerialization.jsonObject(with: metadata) as? [[String: Any]],
              records.allSatisfy({ ["additional_tools", "message"].contains($0["type"] as? String ?? "") }),
              records.contains(where: { $0["type"] as? String == "additional_tools" }) else {
            throw AgentImportError.failed("Codex could not verify its tool-free observer manifest. No model was started.")
        }
        for record in records where record["type"] as? String == "additional_tools" {
            guard let namespaces = record["tools"] as? [[String: Any]] else { throw unsafeManifest() }
            for namespace in namespaces {
                guard namespace["type"] as? String == "namespace", namespace["name"] as? String == "functions",
                      let tools = namespace["tools"] as? [[String: Any]] else { throw unsafeManifest() }
                for tool in tools {
                    guard tool["type"] as? String == "function", tool["name"] as? String == "request_user_input" else {
                        throw unsafeManifest()
                    }
                }
            }
        }
    }

    private static func unsafeManifest() -> AgentImportError {
        .failed("This Codex CLI still exposes filesystem or external tools under the observer controls. Safe inspection stopped before starting a model. Update the CLI and retry.")
    }
}
