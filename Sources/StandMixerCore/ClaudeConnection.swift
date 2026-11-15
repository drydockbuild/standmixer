import CoreFoundation
import Darwin
import Foundation
import os

public enum StandMixerClaudeConnectionState: String, Codable, Sendable {
    case connected, signInRequired, unavailable, missing
}

/// A bounded public status summary. Raw CLI output and authorization URLs never leave this service.
public struct StandMixerClaudeConnectionReport: Codable, Sendable {
    public var state: StandMixerClaudeConnectionState
    public var detail: String
    public var cliPath: String?
    public var checkedAt: Date

    public init(state: StandMixerClaudeConnectionState, detail: String, cliPath: String? = nil, checkedAt: Date = Date()) {
        self.state = state; self.detail = detail; self.cliPath = cliPath
        self.checkedAt = checkedAt
    }
}

/// Nonsecret launch metadata only. A nil configuration directory intentionally leaves the
/// variable unset; an explicit default path is a different CLI credential namespace.
public struct StandMixerClaudeInvocation: Codable, Sendable, Equatable {
    public let executable: URL
    public let home: URL
    public let configDirectory: String?

    public init(executable: URL, home: URL, configDirectory: String?) {
        self.executable = executable; self.home = home; self.configDirectory = configDirectory
    }

    /// Public status and sign-in use a fixed locale for CLI output.
    public func environment(from source: [String: String]) -> [String: String] {
        var result = workerEnvironment(from: source)
        result["LC_ALL"] = "C"
        return result
    }

