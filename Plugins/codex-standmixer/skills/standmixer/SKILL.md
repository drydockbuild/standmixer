---
name: standmixer
description: Open StandMixer's interactive settings panel inside Codex, or manage model presets for Codex and Claude Code.
---
<!-- Managed by StandMixer. Changes inside this file are replaced on Apply. -->

# StandMixer

With no argument, or when asked to open settings, show the interactive panel. Do not substitute a text status report.

Open the native panel with `open_standmixer`. If unavailable, explain that the plugin connection has not loaded; enable or reload StandMixer and start a fresh chat.

Web is explicit-only: this plugin's `scripts/open-ui.sh` returns a private local URL. Ask for needed permissions only if blocked; do not change global permissions.

Choose and edit presets in the panel. Selection and saving do not apply routing. Review and Apply uses the exact stored preview; never silently apply defaults just to open settings. Uninstall and restore also require their reviewed confirmation.

For an explicit status request, use the bundled helper's `--standmixer status`. For a worker test, run only the requested installed route and report actual execution metadata when available. Opening the UI does not test recipes or model access.

For an explicit `install-mac` request, run `~/Library/Application Support/StandMixer/bin/standmixer install-mac` with the path quoted. It builds and opens the optional Mac app locally; Apple Command Line Tools with Swift 6 are required. Report progress and failures. It does not apply routing, install developer tools, or change Gatekeeper.

For an explicit `update` request, run `"$HOME/Library/Application Support/StandMixer/bin/standmixer" update`. `update --mac` also rebuilds the optional Mac app. Updates preserve presets and model defaults. Report progress and failures; never check for or run updates unprompted.

Controller Auto preserves the currently selected native model. Ordinary questions and small edits need no extra intake or planning agent. Delegation follows task needs, explicit instructions, and project permissions. Settings configure routing and read saved local files without models or required sign-in. For Codex-to-Claude work, use the optional **Connect Claude for Codex** action or the explicit `standmixer connect-claude` command. It runs Claude Code’s official browser login; credentials stay with the CLI. The connection dialog also offers **Log out…** with confirmation for switching accounts. `standmixer logout-claude --yes` signs out that shared CLI profile and requires an explicit user sign-out request; never run it merely to troubleshoot or test a connection. Worker recipes use the checked connection. On a confirmed authentication failure, offer this flow and wait for the user; never automatically replay work that may have started, switch providers, or treat a network/usage error as a sign-in failure.

The UI and local helper manage only known harness settings. Do not read credentials, search personal folders, or manually reconstruct configuration. If this host cannot show the panel, report that specific limitation rather than claiming the UI opened.
