# Roadmap

## 0.1

- One-command setup, native Claude pane, embedded Codex web UI.
- Fast, Optimized, and High presets; Auto controller; inline Edit controls.
- Saved presets, exact file review, backups, restore, and safe settings removal.
- Explicit CLI-account checks and optional preference inspection.
- Optional locally built Mac app through `install-mac`.

## 0.1.5
status: verified locally; unpublished · started: 2026-11-05 · branch: v0.1.5 · revision: local-015-1 · took: ~25m

- [x] Use StandMixer names and paths throughout the active installation (~15m). · took: ~4m
- [x] Retire verified old installations with bounded cleanup and recovery copies; keep saved preferences without runtime compatibility aliases (~20m). · took: ~9m
- [x] Show version and last-check information in Sources/Connections (~10m). · took: ~3m
- [x] Add an explicit Check now control while keeping automatic checks throttled (~15m). · took: ~2m
- [x] Preserve the previous restore point for an unchanged update (~10m). · took: ~2m
- [x] Build and verify locally; keep GitHub and both installed baselines unchanged until publication is approved (~10m). · took: ~5m


## 0.1.6
status: installed locally in Codex and Claude; unpublished; other-Mac checks pending · started: 2026-11-08 · branch: v0.1.6 · revision: local-016-3 · Mac build: 9 · took: ~25m

- [x] Replace linked-worktree permission troubleshooting with a short controller handoff instruction (~3m). · took: ~1m
- [x] Document the other-Mac upgrade test from public 0.1.4, keeping publication separate (~5m). · took: ~2m
- [x] Build and verify the packaged recipes locally without installing or publishing (~7m). · took: ~5m

- [x] Test Codex sandbox commit/merge from both linked-worktree and main-checkout working directories; update the shared recipe from observed results (~15m). · took: ~12m

- [x] Narrow routing to model/effort preferences and explicit team settings; install locally in Codex and Claude while preserving current choices (~20m). · took: ~25m

### This Mac

- [ ] Confirm the refreshed local panels show the preserved setup (~2m).
  Group: Local install
  Why: The files and plugin registrations are verified; an already-open host may still hold its earlier panel or instructions.
  Do: Reload Claude plugins and open /standmixer, then open StandMixer in a new Codex chat.
  Expect: Version 0.1.6 appears in Connections or Sources, with the existing custom assignments. Claude Review remains native Opus 5.5.
  Valid-for: local-016-3

### Other Mac checks

- [ ] Keep an installed 0.1.4 baseline with a saved preset (~3m).
  Group: Other Mac upgrade
  Why: Version 0.1.0 predates the updater; uninstalling would lose the baseline we need to test.
  Do: Follow step 1 in docs/upgrade-test.md on the other Mac, then save the current setup as Upgrade test.
  Expect: StandMixer opens and the saved preset retains the current assignments.
  Valid-for: local-016-3
- [ ] Upgrade the other Mac and verify both panels (~3m).
  Group: Other Mac upgrade
  When: later, after 0.1.6 publication is approved and completed
  Why: Fixture checks cannot establish the other Mac's native plugin reload behavior.
  Do: Follow step 2 in docs/upgrade-test.md, then review and Apply the saved setup once.
  Expect: Sources or Connections shows 0.1.6; Check now updates its timestamp; saved assignments are retained.
  Valid-for: local-016-3
- [ ] Verify a repeated update preserves recovery (~2m).
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
status: published 0.1.7 on 2026-11-10 (0062400); cross-device upgrade checks pending · started: 2026-11-10 · branch: v0.1.7 · revision: local-017-1 · Mac build: 10 · took: ~10m

- [x] Add Fable 5.2 to the catalog and all model pickers with its supported efforts and four-bar identity (~5m). · took: ~4m
- [x] Verify selection and generated worker recipes; install locally without changing existing assignments (~7m). · took: ~6m

## 0.1.8
status: published 0.1.8 on 2026-11-10 (33b5e67) · started: 2026-11-10 · branch: v0.1.8 · revision: local-018-1 · Mac build: 11 · took: ~8m

