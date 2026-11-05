#!/usr/bin/env python3
"""Test native Codex plugin loading and interactive MCP without chats or inference.

Requires an installed Codex CLI and a built helper. All installation metadata,
plugin cache files, and settings fixtures live in a temporary directory.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time


class RPC:
    def __init__(self, command, *, env, cwd, mcp=False):
        self.process = subprocess.Popen(command, env=env, cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, bufsize=1, start_new_session=True)
        self.messages = queue.Queue()
        self.next_id = 0
        self.mcp = mcp
        self.readers = [threading.Thread(target=self.read_stdout, daemon=True),
                        threading.Thread(target=self.read_stderr, daemon=True)]
        for reader in self.readers:
            reader.start()

    def read_stdout(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                self.messages.put({"invalidJSON": True})
        self.messages.put(None)

    def read_stderr(self):
        # Drain diagnostics without dumping host configuration or account paths.
        for _ in self.process.stderr:
            pass

    def send(self, method, params=None, identifier=None):
        message = {"method": method}
        if self.mcp:
            message["jsonrpc"] = "2.0"
        if identifier is not None:
            message["id"] = identifier
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params=None, timeout=20):
        self.next_id += 1
        identifier = self.next_id
        self.send(method, params, identifier)
        deadline = time.monotonic() + timeout
        while True:
            try:
                message = self.messages.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                raise AssertionError(f"{method} did not reply while stdin remained open") from None
            assert message is not None, f"RPC process exited before {method} replied"
            assert not message.get("invalidJSON"), "RPC stdout contained non-protocol output"
            if "id" in message and "method" in message:
                raise AssertionError(f"Unexpected host request: {message['method']}")
            if message.get("id") != identifier:
                continue
            assert "error" not in message, f"{method} returned an RPC error"
            assert "result" in message, f"{method} returned no result"
            assert not self.process.stdin.closed, "RPC test closed stdin too early"
            return message["result"]

    def __enter__(self):
        return self

    def __exit__(self, *_):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
        for reader in self.readers:
            reader.join(timeout=1)
        self.process.stdout.close()
        self.process.stderr.close()


def install_fixture(codex, marketplace, selector, env, cwd):
    for arguments in (["plugin", "marketplace", "add", str(marketplace)],
                      ["plugin", "add", selector, "--json"]):
        result = subprocess.run([str(codex), *arguments], env=env, cwd=cwd,
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, f"Codex {' '.join(arguments[:2])} failed in the isolated fixture"


def native_loader(codex, marketplace, plugin_name, selector, package, env, cwd):
    with RPC([str(codex), "app-server", "--stdio"], env=env, cwd=cwd) as rpc:
        rpc.request("initialize", {"clientInfo": {"name": "standmixer_native_test", "version": "1"},
                                   "capabilities": {"experimentalApi": True}})
        rpc.send("initialized")
        plugin = rpc.request("plugin/read", {
            "marketplacePath": str(marketplace / ".agents/plugins/marketplace.json"),
            "pluginName": plugin_name})["plugin"]
        assert plugin["summary"]["installed"] and plugin["summary"]["enabled"], "Fixture plugin is not enabled"
        assert plugin["mcpServers"] == ["standmixer"], "Codex ignored the bundled MCP declaration"
        catalog = rpc.request("mcpServerStatus/list", {"detail": "full", "limit": 100})
        assert catalog.get("nextCursor") is None, "Unexpected extra MCP catalog page"
        assert len(catalog["data"]) == 1, "Expected only the fixture MCP server"
        server = catalog["data"][0]
        assert server["name"] == "standmixer" and server["pluginId"] == selector
        assert server["toolsError"] is None and server["httpOrigin"] is None
        tools = server["tools"]
        assert set(tools) == {"open_standmixer", "standmixer_action"}, "Native tool discovery failed"
        icons = tools["open_standmixer"].get("icons", [])
        assert {icon["theme"] for icon in icons} == {"light", "dark"}, "Native entrypoint lost themed icons"
        for icon in icons:
            assert icon["mimeType"] == "image/png" and icon["sizes"] == ["128x128"], "SVG icons are recolored by Codex"
            prefix = "data:image/png;base64,"
            assert icon["src"].startswith(prefix), "Sidebar icon must work without a network request"
            decoded = base64.b64decode(icon["src"][len(prefix):], validate=True)
            assert decoded.startswith(b"\x89PNG\r\n\x1a\n")
            assert int.from_bytes(decoded[16:20], "big") == 128 and int.from_bytes(decoded[20:24], "big") == 128
            assert decoded[25] == 6, "Sidebar icons must retain RGB color and alpha"
            name = "standmixer-sidebar-" + icon["theme"] + ".png"
            assert decoded == (Path(__file__).resolve().parent.parent / "brand" / name).read_bytes()
        assert server["serverInfo"]["icons"] == icons, "Server icon fallback differs from the entrypoint"
        opening = tools["open_standmixer"]["_meta"]
        uri = opening["ui"]["resourceUri"]
        assert uri == "ui://standmixer/settings.html"
        assert set(opening["ui"]["visibility"]) == {"model", "app"}
        assert {entry["type"] for entry in opening["openai/ui"]["entrypoints"]} == {"thread", "global"}
        assert tools["standmixer_action"]["_meta"]["ui"]["visibility"] == ["app"]
        contents = rpc.request("mcpServer/resource/read", {"server": server["name"], "uri": uri})["contents"]
        assert len(contents) == 1 and contents[0]["mimeType"] == "text/html;profile=mcp-app"
        assert contents[0]["text"].encode() == (package / "ui/index.html").read_bytes(), "Native HTML differs from bundled HTML"
        assert rpc.request("thread/loaded/list", {})["data"] == [], "The test must not create chats"
    print("Native Codex: passed (installed package, stdio tools, UI entrypoints, exact HTML; no chats)")


def interactive_helper(package, settings, env, cwd):
    command = [str(package / "bin/AgentMixHelper"), "--test-home", str(settings),
               "--mcp", "--ui-root", str(package / "ui")]
    with RPC(command, env=env, cwd=cwd, mcp=True) as rpc:
        rpc.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                   "clientInfo": {"name": "standmixer_fixture", "version": "1"}}, timeout=5)
        rpc.send("notifications/initialized")
        opened = rpc.request("tools/call", {"name": "open_standmixer", "arguments": {}}, timeout=5)
        assert opened["structuredContent"]["ok"] and not opened.get("isError")
        assert opened["_meta"]["ui"]["resourceUri"] == "ui://standmixer/settings.html"
        response = rpc.request("tools/call", {"name": "standmixer_action", "arguments": {"action": "state"}}, timeout=5)
        assert response["structuredContent"]["ok"] and not response.get("isError")
        state = response["structuredContent"]["state"]
        assert {"configuration", "presets", "catalog", "nativeSettings"}.issubset(state)
        assert set(state["availablePlatforms"]) == {"codex", "claude"}
    assert not (settings / ".codex").exists() and not (settings / ".claude").exists(), "State read created native settings"
    print("Interactive MCP: passed (initialize, open, state with stdin open; no settings writes)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", help="Codex executable; defaults to codex on PATH")
    parser.add_argument("--helper", type=Path, help="Use a freshly built helper in the temporary package")
    args = parser.parse_args()
    codex_path = shutil.which(args.codex or "codex")
    if not codex_path:
        parser.error("Install Codex or provide --codex")
    codex = Path(codex_path).resolve()
    repo = Path(__file__).resolve().parent.parent
    source_package = repo / "Plugins/codex-agentmix"
    plugin_name = json.loads((source_package / "plugin.json").read_text())["name"]
    catalog = json.loads((repo / ".agents/plugins/marketplace.json").read_text())
    entries = [entry for entry in catalog["plugins"] if entry["name"] == plugin_name]
    assert len(entries) == 1 and entries[0]["source"]["source"] == "local"
    relative = Path(entries[0]["source"]["path"])
    assert not relative.is_absolute() and ".." not in relative.parts
    assert (repo / relative).resolve() == source_package.resolve()
    catalog["plugins"] = entries
    with tempfile.TemporaryDirectory(prefix="standmixer-native-") as temporary:
        root = Path(temporary).resolve()
        settings, host_home, marketplace = root / "settings", root / "host", root / "marketplace"
        fake_bin = settings / ".local/bin"
        fake_bin.mkdir(parents=True)
        marker = root / "unexpected-cli-execution"
        for name in ("codex", "claude"):
            fake = fake_bin / name
            fake.write_text('#!/bin/sh\n: > "$STANDMIXER_CLI_MARKER"\nexit 1\n')
            fake.chmod(0o700)
        codex_home = host_home / ".codex"
        codex_home.mkdir(parents=True)
        (codex_home / "config.toml").write_text('cli_auth_credentials_store = "file"\n'
                                                'sandbox_mode = "read-only"\n'
                                                'approval_policy = "on-request"\n')
        # These subprocess-only homes are fresh fixtures, with no inherited auth
        # or provider environment. Real Codex is invoked only by its resolved path.
        env = {"PATH": str(fake_bin) + os.pathsep + os.defpath, "HOME": str(host_home),
               "CODEX_HOME": str(codex_home), "CLAUDE_CONFIG_DIR": str(host_home / ".claude"),
               "TMPDIR": str(root), "LANG": "en_US.UTF-8", "RUST_LOG": "error",
               "STANDMIXER_CLI_MARKER": str(marker)}
        package = marketplace / relative
        shutil.copytree(source_package, package)
        if args.helper:
            shutil.copy2(args.helper.resolve(), package / "bin/AgentMixHelper")
        assert os.access(package / "bin/AgentMixHelper", os.X_OK), "Build the helper or provide --helper"
        manifest = marketplace / ".agents/plugins/marketplace.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps(catalog))
        selector = plugin_name + "@" + catalog["name"]
        install_fixture(codex, marketplace, selector, env, root)
        native_loader(codex, marketplace, plugin_name, selector, package, env, root)
        interactive_helper(package, settings, env, root)
        assert not marker.exists(), "A fixture model CLI was unexpectedly launched"
        assert not (codex_home / "auth.json").exists(), "The test must not authenticate"
    print("Passed: no inference, HTTP listener, authentication, or real configuration changes.")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit("FAIL: " + str(error)) from None