    /// Workers keep the caller's locale and the same checked profile as status and sign-in.
    /// The official CLI owns its native credentials; inherited API/provider tokens cannot
    /// silently change the billing source or override this connection.
    func workerEnvironment(from source: [String: String]) -> [String: String] {
        let removedPrefixes = ["DYLD_", "LD_"]
        let removedKeys: Set<String> = ["CLAUDECODE", "CLAUDE_CONFIG_DIR", "CLAUDE_API_KEY", "CLAUDE_AUTH_TOKEN", "CLAUDE_OAUTH_TOKEN",
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
            "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_FOUNDRY_BASE_URL", "ANTHROPIC_FOUNDRY_RESOURCE",
            "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
            "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
            "CLAUDE_CODE_SKIP_BEDROCK_AUTH", "CLAUDE_CODE_SKIP_VERTEX_AUTH", "CLAUDE_CODE_SKIP_FOUNDRY_AUTH"]
        var result = AgentImportService.inspectionEnvironment(from: source).filter { key, value in
            !removedKeys.contains(key) && !removedPrefixes.contains(where: key.hasPrefix)
                && !key.utf8.contains(0) && !value.utf8.contains(0)
        }
        let directories = (result["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        result["PATH"] = ([executable.deletingLastPathComponent().path] + directories
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"])
            .filter { seen.insert($0).inserted }.joined(separator: ":")
        result["HOME"] = home.path
        result["CLAUDE_CONFIG_DIR"] = configDirectory
        result["DISABLE_AUTOUPDATER"] = "1"
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return result
    }

    fileprivate var valid: Bool {
        [executable, home].allSatisfy { $0.isFileURL && Self.validPath($0.path) }
            && configDirectory.map { $0.isEmpty || Self.validPath($0) } != false
    }
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    fileprivate func sharesProfile(with other: Self) -> Bool {
        home == other.home && configDirectory == other.configDirectory
    }
}

/// Settings can check the public CLI status on open when routes require Claude Code.
/// Checks never invoke a model. Only connect() may start the official browser login.
public actor StandMixerClaudeConnectionService {
    public static let maximumCheckDuration: TimeInterval = 12
    public static let maximumLoginDuration: TimeInterval = 300
    private let service: IntegrationService
    private let checkDuration: TimeInterval
    private let loginDuration: TimeInterval
    private let probeDuration: TimeInterval
    private var connecting = false
    private var preferenceURL: URL { service.applicationSupport.appendingPathComponent("claude-connection.json") }

    public init(service: IntegrationService) {
        self.service = service
        checkDuration = Self.maximumCheckDuration; loginDuration = Self.maximumLoginDuration; probeDuration = 2
    }

    init(service: IntegrationService, checkDuration: TimeInterval, loginDuration: TimeInterval = 300,
         probeDuration: TimeInterval = 2) {
        self.service = service
        self.checkDuration = min(Self.maximumCheckDuration, max(0.01, checkDuration))
        self.loginDuration = min(Self.maximumLoginDuration, max(0.01, loginDuration))
        self.probeDuration = max(0.01, probeDuration)
    }

    public func check() async throws -> StandMixerClaudeConnectionReport {
        try await findConnection(profile: remembered() ?? currentProfile()).report
    }

    public func connect() async throws -> StandMixerClaudeConnectionReport {
        guard !connecting else {
            return .init(state: .unavailable, detail: "Claude sign-in is already in progress. Complete or cancel it before trying again.")
        }
        connecting = true
        defer { connecting = false }
        let checked = try await findConnection(profile: remembered() ?? currentProfile())
        guard checked.report.state == .signInRequired, let invocation = checked.invocation else { return checked.report }
        try Task.checkCancellation()
        _ = try remembered(for: invocation)
        let report: StandMixerClaudeConnectionReport
        do {
            // Login output can contain authorization URLs and codes. Drain and discard it all.
            let result = try await run(invocation, arguments: ["auth", "login"], timeout: loginDuration, maximumBytes: 0)
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                return .init(state: .unavailable, detail: "Claude sign-in did not complete. Recheck to try again.", cliPath: invocation.executable.path)
            }
            // An exit-zero login is not proof of authentication. Check the exact same binary,
            // HOME, and configuration namespace, without fallback to another installation.
            report = try await status(invocation, timeout: checkDuration)
        } catch is CancellationError { throw CancellationError() }
        catch ClaudeConnectionProcess.Failure.timedOut {
            return .init(state: .unavailable, detail: "Claude sign-in reached its time limit and was stopped. Recheck to try again.", cliPath: invocation.executable.path)
        } catch {
            return .init(state: .unavailable, detail: "Claude sign-in could not complete. Recheck to try again.", cliPath: invocation.executable.path)
        }
        if report.state == .connected, !(try await remember(invocation)) { return preferenceFailure(invocation) }
        return report
    }

    /// Resolve and verify the saved connection without opening a browser. A removed or updated
    /// executable may be replaced from bounded known locations, always in the saved profile.
    public func resolveInvocation(workingDirectory: URL? = nil) async throws -> StandMixerClaudeInvocation {
        let profile = try remembered() ?? currentProfile()
        let checked = try await findConnection(profile: profile)
        guard checked.report.state == .connected, let invocation = checked.invocation else {
            throw StandMixerError.invalid(checked.report.detail + " Open StandMixer settings and choose Connect Claude for Codex.")
        }
        if let workingDirectory {
            // Native project/local settings remain enabled. Verify their actual auth context
            // before a worker starts; a different directory must not change the billing source.
            guard workingDirectory.isFileURL, workingDirectory.path.hasPrefix("/"),
                  !workingDirectory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw StandMixerError.invalid("Choose a valid project working directory and retry. No worker was started.")
            }
            let report: StandMixerClaudeConnectionReport
            do {
                report = try await status(invocation, timeout: min(probeDuration, checkDuration), workingDirectory: workingDirectory)
            } catch is CancellationError { throw CancellationError() }
            catch ClaudeConnectionProcess.Failure.timedOut {
                throw StandMixerError.invalid("Claude connection verification timed out in this project. Retry the worker launch. No worker was started.")
            } catch {
                throw StandMixerError.invalid("Claude connection verification could not run in this project. Check the working directory and retry. No worker was started.")
            }
            guard report.state == .connected else {
                throw StandMixerError.invalid("Could not verify Claude's connection in this project. \(report.detail) No worker was started.")
            }
        }
        return invocation
    }

