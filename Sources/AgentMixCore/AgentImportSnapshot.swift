import Darwin
import Foundation

/// The observer receives these bounded copies as data. It never gets a filesystem tool.
/// Each source is opened relative to a verified directory descriptor with O_NOFOLLOW;
/// neither directory walks outside the allowlist nor symlink targets are inspected.
struct AgentImportSnapshot {
    var text: String
    var paths: [String]
    var uncertainties: [String]
    var nativeModelID: String?
    var nativeEffort: String?
    var nativeProviderID: String?
    var recentProjects: [String]
    var recentEvidencePaths: Set<String>

    /// A configuration-only view for the mod. This deliberately skips project,
    /// memory, agent, and instruction discovery and never starts an observer.
    static func captureGlobalDefaults(platform: AgentPlatform, codexHome: URL, claudeHome: URL) -> AgentImportSnapshot {
        var reader = Reader()
        reader.reserve(files: 1, bytes: 131_072, entries: 1)
        if platform == .codex { reader.file(codexHome, "config.toml", format: .toml) }
        else { reader.file(claudeHome, "settings.json", format: .json) }
        // An incomplete source cannot prove which later value wins. Never
        // present a primitive recovered from a truncated file as current state.
        let complete = reader.notes.isEmpty
        return .init(text: "", paths: reader.paths, uncertainties: reader.notes,
                     nativeModelID: complete ? reader.nativeModelID : nil,
                     nativeEffort: complete ? reader.nativeEffort : nil,
                     nativeProviderID: complete ? reader.nativeProviderID : nil,
                     recentProjects: [], recentEvidencePaths: [])
    }

    static func capture(platform: AgentPlatform, home: URL, codexHome: URL, claudeHome: URL,
                        project: URL?) -> AgentImportSnapshot {
        var reader = Reader()
        // Global sources cannot consume the recent-project evidence allocation.
        reader.reserve(files: 20, bytes: 131_072, entries: 64)
        switch platform {
        case .codex:
            reader.file(codexHome, "config.toml", format: .toml)
            for name in ["AGENTS.md", "AGENTS.override.md"] { reader.file(codexHome, name) }
            reader.directory(codexHome, "agents", extensions: ["toml"], format: .toml, depth: 1)
            let memory = reader.file(codexHome, "memories/MEMORY.md", limit: 98_304)
            reader.referencedRoutingNotes(memory, root: codexHome.appendingPathComponent("memories"))
        case .claude:
            reader.file(claudeHome, "settings.json", format: .json)
            reader.file(claudeHome, "CLAUDE.md")
            reader.directory(claudeHome, "rules", extensions: ["md"], depth: 3)
            reader.directory(claudeHome, "agents", extensions: ["md"], depth: 2)
        }
        if let project, project.standardizedFileURL.path != home.standardizedFileURL.path {
            reader.reserve(files: 12, bytes: 65_536, entries: 32)
            reader.sourceScope = "selectedProject"; reader.projectRoot = project.path
            reader.project(project, platform: platform, claudeHome: claudeHome)
        }
        var discovery = AgentRecentProjectDiscovery()
        let recent = discovery.projects(platform: platform, home: home, codexHome: codexHome,
                                        claudeHome: claudeHome, excluding: project)
        reader.sourceScope = "recentProject"
        for (index, project) in recent.enumerated() {
            let remaining = recent.count - index
            reader.reserve(files: max(1, (Reader.maximumFiles - reader.paths.count) / remaining),
                           bytes: min(65_536, (Reader.maximumBytes - reader.bytes) / remaining),
                           entries: max(1, (320 - reader.entries) / remaining))
            reader.projectRoot = project.path
            reader.project(project, platform: platform, claudeHome: claudeHome)
        }
        if reader.paths.isEmpty { reader.notes.append("No readable routing sources were found in the permitted harness files. No other folders were searched.") }
        return .init(text: reader.parts.joined(separator: "\n"), paths: reader.paths, uncertainties: reader.notes,
                     nativeModelID: reader.nativeModelID, nativeEffort: reader.nativeEffort, nativeProviderID: reader.nativeProviderID,
                     recentProjects: recent.map(\.path), recentEvidencePaths: reader.recentEvidencePaths)
    }

