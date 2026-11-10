import Darwin
import Foundation

/// Reads path/recency metadata owned by the native harnesses. Metadata is never sent to
/// the observer: only exact, bounded project instruction/memory files enter its snapshot.
/// In particular this never decodes Claude's lossy directory names into filesystem paths.
struct AgentRecentProjectDiscovery {
    static let maximumProjects = 5
    private static let maximumCandidates = 160
    private var remainingBytes = 3_145_728
    private var candidates: [String: Double] = [:]
    private var projectHome: URL?

    init() {}

    /// The inspection reference projects only public catalog names/IDs. Its reader is
    /// stricter than general CLI discovery: no user symlink or hardlink is followed.
    static func cachedModelReferences(codexHome: URL) -> [ModelSpec] {
        var reader = Self()
        guard let data = reader.metadata(codexHome, "models_cache.json", cap: 262_144),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        let knownLabels = Dictionary(ModelSpec.builtIn.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        return models.prefix(64).compactMap { model in
            guard let id = model["slug"] as? String, model["visibility"] as? String != "hide" else { return nil }
            let label = knownLabels[id] ?? model["display_name"] as? String ?? id
            return ModelSpec(id: id, label: label, platform: .codex, isDiscovered: true)
        }
    }

    mutating func projects(platform: AgentPlatform, home: URL, codexHome: URL, claudeHome: URL,
                           excluding selected: URL?) -> [URL] {
        projectHome = home
        if let data = metadata(codexHome, ".codex-global-state.json", cap: 2_097_152),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Only these native project-path fields and one timestamp map are projected.
            // Prompt history, recent files, chat contents and other atom state are ignored.
            let atoms = state["electron-persisted-atom-state"] as? [String: Any] ?? [:]
            let activity = atoms["thread-user-activity-times-v1"] as? [String: Any] ?? [:]
            let hints = state["thread-workspace-root-hints"] as? [String: String] ?? [:]
            var recentHints: [(path: String, time: Double)] = []
            for (thread, path) in hints { recentHints.append((path, Self.timestamp(activity[thread]))) }
            recentHints.sort {
                if $0.time == $1.time { return $0.path < $1.path }
                return $0.time > $1.time
            }
            for (path, time) in recentHints {
                add(path, time: time)
                if candidates.count >= Self.maximumCandidates { break }
            }
            // Timed activity takes the bounded candidate slots before unordered saved roots.
            for key in ["electron-saved-workspace-roots", "saved-workspace-roots", "active-workspace-roots"] {
                for path in (state[key] as? [String] ?? []).prefix(Self.maximumCandidates) { add(path, time: 0) }
            }
            // Older/newer native stores may retain the actual root on a project record.
            if let local = state["local-projects"] as? [String: [String: Any]] {
                for key in local.keys.sorted().prefix(Self.maximumCandidates) {
                    let record = local[key] ?? [:]
                    if let path = record["path"] as? String ?? record["rootPath"] as? String {
                        add(path, time: Self.timestamp(record["updatedAt"]))
                    }
                }
            }
        }
        if let data = metadata(codexHome, "config.toml", cap: 262_144), let text = String(data: data, encoding: .utf8) {
            trustedProjects(text).forEach { add($0, time: 0) }
        }
        if platform == .claude {
            // This optional documented history projection reads a bounded tail and keeps
            // only project/timestamp. Display text, attachments and message bodies are ignored.
            if let data = metadata(claudeHome, "history.jsonl", cap: 524_288, tail: true) {
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(512) {
                    if let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                       let path = record["project"] as? String {
                        add(path, time: Self.timestamp(record["timestamp"]))
                    }
                }
            }
            // Enumerate native scope METADATA only. A projectPath must match its exact
            // encoded scope; no transcript or UUID directory is ever opened.
            for scope in directoryNames(claudeHome, "projects").prefix(Self.maximumCandidates) {
                guard let data = metadata(claudeHome, "projects/\(scope)/sessions-index.json", cap: 32_768),
                      let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let records = [index] + Array((index["entries"] as? [[String: Any]] ?? []).prefix(64))
                for record in records {
                    guard let path = record["projectPath"] as? String ?? record["originalPath"] as? String,
                          Self.claudeKey(path) == scope else { continue }
                    add(path, time: Self.timestamp(record["modified"]))
                }
            }
        }
        let selectedPath = selected?.standardizedFileURL.path
        var selectedIdentity: String?
        if let selected, let descriptor = Self.directoryDescriptor(selected) {
            selectedIdentity = Self.identity(descriptor); Darwin.close(descriptor)
        }
        var rankedByIdentity: [String: (URL, Double)] = [:]
        for (path, savedTime) in candidates {
            guard path != selectedPath, Self.permittedProject(path, home: home) else { continue }
            let project = URL(fileURLWithPath: path, isDirectory: true)
            guard let descriptor = Self.directoryDescriptor(project) else { continue }
            guard let identity = Self.identity(descriptor), identity != selectedIdentity else { Darwin.close(descriptor); continue }
            // Prefer actual work repositories/harness projects. This is metadata for three
            // exact names, never a project walk or a source-code/message search.
            let isProject = [".git", ".claude", ".codex"].contains { name in
                var status = stat()
                return fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 &&
                    (status.st_mode & S_IFMT == S_IFDIR || (status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1))
            }
            Darwin.close(descriptor)
            guard isProject else { continue }
            var time = savedTime
            if platform == .claude {
                let relative = "projects/\(Self.claudeKey(path))"
                guard let scopeTime = directoryActivity(claudeHome, relative) else { continue }
                time = max(time, max(scopeTime, directoryActivity(claudeHome, relative + "/memory") ?? 0))
            }
            if rankedByIdentity[identity] == nil || time > rankedByIdentity[identity]!.1 {
                rankedByIdentity[identity] = (project, time)
            }
        }
        let ranked = Array(rankedByIdentity.values)
        return ranked.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
            .prefix(Self.maximumProjects).map(\.0)
    }

