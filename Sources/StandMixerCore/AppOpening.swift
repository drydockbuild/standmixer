import CryptoKit
import Darwin
import Foundation

public struct StandMixerWebOpening: Codable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}

public struct StandMixerInstalledMac: Codable, Sendable {
    public var isAvailable: Bool
    public var appPath: String?
    public var detail: String
    public init(isAvailable: Bool, appPath: String? = nil, detail: String) {
        self.isAvailable = isAvailable; self.appPath = appPath; self.detail = detail
    }
}

public enum StandMixerAppOpeningError: LocalizedError, Sendable {
    case webUnavailable, invalidSession, appUnavailable, unsafeApp, failed, fixtureDisabled
    public var code: String {
        switch self {
        case .webUnavailable: return "webUnavailable"
        case .invalidSession: return "invalidWebSession"
        case .appUnavailable: return "appUnavailable"
        case .unsafeApp: return "unsafeApp"
        case .failed: return "openFailed"
        case .fixtureDisabled: return "fixtureDisabled"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .webUnavailable: return "The owned StandMixer web launcher is unavailable or modified. Reinstall the complete package from your trusted checkout."
        case .invalidSession: return "The web launcher did not return a valid private loopback session. No browser was opened."
        case .appUnavailable: return "The owned StandMixer Mac app is unavailable. Choose Install Mac app first."
        case .unsafeApp: return "The installed Mac app or its ownership receipt changed. It was kept and was not opened."
        case .failed: return "StandMixer could not open the selected interface. Check the local installation and try again."
        case .fixtureDisabled: return "Opening an interface is disabled in fixture mode. No application or web server was started."
        }
    }
}

/// Explicit interface actions only. No browser launches, account reads, inference,
/// request-selected paths, or native configuration transactions are involved.
public enum StandMixerAppOpening {
    public static func installedMac(service: IntegrationService) -> StandMixerInstalledMac {
        do {
            let app = try validatedApp(service: service)
            return .init(isAvailable: true, appPath: app.path, detail: "An owned Mac app is installed. Its signature is checked when opened.")
        } catch StandMixerAppOpeningError.appUnavailable {
            return .init(isAvailable: false, detail: "Install the optional StandMixer Mac app to open a separate window.")
        } catch {
            return .init(isAvailable: false, detail: "The installed Mac app could not be verified. Existing files were kept.")
        }
    }