    private func currentProfile() -> StandMixerClaudeInvocation {
        .init(executable: URL(fileURLWithPath: "/claude"), home: service.home,
              configDirectory: service.environment["CLAUDE_CONFIG_DIR"])
    }

    private struct Checked {
        var report: StandMixerClaudeConnectionReport
        var invocation: StandMixerClaudeInvocation?
    }

    private func findConnection(profile: StandMixerClaudeInvocation) async throws -> Checked {
        try Task.checkCancellation()
        guard !service.metadataOnlyDiscovery else {
            return .init(report: .init(state: .unavailable, detail: "Claude connection checks are disabled in fixture mode. No command was started."))
        }
        guard profile.valid, profile.home == service.home else {
            return .init(report: .init(state: .unavailable, detail: "The Claude profile path is not valid. Use an absolute CLAUDE_CONFIG_DIR path or leave it unset."))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + checkDuration
        var candidates = service.cliDiscovery.candidates(.claude)
        guard !candidates.isEmpty else {
            return .init(report: .init(state: .missing, detail: "Claude Code was not found in known installation locations. Install the official Claude Code CLI, then choose Connect Claude."))
        }
        if let saved = try remembered(for: profile),
           let index = candidates.firstIndex(where: { $0.executable == saved.executable }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        var signedOut: Checked?
        for candidate in candidates {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let invocation = StandMixerClaudeInvocation(executable: candidate.executable, home: profile.home,
                                                        configDirectory: profile.configDirectory)
            let report: StandMixerClaudeConnectionReport
            do {
                let version = try await run(invocation, arguments: ["--version"], timeout: min(probeDuration, remaining), maximumBytes: 4096)
                guard version.exitCode == 0, !version.overflow,
                      CLIDiscovery.versionToken(String(decoding: version.output, as: UTF8.self), platform: .claude) != nil else { continue }
                let available = deadline - ProcessInfo.processInfo.systemUptime
                guard available > 0 else { break }
                report = try await status(invocation, timeout: min(probeDuration, available))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
            if report.state == .connected {
                guard try await remember(invocation) else { return .init(report: preferenceFailure(invocation)) }
                return .init(report: report, invocation: invocation)
            }
            if report.state == .signInRequired, signedOut == nil { signedOut = .init(report: report, invocation: invocation) }
        }
        try Task.checkCancellation()
        if let signedOut { return signedOut }
        return .init(report: .init(state: .unavailable,
            detail: "Claude's connection could not be verified within this check. A timeout, network problem, or unsupported CLI does not mean you are signed out. Check again."))
    }

    private func status(_ invocation: StandMixerClaudeInvocation, timeout: TimeInterval,
                        workingDirectory: URL? = nil) async throws -> StandMixerClaudeConnectionReport {
        let result = try await run(invocation, arguments: ["auth", "status", "--json"], timeout: timeout,
                                   maximumBytes: 64 * 1024, workingDirectory: workingDirectory)
        try Task.checkCancellation()
        return Self.parse(result, cliPath: invocation.executable.path)
    }

    private func run(_ invocation: StandMixerClaudeInvocation, arguments: [String], timeout: TimeInterval,
                     maximumBytes: Int, workingDirectory: URL? = nil) async throws -> ClaudeConnectionProcess.Result {
        let process = ClaudeConnectionProcess()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await process.run(invocation, arguments: arguments, environment: invocation.environment(from: service.environment),
                                         timeout: timeout, maximumBytes: maximumBytes, workingDirectory: workingDirectory ?? invocation.home)
        }, onCancel: { process.stop(.cancelled) })
    }

    static func parse(_ result: ClaudeConnectionProcess.Result, cliPath: String) -> StandMixerClaudeConnectionReport {
        func unavailable(_ detail: String = "Claude did not return a recognized subscription sign-in status. Check the official CLI, then try again.") -> StandMixerClaudeConnectionReport {
            .init(state: .unavailable, detail: detail, cliPath: cliPath)
        }
        guard !result.overflow, result.exitCode == 0 || result.exitCode == 1,
              let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let loggedIn = object["loggedIn"] as? NSNumber, CFGetTypeID(loggedIn) == CFBooleanGetTypeID() else { return unavailable() }
        if !loggedIn.boolValue {
            return .init(state: .signInRequired, detail: "Claude Code reports that this profile needs sign-in. Choose Connect Claude to use its official sign-in flow.", cliPath: cliPath)
        }
        guard result.exitCode == 0 else { return unavailable() }
        guard object["authMethod"] as? String == "claude.ai",
              object["apiProvider"] == nil || object["apiProvider"] as? String == "firstParty" else {
            return unavailable("This CLI reports API or provider authentication instead of a Claude subscription connection. Use the official Claude Code subscription sign-in, then check again.")
        }
        if let expiry = expiry(object["loginExpiresAt"]), expiry <= Date() {
            return .init(state: .signInRequired, detail: "Claude Code reports that this profile's sign-in has expired. Choose Connect Claude to sign in again.", cliPath: cliPath)
        }
        return .init(state: .connected, detail: "Claude is connected for Codex through the official Claude Code CLI. No model request was made.",
                     cliPath: cliPath)
    }

    private static func expiry(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0 {
            let epoch = number.doubleValue
            return Date(timeIntervalSince1970: epoch >= 100_000_000_000 ? epoch / 1000 : epoch)
        }
        guard let string = value as? String else { return nil }
        let format = ISO8601DateFormatter()
        if let date = format.date(from: string) { return date }
        format.formatOptions.insert(.withFractionalSeconds)
        return format.date(from: string)
    }

    private func remembered() throws -> StandMixerClaudeInvocation? {
        // Only StandMixer's own bounded launch preference is read. Never inspect CLI auth files.
        guard (try? service.checkNoSymlink(preferenceURL)) != nil else {
            throw StandMixerError.invalid("StandMixer could not safely read the saved Claude connection. Its profile was not changed.")
        }
        guard FileManager.default.fileExists(atPath: preferenceURL.path) else { return nil }
        guard
              let attributes = try? FileManager.default.attributesOfItem(atPath: preferenceURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16_384,
              let data = try? Data(contentsOf: preferenceURL),
              let invocation = try? JSONDecoder().decode(StandMixerClaudeInvocation.self, from: data),
              invocation.valid, invocation.home == service.home else {
            throw StandMixerError.invalid("StandMixer could not read the saved Claude connection. Its profile was not changed.")
        }
        return invocation
    }

    private func preferenceFailure(_ invocation: StandMixerClaudeInvocation) -> StandMixerClaudeConnectionReport {
        .init(state: .unavailable, detail: "Claude is signed in, but StandMixer could not save this connection. Recheck to try again.", cliPath: invocation.executable.path)
    }

    private func remembered(for invocation: StandMixerClaudeInvocation) throws -> StandMixerClaudeInvocation? {
        let existing = try remembered()
        guard existing?.sharesProfile(with: invocation) != false else {
            throw StandMixerError.invalid("The selected Claude profile changed during this check. Recheck the connection.")
        }
        return existing
    }

    private func remember(_ invocation: StandMixerClaudeInvocation) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(500)
        while true {
            try Task.checkCancellation()
            if try remembered(for: invocation) == invocation { return true }
            do {
                return try service.withOperationLock {
                    try Task.checkCancellation()
                    if try remembered(for: invocation) == invocation { return true }
                    return (try? service.write(JSONEncoder().encode(invocation), to: preferenceURL, mode: 0o600)) != nil
                }
            } catch StandMixerError.conflict {
                try Task.checkCancellation()
                let now = clock.now
                // A checked replacement can use an already bound profile while its path update is busy.
                guard now < deadline else { return try remembered(for: invocation) != nil }
                try await Task.sleep(until: min(now + .milliseconds(25), deadline), clock: clock)
            }
        }
    }
}

/// One owned process group per probe/login. Adapted from Sketchwright's InvocationProcessGroup:
/// retain the exited leader until all signaling is done, so its group ID cannot be recycled.
final class ClaudeConnectionProcess: @unchecked Sendable {
    enum Failure: Error { case cancelled, timedOut, launchFailed }
    struct Result: Sendable {
        var output: Data
        var exitCode: Int32?
        var overflow: Bool
    }
    private struct State {
        var group: ClaudeConnectionProcessGroup?
        var stopped: Failure?
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func stop(_ reason: Failure) {
        let group = state.withLock { value -> ClaudeConnectionProcessGroup? in
            guard !value.finished else { return nil }
            if value.stopped == nil { value.stopped = reason }
            return value.group
        }
        guard let group else { return }
        group.signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { group.signal(SIGKILL) }
    }