    private mutating func add(_ path: String, time: Double) {
        guard let normalized = permittedPath(path) else { return }
        if candidates[normalized] == nil, candidates.count >= Self.maximumCandidates {
            guard let oldest = candidates.min(by: { $0.value < $1.value }), time > oldest.value else { return }
            candidates.removeValue(forKey: oldest.key)
        }
        candidates[normalized] = max(candidates[normalized] ?? 0, time)
    }

    private func permittedPath(_ path: String) -> String? {
        guard path.utf8.count <= 2_048, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }),
              !path.split(separator: "/").contains("..") else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let projectHome, Self.permittedProject(normalized, home: projectHome) else { return nil }
        return normalized
    }

    private static func identity(_ descriptor: Int32) -> String? {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return "\(status.st_dev):\(status.st_ino)"
    }

    static func permittedProject(_ path: String, home: URL) -> Bool {
        let root = home.standardizedFileURL.path
        guard path != "/", path != root, !root.hasPrefix(path + "/") else { return false }
        let components = path.split(separator: "/").map { $0.lowercased() }
        let protected: Set<String> = ["music", "downloads", "desktop", "documents", "pictures", "movies", "library", ".trash", "cloudstorage", "mobile documents", "dropbox", "icloud drive", "google drive"]
        return !components.contains(where: { protected.contains($0) || $0.hasPrefix("onedrive") || $0.hasPrefix("google drive") })
    }

    static func claudeKey(_ path: String) -> String {
        path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
    }

    private static func timestamp(_ raw: Any?) -> Double {
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            guard value.isFinite, value > 0 else { return 0 }
            return value > 10_000_000_000 ? value / 1_000 : value
        }
        if let text = raw as? String, text.count < 80 {
            return ISO8601DateFormatter().date(from: text)?.timeIntervalSince1970 ?? 0
        }
        return 0
    }

    private func trustedProjects(_ text: String) -> [String] {
        var paths: [String] = []; var path: String?; var delimiter: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let current = delimiter { if line.contains(current) { delimiter = nil }; continue }
            if let current = ["\"\"\"", "'''"].first(where: { line.contains($0) }) {
                if line.components(separatedBy: current).count == 2 { delimiter = current }
                continue
            }
            if line.hasPrefix("[") {
                path = nil
                let prefix = "[projects."
                if line.hasPrefix(prefix), line.hasSuffix("]") {
                    let quoted = String(line.dropFirst(prefix.count).dropLast())
                    path = (try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: [.fragmentsAllowed])) as? String
                }
            } else if let path, line.replacingOccurrences(of: " ", with: "").hasPrefix("trust_level=\"trusted\""),
                      let normalized = permittedPath(path), !paths.contains(normalized) {
                // Protected historical project tables cannot crowd the finite work-project
                // allocation before late native tables for current repositories are seen.
                paths.append(normalized)
            }
            if paths.count >= Self.maximumCandidates { break }
        }
        return paths
    }

    /// Every ancestor is opened without following links; fixed macOS aliases alone expand.
    static func directoryDescriptor(_ root: URL, _ relative: String = "") -> Int32? {
        var absolute = root.path
        guard absolute.hasPrefix("/"), !relative.hasPrefix("/") else { return nil }
        for alias in ["/var", "/tmp", "/etc"] where absolute == alias || absolute.hasPrefix(alias + "/") {
            absolute = "/private" + absolute; break
        }
        let components = (absolute + (relative.isEmpty ? "" : "/" + relative)).split(separator: "/").map(String.init)
        guard !components.contains("..") else { return nil }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in components {
            let child = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            Darwin.close(descriptor); guard child >= 0 else { return nil }; descriptor = child
        }
        return descriptor
    }

    private func directoryNames(_ root: URL, _ relative: String) -> [String] {
        guard let descriptor = Self.directoryDescriptor(root, relative) else { return [] }
        guard let stream = fdopendir(descriptor) else { Darwin.close(descriptor); return [] }
        defer { closedir(stream) }
        var names: [(String, Double)] = []; var count = 0
        while count < 320, let entry = readdir(stream) {
            count += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            guard name != ".", name != "..", !name.contains("/") else { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
            names.append((name, Double(status.st_mtimespec.tv_sec)))
        }
        return names.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map(\.0)
    }

    /// A transcript's modification time is harmless project activity metadata. Its body and
    /// UUID subdirectory are never opened. Existing memory edits also update this ranking.
    private func directoryActivity(_ root: URL, _ relative: String) -> Double? {
        guard let descriptor = Self.directoryDescriptor(root, relative) else { return nil }
        var status = stat(); var latest = fstat(descriptor, &status) == 0 ? Double(status.st_mtimespec.tv_sec) : 0
        guard let stream = fdopendir(descriptor) else { Darwin.close(descriptor); return latest }
        defer { closedir(stream) }
        var count = 0
        while count < 96, let entry = readdir(stream) {
            count += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            guard name != ".", name != "..", !name.contains("/"),
                  fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { continue }
            latest = max(latest, Double(status.st_mtimespec.tv_sec))
        }
        return latest
    }

    private mutating func metadata(_ root: URL, _ relative: String, cap: Int, tail: Bool = false) -> Data? {
        let components = relative.split(separator: "/").map(String.init)
        guard let name = components.last, !relative.hasPrefix("/"), !components.contains(".."), remainingBytes > 0,
              let directory = Self.directoryDescriptor(root, components.dropLast().joined(separator: "/")) else { return nil }
        defer { Darwin.close(directory) }
        let descriptor = name.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }; defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1, status.st_size >= 0 else { return nil }
        let limit = min(cap, remainingBytes)
        guard tail || status.st_size <= off_t(limit) else { return nil }
        let offset = tail ? max(0, status.st_size - off_t(limit)) : 0
        guard lseek(descriptor, offset, SEEK_SET) >= 0 else { return nil }
        var data = Data(count: min(Int(min(status.st_size, off_t(limit))), limit)); var count = 0
        data.withUnsafeMutableBytes { buffer in
            while count < buffer.count {
                let amount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if amount <= 0 { break }; count += amount
            }
        }
        data.count = count; remainingBytes -= count
        guard !data.contains(0) else { return nil }
        if offset > 0, let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
        return data
    }
}