    private enum Format { case markdown, json, toml }
    private struct Reader {
        static let maximumFiles = 80
        static let maximumBytes = 524_288
        var parts: [String] = []
        var paths: [String] = []
        var notes: [String] = []
        var bytes = 0
        var entries = 0
        var seen: Set<String> = []
        var nativeModelID: String?
        var nativeEffort: String?
        var nativeProviderID: String?
        var claudeDefaults: [String: Any] = [:]
        var sourceScope = "global"
        var projectRoot: String?
        var recentEvidencePaths: Set<String> = []
        var fileLimit = 80
        var byteLimit = 524_288
        var entryLimit = 320
        var groupExhausted = false
        var hasCapacity: Bool { !groupExhausted && paths.count < fileLimit && bytes + 256 < byteLimit }

        mutating func reserve(files: Int, bytes: Int, entries: Int) {
            fileLimit = min(Self.maximumFiles, paths.count + files)
            byteLimit = min(Self.maximumBytes, self.bytes + bytes)
            entryLimit = min(320, self.entries + entries)
            groupExhausted = false
        }

        mutating func project(_ project: URL, platform: AgentPlatform, claudeHome: URL) {
            switch platform {
            case .codex:
                for name in ["AGENTS.md", "AGENTS.override.md", ".codex/AGENTS.md", ".codex/AGENTS.override.md"] { file(project, name) }
                file(project, ".codex/config.toml", format: .toml)
                directory(project, ".codex/agents", extensions: ["toml"], format: .toml, depth: 1)
            case .claude:
                for name in ["CLAUDE.md", ".claude/CLAUDE.md"] { file(project, name) }
                for name in [".claude/settings.json", ".claude/settings.local.json"] { file(project, name, format: .json) }
                directory(project, ".claude/rules", extensions: ["md"], depth: 3)
                directory(project, ".claude/agents", extensions: ["md"], depth: 2)
            }
            if sourceScope == "recentProject" {
                // Related project instructions may name cross-harness workers. Their scope
                // remains project evidence, never the other harness's installed defaults.
                for name in ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md"] { file(project, name) }
            }
            if platform == .claude || sourceScope == "recentProject" {
                let key = AgentRecentProjectDiscovery.claudeKey(project.path)
                let relative = "projects/\(key)/memory"
                let index = file(claudeHome, relative + "/MEMORY.md", limit: 16_384, routingIndex: true)
                referencedProjectRoutingNotes(index, root: claudeHome, relative: relative)
                directory(claudeHome, relative, extensions: ["md"], depth: 2, routingOnly: true)
            }
        }

