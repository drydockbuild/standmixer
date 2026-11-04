import Darwin
import Foundation

public enum StandMixerRelease {
    public static let version = "0.1.2"
}

public struct StandMixerUpdate: Codable, Sendable {
    public let currentVersion: String
    public let latestVersion: String
}

public enum StandMixerUpdateChecker {
    static let interval: TimeInterval = 24 * 60 * 60
    static let maximumBytes = 16 * 1024
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/drydockbuild/standmixer/main/Plugins/codex-agentmix/plugin.json")!
    struct Cache: Codable {
        var checkedAt: Date
        var latestVersion: String?
    }

    public static func check(service: IntegrationService) async -> StandMixerUpdate? {
        guard !service.metadataOnlyDiscovery else { return nil }
        return await check(service: service, now: Date(), currentVersion: StandMixerRelease.version, fetch: fetchManifest)
    }

    // Tests supply their own clock and transport; production accepts neither from requests.
    static func check(service: IntegrationService, now: Date, currentVersion: String,
                      fetch: @Sendable () async throws -> Data) async -> StandMixerUpdate? {
        let directory = service.applicationSupport.appendingPathComponent("UpdateCheck", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("version.json")
        do {
            try service.privateDirectory(directory)
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { return nil }
            let previous = try readCache(service: service, url: cacheURL)
            if let previous, isFresh(previous, now: now) { return available(previous.latestVersion, current: currentVersion) }
            let lockURL = directory.appendingPathComponent("check.lock")
            try service.checkNoSymlink(lockURL)
            let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return nil }
            defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { return available(previous?.latestVersion, current: currentVersion) }
            let cached = try readCache(service: service, url: cacheURL)
            if let cached, isFresh(cached, now: now) { return available(cached.latestVersion, current: currentVersion) }
            var next = Cache(checkedAt: now, latestVersion: cached?.latestVersion)
            // Record attempts too, so an offline launch does not retry on every open.
            try service.write(JSONEncoder().encode(next), to: cacheURL, mode: 0o600)
            do {
                let data = try await fetch()
                if data.count <= maximumBytes,
                   let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = manifest["version"] as? String, components(version) != nil {
                    next.latestVersion = version
                    try service.write(JSONEncoder().encode(next), to: cacheURL, mode: 0o600)
                }
            } catch { /* Optional checks stay quiet and never block settings. */ }
            return available(next.latestVersion, current: currentVersion)
        } catch { return nil }
    }

    private static func readCache(service: IntegrationService, url: URL) throws -> Cache? {
        try service.checkNoSymlink(url)
        do {
            let data = try AgentMixMacInstaller.readOwned(url, maximum: 4096)
            return try? JSONDecoder().decode(Cache.self, from: data)
        }
        catch AgentMixMacInstallerError.unavailable { return nil }
    }
    private static func isFresh(_ cache: Cache, now: Date) -> Bool {
        let age = now.timeIntervalSince(cache.checkedAt)
        return age >= -60 && age < interval
    }
    static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        return parts.map { Int($0)! }
    }
    private static func available(_ latest: String?, current: String) -> StandMixerUpdate? {
        guard let latest, let lhs = components(current), let rhs = components(latest), lhs.lexicographicallyPrecedes(rhs) else { return nil }
        return .init(currentVersion: current, latestVersion: latest)
    }
    private static func fetchManifest() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StandMixer/" + StandMixerRelease.version, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == manifestURL, response.expectedContentLength <= maximumBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
