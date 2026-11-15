import CoreFoundation
import Foundation

public enum StandMixerCLIAccountState: String, Codable, Sendable {
    case signedIn, signedOut, unknown
}

/// An ephemeral report from a selected CLI's public status command, never a
/// Desktop app account, model entitlement, usage limit, or credential snapshot.
public struct StandMixerCLIAccount: Codable, Sendable {
    public var platform: AgentPlatform
    public var status: StandMixerCLIAccountState
    public var email: String?
    public var subscription: String?
    public var detail: String
    public var cliPath: String?
    public init(platform: AgentPlatform, status: StandMixerCLIAccountState, email: String? = nil,
                subscription: String? = nil, detail: String, cliPath: String? = nil) {
        self.platform = platform; self.status = status; self.email = email
        self.subscription = subscription; self.detail = detail; self.cliPath = cliPath
    }
}

public struct StandMixerModAccounts: Codable, Sendable {
    public var checkedAt: Date
    public var providers: [StandMixerCLIAccount]
    public init(checkedAt: Date = Date(), providers: [StandMixerCLIAccount]) {
        self.checkedAt = checkedAt; self.providers = providers
    }
}

public enum StandMixerAccountChecker {
    public static let maximumDuration: TimeInterval = 10
    public static let maximumOutputBytes = 64 * 1024
    typealias StatusRunner = @Sendable (AgentPlatform, URL, [String], [String: String], URL, TimeInterval) async throws -> InspectionProcess.Capture

    public static func check(service: IntegrationService) async throws -> StandMixerModAccounts {
        try await check(service: service, executables: nil, runner: nil)
    }

