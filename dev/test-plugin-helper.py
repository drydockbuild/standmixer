#!/usr/bin/env python3
"""Exercise the packaged binary and installer using isolated homes; no inference."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile
import tomllib

project = Path(__file__).resolve().parent.parent
engine = project / "Plugins/claude-standmixer/bin/StandMixerHelper"
bootstrap = project / "Plugins/claude-standmixer/scripts/bootstrap.sh"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', type=Path, default=engine)
engine = parser.parse_args().helper.resolve()

with tempfile.TemporaryDirectory(prefix="standmixer-plugin-e2e-", dir="/private/tmp") as temporary:
    home = Path(temporary) / "home"
    for platform in ["codex", "claude"]:
        cli = home / ".local/bin" / platform
        cli.parent.mkdir(parents=True, exist_ok=True)
        cli.write_text("#!/bin/sh\nexit 99\n")
        cli.chmod(0o700)
    codex = home / ".codex/config.toml"
    claude = home / ".claude/settings.json"
    codex.parent.mkdir(parents=True)
    claude.parent.mkdir(parents=True)
    codex.write_text('model = "original-codex"\nmodel_reasoning_effort = "high"\n[unrelated]\nkeep = true\n')
    claude.write_text('{"model":"original-claude","permissions":{"deny":["Bash(rm *)"]}}\n')

    def call(action, **fields):
        result = subprocess.run([str(engine), "--test-home", str(home)], input=json.dumps({"action": action, **fields}), text=True, capture_output=True, timeout=30)
        response = json.loads(result.stdout)
        assert (result.returncode == 0) == response["ok"], response
        return response

    initial = call("state")
    assert set(initial) == {"ok", "state"}
    state = initial["state"]
    assert set(state).issubset({"configuration", "hasSavedDraft", "previousDraft", "enabledPlatforms", "preferredPlatforms",
                               "availablePlatforms", "presets", "catalog", "connections", "installation", "savedPresets",
                               "nativeSettings", "inspection", "canRestore", "installedMac", "canCheckUpdates", "releaseVersion", "notes"})
    assert set(state["availablePlatforms"]) == {"codex", "claude"}
    assert not state["installation"]["hasInstallation"]
    assert not (home / "Library/Application Support/StandMixer").exists()
    assert call("unsupportedAction")["error"]["code"] == "invalidRequest"
    inspection = call("inspect")["inspection"]
    assert all(report["status"] == "failed" and "Fixture inspection is disabled" in report["error"] for report in inspection["reports"])
    assert call("inspect")["inspection"]["fromCache"]
    fast = next(p["configuration"] for p in state["presets"] if p["id"] == "fast")
    plan = call("preview", configuration=fast, platforms=["codex", "claude"])["preview"]
    # Auto preserves both native defaults; canonical controls and routes add12files.
    assert plan["changedFiles"] == 12
    assert all("before" not in file and "after" not in file for file in plan["changes"])
    assert tomllib.loads(codex.read_text())["model"] == "original-codex"
    instructions = home / ".codex/AGENTS.md"
    instructions.write_text("# changed after review\n")
    assert call("apply", previewID=plan["id"])["error"]["code"] == "conflict"
    assert not (home / ".claude/CLAUDE.md").exists()
    assert instructions.read_text() == "# changed after review\n"
    plan = call("preview", configuration=fast, platforms=["codex", "claude"])["preview"]
    assert call("apply", previewID=plan["id"])["ok"]
    assert tomllib.loads(codex.read_text())["model"] == "original-codex"
    assert json.loads(claude.read_text())["model"] == "original-claude"
    assert not call("apply", previewID=plan["id"])["ok"]
    state = call("state")["state"]
    assert state["installation"]["state"] == "applied"
    fast_files = {file["path"]: Path(file["path"]).read_bytes() for file in plan["changes"]}
    high = next(p["configuration"] for p in state["presets"] if p["id"] == "high")
    plan = call("preview", configuration=high, platforms=["codex", "claude"])["preview"]
    assert call("apply", previewID=plan["id"])["ok"]
    plan = call("previewRestore")["preview"]
    assert call("restore", previewID=plan["id"])["ok"]
    assert all(Path(path).read_bytes() == content for path, content in fast_files.items())
    plan = call("previewUninstall")["preview"]
    assert call("uninstall", previewID=plan["id"])["ok"]
    assert tomllib.loads(codex.read_text())["model"] == "original-codex"
    assert tomllib.loads(codex.read_text())["unrelated"]["keep"]
    assert json.loads(claude.read_text())["model"] == "original-claude"
    assert not call("state")["state"]["installation"]["hasInstallation"]
    assert instructions.read_text() == "# changed after review\n"
    print("Packaged helper: state contract, unsupported action, exact review/apply, stale rejection, two presets, restore, and original-baseline uninstall passed.")

    def install():
        return subprocess.run([str(engine), "--test-home", str(home), "--bootstrap"], capture_output=True, text=True, timeout=30)

    resolved = subprocess.run(["/bin/sh", str(bootstrap)], capture_output=True, text=True, timeout=30, check=True)
    assert Path(resolved.stdout.strip()) == project / "Plugins/claude-standmixer/bin/StandMixerHelper"

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: install(), range(4)))
    assert all(result.returncode == 0 for result in results), [result.stderr for result in results]
    installed = Path(results[0].stdout.strip())
    assert installed.parent.name == 'runtime'
    receipt = installed.parent / ".engine.sha256"
    assert installed.read_bytes() == engine.read_bytes()
    legacy = installed.parent.parent / 'bin/StandMixerHelper'
    legacy.parent.mkdir(exist_ok=True)
    legacy.write_text('older plugin engine\n')
    assert install().returncode == 0
    assert installed.read_bytes() == engine.read_bytes()
    assert legacy.read_text() == 'older plugin engine\n'
    receipt.write_text("interrupted-receipt\n")
    assert install().returncode == 0
    assert receipt.read_text().strip() == hashlib.sha256(engine.read_bytes()).hexdigest()
    installed.write_bytes(installed.read_bytes() + b"user edit")
    modified = installed.read_bytes()
    assert install().returncode != 0
    assert installed.read_bytes() == modified
    installed.unlink()
    other = home / "unrelated-file"
    other.write_text("keep me")
    installed.symlink_to(other)
    assert install().returncode != 0
    assert other.read_text() == "keep me"
    print("Packaged installer: concurrent install, interrupted-receipt repair, user edits, and symlink protection passed.")
