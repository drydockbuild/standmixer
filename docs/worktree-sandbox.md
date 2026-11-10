# Linked-worktree Git permissions

Verified with Codex CLI `0.167.0-alpha.3.2` on macOS using `codex sandbox`, real Git, and disposable repositories. No model calls or network were used.

| Job working directory | Extra writable roots | Stage, commit, merge |
| --- | --- | --- |
| Linked worktree | None | Blocked at `index.lock` |
| Linked worktree | Common Git directory only | Blocked at `index.lock` |
| Linked worktree | Per-worktree Git directory only | Blocked writing Git objects |
| Linked worktree | **Both Git directories, explicitly** | **Passed** |
| Main checkout, with worktree beneath it | Common Git directory | Passed |
| Main checkout, with worktree beneath it | None | Blocked at `index.lock` |
| Either working directory, read-only | None | File edits and Git writes blocked |

Both explicit root-argument orders passed. The both-roots configuration also passed with a sibling linked worktree outside the main checkout. Unrelated writes stayed blocked, the main checkout's files and HEAD were unchanged, and a non-Git workspace could edit normally without extra roots.

## Recipe

Keep the job's working directory in its linked worktree. Resolve both paths there:

```sh
git -C /approved/worktree rev-parse --path-format=absolute --git-dir --git-common-dir
```

For an authorized Git-writing Codex job, pass each result as its own `--add-dir` argument. Do not remove the per-worktree entry just because it lies beneath the common directory: its separate protected-path rule needs the explicit grant. This preserves the worktree's instruction context without granting the main checkout as a workspace.

Read-only jobs get no extra write roots. CLI arguments cannot override a parent app or managed policy. When those paths are not authorized, use the existing controller's normal approval flow for the Git operation instead of launching another agent or changing global permissions.

## Reproduce

```sh
python3 dev/test-worktree-sandbox.py
```

Run from a host allowed to invoke macOS Seatbelt. The test uses Codex's `sandbox_workspace_write.writable_roots` configuration to exercise its filesystem policy directly, without an inference turn. It disables implicit temporary-directory write grants so they cannot hide missing permissions. This is a sandbox integration test, not a claim that an LLM worker was launched.