    static func check(service: IntegrationService, executables: [AgentPlatform: URL]?, runner: StatusRunner?,
                      timeout: TimeInterval = maximumDuration) async throws -> StandMixerModAccounts {
        try Task.checkCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + min(maximumDuration, max(0.01, timeout))
        guard !service.metadataOnlyDiscovery || runner != nil else {
            return .init(providers: AgentPlatform.allCases.map {
                .init(platform: $0, status: .unknown, detail: "CLI account checks are disabled in fixture mode. No status command was started.")
            })
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("standmixer-account-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        var environment = AgentImportService.inspectionEnvironment(from: service.environment)
        environment["HOME"] = service.home.path
        environment["CODEX_HOME"] = service.codexHome.path
        environment["CLAUDE_CONFIG_DIR"] = service.claudeHome.path
        environment["LC_ALL"] = "C"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        if environment["PATH"]?.isEmpty != false { environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" }
        let launchEnvironment = environment
        let statusRunner = runner ?? runStatus
        let reports = try await withThrowingTaskGroup(of: StandMixerCLIAccount.self) { group in
            for platform in AgentPlatform.allCases {
                group.addTask {
                    try Task.checkCancellation()
                    var selectedPath: String?
                    do {
                        // Preserve the active/newest verified policy, with at most four
                        // concurrent probes across both providers and no account fallback.
                        let selected: URL?
                        if let executables { selected = executables[platform] }
                        else if service.metadataOnlyDiscovery { selected = nil }
                        else { selected = try await service.cliDiscovery.select(platform, deadline: deadline)?.executable }
                        try Task.checkCancellation()
                        let remaining = deadline - ProcessInfo.processInfo.systemUptime
                        guard remaining > 0 else { throw AgentImportError.timedOut(timeout) }
                        guard let executable = selected else {
                            return .init(platform: platform, status: .unknown, detail: "No working CLI could be verified in known installation locations. Install or repair it, then check again.")
                        }
                        selectedPath = executable.path
                        let arguments = platform == .claude ? ["auth", "status", "--json"] : ["login", "status"]
                        let output = try await statusRunner(platform, executable, arguments, launchEnvironment, staging, remaining)
                        try Task.checkCancellation()
                        return parse(output, platform: platform, cliPath: executable.path)
                    } catch is CancellationError { throw CancellationError() }
                    catch AgentImportError.timedOut {
                        return .init(platform: platform, status: .unknown, detail: "CLI verification and public sign-in status exceeded this check's time budget and were stopped. Retry this check or use the CLI's status command in Terminal.", cliPath: selectedPath)
                    } catch {
                        return .init(platform: platform, status: .unknown, detail: "The selected CLI's public sign-in status could not be checked. Update the CLI or run its status command in Terminal. No account was changed.", cliPath: selectedPath)
                    }
                }
            }
            var results: [StandMixerCLIAccount] = []
            for try await report in group { results.append(report) }
            return AgentPlatform.allCases.compactMap { platform in results.first { $0.platform == platform } }
        }
        return .init(providers: reports)
    }

    private static func runStatus(_ platform: AgentPlatform, _ executable: URL, _ arguments: [String],
                                  _ environment: [String: String], _ cwd: URL, _ timeout: TimeInterval) async throws -> InspectionProcess.Capture {
        // Two separately drained streams share a strict 64 KiB retained bound.
        let process = InspectionProcess(maximumBytes: maximumOutputBytes / 2)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await process.runCaptured(executable: executable, arguments: arguments,
                environment: environment, cwd: cwd, input: URL(fileURLWithPath: "/dev/null"), timeout: timeout)
        }, onCancel: { process.cancel() })
    }

    static func parse(_ output: InspectionProcess.Capture, platform: AgentPlatform, cliPath: String) -> StandMixerCLIAccount {
        func unknown(_ detail: String = "This CLI did not return a recognized public sign-in status. Identity is unknown; no account was changed.") -> StandMixerCLIAccount {
            .init(platform: platform, status: .unknown, detail: detail, cliPath: cliPath)
        }
        guard !output.outputOverflow, !output.diagnosticsOverflow,
              output.output.count + output.diagnostics.count <= maximumOutputBytes, output.exitCode >= 0 else {
            return unknown("The CLI status output exceeded its safe limit or did not complete normally. Identity is unknown; no account was changed.")
        }
        if platform == .claude {
            guard let object = try? JSONSerialization.jsonObject(with: output.output) as? [String: Any],
                  let loggedIn = object["loggedIn"] as? NSNumber,
                  CFGetTypeID(loggedIn) == CFBooleanGetTypeID() else { return unknown() }
            if !loggedIn.boolValue {
                return .init(platform: platform, status: .signedOut,
                    detail: "The selected Claude Code CLI reports that it is signed out when launched outside Claude Desktop. Desktop app accounts can differ; selecting its managed executable does not share the Desktop session.", cliPath: cliPath)
            }
            guard output.succeeded else { return unknown() }
            let method = (object["authMethod"] as? String ?? "").lowercased()
            if ["api_key", "api-key", "apikey"].contains(method) {
                return .init(platform: platform, status: .signedIn,
                    detail: "The selected Claude Code CLI reports API key authentication. Account email and subscription are unavailable; Desktop app accounts can differ.", cliPath: cliPath)
            }
            return .init(platform: platform, status: .signedIn, email: safeEmail(object["email"]),
                subscription: safeSubscription(object["subscriptionType"]),
                detail: "The selected Claude Code CLI reports that it is signed in. Desktop app accounts can differ. This does not check usage limits or model access.", cliPath: cliPath)
        }
        // Some Codex versions write status to stderr and can include a masked
        // or full API key. Match fixed status phrases and never return the text.
        let lines = String(decoding: output.output + Data([10]) + output.diagnostics, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if output.succeeded, lines.contains(where: { $0.hasPrefix("logged in using chatgpt") }) {
            return .init(platform: platform, status: .signedIn,
                detail: "The selected Codex CLI reports ChatGPT sign-in. Its public status command does not provide account email or subscription; Desktop app accounts can differ.", cliPath: cliPath)
        }
        if output.succeeded, lines.contains(where: {
            $0.hasPrefix("logged in using an api key") || $0.hasPrefix("logged in using api key") || $0.hasPrefix("logged in using apikey")
        }) {
            return .init(platform: platform, status: .signedIn,
                detail: "The selected Codex CLI reports API key authentication. Its public status command does not provide account email or subscription; Desktop app accounts can differ.", cliPath: cliPath)
        }
        if lines.contains(where: { $0 == "not logged in" || $0 == "not signed in" || $0 == "logged out" }) {
            return .init(platform: platform, status: .signedOut,
                detail: "The selected Codex CLI reports that it is signed out. Desktop app accounts can differ.", cliPath: cliPath)
        }
        return unknown()
    }

    private static func safeEmail(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 254,
              text.range(of: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[A-Z0-9](?:[A-Z0-9.-]{0,251}[A-Z0-9])?$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return text
    }
    private static func safeSubscription(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let recognized = ["free", "pro", "max", "ultra", "team", "teams", "enterprise", "api", "max_5x", "max_20x"]
        return recognized.contains(text.lowercased()) ? text : nil
    }
}