- [x] Show manually selected effort and ranges in the main settings view; keep Auto quiet (~5m). · took: ~3m
- [x] Verify and install the display update locally without modifying any assignments (~7m). · took: ~5m

## 0.2
status: 0.2.8 published and installed; website and 6.2 previews deployed and verified · started: 2026-11-17 · branch: website/0.2.8-refresh · revision: website-028-1 · Mac build: 22 · took: ~8m

- [x] Add six routing groups, independently inherited overrides, and migration that preserves existing assignments (~25m, Sol 6.1). · took: ~25m
- [x] Add the agreed Optimized defaults and deliberate Fast and High-quality presets (~10m, Sol 6.1). · took: ~20m
- [x] Separate normal review from release/exposure security and add bounded debugging escalation choices (~10m, Sol 6.1 + Astra 6). · took: ~15m
- [x] Keep Claude and Codex together in compact settings, with effort bars, crossover labels, and one inline editor (~25m, Astra 6). · took: ~40m
- [x] Verify migration, routing, presets, and all three interfaces; review the implementation (~15m). · took: ~20m
- [x] Build and install 0.2.0 locally in both hosts and the Mac app without GitHub publication (~10m). · took: ~10m

This batch selects models, effort, and explicit teams. Permissions remain with the host and project. Quota monitoring, automatic fallback, model-specific permission bans, and project-specific mandatory review rules are outside StandMixer's scope. The previously recorded ideas below are not part of this local build.

### Now

- [ ] Check the installed logout confirmation (~1m).
  Group: Claude account control
  Why: The Mac was locked during the final visual check; automated logout and cancellation tests passed.
  Do: Reopen StandMixer or open it in a fresh Codex chat, then choose Sources, Connect Claude for Codex, Log out…, and Cancel.
  Expect: Version 0.2.7 is shown, the confirmation explains the shared CLI profile, and Cancel keeps the connection unchanged.
  Valid-for: local-027-1

- [ ] Load the updated settings panel (~1m).
  Group: Local 0.2.6 check
  Why: Already-open Codex connections can keep serving the older panel after installation.
  Do: Open a new Codex chat and open StandMixer there.
  Expect: v0.2.6 is visible under StandMixer. With Codex-to-Claude routes enabled, a signed-out or failed Claude connection opens its dialog automatically; a working connection stays quiet.
  Valid-for: local-026-1

- [ ] Try direct editing in the updated Codex panel (~1m).
  Group: Local 0.2 check
  Why: A panel already open during installation may still show the previous interface.
  Do: Open StandMixer in a fresh Codex chat, click a model name or effort bar, choose a value, and try Undo.
  Expect: The field updates immediately, the draft saves automatically, and Undo restores it. Active routing changes only after Review & apply.
  Valid-for: local-020-2

- [x] Confirm the corrected Codex panel after loading the cache patch (~1m). · took: ~1m
  Group: Local 0.2.1 check
  Why: Codex was still running 0.2.0 helpers after the patch was installed; the new panel has a different content-addressed resource ID.
  Do: Restart Codex, reopen StandMixer, and click a model name or effort bar.
  Expect: Sources reports 0.2.1, the old global Edit button is absent, and the clicked field opens its selector directly.
  Valid-for: local-021-1

### Found while working

- [x] Update the live website version, settings screenshot, and share preview for 0.2.8 and the 6.2 models (~8m, Astra 6.2). · started: 2026-11-17 · branch: website/0.2.8-refresh · took: ~8m
  Published source 5ee6b8d and switched the static release atomically. Verified the v0.2.8 release link, current UI screenshot, Sol/Astra 6.2 share card, 1200×630 image size, desktop/mobile layout, image loading, social metadata, and exact live HTML/image bytes. Browser cache was cleared by a normal reload during final verification; the previous static release is retained for rollback. No application settings changed.

