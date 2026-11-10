import Foundation

/// Read-only saved global defaults. These are neither a model inspection report
/// nor proof of the model used by a running session. Only known primitive keys
/// escape the bounded, descriptor-safe snapshot reader.
public struct StandMixerModNativeSettings: Codable, Sendable {
    public var platform: AgentPlatform
    public var sourcePath: String
    public var modelID: String?
    public var effort: String?
    public var providerID: String?
    public var status: String
    public var detail: String

    static func capture(platform: AgentPlatform, service: IntegrationService) -> Self {
        let source = (platform == .codex ? service.codexHome : service.claudeHome)
            .appendingPathComponent(platform == .codex ? "config.toml" : "settings.json")
        let snapshot = AgentImportSnapshot.captureGlobalDefaults(platform: platform,
            codexHome: service.codexHome, claudeHome: service.claudeHome)
        let status = snapshot.nativeModelID != nil ? "known" : snapshot.paths.isEmpty ? "unavailable" : "unknown"
        let detail: String
        if status == "known" {
            detail = "Saved global native default for future sessions. The current chat model may differ through project, environment, or session selection. Controller Auto leaves this saved model and effort untouched; worker preferences are unknown unless StandMixer has an installation record."
        } else if !snapshot.uncertainties.isEmpty {
            detail = "The saved global settings exceeded the safe read limit. Native model and effort are unknown."
        } else if status == "unavailable" {
            detail = "No safely readable direct global settings file was found. Native model and effort are unknown."
        } else {
            detail = "No explicit primary model was found in the saved global settings. Native defaults and worker preferences are unknown."
        }
        return .init(platform: platform, sourcePath: source.path,
            modelID: snapshot.nativeModelID, effort: snapshot.nativeEffort,
            providerID: snapshot.nativeProviderID, status: status, detail: detail)
    }
}