    func run(_ invocation: StandMixerClaudeInvocation, arguments: [String], environment: [String: String],
             timeout: TimeInterval, maximumBytes: Int, workingDirectory: URL) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { continuation.resume(returning: try execute(invocation, arguments: arguments, environment: environment,
                                                                timeout: timeout, maximumBytes: maximumBytes, workingDirectory: workingDirectory)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func execute(_ invocation: StandMixerClaudeInvocation, arguments: [String], environment: [String: String],
                         timeout: TimeInterval, maximumBytes: Int, workingDirectory: URL) throws -> Result {
        guard !state.withLock({ $0.stopped != nil }) else { throw CancellationError() }
        let stdout = Pipe(), stderr = Pipe()
        defer { try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close() }
        let stdoutDescriptor = stdout.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderr.fileHandleForReading.fileDescriptor
        for descriptor in [stdoutDescriptor, stderrDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.launchFailed }
        }
        let group = try ClaudeConnectionProcessGroup.spawn(invocation, arguments: arguments, environment: environment,
                                                           directory: workingDirectory, stdout: stdout, stderr: stderr)
        let stopReason = state.withLock { value -> Failure? in value.group = group; return value.stopped }
        if let stopReason { stop(stopReason) }
        let timer = DispatchWorkItem { [self] in stop(.timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        let capture = ClaudeConnectionCapture(limit: maximumBytes)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { [self] in
            defer { readers.leave() }
            drain(stdoutDescriptor, capture: maximumBytes > 0 ? capture : nil)
        }
        readers.enter()
        DispatchQueue.global().async { [self] in
            defer { readers.leave() }
            drain(stderrDescriptor, capture: nil)
        }
        group.observeExit()
        // Cleanup also runs after a wrapper exits normally with detached-in-group children.
        if group.isRunning {
            group.signal(SIGTERM)
            let killAt = ProcessInfo.processInfo.systemUptime + 0.4
            while group.isRunning {
                if ProcessInfo.processInfo.systemUptime >= killAt { group.signal(SIGKILL) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let exitCode = group.reap()
        state.withLock { $0.group = nil }
        readers.wait()
        let stopped = state.withLock { value -> Failure? in
            value.finished = true; return value.stopped
        }
        if let stopped {
            if case .cancelled = stopped { throw CancellationError() }
            throw stopped
        }
        return .init(output: capture.data, exitCode: exitCode, overflow: capture.overflow)
    }

    private func drain(_ descriptor: Int32, capture: ClaudeConnectionCapture?) {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            // After reaping, take the remaining buffered stdout up to the capture bound.
            // Descendants outside the group can still have a pipe open, so EOF is optional.
            let groupFinished = state.withLock { $0.group == nil }
            if groupFinished, capture == nil || capture?.overflow == true { return }
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 {
                if let capture, !capture.overflow { capture.append(Data(bytes.prefix(count))) }
                continue
            }
            if count == 0 { return }
            let readError = errno
            if readError == EINTR { continue }
            guard !groupFinished, readError == EAGAIN || readError == EWOULDBLOCK else { return }
            // Bound the wait so a quiet writer cannot delay observing group completion.
            if poll(&event, 1, 50) < 0, errno != EINTR { return }
        }
    }
}

private final class ClaudeConnectionCapture: @unchecked Sendable {
    let limit: Int
    var data = Data()
    var overflow = false
    init(limit: Int) { self.limit = limit }
    // Exactly one drain task writes; the dispatch group joins before the owner reads.
    func append(_ bytes: Data) {
        let room = max(0, limit - data.count)
        if bytes.count > room { overflow = true }
        data.append(bytes.prefix(room))
    }
}

private final class ClaudeConnectionProcessGroup: Sendable {
    private let leader: pid_t
    private enum LeaderState { case running, exited, released }
    private let state = OSAllocatedUnfairLock(initialState: LeaderState.running)
    private init(leader: pid_t) { self.leader = leader }

    static func spawn(_ invocation: StandMixerClaudeInvocation, arguments: [String], environment: [String: String],
                      directory: URL, stdout: Pipe, stderr: Pipe) throws -> ClaudeConnectionProcessGroup {
        let writeHandles = [stdout.fileHandleForWriting, stderr.fileHandleForWriting]
        defer { for handle in writeHandles { try? handle.close() } }
        guard invocation.valid, directory.isFileURL, !directory.path.utf8.contains(0) else { throw ClaudeConnectionProcess.Failure.launchFailed }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        if #available(macOS 26.0, *) { try checked(posix_spawn_file_actions_addchdir(&actions, directory.path)) }
        else { try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        for (source, target) in zip(writeHandles, [STDOUT_FILENO, STDERR_FILENO]) {
            try checked(posix_spawn_file_actions_adddup2(&actions, source.fileDescriptor, target))
        }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGCHLD] { sigaddset(&defaults, signal) }
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        var child: pid_t = 0
        try withCStringArray([invocation.executable.path] + arguments) { argv in
            try withCStringArray(environment.map { "\($0.key)=\($0.value)" }) { envp in
                try checked(posix_spawn(&child, invocation.executable.path, &actions, &attributes, argv, envp))
            }
        }
        return .init(leader: child)
    }

    func observeExit() {
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
        let observed = result == 0
        state.withLock { $0 = observed ? .exited : .released }
    }

    var isRunning: Bool {
        state.withLock { status in
            guard status != .released, leader > 1 else { return false }
            if kill(-leader, 0) == 0 { return true }
            if errno == ESRCH { return false }
            guard errno == EPERM, status == .exited else { return true }
            var members = [pid_t](repeating: 0, count: 2)
            let bytes = members.withUnsafeMutableBufferPointer {
                proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(leader), $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
            }
            return bytes != MemoryLayout<pid_t>.stride || members[0] != leader
        }
    }

    func signal(_ number: Int32) {
        state.withLock { status in if status != .released, leader > 1 { _ = kill(-leader, number) } }
    }

    func reap() -> Int32? {
        state.withLock { leaderState in
            guard leaderState == .exited else { return nil }
            var status: Int32 = 0, pid: pid_t
            repeat { pid = waitpid(leader, &status, 0) } while pid == -1 && errno == EINTR
            leaderState = .released
            return pid == leader && status & 0x7f == 0 ? (status >> 8) & 0xff : nil
        }
    }

    private static func checked(_ code: Int32) throws {
        if code != 0 { throw ClaudeConnectionProcess.Failure.launchFailed }
    }
    private static func withCStringArray<T>(_ values: [String],
                                            _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        guard values.allSatisfy({ !$0.utf8.contains(0) }) else { throw ClaudeConnectionProcess.Failure.launchFailed }
        var pointers = values.map { strdup($0) }
        defer { pointers.compactMap { $0 }.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw ClaudeConnectionProcess.Failure.launchFailed }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
}
