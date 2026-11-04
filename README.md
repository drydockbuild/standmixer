# StandMixer

Free, MIT-licensed model presets for Claude Code and Codex, from Drydock Labs. Apply **Optimized** to get started, or customize each category. [Website](https://standmixer.dev/) · [Roadmap](ROADMAP.md)

## Install

Requires macOS 14+, Git, and an installed Claude Code or Codex CLI. One StandMixer installation connects both tools when available; single-tool setups use native models.

```sh
git clone https://github.com/drydockbuild/standmixer.git && sh standmixer/install.sh
```

The installer opens settings and leaves model defaults unchanged until you apply a preset. The bundled helper needs no compiler, Node, Python, or separate API key.

- **Claude Code:** `/standmixer` opens the native panel. Run `/reload-plugins` or start a new session after installation if needed.
- **Codex:** `$standmixer` opens the native MCP panel. Restart Codex after installing or updating the plugin if its tools have not loaded. This path needs no local HTTP listener.
- **Interface** in either agent opens the web view or optional Mac app.

Terminal installation opens the local web interface. Inside Claude Code or Codex, the installer detects the host and returns native-panel instructions instead. `--host claude` or `--host codex` overrides that detection; `--no-open` installs without opening settings. Choosing Web explicitly starts a loopback-only helper server. If the host blocks session-file writes or a local listener, request its approval rather than changing global permissions.

## Presets and editing

**Fast** uses lighter models, **Optimized** matches models to tasks, and **High** uses stronger models and larger teams. Optimized gives the lead substantive work and helpers focused reviews or design alternatives. High allows fuller independent passes. After choosing a visual design, implementation and ordinary follow-ups stay with its owner.

**Controller: Auto** keeps your current chat model. Worker effort Auto follows the caller at a supported level. Explicit controller pins change defaults for future sessions. Presets guide useful delegation; they do not add mandatory planning, security reviews, or extra agents to ordinary chat.

**Edit → Save** saves a draft; **Undo** reverses draft edits. **Review & apply** shows the actual file changes before applying them. StandMixer checks for intervening edits and keeps recovery data. Start new sessions to load changed routing instructions. Model entries and routing instructions do not prove account access or actual execution.

## Accounts and preferences

**Sources → Check CLI accounts** reads exposed login metadata. External workers use their CLI sign-in, which can differ from the desktop app. StandMixer does not copy credentials, switch accounts, or log anyone out. Cross-provider workers launch directly through the installed CLI, without extra launcher or watcher agents.

Opening settings and editing presets do not run models. **Read preferences** can ask your agent to interpret a bounded snapshot of settings and recent project instructions. It never applies changes automatically; credentials and conversation bodies are excluded.

## Optional Mac app

Choose **Install Mac app** in Interface, or run `/standmixer install-mac` in Claude Code or `$standmixer install-mac` in Codex.

The app builds locally, is ad-hoc signed, and installs in `~/Applications/StandMixer.app`. It follows system appearance. Apple Command Line Tools with Swift 6 and a compatible macOS SDK are required; full Xcode and paid signing are not. If tools are missing, run `xcode-select --install` and complete Apple's installation. No DMG is needed.

## Update and remove

Run the installer from a fresh checkout:

```sh
standmixer_update="$(mktemp -d)" && git clone --depth 1 https://github.com/drydockbuild/standmixer.git "$standmixer_update/standmixer" && /bin/sh "$standmixer_update/standmixer/install.sh"
```

Updates preserve presets, drafts, backups, and modified or unowned files. New code does not automatically apply a different routing preset.

`/standmixer uninstall` or **Sources → Remove StandMixer settings** previews restoration of the original managed settings. The Mac app offers **Settings → Uninstall StandMixer**. Later user edits are preserved. Remove the plugin separately in the host's plugin manager; saved presets, recovery data, source, and the optional app remain.

The installer prints the full Terminal command path without changing your shell's PATH. The launcher accepts `status`, `fast`, `optimized`, `high`, and `uninstall`; mutations preview first and require `--yes`.

## Local data

Data remains in `~/Library/Application Support/AgentMix` for compatibility with existing installations. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are respected. StandMixer changes only managed instructions, worker definitions, control skills, and explicitly pinned model fields. It preserves unrelated settings and refuses redirected or conflicting files.

Discovery is bounded to known tool locations and native project metadata. Worker recipes preserve existing permissions: workspace writes for authorized implementation, read-only for review. StandMixer does not weaken global sandbox settings or Gatekeeper.

## Development

The [website](website/index.html), screenshots, and [link-preview artwork](website/artwork/social-preview.html) are included in `website/`.

```sh
./dev/test.sh
node --test Plugins/codex-agentmix/tests/ui.test.cjs
claude plugin test Plugins/claude-agentmix
python3 dev/test-installers.py
python3 dev/test-codex-native.py
./dev/build-codex-plugin.sh
./dev/build.sh
```

Tests use isolated fixtures and fake worker CLIs. The native Codex loader check uses an installed Codex CLI against a temporary home, without authentication, chats, inference, or real settings changes. Release builds remove private compiler paths and local symbols, preserve runtime metadata, and verify signatures. Both plugins include the [MIT license](LICENSE). Other operating systems are not yet supported.
