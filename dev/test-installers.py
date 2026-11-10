#!/usr/bin/env python3
"""Installer fixtures only: fake harnesses/toolchain, private homes, no inference."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

PROJECT = Path(__file__).resolve().parent.parent
FAKE = r'''import hashlib, json, os, pathlib, shutil, sys, time
p = pathlib.Path
name = p(sys.argv[0]).name
a = sys.argv[1:]
home = p(os.environ['HOME'])
support = home / 'Library/Application Support/StandMixer'
with open(os.environ['FIXTURE_LOG'], 'a') as f: f.write(json.dumps([name, *a]) + '\n')
if name in ('codex', 'claude'):
    state = home / (name + '-marketplace.json')
    roots = json.loads(state.read_text()) if state.exists() else {}
    if isinstance(roots,str): roots={'drydock-standmixer':roots}
    if a == ['plugin', 'marketplace', 'list', '--json']:
        entries=[{'name':key,'root':root,'marketplaceSource':{'sourceType':'local','source':root}} if name == 'codex' else {'name':key,'source':'directory','path':root,'installLocation':root} for key,root in roots.items()]
        print(json.dumps({'marketplaces':entries} if name == 'codex' else entries))
    elif a[:3] == ['plugin','marketplace','add']:
        # Claude deduplicates an already-declared directory before rereading
        # its manifest, even when that manifest now declares a different name.
        if name == 'claude':
            for key, root in roots.items():
                if p(root) == p(a[3]):
                    print('Marketplace '+key+' already on disk — declared in user settings')
                    sys.exit(0)
            if os.environ.get('FIXTURE_CLAUDE_NESTED_ADD_FAIL') and a[3].endswith('/Plugins/claude-standmixer'): sys.exit(21)
        key='drydock-standmixer'
        if key in roots: sys.exit(7)
        roots[key]=a[3]
        state.write_text(json.dumps(roots))
    elif a[:3] == ['plugin','marketplace','remove']:
        del roots[a[3]]
        state.write_text(json.dumps(roots))
    elif a[:2] == ['plugin','list']:
        marketplace=a[a.index('--marketplace')+1]
        plugin='standmixer' if marketplace == 'drydock-standmixer' else 'standmixer'
        root=roots[marketplace]
        print(json.dumps({'installed':[{'pluginId':plugin+'@'+marketplace,'name':plugin,'marketplaceName':marketplace,'version':'0.1.8','installed':True,'enabled':True,'source':{'source':'local','path':root+'/Plugins/codex-standmixer'},'marketplaceSource':{'sourceType':'local','source':root}}],'available':[]}))
    elif a[:2] == ['plugin','remove'] or a[:2] == ['plugin','uninstall']:
        if os.environ.get('FIXTURE_REMOVE_MARKETPLACE'):
            roots.pop(a[2].split('@')[-1], None);state.write_text(json.dumps(roots))
    elif a[:2] in (['plugin','add'], ['plugin','install'], ['plugin','update']):
        if name == 'claude' and a[2].split('@')[-1] not in roots: print('Plugin not found in marketplace',file=sys.stderr); sys.exit(20)
        if os.environ.get('FIXTURE_PLUGIN_INSTALL_FAIL') or (a[1] == 'update' and os.environ.get('FIXTURE_PLUGIN_UPDATE_FAIL')): sys.exit(14)
    else: sys.exit(88)
elif name == 'AgentMixHelper':
    if a == ['--standmixer','uninstall','--yes']:
        print('Old fixture uninstalled')
    elif not a:
        print(json.dumps({'state':{'installation':{'hasInstallation':bool(os.environ.get('FIXTURE_OLD_CONFLICT'))}}}))
    else:sys.exit(89)
elif name == 'StandMixerHelper':
    if a == ['--bootstrap']:
        dest = support / ('bin' if os.environ.get('FIXTURE_LEGACY_BOOTSTRAP') else 'runtime') / 'StandMixerHelper'
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest != p(sys.argv[0]): shutil.copyfile(sys.argv[0], dest); dest.chmod(0o700)
        print(dest)
    elif a == ['--installer-keep-native-defaults']: pass
    elif a[:1] == ['--installer-marketplace-source']:
        if os.environ.get('FIXTURE_BAD_UI_INODE') == str(p(sys.argv[0]).stat().st_ino): os.kill(os.getpid(),9)
        data = json.load(sys.stdin)
        entries = data['marketplaces'] if a[1] == 'codex' else data
        found = [x for x in entries if x['name'] == (a[2] if len(a) > 2 else 'drydock-standmixer')]
        if not found: sys.exit(3)
        if len(found) != 1: sys.exit(2)
        entry = found[0]
        if (a[1] == 'codex' and entry['marketplaceSource']['sourceType'] != 'local') or (a[1] == 'claude' and entry['source'] != 'directory'): sys.exit(2)
        print(entry['root' if a[1] == 'codex' else 'path'])
    elif a == ['--standmixer','install','--yes']:
        for root in [home / '.agents', p(os.environ['CLAUDE_CONFIG_DIR'])]:
            dest = root / 'skills/standmixer/SKILL.md'
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text('Managed by StandMixer fixture\n')
    elif a[:1] == ['--session-url']:
        print(json.loads(p(a[1]).read_text())['url'])
    elif a[:1] == ['--serve-ui']:
        if os.environ.get('FIXTURE_WEB_LISTENER_ERROR'):
            print('StandMixer embedded panel: The operation could not be completed. (Network.NWError error '+os.environ['FIXTURE_WEB_LISTENER_ERROR']+'.)',file=sys.stderr)
            sys.exit(1)
        print(json.dumps({'url':'http://127.0.0.1:9/#token=fixture','pid':os.getpid(),'engine':str(p(sys.argv[0]))}), flush=True)
        time.sleep(10)
    elif a[:1] == ['--mcp']: print(json.dumps({'engine':str(p(sys.argv[0]))}))
    elif a[:1] == ['--standmixer']: print('fixture command ' + ' '.join(a[1:]) + ' via ' + str(p(sys.argv[0])))
    else: sys.exit(89)
elif name == 'xcrun':
    print(p(sys.argv[0]).parent / a[1] if a[:1] == ['--find'] else os.environ['FIXTURE_SDK'])
elif name in ('swift','swiftc'):
    if a == ['--version']: print('Apple Swift version ' + os.environ.get('FIXTURE_SWIFT_VERSION', '6.0'))
    elif '-typecheck' in a:
        if name != 'swiftc': print('Use swiftc for typecheck', file=sys.stderr); sys.exit(2)
        if os.environ.get('FIXTURE_BAD_SDK'): print('SDK fixture lacks SwiftUI', file=sys.stderr); sys.exit(1)
        if os.environ.get('FIXTURE_SDK_MACRO_MISSING') and 'MacOSX27.0.sdk' in a[a.index('-sdk')+1] and '@State' in p(a[-1]).read_text():
            print('SwiftUIMacros.StateMacro plugin missing', file=sys.stderr); sys.exit(1)
    elif a[:1] == ['build']:
        app = home/'Applications/StandMixer.app'
        if os.environ.get('FIXTURE_APP_APPEARS'):
            app.mkdir(parents=True, exist_ok=True)
            (app/'keep').write_text('new user app')
        if os.environ.get('FIXTURE_APP_CHANGES'): (app/'Contents/MacOS/StandMixer').write_text('user edit during build')
        if os.environ.get('FIXTURE_RECEIPT_CHANGES'): (support/'mac-app.receipt').write_text('user receipt edit')
        if os.environ.get('FIXTURE_BUILD_FAIL'):
            print('fixture compiler error: source did not compile',file=sys.stderr)
            sys.exit(9)
        scratch = p(a[a.index('--scratch-path')+1]) / 'release'
        scratch.mkdir(parents=True, exist_ok=True)
        product=a[a.index('--product')+1] if '--product' in a else 'StandMixer'
        payload='fixture app binary ' + os.environ.get('FIXTURE_APP_VERSION','one')
        if os.environ.get('FIXTURE_LEAK_PATH'): payload += str(home)
        (scratch / product).write_text(payload)
        (scratch / product).chmod(0o700)
        if '--show-bin-path' in a: print(scratch)
    else: pass
elif name == 'lipo':
    if a[:1] == ['-create']: shutil.copyfile(a[1], a[a.index('-output')+1])
elif name == 'iconutil': p(a[a.index('-o')+1]).write_text('icon fixture')
elif name == 'codesign':
    if '--verify' in a and os.environ.get('FIXTURE_SIGN_FAIL') and '.standmixer-deploy.' in a[-1]: sys.exit(5)
elif name == 'mv':
    if os.environ.get('FIXTURE_COMMAND_RECEIPT_FAIL') and a[-1] == str(support/'bin/.standmixer-launcher.sha256') and '.command-stage.' in a[0] and '/previous-' not in a[0]: sys.exit(13)
    if os.environ.get('FIXTURE_RECEIPT_FAIL') and a[-1] == str(support/'mac-app.receipt'): sys.exit(11)
    if os.environ.get('FIXTURE_SOURCE_PUBLISH_FAIL') and a[-1] == str(support/'source') and not a[0].endswith('previous-source'): sys.exit(12)
    import subprocess
    sys.exit(subprocess.run(['/bin/mv', *a]).returncode)
elif name == 'ditto': shutil.copytree(a[0], a[1], dirs_exist_ok=True)
elif name == 'sw_vers': print('14.0')
elif name == 'uname': print('arm64' if a==['-m'] else 'Darwin')
elif name in ('open','xattr','strip'): pass
else: sys.exit(90)
'''

class Installers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='standmixer-install-fixture-', dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source checkout'
        self.source.mkdir()
        for file in ['install.sh','dev/install-common.sh','dev/retire-old-install.sh','dev/standmixer.sh','dev/update.sh','dev/install-mac.sh','dev/build.sh','dev/build-paths.sh','dev/build-claude-plugin.sh','dev/build-codex-plugin.sh','dev/install-codex-ui.sh','dev/make-icon.swift','Plugins/claude-standmixer/scripts/bootstrap.sh','Plugins/claude-standmixer/.claude-plugin/marketplace.json','Plugins/codex-standmixer/scripts/mcp.sh']:
            dest = self.source / file
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / file, dest)
        for file in ['.agents/plugins/marketplace.json','.claude-plugin/marketplace.json','Plugins/codex-standmixer/ui/index.html']:
            dest = self.source / file
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text('{}')
        for host in ['codex','claude']:
            dest = self.source / f'Plugins/{host}-standmixer/bin/StandMixerHelper'
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text('#!' + sys.executable + '\n' + FAKE)
            dest.chmod(0o700)
        panel = self.source / 'Plugins/codex-standmixer/scripts/open-ui.sh'
        panel.parent.mkdir(parents=True, exist_ok=True)
        panel.write_text("#!/bin/sh\nprintf 'called\\n' > \"$HOME/web-launcher-called\"\nprintf '%s\\n' '{\"url\":\"http://127.0.0.1:12345/#token=fixture\",\"pid\":123}'\n")
        self.home = self.root / 'private home'
        self.home.mkdir()
        self.bin = self.root / 'fake-tools'
        self.bin.mkdir()
        for name in ['codex','claude','xcrun','swift','swiftc','codesign','iconutil','ditto','open','xattr','sw_vers','uname','mv','strip','lipo']:
            dest = self.bin / name
            dest.write_text('#!' + sys.executable + '\n' + FAKE)
            dest.chmod(0o700)
        self.sdk = self.root / 'sdk'
        self.sdk.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), CODEX_HOME=str(self.home/'custom codex'), CLAUDE_CONFIG_DIR=str(self.home/'custom claude'), PATH=str(self.bin)+':/usr/bin:/bin:/usr/sbin:/sbin', FIXTURE_LOG=str(self.root/'calls.jsonl'), FIXTURE_SDK=str(self.sdk), STANDMIXER_APPLICATIONS_DIR=str(self.root/'fixture Applications'))
        for var in ['GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','SDKROOT','CODEX_THREAD_ID','CLAUDECODE']: self.env.pop(var, None)
        self.git('init','-q')
        self.git('add','.')
        self.git('-c','user.name=StandMixer Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture installer source')
        self.support = self.home / 'Library/Application Support/StandMixer'
        self.launcher = self.support / 'bin/standmixer'
        self.app = self.home / 'Applications/StandMixer.app'
        for config, text in [(self.home/'custom codex/config.toml','model = "keep-codex"\n'), (self.home/'custom claude/settings.json','{"model":"keep-claude"}\n')]:
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text(text)

    def tearDown(self): self.temp.cleanup()
    def git(self, *args): subprocess.run(['git','-C',str(self.source),*args], check=True, capture_output=True, env=self.env)
    def call(self, script, *args, okay=True, env=None):
        result = subprocess.run(['/bin/sh',str(script),*args], text=True, capture_output=True, env=env or self.env, timeout=30)
        if okay: self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        else: self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        return result
    def install(self, *args): return self.call(self.source/'install.sh','--no-open',*args)
    def calls(self): return [json.loads(x) for x in Path(self.env['FIXTURE_LOG']).read_text().splitlines()]

    def seed_old_install(self):
        old = self.home / 'Library/Application Support/AgentMix'
        (old/'source').mkdir(parents=True)
        (old/'source/.agentmix-source').write_text('AgentMix source checkout v1\n')
        (old/'runtime').mkdir()
        engine = old/'runtime/AgentMixHelper'
        engine.write_text('#!' + sys.executable + '\n' + FAKE); engine.chmod(0o700)
        (old/'runtime/.engine.sha256').write_text(hashlib.sha256(engine.read_bytes()).hexdigest()+'\n')
        (old/'configuration.json').write_text('{"custom":"keep"}')
        (old/'presets.json').write_text('[]')
        for host in ['codex', 'claude']:
            root = old/'source' if host == 'codex' else old/'source/Plugins/claude-agentmix'
            (self.home/f'{host}-marketplace.json').write_text(json.dumps({'drydock-standmixer':str(root)}))
        return old

    def test_old_install_retired_once_preferences_kept_and_registrations_replaced(self):
        old = self.seed_old_install()
        (old/'private-notes').write_text('preserve unrelated file')
        result = self.install()
        self.assertIn('Old installation retired', result.stdout)
        self.assertFalse(old.exists())
        retired = list((self.support/'Retired').glob('*/support'))
        self.assertEqual(len(retired), 1)
        self.assertEqual((retired[0]/'private-notes').read_text(), 'preserve unrelated file')
        self.assertEqual((self.support/'configuration.json').read_text(), '{"custom":"keep"}')
        for host in ['codex','claude']:
            roots=json.loads((self.home/f'{host}-marketplace.json').read_text())
            self.assertTrue(roots['drydock-standmixer'].startswith(str(self.support/'source')))
        self.install()
        self.assertEqual(sum(x[:2] == ['AgentMixHelper','--standmixer'] for x in self.calls()),1)

    def test_old_plugin_removal_may_also_remove_its_marketplace(self):
        old=self.seed_old_install();self.env['FIXTURE_REMOVE_MARKETPLACE']='1'
        self.install()
        self.assertFalse(old.exists())
        for host in ['codex','claude']:
            roots=json.loads((self.home/f'{host}-marketplace.json').read_text())
            self.assertTrue(roots['drydock-standmixer'].startswith(str(self.support/'source')))

    def test_old_modified_helper_or_cleanup_conflicts_are_preserved(self):
        old = self.seed_old_install()
        engine = old/'runtime/AgentMixHelper'
        engine.write_text(engine.read_text()+'# edited\n')
        self.assertIn('helper was modified', self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertTrue(old.exists())
        (old/'runtime/.engine.sha256').write_text(hashlib.sha256(engine.read_bytes()).hexdigest()+'\n')
        self.env['FIXTURE_OLD_CONFLICT']='1'
        self.assertIn('Old settings have conflicts',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertTrue(old.exists())
        self.assertFalse((old/'.source-install.lock').exists())
        self.assertFalse(any(x[:2] in (['codex','plugin'],['claude','plugin']) and 'remove' in x for x in self.calls()))

    def test_old_app_retirement_requires_receipt_and_new_preferences_win(self):
        old = self.seed_old_install()
        app=self.home/'Applications/StandMixer.app'
        binary=app/'Contents/MacOS/AgentMix';binary.parent.mkdir(parents=True);binary.write_bytes(b'old app')
        (old/'mac-app.receipt').write_text(str(app)+'\n'+hashlib.sha256(binary.read_bytes()).hexdigest()+'\n')
        self.support.mkdir(parents=True);(self.support/'configuration.json').write_text('{"custom":"new"}')
        self.install()
        self.assertFalse(app.exists())
        self.assertTrue(next((self.support/'Retired').glob('*/previous.app')).exists())
        self.assertEqual((self.support/'configuration.json').read_text(),'{"custom":"new"}')

    def test_foreign_registration_stops_before_old_uninstall(self):
        old=self.seed_old_install()
        (self.home/'claude-marketplace.json').write_text(json.dumps({'drydock-standmixer':'/unrelated/source'}))
        self.assertIn('uses another source',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertTrue(old.exists())
        self.assertFalse(any(x[:2]==['AgentMixHelper','--standmixer'] for x in self.calls()))

    def test_old_root_redirect_and_active_installer_are_preserved(self):
        old = self.seed_old_install()
        lock=old/'.source-install.lock';lock.mkdir()
        self.assertIn('old installation is still running',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertTrue(lock.exists());lock.rmdir()
        moved=self.root/'unrelated';old.rename(moved);old.symlink_to(moved)
        self.assertIn('redirected',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertTrue((moved/'configuration.json').exists())

    def prepare_update(self):
        official='https://github.com/drydockbuild/standmixer.git'
        self.git('remote','add','origin',official)
        self.install()
        self.env['FIXTURE_UPDATE_SOURCE']=str(self.source)
        self.env['FIXTURE_REAL_GIT']=shutil.which('git')
        temporary=self.root/'update scratch'; temporary.mkdir(); self.env['TMPDIR']=str(temporary)
        wrapper=self.bin/'git'
        wrapper.write_text('#!'+sys.executable+'\n'+r'''
import os,sys,subprocess,pathlib,json
args=sys.argv[1:];real=os.environ['FIXTURE_REAL_GIT'];official='https://github.com/drydockbuild/standmixer.git'
if 'clone' in args and official in args:
    with open(os.environ['FIXTURE_LOG'],'a') as f:f.write(json.dumps(['git-update-clone',official])+'\n')
    if os.environ.get('FIXTURE_UPDATE_CLONE_FAIL'):sys.exit(37)
    args[args.index(official)]=pathlib.Path(os.environ['FIXTURE_UPDATE_SOURCE']).as_uri()
    result=subprocess.run([real,*args])
    if result.returncode:sys.exit(result.returncode)
    sys.exit(subprocess.run([real,'-C',args[-1],'remote','set-url','origin',official]).returncode)
os.execv(real,[real,*args])
''')
        wrapper.chmod(0o700)
        (self.source/'release.txt').write_text('new release\n')
        self.git('add','release.txt')
        self.git('-c','user.name=StandMixer Fixture','-c','user.email=fixture@example.invalid','commit','-qm','new release')

    def test_update_fetches_official_source_and_keeps_settings_without_opening_or_building(self):
        self.prepare_update()
        draft=self.support/'configuration.json';draft.write_text('{"customPreset":"keep"}\n')
        protected=[draft,self.home/'custom codex/config.toml',self.home/'custom claude/settings.json']
        before={p:p.read_bytes() for p in protected}
        result=self.call(self.launcher,'update')
        self.assertIn('StandMixer updated to',result.stdout)
        self.assertEqual((self.support/'source/release.txt').read_text(),'new release\n')
        self.assertEqual(before,{p:p.read_bytes() for p in protected})
        self.assertFalse(self.app.exists())
        self.assertFalse(any(c[0] in ['swift','open'] for c in self.calls()))
        self.assertFalse((self.home/'web-launcher-called').exists())
        self.assertFalse(list(Path(self.env['TMPDIR']).glob('standmixer-update.*')))
        self.assertIn('Source is current; refreshing',self.call(self.launcher,'update').stdout)

    def test_update_refuses_dirty_source_forks_and_invalid_arguments_before_download(self):
        self.prepare_update()
        for args in [('update','--yes'),('update','https://example.invalid/repo'),('update','--mac','extra')]:
            self.assertIn('Usage:',self.call(self.launcher,*args,okay=False).stderr)
        self.assertIn('Usage:',self.call(self.launcher,'update','--help').stdout)
        dirty=self.support/'source/local-notes.txt';dirty.write_text('user work')
        self.assertIn('local changes',self.call(self.launcher,'update',okay=False).stderr)
        self.assertEqual(dirty.read_text(),'user work');dirty.unlink()
        subprocess.run([self.env['FIXTURE_REAL_GIT'],'-C',str(self.support/'source'),'remote','set-url','origin','https://example.invalid/fork.git'],check=True)
        self.assertIn('another source repository',self.call(self.launcher,'update',okay=False).stderr)
        self.assertFalse(any(c[0]=='git-update-clone' for c in self.calls()))

    def test_update_download_failure_cleans_up_and_failed_registration_can_retry_current_source(self):
        self.prepare_update()
        self.env['FIXTURE_UPDATE_CLONE_FAIL']='1'
        self.assertEqual(self.call(self.launcher,'update',okay=False).returncode,37)
        self.assertFalse((self.support/'source/release.txt').exists())
        self.assertFalse(list(Path(self.env['TMPDIR']).glob('standmixer-update.*')))
        del self.env['FIXTURE_UPDATE_CLONE_FAIL']
        self.env['FIXTURE_PLUGIN_INSTALL_FAIL']='1'
        self.call(self.launcher,'update',okay=False)
        self.assertTrue((self.support/'source/release.txt').exists())
        del self.env['FIXTURE_PLUGIN_INSTALL_FAIL']
        self.assertIn('Source is current; refreshing',self.call(self.launcher,'update').stdout)

    def test_update_mac_is_explicit_and_reports_partial_failure(self):
        self.prepare_update()
        self.call(self.launcher,'update','--mac')
        binary=self.app/'Contents/MacOS/StandMixer';before=binary.read_bytes()
        self.assertFalse(any(c[0]=='open' for c in self.calls()))
        self.env['FIXTURE_BUILD_FAIL']='1'
        result=self.call(self.launcher,'update','--mac',okay=False)
        self.assertIn('plugins were updated, but the Mac app update did not finish',result.stderr)
        self.assertEqual(binary.read_bytes(),before)

    def test_clone_entered_through_macos_var_alias(self):
        physical=Path(tempfile.gettempdir()).resolve()
        if not physical.is_relative_to('/private/var') or not Path('/var').is_symlink():
            self.skipTest('Requires the real macOS /var temporary-directory alias')
        alias=Path('/var')/physical.relative_to('/private/var')
        with tempfile.TemporaryDirectory(prefix='standmixer-var-alias-',dir=alias) as temporary:
            checkout=Path(temporary)/'fresh checkout'
            subprocess.run(['git','clone','--quiet','--no-hardlinks',str(self.source),str(checkout)],check=True,capture_output=True,env=self.env)
            git_root=subprocess.check_output(['git','-C',str(checkout),'rev-parse','--show-toplevel'],text=True,env=self.env).strip()
            self.assertNotEqual(str(checkout),git_root)
            self.assertEqual(str(checkout.resolve()),git_root)
            self.call(checkout/'install.sh','--host','codex','--no-open')
            self.assertTrue(self.launcher.is_file())
            self.assertTrue((self.support/'source/.git').is_dir())

    def test_parent_repository_subdirectory_is_not_a_checkout_root(self):
        nested=self.source/'nested package'
        for name in ['install.sh','dev/install-common.sh']:
            target=nested/name
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(PROJECT/name,target)
        self.git('add','.')
        self.git('-c','user.name=StandMixer Fixture','-c','user.email=fixture@example.invalid','commit','-qm','parent repository fixture')
        result=self.call(nested/'install.sh','--no-open',okay=False)
        self.assertIn('Expected the complete StandMixer Git checkout',result.stderr)
        self.assertFalse((self.support/'source').exists())

    def test_install_repeat_and_durable_launcher(self):
        self.install('--host','codex')
        self.install('--host','claude')
        self.assertTrue((self.support/'source/.git').is_dir())
        self.assertEqual((self.home/'custom codex/config.toml').read_text(),'model = "keep-codex"\n')
        self.assertEqual((self.home/'custom claude/settings.json').read_text(),'{"model":"keep-claude"}\n')
        self.assertEqual(sum(x[1:4] == ['plugin','marketplace','add'] for x in self.calls()),2)
        self.assertEqual(sum(x[1:3] == ['plugin','update'] for x in self.calls()),2)
        self.assertFalse(any(x[0]=='open' for x in self.calls()))
        shutil.rmtree(self.source)
        self.assertIn('native settings panel',self.call(self.launcher,'settings','--host','codex').stdout)
        self.assertIn('/standmixer',self.call(self.launcher,'settings','--host','claude').stdout)
        self.call(self.launcher,'status')

    def test_codex_host_uses_native_panel_without_web(self):
        self.env['FIXTURE_WEB_LISTENER_ERROR']='1'
        installed=self.call(self.source/'install.sh','--host','codex')
        self.assertIn('/standmixer',installed.stdout)
        self.assertIn('restart Codex',installed.stdout)
        marker=self.home/'web-launcher-called'
        self.assertFalse(marker.exists())
        self.support.chmod(0o500)
        try:
            result=self.call(self.launcher,'settings','--host','codex')
            self.assertIn('native settings panel',result.stdout)
            self.assertNotIn('http://',result.stdout)
            self.assertFalse((self.support/'CodexSessions').exists())
        finally:self.support.chmod(0o700)
        self.assertFalse(marker.exists())
        self.assertFalse(any('--serve-ui' in x or x[0]=='open' for x in self.calls()))
        # Terminal settings and explicit Web commands retain their browser path.
        self.assertIn('http://127.0.0.1:',self.call(self.launcher,'settings','--no-open').stdout)
        self.assertTrue(marker.exists())
        self.call(self.launcher,'settings')
        self.assertTrue(any(x[0]=='open' for x in self.calls()))

    def test_installer_detects_codex_without_starting_web(self):
        self.env['CODEX_THREAD_ID']='fixture-thread'
        self.env['CLAUDECODE']='1'
        result=self.call(self.source/'install.sh')
        self.assertIn('new Codex chat',result.stdout)
        self.assertFalse((self.home/'web-launcher-called').exists())
        self.assertFalse(any('--serve-ui' in x or x[0]=='open' for x in self.calls()))

    def test_installer_detects_claude_without_starting_web(self):
        self.env['CLAUDECODE']='1'
        result=self.call(self.source/'install.sh')
        self.assertIn('Open Claude Code and run /standmixer',result.stdout)
        self.assertFalse((self.home/'web-launcher-called').exists())
        self.assertFalse(any('--serve-ui' in x or x[0]=='open' for x in self.calls()))

    def test_installer_explicit_host_overrides_detected_context(self):
        self.env['CODEX_THREAD_ID']='fixture-thread'
        result=self.call(self.source/'install.sh','--host','claude')
        self.assertIn('Open Claude Code and run /standmixer',result.stdout)
        self.assertNotIn('new Codex chat',result.stdout)
        self.env.pop('CODEX_THREAD_ID')
        self.env['CLAUDECODE']='1'
        result=self.call(self.source/'install.sh','--host','codex')
        self.assertIn('new Codex chat',result.stdout)
        self.assertFalse((self.home/'web-launcher-called').exists())
        self.assertFalse(any('--serve-ui' in x or x[0]=='open' for x in self.calls()))

    def test_explicit_web_reports_session_folder_permissions(self):
        script=self.source/'Plugins/codex-standmixer/scripts/open-ui.sh'
        shutil.copyfile(PROJECT/'Plugins/codex-standmixer/scripts/open-ui.sh',script)
        library=self.home/'Library'
        library.mkdir()
        library.chmod(0o500)
        try:
            result=self.call(script,okay=False)
            self.assertIn('cannot write its private session folder',result.stderr)
            self.assertIn('/standmixer in Codex',result.stderr)
        finally:library.chmod(0o700)
        denied_chmod=self.bin/'chmod'
        denied_chmod.write_text('#!/bin/sh\nexit 1\n')
        denied_chmod.chmod(0o700)
        self.assertIn('cannot write its private session folder',self.call(script,okay=False).stderr)
        self.assertFalse(Path(self.env['FIXTURE_LOG']).exists())

    def test_explicit_web_reports_listener_denial_without_retry(self):
        script=self.source/'Plugins/codex-standmixer/scripts/open-ui.sh'
        shutil.copyfile(PROJECT/'Plugins/codex-standmixer/scripts/open-ui.sh',script)
        for code in ['1','13','10']:
            with self.subTest(code=code):
                log=Path(self.env['FIXTURE_LOG'])
                if log.exists():log.unlink()
                self.env['FIXTURE_WEB_LISTENER_ERROR']=code
                result=self.call(script,okay=False)
                if code in ['1','13']:
                    self.assertIn('denied network permission',result.stderr)
                    self.assertIn('native panel',result.stderr)
                else:
                    self.assertNotIn('denied network permission',result.stderr)
                    self.assertIn('Network.NWError error 10',result.stderr)
                self.assertEqual(sum('--serve-ui' in x for x in self.calls()),1)
                self.assertFalse((self.support/'CodexSessions/current.json').exists())


    def test_only_canonical_command_is_installed(self):
        self.install()
        self.assertTrue((self.support/'bin/standmixer').exists())
        self.assertTrue((self.support/'bin/.standmixer-launcher.sha256').exists())
        self.assertIn('stable no-inference command launcher v1',self.launcher.read_text())
        self.assertIn('--standmixer',self.launcher.read_text())
        receipt=self.support/'bin/.standmixer-launcher.sha256'
        self.assertEqual(receipt.read_text().strip(),hashlib.sha256(self.launcher.read_bytes()).hexdigest())
        session=json.loads(self.call(self.launcher,'web-url').stdout)
        self.assertEqual(session['url'],'http://127.0.0.1:12345/#token=fixture')
        self.assertIn(str(self.support/'runtime/StandMixerHelper'),self.call(self.launcher,'status').stdout)
        self.assertFalse(any(x[0]=='open' for x in self.calls()))





    def test_canonical_command_symlink_is_preserved_and_fresh_failure_rolls_back(self):
        self.env['FIXTURE_COMMAND_RECEIPT_FAIL']='1'
        self.call(self.source/'install.sh','--no-open',okay=False)
        for name in ['standmixer','standmixer','.standmixer-launcher.sha256','.standmixer-launcher.sha256']:
            self.assertFalse((self.support/'bin'/name).exists())
        del self.env['FIXTURE_COMMAND_RECEIPT_FAIL']
        self.install()
        outside=self.root/'outside command'
        outside.write_text('preserve outside')
        original=self.launcher.read_bytes()
        self.launcher.unlink();self.launcher.symlink_to(outside)
        self.assertIn('redirected',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertTrue(self.launcher.is_symlink())
        self.assertEqual(outside.read_text(),'preserve outside')




    def test_detected_harness_and_empty_custom_config_roots(self):
        (self.bin/'claude').unlink()
        shutil.rmtree(self.home/'custom codex')
        shutil.rmtree(self.home/'custom claude')
        self.install('--host','codex')
        self.assertTrue((self.home/'custom codex').is_dir())
        self.assertFalse(any(x[0]=='claude' for x in self.calls()))
        self.assertEqual(sum(x[1:4]==['plugin','marketplace','add'] for x in self.calls()),1)

    def test_known_cli_fallbacks_and_path_precedence(self):
        # PATH stays authoritative even when a known bundle also exists.
        codex=Path(self.env['STANDMIXER_APPLICATIONS_DIR'])/'ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
        codex.parent.mkdir(parents=True)
        codex.write_text('#!'+sys.executable+'\n'+FAKE)
        codex.chmod(0o700)
        native=self.home/'.local/bin/claude'
        native.parent.mkdir(parents=True)
        native.write_text('#!'+sys.executable+'\n'+FAKE)
        native.chmod(0o700)
        common=str(self.source/'dev/install-common.sh')
        def find(platform):
            result=subprocess.run(['/bin/sh','-c','. "$1"; standmixer_find_cli "$2"','fixture',common,platform],env=self.env,text=True,capture_output=True,check=True)
            return result.stdout.strip()
        self.assertEqual(find('codex'),str(self.bin/'codex'))
        self.assertEqual(find('claude'),str(self.bin/'claude'))
        (self.bin/'codex').unlink()
        (self.bin/'claude').unlink()
        self.assertEqual(find('codex'),str(codex))
        self.assertEqual(find('claude'),str(native))
        self.install('--host','codex')
        self.assertTrue((self.home/'codex-marketplace.json').exists())
        self.assertTrue((self.home/'claude-marketplace.json').exists())
        self.assertTrue(all(x[1:2]==['plugin'] for x in self.calls() if x[0] in ('codex','claude')))

    def test_marketplace_migration_and_conflict(self):
        for host in ['codex','claude']: (self.home/f'{host}-marketplace.json').write_text(json.dumps(str(self.source)))
        self.install()
        for host in ['codex','claude']:
            expected=self.support/'source' if host == 'codex' else self.support/'source/Plugins/claude-standmixer'
            self.assertEqual(json.loads((self.home/f'{host}-marketplace.json').read_text())['drydock-standmixer'],str(expected))
        (self.home/'codex-marketplace.json').write_text(json.dumps('/some/other/checkout'))
        result=self.call(self.source/'install.sh','--no-open',okay=False)
        self.assertIn('belongs to another source',result.stderr)
        self.assertEqual(json.loads((self.home/'codex-marketplace.json').read_text()),'/some/other/checkout')



    def test_claude_canonical_root_retarget_failure_restores_prior_registration(self):
        (self.bin/'codex').unlink()
        self.install('--host','claude')
        state=self.home/'claude-marketplace.json'
        previous={'drydock-standmixer':str(self.support/'source')}
        state.write_text(json.dumps(previous))
        self.env['FIXTURE_CLAUDE_NESTED_ADD_FAIL']='1'
        result=self.call(self.source/'install.sh','--host','claude','--no-open',okay=False)
        self.assertIn('prior source was restored',result.stderr)
        self.assertEqual(json.loads(state.read_text()),previous)

    def test_claude_canonical_install_failure_restores_prior_root_registration(self):
        (self.bin/'codex').unlink()
        self.install('--host','claude')
        state=self.home/'claude-marketplace.json'
        previous={'drydock-standmixer':str(self.support/'source')}
        for failure in ['FIXTURE_PLUGIN_INSTALL_FAIL','FIXTURE_PLUGIN_UPDATE_FAIL']:
            with self.subTest(failure=failure):
                state.write_text(json.dumps(previous))
                self.env[failure]='1'
                self.call(self.source/'install.sh','--host','claude','--no-open',okay=False)
                self.assertEqual(json.loads(state.read_text()),previous)
                del self.env[failure]










    def test_refuse_modified_source_launcher_and_redirect(self):
        self.install()
        self.launcher.write_text('unowned edit\n')
        self.assertIn('launcher was modified',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.launcher.unlink()
        (self.support/'source/dev/standmixer.sh').write_text('local source edit\n')
        self.assertIn('local changes',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        shutil.rmtree(self.support/'source')
        outside=self.root/'outside'; outside.mkdir()
        (self.support/'source').symlink_to(outside)
        self.assertIn('redirected',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertEqual(list(outside.iterdir()),[])

    def test_ui_launcher_replacement_and_modification(self):
        self.install()
        launcher=self.support/'bin/open-codex-ui'
        receipt=self.support/'bin/.codex-ui-launcher.sha256'
        ui=self.source/'Plugins/codex-standmixer/ui/index.html'
        ui.write_text('updated fixture assets')
        self.git('add','.')
        self.git('-c','user.name=StandMixer Fixture','-c','user.email=fixture@example.invalid','commit','-qm','update embedded assets')
        self.install()
        self.assertEqual(receipt.read_text().strip(),hashlib.sha256(launcher.read_bytes()).hexdigest())
        launcher.write_text(launcher.read_text()+'# user edit\n')
        modified=launcher.read_bytes()
        self.assertIn('UI launcher was modified',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertEqual(launcher.read_bytes(),modified)
        receipt.unlink()
        self.assertIn('unsafe or unowned file',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertEqual(launcher.read_bytes(),modified)

    def test_ui_assets_modification_is_preserved(self):
        self.install()
        asset=next((self.support/'CodexUI').glob('*/scripts/open-ui.sh'))
        asset.write_text('user script edit\n')
        self.assertIn('UI assets were modified',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertEqual(asset.read_text(),'user script edit\n')

    def test_legacy_bootstrap_cannot_redirect_plugin_or_canonical_runtime(self):
        # Exercise the real launch scripts with fake metadata-only helper payloads.
        shutil.copyfile(PROJECT/'Plugins/codex-standmixer/scripts/open-ui.sh', self.source/'Plugins/codex-standmixer/scripts/open-ui.sh')
        self.git('add','.')
        self.git('-c','user.name=StandMixer Fixture','-c','user.email=fixture@example.invalid','commit','-qm','real launcher fixture')
        self.install()
        runtime = self.support/'runtime/StandMixerHelper'
        payload = runtime.read_bytes()
        generation = next((self.support/'CodexUI').iterdir())
        ui_payload = (generation/'bin/StandMixerHelper').read_bytes()
        # Simulate an already-shipped older cached bootstrap, which knows only bin.
        old = self.root/'older cached plugin/bootstrap.sh'
        old.parent.mkdir()
        old.write_text('#!/bin/sh\nset -eu\nmkdir -p "$HOME/Library/Application Support/StandMixer/bin"\nprintf \'older engine\\n\' > "$HOME/Library/Application Support/StandMixer/bin/StandMixerHelper"\n')
        self.call(old)
        self.assertEqual(runtime.read_bytes(), payload)
        self.assertIn(str(runtime), self.call(self.launcher,'status').stdout)
        for host in ['codex','claude']:
            plugin = self.support/f'source/Plugins/{host}-standmixer'
            if host == 'codex':
                self.assertEqual(json.loads(self.call(plugin/'scripts/mcp.sh').stdout)['engine'],str(plugin/'bin/StandMixerHelper'))
            else:
                self.assertEqual(self.call(plugin/'scripts/bootstrap.sh').stdout.strip(),str(plugin/'bin/StandMixerHelper'))
        for script, expected in [(self.support/'source/Plugins/codex-standmixer/scripts/open-ui.sh', self.support/'source/Plugins/codex-standmixer/bin/StandMixerHelper'), (self.support/'bin/open-codex-ui', generation/'bin/StandMixerHelper')]:
            session = json.loads(self.call(script).stdout)
            try: self.assertEqual(session['engine'],str(expected))
            finally:
                try: os.kill(session['pid'],15)
                except ProcessLookupError: pass
        self.assertEqual((generation/'bin/StandMixerHelper').read_bytes(),ui_payload)

    def test_identical_ui_generation_reuses_helper_inode_and_mtime(self):
        self.install()
        generation=next((self.support/'CodexUI').iterdir())
        files=[generation/p for p in ['ui/index.html','scripts/open-ui.sh','bin/StandMixerHelper']]
        before={p:(p.stat().st_ino,p.stat().st_mtime_ns) for p in files}
        self.install()
        self.assertEqual(before,{p:(p.stat().st_ino,p.stat().st_mtime_ns) for p in files})

    def test_exact_execution_bad_ui_helper_gets_fresh_inode_without_asset_rewrite(self):
        self.install()
        generation=next((self.support/'CodexUI').iterdir())
        helper=generation/'bin/StandMixerHelper'
        payload=helper.read_bytes()
        old_inode=helper.stat().st_ino
        assets=[generation/'ui/index.html',generation/'scripts/open-ui.sh']
        before={p:(p.stat().st_ino,p.stat().st_mtime_ns) for p in assets}
        self.env['FIXTURE_BAD_UI_INODE']=str(old_inode)
        self.install()
        self.assertNotEqual(helper.stat().st_ino,old_inode)
        self.assertEqual(helper.read_bytes(),payload)
        self.assertEqual(before,{p:(p.stat().st_ino,p.stat().st_mtime_ns) for p in assets})
        # The repaired generation is immutable on the next identical install.
        repaired=(helper.stat().st_ino,helper.stat().st_mtime_ns)
        self.install()
        self.assertEqual((helper.stat().st_ino,helper.stat().st_mtime_ns),repaired)

    def test_modified_installed_ui_helper_is_preserved(self):
        self.install()
        helper = next((self.support/'CodexUI').glob('*/bin/StandMixerHelper'))
        helper.write_text('user helper edit\n')
        self.assertIn('UI assets were modified',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertEqual(helper.read_text(),'user helper edit\n')

    def test_stale_bundled_bootstrap_cannot_rebind_installed_runtime(self):
        self.install()
        runtime = self.support/'runtime/StandMixerHelper'
        original = runtime.read_bytes()
        launcher = (self.support/'bin/open-codex-ui').read_bytes()
        self.env['FIXTURE_LEGACY_BOOTSTRAP'] = '1'
        self.assertIn('older StandMixer helper',self.call(self.source/'install.sh','--no-open',okay=False).stderr)
        self.assertEqual(runtime.read_bytes(),original)
        self.assertEqual((self.support/'bin/open-codex-ui').read_bytes(),launcher)

    def test_local_app_build_update_and_failures(self):
        self.install()
        self.call(self.launcher,'install-mac','--no-open')
        binary=self.app/'Contents/MacOS/StandMixer'
        first=binary.read_text()
        self.assertFalse(any(x[0]=='open' for x in self.calls()))
        self.assertFalse(any('--arch' in x for x in self.calls() if x[0]=='swift'))
        self.env['FIXTURE_APP_VERSION']='two'
        self.call(self.launcher,'install-mac','--no-open')
        self.assertNotEqual(binary.read_text(),first)
        current=binary.read_bytes()
        for option in ['FIXTURE_BUILD_FAIL','FIXTURE_SIGN_FAIL','FIXTURE_BAD_SDK','FIXTURE_RECEIPT_FAIL']:
            self.env[option]='1'
            self.call(self.launcher,'install-mac','--no-open',okay=False)
            self.assertEqual(binary.read_bytes(),current)
            del self.env[option]
        self.env['FIXTURE_SWIFT_VERSION']='5.9'
        self.assertIn('requires Swift 6 or newer',self.call(self.launcher,'install-mac','--no-open',okay=False).stderr)
        self.assertEqual(binary.read_bytes(),current)
        del self.env['FIXTURE_SWIFT_VERSION']
        binary.write_text('user edit')
        self.assertIn('modified',self.call(self.launcher,'install-mac','--no-open',okay=False).stderr)
        self.assertEqual(binary.read_text(),'user edit')

    def test_mac_build_failure_keeps_private_log_and_actual_exit(self):
        self.install()
        self.env['FIXTURE_BUILD_FAIL']='1'
        result=self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertEqual(result.returncode,9)
        self.assertIn('fixture compiler error: source did not compile',result.stdout+result.stderr)
        self.assertIn('local Mac app build failed (exit 9)',result.stderr)
        self.assertIn('"$HOME/Library/Application Support/StandMixer/bin/standmixer" install-mac --no-open',result.stderr)
        logs=list((self.support/'InstallLogs').glob('install-mac.*'))
        self.assertEqual(len(logs),1)
        self.assertIn('fixture compiler error: source did not compile',logs[0].read_text())
        self.assertIn('Installer exited with status 9',logs[0].read_text())
        self.assertEqual(logs[0].stat().st_mode & 0o777,0o600)
        self.assertEqual(logs[0].parent.stat().st_mode & 0o777,0o700)
        self.assertFalse((self.support/'.source-install.lock').exists())
        self.assertFalse(self.app.exists())
        del self.env['FIXTURE_BUILD_FAIL']
        self.call(self.launcher,'install-mac','--no-open')
        self.assertTrue(logs[0].is_file())
        self.assertEqual(len(list((self.support/'InstallLogs').glob('install-mac.*'))),2)

    def test_mac_temporary_allocation_failure_releases_only_acquired_lock(self):
        self.install()
        mktemp=self.bin/'mktemp'
        mktemp.write_text('#!/bin/sh\ncase "$*" in *standmixer-install-mac.XXXXXX*) printf "fixture temporary directory denied\\n" >&2; exit 73;; esac\nexec /usr/bin/mktemp "$@"\n')
        mktemp.chmod(0o700)
        result=self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertEqual(result.returncode,73)
        self.assertFalse((self.support/'.source-install.lock').exists())
        logs=list((self.support/'InstallLogs').glob('install-mac.*'))
        self.assertEqual(len(logs),1)
        self.assertIn('fixture temporary directory denied',logs[0].read_text())
        mktemp.unlink()
        self.call(self.launcher,'install-mac','--no-open')
        lock=self.support/'.source-install.lock'
        lock.mkdir()
        before=lock.stat().st_ino
        self.assertIn('Wait for it to finish',self.call(self.launcher,'install-mac','--no-open',okay=False).stderr)
        self.assertEqual(lock.stat().st_ino,before)

    def test_mac_preflight_log_survives_cleanup_and_log_symlinks_are_refused(self):
        self.install()
        self.env['FIXTURE_BAD_SDK']='1'
        result=self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertIn('SwiftUI import failed',result.stderr)
        logs=list((self.support/'InstallLogs').glob('install-mac.*'))
        self.assertEqual(len(logs),1)
        self.assertIn('SDK fixture lacks SwiftUI',logs[0].read_text())
        self.assertFalse((self.support/'.source-install.lock').exists())
        del self.env['FIXTURE_BAD_SDK']
        shutil.rmtree(self.support/'InstallLogs')
        foreign=self.root/'foreign logs';foreign.mkdir()
        (self.support/'InstallLogs').symlink_to(foreign)
        self.assertIn('redirected install path',self.call(self.launcher,'install-mac','--no-open',okay=False).stderr)
        self.assertEqual(list(foreign.iterdir()),[])
        self.assertFalse((self.support/'.source-install.lock').exists())

    def test_compatible_installed_sdk_and_explicit_sdk_pin(self):
        self.install()
        sdks=self.root/'developer SDKs'
        current=sdks/'MacOSX27.0.sdk'; current.mkdir(parents=True)
        compatible=sdks/'MacOSX26.5.sdk'; compatible.mkdir()
        self.env['FIXTURE_SDK']=str(current)
        self.env['FIXTURE_SDK_MACRO_MISSING']='1'
        result=self.call(self.launcher,'install-mac','--no-open')
        self.assertIn(str(compatible),result.stdout)
        app_builds=[x for x in self.calls() if x[:2]==['swift','build']]
        self.assertTrue(all('--sdk' in x and x[x.index('--sdk')+1]==str(compatible) for x in app_builds))
        original=(self.app/'Contents/MacOS/StandMixer').read_bytes()
        self.env['SDKROOT']=str(current)
        result=self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertIn('cannot compile SwiftUI State and bindings',result.stdout+result.stderr)
        self.assertEqual((self.app/'Contents/MacOS/StandMixer').read_bytes(),original)

    def test_app_changes_during_build_are_preserved(self):
        self.install()
        self.env['FIXTURE_APP_APPEARS']='1'
        self.assertIn('appeared at the destination',self.call(self.launcher,'install-mac','--no-open',okay=False).stderr)
        self.assertEqual((self.app/'keep').read_text(),'new user app')
        del self.env['FIXTURE_APP_APPEARS']
        shutil.rmtree(self.app)
        self.call(self.launcher,'install-mac','--no-open')
        binary=self.app/'Contents/MacOS/StandMixer'
        self.env['FIXTURE_RECEIPT_CHANGES']='1'
        self.assertIn('receipt changed during',self.call(self.launcher,'install-mac','--no-open',okay=False).stderr)
        self.assertEqual((self.support/'mac-app.receipt').read_text(),'user receipt edit')
        del self.env['FIXTURE_RECEIPT_CHANGES']
        (self.support/'mac-app.receipt').write_text(str(self.app)+'\n'+hashlib.sha256(binary.read_bytes()).hexdigest()+'\n')
        self.env['FIXTURE_APP_CHANGES']='1'
        self.assertIn('app changed during',self.call(self.launcher,'install-mac','--no-open',okay=False).stderr)
        self.assertEqual(binary.read_text(),'user edit during build')

    def test_release_prefix_maps_and_leak_rejection(self):
        self.install()
        self.call(self.launcher,'install-mac','--no-open')
        resources=self.app/'Contents/Resources'
        self.assertTrue((resources/'StandMixer.icns').is_file())
        self.assertFalse((resources/'StandMixerLight.icns').exists())
        icon_renders=[x for x in self.calls() if x[0]=='swift' and any(part.endswith('/make-icon.swift') for part in x)]
        self.assertEqual({x[-1] for x in icon_renders},{'dark'})
        builds=[x for x in self.calls() if x[:2]==['swift','build']]
        self.assertTrue(builds)
        for command in builds:
            self.assertIn('--build-system',command)
            self.assertEqual(command[command.index('--build-system')+1],'native')
            self.assertIn('-file-prefix-map',command)
            self.assertIn('-debug-prefix-map',command)
            self.assertIn('-no-serialize-debugging-options',command)
            self.assertIn(str(self.home)+'=/home/builder',command)
            self.assertIn(str(self.support/'source')+'=/StandMixer',command)
            self.assertIn('/StandMixer',command)
        strip_calls=[x for x in self.calls() if x[0]=='strip']
        self.assertTrue(strip_calls)
        self.assertTrue(all('-S' in x and '-x' in x for x in strip_calls))
        original=(self.app/'Contents/MacOS/StandMixer').read_bytes()
        self.env['FIXTURE_LEAK_PATH']='1'
        result=self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertIn('still contains a local build path',result.stdout+result.stderr)
        self.assertEqual((self.app/'Contents/MacOS/StandMixer').read_bytes(),original)
        del self.env['FIXTURE_LEAK_PATH']
        self.env['STANDMIXER_BUILD_WORK']=str(self.root/'helper-build')
        self.call(self.source/'dev/build-claude-plugin.sh')
        helper_builds=[x for x in self.calls() if x[:2]==['swift','build'] and '--product' in x and x[x.index('--product')+1]=='StandMixerHelper']
        self.assertTrue(helper_builds)
        for command in helper_builds:
            self.assertIn('--build-system',command)
            self.assertEqual(command[command.index('--build-system')+1],'native')
            self.assertIn('-file-prefix-map',command)
            self.assertIn('-debug-prefix-map',command)
            self.assertIn('-no-serialize-debugging-options',command)
            self.assertIn(str(self.source)+'=/StandMixer',command)
        self.assertTrue(any('--triple' in x and x[x.index('--triple')+1]=='arm64-apple-macosx14.0' for x in helper_builds))
        self.assertTrue(any('--triple' in x and x[x.index('--triple')+1]=='x86_64-apple-macosx14.0' for x in helper_builds))
        self.assertTrue(any(x[0]=='lipo' and '-verify_arch' in x for x in self.calls()))
        calls=self.calls()
        for index, command in enumerate(calls):
            if command[0]=='strip':
                self.assertIn('-S',command)
                self.assertIn('-x',command)
                self.assertTrue(any(x[0]=='codesign' and '--sign' in x for x in calls[index+1:]))
        helper=self.source/'Plugins/claude-standmixer/bin/StandMixerHelper'
        original=helper.read_bytes()
        self.env['FIXTURE_LEAK_PATH']='1'
        self.assertIn('still contains a local build path',self.call(self.source/'dev/build-claude-plugin.sh',okay=False).stderr)
        self.assertEqual(helper.read_bytes(),original)

    def test_helper_build_publishes_fresh_inodes(self):
        self.env['STANDMIXER_BUILD_WORK']=str(self.root/'helper-build')
        (self.source/'dev/build-claude-plugin.sh').chmod(0o755)
        helpers=[self.source/f'Plugins/{platform}-standmixer/bin/StandMixerHelper' for platform in ['claude','codex']]
        before=[helper.stat().st_ino for helper in helpers]
        self.call(self.source/'dev/build-codex-plugin.sh')
        self.assertEqual(helpers[0].read_bytes(),helpers[1].read_bytes())
        self.assertTrue(all(helper.stat().st_ino!=inode for helper,inode in zip(helpers,before)))
        before=[(helper.stat().st_ino,helper.read_bytes()) for helper in helpers]
        self.env['FIXTURE_BUILD_FAIL']='1'
        self.call(self.source/'dev/build-codex-plugin.sh',okay=False)
        self.assertEqual([(helper.stat().st_ino,helper.read_bytes()) for helper in helpers],before)

    def test_source_publish_rollback_and_shared_lock(self):
        self.install()
        installed = self.support/'source/dev/standmixer.sh'
        original = installed.read_bytes()
        (self.source/'dev/standmixer.sh').write_text((self.source/'dev/standmixer.sh').read_text()+'\n# updated checkout\n')
        self.git('add','.')
        self.git('-c','user.name=StandMixer Fixture','-c','user.email=fixture@example.invalid','commit','-qm','update source')
        self.env['FIXTURE_SOURCE_PUBLISH_FAIL']='1'
        self.call(self.source/'install.sh','--no-open',okay=False)
        self.assertEqual(installed.read_bytes(),original)
        del self.env['FIXTURE_SOURCE_PUBLISH_FAIL']
        lock=self.support/'.source-install.lock'; lock.mkdir()
        self.call(self.source/'install.sh','--no-open',okay=False)
        self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertEqual(installed.read_bytes(),original)
        lock.rmdir()
        self.call(self.launcher,'install-mac')
        self.assertTrue(any(x==['open',str(self.app)] for x in self.calls()))

    def test_app_conflicts_and_redirects(self):
        self.install()
        self.app.mkdir(parents=True)
        (self.app/'keep').write_text('preserve')
        self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertEqual((self.app/'keep').read_text(),'preserve')
        shutil.rmtree(self.app)
        outside=self.root/'unrelated app'; outside.mkdir()
        self.app.symlink_to(outside)
        self.call(self.launcher,'install-mac','--no-open',okay=False)
        self.assertEqual(list(outside.iterdir()),[])

class Packages(unittest.TestCase):
    def test_standalone_archives_include_mit_license(self):
        with tempfile.TemporaryDirectory(prefix='standmixer-package-fixture-',dir='/private/tmp') as temporary:
            root=Path(temporary)
            source=root/'source'
            for relative in ['LICENSE','README.md','.claude-plugin/marketplace.json','.agents/plugins/marketplace.json',
                             'dev/package-claude-plugin.sh','dev/package-codex-plugin.sh']:
                target=source/relative
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copyfile(PROJECT/relative,target)
            for platform, archive in [('claude','StandMixer-Claude-plugin.zip'),('codex','StandMixer-Codex-plugin.zip')]:
                plugin=source/f'Plugins/{platform}-standmixer'
                plugin.mkdir(parents=True)
                (plugin/'payload').write_text('standalone plugin fixture\n')
                shipped_license=PROJECT/f'Plugins/{platform}-standmixer/LICENSE'
                self.assertEqual(shipped_license.read_bytes(),(PROJECT/'LICENSE').read_bytes())
                shutil.copyfile(shipped_license,plugin/'LICENSE')
                subprocess.run(['/bin/sh',str(source/f'dev/package-{platform}-plugin.sh'),'--skip-build'],check=True,capture_output=True,timeout=30)
                with zipfile.ZipFile(root/archive) as packaged:
                    names=packaged.namelist()
                    licenses=[name for name in names if name.count('/')==1 and name.endswith('/LICENSE')]
                    self.assertEqual(len(licenses),1,names)
                    self.assertEqual(packaged.read(licenses[0]),(PROJECT/'LICENSE').read_bytes())
                    plugin_license=next(name for name in names if name.endswith(f'/Plugins/{platform}-standmixer/LICENSE'))
                    self.assertEqual(packaged.read(plugin_license),(PROJECT/'LICENSE').read_bytes())
                    self.assertTrue(any(name.endswith(f'/Plugins/{platform}-standmixer/payload') for name in names))


if __name__ == '__main__': unittest.main(verbosity=2)
