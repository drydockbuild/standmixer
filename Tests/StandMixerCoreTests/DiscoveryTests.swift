import Foundation
import XCTest
@testable import StandMixerCore

final class DiscoveryTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        let temporary = FileManager.default.temporaryDirectory.path
        let canonical = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        root = URL(fileURLWithPath: canonical).appendingPathComponent("standmixer-discovery-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func discovery(active: [URL] = [], path: String = "", directoryReader: @escaping (URL) -> [URL] = CLIDiscovery.readDirectory) -> CLIDiscovery {
        // Match production's 2s budget so cold fixture launches do not race 250ms under load.
        CLIDiscovery(home: home, environment: ["PATH": path], applicationDirectories: [root.appendingPathComponent("Applications")],
                     commonDirectories: [], activeExecutables: { active }, probeTimeout: 2, directoryReader: directoryReader)
    }

    @discardableResult private func executable(_ relative: String, version: String, platform: AgentPlatform = .claude) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = platform == .claude ? "\(version) (Claude Code)" : "codex-cli \(version)"
        // The fake CLI refuses every command except --version; it never accesses real app state.
        let script = "#!/bin/sh\n[ \"$#\" -eq 1 ] && [ \"$1\" = '--version' ] || exit 90\nprintf '%s\\n' '\(output)'\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testHashNestedDesktopCLIBeatsStaleNativeSymlink() throws {
        let native = try executable(".local/share/claude/versions/2.1.285", version: "2.1.285")
        let link = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: native)
        let newest = try executable("Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude", version: "2.1.309")
        let selected = try XCTUnwrap(discovery().select(.claude))
        XCTAssertEqual(selected.executable, newest)
        XCTAssertEqual(selected.version, "2.1.309")
        XCTAssertEqual(selected.source, "Claude Desktop managed CLI")
        XCTAssertFalse(selected.isActive)
    }

    func testVerifiedActiveCLITakesPrecedenceOverNewerInstalledCLI() throws {
        let active = try executable("custom/bin/claude", version: "2.1.308")
        try executable(".local/share/claude/versions/2.1.309", version: "2.1.309")
        let selected = try XCTUnwrap(discovery(active: [active]).select(.claude))
        XCTAssertEqual(selected.executable, active)
        XCTAssertEqual(selected.version, "2.1.308")
        XCTAssertTrue(selected.isActive)
    }

    func testUnverifiedActiveProcessCannotDisplaceVerifiedCLI() throws {
        let active = try executable("custom/bin/claude", version: "invalid")
        let installed = try executable(".local/share/claude/versions/2.1.309", version: "2.1.309")
        let selected = try XCTUnwrap(discovery(active: [active]).select(.claude))
        XCTAssertEqual(selected.executable, installed)
        XCTAssertFalse(selected.isActive)
    }

    func testNewestNativeVersionsAreConsideredBeforeProbeLimit() throws {
        for patch in 1...80 { try executable(".local/share/claude/versions/2.1.\(patch)", version: "2.1.\(patch)") }
        let candidates = discovery().candidates(.claude)
        XCTAssertLessThanOrEqual(candidates.count, CLIDiscovery.maximumProbes)
        XCTAssertEqual(candidates.first?.executable.lastPathComponent, "2.1.80")
        XCTAssertEqual(discovery().select(.claude)?.version, "2.1.80")
    }

    func testVersionStoresCannotCrowdNewerPATHCLIOutOfBudget() throws {
        for patch in 1...40 {
            try executable(".local/share/claude/versions/2.1.\(patch)", version: "2.1.\(patch)")
            try executable("Library/Application Support/Claude/claude-code/2.1.\(patch)/5af865b9901c/claude.app/Contents/MacOS/claude", version: "2.1.\(patch)")
        }
        let latest = try executable("custom/bin/claude", version: "3.0.0")
        let resolver = discovery(path: latest.deletingLastPathComponent().path)
        XCTAssertLessThanOrEqual(resolver.candidates(.claude).count, CLIDiscovery.maximumProbes)
        XCTAssertEqual(resolver.select(.claude)?.executable, latest)
    }

    func testSymlinksAreDeduplicatedByResolvedExecutable() throws {
        let native = try executable(".local/share/claude/versions/2.1.309", version: "2.1.309")
        let link = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: native)
        XCTAssertEqual(discovery(path: link.deletingLastPathComponent().path).candidates(.claude).map(\.executable), [native])
    }

    func testGUIExecutableIsNotAnActiveCLI() throws {
        let gui = URL(fileURLWithPath: "/Applications/Claude.app/Contents/MacOS/Claude")
        XCTAssertFalse(CLIDiscovery.isCLIPath(gui, platform: .claude))
        XCTAssertTrue(discovery(active: [gui]).candidates(.claude).isEmpty)
    }

    func testNodeVersionManagerAndCodexBundleLocations() throws {
        let npm = try executable(".nvm/versions/node/v24.0.0/bin/codex", version: "0.200.1", platform: .codex)
        XCTAssertEqual(discovery().select(.codex)?.executable, npm)
        let app = root.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex-cli/bin/codex")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: npm, to: app)
        XCTAssertTrue(discovery().candidates(.codex).contains { $0.executable == app })
    }

    func testProtectedPATHAndRunningPathsAreNeverCandidates() throws {
        let forbidden = ["Music", "Downloads", "Documents", "Desktop", "Pictures", "Movies",
                         "Library/CloudStorage/GoogleDrive-account", "Library/Mobile Documents/com~apple~CloudDocs",
                         "Google Drive", "OneDrive - Company", "Dropbox", "Library/Application Support/OtherApp"]
        let executables = try forbidden.map { try executable("\($0)/bin/claude", version: "9.0.0") }
        let paths = executables.map { $0.deletingLastPathComponent().path }.joined(separator: ":")
        var listed: [URL] = []
        let resolver = discovery(active: executables, path: paths) { directory in
            listed.append(directory)
            return CLIDiscovery.readDirectory(directory)
        }
        XCTAssertTrue(resolver.candidates(.claude).isEmpty)
        XCTAssertFalse(listed.contains { directory in forbidden.contains { directory.path.hasPrefix(home.appendingPathComponent($0).path) } })
    }

    func testProtectedPathCaseAndFixedMacOSAliasesCannotBypassPolicy() {
        let resolver = discovery()
        let paths = [home.path.lowercased() + "/mUsIc/bin/claude",
                     "/System/Volumes/Data" + home.path + "/Downloads/bin/claude",
                     home.path + "/LiBrArY/CloudStorage/account/bin/claude"]
        for path in paths {
            XCTAssertTrue(resolver.isProtectedPath(URL(fileURLWithPath: path)), path)
        }
    }

    func testVersionProbeExcludesProtectedPATHDirectories() throws {
        let cli = try executable("custom/bin/claude", version: "2.1.309")
        let script = "#!/bin/sh\ncase \"$PATH\" in *Music*|*Downloads*|*GoogleDrive*) exit 91 ;; esac\nprintf '2.1.309 (Claude Code)\\n'\n"
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let forbidden = ["Music/bin", "Downloads/bin", "Library/CloudStorage/GoogleDrive-account/bin"].map { home.appendingPathComponent($0).path }
        XCTAssertEqual(discovery(path: ([cli.deletingLastPathComponent().path] + forbidden).joined(separator: ":")).select(.claude)?.version, "2.1.309")
    }

    func testCLISymlinksCannotEscapeIntoProtectedLocations() throws {
        let protected = try executable("Music/private/claude", version: "9.0.0")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("claude"), withDestinationURL: protected)
        let parentAlias = home.appendingPathComponent("custom")
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: protected.deletingLastPathComponent())
        XCTAssertTrue(discovery(path: "\(bin.path):\(parentAlias.path)").candidates(.claude).isEmpty)
    }

    func testStoreAndBundleEnumerationUseOnlyCLISubtrees() throws {
        let newest = try executable("Library/Application Support/Claude/claude-code/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude", version: "2.1.309")
        let resources = root.appendingPathComponent("Applications/Claude.app/Contents/Resources")
        let bundleCLI = resources.appendingPathComponent("claude-code/bin/claude")
        try FileManager.default.createDirectory(at: bundleCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: newest, to: bundleCLI)
        let outsideSubtree = resources.appendingPathComponent("unrelated/claude")
        try FileManager.default.createDirectory(at: outsideSubtree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: newest, to: outsideSubtree)
        var listed: [URL] = []
        let candidates = discovery { directory in
            listed.append(directory)
            return CLIDiscovery.readDirectory(directory)
        }.candidates(.claude)
        XCTAssertTrue(candidates.contains { $0.executable == newest })
        XCTAssertTrue(candidates.contains { $0.executable == bundleCLI })
        XCTAssertFalse(candidates.contains { $0.executable == outsideSubtree })
        XCTAssertFalse(listed.contains(home.appendingPathComponent("Library/Application Support/Claude")))
        XCTAssertFalse(listed.contains(resources))
        XCTAssertFalse(listed.contains(outsideSubtree.deletingLastPathComponent()))
    }

    func testDirectorySymlinksInStoresAndBundlesAreNotTraversed() throws {
        let forbidden = home.appendingPathComponent("Downloads/private")
        try FileManager.default.createDirectory(at: forbidden, withIntermediateDirectories: true)
        try executable("Downloads/private/claude", version: "9.0.0")
        let links = [home.appendingPathComponent(".local/share/claude/versions"),
                     home.appendingPathComponent(".nvm/versions/node"),
                     root.appendingPathComponent("Applications/Claude.app/Contents/Resources/claude-code")]
        for link in links {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: forbidden)
        }
        var listed: [URL] = []
        let resolver = discovery { directory in
            listed.append(directory)
            return CLIDiscovery.readDirectory(directory)
        }
        XCTAssertTrue(resolver.candidates(.claude).isEmpty)
        XCTAssertFalse(listed.contains { $0.path.hasPrefix(forbidden.path) || links.contains($0) })
    }

    func testNestedBundleSymlinkCannotLeadWalkerOutsideCLIPackage() throws {
        let protected = try executable("Library/Application Support/UnrelatedApp/private/claude", version: "9.0.0")
        let package = root.appendingPathComponent("Applications/Claude.app/Contents/Resources/claude-code")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let alias = package.appendingPathComponent("vendor")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected.deletingLastPathComponent())
        var listed: [URL] = []
        let candidates = discovery { directory in
            listed.append(directory)
            return CLIDiscovery.readDirectory(directory)
        }.candidates(.claude)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(listed.filter { $0.path.hasPrefix(package.path) }.map(\.path), [package.path])
        XCTAssertFalse(listed.contains(protected.deletingLastPathComponent()))
    }

    func testSemVerPrecedenceAndBrandVerification() throws {
        let ascending = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        let versions = try ascending.map { try XCTUnwrap(CLIVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) { XCTAssertLessThan(a, b) }
        XCTAssertEqual(CLIVersion("2.1.309+build.9"), CLIVersion("2.1.309+build.10"))
        XCTAssertLessThan(try XCTUnwrap(CLIVersion("2.1.99")), try XCTUnwrap(CLIVersion("2.1.100")))
        for invalid in ["2.1", "2.01.1", "2.1.1-alpha.01", "2.1.1+", "2.1.1-", "2.1.1+one+two"] { XCTAssertNil(CLIVersion(invalid)) }
        XCTAssertEqual(CLIDiscovery.versionToken("2.1.309 (Claude Code)\n", platform: .claude), "2.1.309")
        XCTAssertEqual(CLIDiscovery.versionToken("codex-cli 0.200.1\n", platform: .codex), "0.200.1")
        XCTAssertNil(CLIDiscovery.versionToken("2.1.309 Desktop App", platform: .claude))
        XCTAssertNil(CLIDiscovery.versionToken("2.1.309 (Claude Code)", platform: .codex))
    }

    func testProbeTimeoutDoesNotAcceptUnfinishedVersionOutput() throws {
        let url = try executable("slow/claude", version: "2.1.309")
        try "#!/bin/sh\nprintf '2.1.309 (Claude Code)\\n'\nexec /bin/sleep 2\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let started = Date()
        XCTAssertNil(CLIDiscovery.version(url, platform: .claude, environment: [:], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testCacheReusesSelectionsAndMissingResultsUntilRefreshOrExpiry() {
        let cache = ExecutableDiscoveryCache()
        let start = Date(timeIntervalSince1970: 1000)
        let path = URL(fileURLWithPath: "/fixture/claude")
        let selected = CLISelection(executable: path, version: "2.1.309", source: "fixture", isActive: false)
        var probes = 0
        func resolve() -> CLISelection? { probes += 1; return selected }
        XCTAssertEqual(cache.selection(for: .claude, now: start, resolve: resolve)?.executable, path)
        XCTAssertEqual(cache.selection(for: .claude, now: start.addingTimeInterval(20), resolve: resolve)?.executable, path)
        XCTAssertEqual(probes, 1)
        _ = cache.selection(for: .claude, now: start.addingTimeInterval(61), resolve: resolve)
        XCTAssertEqual(probes, 2)
        cache.invalidate()
        _ = cache.selection(for: .claude, now: start.addingTimeInterval(62), resolve: resolve)
        XCTAssertEqual(probes, 3)
        var missingProbes = 0
        for second in 0...5 {
            XCTAssertNil(cache.selection(for: .codex, now: start.addingTimeInterval(Double(second))) { missingProbes += 1; return nil })
        }
        XCTAssertEqual(missingProbes, 1)
    }
}
