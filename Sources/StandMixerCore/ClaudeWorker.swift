import Darwin
import Foundation

/// CLI entrypoints retain cancellation ownership while official login/status commands run.
/// Settings APIs themselves do not install process-wide signal handlers.
public enum StandMixerCommandHost {
    public static func run(arguments: [String], service: IntegrationService,
                           availablePlatforms: Set<AgentPlatform>? = nil) async -> StandMixerCommandResponse {
        do {
            return try await cancellable {
                await StandMixerCommandInterface.run(arguments: arguments, service: service, availablePlatforms: availablePlatforms)
            }
        } catch { return .init("StandMixer command cancelled.", exitCode: 130) }
    }

    static func cancellable<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        termination.setEventHandler { task.cancel() }; interruption.setEventHandler { task.cancel() }
        termination.resume(); interruption.resume()
        defer {
            termination.cancel(); interruption.cancel()
            signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

/// An explicit worker invocation uses the same checked CLI profile. execve preserves the
/// caller's working directory, streams, permissions, and native job completion handle.
public enum StandMixerClaudeWorker {
    public static func workerArguments(_ arguments: [String]) throws -> [String] {
        guard arguments.first == "--", arguments.count >= 2 else {
            throw StandMixerError.invalid("Usage: standmixer run-claude -- -p <Claude worker arguments>")
        }
        let args = Array(arguments.dropFirst())
        let authOverrides = ["--settings", "--setting-sources", "--api-key", "--auth-token", "--base-url", "--console"]
        guard ["-p", "--print"].contains(args[0]), args.allSatisfy({ !$0.contains("\0") }),
              !args.contains(where: { arg in authOverrides.contains { arg == $0 || arg.hasPrefix($0 + "=") } }) else {
            throw StandMixerError.invalid("Use a print-mode worker with the linked Claude connection. Authentication/provider overrides require a separate native CLI invocation.")
        }
        return args
    }

    public static func run(arguments: [String], service: IntegrationService) async -> Int32 {
        do {
            let args = try workerArguments(arguments)
            guard !service.metadataOnlyDiscovery else { throw StandMixerError.invalid("Worker launches are disabled in fixture mode.") }
            let invocation = try await StandMixerCommandHost.cancellable {
                try await StandMixerClaudeConnectionService(service: service).resolveInvocation(
                    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            }
            try Task.checkCancellation()
            try replaceProcess(invocation, arguments: args, environment: invocation.workerEnvironment(from: service.environment))
        } catch is CancellationError {
            fputs("StandMixer: Claude connection check cancelled.\n", stderr); return 130
        } catch {
            fputs("StandMixer: \(error.localizedDescription)\n", stderr); return 1
        }
    }

    private static func replaceProcess(_ invocation: StandMixerClaudeInvocation, arguments: [String], environment: [String: String]) throws -> Never {
        let args = ([invocation.executable.path] + arguments).map { strdup($0) }
        let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        guard args.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else {
            throw StandMixerError.invalid("The Claude worker could not allocate its launch context.")
        }
        var argv = args + [nil], envp = env + [nil]
        invocation.executable.path.withCString { path in
            argv.withUnsafeMutableBufferPointer { a in
                envp.withUnsafeMutableBufferPointer { e in _ = execve(path, a.baseAddress!, e.baseAddress!) }
            }
        }
        throw StandMixerError.invalid("The checked Claude CLI could not start (system error \(errno)). Recheck Connect Claude for Codex in StandMixer.")
    }
}