        @discardableResult mutating func file(_ root: URL, _ relative: String, format: Format = .markdown,
                                              limit: Int = 49_152, routingIndex: Bool = false) -> String {
            guard hasCapacity else { groupExhausted = true; bounded(); return "" }
            let components = relative.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains(".."), !relative.hasPrefix("/"),
                  let name = components.last, !Self.forbiddenName(name) else { return "" }
            let path = root.appendingPathComponent(relative).path
            guard seen.insert(path).inserted else { return "" }
            let parent = components.dropLast().joined(separator: "/")
            guard let directory = AgentRecentProjectDiscovery.directoryDescriptor(root, parent) else { return "" }
            defer { Darwin.close(directory) }
            let descriptor = name.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard descriptor >= 0 else { return "" }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
                  status.st_size >= 0 else { return "" }
            let overhead = path.utf8.count + (projectRoot?.utf8.count ?? 0) + 160
            let cap = min(limit, byteLimit - bytes - min(overhead, byteLimit - bytes))
            guard cap > 0 else { groupExhausted = true; bounded(); return "" }
            // Read only a bounded prefix; never map or load the remainder of a large file.
            var data = Data(count: min(Int(min(status.st_size, off_t(cap))), cap))
            let expectedCount = data.count
            var count = 0
            data.withUnsafeMutableBytes { buffer in
                while count < buffer.count {
                    let amount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                    if amount < 0, errno == EINTR { continue }
                    if amount <= 0 { break }
                    count += amount
                }
            }
            var finalStatus = stat()
            var pathStatus = stat()
            let samePath = name.withCString { Darwin.fstatat(directory, $0, &pathStatus, AT_SYMLINK_NOFOLLOW) } == 0
                && pathStatus.st_dev == status.st_dev && pathStatus.st_ino == status.st_ino
            guard count == expectedCount, fstat(descriptor, &finalStatus) == 0, samePath,
                  finalStatus.st_size == status.st_size, finalStatus.st_nlink == status.st_nlink,
                  finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
                  finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
                  finalStatus.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
                  finalStatus.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec else {
                notes.append("A permitted source changed or could not be read completely and was omitted: \(path)")
                return ""
            }
            data.count = count
            guard !data.contains(0), let raw = String(data: data, encoding: .utf8) else { return "" }
            var clean = Self.sanitized(raw, format: format)
            if routingIndex {
                clean = clean.components(separatedBy: .newlines).filter(Self.routingEvidenceLine).joined(separator: "\n")
                guard !clean.isEmpty else { return "" }
            }
            // JSON encoding prevents a source from closing its evidence delimiter or masquerading
            // as the observer's instructions. All source contents remain explicitly untrusted.
            if clean.utf8.count > cap { clean = String(decoding: clean.utf8.prefix(cap), as: UTF8.self) }
            var object: [String: String] = ["source": path, "scope": sourceScope, "untrusted_text": clean]
            if let projectRoot { object["project_root"] = projectRoot }
            guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  encoded.count + bytes + 1 <= byteLimit else { groupExhausted = true; bounded(); return "" }
            if sourceScope != "recentProject", ["config.toml", ".codex/config.toml", "settings.json", ".claude/settings.json", ".claude/settings.local.json"].contains(relative) {
                captureNativeDefaults(clean, format: format)
            }
            parts.append(String(decoding: encoded, as: UTF8.self)); paths.append(path); bytes += encoded.count + 1
            if status.st_size > off_t(cap) { notes.append("A permitted source was truncated at the snapshot limit: \(path)") }
            if sourceScope == "recentProject" { recentEvidencePaths.insert(path) }
            return clean
        }

        mutating func directory(_ root: URL, _ relative: String, extensions: Set<String>,
                                format: Format = .markdown, depth: Int, routingOnly: Bool = false) {
            guard depth > 0, hasCapacity, entries < entryLimit,
                  let descriptor = AgentRecentProjectDiscovery.directoryDescriptor(root, relative) else { return }
            // fdopendir owns this descriptor. Names come only from an explicit allowlisted folder.
            guard let stream = fdopendir(descriptor) else { Darwin.close(descriptor); return }
            defer { closedir(stream) }
            var names: [(String, UInt8)] = []
            while entries < entryLimit, let entry = readdir(stream) {
                entries += 1
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                guard name != ".", name != "..", !name.hasPrefix("."), !Self.forbiddenName(name) else { continue }
                names.append((name, entry.pointee.d_type))
            }
            let ordered = names.sorted {
                let left = routingOnly ? Self.routingPriority($0.0) : 0
                let right = routingOnly ? Self.routingPriority($1.0) : 0
                return left == right ? $0.0 < $1.0 : left < right
            }
            for (name, type) in ordered {
                guard hasCapacity else { groupExhausted = true; bounded(); break }
                if routingOnly && !Self.routingRelatedName(name) { continue }
                let child = relative + "/" + name
                if type == UInt8(DT_DIR) { directory(root, child, extensions: extensions, format: format, depth: depth - 1, routingOnly: routingOnly) }
                else if type == UInt8(DT_REG) || type == UInt8(DT_UNKNOWN) {
                    if extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) { file(root, child, format: format) }
                }
                // DT_LNK is never opened or inspected, even when its extension looks permitted.
            }
            if entries >= entryLimit { bounded() }
        }

