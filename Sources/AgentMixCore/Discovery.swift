// Read-only CLI discovery; only --version runs, in an isolated configuration directory.
import Darwin
import Foundation

extension IntegrationService {
    public func detect() async -> [ConnectionStatus] {
        await Task.detached(priority: .utility) { [self] in
            discoveryCache.invalidate()
            return AgentPlatform.allCases.map { platform in
                guard let selected = discoveredSelection(platform) else {
                    return ConnectionStatus(platform: platform, path: nil, version: nil,
                        detail: "CLI not found. Install it separately, then check again.", isInstalled: false)
                }
                let evidence = selected.version == nil
                    ? "Executable found; the CLI version could not be verified."
                    : selected.isActive
                        ? "Selected a running CLI executable, verified with --version."
                        : "Selected the newest verified CLI found on this Mac."
                return ConnectionStatus(platform: platform, path: selected.executable.path, version: selected.version,
                    detail: "\(evidence) Source: \(selected.source). Sign-in and model entitlement are not inspected.",
                    isInstalled: true)
            }
        }.value
    }

    /// Reads the model catalog only. Account identity and all other cache keys are ignored.
    /// A cached model is discovered, not a guarantee of current account entitlement.
    public func discoveredModels() -> [ModelSpec] {
        let requestedPath = codexHome.appendingPathComponent("models_cache.json")
        guard let path = CLIDiscovery(home: home, environment: [:]).safeURL(requestedPath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000,
              let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { item in
            guard let id = item["slug"] as? String, !id.isEmpty,
                  item["visibility"] as? String != "hide" else { return nil }
            let labels: [String: String] = ["gpt-6.1-sol": "Sol 6.1", "gpt-6-astra": "Astra 6", "gpt-6-luna": "Luna 6", "gpt-6.1-terra": "Terra 6.1"]
            let levels = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            return ModelSpec(id: id, label: labels[id] ?? item["display_name"] as? String ?? id, platform: .codex,
                             supportedEfforts: levels.isEmpty ? EffortPolicy.levels : levels, isDiscovered: true,
                             defaultEffort: item["default_reasoning_level"] as? String)
        }
    }

    func discoveredExecutable(_ platform: AgentPlatform) -> URL? {
        discoveredSelection(platform)?.executable
    }

    private func discoveredSelection(_ platform: AgentPlatform) -> CLISelection? {
        discoveryCache.selection(for: platform) {
            let discovery = CLIDiscovery(home: home, environment: environment)
            if metadataOnlyDiscovery {
                return discovery.candidates(platform).first.map {
                    CLISelection(executable: $0.executable, version: nil, source: $0.source, isActive: $0.isActive)
                }
            }
            return discovery.select(platform)
        }
    }

    /// Bounded known CLI locations and executable metadata only. This never
    /// launches a CLI, reads credentials, or claims sign-in/model entitlement.
    public func detectMetadata() -> [ConnectionStatus] {
        let discovery = CLIDiscovery(home: home, environment: environment)
        return AgentPlatform.allCases.map { platform in
            let selected = discovery.candidates(platform).first
            return .init(platform: platform, path: selected?.executable.path, version: nil,
                detail: selected.map { "Executable found. Source: \($0.source). Version, sign-in, and model entitlement are not checked." }
                    ?? "CLI not found in known installation locations.", isInstalled: selected != nil)
        }
    }
}

/// SemVer precedence, including numeric prereleases and ignored build metadata.
struct CLIVersion: Comparable, Sendable {
    private let core: [String]
    private let prerelease: [String]

    init?(_ text: String) {
        let metadata = text.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2, metadata.count == 1 || Self.validIdentifiers(String(metadata[1])) else { return nil }
        let parts = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count == 3, numbers.allSatisfy(Self.validNumber) else { return nil }
        let suffix = parts.count == 2 ? String(parts[1]) : nil
        guard suffix == nil || Self.validIdentifiers(suffix!) else { return nil }
        let identifiers = suffix?.split(separator: ".").map(String.init) ?? []
        guard identifiers.allSatisfy({ !Self.isNumeric($0) || Self.validNumber($0) }) else { return nil }
        core = numbers; prerelease = identifiers
    }

