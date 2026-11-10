#!/usr/bin/env python3
"""Real Codex/Seatbelt Git fixtures; no model calls, network, or real settings.

Run on macOS from a host allowed to invoke sandbox-exec. Tests configure only
throwaway repositories. Temp-directory write allowances are disabled so they
cannot accidentally make an outside Git directory writable.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    codex = shutil.which('codex')
    if not codex:
        raise SystemExit('Install Codex CLI before running this sandbox integration check.')
    git = subprocess.check_output(['/usr/bin/xcrun', '--find', 'git'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='standmixer-git-sandbox-', dir='/private/tmp') as temporary:
        root = Path(temporary)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'CODEX_', 'CLAUDE_', 'OPENAI_'))}
        env.update(HOME=str(root/'home'), CODEX_HOME=str(root/'codex'), TMPDIR=str(root/'tmp'),
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', PATH=str(Path(git).parent)+':/usr/bin:/bin')
        for key in ['HOME', 'CODEX_HOME', 'TMPDIR']:
            Path(env[key]).mkdir()

        def run(command, cwd):
            return subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True, timeout=30)

        def g(cwd, *args):
            result = run([git, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                          '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', *args], cwd)
            assert result.returncode == 0, result.stderr
            return result.stdout.strip()

        def sandbox(cwd, policy, roots, command):
            args = [codex, 'sandbox', '-c', f'sandbox_mode="{policy}"',
                    '-c', 'sandbox_workspace_write.exclude_tmpdir_env_var=true',
                    '-c', 'sandbox_workspace_write.exclude_slash_tmp=true',
                    '-c', 'sandbox_workspace_write.network_access=false']
            if roots:
                args += ['-c', 'sandbox_workspace_write.writable_roots='+json.dumps(roots)]
            return run(args+['--', *command], cwd)

        version = run([codex, '--version'], root)
        assert version.returncode == 0, version.stderr
        print(version.stdout.strip())
        cases = [('linked', 'none', False), ('linked', 'common', False), ('linked', 'per-worktree', False),
                 ('linked', 'both', True), ('linked', 'both-reversed', True), ('sibling', 'both', True), ('main', 'none', False), ('main', 'common', True),
                 ('linked', 'read-only', False), ('main', 'read-only', False)]
        for cwd_kind, grant, succeeds in cases:
            base = root/f'{cwd_kind}-{grant}'; base.mkdir()
            main_repo = base/'main'; main_repo.mkdir()
            g(main_repo, 'init', '-b', 'main')
            (main_repo/'work.txt').write_text('base\n'); (main_repo/'.gitignore').write_text('.worktrees/\n')
            g(main_repo, 'add', '.'); g(main_repo, 'commit', '-m', 'base')
            original = g(main_repo, 'rev-parse', 'HEAD')
            g(main_repo, 'checkout', '-b', 'incoming'); (main_repo/'incoming.txt').write_text('incoming\n')
            g(main_repo, 'add', 'incoming.txt'); g(main_repo, 'commit', '-m', 'incoming'); g(main_repo, 'checkout', 'main')
            linked = base/'worktree' if cwd_kind == 'sibling' else main_repo/'.worktrees/task'; g(main_repo, 'worktree', 'add', '-b', 'worker', str(linked))
            gitdir = g(linked, 'rev-parse', '--absolute-git-dir')
            common = g(linked, 'rev-parse', '--path-format=absolute', '--git-common-dir')
            roots = [gitdir, common] if grant == 'both-reversed' else [common, gitdir] if grant == 'both' else [common] if grant == 'common' else [gitdir] if grant == 'per-worktree' else []
            policy = 'read-only' if grant == 'read-only' else 'workspace-write'
            cwd = main_repo if cwd_kind == 'main' else linked
            command = '''set -eu
cd "$1"
printf 'worker edit\\n' >> work.txt
printf 'EDIT_OK\\n'
git add work.txt
printf 'ADD_OK\\n'
git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm worker
printf 'COMMIT_OK\\n'
git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null merge --no-ff incoming -m merge
printf 'MERGE_OK\\n'
'''
            result = sandbox(cwd, policy, roots, ['/bin/sh', '-c', command, 'fixture', str(linked)])
            assert (result.returncode == 0) == succeeds, (cwd_kind, grant, result.stdout, result.stderr)
            if succeeds:
                assert 'COMMIT_OK' in result.stdout and 'MERGE_OK' in result.stdout
                assert (linked/'incoming.txt').read_text() == 'incoming\n'
                assert g(linked, 'rev-list', '--count', 'HEAD') == '4'
                assert g(linked, 'status', '--porcelain') == ''
            elif grant == 'read-only':
                assert roots == [] and 'EDIT_OK' not in result.stdout
                denied_git = sandbox(cwd, policy, roots, [git, '-C', str(linked), 'add', 'work.txt'])
                assert denied_git.returncode != 0
            else:
                assert 'EDIT_OK' in result.stdout and 'ADD_OK' not in result.stdout
                assert 'Operation not permitted' in result.stderr
                if grant in ['none', 'common']:
                    assert 'index.lock' in result.stderr
            outside = sandbox(cwd, policy, roots, ['/bin/sh', '-c', 'printf forbidden > "$1"', 'fixture', str(root/'outside.txt')])
            assert outside.returncode != 0 and not (root/'outside.txt').exists()
            if cwd_kind != 'main':
                outside_main = sandbox(cwd, policy, roots, ['/bin/sh', '-c', 'printf forbidden > "$1"', 'fixture', str(main_repo/'outside.txt')])
                assert outside_main.returncode != 0 and not (main_repo/'outside.txt').exists()
            assert g(main_repo, 'rev-parse', 'HEAD') == original
            assert (main_repo/'work.txt').read_text() == 'base\n'
            print(f'{cwd_kind:6} / {grant:12}: {"commit + merge passed" if succeeds else "writes blocked as expected"}')

        plain = root/'not-git'; plain.mkdir()
        result = sandbox(plain, 'workspace-write', [], ['/bin/sh', '-c', 'printf allowed > work.txt'])
        assert result.returncode == 0 and (plain/'work.txt').read_text() == 'allowed'
        print('Non-Git workspace: edits passed with no extra roots. All unrelated writes stayed blocked.')


if __name__ == '__main__':
    main()
