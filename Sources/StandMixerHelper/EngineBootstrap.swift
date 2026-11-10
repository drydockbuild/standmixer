import CryptoKit
import Darwin
import Foundation

/// Explicit installation publishes the canonical command runtime separately
/// from the legacy shared helper that older cached plugins can still replace.
/// Kernel locking and matching payloads preserve interrupted-update recovery.
enum EngineBootstrap {
    static func install(source: URL, home: URL) throws -> URL {
        let directory = home.appendingPathComponent("Library/Application Support/StandMixer/runtime", isDirectory: true)
        try checkAncestors(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent(".engine-install.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw failure("The StandMixer engine install lock is unavailable.") }
        defer { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_uid == getuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_nlink == 1 else {
            throw failure("The StandMixer engine install lock is not a private regular file.")
        }
        let deadline = Date().addingTimeInterval(10)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN, Date() < deadline else { throw failure("Another StandMixer update is still running. Reopen StandMixer shortly.") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try checkAncestors(directory)
        let sourceBytes = try readRegular(source, maximum: 16 * 1024 * 1024)
        try verify(source)
        let sourceHash = hash(sourceBytes)
        let target = directory.appendingPathComponent("StandMixerHelper")
        let receipt = directory.appendingPathComponent(".engine.sha256")
        if FileManager.default.fileExists(atPath: target.path) || isSymlink(target) {
            let installedHash = hash(try readRegular(target, maximum: 16 * 1024 * 1024))
            if installedHash == sourceHash {
                // Recover a crash after publishing the binary but before its receipt.
                if isSymlink(receipt) { throw failure("StandMixer will not replace a symlink at its engine receipt.") }
                try writeReceipt(sourceHash, to: receipt)
                return target
            }
            let recorded = String(decoding: try readRegular(receipt, maximum: 1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard installedHash == recorded else { throw failure("The installed StandMixer engine was modified or is unrecognized. It was kept.") }
        } else if isSymlink(receipt) {
            throw failure("StandMixer will not replace a symlink at its engine receipt.")
        }
        let stage = directory.appendingPathComponent(".engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try sourceBytes.write(to: stage, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        try verify(stage)
        guard rename(stage.path, target.path) == 0 else { throw failure("StandMixer could not publish its engine.") }
        try writeReceipt(sourceHash, to: receipt)
        return target
    }

    private static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure("StandMixer could not safely read its engine or ownership receipt.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_size >= 0, information.st_size <= maximum, information.st_nlink == 1 else {
            throw failure("StandMixer will not replace an unsafe engine file.")
        }
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= maximum else { throw failure("StandMixer engine exceeded its size limit.") }
        return data
    }

    private static func writeReceipt(_ value: String, to url: URL) throws {
        let bytes = Data((value + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try readRegular(url, maximum: 1024)
            var information = stat()
            if existing == bytes, lstat(url.path, &information) == 0,
               information.st_uid == getuid(), information.st_mode & mode_t(0o777) == 0o600 {
                return
            }
        }
        guard !isSymlink(url) else { throw failure("StandMixer will not replace a symlink at its engine receipt.") }
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func checkAncestors(_ url: URL) throws {
        var candidate = url
        while candidate.path != "/" {
            var information = stat()
            if lstat(candidate.path, &information) == 0 {
                let link = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)
                let systemAlias = candidate.path == "/tmp" && (link == "/private/tmp" || link == "private/tmp")
                guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) || systemAlias else { throw failure("StandMixer will not install through a symlink or non-directory: \(candidate.path)") }
            } else if errno != ENOENT { throw failure("StandMixer could not inspect its install directory.") }
            candidate.deleteLastPathComponent()
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && information.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func verify(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", url.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("The StandMixer engine signature is invalid. Reinstall the complete plugin package.") }
    }
    private static func failure(_ message: String) -> NSError { NSError(domain: "StandMixerBootstrap", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