    private static func isNumeric(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func validNumber(_ text: String) -> Bool {
        isNumeric(text) && (text.count == 1 || text.first != "0")
    }
    private static func validIdentifiers(_ text: String) -> Bool {
        text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
    private static func numberLess(_ a: String, _ b: String) -> Bool {
        a.count == b.count ? a < b : a.count < b.count
    }
    static func < (a: Self, b: Self) -> Bool {
        for (x, y) in zip(a.core, b.core) where x != y { return numberLess(x, y) }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (isNumeric(x), isNumeric(y)) {
            case (true, true): return numberLess(x, y)
            case (true, false): return true
            case (false, true): return false
            case (false, false): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
    static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }
}

struct CLICandidate: Sendable {
    var executable: URL
    var source: String
    var isActive: Bool = false
    var versionHint: CLIVersion?
    var allowsDirectorySymlinks: Bool = true
}

struct CLISelection: Sendable {
    var executable: URL
    var version: String?
    var source: String
    var isActive: Bool
}

/// Injectable paths and process snapshots keep tests independent of the owner's installed apps.
struct CLIDiscovery {
    var home: URL
    var environment: [String: String]
    var applicationDirectories: [URL]
    var commonDirectories: [URL]
    var activeExecutables: () -> [URL]
    var probeTimeout: TimeInterval
    var directoryReader: (URL) -> [URL]
    static let maximumProbes = 64

    init(home: URL, environment: [String: String], applicationDirectories: [URL]? = nil,
         commonDirectories: [URL]? = nil, activeExecutables: @escaping () -> [URL] = CLIDiscovery.runningExecutables,
         probeTimeout: TimeInterval = 2, directoryReader: @escaping (URL) -> [URL] = CLIDiscovery.readDirectory) {
        self.home = home; self.environment = environment
        self.applicationDirectories = applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.commonDirectories = commonDirectories ?? ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map(URL.init(fileURLWithPath:))
        self.activeExecutables = activeExecutables; self.probeTimeout = probeTimeout
        self.directoryReader = directoryReader
    }

    func select(_ platform: AgentPlatform) -> CLISelection? {
        let candidates = candidates(platform)
        guard !candidates.isEmpty else { return nil }
        let probeEnvironment = ["PATH": binDirectories().compactMap { safeURL($0) }.map(\.path).joined(separator: ":")]
        let timeout = probeTimeout
        let results = CLIProbeResults(count: candidates.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        for (index, candidate) in candidates.enumerated() {
            queue.addOperation {
                results.set(Self.version(candidate.executable, platform: platform, environment: probeEnvironment,
                                         timeout: timeout), at: index)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        let versions = results.values
        return Self.choose(candidates: candidates, versions: versions)
    }

    /// Active verified CLIs take precedence; otherwise choose the newest verified version.
    static func choose(candidates: [CLICandidate], versions: [String?]) -> CLISelection? {
        let verified = zip(candidates, versions).compactMap { candidate, text -> (CLICandidate, String, CLIVersion)? in
            guard let text, let version = CLIVersion(text) else { return nil }
            return (candidate, text, version)
        }
        let active = verified.filter { $0.0.isActive }
        let pool = active.isEmpty ? verified : active
        // Strict comparison preserves the first candidate among equal versions.
        let selected = pool.reduce(nil as (CLICandidate, String, CLIVersion)?) { best, item in
            guard let best else { return item }
            return best.2 < item.2 ? item : best
        }
        if let selected {
            return CLISelection(executable: selected.0.executable, version: selected.1,
                                source: selected.0.source, isActive: selected.0.isActive)
        }
        return candidates.first.map { CLISelection(executable: $0.executable, version: nil, source: $0.source, isActive: false) }
    }

    func candidates(_ platform: AgentPlatform) -> [CLICandidate] {
        let files = FileManager.default
        let active = activeExecutables().filter { Self.isCLIPath($0, platform: platform) }
        var found = active.map { CLICandidate(executable: $0, source: "running process executable", isActive: true) }
        for directory in binDirectories() where !isProtectedPath(directory) {
            found.append(CLICandidate(executable: directory.appendingPathComponent(platform.rawValue), source: "PATH or CLI bin directory"))
        }
        if platform == .claude {
            let native = home.appendingPathComponent(".local/share/claude/versions")
            for entry in sortedEntries(native).filter({ CLIVersion($0.lastPathComponent) != nil }).prefix(32) {
                found += [entry, entry.appendingPathComponent("claude")].map {
                    CLICandidate(executable: $0, source: "Claude native version store", versionHint: CLIVersion(entry.lastPathComponent),
                                 allowsDirectorySymlinks: false)
                }
            }
            // This exact CLI store is sufficient; never list Claude's application-data parent.
            let store = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
            for version in sortedEntries(store).filter({ CLIVersion($0.lastPathComponent) != nil }).prefix(32) {
                var leaves = [version.appendingPathComponent("claude"), version.appendingPathComponent("claude.app/Contents/MacOS/claude")]
                for hash in sortedEntries(version).filter({ Self.isBuildHash($0.lastPathComponent) }).prefix(32) {
                    leaves.append(hash.appendingPathComponent("claude.app/Contents/MacOS/claude"))
                }
                found += leaves.map {
                    CLICandidate(executable: $0, source: "Claude Desktop managed CLI", versionHint: CLIVersion(version.lastPathComponent),
                                 allowsDirectorySymlinks: false)
                }
            }
        }
        for parent in applicationDirectories {
            let names = platform == .claude ? ["Claude.app"] : ["ChatGPT.app", "Codex.app"]
            for name in names {
                let resources = parent.appendingPathComponent("\(name)/Contents/Resources")
                let directPaths = [platform.rawValue, "bin/\(platform.rawValue)"]
                found += directPaths.map {
                    CLICandidate(executable: resources.appendingPathComponent($0), source: "\(name) bundled CLI", allowsDirectorySymlinks: false)
                }
                let cliSubtrees = platform == .claude
                    ? ["claude-code", "app.asar.unpacked/node_modules/@anthropic-ai/claude-code"]
                    : ["codex-cli", "app.asar.unpacked/node_modules/@openai/codex"]
                for subtree in cliSubtrees {
                    found += bundledCLIs(in: resources.appendingPathComponent(subtree), platform: platform, maximumEntries: 500, depth: 6).map {
                        CLICandidate(executable: $0, source: "\(name) bundled CLI", allowsDirectorySymlinks: false)
                    }
                }
            }
        }
        var seen = Set<String>()
        let installed = found.compactMap { candidate -> CLICandidate? in
            guard let resolved = safeURL(candidate.executable, allowDirectorySymlinks: candidate.allowsDirectorySymlinks),
                  files.isExecutableFile(atPath: resolved.path),
                  let attributes = try? files.attributesOfItem(atPath: resolved.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            // A running executable and a discovered symlink may identify the same file.
            if !seen.insert(resolved.path).inserted { return nil }
            var result = candidate
            result.executable = resolved
            return result
        }
        // Keep active executables and newest named version stores before applying the probe budget.
        let sorted = installed.enumerated().sorted { a, b in
            if a.element.isActive != b.element.isActive { return a.element.isActive }
            switch (a.element.versionHint, b.element.versionHint) {
            case let (x?, y?) where x != y: return y < x
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        let running = sorted.filter(\.isActive)
        let namedVersions = sorted.filter { !$0.isActive && $0.versionHint != nil }
        let binPaths = sorted.filter { !$0.isActive && $0.versionHint == nil }
        // A large old-version store must not crowd the current PATH CLI out of the budget.
        let reserved = running + Array(namedVersions.prefix(32)) + Array(binPaths.prefix(24))
        let reservedPaths = Set(reserved.map { $0.executable.path })
        return Array((reserved + sorted.filter { !reservedPaths.contains($0.executable.path) }).prefix(Self.maximumProbes))
    }

    static func readDirectory(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    private func sortedEntries(_ directory: URL) -> [URL] {
        // Enumeration never follows even a safe-looking symlink to another directory.
        guard let safe = safeURL(directory, allowDirectorySymlinks: false, allowLeafSymlink: false) else { return [] }
        return directoryReader(safe).sorted { a, b in
            let x = CLIVersion(a.lastPathComponent), y = CLIVersion(b.lastPathComponent)
            if let x, let y, x != y { return y < x }
            return a.lastPathComponent.compare(b.lastPathComponent, options: [.numeric, .literal]) == .orderedDescending
        }
    }

    private func binDirectories() -> [URL] {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").prefix(128)
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        let local = [".local/bin", ".npm-global/bin", ".npm/bin", ".volta/bin", ".asdf/shims", ".local/share/mise/shims", "Library/pnpm", ".bun/bin"]
            .map { home.appendingPathComponent($0) }
        return pathDirectories + local + commonDirectories + nodeDirectories()
    }

    private func nodeDirectories() -> [URL] {
        let stores: [(String, String)] = [(".nvm/versions/node", "bin"), (".fnm/node-versions", "installation/bin"),
            (".local/share/fnm/node-versions", "installation/bin"), (".local/share/mise/installs/node", "bin"), (".asdf/installs/nodejs", "bin")]
        return stores.flatMap { root, suffix in
            sortedEntries(home.appendingPathComponent(root)).prefix(16).map { $0.appendingPathComponent(suffix) }
        }
    }

    private func bundledCLIs(in root: URL, platform: AgentPlatform, maximumEntries: Int, depth: Int) -> [URL] {
        // Only explicitly named CLI package subtrees reach this bounded walk, never all Resources.
        var pending: [(URL, Int)] = [(root, 0)]
        var found: [URL] = []; var count = 0
        while !pending.isEmpty && count < maximumEntries {
            let (directory, level) = pending.removeFirst()
            for url in sortedEntries(directory).prefix(maximumEntries - count) {
                count += 1
                if url.lastPathComponent == platform.rawValue { found.append(url) }
                guard level + 1 < depth,
                      let safe = safeURL(url, allowDirectorySymlinks: false, allowLeafSymlink: false),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: safe.path),
                      attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                pending.append((safe, level + 1))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func isBuildHash(_ text: String) -> Bool {
        (8...128).contains(text.count) && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    /// Resolve one component at a time, rejecting a protected destination before touching it.
    /// Foundation's resolvingSymlinksInPath can traverse the destination before we can filter it.
    fileprivate func safeURL(_ url: URL, allowDirectorySymlinks: Bool = true, allowLeafSymlink: Bool = true) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"), !isProtectedPath(url) else { return nil }
        var pending = Array(Self.normalizedURL(url).pathComponents.dropFirst())
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            let item = resolved.appendingPathComponent(component)
            var information = stat()
            guard item.path.withCString({ lstat($0, &information) }) == 0 else { return nil }
            let kind = information.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) {
                guard allowLeafSymlink, allowDirectorySymlinks || pending.isEmpty, links < 32,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) else { return nil }
                links += 1
                var destination = target.hasPrefix("/") ? URL(fileURLWithPath: target) : resolved.appendingPathComponent(target)
                for remainder in pending { destination.appendPathComponent(remainder) }
                destination = Self.normalizedURL(destination)
                guard !isProtectedPath(destination) else { return nil }
                pending = Array(destination.pathComponents.dropFirst())
                resolved = URL(fileURLWithPath: "/", isDirectory: true)
            } else {
                guard pending.isEmpty || kind == mode_t(S_IFDIR) else { return nil }
                resolved = item
            }
        }
        return resolved
    }

    /// Purely lexical normalization. Only Darwin's fixed filesystem aliases are expanded;
    /// no user-controlled parent symlink is resolved as a side effect of normalization.
    private static func normalizedURL(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.pathComponents where component != "/" && component != "." {
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        if components.prefix(3).map({ $0.lowercased() }) == ["system", "volumes", "data"] {
            components.removeFirst(3)
        }
        if let first = components.first?.lowercased(), ["var", "tmp", "etc"].contains(first) {
            components[0] = first
            components.insert("private", at: 0)
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
    }

    func isProtectedPath(_ url: URL) -> Bool {
        let components = Self.normalizedURL(url).pathComponents
        // Cloud clients can also mount outside the home directory.
        if components.contains(where: { component in
            let compact = component.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
            return compact.hasPrefix("googledrive") || compact.hasPrefix("onedrive") || compact.hasPrefix("dropbox") || compact.hasPrefix("iclouddrive")
        }) { return true }
        let homeComponents = Self.normalizedURL(home).pathComponents.map { $0.lowercased() }
        guard components.map({ $0.lowercased() }).starts(with: homeComponents) else { return false }
        let relative = Array(components.dropFirst(homeComponents.count))
        guard let first = relative.first?.lowercased() else { return false }
        if ["desktop", "documents", "downloads", "music", "movies", "pictures"].contains(first) { return true }
        guard first == "library" else { return false }
        // Do not probe any other app's data, containers, or cloud storage via PATH or a symlink.
        let allowed = [["library", "pnpm"], ["library", "application support", "claude", "claude-code"]]
        return !allowed.contains { relative.map { $0.lowercased() }.starts(with: $0) }
    }

    static func isCLIPath(_ url: URL, platform: AgentPlatform) -> Bool {
        if url.lastPathComponent == platform.rawValue { return true }
        return platform == .claude && url.path.contains("/.local/share/claude/versions/") && CLIVersion(url.lastPathComponent) != nil
    }

    /// Kernel executable paths only: never process arguments, prompts, or environment variables.
    /// Sandbox denial or a process exiting simply leaves the newest installed CLI as the fallback.
    static func runningExecutables() -> [URL] {
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&request, 4, nil, &size, nil, 0) == 0, size > 0,
              size <= MemoryLayout<kinfo_proc>.stride * 32768 else { return [] }
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = table.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&request, 4, &table, &size, nil, 0) == 0 else { return [] }
        var paths: [URL] = []
        let processCount = min(table.count, min(size / MemoryLayout<kinfo_proc>.stride, 32768))
        for index in 0..<processCount {
            let process = table[index]
            guard process.kp_eproc.e_ucred.cr_uid == getuid() else { continue }
            // PROC_PIDPATHINFO_MAXSIZE is the C expression (4 * MAXPATHLEN), not imported by Swift.
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = buffer.withUnsafeMutableBytes { proc_pidpath(process.kp_proc.p_pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { continue }
            let url = URL(fileURLWithPath: String(cString: buffer))
            if AgentPlatform.allCases.contains(where: { isCLIPath(url, platform: $0) }) { paths.append(url) }
        }
        return paths.sorted { $0.path < $1.path }
    }

    static func versionToken(_ text: String, platform: AgentPlatform) -> String? {
        let lower = text.lowercased()
        let branded = platform == .claude
            ? lower.contains("claude code") || lower.contains("claude-code")
            : lower.contains("codex-cli") || lower.hasPrefix("codex ")
        guard branded else { return nil }
        return text.split(whereSeparator: \.isWhitespace).map(String.init).first { CLIVersion($0) != nil }
    }

    static func version(_ executable: URL, platform: AgentPlatform, environment: [String: String], timeout: TimeInterval) -> String? {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("agentmix-cli-version-\(UUID().uuidString)")
        do {
            try files.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: temporary) }
            let outputURL = temporary.appendingPathComponent("version-output")
            guard files.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = executable; process.arguments = ["--version"]
            process.currentDirectoryURL = temporary
            let cliPath = [executable.deletingLastPathComponent().path, environment["PATH"] ?? "", "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"].joined(separator: ":")
            process.environment = ["HOME": temporary.path, "CODEX_HOME": temporary.path,
                "CLAUDE_CONFIG_DIR": temporary.path, "PATH": cliPath, "LANG": "en_US.UTF-8", "TMPDIR": temporary.path]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            let complete = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in complete.signal() }
            try process.run()
            guard complete.wait(timeout: .now() + timeout) == .success else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = complete.wait(timeout: .now() + 1)
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let input = try FileHandle(forReadingFrom: outputURL)
            defer { try? input.close() }
            let data = try input.read(upToCount: 4097) ?? Data()
            guard data.count <= 4096 else { return nil }
            return versionToken(String(decoding: data, as: UTF8.self), platform: platform)
        } catch { return nil }
    }
}

private final class CLIProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ version: String?, at index: Int) { lock.lock(); defer { lock.unlock() }; storage[index] = version }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// One cache per integration service; a refresh replaces the path used by later previews as well.
final class ExecutableDiscoveryCache: @unchecked Sendable {
    private struct Entry { var selection: CLISelection?; var checkedAt: Date }
    private let lock = NSRecursiveLock()
    private var entries: [AgentPlatform: Entry] = [:]

    func invalidate() { lock.lock(); defer { lock.unlock() }; entries.removeAll() }

    func selection(for platform: AgentPlatform, now: Date = Date(), resolve: () -> CLISelection?) -> CLISelection? {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries[platform] {
            let age = now.timeIntervalSince(entry.checkedAt)
            if age >= 0 && age < 60 { return entry.selection }
        }
        let selection = resolve()
        entries[platform] = Entry(selection: selection, checkedAt: now)
        return selection
    }
}
