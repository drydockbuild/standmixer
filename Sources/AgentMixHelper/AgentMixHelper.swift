import AgentMixCore
import Darwin
import Foundation

@main
struct AgentMixHelper {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var testHome: URL?
        var uiRoot: String?
        let detachedUI = arguments.contains("--detached-ui")
        arguments.removeAll { $0 == "--detached-ui" }
        for flag in ["--test-home", "--ui-root"] {
            if let index = arguments.firstIndex(of: flag) {
                guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/"),
                      arguments.filter({ $0 == flag }).count == 1 else {
                    writeFailure("Use \(flag) with one absolute directory."); exit(2)
                }
                if flag == "--test-home" { testHome = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL }
                else { uiRoot = arguments[index + 1] }
                arguments.removeSubrange(index...index + 1)
            }
        }
        if arguments.first == "--installer-marketplace-source" {
            guard [2, 3].contains(arguments.count), uiRoot == nil, !detachedUI,
                  let platform = AgentPlatform(rawValue: arguments[1]) else {
                fputs("Use --installer-marketplace-source codex|claude [drydock-standmixer|drydock-agentmix].\n", stderr); exit(2)
            }
            do {
                let input = try readInput(maximum: AgentMixInstallerMarketplaceSource.maximumInputBytes)
                guard let source = try AgentMixInstallerMarketplaceSource.source(in: input, platform: platform,
                    marketplace: arguments.count == 3 ? arguments[2] : "drydock-agentmix") else { exit(3) }
                print(source); exit(0)
            } catch {
                fputs("The drydock-agentmix marketplace metadata is invalid, ambiguous, or remote. No registration was changed.\n", stderr); exit(2)
            }
        }
        if arguments.first == "--installer-codex-package" {
            guard arguments.count == 3, uiRoot == nil, !detachedUI,
                  ["prepare", "check", "canonical-check"].contains(arguments[1]) else {
                fputs("Use --installer-codex-package prepare|check|canonical-check /absolute/registered/root.\n", stderr); exit(2)
            }
            do {
                let migrationHome = testHome?.resolvingSymlinksInPath() ?? FileManager.default.homeDirectoryForCurrentUser
                let codexHome = testHome == nil ? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } : nil
                let migration = InstallerPluginMigration(home: migrationHome, codexHome: codexHome)
                let input = try readInput(maximum: 1_048_576)
                switch arguments[1] {
                case "prepare":
                    let plan = try migration.prepare(metadata: input, registeredRoot: arguments[2])
                    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(plan) + Data([10]))
                case "check": try migration.recheck(metadata: input, registeredRoot: arguments[2])
                default: try migration.checkCanonical(metadata: input, registeredRoot: arguments[2])
                }
                exit(0)
            } catch { fputs("StandMixer: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if detachedUI {
            guard arguments == ["--serve-ui"], setsid() >= 0 else {
                writeFailure("Detached mode is available only for a new local UI service."); exit(2)
            }
            signal(SIGHUP, SIG_IGN)
        }
        let home = testHome ?? FileManager.default.homeDirectoryForCurrentUser
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if arguments.first == "--session-url" {
            guard arguments.count == 2 else { exit(2) }
            do { print(try AgentMixPanelSession.read(arguments[1])); exit(0) }
            catch { fputs("The private StandMixer panel session is invalid.\n", stderr); exit(1) }
        }
        if arguments == ["--bootstrap"] {
            do { print(try EngineBootstrap.install(source: executable, home: home).path); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        let environment = testHome == nil ? ProcessInfo.processInfo.environment : [:]
        let service = IntegrationService(home: home, environment: environment, executableURL: executable,
                                         metadataOnlyDiscovery: testHome != nil)
        let fixtureConnections: [ConnectionStatus]? = testHome.map { home in
            AgentPlatform.allCases.map { platform in
                let path = home.appendingPathComponent(".local/bin/\(platform.rawValue)")
                let exists = FileManager.default.isExecutableFile(atPath: path.path)
                return .init(platform: platform, path: exists ? path.path : nil, version: nil,
                             detail: "Isolated fixture CLI metadata; no executable is launched.", isInstalled: exists)
            }
        }
        let fixtureReader: (@Sendable (AgentPlatform) async throws -> AgentImportProposal)?
        let fixtureInstaller: (@Sendable () async throws -> ApplyResult)?
        if testHome == nil { fixtureReader = nil; fixtureInstaller = nil }
        else {
            fixtureReader = { _ in throw AgentImportError.failed("Fixture inspection is disabled. No observer model was started.") }
            fixtureInstaller = { throw AgentMixMacInstallerError.fixtureDisabled }
        }
        let interface = AgentMixModInterface(service: service, connections: fixtureConnections,
                                            inspectionReader: fixtureReader, macInstaller: fixtureInstaller)
        if arguments == ["--mcp"] || arguments == ["--serve-ui"] {
            do {
                let assets = try AgentMixUIAssets.resolve(explicitPath: uiRoot, executable: executable)
                let engine = AgentMixUIEngine(interface: interface)
                if arguments == ["--mcp"] {
                    let stdio = AgentMixMCPStdio(server: .init(engine: engine, assets: assets))
                    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
                    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
                    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
                    // Cancellation invokes the observer's synchronous owned
                    // process-group cleanup before this helper terminates.
                    termination.setEventHandler { stdio.cancelAll(); exit(0) }
                    interruption.setEventHandler { stdio.cancelAll(); exit(0) }
                    termination.resume(); interruption.resume()
                    try await stdio.run()
                    termination.cancel(); interruption.cancel()
                } else {
                    let server = try AgentMixHTTPUIServer(engine: engine, assets: assets)
                    let url = try await server.start()
                    let output = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString, "pid": ProcessInfo.processInfo.processIdentifier,
                                                                           "idleTimeoutSeconds": Int(AgentMixHTTPUIServer.idleLifetime)], options: [.sortedKeys])
                    try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
                    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
                    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
                    let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
                    termination.setEventHandler { server.stop() }; interruption.setEventHandler { server.stop() }
                    termination.resume(); interruption.resume()
                    await server.waitUntilStopped()
                    termination.cancel(); interruption.cancel()
                }
                exit(0)
            } catch {
                fputs("StandMixer embedded panel: \(error.localizedDescription)\n", stderr); exit(1)
            }
        }
        guard uiRoot == nil else { writeFailure("--ui-root is used only with --mcp or --serve-ui."); exit(2) }
        if arguments.first == "--standmixer" {
            let available = fixtureConnections.map { Set($0.filter(\.isInstalled).map(\.platform)) }
            let response = await AgentMixCommandInterface.run(arguments: Array(arguments.dropFirst()), service: service, availablePlatforms: available)
            if response.openSettings { print("Open the StandMixer panel with /standmixer in Claude Code. Use the installed StandMixer Mac app for its own settings.") }
            else { print(response.text) }
            exit(response.exitCode)
        }
        guard arguments.isEmpty else {
            writeFailure("AgentMixHelper accepts JSON on stdin, --standmixer <command>, --mcp, or --serve-ui."); exit(2)
        }
        do {
            // readToEnd is intentionally avoided: an invalid sender cannot
            // make this small configuration helper allocate unbounded input.
            let input = try readInput(maximum: AgentMixModInterface.maximumRequestBytes)
            let requestData = input
            let operation = Task { await interface.runJSON(requestData) }
            // Native host cancellation/timeout must also stop the observer's
            // owned process group, through its existing Task cancellation hook.
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            termination.setEventHandler { operation.cancel() }
            interruption.setEventHandler { operation.cancel() }
            termination.resume(); interruption.resume()
            let result = await operation.value
            termination.cancel(); interruption.cancel()
            try FileHandle.standardOutput.write(contentsOf: result.output + Data([10]))
            exit(result.exitCode)
        } catch {
            writeFailure("StandMixer could not read the JSON request or write its response."); exit(1)
        }
    }

    private static func readInput(maximum: Int) throws -> Data {
        var input = Data()
        while input.count <= maximum {
            let chunk = try FileHandle.standardInput.read(upToCount: min(16 * 1024, maximum + 1 - input.count)) ?? Data()
            if chunk.isEmpty { break }
            input.append(chunk)
        }
        return input
    }

    private static func writeFailure(_ message: String) {
        let object: [String: Any] = ["ok": false, "error": ["code": "invalidRequest", "message": message]]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
    }
}