        mutating func referencedProjectRoutingNotes(_ index: String, root: URL, relative: String) {
            // Exact local Markdown names on routing-related memory index lines only.
            // No absolute paths, links outside this memory scope, or arbitrary read directives.
            guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./-])[A-Za-z0-9_-]+\.md"#) else { return }
            var references: Set<String> = []
            for line in index.components(separatedBy: .newlines) {
                guard Self.routingEvidenceLine(line) else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in expression.matches(in: line, range: range) {
                    guard references.count < 32, let value = Range(match.range, in: line) else { break }
                    references.insert(String(line[value]))
                }
            }
            let ordered = references.sorted {
                let left = Self.routingPriority($0), right = Self.routingPriority($1)
                return left == right ? $0 < $1 : left < right
            }
            for name in ordered.prefix(12) {
                guard hasCapacity else { groupExhausted = true; bounded(); break }
                file(root, relative + "/" + name)
            }
        }

        static func routingRelatedName(_ name: String) -> Bool {
            let lower = name.lowercased()
            return ["routing", "model", "tier", "codex", "claude", "fable", "opus", "haiku", "delegat", "agent", "build", "review", "ui-design", "design-ui", "variant", "quota", "coordinator", "effort"].contains(where: lower.contains)
        }

        static func routingEvidenceLine(_ line: String) -> Bool {
            let lower = line.lowercased()
            if ["routing", "model", "tier", "codex", "claude", "fable", "opus", "haiku", "delegat", "coordinator", "effort", "quota", "variant"].contains(where: lower.contains) { return true }
            // Generic words such as "build" in a repository URL or "agent" in prose
            // do not make an unrelated hardware/product note a routing reference.
            let names = lower.split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "." }
            return names.contains { $0.hasSuffix(".md") && routingRelatedName(String($0)) }
        }

        static func routingPriority(_ name: String) -> Int {
            let lower = name.lowercased()
            if lower.contains("model") && lower.contains("tier") { return 0 }
            if lower.contains("routing") { return 1 }
            if lower.contains("codex") || lower.contains("claude") { return 2 }
            if lower.contains("variant") { return 3 }
            if lower.contains("quota") { return 4 }
            return 5
        }

        mutating func referencedRoutingNotes(_ memory: String, root: URL) {
            // Only Markdown references on routing/model-related index lines may name a note.
            // Absolute paths, traversal, arbitrary 'read this file' instructions, sessions and
            // transcript stores are not a discovery mechanism.
            guard let expression = try? NSRegularExpression(pattern: #"(?:rollout_summaries|notes|extensions/ad_hoc/notes)/[A-Za-z0-9_./-]+\.md"#) else { return }
            var count = 0
            for line in memory.components(separatedBy: .newlines) {
                let lower = line.lowercased()
                guard ["routing", "model", "effort", "coordinator", "delegat", "agentmix"].contains(where: lower.contains) else { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in expression.matches(in: line, range: range) {
                    guard count < 12, let value = Range(match.range, in: line) else { return }
                    let relative = String(line[value])
                    guard !relative.split(separator: "/").contains("..") else { continue }
                    file(root, relative); count += 1
                }
            }
        }

        mutating func bounded() {
            let note = "A routing evidence group reached its file, entry, or byte limit; remaining files in that group were not read. Capacity remains reserved for later project groups."
            if !notes.contains(note) { notes.append(note) }
        }

        mutating func captureNativeDefaults(_ raw: String, format: Format) {
            func valid(_ value: String?) -> String? {
                guard let value, !value.isEmpty, value.count <= 180,
                      value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/[]").contains($0) }) else { return nil }
                return value
            }
            if format == .json, let settings = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                for key in ["model", "effortLevel", "modelSettings"] where settings[key] != nil { claudeDefaults[key] = settings[key] }
                if let model = valid(claudeDefaults["model"] as? String) { nativeModelID = model }
                let models = claudeDefaults["modelSettings"] as? [String: [String: Any]]
                let effort = nativeModelID.flatMap { models?[$0]?["effortLevel"] as? String } ?? claudeDefaults["effortLevel"] as? String
                if let effort, EffortPolicy.levels.contains(effort) { nativeEffort = effort }
            } else if format == .toml {
                // Only primitive saved observer defaults are projected into runtime controls.
                // Never project provider commands, env values, hooks, instructions, or credentials.
                var section = ""
                var multilineDelimiter: String?
                var tables: [String: [String: String]] = [:]
                for line in raw.components(separatedBy: .newlines) {
                    let line = line.trimmingCharacters(in: .whitespaces)
                    if let delimiter = multilineDelimiter {
                        if line.contains(delimiter) { multilineDelimiter = nil }
                        continue
                    }
                    if line.hasPrefix("["), line.hasSuffix("]") {
                        section = String(line.dropFirst().dropLast()).replacingOccurrences(of: "\"", with: "")
                        continue
                    }
                    let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pieces.count == 2 else { continue }
                    let key = pieces[0].trimmingCharacters(in: .whitespaces)
                    let value = pieces[1].trimmingCharacters(in: .whitespaces)
                    if let delimiter = ["\"\"\"", "'''"] .first(where: { value.hasPrefix($0) }) {
                        if !value.dropFirst(3).contains(delimiter) { multilineDelimiter = delimiter }
                        continue
                    }
                    guard ["model", "model_provider", "model_reasoning_effort", "profile"].contains(key) else { continue }
                    guard let quote = value.first, ["\"", "'"].contains(String(quote)),
                          let end = value.dropFirst().firstIndex(of: quote) else { continue }
                    tables[section, default: [:]][key] = String(value[value.index(after: value.startIndex)..<end])
                }
                var defaults = tables[""] ?? [:]
                if let profile = defaults["profile"], let overrides = tables["profiles.\(profile)"] { defaults.merge(overrides) { _, saved in saved } }
                if let model = valid(defaults["model"]) { nativeModelID = model }
                if let provider = valid(defaults["model_provider"]) { nativeProviderID = provider }
                if let effort = defaults["model_reasoning_effort"], EffortPolicy.levels.contains(effort) { nativeEffort = effort }
            }
        }

        static func forbiddenName(_ name: String) -> Bool {
            let lower = name.lowercased()
            return lower == "auth.json" || lower == ".claude.json" || lower.hasPrefix(".env") ||
                ["credential", "secret", "token", "keychain", "session", "transcript"].contains(where: lower.contains)
        }

        static func sanitized(_ raw: String, format: Format) -> String {
            if format == .json {
                guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                    return "[Settings were omitted because they were not complete valid JSON.]"
                }
                let allowed: Set<String> = ["model", "effortLevel", "modelSettings", "agent", "agents", "defaultAgent", "defaultModel", "routing", "routes"]
                let filtered = object.filter { allowed.contains($0.key) }.mapValues(scrubJSON)
                guard let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]) else { return "" }
                return String(decoding: data, as: UTF8.self)
            }
            var excludedSection = false
            var instructionDelimiter: String?
            var redactedStringDelimiter: String?
            var markdownSensitiveIndent: Int?
            var markdownSecretSection = false
            var markdownSecretBraces = 0
            var lines: [String] = []
            for line in raw.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let lower = trimmed.lowercased()
                if format == .markdown {
                    if markdownSecretBraces > 0 {
                        markdownSecretBraces += trimmed.filter { $0 == "{" || $0 == "[" }.count - trimmed.filter { $0 == "}" || $0 == "]" }.count
                        continue
                    }
                    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                    if let secretIndent = markdownSensitiveIndent {
                        if trimmed.isEmpty || indent > secretIndent { continue }
                        markdownSensitiveIndent = nil
                    }
                    if lower.hasPrefix("["), lower.hasSuffix("]") {
                        markdownSecretSection = ["env", "header", "credential", "secret", "token"].contains(where: lower.contains)
                    }
                    if lower.hasPrefix("```") || lower.hasPrefix("~~~") { markdownSecretSection = false }
                    if markdownSecretSection { continue }
                    let assignment = trimmed.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "=" }).map(String.init)
                    if assignment.count == 2, sensitiveKey(assignment[0]) {
                        lines.append("[Sensitive configuration block omitted]")
                        let value = assignment[1].trimmingCharacters(in: .whitespaces)
                        if value.isEmpty || ["|", ">"].contains(value) { markdownSensitiveIndent = indent }
                        for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
                            if !value.dropFirst(3).contains(delimiter) { redactedStringDelimiter = delimiter }
                        }
                        markdownSecretBraces = max(0, value.filter { $0 == "{" || $0 == "[" }.count - value.filter { $0 == "}" || $0 == "]" }.count)
                        continue
                    }
                }
                if let delimiter = redactedStringDelimiter {
                    if trimmed.contains(delimiter) { redactedStringDelimiter = nil }
                    continue
                }
                if format == .toml, instructionDelimiter == nil, lower.hasPrefix("[") {
                    let routingTable = ["[profiles", "[agents", "[routing", "[routes"].contains(where: lower.hasPrefix)
                    excludedSection = !routingTable || ["env", "header", "credential", "secret", "mcp_servers", "hooks", "plugins", "apps", "model_providers"].contains(where: lower.contains)
                }
                if excludedSection { continue }
                if isSensitiveLine(lower) {
                    lines.append(format == .toml ? "# Sensitive configuration line omitted" : "[Sensitive configuration line omitted]")
                    if format == .toml {
                        let value = lower.split(separator: "=", maxSplits: 1).dropFirst().joined()
                        for delimiter in ["\"\"\"", "'''"] where value.contains(delimiter) {
                            if value.components(separatedBy: delimiter).count == 2 { redactedStringDelimiter = delimiter }
                        }
                        if (value.contains("{") && !value.contains("}")) ||
                            (value.contains("[") && !value.contains("]")) || value.contains("\"\"\"") || value.contains("'''") {
                            excludedSection = true
                        }
                    }
                    continue
                }
                if format == .toml {
                    if let delimiter = instructionDelimiter {
                        lines.append(line)
                        if trimmed.contains(delimiter) { instructionDelimiter = nil }
                        continue
                    }
                    if lower.hasPrefix("[") {
                        // Preserve only tables that can establish native models, profiles or agents.
                        if ["[profiles", "[agents", "[routing", "[routes"].contains(where: lower.hasPrefix) { lines.append(line) }
                        continue
                    }
                    let pieces = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pieces.count == 2 else { continue }
                    let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let allowed: Set<String> = ["model", "model_provider", "model_reasoning_effort", "model_reasoning_summary", "profile", "effort", "effort_level", "minimum", "maximum", "developer_instructions", "instructions", "description", "name", "config_file", "coordinator", "planning", "ui", "implementation", "algorithms", "review", "algorithmreview", "mechanical", "additionalagents", "resultmode", "judgemodelid"]
                    guard allowed.contains(key) else { continue }
                    let value = pieces[1].trimmingCharacters(in: .whitespaces)
                    if ["developer_instructions", "instructions", "description"].contains(key) {
                        for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
                            if !value.dropFirst(3).contains(delimiter) { instructionDelimiter = delimiter }
                        }
                    }
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }

        static func scrubJSON(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { key, _ in !sensitiveKey(key) }.mapValues(scrubJSON)
            }
            if let array = value as? [Any] { return array.map(scrubJSON) }
            if let text = value as? String, isSensitiveLine(text.lowercased()) { return "[Sensitive value omitted]" }
            return value
        }
        static func sensitiveKey(_ key: String) -> Bool {
            let lower = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\"'[]{}"))).lowercased()
            return lower == "env" || lower == "environment" || lower == "environments" || lower.hasSuffix("_env") || lower.hasPrefix("env_") ||
                ["token", "secret", "password", "credential", "authorization", "header", "api_key", "apikey", "access_key", "private_key", "hook", "command"].contains(where: lower.contains)
        }
        static func isSensitiveLine(_ lower: String) -> Bool {
            if lower.contains("bearer ") || lower.contains("sk-ant-") || lower.contains("sk-proj-") { return true }
            let key = lower.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "=" }).first.map(String.init) ?? lower
            if (lower.contains("=") || lower.contains(":")), sensitiveKey(key) { return true }
            // Markdown/YAML and configuration snippets can also contain JSON-style credentials.
            return ["api_key", "apikey", "access_token", "refresh_token", "client_secret", "authorization", "http_headers", "password"].contains(where: lower.contains)
        }
    }
}
