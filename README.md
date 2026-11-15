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

**Fast** keeps strong models at lower effort for ordinary work, **Optimized** matches models and effort to each kind of work, and **High-quality** uses more Fable and two-model teams for substantive work. Presets select workers for warranted tasks without adding mandatory workflow stages.

Six main groups cover Planning & algorithms, Design & UI, General coding, Code review, Research & writing, and Routine tasks. Optional subcategories inherit model, effort, and team settings independently. A fixed child setting stays fixed when its parent changes; **Use parent** restores inheritance. Older saved configurations retain their assignments, including a separate Algorithms override where needed.

Claude Code and Codex stay visible together. Effort bars distinguish fixed levels, ranges, and caller-following settings; their accessible labels and help show the exact policy. Cross-provider assignments say **via Codex** or **via Claude Code**. Model tiers use bottom-up dots and matching name colors. Fully inherited child summaries stay quiet; visible exceptions show complete assignments and aligned team members.

Routing follows the substance of a task. Serious algorithm or invention work remains on the reasoning route even when described as brainstorming or implementation. Quick ideas are bounded nontechnical suggestions. Drafting and editing at lower effort transforms settled content; difficult new conclusions use Deep analysis. Running a known test command is routine, while investigating an unexplained failure uses Debugging / root cause. Reviewing a UI, an algorithm, and code correctness follows the corresponding subject route.

Code review covers ordinary development and pre-release checks. **Release security** selects the fuller cross-provider review when a release or change warrants an exposure assessment. The agent considers actual exposure, including internet-facing staging or test services, rather than relying on a production/staging label. A local edit does not automatically require a full security audit.

Debugging can have an ordered **When stuck** list, separate from its normal team. The controller uses it only after genuine lack of progress, carrying the current changes, failed hypotheses, and test evidence forward. It skips already-exhausted models and uses each remaining target once. This is model-selection guidance, not a retry engine or quota/availability fallback.

**Controller: Auto** keeps your current chat model. Worker effort Auto follows the caller at a supported level. Explicit controller pins change defaults for future sessions. Presets guide useful delegation; they do not add mandatory planning, security reviews, or extra agents to ordinary chat.

StandMixer selects models, effort, and explicitly configured teams. The host and project own permissions. Quota monitoring, automatic fallback, model-specific access restrictions, and project-specific mandatory reviews belong outside this tool.

In the Codex/web panel, click a model name or effort bar to change it directly. The draft updates immediately and saves automatically; Undo and Redo remain available, and a failed save keeps the local changes with a retry action. The row's more-settings control holds team and escalation options. Claude's native pane and the Mac app use **Edit → Save** for draft changes. **Review & apply** remains separate in every interface and shows the actual file changes before applying them. StandMixer checks for intervening edits and keeps recovery data. Start new sessions to load changed routing instructions. Model entries and routing instructions do not prove account access or actual execution.

## Accounts and preferences

**Sources** shows saved local defaults and installed CLI versions. The native Codex panel and Mac app automatically run Claude Code’s public `auth status --json` check when you open settings with Codex-to-Claude routes configured, choose Claude for Codex, or re-enable a provider those routes need. A working connection stays quiet. If the check needs attention, StandMixer opens the connection dialog. **Not now** lets you continue configuring routes. **Connect Claude for Codex** also checks the current status. Choose **Continue with Claude** to start the official `auth login` browser flow. Claude Code owns credentials. StandMixer keeps only the checked executable and profile metadata.

Codex workers resolve their CLI with `standmixer resolve-cli codex`. Claude workers use `standmixer run-claude -- -p …`, which checks the linked native connection in the worker’s directory and replaces itself with the selected CLI. The same profile is used for checking, sign-in, and execution; versioned executables can be rediscovered without switching profiles. No browser login or model retry starts automatically from a worker launch. A signed-in Desktop session alone does not establish independent CLI authentication.

All settings comparisons use deterministic reads of saved global defaults and verified StandMixer installation records. Unknown settings stay unknown. You can open, edit, preview, and apply settings without a successful login, model calls, or conversation-history inspection.

