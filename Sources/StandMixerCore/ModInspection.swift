import CryptoKit
import Darwin
import Foundation

public struct StandMixerModObservedWorker: Codable, Sendable {
    public var id: UUID
    public var modelID: String
    public var modelPlatform: AgentPlatform?
    public var effort: EffortPolicy?
    init(_ worker: ImportedAgentAssignment) {
        id = worker.id; modelID = worker.modelID; modelPlatform = worker.modelPlatform; effort = worker.effort
    }
}

public struct StandMixerModObservedRoute: Codable, Sendable {
    public var category: WorkCategory
    public var modelID: String?
    public var modelPlatform: AgentPlatform?
    public var effort: EffortPolicy?
    public var evidence: [ImportEvidence]
    public var uncertainties: [String]
    public var additionalAgents: [StandMixerModObservedWorker]?
    public var resultMode: RouteResultMode?
    public var judgeModelID: String?
    public var scope: String
    init(_ route: ImportedRoute) {
        category = route.category; modelID = route.modelID; modelPlatform = route.modelPlatform
        effort = route.effort; evidence = route.evidence; uncertainties = route.uncertainties
        additionalAgents = route.additionalAgents?.map(StandMixerModObservedWorker.init)
        resultMode = route.resultMode; judgeModelID = route.judgeModelID; scope = route.scope.rawValue
    }
}

public struct StandMixerModInspectionReport: Codable, Sendable {
    public var platform: AgentPlatform
    public var status: String
    public var summary: String
    public var routes: [StandMixerModObservedRoute]
    public var notes: [String]
    public var sources: [ImportEvidence]
    public var executionModelID: String?
    public var error: String?
}

public struct StandMixerModInspection: Codable, Sendable {
    public var createdAt: Date
    public var expiresAt: Date
    public var reports: [StandMixerModInspectionReport]
    public var fromCache: Bool
}

private struct InspectionCache: Codable {
    var version = 1
    var fingerprint: [String: String]
    var inspection: StandMixerModInspection
}

extension StandMixerModInterface {
    private var inspectionURL: URL { service.applicationSupport.appendingPathComponent("mod-inspection.json") }

    /// A cache hit never starts a CLI or exposes snapshot bodies. Source hashes
    /// are built from the same descriptor-safe, redacted allowlist as the app.
    func loadCachedInspection() throws -> StandMixerModInspection? {
        try service.checkNoSymlink(inspectionURL)
        let descriptor = Darwin.open(inspectionURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw StandMixerError.invalid("The private preference report is unavailable.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == getuid(), information.st_nlink == 1,
              information.st_size <= 1_048_576, information.st_mode & mode_t(0o077) == 0 else { return nil }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(InspectionCache.self, from: data), cache.version == 1,
              cache.inspection.createdAt <= Date().addingTimeInterval(60), cache.inspection.expiresAt > Date(),
              cache.inspection.expiresAt.timeIntervalSince(cache.inspection.createdAt) <= 901,
              cache.inspection.reports.count <= AgentPlatform.allCases.count,
              Set(cache.inspection.reports.map(\.platform)).count == cache.inspection.reports.count else { return nil }
        for report in cache.inspection.reports {
            guard cache.fingerprint[report.platform.rawValue] == sourceFingerprint(report.platform) else { return nil }
        }
        var result = cache.inspection
        result.fromCache = true
        return result
    }

    func inspectPreferences(platforms requested: Set<AgentPlatform>?, refresh: Bool = false) async throws -> StandMixerModResponse {
        let available = Set(await connections().filter(\.isInstalled).map(\.platform))
        let preference = try service.loadConfiguration().enabledPlatforms
        let selected = (requested ?? preference ?? available).intersection(available)
        guard !selected.isEmpty else { throw StandMixerError.invalid("Enable an available harness before reading preferences.") }
        if !refresh, let cached = try loadCachedInspection(), selected.isSubset(of: Set(cached.reports.map(\.platform))) {
            var filtered = cached; filtered.reports.removeAll { !selected.contains($0.platform) }
            return .init(ok: true, inspection: filtered)
        }
        // This lock is separate from settings transactions: reading preferences
        // cannot block Apply in another host, or duplicate inference concurrently.
        try service.privateDirectory(service.applicationSupport)
        let lockURL = service.applicationSupport.appendingPathComponent(".inspection.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw StandMixerError.invalid("The private preference-read lock is unavailable.") }
        defer { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == getuid(), information.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { throw StandMixerError.invalid("The preference-read lock is not a private regular file.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StandMixerError.conflict("StandMixer is already reading preferences in another session. Try refreshing shortly.") }
        // Another process may have finished between the first cache read and lock.
        if !refresh, let cached = try loadCachedInspection(), selected.isSubset(of: Set(cached.reports.map(\.platform))) {
            var filtered = cached; filtered.reports.removeAll { !selected.contains($0.platform) }
            return .init(ok: true, inspection: filtered)
        }
        try Task.checkCancellation()
        let before = Dictionary(uniqueKeysWithValues: selected.map { ($0.rawValue, sourceFingerprint($0)) })
        let integration = service
        let injected = inspectionReader
        let reader = AgentImportService(integration: integration, timeout: 75)
        var reports = await withTaskGroup(of: StandMixerModInspectionReport.self) { group in
            for platform in selected {
                group.addTask {
                    do {
                        let proposal: AgentImportProposal
                        if let injected { proposal = try await injected(platform) }
                        else { proposal = try await reader.inspect(platform: platform, mode: .quick) }
                        return .init(platform: platform, status: proposal.uncertainties.isEmpty ? "complete" : "partial",
                            summary: proposal.summary, routes: proposal.routes.map(StandMixerModObservedRoute.init),
                            notes: proposal.uncertainties, sources: proposal.sources,
                            executionModelID: proposal.executionModelID, error: nil)
                    } catch {
                        return .init(platform: platform, status: "failed", summary: "Preference reading did not complete.", routes: [],
                            notes: ["Existing settings and the selected draft were kept. No alternate model was started."], sources: [],
                            executionModelID: nil, error: error is CancellationError ? "Preference reading was stopped." : error.localizedDescription)
                    }
                }
            }
            var results: [StandMixerModInspectionReport] = []
            for await report in group { results.append(report) }
            return results.sorted { $0.platform.rawValue < $1.platform.rawValue }
        }
        try Task.checkCancellation()
        for index in reports.indices where before[reports[index].platform.rawValue] != sourceFingerprint(reports[index].platform) {
            reports[index].status = "partial"
            reports[index].notes.append("Settings changed while they were being read. Refresh before relying on this report.")
        }
        let created = Date()
        let inspection = StandMixerModInspection(createdAt: created,
            expiresAt: created.addingTimeInterval(reports.contains { $0.status == "failed" } ? 120 : 900), reports: reports, fromCache: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(InspectionCache(fingerprint: before, inspection: inspection))
        guard data.count <= 1_048_576 else { throw StandMixerError.invalid("The preference report is too large. Existing settings were kept.") }
        try service.write(data, to: inspectionURL, mode: 0o600)
        return .init(ok: true, inspection: inspection)
    }

    private func sourceFingerprint(_ platform: AgentPlatform) -> String {
        let snapshot = AgentImportSnapshot.capture(platform: platform, home: service.home,
            codexHome: service.codexHome, claudeHome: service.claudeHome, project: nil)
        return SHA256.hash(data: Data((snapshot.text + "\n" + snapshot.paths.joined(separator: "\n")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