    public static func openWeb(service: IntegrationService) async throws -> StandMixerWebOpening {
        guard !service.metadataOnlyDiscovery else { throw StandMixerAppOpeningError.fixtureDisabled }
        let bin = service.applicationSupport.appendingPathComponent("bin")
        let launcher = bin.appendingPathComponent("open-codex-ui")
        do {
            for directory in [service.applicationSupport, bin] {
                var information = stat()
                guard lstat(directory.path, &information) == 0,
                      information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), information.st_uid == getuid(),
                      information.st_mode & mode_t(0o022) == 0 else { throw StandMixerAppOpeningError.webUnavailable }
            }
            try service.checkNoSymlink(launcher)
            let bytes = try StandMixerMacInstaller.readOwned(launcher, maximum: 16 * 1024, executable: true)
            let receipt = bin.appendingPathComponent(".codex-ui-launcher.sha256")
            try service.checkNoSymlink(receipt)
            let recorded = try StandMixerMacInstaller.readOwned(receipt, maximum: 128)
            guard bytes.starts(with: Data("#!/bin/sh\n# Managed by StandMixer\n".utf8)),
                  recorded == Data((digest(bytes) + "\n").utf8) else { throw StandMixerAppOpeningError.webUnavailable }
        } catch { throw StandMixerAppOpeningError.webUnavailable }
        let output = try await run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [launcher.path],
                                   service: service, maximumBytes: 2048, timeout: 20)
        return try webSession(output)
    }

    public static func openMac(service: IntegrationService) async throws -> ApplyResult {
        guard !service.metadataOnlyDiscovery else { throw StandMixerAppOpeningError.fixtureDisabled }
        let app = try validatedApp(service: service)
        _ = try await run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                          arguments: ["--verify", "--deep", "--strict", app.path], service: service)
        // Recheck the receipt/hash after signature verification and before opening.
        guard try validatedApp(service: service) == app else { throw StandMixerAppOpeningError.unsafeApp }
        _ = try await run(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [app.path], service: service)
        return .init(message: "Opened StandMixer in its Mac app.", changedFiles: 0)
    }

    static func webSession(_ bytes: Data) throws -> StandMixerWebOpening {
        guard bytes.count <= 2048,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["url", "pid", "idleTimeoutSeconds"],
              let text = object["url"] as? String, let url = URLComponents(string: text),
              url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port),
              url.path == "/", url.user == nil, url.password == nil, url.query == nil,
              let fragment = url.fragment, fragment.hasPrefix("token="), fragment.dropFirst(6).count == 43,
              fragment.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let pid = object["pid"] as? Int, pid > 0,
              let lifetime = object["idleTimeoutSeconds"] as? Int, lifetime > 0, lifetime <= 86400 else {
            throw StandMixerAppOpeningError.invalidSession
        }
        return .init(url: text)
    }

    static func validatedApp(service: IntegrationService) throws -> URL {
        let receipt = service.applicationSupport.appendingPathComponent("mac-app.receipt")
        let text: String
        do {
            try service.checkNoSymlink(receipt)
            guard let value = String(data: try StandMixerMacInstaller.readOwned(receipt, maximum: 8192), encoding: .utf8) else { throw StandMixerAppOpeningError.unsafeApp }
            text = value
        } catch StandMixerMacInstallerError.unavailable { throw StandMixerAppOpeningError.appUnavailable }
        catch { throw StandMixerAppOpeningError.unsafeApp }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 3, lines[2].isEmpty, lines[0].hasPrefix("/"),
              !lines[0].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              lines[1].count == 64, lines[1].allSatisfy({ "0123456789abcdef".contains($0) }) else { throw StandMixerAppOpeningError.unsafeApp }
        let app = URL(fileURLWithPath: String(lines[0])).standardizedFileURL
        guard app.lastPathComponent == "StandMixer.app" else { throw StandMixerAppOpeningError.unsafeApp }
        let binary = app.appendingPathComponent("Contents/MacOS/StandMixer")
        do {
            try service.checkNoSymlink(binary)
            for directory in [app, app.appendingPathComponent("Contents"), binary.deletingLastPathComponent()] {
                var information = stat()
                guard lstat(directory.path, &information) == 0,
                      information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), information.st_uid == getuid(),
                      information.st_mode & mode_t(0o022) == 0 else { throw StandMixerAppOpeningError.unsafeApp }
            }
            let bytes = try StandMixerMacInstaller.readOwned(binary, maximum: 32 * 1024 * 1024, executable: true)
            guard digest(bytes) == lines[1] else { throw StandMixerAppOpeningError.unsafeApp }
            let infoURL = app.appendingPathComponent("Contents/Info.plist")
            try service.checkNoSymlink(infoURL)
            let infoBytes = try StandMixerMacInstaller.readOwned(infoURL, maximum: 64 * 1024)
            let info = try PropertyListSerialization.propertyList(from: infoBytes, options: [], format: nil) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == "build.drydock.StandMixer",
                  info?["CFBundleExecutable"] as? String == "StandMixer" else { throw StandMixerAppOpeningError.unsafeApp }
        } catch { throw StandMixerAppOpeningError.unsafeApp }
        return app
    }

    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func run(executable: URL, arguments: [String], service: IntegrationService,
                            maximumBytes: Int = 4096, timeout: TimeInterval = 10) async throws -> Data {
        let process = InspectionProcess(maximumBytes: maximumBytes, failureMessage: StandMixerAppOpeningError.failed.localizedDescription)
        let keys: Set<String> = ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"]
        var environment = service.environment.filter { keys.contains($0.key) }
        environment["HOME"] = service.home.path
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let isolated = environment
        do {
            return try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await process.run(executable: executable, arguments: arguments, environment: isolated,
                    cwd: service.home, input: URL(fileURLWithPath: "/dev/null"), timeout: timeout)
            }, onCancel: { process.cancel() })
        } catch is CancellationError { throw CancellationError() }
        catch { throw StandMixerAppOpeningError.failed }
    }
}
