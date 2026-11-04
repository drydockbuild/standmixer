import Foundation
import XCTest
@testable import AgentMixCore

final class UpdateCheckTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    actor Counter {
        var count = 0
        func hit() { count += 1 }
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-update-check-\(UUID())")
        service = IntegrationService(home: root, environment: [:])
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private func nativeFilesRemainAbsent() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.applicationSupport.appendingPathComponent("configuration.json").path))
    }

    func testChecksOncePerDayAcrossServicesAndComparesVersionsNumerically() async {
        let counter = Counter()
        let fetch: @Sendable () async throws -> Data = { await counter.hit(); return Data(#"{"version":"0.10.0"}"#.utf8) }
        let first = await StandMixerUpdateChecker.check(service: service, now: now, currentVersion: "0.9.9", fetch: fetch)
        XCTAssertEqual(first?.latestVersion, "0.10.0")
        let other = IntegrationService(home: root, environment: [:])
        let cached = await StandMixerUpdateChecker.check(service: other, now: now.addingTimeInterval(86399), currentVersion: "0.9.9", fetch: fetch)
        XCTAssertEqual(cached?.latestVersion, "0.10.0")
        let count = await counter.count; XCTAssertEqual(count, 1)
        _ = await StandMixerUpdateChecker.check(service: service, now: now.addingTimeInterval(86400), currentVersion: "0.9.9", fetch: fetch)
        let nextCount = await counter.count; XCTAssertEqual(nextCount, 2)
        nativeFilesRemainAbsent()
    }

    func testOfflineAndInvalidResponsesAreQuietAndThrottled() async {
        let counter = Counter()
        let failure: @Sendable () async throws -> Data = { await counter.hit(); throw URLError(.notConnectedToInternet) }
        let first = await StandMixerUpdateChecker.check(service: service, now: now, currentVersion: "0.1.2", fetch: failure)
        let second = await StandMixerUpdateChecker.check(service: service, now: now.addingTimeInterval(20), currentVersion: "0.1.2", fetch: failure)
        XCTAssertNil(first); XCTAssertNil(second)
        let count = await counter.count; XCTAssertEqual(count, 1)
        let invalid = await StandMixerUpdateChecker.check(service: service, now: now.addingTimeInterval(86401), currentVersion: "0.1.2", fetch: { Data(#"{"version":"9.0.0\n"}"#.utf8) })
        XCTAssertNil(invalid)
        nativeFilesRemainAbsent()
    }

    func testConcurrentChecksDoNotDuplicateFetch() async throws {
        let counter = Counter(), selected = service!, date = now
        let fetch: @Sendable () async throws -> Data = {
            await counter.hit(); try await Task.sleep(nanoseconds: 150_000_000)
            return Data(#"{"version":"0.2.0"}"#.utf8)
        }
        let first = Task { await StandMixerUpdateChecker.check(service: selected, now: date, currentVersion: "0.1.2", fetch: fetch) }
        for _ in 0..<100 { if await counter.count > 0 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        _ = await StandMixerUpdateChecker.check(service: service, now: now, currentVersion: "0.1.2", fetch: fetch)
        let result = await first.value; XCTAssertEqual(result?.latestVersion, "0.2.0")
        let count = await counter.count; XCTAssertEqual(count, 1)
    }

    func testCurrentOrOlderVersionsAndOversizedPayloadDoNotAdvertiseAnUpdate() async {
        for (i, version) in ["0.1.2", "0.1.1", "0.2.0-beta.1"].enumerated() {
            let result = await StandMixerUpdateChecker.check(service: service, now: now.addingTimeInterval(Double(i) * 86401), currentVersion: "0.1.2", fetch: { Data("{\"version\":\"\(version)\"}".utf8) })
            XCTAssertNil(result)
        }
        let oversized = await StandMixerUpdateChecker.check(service: service, now: now.addingTimeInterval(4 * 86401), currentVersion: "0.1.2", fetch: { Data(repeating: 32, count: StandMixerUpdateChecker.maximumBytes + 1) })
        XCTAssertNil(oversized)
    }

    func testRedirectedCacheCannotWriteOrFetchAndFixturesNeverUseNetwork() async throws {
        let fixture = IntegrationService(home: root, environment: [:], metadataOnlyDiscovery: true)
        let disabled = await StandMixerUpdateChecker.check(service: fixture)
        XCTAssertNil(disabled); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let directory = service.applicationSupport.appendingPathComponent("UpdateCheck")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("version.json"), withDestinationURL: target)
        let counter = Counter()
        let result = await StandMixerUpdateChecker.check(service: service, now: now, currentVersion: "0.1.2", fetch: { await counter.hit(); return Data() })
        XCTAssertNil(result); let count = await counter.count; XCTAssertEqual(count, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
}