- [x] Publish 0.2.8 source, tag, and plugin packages after final release checks (~12m, Astra 6.2 + Fable 5.2). · started: 2026-11-17 · branch: publish/0.2.8 · took: ~12m
  Published release commit 3495c54 and v0.2.8 with both plugin ZIPs and SHA256SUMS. Independent native and Fable 5.2 reviews found no blockers. Final Swift suite passed 392 tests with one expected skip. Installer fixtures passed 44 on the first run; the remaining fixture hit its 30-second subprocess deadline and passed unchanged in an isolated rerun. Downloaded release assets match their original checksums, plugin versions, and strict code signatures; GitHub marks v0.2.8 latest. Existing local build 22 and the applied 6.2 routing remain current. No live website deployment was part of this publication batch.

- [x] Replace prior Sol/Astra assignments with Sol 6.2 and Astra 6.2, preserve other routing choices, and install/apply the local update (~20m, Sol 6.2 + Astra 6.2). · started: 2026-11-17 · branch: v0.2.8-models-6.2 · took: ~20m
  Updated catalog, factory presets, model pickers, labels, generated selectors, and editable saved choices. Exact reviewed previews and applied/restore records keep historical IDs. Verified 118 Codex UI tests, 61 Claude panel tests, 61 native App/Helper tests, Core migration/category/preset coverage (one stale fixture corrected and rerun), packaged-helper safeguards, native Codex loading, universal helper build, and installed Mac signature. Applied the reviewed 11-file update; all 20 Sol/Astra references changed exactly as requested, with no other configuration differences. Native controller defaults and Claude connection metadata were preserved. No inference smoke, GitHub publication, or website deployment was part of this batch.

- [x] Add explicit Claude CLI logout in Codex and Mac connection controls, verify profile/cancellation behavior, and install locally (~40m, Sol 6.1 + Astra 6). · started: 2026-11-16 · branch: v0.2.7-claude-logout · took: ~40m
  Passed 386 Swift tests (one expected platform skip), 117 Codex UI tests, 61 Claude panel tests, native Codex loading, packaged-helper protections, and MCP/HTTP boundary checks. Logout tests use isolated fake CLIs; no real logout or login ran. Review fixed false logout confirmation for expired sessions, rejected redirected saved executables, and resolved a reproduced first-publication race by staging complete connection records before rename. The strict concurrent-link check passed 10 repeated runs and independent staged-write stress passed 5,000 cycles. Installed both plugins/helper and Mac build 21; signatures and installed helper hashes verified. Routing/native settings and connection metadata stayed unchanged; only normal installation/recovery receipts changed. Live visual verification was blocked by the locked Mac.

- [x] Refresh the live website for 0.2.6 with the current interface capture and link-preview artwork (~15m, Astra 6). · started: 2026-11-14 · branch: website/0.2.6-refresh · took: ~15m
  Published the current-version link, released Codex UI capture using isolated factory data, and 1200×630 share-preview artwork with new asset URLs. Verified desktop/mobile layout, loaded images, release link, social metadata, and exact live HTML/image bytes at https://standmixer.dev/. The static release was switched atomically with its prior release retained; runtime settings and release artifacts were unchanged.

- [x] Prepare 0.2.6 release documentation, verify packages, and complete independent release review (~40m, Astra 6 + Fable 5.2 + Sol 6.1). · started: 2026-11-14 · branch: v0.2 · took: ~40m
  Completed independent native and Fable 5.2 reviews. Fixed bounded pipe draining, late sheet callbacks, redundant connection writes under contention, worker locale changes, misleading probe errors, and unnecessary account fields. Retained owned-process cleanup rather than abandoning an unreaped group for a hypothetical kernel stall. Final checks passed: 360 Swift tests (one platform skip), 112 Codex UI tests, 61 Claude panel tests, 45 installer/package tests, packaged-helper lifecycle, native Codex loader, MCP/HTTP boundaries, universal helper signatures, and local Mac build 20. A one-turn Haiku 5.5 request through the final helper returned the expected smoke-test response. The public snapshot is based on the existing public main history and excludes private reply routes. Fresh public-clone/update and deployed-site checks require publication; the other-Mac upgrade remains pending. No push, tag publication, GitHub Release, or website deployment occurred.
