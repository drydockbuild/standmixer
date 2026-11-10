# Other-Mac upgrade test: 0.1.4 → 0.1.7

This plan uses 0.1.4 as the baseline and tests an update to 0.1.7, including the new StandMixer paths, update details, restore-point fix, and verified linked-worktree Git instructions. Use the pinned baseline below before running the update.

Do not uninstall first: the existing installation is what this test needs. Version 0.1.0 predates the update command and needs the baseline installer first. Skip the baseline install if that Mac is already on 0.1.4. Do not downgrade a newer installation.

## 1. Prepare the baseline now (~3 minutes)

On the other Mac, install the exact public 0.1.4 commit. This pinned command stays a 0.1.4 installer even after a later release is published:

```sh
sm_test="$(mktemp -d)" && git clone https://github.com/drydockbuild/standmixer.git "$sm_test/standmixer" && git -C "$sm_test/standmixer" checkout --detach 507e531a424e7c280825e320a304b6db1f4f00e8 && /bin/sh "$sm_test/standmixer/install.sh" --no-open
```

Reload Claude plugins or restart Codex. Open StandMixer and save the current setup as **Upgrade test**. Keep a screenshot of the assignments for comparison. Do not reset or remove existing settings.

Expected: StandMixer opens in both installed tools, and the saved preset appears. Your existing setup is still present.

## 2. Test the update after publication (~3 minutes)

After 0.1.7 is published, run **one** of these in the agent chat:

- Codex: `$standmixer update`
- Claude Code: `/standmixer update`

Use the plain update command for this first path-changing upgrade. Build the optional Mac app separately afterward with `install-mac`; the old updater's `--mac` step still references the former source location.

Reload plugins or restart the host, then reopen StandMixer. Sources in Codex/web or Connections in Claude should show **0.1.7**. **Check now** should report the current version and update the check time. The **Upgrade test** preset and assignments should still be there.

This first upgrade retires the old layout into a private recovery folder, retaining presets and drafts. Load the saved setup, review the changes, and **Apply once** to install routing at the new paths and refresh the worker instructions. Start new agent chats to load them. An unrecognized or modified old installation may stop cleanup with a specific conflict; preserve it and report the message rather than deleting anything manually.

## 3. Test a repeated update (~2 minutes)

After Apply, these read-only hashes surrounding a second update check that an unchanged update keeps the previous restore point:

```sh
shasum -a 256 "$HOME/Library/Application Support/StandMixer/last-backup.json"
"$HOME/Library/Application Support/StandMixer/bin/standmixer" update
shasum -a 256 "$HOME/Library/Application Support/StandMixer/last-backup.json"
```

Expected: the updater says the source is current, the two hashes match, saved presets remain, and both panels still open. Do not use Restore merely to test this.

Checks notify; they do not install automatically. A genuine “newer version available” notice requires a later published version, so that part remains a subsequent test.

## Verified locally / still pending

The build checks use isolated homes and fake harnesses, without model calls. They cover generated recipe wording, the published 0.1.4 updater invoking the new installer, saved-preference retention, the new-path launcher, repeated updates, and receipt-order no-op behavior.

The other Mac's real host/plugin reload and upgrade checks above remain pending. Local fixture success is not a report that the other Mac has passed.
