#!/usr/bin/env python3
"""Fixture-only MCP and loopback HTTP smoke checks. Never starts inference."""
import argparse
import json
import os
import pathlib
import select
import signal
import subprocess
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=pathlib.Path)
    parser.add_argument("ui_root", type=pathlib.Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="standmixer-embedded-smoke-") as directory:
        root = pathlib.Path(directory)
        home = root / "home"
        (home / ".local/bin").mkdir(parents=True)
        marker = root / "unexpected-cli-execution"
        for cli in ("claude", "codex"):
            file = home / ".local/bin" / cli
            file.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\nexit 1\n")
            file.chmod(0o700)
        base = [str(args.helper.resolve()), "--test-home", str(home), "--ui-root", str(args.ui_root.resolve())]
        methods = [
            ("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}}),
            ("tools/list", {}),
            ("resources/read", {"uri": "ui://standmixer/settings.html"}),
            ("tools/call", {"name": "open_standmixer", "arguments": {}}),
            ("tools/call", {"name": "standmixer_action", "arguments": {"action": "inspect", "platforms": ["codex"]}}),
        ]
        requests = "".join(json.dumps({"jsonrpc": "2.0", "id": index + 1, "method": method, "params": params}) + "\n"
                           for index, (method, params) in enumerate(methods))
        completed = subprocess.run(base + ["--mcp"], input=requests, text=True, capture_output=True, timeout=30)
        assert completed.returncode == 0, completed.stderr
        responses = {result["id"]: result for result in map(json.loads, completed.stdout.splitlines())}
        assert len(responses) == len(methods)
        assert responses[1]["result"]["protocolVersion"] == "2025-11-25"
        assert len(responses[2]["result"]["tools"]) == 2
        action_tool = next(tool for tool in responses[2]["result"]["tools"] if tool["name"] == "standmixer_action")
        properties = action_tool["inputSchema"]["properties"]
        assert set(properties["action"]["enum"]) == {"state", "inspect", "saveDraft", "savePreset", "deletePreset", "preview",
                                                    "apply", "previewUninstall", "uninstall", "previewRestore", "restore",
                                                    "installMac", "openWeb", "openMac", "checkAccounts", "checkUpdates"}
        assert set(properties) == {"action", "configuration", "platforms", "previewID", "presetID", "name", "refresh"}
        assert responses[3]["result"]["contents"][0]["mimeType"] == "text/html;profile=mcp-app"
        assert responses[4]["result"]["structuredContent"]["ok"]
        unsupported = [{"action": "unsupportedAction"}, {"action": "state", "unexpectedField": True}]
        invalid_requests = "".join(json.dumps({"jsonrpc": "2.0", "id": index + 1, "method": "tools/call",
                                               "params": {"name": "standmixer_action", "arguments": arguments}}) + "\n"
                                  for index, arguments in enumerate(unsupported))
        invalid = subprocess.run(base + ["--mcp"], input=invalid_requests, text=True, capture_output=True, timeout=30)
        assert invalid.returncode == 0, invalid.stderr
        rejected = list(map(json.loads, invalid.stdout.splitlines()))
        assert len(rejected) == len(unsupported)
        assert all(response["result"]["structuredContent"]["error"]["code"] == "invalidRequest" for response in rejected)
        assert not marker.exists(), "Fixture CLI was executed"
        print("MCP stdio: passed (settings schema, 5 responses, unsupported action/field rejected, no CLI execution)")

        process = subprocess.Popen(base + ["--serve-ui", "--detached-ui"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            readable, _, _ = select.select([process.stdout], [], [], 10)
            assert readable, "Server did not publish its session within 10 seconds"
            line = process.stdout.readline()
            assert line, "Server exited: " + process.stderr.read()
            session = json.loads(line)
            assert os.getpgid(process.pid) == process.pid, "UI service must own a session outside its launcher group"
            parts = urllib.parse.urlsplit(session["url"])
            origin = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "", "", ""))
            token = urllib.parse.parse_qs(parts.fragment)["token"][0]
            assert parts.hostname == "127.0.0.1" and len(token) == 43
            with urllib.request.urlopen(origin + "/", timeout=5) as response:
                html = response.read()
                assert response.headers["Content-Security-Policy"].startswith("default-src 'none'")
                assert b"StandMixer" in html
            data = json.dumps({"action": "state"}).encode()
            headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token, "Origin": origin}
            request = urllib.request.Request(origin + "/api", data=data, headers=headers)
            with urllib.request.urlopen(request, timeout=5) as response:
                state_response = json.load(response)
                assert state_response["ok"]
                assert set(state_response) == {"ok", "state"}
                assert {"configuration", "presets", "catalog", "nativeSettings"}.issubset(state_response["state"])
            cases = [(dict(headers, Origin="https://evil.test"), 403), (dict(headers, Authorization="Bearer invalid"), 401)]
            for rejected_headers, expected in cases:
                try:
                    urllib.request.urlopen(urllib.request.Request(origin + "/api", data=data, headers=rejected_headers), timeout=5)
                    raise AssertionError("Unauthorized action was accepted")
                except urllib.error.HTTPError as error:
                    assert error.code == expected
            assert not marker.exists(), "Fixture CLI was executed"
            assert not (home / ".codex").exists() and not (home / ".claude").exists(), "Native settings were created"
            print("HTTP socket: passed (bundled HTML, authenticated state, rejected Origin/token, no native writes)")

            def action(name, okay=True, **fields):
                request = urllib.request.Request(origin + "/api", data=json.dumps({"action": name, **fields}).encode(), headers=headers)
                with urllib.request.urlopen(request, timeout=10) as response:
                    result = json.load(response)
                assert result["ok"] == okay, result
                return result

            codex = home / ".codex/config.toml"
            claude = home / ".claude/settings.json"
            codex.parent.mkdir()
            claude.parent.mkdir()
            originals = {
                codex: b'model = "original-codex"\nmodel_reasoning_effort = "high"\n[unrelated]\nkeep = true\n',
                claude: b'{"model":"original-claude","permissions":{"deny":["Bash(rm *)"]}}\n',
            }
            for path, content in originals.items():
                path.write_bytes(content)
            state = action("state")["state"]
            configuration = next(p["configuration"] for p in state["presets"] if p["id"] == "fast")
            native = next(model for model in state["catalog"] if model["platform"] == "codex")
            profile = next(p for p in configuration["profiles"] if p["platform"] == "codex")
            controller = next(route for route in profile["routes"] if route["category"] == "coordinator")
            controller["modelID"] = native["id"]
            controller["effort"] = {"mode": "fixed", "value": "high", "minimum": "low", "maximum": "ultra"}
            reviewed = action("preview", configuration=configuration, platforms=["codex", "claude"])["preview"]
            assert reviewed["changedFiles"] > 0
            paths = [pathlib.Path(change["path"]) for change in reviewed["changes"] if change["isChanged"]]
            assert all(path.is_relative_to(home) for path in paths), "Fixture preview escaped its home"
            assert all(path.read_bytes() == content for path, content in originals.items()), "Preview wrote native settings"
            assert not (home / ".codex/AGENTS.md").exists(), "Preview applied routing"
            action("apply", previewID=reviewed["id"])
            assert tomllib.loads(codex.read_text())["model"] == native["id"]
            assert all(path.is_file() for path in paths)
            installed_files = {path: path.read_bytes() for path in paths}
            assert action("state")["state"]["installation"]["state"] == "applied"
            action("apply", okay=False, previewID=reviewed["id"])

            high = next(p["configuration"] for p in state["presets"] if p["id"] == "high")
            reviewed = action("preview", configuration=high, platforms=["codex", "claude"])["preview"]
            action("apply", previewID=reviewed["id"])
            reviewed = action("previewRestore")["preview"]
            action("restore", previewID=reviewed["id"])
            assert all(path.read_bytes() == content for path, content in installed_files.items())
            reviewed = action("previewUninstall")["preview"]
            action("uninstall", previewID=reviewed["id"])
            assert not action("state")["state"]["installation"]["hasInstallation"]
            assert all(path.read_bytes() == content for path, content in originals.items()), "Uninstall lost the original native baseline"
            assert all(not path.exists() for path in paths if path not in originals), "Managed fixture files remained"
            assert not marker.exists(), "Fixture CLI was executed"
            print("HTTP settings: passed (stored preview/apply changed temporary native settings and managed files; stale ID rejected; reviewed restore/uninstall restored baseline; no CLI execution)")
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    main()
