# Roadmap

## 0.1

- One-command setup, native Claude pane, embedded Codex web UI.
- Fast, Optimized, and High presets; Auto controller; inline Edit controls.
- Saved presets, exact file review, backups, restore, and safe settings removal.
- Explicit CLI-account checks and optional preference inspection.
- Optional locally built Mac app through `install-mac`.

## 0.1.5
status: included in 0.1.7; verified locally · started: 2026-11-05 · revision: local-015-1 · took: ~25m

- [x] Use StandMixer names and paths throughout the active installation (~15m). · took: ~4m
- [x] Retire verified old installations with bounded cleanup and recovery copies; keep saved preferences without runtime compatibility aliases (~20m). · took: ~9m
- [x] Show version and last-check information in Sources/Connections (~10m). · took: ~3m
- [x] Add an explicit Check now control while keeping automatic checks throttled (~15m). · took: ~2m
- [x] Preserve the previous restore point for an unchanged update (~10m). · took: ~2m
- [x] Build and verify locally; keep GitHub and both installed baselines unchanged until publication is approved (~10m). · took: ~5m


## 0.1.6
status: included in 0.1.7; cross-device upgrade checks pending · started: 2026-11-08 · revision: local-016-3 · Mac build: 9 · took: ~25m

- [x] Replace linked-worktree permission troubleshooting with a short controller handoff instruction (~3m). · took: ~1m
- [x] Document the other-Mac upgrade test from public 0.1.4, keeping publication separate (~5m). · took: ~2m
- [x] Build and verify the packaged recipes locally without installing or publishing (~7m). · took: ~5m

- [x] Test Codex sandbox commit/merge from both linked-worktree and main-checkout working directories; update the shared recipe from observed results (~15m). · took: ~12m

- [x] Narrow routing to model/effort preferences and explicit team settings; install locally in Codex and Claude while preserving current choices (~20m). · took: ~25m

### This Mac

- [ ] Confirm the refreshed local panels show the preserved setup (~2m). · human: check
  Group: Local install
  Why: The files and plugin registrations are verified; an already-open host may still hold its earlier panel or instructions.
  Do: Reload Claude plugins and open /standmixer, then open StandMixer in a new Codex chat.
  Expect: Version 0.1.7 appears in Connections or Sources, with the existing custom assignments. Claude Review remains native Opus 5.5.
  Valid-for: local-016-3

### Other Mac checks

- [ ] Keep an installed 0.1.4 baseline with a saved preset (~3m). · human: check
  Group: Other Mac upgrade
  Why: Version 0.1.0 predates the updater; uninstalling would lose the baseline we need to test.
  Do: Follow step 1 in docs/upgrade-test.md on the other Mac, then save the current setup as Upgrade test.
  Expect: StandMixer opens and the saved preset retains the current assignments.
  Valid-for: local-016-3
- [ ] Upgrade the other Mac and verify both panels (~3m). · human: check
  Group: Other Mac upgrade
  When: later, after 0.1.7 publication
  Why: Fixture checks cannot establish the other Mac's native plugin reload behavior.
  Do: Follow step 2 in docs/upgrade-test.md, then review and Apply the saved setup once.
  Expect: Sources or Connections shows 0.1.7; Check now updates its timestamp; saved assignments are retained.
  Valid-for: local-016-3
- [ ] Verify a repeated update preserves recovery (~2m). · human: check
  Group: Other Mac upgrade
  When: later, after the first upgrade and Apply succeed
  Why: An unchanged update must preserve the last real restore point.
  Do: Run the three commands in step 3 of docs/upgrade-test.md.
  Expect: Both backup hashes match; the updater says current; both panels still open.
  Valid-for: local-016-3

### Found while working

- [x] During a path-changing reinstall, preserve native model defaults by retiring historical ownership records before removing the old integration (~5m). · took: ~5m

- [ ] The pre-0.1.5 updater's --mac step still points to the former source location after cleanup; verify this release boundary on a real Mac, using plain update then install-mac (~3m).

## 0.1.7
status: released 0.1.7 on 2026-11-10; local verification complete · started: 2026-11-10 · revision: local-017-1 · Mac build: 10 · took: ~10m

- [x] Add Fable 5.2 to the catalog and all model pickers with its supported efforts and four-bar identity (~5m). · took: ~4m
- [x] Verify selection and generated worker recipes; install locally without changing existing assignments (~7m). · took: ~6m

## 0.1.8
status: released 0.1.8 on 2026-11-10 · started: 2026-11-10 · revision: local-018-1 · Mac build: 11 · took: ~8m

- [x] Show manually selected effort and ranges in the main settings view; keep Auto quiet (~5m). · took: ~3m
- [x] Verify and install the display update locally without modifying any assignments (~7m). · took: ~5m

## 0.2

- **Automatic model tracking and upgrades:** discover new releases from authoritative provider metadata and exposed harness catalogs, with cached checks rather than per-task model calls. Offer opt-in successor tracking alongside exact-version pins. Prefer compatible successors within the selected provider/family; consider account access, effort/capability changes, and subscription/cost limits. Preview changes, preserve custom assignments and team structure, never silently cross providers or increase cost tiers, and support rollback. Do not change an in-progress job's model.

- **Activity:** revisit a simple view of model usage by project once the preset workflow is settled. Keep collection optional, estimates clearly labeled, and ordinary settings use free of background model calls.

- **Per-project presets:** inherit global settings or override a preset and individual assignments. Separate previews and backups keep one project's changes from affecting another.
- **Plan-aware routing:** combine exposed subscription/entitlement metadata with user-confirmed budgets. Preserve explicit pins, unknown quotas, and paid-overage decisions. Monthly prices alone do not establish cross-provider capacity.
- **Account profiles:** consider selecting independently configured CLI profiles where reliable public interfaces exist. Executable versions are not separate accounts; do not copy credentials between apps.
  Keep selection sticky. Quota checks must use cached, directly exposed metadata, never inference or per-turn polling. Recheck on explicit refresh or a confirmed account limit; unknown is not zero. Any future failover is opt-in and bounded, with no automatic retry after work or tool side effects have begun and no paid-API fallback.
- **Host coverage:** verify native MCP entrypoints across Codex releases and expand platforms after the helper is portable.
- **Routing lab:** compare one strong agent, lead plus focused review, independent teams, and design-winner follow-ups on the same held-out coding/design tasks. Pin model versions and effort, repeat runs, and measure verified correctness, blind design preference, tokens, latency, and retries under fixed budgets. Use results to tune presets; do not treat votes or more agents as proof of higher quality. Benchmark execution is separate from ordinary settings use.

Keep the main workflow focused on presets.
