import CryptoKit
import Foundation
import XCTest
@testable import StandMixerCore

final class AppOpeningTests: XCTestCase {
    private var root: URL!
    private var service: IntegrationService!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("standmixer-opening-\(UUID().uuidString)")
        service = .init(home: root, environment: [:])
        try FileManager.default.createDirectory(at: service.applicationSupport, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func app(_ name: String = "StandMixer.app") throws -> URL {
        let app = root.appendingPathComponent("Applications/\(name)")
        let binary = app.appendingPathComponent("Contents/MacOS/StandMixer")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bytes = Data("owned fixture executable".utf8)
        try bytes.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let info: [String: String] = ["CFBundleIdentifier": "build.drydock.StandMixer", "CFBundleExecutable": "StandMixer"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let receipt = service.applicationSupport.appendingPathComponent("mac-app.receipt")
        try Data((app.path + "\n" + hash + "\n").utf8).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return app
    }
    private func webLauncher(session: String) throws -> URL {
        let bin = service.applicationSupport.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let launcher = bin.appendingPathComponent("open-codex-ui")
        let bytes = Data(("#!/bin/sh\n# Managed by StandMixer\n[ \"$#\" -eq 0 ] || exit 7\nprintf '%s\\n' '" + session + "'\n").utf8)
        try bytes.write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try Data((hash + "\n").utf8).write(to: bin.appendingPathComponent(".codex-ui-launcher.sha256"))
        return launcher
    }
    private var session: String { "{\"url\":\"http://127.0.0.1:12345/#token=\(String(repeating: "a", count: 43))\",\"pid\":123,\"idleTimeoutSeconds\":600}" }

    func testAvailabilityAcceptsOwnedCurrentAndLegacyAppsWithoutStartingAnything() throws {
        XCTAssertFalse(StandMixerAppOpening.installedMac(service: service).isAvailable)
        for name in ["StandMixer.app", "StandMixer.app"] {
            let app = try app(name)
            let status = StandMixerAppOpening.installedMac(service: service)
            XCTAssertTrue(status.isAvailable)
            XCTAssertEqual(status.appPath, app.standardizedFileURL.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.codexHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.claudeHome.path))
    }

    func testModifiedUnownedAndRedirectedAppsStayUnavailable() throws {
        let current = try app()
        let binary = current.appendingPathComponent("Contents/MacOS/StandMixer")
        try Data("modified".utf8).write(to: binary)
        XCTAssertFalse(StandMixerAppOpening.installedMac(service: service).isAvailable)
        _ = try app()
        let copy = root.appendingPathComponent("saved-binary")
        try FileManager.default.moveItem(at: binary, to: copy)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: copy)
        XCTAssertFalse(StandMixerAppOpening.installedMac(service: service).isAvailable)
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.linkItem(at: copy, to: binary)
        XCTAssertFalse(StandMixerAppOpening.installedMac(service: service).isAvailable)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "owned fixture executable")
    }

    func testWebOpeningRunsOnlyOwnedLauncherAndReturnsPrivateLoopbackURL() async throws {
        let launcher = try webLauncher(session: session)
        let response = try await StandMixerAppOpening.openWeb(service: service)
        XCTAssertEqual(response.url, "http://127.0.0.1:12345/#token=" + String(repeating: "a", count: 43))
        try Data("modified launcher".utf8).write(to: launcher)
        do { _ = try await StandMixerAppOpening.openWeb(service: service); XCTFail("Modified launcher must stay unexecuted") }
        catch { XCTAssertEqual((error as? StandMixerAppOpeningError)?.code, "webUnavailable") }
    }

    func testWebSessionRejectsRemoteMalformedAndExtraPayloadFields() throws {
        XCTAssertNoThrow(try StandMixerAppOpening.webSession(Data(session.utf8)))
        for value in [session.replacingOccurrences(of: "127.0.0.1", with: "example.com"),
                      session.replacingOccurrences(of: "http:", with: "file:"),
                      session.replacingOccurrences(of: "123,", with: "0,"),
                      session.dropLast() + ",\"path\":\"/private\"}", "{}"] {
            XCTAssertThrowsError(try StandMixerAppOpening.webSession(Data(value.utf8)))
        }
    }

    func testFixtureOpeningNeverLaunchesWebServerOrMacApp() async throws {
        _ = try app()
        _ = try webLauncher(session: session)
        let fixture = IntegrationService(home: root, environment: [:], metadataOnlyDiscovery: true)
        do { _ = try await StandMixerAppOpening.openWeb(service: fixture); XCTFail("Fixture must not start a web server") }
        catch { XCTAssertEqual((error as? StandMixerAppOpeningError)?.code, "fixtureDisabled") }
        do { _ = try await StandMixerAppOpening.openMac(service: fixture); XCTFail("Fixture must not open an app") }
        catch { XCTAssertEqual((error as? StandMixerAppOpeningError)?.code, "fixtureDisabled") }
    }
}
