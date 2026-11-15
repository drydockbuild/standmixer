# Other-Mac upgrade test for 0.2.6

Run the test over the existing installation. Version 0.1.4 exercises the one-time migration from the old data layout. Version 0.1.8 or an earlier 0.2.x release exercises a standard update under the current layout.

## 1. Save the starting preset (~3 minutes)

If StandMixer 0.1.4 or newer is already installed, keep that installation and skip the command below. To prepare a legacy baseline on a fresh test Mac or one still on 0.1.0, which predates `update`, use the pinned public 0.1.4 installer.

```sh
sm_test="$(mktemp -d)" && git clone https://github.com/drydockbuild/standmixer.git "$sm_test/standmixer" && git -C "$sm_test/standmixer" checkout --detach 507e531a424e7c280825e320a304b6db1f4f00e8 && /bin/sh "$sm_test/standmixer/install.sh" --no-open
```

Reload Claude plugins or restart Codex. Verify StandMixer opens in each installed tool, then save the current setup as **Upgrade test**. Keep a screenshot of the assignments for comparison and leave the existing settings in place.

## 2. Test the update after publication (~3 minutes)

While 0.2.6 is the current public release, run **one** of these in the agent chat.

- Codex: `$standmixer update`
- Claude Code: `/standmixer update`

For the legacy migration, use the plain update command. If you use the optional Mac app, rebuild it afterward with `install-mac` because the 0.1.4 updater's `--mac` step still references the former source location. For a standard update, you can add `--mac` to rebuild the app at the same time.

Reload Claude plugins or restart Codex, then reopen StandMixer. **Sources** in Codex or **Connections** in Claude should show **0.2.6**. **Check now** should report that StandMixer is up to date and refresh the check time. Confirm the **Upgrade test** preset retains its model and effort assignments. If you rebuilt the Mac app, its window should show **v0.2.6 · build 20**. You can choose **Not now** if a Claude connection prompt appears during the check.

The legacy migration moves the old installation into a private recovery folder and retains presets and drafts. Load **Upgrade test**, review the changes, and **Apply** once to install routing at the new paths. Start new agent chats to load those instructions. If cleanup stops on a conflict, keep the files and report the message. A standard update keeps routing in place and needs no migration Apply step.

## 3. Test a repeated update (~2 minutes)

On the upgraded installation, compare the restore-point hash before and after a second update to the same release. For the legacy path, do this after **Apply**. For the standard path, use an installation that already has a restore point.

```sh
shasum -a 256 "$HOME/Library/Application Support/StandMixer/last-backup.json"
"$HOME/Library/Application Support/StandMixer/bin/standmixer" update
shasum -a 256 "$HOME/Library/Application Support/StandMixer/last-backup.json"
```

The updater should say the source is current, the two hashes should match, and each installed panel should still open with the saved preset. Comparing the hashes checks preservation without using **Restore**.

Version checks report availability. Test the update notice when a later version is published.

## Verification

Local fixtures cover legacy retirement, saved-preference retention, updates, and preserving the restore point on a no-op. They use isolated homes and fake harnesses without model calls. The other-Mac upgrade and real host reload checks remain pending.
