import CryptoKit
import Foundation
import XCTest
@testable import StandMixerCore

final class MacAppInstallerTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    private var launcher: URL { service.home.appendingPathComponent("Library/Application Support/StandMixer/bin/standmixer") }
    private var receipt: URL { launcher.deletingLastPathComponent().appendingPathComponent(".standmixer-launcher.sha256") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("standmixer-mac-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = .init(home: root.appendingPathComponent("home"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func installFixture(_ body: String, marker: String = StandMixerMacInstaller.launcherMarker) throws {
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = Data(("#!/bin/sh\n" + marker + "\n" + body + "\n").utf8)
        try data.write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try Data((hash + "\n").utf8).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }

    func testOwnedLauncherRunsOnlyFixedInstallVerbWithIsolatedHomeAndBoundedOutput() async throws {
        let recorded = root.appendingPathComponent("invocation.txt")
        try installFixture("[ \"$#\" -eq 1 ] && [ \"$1\" = install-mac ] || exit 7\n/usr/bin/printf '%s\\n%s\\n' \"$1\" \"$HOME\" > " + quote(recorded.path) + "\n/bin/dd if=/dev/zero bs=98304 count=1 2>/dev/null")
        XCTAssertEqual(try StandMixerMacInstaller.validatedLauncher(service: service), launcher)
        let installed = try await StandMixerMacInstaller.install(service: service)
        XCTAssertEqual(installed.changedFiles, 0)
        XCTAssertTrue(installed.message.contains("~/Applications/StandMixer.app"))
        XCTAssertEqual(try String(contentsOf: recorded, encoding: .utf8), "install-mac\n" + service.home.path + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
    }

    func testMissingModifiedUnmarkedAndWritableLaunchersAreRejectedBeforeExecution() throws {
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service)) { XCTAssertEqual(($0 as? StandMixerMacInstallerError)?.code, "installerUnavailable") }
        try installFixture("exit 0")
        try Data("changed\n".utf8).write(to: launcher)
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
        try installFixture("exit 0", marker: "# not owned")
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
        try installFixture("exit 0")
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: launcher.path)
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
        try installFixture("exit 0")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: receipt.path)
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
    }

    func testBuildFailureKeepsBoundedFinalDiagnosticsAndCanonicalRetryCommand() async throws {
        try installFixture("""
        /usr/bin/printf 'EARLY_OUTPUT_SENTINEL\\n'
        /usr/bin/awk 'BEGIN { for (i = 0; i < 10000; i++) print "compiler progress" }'
        /usr/bin/printf 'Final build context\\n'
        /usr/bin/printf 'EARLY_ERROR_SENTINEL\\n' >&2
        /usr/bin/awk 'BEGIN { for (i = 0; i < 10000; i++) print "compiler warning" }' >&2
        /usr/bin/printf 'error: ambiguous use of prefix\\n' >&2
        exit 42
        """)
        do {
            _ = try await StandMixerMacInstaller.install(service: service)
            XCTFail("Expected build failure")
        } catch let error as StandMixerMacInstallerError {
            XCTAssertEqual(error.code, "installMacFailed")
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("exited with code 42"))
            XCTAssertTrue(message.contains("Final build context"))
            XCTAssertTrue(message.contains("error: ambiguous use of prefix"))
            XCTAssertTrue(message.contains("\"$HOME/Library/Application Support/StandMixer/bin/standmixer\" install-mac"))
            XCTAssertFalse(message.contains("EARLY_OUTPUT_SENTINEL"))
            XCTAssertFalse(message.contains("EARLY_ERROR_SENTINEL"))
            XCTAssertLessThan(message.utf8.count, 9000)
        }
    }

    func testRemovedLegacyCommandCannotReplaceMissingCanonicalLauncher() throws {
        try installFixture("exit 0")
        let legacy = launcher.deletingLastPathComponent().appendingPathComponent("unrelated-command")
        try FileManager.default.moveItem(at: launcher, to: legacy)
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testSymlinkAndHardlinkLaunchersAndRedirectedParentsAreRejected() throws {
        try installFixture("exit 0")
        let copy = root.appendingPathComponent("source-launcher")
        try FileManager.default.moveItem(at: launcher, to: copy)
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: copy)
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
        try FileManager.default.removeItem(at: launcher)
        try FileManager.default.linkItem(at: copy, to: launcher)
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
        try FileManager.default.removeItem(at: launcher)
        try FileManager.default.removeItem(at: copy)
        try installFixture("exit 0")
        let bin = launcher.deletingLastPathComponent()
        let moved = root.appendingPathComponent("redirected-bin")
        try FileManager.default.moveItem(at: bin, to: moved)
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: moved)
        XCTAssertThrowsError(try StandMixerMacInstaller.validatedLauncher(service: service))
    }

    func testFixtureServiceCannotStartEvenAValidOwnedInstaller() async throws {
        let started = root.appendingPathComponent("must-not-start")
        try installFixture("/usr/bin/touch " + quote(started.path))
        let fixture = IntegrationService(home: service.home, environment: [:], metadataOnlyDiscovery: true)
        do { _ = try await StandMixerMacInstaller.install(service: fixture); XCTFail("Fixture install must fail") }
        catch { XCTAssertEqual((error as? StandMixerMacInstallerError)?.code, "fixtureDisabled") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
    }

    func testTimeoutAndCancellationStopOwnedBuildDescendants() async throws {
        let heartbeat = root.appendingPathComponent("heartbeat")
        let child = "trap '' TERM; while :; do /usr/bin/printf x >> " + quote(heartbeat.path) + "; /bin/sleep 0.05; done"
        try installFixture("/bin/sh -c " + quote(child) + " &\nwait")
        do { _ = try await StandMixerMacInstaller.install(service: service, timeout: 1); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? StandMixerMacInstallerError)?.code, "installMacTimedOut") }
        let timedOutCount = try Data(contentsOf: heartbeat).count
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try Data(contentsOf: heartbeat).count, timedOutCount)
        try FileManager.default.removeItem(at: heartbeat)
        let selectedService = service!
        let operation = Task { try await StandMixerMacInstaller.install(service: selectedService) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: heartbeat.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelledCount = try Data(contentsOf: heartbeat).count
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try Data(contentsOf: heartbeat).count, cancelledCount)
    }
}