## Optional Mac app

Choose **Install Mac app** in Interface, or run `/standmixer install-mac` in Claude Code or `$standmixer install-mac` in Codex.

The app builds locally, is ad-hoc signed, and installs in `~/Applications/StandMixer.app`. It follows system appearance. Apple Command Line Tools with Swift 6 and a compatible macOS SDK are required; full Xcode and paid signing are not. If tools are missing, run `xcode-select --install` and complete Apple's installation. No DMG is needed.

## Update and remove

Run `/standmixer update` in Claude Code or `$standmixer update` in Codex. On the current data layout, add `--mac` to also rebuild the optional Mac app. In Terminal:

```sh
"$HOME/Library/Application Support/StandMixer/bin/standmixer" update
```

Opening a Claude/Codex panel checks GitHub for a newer version at most once per day, using a shared local cache. Checks use no models or credentials, send no settings or project data, and stay quiet offline. Installing updates remains explicit; there is no background polling. **Sources** (Codex/web) or **Connections** (Claude) shows the installed version, last check, and **Check now** to bypass the daily cache.

Existing installations with an update command can use it. Older installations without it (including 0.1.0) need an installer refresh:

```sh
standmixer_update="$(mktemp -d)" && git clone --depth 1 https://github.com/drydockbuild/standmixer.git "$standmixer_update/standmixer" && /bin/sh "$standmixer_update/standmixer/install.sh"
```

The installer retires a verified installation using the old data layout into a private recovery folder and retains saved presets and drafts. It removes the old integration using its recorded baseline, then installs under the new StandMixer paths. Reload plugins and review and apply your preset once. If you used the optional Mac app, rebuild it with `install-mac`. Modified or unrecognized files are preserved; conflicts stop cleanup.

Native model defaults stay unchanged when the old integration is retired. Its original ownership records remain in the recovery copy.

Subsequent updates preserve presets, drafts, backups, and modified or unowned files. New code does not automatically apply a different routing preset.

`/standmixer uninstall` or **Sources → Remove StandMixer settings** previews restoration of the original managed settings. The Mac app offers **Settings → Uninstall StandMixer**. Later user edits are preserved. Remove the plugin separately in the host's plugin manager; saved presets, recovery data, source, and the optional app remain.

The [0.2.6 upgrade test plan](docs/upgrade-test.md) covers migration from 0.1.4, a standard update from 0.1.8 or an earlier 0.2.x release, and checking that a repeated update preserves the restore point.

The installer prints the full Terminal command path without changing your shell's PATH. The launcher also accepts `status`, `fast`, `optimized`, `high`, and `uninstall`; routing changes preview first and require `--yes`.

## Local data

Data is stored in `~/Library/Application Support/StandMixer`. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are respected. StandMixer changes only managed instructions, worker definitions, control skills, and explicitly pinned model fields. It preserves unrelated settings and refuses redirected or conflicting files.

Discovery is bounded to known tool locations and native project metadata. Worker recipes preserve existing permissions: workspace writes for authorized implementation, read-only for review. StandMixer does not weaken global sandbox settings or Gatekeeper.

## Development

The [website](website/index.html), screenshots, and [link-preview artwork](website/artwork/social-preview.html) are included in `website/`.

The [worktree sandbox check](docs/worktree-sandbox.md) exercises real Git operations under Codex permissions without model calls.

```sh
./dev/test.sh
node --test Plugins/codex-standmixer/tests/ui.test.cjs
claude plugin test Plugins/claude-standmixer
python3 dev/test-installers.py
python3 dev/test-codex-native.py
./dev/build-codex-plugin.sh
./dev/build.sh
```

Tests use isolated fixtures and fake worker CLIs. The native Codex loader check uses an installed Codex CLI against a temporary home, without authentication, chats, inference, or real settings changes. Release builds remove private compiler paths and local symbols, preserve runtime metadata, and verify signatures. Both plugins include the [MIT license](LICENSE). Other operating systems are not yet supported.
