# Development guidance

- Keep the product a compact preset settings utility. Detailed overrides belong inline in Edit; diagnostics belong in Sources.
- Automated tests use isolated fixtures and fake worker CLIs. Native host-loading checks use temporary homes without authentication or chats. Never spend inference quota or mutate real harness settings in tests. Live checks must name the actual model and need an explicit task reason.
- Preserve Auto controller semantics, native-only explicit controller pins, caller-effort translation, provider labels, and approved preset regression fixtures.
- Preserve exact reviewed previews, first-install baselines, later user edits, and safe restore/uninstall. Do not broaden permissions to make tests pass.
- Discovery stays bounded. Never search personal folders or read raw credentials.
- Release source and binaries must exclude private paths, prompts, logs, and authentication material. Check the release snapshot before publishing.
- Preserve published Git history. Add normal commits; do not recut or force-reset public `main`.
- Bump runtime release versions consistently so update notices can detect new releases.
- Per-project and plan-aware routing stay in [ROADMAP.md](ROADMAP.md) unless explicitly requested.