- [x] Scope Claude sheet dismissal to its own presentation so late callbacks cannot cancel newer checks (~8m, Astra 6). · started: 2026-11-14 · branch: v0.2 · took: ~8m
  The original late-dismissal regressions failed before the fix; all 22 Mac tests passed afterward, including normal Escape, preview continuation, and quit cleanup.
- [x] Avoid redundant connection metadata writes, retain worker locales, distinguish project probe timeouts, and omit unused account details from reports (~8m, Sol 6.1). · started: 2026-11-14 · branch: v0.2 · took: ~9m
  All 36 focused core/protocol tests passed, including lock contention, changed-profile rejection, cancellation, locale preservation, status redaction, project timeout, and detached-pipe cleanup. Security-related environment filtering remains in place.
- [x] Bound connection output draining when a detached child retains a pipe, preserving cancellation and shutdown completion (~5m, Sol 6.1). · started: 2026-11-14 · branch: v0.2 · took: ~6m
  The two escaped-child cancellation/timeout regressions passed with all 23 connection tests. Native review confirmed bounded reader completion and descriptor ownership. Two unrelated fixture failures during concurrent release builds passed unchanged with builds idle; the positive connection fixture now uses the production probe allowance and the Mac fixture reports its discovery prerequisite directly.

- [x] Check required Claude connections on settings open and provider re-enable, discard stale results after disable, and surface failed checks without claiming sign-out (~25m, Astra 6). · started: 2026-11-14 · branch: v0.2 · took: ~25m
  Passed 112 Codex UI tests, 61 Claude panel tests, 19 Mac lifecycle/trigger tests, universal helper builds, isolated native Codex loading, and Mac release build/signatures. Review found and fixed superseded-check and UI-only-generation races. Installed 0.2.6 in both plugins and Mac build 19. Verified the running Mac version and its automatic Sign in with Claude dialog on startup while the public CLI status was signInRequired; no browser login or inference was initiated. Six configuration/state files remained byte-for-byte unchanged. Existing Codex panels in this chat retained older loaded UI; the fresh-chat check above remains pending. User subsequently confirmed the reconnect flow worked and completed Claude sign-in. The requested single tool-free smoke request through the installed run-claude launcher succeeded with the expected smoke-test response; runtime metadata reported claude-haiku-5-5, firstParty, one turn, 1561 ms. The local connection batch is complete.
- [x] Add minimal optional Connect Claude for Codex using official auth login, consistent worker profile binding, and configuration-triggered prompts; test and install locally (~30m, Astra 6 + Sol 6.1). · started: 2026-11-14 · branch: v0.2 · took: ~40m
  Verified 340 Swift tests (one platform skip), final 9 Mac lifecycle/trigger checks, 103 Codex UI tests, 61 Claude panel tests, helper/installer/HTTP/MCP smoke tests, native Codex loading, and Mac build/signatures. Actual Mac dialog found an existing CLI login and showed connected. One tool-free worker through run-claude returned the expected nonce with runtime metadata identifying claude-opus-5-5. No fresh browser login was needed or forced. Applied only two reviewed worker-guide changes; all model/effort values and saved presets/history were preserved.
- [x] Show the loaded version persistently, make Expand available only where it can expand, and distinguish read-only global defaults from collapsed CLI diagnostics (~15m, Astra 6). · started: 2026-11-14 · branch: v0.2 · took: ~20m
  Verified 86 Codex UI tests, 61 Claude panel tests, release helper builds, native Codex loader, and Mac build/signatures. Saved configuration and presets remained byte-for-byte unchanged. This chat retained the older MCP connection during verification; a fresh chat must load the new package.
- [x] Make manual collapse hide all child rows without changing route settings (~4m, Astra 6). · took: ~4m
- [x] Resolve current healthy provider CLIs at launch, align account checks, and recognize Ultra metadata (~6m, Astra 6). · took: ~12m

