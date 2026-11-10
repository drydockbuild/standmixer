import CryptoKit
import Foundation

/// A model selector can serve independent tasks without defining a worker persona.
/// Only provider, exact model ID, and meaningful effort intent determine identity.
struct WorkerSpec: Hashable {
    let provider: AgentPlatform
    let modelID: String
    let effort: EffortPolicy

    init(model: ModelSpec, effort: EffortPolicy) {
        provider = model.platform
        modelID = model.id
        switch effort.mode {
        case .auto: self.effort = .auto
        case .fixed: self.effort = .fixed(effort.value)
        case .range: self.effort = .range(minimum: effort.minimum, maximum: effort.maximum)
        }
    }

    private var effortToken: String {
        switch effort.mode {
        case .auto: return "auto"
        case .fixed: return effort.value
        case .range: return "range-\(effort.minimum)-\(effort.maximum)"
        }
    }

    /// Description metadata is available to the controller before launch; the
    /// child body cannot configure effort after its model has already started.
    func launchDescription(for model: ModelSpec) -> String {
        let levels = model.callerEfforts.joined(separator: ", ")
        let supported = levels.isEmpty ? "not established; verify before launch" : levels
        return "Model selector: \(model.label); effort: \(effort.description). Supported launch levels: \(supported)."
    }

    /// A guide anchor is not a native agent name and cannot select a cheap driver.
    var externalReferenceID: String { "external-" + String(name.dropFirst("standmixer-".count)) }

    var name: String {
        if ModelSpec.builtIn.contains(where: { $0.id == modelID && $0.platform == provider }) {
            return "standmixer-\(modelID)-\(effortToken)"
        }
        let identity = "\(provider.rawValue)\u{0}\(modelID)\u{0}\(effortToken)"
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let safe = modelID.lowercased().unicodeScalars.map { scalar -> String in
            (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
                ? String(scalar) : "-"
        }.joined().split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let slug = String(safe.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "standmixer-\(slug.isEmpty ? "model" : slug)-\(effortToken)-\(hash)"
    }
}
