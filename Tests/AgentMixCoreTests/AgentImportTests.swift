import Darwin
import Foundation
import XCTest
@testable import AgentMixCore

final class AgentImportTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var integration: IntegrationService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("agentmix-import-tests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data("{\"fixtureOnly\":true}".utf8).write(to: codex.appendingPathComponent("auth.json"))
        integration = IntegrationService(home: home, applicationSupport: root.appendingPathComponent("support"), environment: [:])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testCodexUsesExistingDefaultsAndStructuredResultWithoutApplyingAnything() async throws {
        let response = try payload()
        let fixture = root.appendingPathComponent("response.json")
        try response.write(to: fixture)
        let arguments = root.appendingPathComponent("arguments.txt")
        let prompt = root.appendingPathComponent("prompt.txt")
        let fake = try executable("""
        /usr/bin/printf '%s\\n' "$@" > \(quote(arguments.path))
        out=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then out="$2"; shift 2; else shift; fi
        done
        /bin/cat > \(quote(prompt.path))
        /bin/cp \(quote(fixture.path)) "$out"
        /usr/bin/printf '{"type":"thread.started","thread_id":"fake-only"}\\n'
        """)
        let importer = AgentImportService(integration: integration, executableOverrides: [.codex: fake])
        let proposal = try await importer.inspect(platform: .codex, workingDirectory: home, mode: .preserveNativeDefaults)
        XCTAssertEqual(proposal.routes.first?.modelID, "gpt-6.1-sol")
        XCTAssertEqual(proposal.routes.first?.effort, .fixed("ultra"))
        XCTAssertNil(proposal.executionModelID)
        let flags = try String(contentsOf: arguments, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertTrue(flags.contains("read-only"))
        XCTAssertFalse(flags.contains("mcp_servers={}"))
        XCTAssertTrue(flags.contains("agents.enabled=false"))
        for control in ["features.code_mode.enabled=false", "features.code_mode_host=false", "features.shell_tool=false", "features.unified_exec=false", "project_doc_max_bytes=0", "skills.include_instructions=false", "skills.bundled.enabled=false", "features.skip_host_skill_discovery=true", "--ignore-user-config"] { XCTAssertTrue(flags.contains(control)) }
        for forbidden in ["-m", "--model", "--effort", "features.code_mode.enabled=true", "features.shell_tool=true", "features.unified_exec=true"] { XCTAssertFalse(flags.contains(forbidden)) }
        XCTAssertFalse(flags.contains { $0.hasPrefix("model_reasoning_effort=") })
        let brief = try String(contentsOf: prompt, encoding: .utf8)
        XCTAssertTrue(brief.contains("BEGIN UNTRUSTED ROUTING SNAPSHOT"))
        XCTAssertTrue(brief.contains("You have NO filesystem, shell"))
        XCTAssertFalse(brief.contains("Read/Glob/Grep or read-only shell"))
        XCTAssertTrue(brief.contains("a separate category-to-model mapping is not required"))
        XCTAssertTrue(brief.contains("Never report a known global primary only in summary while leaving coordinator null"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("support").path))
    }

    func testClaudeEnvelopeAndLargeStderrAreDrainedWithoutHanging() async throws {
        let body = try JSONSerialization.jsonObject(with: payload())
        let envelope = try JSONSerialization.data(withJSONObject: ["structured_output": body, "is_error": false,
            "modelUsage": ["claude-opus-5-5": ["inputTokens": 1]]])
        let fixture = root.appendingPathComponent("envelope.json")
        try envelope.write(to: fixture)
        let arguments = root.appendingPathComponent("arguments.txt")
        let fake = try executable("""
        /usr/bin/printf '%s\\n' "$@" > \(quote(arguments.path))
        /bin/cat >/dev/null
        /usr/bin/yes diagnostic | /usr/bin/head -c 262144 >&2
        /bin/cat \(quote(fixture.path))
        """)
        let importer = AgentImportService(integration: integration, executableOverrides: [.claude: fake], timeout: 5)
        let proposal = try await importer.inspect(platform: .claude, mode: .preserveNativeDefaults)
        XCTAssertEqual(proposal.executionModelID, "claude-opus-5-5")
        let flags = try String(contentsOf: arguments, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertFalse(flags.contains("Read,Glob,Grep"))
        for flag in ["--safe-mode", "--disable-slash-commands", "--strict-mcp-config", "{\"disableAllHooks\":true}"] { XCTAssertTrue(flags.contains(flag)) }
        for flag in ["--tools", "--setting-sources"] {
            let index = try XCTUnwrap(flags.firstIndex(of: flag))
            XCTAssertEqual(flags[index + 1], "")
        }
        let disallowed = try XCTUnwrap(flags.firstIndex(of: "--disallowedTools"))
        XCTAssertEqual(flags[disallowed + 1], "*")
        let maxTurns = try XCTUnwrap(flags.firstIndex(of: "--max-turns"))
        XCTAssertEqual(flags[maxTurns + 1], "1")
        XCTAssertFalse(flags.contains("--max-output-tokens"))
        XCTAssertFalse(flags.contains("--model"))
    }

    func testClaudeToollessResultJSONStringImportsWithoutSchemaTool() async throws {
        let rawResult = String(decoding: try payload(), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["result": rawResult, "is_error": false])
        let fixture = root.appendingPathComponent("claude-result-string.json")
        try envelope.write(to: fixture)
        let capturedArguments = root.appendingPathComponent("claude-result-arguments.txt")
        let fake = try executable("""
        /usr/bin/printf '%s\\n' "$@" > \(quote(capturedArguments.path))
        /bin/cat >/dev/null
        /bin/cat \(quote(fixture.path))
        """)

        let proposal = try await AgentImportService(integration: integration, executableOverrides: [.claude: fake])
            .inspect(platform: .claude, mode: .preserveNativeDefaults)
        XCTAssertEqual(proposal.routes.first?.modelID, "gpt-6.1-sol")
        XCTAssertEqual(proposal.routes.first?.effort, .fixed("ultra"))
        let flags = try String(contentsOf: capturedArguments, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertTrue(flags.contains("--safe-mode"))
        XCTAssertFalse(flags.contains("--json-schema"))
        let permission = try XCTUnwrap(flags.firstIndex(of: "--permission-mode"))
        XCTAssertEqual(flags[permission + 1], "dontAsk")
        let tools = try XCTUnwrap(flags.firstIndex(of: "--tools"))
        XCTAssertEqual(flags[tools + 1], "")
        let disallowed = try XCTUnwrap(flags.firstIndex(of: "--disallowedTools"))
        XCTAssertEqual(flags[disallowed + 1], "*")
    }

    func testClaudeResultRejectsNarrativeInvalidAndSchemaIncompleteJSON() async throws {
        let valid = String(decoding: try payload(), as: UTF8.self)
        let invalidResults = [
            "Here are the current settings: " + valid,
            #"{"summary":"Unfinished JSON","routes":["#,
            #"{"routes":[],"sources":[],"uncertainties":[]}"#,
            #"{"summary":"Wrong route shape","routes":{},"sources":[],"uncertainties":[]}"#
        ]
        for (index, result) in invalidResults.enumerated() {
            let fixture = root.appendingPathComponent("claude-invalid-result-\(index).json")
            try JSONSerialization.data(withJSONObject: ["result": result, "is_error": false]).write(to: fixture)
            let fake = try executable("""
            /bin/cat >/dev/null
            /bin/cat \(quote(fixture.path))
            """)
            do {
                _ = try await AgentImportService(integration: integration, executableOverrides: [.claude: fake])
                    .inspect(platform: .claude, mode: .preserveNativeDefaults)
                XCTFail("Claude result case \(index) should not import incomplete or narrative findings")
            } catch { XCTAssertTrue(error is AgentImportError) }
        }
    }

    func testClaudeResultRejectsMarkdownFenceAroundOtherwiseValidJSON() async throws {
        let fenced = "```json\n" + String(decoding: try payload(), as: UTF8.self) + "\n```"
        let fixture = root.appendingPathComponent("claude-fenced-result.json")
        try JSONSerialization.data(withJSONObject: ["result": fenced, "is_error": false]).write(to: fixture)
        let fake = try executable("""
        /bin/cat >/dev/null
        /bin/cat \(quote(fixture.path))
        """)

        do {
            _ = try await AgentImportService(integration: integration, executableOverrides: [.claude: fake])
                .inspect(platform: .claude, mode: .preserveNativeDefaults)
            XCTFail("A fenced result is not a complete raw JSON response")
        } catch { XCTAssertTrue(error is AgentImportError) }
    }

    func testObserverUsesEmptyPrivateStagingAndInlineSanitizedNativeSettings() async throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"gpt-saved-native\"\nmodel_reasoning_effort = \"ultra\"\n[env]\nTOKEN = \"FORBIDDEN_NATIVE_SECRET\"".write(to: config, atomically: true, encoding: .utf8)
        let selected = home.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try "Use gpt-selected-worker for backend implementation.".write(to: selected.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let fixture = root.appendingPathComponent("staged-findings.json")
        try payload().write(to: fixture)
        let captured = root.appendingPathComponent("staged-arguments.txt")
        let capturedPrompt = root.appendingPathComponent("staged-prompt.txt")
        let capturedCWD = root.appendingPathComponent("staged-cwd.txt")
        let fake = try executable("""
        [ -z "$(/bin/ls -A .)" ] || exit 9
        [ "$CODEX_HOME" != \(quote(home.appendingPathComponent(".codex").path)) ] || exit 9
        [ ! -e "$CODEX_HOME/AGENTS.md" ] || exit 9
        [ -L "$CODEX_HOME/auth.json" ] || exit 9
        [ "$(/usr/bin/readlink "$CODEX_HOME/auth.json")" = \(quote(home.appendingPathComponent(".codex/auth.json").path)) ] || exit 9
        /bin/pwd > \(quote(capturedCWD.path))
        /usr/bin/printf '%s\\n' "$@" > \(quote(captured.path))
        out=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then out="$2"; shift 2; else shift; fi
        done
        /bin/cat > \(quote(capturedPrompt.path))
        /bin/cp \(quote(fixture.path)) "$out"
        /usr/bin/printf '{}\\n'
        """)
        _ = try await AgentImportService(integration: integration, executableOverrides: [.codex: fake]).inspect(platform: .codex, workingDirectory: selected, mode: .preserveNativeDefaults)
        let cwd = try String(contentsOf: capturedCWD, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(cwd, home.path)
        XCTAssertNotEqual(cwd, selected.path)
        XCTAssertTrue(cwd.hasSuffix("/observer"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd), "Private staging must be removed after inspection")
        let flags = try String(contentsOf: captured, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertTrue(flags.contains("--ignore-user-config"))
        XCTAssertTrue(flags.contains("gpt-saved-native"))
        XCTAssertTrue(flags.contains("model_reasoning_effort=\"ultra\""))
        func normalizeSystemAlias(_ path: String) -> String {
            for alias in ["/var", "/tmp", "/etc"] {
                let canonical = "/private" + alias
                if path == canonical || path.hasPrefix(canonical + "/") { return String(path.dropFirst("/private".count)) }
            }
            return path
        }
        XCTAssertEqual(normalizeSystemAlias(flags[try XCTUnwrap(flags.firstIndex(of: "-C")) + 1]), normalizeSystemAlias(cwd))
        let prompt = try String(contentsOf: capturedPrompt, encoding: .utf8)
        XCTAssertTrue(prompt.contains("gpt-saved-native"))
        XCTAssertTrue(prompt.contains("gpt-selected-worker"))
        XCTAssertFalse(prompt.contains("FORBIDDEN_NATIVE_SECRET"))
    }

    func testMissingStructuredOutputAndExcessStdoutAreRejected() async throws {
        let missing = try executable("/usr/bin/printf '{\"is_error\":true,\"result\":\"refused\"}'")
        let importer = AgentImportService(integration: integration, executableOverrides: [.claude: missing], timeout: 3)
        do { _ = try await importer.inspect(platform: .claude); XCTFail("Expected structured response error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("without structured findings")) }
        let flood = try executable("/usr/bin/yes output | /usr/bin/head -c 65536")
        let bounded = AgentImportService(integration: integration, executableOverrides: [.claude: flood], timeout: 3, maximumOutputBytes: 4096)
        do { _ = try await bounded.inspect(platform: .claude); XCTFail("Expected output limit error") }
        catch { XCTAssertTrue(error is AgentImportError) }
    }

    func testCustomProviderIsRefusedWithoutReadingProviderSecretsOrStartingCLI() async throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"gpt-private\"\nmodel_provider = \"private-provider\"\n[model_providers.private-provider]\napi_key = \"FORBIDDEN_PROVIDER_CREDENTIAL\"".write(to: config, atomically: true, encoding: .utf8)
        let started = root.appendingPathComponent("custom-provider-cli-started.txt")
        let fake = try executable("/usr/bin/printf started > \(quote(started.path))", inventory: nil)
        do {
            _ = try await AgentImportService(integration: integration, executableOverrides: [.codex: fake]).inspect(platform: .codex)
            XCTFail("Expected unsupported custom-provider notice")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("custom model provider"))
            XCTAssertFalse(error.localizedDescription.contains("FORBIDDEN_PROVIDER_CREDENTIAL"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
    }

    func testCancellationTerminatesIgnoringDescendantEvenWithRedirectedPipes() async throws {
        let heartbeat = root.appendingPathComponent("heartbeat.txt")
        let ready = root.appendingPathComponent("ready.txt")
        let childScript = "trap '' TERM; while :; do /usr/bin/printf x >> \(quote(heartbeat.path)); /bin/sleep 0.05; done"
        let fake = try executable("""
        /bin/sh -c \(quote(childScript)) >/dev/null 2>&1 &
        /usr/bin/printf ready > \(quote(ready.path))
        wait
        """)
        let importer = AgentImportService(integration: integration, executableOverrides: [.codex: fake], timeout: 5)
        let task = Task { try await importer.inspect(platform: .codex) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: heartbeat.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let afterStop = try Data(contentsOf: heartbeat)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try Data(contentsOf: heartbeat), afterStop)
    }

    func testDeadlineStopsTheInspection() async throws {
        let fake = try executable("/bin/sleep 30")
        let importer = AgentImportService(integration: integration, executableOverrides: [.codex: fake], timeout: 0.1)
        let start = Date()
        do { _ = try await importer.inspect(platform: .codex); XCTFail("Expected deadline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("exceeded")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCodexVerifiesEachConfiguredMCPServerIsDisabledBeforeInspection() async throws {
        let fixture = root.appendingPathComponent("findings.json")
        try payload().write(to: fixture)
        let captured = root.appendingPathComponent("exec-arguments.txt")
        let fake = try executable("""
        inventory=false
        disabled=false
        ignores_user_config=false
        for argument in "$@"; do
          if [ "$argument" = mcp ]; then inventory=true; fi
          if [ "$argument" = --ignore-user-config ]; then ignores_user_config=true; fi
          if [ "$argument" = mcp_servers.fixture_server.enabled=false ]; then disabled=true; fi
        done
        if [ "$inventory" = true ]; then
          [ "$ignores_user_config" = false ] || exit 8
          [ "$HOME" = "$CODEX_HOME" ] || exit 8
          [ "$HOME" != \(quote(home.path)) ] || exit 8
          [ -z "$(/bin/ls -A .)" ] || exit 8
          if [ "$disabled" = true ]; then
            /usr/bin/printf '[{"name":"fixture_server","enabled":false,"transport":{"type":"stdio"}},{"name":"http_fixture","enabled":false,"transport":{"type":"streamable_http"}}]'
          else
            /usr/bin/printf '[{"name":"fixture_server","enabled":true,"transport":{"type":"stdio"}},{"name":"http_fixture","enabled":true,"transport":{"type":"streamable_http"}}]'
          fi
          exit 0
        fi
        /usr/bin/printf '%s\\n' "$@" > \(quote(captured.path))
        out=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then out="$2"; shift 2; else shift; fi
        done
        /bin/cat >/dev/null
        /bin/cp \(quote(fixture.path)) "$out"
        /usr/bin/printf '{}\\n'
        """, inventory: nil)
        let importer = AgentImportService(integration: integration, executableOverrides: [.codex: fake], timeout: 5)
        _ = try await importer.inspect(platform: .codex)
        let execFlags = try String(contentsOf: captured, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertTrue(execFlags.contains("mcp_servers.fixture_server.enabled=false"))
        XCTAssertTrue(execFlags.contains("mcp_servers.fixture_server.command=\"/usr/bin/false\""))
        XCTAssertTrue(execFlags.contains("mcp_servers.http_fixture.enabled=false"))
        XCTAssertTrue(execFlags.contains("mcp_servers.http_fixture.url=\"http://127.0.0.1:9\""))
        XCTAssertFalse(execFlags.contains("mcp_servers={}"))
    }

    func testInvalidOrStillEnabledMCPInventoryNeverStartsInference() async throws {
        let started = root.appendingPathComponent("inference-started.txt")
        for inventory in ["not-json", #"[{"name":"still_enabled","enabled":true,"transport":{"type":"stdio"}}]"#, #"[{"name":"odd.name","enabled":true,"transport":{"type":"stdio"}}]"#] {
            let fake = try executable("/usr/bin/printf started > \(quote(started.path))", inventory: inventory)
            let importer = AgentImportService(integration: integration, executableOverrides: [.codex: fake], timeout: 3)
            do { _ = try await importer.inspect(platform: .codex); XCTFail("Expected safe preflight refusal") }
            catch { XCTAssertTrue(error is AgentImportError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
        }
    }

    func testMergeProtectsNewerEditsAndDoesNotInventMissingEffort() throws {
        let importer = AgentImportService(integration: integration)
        var baseline = pinnedControllers()
        let implementation = try XCTUnwrap(baseline.profiles[0].routes.firstIndex { $0.category == .implementation })
        baseline.profiles[0].routes[implementation].effort = .fixed("ultra")
        var current = baseline
        current.profiles[0].routes[0].effort = .fixed("high")
        let findings = AgentImportProposal(platform: .codex, workingDirectory: home.path, routes: [
            .init(category: .coordinator, modelID: "gpt-6-astra", modelPlatform: .codex, effort: .fixed("ultra")),
            .init(category: .implementation, modelID: "gpt-6-luna", modelPlatform: .codex),
            .init(category: .mechanical, modelID: "gpt-custom-exact", modelPlatform: .codex, effort: .fixed("high")),
        ])
        let merged = importer.merge(proposals: [findings], into: current, baseline: baseline)
        XCTAssertEqual(merged.configuration.profiles[0].routes[0], current.profiles[0].routes[0])
        XCTAssertEqual(merged.configuration.profile(for: .codex)?.route(for: .implementation), current.profile(for: .codex)?.route(for: .implementation))
        XCTAssertEqual(merged.configuration.profile(for: .codex)?.route(for: .mechanical)?.modelID, "gpt-custom-exact")
        XCTAssertEqual(merged.configuration.customModels.first?.platform, .codex)
        XCTAssertEqual(merged.changedRoutes, 1)
        XCTAssertFalse(merged.notes.isEmpty)
    }

    func testUnknownCategoryAndInvalidModelCannotOverwriteDraftFields() throws {
        let malformed: [String: Any] = ["routes": [
            ["category": "unknown", "modelID": "gpt-6-astra"],
            ["category": "implementation", "modelID": "use the best model please", "effort": ["mode": "fixed", "value": "low"]],
            ["category": "planning", "modelID": NSNull(), "effort": ["mode": "not-known"]],
        ]]
        let proposal = try AgentImportService.decode(JSONSerialization.data(withJSONObject: malformed), platform: .codex, cwd: home)
        XCTAssertEqual(proposal.routes.count, 2)
        XCTAssertNil(proposal.routes[0].modelID)
        XCTAssertNil(proposal.routes[0].effort)
        XCTAssertNil(proposal.routes[1].effort)
        let result = AgentImportService(integration: integration).merge(proposals: [proposal], into: .defaults)
        XCTAssertEqual(result.configuration, .defaults)
    }

    func testUnresolvedAIJudgeDoesNotReplaceDraftResultHandling() {
        let importer = AgentImportService(integration: integration)
        let proposal = AgentImportProposal(platform: .claude, workingDirectory: home.path, routes: [
            .init(category: .ui, resultMode: .ai, judgeModelID: "unknown-judge")
        ])
        let result = importer.merge(proposals: [proposal], into: .defaults)
        XCTAssertEqual(result.configuration, .defaults)
        XCTAssertFalse(result.notes.isEmpty)
    }

    func testRuntimeInjectionIsRemovedWhileUserProviderAndModelSettingsSurvive() async throws {
        let fixture = root.appendingPathComponent("findings.json")
        try payload().write(to: fixture)
        let environment = ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent(".codex").path,
            "CODEX_API_KEY": "fixture-only", "ANTHROPIC_MODEL": "configured-alias", "CLAUDE_CODE_EFFORT_LEVEL": "xhigh",
            "CODEX_MODEL": "configured-codex-alias", "CODEX_APP_RUNTIME_CLI_PATH": "/fake/runtime",
            "CODEX_APP_TOOLS_PIPE_PATH": "/fake/pipe", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "injected",
            "CODEX_SESSION_ID": "host-session", "CODEX_PERMISSION_PROFILE": "host-profile", "CODEX_CI": "1", "CLAUDECODE": "1",
            "BASH_ENV": "/fake/startup", "NODE_OPTIONS": "--require /fake/injected.js", "CLAUDE_CODE_ENV_FILE": "/fake/env"]
        let scoped = IntegrationService(home: home, applicationSupport: root.appendingPathComponent("support"), environment: environment)
        let fake = try executable("""
        [ -z "${CODEX_APP_RUNTIME_CLI_PATH+x}" ] || exit 2
        [ -z "${CODEX_APP_TOOLS_PIPE_PATH+x}" ] || exit 2
        [ -z "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE+x}" ] || exit 2
        [ -z "${CODEX_SESSION_ID+x}" ] || exit 2
        [ -z "${CODEX_PERMISSION_PROFILE+x}" ] || exit 2
        [ -z "${CODEX_CI+x}" ] || exit 2
        [ -z "${CLAUDECODE+x}" ] || exit 2
        [ -z "${BASH_ENV+x}" ] || exit 2
        [ -z "${NODE_OPTIONS+x}" ] || exit 2
        [ -z "${CLAUDE_CODE_ENV_FILE+x}" ] || exit 2
        [ "$CODEX_API_KEY" = fixture-only ] || exit 3
        [ "$ANTHROPIC_MODEL" = configured-alias ] || exit 3
        [ "$CLAUDE_CODE_EFFORT_LEVEL" = xhigh ] || exit 3
        [ "$CODEX_MODEL" = configured-codex-alias ] || exit 3
        out=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then out="$2"; shift 2; else shift; fi
        done
        /bin/cat >/dev/null
        /bin/cp \(quote(fixture.path)) "$out"
        /usr/bin/printf '{}\\n'
        """)
        let importer = AgentImportService(integration: scoped, executableOverrides: [.codex: fake], timeout: 5)
        let proposal = try await importer.inspect(platform: .codex)
        XCTAssertEqual(proposal.routes.first?.modelID, "gpt-6.1-sol")
        XCTAssertEqual(environment["CODEX_APP_RUNTIME_CLI_PATH"], "/fake/runtime")
    }

    func testQuickObserverUsesMechanicalModelWithoutClaimingItAsConfiguredCoordinator() async throws {
        let fixture = root.appendingPathComponent("quick-findings.json")
        try payload().write(to: fixture)
        let captured = root.appendingPathComponent("quick-arguments.txt")
        let fake = try executable("""
        /usr/bin/printf '%s\\n' "$@" > \(quote(captured.path))
        out=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then out="$2"; shift 2; else shift; fi
        done
        /bin/cat >/dev/null
        /bin/cp \(quote(fixture.path)) "$out"
        /usr/bin/printf '{}\\n'
        """)
        let proposal = try await AgentImportService(integration: integration, executableOverrides: [.codex: fake]).inspect(platform: .codex)
        let flags = try String(contentsOf: captured, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertTrue(flags.contains("gpt-6-luna"))
        XCTAssertTrue(flags.contains("model_reasoning_effort=\"low\""))
        XCTAssertEqual(proposal.routes.first?.modelID, "gpt-6.1-sol")
    }

    func testQuickUnavailableModelWithoutSavedCoordinatorFailsWithoutRetry() async throws {
        let attempts = root.appendingPathComponent("attempts.txt")
        let fake = try executable("""
        /usr/bin/printf x >> \(quote(attempts.path))
        /bin/cat >/dev/null
        /usr/bin/printf 'unsupported model' >&2
        exit 1
        """)
        do {
            _ = try await AgentImportService(integration: integration, executableOverrides: [.claude: fake]).inspect(platform: .claude)
            XCTFail("Unavailable Haiku must not trigger a native/default model retry")
        } catch {
            guard case AgentImportError.modelUnavailable = error else { return XCTFail("Expected quick-model unavailability, received \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("No other model was started"))
        }
        XCTAssertEqual(try String(contentsOf: attempts, encoding: .utf8), "x")
    }

    func testQuickUnavailableModelRecoversOnlyLocallySavedCoordinatorWithoutPremiumRetry() async throws {
        for platform in AgentPlatform.allCases {
            let savedModel = platform == .codex ? "gpt-6-astra" : "claude-opus-5-5"
            let savedEffort = platform == .codex ? "ultra" : "xhigh"
            let settings = home.appendingPathComponent(platform == .codex ? ".codex/config.toml" : ".claude/settings.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = platform == .codex
                ? "model = \"\(savedModel)\"\nmodel_reasoning_effort = \"\(savedEffort)\"\n"
                : "{\"model\":\"\(savedModel)\",\"effortLevel\":\"\(savedEffort)\"}"
            try content.write(to: settings, atomically: true, encoding: .utf8)
            let attempts = root.appendingPathComponent("\(platform.rawValue)-quick-attempts.txt")
            let arguments = root.appendingPathComponent("\(platform.rawValue)-quick-arguments.txt")
            let fake = try executable("""
            /usr/bin/printf x >> \(quote(attempts.path))
            /usr/bin/printf '%s\\n' "$@" > \(quote(arguments.path))
            /bin/cat >/dev/null
            /usr/bin/printf 'unsupported model' >&2
            exit 1
            """)
            let proposal = try await AgentImportService(integration: integration, executableOverrides: [platform: fake]).inspect(platform: platform)
            XCTAssertEqual(try String(contentsOf: attempts, encoding: .utf8), "x")
            let flags = try String(contentsOf: arguments, encoding: .utf8).components(separatedBy: "\n")
            XCTAssertFalse(flags.contains(savedModel))
            XCTAssertTrue(flags.contains(platform == .codex ? "gpt-6-luna" : "claude-haiku-5-5"))
            XCTAssertTrue(flags.contains(platform == .codex ? "model_reasoning_effort=\"low\"" : "low"))
            XCTAssertEqual(proposal.routes.count, 1)
            XCTAssertEqual(proposal.routes.first?.category, .coordinator)
            XCTAssertEqual(proposal.routes.first?.scope, .current)
            XCTAssertEqual(proposal.routes.first?.modelID, savedModel)
            XCTAssertEqual(proposal.routes.first?.effort, .fixed(savedEffort))
            XCTAssertNil(proposal.executionModelID)
            XCTAssertTrue(proposal.uncertainties.contains { $0.contains("No other model was started") && $0.contains("Other routing preferences were not inspected") })
        }
    }

    func testMissingQuickCodexCatalogModelRecoversSavedCoordinatorWithoutStartingInference() async throws {
        let settings = home.appendingPathComponent(".codex/config.toml")
        try "model = \"gpt-6-astra\"\nmodel_reasoning_effort = \"ultra\"\n".write(to: settings, atomically: true, encoding: .utf8)
        let inference = root.appendingPathComponent("missing-luna-inference.txt")
        let fake = try executable("/usr/bin/printf started > \(quote(inference.path))", modelIDs: ["gpt-6-astra"])
        let proposal = try await AgentImportService(integration: integration, executableOverrides: [.codex: fake]).inspect(platform: .codex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inference.path))
        XCTAssertEqual(proposal.routes.count, 1)
        XCTAssertEqual(proposal.routes.first?.category, .coordinator)
        XCTAssertEqual(proposal.routes.first?.scope, .current)
        XCTAssertEqual(proposal.routes.first?.modelID, "gpt-6-astra")
        XCTAssertEqual(proposal.routes.first?.effort, .fixed("ultra"))
        XCTAssertNil(proposal.executionModelID)
        XCTAssertTrue(proposal.uncertainties.contains { $0.contains("public model catalogue") && $0.contains("No observer model was started") })
    }

    func testQuickQuotaFailureDoesNotRetrySavedPremiumModel() async throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"model\":\"claude-opus-5-5\",\"effortLevel\":\"xhigh\"}".write(to: settings, atomically: true, encoding: .utf8)
        let attempts = root.appendingPathComponent("quota-attempts.txt")
        let fake = try executable("""
        /usr/bin/printf x >> \(quote(attempts.path))
        /bin/cat >/dev/null
        /usr/bin/printf 'unsupported model: quota reached' >&2
        exit 1
        """)
        do {
            _ = try await AgentImportService(integration: integration, executableOverrides: [.claude: fake]).inspect(platform: .claude)
            XCTFail("A quick observer quota failure must remain explicit")
        } catch {
            guard case AgentImportError.failed = error else { return XCTFail("Expected explicit inspection failure, received \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("provider usage limits"))
        }
        XCTAssertEqual(try String(contentsOf: attempts, encoding: .utf8), "x")
    }

    func testToollessProtocolResponseIsNotReportedAsSuccessfulCurrentRead() async throws {
        let fixture = root.appendingPathComponent("no-tools.json")
        let body: [String: Any] = ["summary": "No read/search tool is available.", "routes": [], "sources": [], "uncertainties": []]
        try JSONSerialization.data(withJSONObject: body).write(to: fixture)
        let fake = try executable("""
        out=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then out="$2"; shift 2; else shift; fi
        done
        /bin/cat >/dev/null
        /bin/cp \(quote(fixture.path)) "$out"
        /usr/bin/printf '{}\\n'
        """)
        do {
            _ = try await AgentImportService(integration: integration, executableOverrides: [.codex: fake]).inspect(platform: .codex)
            XCTFail("Tool-less read should not be marked successful")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no current settings were verified")) }
    }

    func testCodexLargeEventStreamDoesNotRejectBoundedValidStructuredResult() async throws {
        let fixture = root.appendingPathComponent("bounded-result.json")
        try payload().write(to: fixture)
        let fake = try executable("""
        out=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then out="$2"; shift 2; else shift; fi
        done
        /bin/cat >/dev/null
        /usr/bin/yes event-log | /usr/bin/head -c 131072
        /bin/cp \(quote(fixture.path)) "$out"
        """)
        let importer = AgentImportService(integration: integration, executableOverrides: [.codex: fake], timeout: 5, maximumOutputBytes: 4096)
        let proposal = try await importer.inspect(platform: .codex)
        XCTAssertEqual(proposal.routes.first?.modelID, "gpt-6.1-sol")
    }

    func testForeignCoordinatorCannotHideOrReplaceNativeCoordinator() throws {
        let body: [String: Any] = ["routes": [
            ["category": "coordinator", "modelID": "gpt-6.1-sol", "modelPlatform": "codex"],
            ["category": "coordinator", "modelID": "fable[1m]", "modelPlatform": "claude", "effort": ["mode": "fixed", "value": "xhigh"]]
        ]]
        let result = try AgentImportService.decode(JSONSerialization.data(withJSONObject: body), platform: .claude, cwd: home)
        XCTAssertEqual(result.routes.count, 1)
        XCTAssertEqual(result.routes.first?.modelID, "fable[1m]")
        XCTAssertEqual(result.routes.first?.effort, .fixed("xhigh"))
        XCTAssertTrue(result.uncertainties.contains { $0.contains("other harness") })
    }

    func testDecoderKeepsCurrentAndUsualFindingsForOneCategory() throws {
        let body: [String: Any] = ["routes": [
            ["category": "coordinator", "scope": "current", "modelID": "fable-installed", "modelPlatform": "claude"],
            ["category": "coordinator", "scope": "usual", "modelID": "gpt-project-lead", "modelPlatform": "codex"],
            ["category": "planning", "modelID": "opus-backward-compatible"]
        ]]
        let proposal = try AgentImportService.decode(JSONSerialization.data(withJSONObject: body), platform: .claude, cwd: home)
        XCTAssertEqual(proposal.routes.count, 3)
        XCTAssertEqual(proposal.routes.filter { $0.category == .coordinator }.map(\.scope), [.current, .usual])
        XCTAssertEqual(Set(proposal.routes.map(\.id)).count, 3)
        XCTAssertEqual(proposal.routes.last?.scope, .current, "Older responses without scope retain the current default.")
    }

    func testPromptMapsExplicitVersionedLabelsAndExtractsKnownTeamsWithoutInventingEffort() throws {
        let snapshot = AgentImportSnapshot.capture(platform: .claude, home: home,
            codexHome: home.appendingPathComponent(".codex"), claudeHome: home.appendingPathComponent(".claude"), project: nil)
        let custom = ModelSpec(id: "gpt-known-custom", label: "Known Custom 2", platform: .codex, defaultEffort: "ultra")
        let models = ModelSpec.builtIn + [custom]
        let brief = AgentImportService.prompt(platform: .claude, cwd: home, snapshot: snapshot, referenceModels: models)
        let reference = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(AgentImportService.modelReference(models).utf8)) as? [[String: String]])
        XCTAssertEqual(reference.first { $0["label"] == "Opus 5.5" }?["modelID"], "claude-opus-5-5")
        XCTAssertEqual(reference.first { $0["label"] == "Fable 5.1" }?["modelID"], "claude-fable-5-1")
        XCTAssertEqual(reference.first { $0["label"] == "Haiku 5.5" }?["modelID"], "claude-haiku-5-5")
        XCTAssertEqual(reference.first { $0["label"] == "Sol 6.1" }?["modelID"], "gpt-6.1-sol")
        XCTAssertEqual(reference.first { $0["label"] == "Known Custom 2" }?["modelID"], "gpt-known-custom")
        XCTAssertTrue(reference.allSatisfy { Set($0.keys) == ["label", "modelID", "modelPlatform"] })
        XCTAssertTrue(brief.contains("Preserve exact saved current model IDs/aliases unchanged, including fable[1m]"))
        XCTAssertTrue(brief.contains("generic unversioned name such as Opus stays alias \"opus\""))
        XCTAssertTrue(brief.contains("BOTH named models build UI for comparison establishes two known workers"))
        XCTAssertTrue(brief.contains("set each unknown effort to null"))
        XCTAssertTrue(brief.contains("Every explicit category/model choice described in your summary must also appear in routes"))
        XCTAssertTrue(brief.contains("StandMixer Auto follows the caller's requested or effective reasoning intensity"))
        XCTAssertTrue(brief.contains("preserve an explicit legacy Auto setting as auto"))
        XCTAssertTrue(brief.contains("A source requiring only the target model's default does NOT establish follow-caller Auto: report its effort as null with uncertainty"))
    }

    private func executable(_ body: String, inventory: String? = "[]", modelIDs: [String]? = nil) throws -> URL {
        let url = root.appendingPathComponent("fake-agent-\(UUID().uuidString)")
        let models = modelIDs ?? (ModelSpec.builtIn.filter { $0.platform == .codex }.map(\.id) + ["gpt-saved-native"])
        let catalog = try JSONSerialization.data(withJSONObject: ["models": Array(Set(models)).sorted().map {
            ["slug": $0, "apply_patch_tool_type": "freeform", "experimental_supported_tools": ["exec_command"], "tool_mode": "code"] as [String: Any]
        }])
        let metadataPreflight = """
        for argument in "$@"; do
          if [ "$argument" = models ]; then /usr/bin/printf '%s' \(quote(String(decoding: catalog, as: UTF8.self))); exit 0; fi
          if [ "$argument" = prompt-input ]; then /usr/bin/printf '%s' '[{"type":"additional_tools","tools":[{"type":"namespace","name":"functions","tools":[{"type":"function","name":"request_user_input"}]}]}]'; exit 0; fi
        done
        """ + "\n"
        let preflight = inventory.map { value in
            "for argument in \"$@\"; do if [ \"$argument\" = mcp ]; then /usr/bin/printf '%s' \(quote(value)); exit 0; fi; done\n"
        } ?? ""
        try ("#!/bin/sh\n" + metadataPreflight + preflight + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func payload() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["summary": "Existing explicit routing", "routes": [
            ["category": "implementation", "modelID": "gpt-6.1-sol", "modelPlatform": "codex",
             "effort": ["mode": "fixed", "value": "ultra", "minimum": NSNull(), "maximum": NSNull()],
             "evidence": [["path": "/fixture/AGENTS.md", "explanation": "Explicit instruction"]], "uncertainties": [],
             "additionalAgents": NSNull(), "resultMode": NSNull(), "judgeModelID": NSNull(), "scope": "current"]
        ], "sources": [], "uncertainties": []])
    }
}