- [ ] Add discovery-first Claude authentication in the Mac app, a centered official sign-in flow, and graceful disconnect recovery with shared checked/login/worker connection selection (~40m, Astra 6). · stopped: 2026-11-14; removed from StandMixer scope at user request; implementation handoff belongs to a separate application.
- [x] Return all StandMixer settings interfaces to deterministic configuration-only behavior, remove account/observer controls, verify and install locally, and hand off authentication design for separate application use (~30m, Astra 6). · started: 2026-11-14 · branch: v0.2 · took: ~25m
- [x] Broaden Routine coding to bounded specified implementation and direct settled work to that route in both hosts, preserving every model and effort assignment (~5m). · started: 2026-11-14 · branch: v0.2 · took: ~5m
  Verified 299 Swift tests (one platform-alias skip), 83 Codex UI tests, 61 Claude panel tests, native Codex loader, packaged helper/MCP/HTTP smoke tests, and the installed Mac app Sources UI. Applied only the two reviewed routing instruction files; all model/effort values and saved presets/draft history were preserved.

- [x] Fix persistent Codex panel caching with content-addressed resource IDs and verify the actual native panel after local installation (~8m). · started: 2026-11-14 · branch: v0.2 · revision: local-021-1 · Mac build: 14 · took: ~10m

- [x] Keep legacy applied snapshots distinct from migrated editable drafts so new routes are not reported as already active (~5m). · took: ~5m
- [x] Compare inheritance and ordered escalation policy when matching presets, including equal effective values (~5m). · took: ~5m
- [x] Record the external Opus review rejection and complete the subsequently configured native Astra review (~5m). · took: ~8m
  Automatic approval review blocked source export to Claude. No external Opus review ran. Native review found two draft-autosave issues; both were fixed and verified.
- [x] Fix grouped dividers, child indentation, reload and legend graphics, full team alignment, and visible Computer use effort (~5m). · took: ~8m
- [x] Replace Codex's ordinary Edit flow with direct model/effort controls and serialized draft autosave, preserving explicit reviewed Apply (~8m). · took: ~12m

- **Activity:** revisit a simple view of model usage by project once the preset workflow is settled. Keep collection optional, estimates clearly labeled, and ordinary settings use free of background model calls.

- **Per-project presets:** inherit global settings or override a preset and individual assignments. Separate previews and backups keep one project's changes from affecting another.
- **Plan-aware routing:** combine exposed subscription/entitlement metadata with user-confirmed budgets. Preserve explicit pins, unknown quotas, and paid-overage decisions. Monthly prices alone do not establish cross-provider capacity.
- **Account profiles:** consider selecting independently configured CLI profiles where reliable public interfaces exist. Executable versions are not separate accounts; do not copy credentials between apps.
  Keep selection sticky. Quota checks must use cached, directly exposed metadata, never inference or per-turn polling. Recheck on explicit refresh or a confirmed account limit; unknown is not zero. Any future failover is opt-in and bounded, with no automatic retry after work or tool side effects have begun and no paid-API fallback.
- **Host coverage:** verify native MCP entrypoints across Codex releases and expand platforms after the helper is portable.
- **Routing lab:** compare one strong agent, lead plus focused review, independent teams, and design-winner follow-ups on the same held-out coding/design tasks. Pin model versions and effort, repeat runs, and measure verified correctness, blind design preference, tokens, latency, and retries under fixed budgets. Use results to tune presets; do not treat votes or more agents as proof of higher quality. Benchmark execution is separate from ordinary settings use.

## 0.3
status: planned; not started

- [ ] Add online model discovery and an opt-in **Auto-select new models** setting (~2h). Use authoritative provider release information and exposed harness catalogs, with cached checks. Identify compatible successors and appropriate task defaults; update only auto-managed choices. Preserve exact-version pins, custom overrides, team structure, and in-progress jobs. Show what changed and retain rollback. Unknown model-family progressions should become suggestions rather than guessed replacements. Keep quota monitoring and fallback policy outside this feature.

Keep the main workflow focused on presets.
