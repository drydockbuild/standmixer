import CryptoKit
import Darwin
import Foundation

public enum StandMixerMacInstallerError: LocalizedError, Sendable {
    case unavailable, unsafeLauncher, failed, timedOut, fixtureDisabled
    case failedWithDetails(String)

    private var retryCommand: String {
        "\"$HOME/Library/Application Support/StandMixer/bin/standmixer\" install-mac"
    }

    public var code: String {
        switch self {
        case .unavailable: return "installerUnavailable"
        case .unsafeLauncher: return "unsafeInstaller"
        case .failed, .failedWithDetails: return "installMacFailed"
        case .timedOut: return "installMacTimedOut"
        case .fixtureDisabled: return "fixtureDisabled"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The local Mac app installer is unavailable. Rerun install.sh from your trusted StandMixer checkout, then choose Install Mac app again."
        case .unsafeLauncher:
            return "The installed StandMixer launcher or its ownership receipt is unsafe or modified. It was kept. Review the local installation and rerun install.sh from your trusted checkout."
        case .failed:
            return "The Mac app installer stopped. Retry in Terminal to see the build details:\n" + retryCommand
        case .failedWithDetails(let details):
            return details + "\n\nRetry in Terminal:\n" + retryCommand
        case .timedOut:
            return "The Mac app build exceeded the panel's nine-minute limit and its build processes were stopped. Run in Terminal for the full build time:\n" + retryCommand
        case .fixtureDisabled:
            return "Mac app installation is disabled in fixture mode. No installer was started."
        }
    }
}

/// The panel can invoke only the installed, owned launcher with a fixed verb.
/// Source staging, toolchain checks, signing, and app deployment remain in the
/// trusted source installer; native model/settings transactions are independent.
public enum StandMixerMacInstaller {
    public static let maximumDuration: TimeInterval = 9 * 60
    static let launcherMarker = "# Managed by StandMixer: stable no-inference command launcher v1."

    public static func install(service: IntegrationService) async throws -> ApplyResult {
        try await install(service: service, timeout: maximumDuration)
    }

    // A shorter deadline is available only to in-module fixture tests.
    static func install(service: IntegrationService, timeout: TimeInterval) async throws -> ApplyResult {
        try Task.checkCancellation()
        guard !service.metadataOnlyDiscovery else { throw StandMixerMacInstallerError.fixtureDisabled }
        let launcher = try validatedLauncher(service: service)
        let process = InspectionProcess(maximumBytes: 4096, allowTruncatedOutput: true, retainOutputTail: true)
        let keys: Set<String> = ["PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"]
        var environment = service.environment.filter { keys.contains($0.key) }
        environment["HOME"] = service.home.path
        if environment["PATH"]?.isEmpty != false { environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" }
        let launchEnvironment = environment
        do {
            let capture = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await process.runCaptured(executable: launcher, arguments: ["install-mac"],
                    environment: launchEnvironment, cwd: launcher.deletingLastPathComponent(),
                    input: URL(fileURLWithPath: "/dev/null"), timeout: min(timeout, maximumDuration))
            }, onCancel: { process.cancel() })
            try Task.checkCancellation()
            guard capture.succeeded else {
                let output = [capture.output, capture.diagnostics]
                    .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                let reason = capture.exitCode < 0 ? "stopped by signal \(-capture.exitCode)" : "exited with code \(capture.exitCode)"
                throw StandMixerMacInstallerError.failedWithDetails("The Mac app installer \(reason)." + (output.isEmpty ? "" : "\n\nLast build output:\n" + output))
            }
        } catch is CancellationError { throw CancellationError() }
        catch AgentImportError.timedOut { throw StandMixerMacInstallerError.timedOut }
        catch let error as StandMixerMacInstallerError { throw error }
        catch { throw StandMixerMacInstallerError.failedWithDetails("The Mac app installer could not run: " + error.localizedDescription) }
        return .init(message: "Installed StandMixer in ~/Applications/StandMixer.app and opened it.", changedFiles: 0)
    }

    static func validatedLauncher(service: IntegrationService) throws -> URL {
        let support = service.applicationSupport
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        let launcher = bin.appendingPathComponent("standmixer")
        let receipt = bin.appendingPathComponent(".standmixer-launcher.sha256")
        guard !launcher.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw StandMixerMacInstallerError.unsafeLauncher
        }
        do { try service.checkNoSymlink(launcher); try service.checkNoSymlink(receipt) }
        catch { throw StandMixerMacInstallerError.unsafeLauncher }
        for directory in [support, bin] {
            var information = stat()
            guard lstat(directory.path, &information) == 0 else {
                if errno == ENOENT { throw StandMixerMacInstallerError.unavailable }
                throw StandMixerMacInstallerError.unsafeLauncher
            }
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), information.st_uid == getuid(),
                  information.st_mode & mode_t(0o022) == 0 else { throw StandMixerMacInstallerError.unsafeLauncher }
        }
        let source = try readOwned(launcher, maximum: 64 * 1024, executable: true)
        let recorded = try readOwned(receipt, maximum: 128)
        guard let text = String(data: source, encoding: .utf8), text.hasPrefix("#!/bin/sh\n" + launcherMarker + "\n"),
              let recordedHash = String(data: recorded, encoding: .utf8),
              recordedHash == SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() + "\n" else {
            throw StandMixerMacInstallerError.unsafeLauncher
        }
        return launcher
    }

    static func readOwned(_ url: URL, maximum: Int, executable: Bool = false) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw StandMixerMacInstallerError.unavailable }
            throw StandMixerMacInstallerError.unsafeLauncher
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == getuid(), information.st_nlink == 1,
              information.st_size > 0, information.st_size <= maximum, information.st_mode & mode_t(0o022) == 0,
              !executable || information.st_mode & mode_t(0o100) != 0 else { throw StandMixerMacInstallerError.unsafeLauncher }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw StandMixerMacInstallerError.unsafeLauncher }
        return data
    }
}
