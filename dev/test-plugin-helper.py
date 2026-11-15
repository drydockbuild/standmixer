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
    marker = home / "unexpected-cli-execution"
    for platform in ["codex", "claude"]:
        cli = home / ".local/bin" / platform
        cli.parent.mkdir(parents=True, exist_ok=True)
        cli.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\nexit 99\n")
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
    invalid_resolver = subprocess.run([str(engine), "--test-home", str(home), "--standmixer", "resolve-cli", "invalid"], text=True, capture_output=True, timeout=10)
    assert invalid_resolver.returncode != 0 and not invalid_resolver.stdout
    assert "resolve-cli <claude|codex>" in invalid_resolver.stderr
    assert set(initial) == {"ok", "state"}
    state = initial["state"]
    assert set(state).issubset({"configuration", "hasSavedDraft", "previousDraft", "enabledPlatforms", "preferredPlatforms",
                               "availablePlatforms", "presets", "catalog", "connections", "installation", "savedPresets",
                               "nativeSettings", "canRestore", "installedMac", "canCheckUpdates", "canConnectClaude", "releaseVersion", "notes"})
    assert set(state["availablePlatforms"]) == {"codex", "claude"}
    assert not state["installation"]["hasInstallation"]
    assert not (home / "Library/Application Support/StandMixer").exists()
    assert call("unsupportedAction")["error"]["code"] == "invalidRequest"
    for retired in ("inspect", "checkAccounts"):
        assert call(retired)["error"]["code"] == "retiredAction"
    assert call("inspect", platforms=["codex", "claude"], refresh=True)["error"]["code"] == "retiredAction"
    assert not (home / "Library/Application Support/StandMixer").exists()
    fast = next(p["configuration"] for p in state["presets"] if p["id"] == "fast")
    plan = call("preview", configuration=fast, platforms=["codex", "claude"])["preview"]
    # Worker definitions vary with the preset's model/effort assignments. Check
    # the plan contract and required routing files instead of a legacy count.
    assert plan["changedFiles"] > 0
    assert plan["changedFiles"] == sum(file["isChanged"] for file in plan["changes"])
    planned_paths = [Path(file["path"]).resolve() for file in plan["changes"] if file["isChanged"]]
    assert all(path.is_relative_to(home.resolve()) for path in planned_paths)
    assert (home / ".codex/AGENTS.md").resolve() in planned_paths
    assert (home / ".claude/CLAUDE.md").resolve() in planned_paths
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
    assert not marker.exists(), "Fixture CLI was executed by settings workflow"
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
