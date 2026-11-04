import { expect, test } from 'claude-code/testing';
import { state, preview, pane } from './fixtures.js';
import { reviewPages } from '../hooks/register.js';
import { recipeKey, matchedPreset, modelIdentity, routeKey } from '../hooks/presentation.js';

function harness(on, initial = state(), reviewed = preview(), placements = [true], inspectionGate = null, installGate = null, accountResult = null) {
  const calls = []; const registeredCommands = []; const openedURLs = []; let openingURL = 'http://127.0.0.1:54321/#token=' + 'a'.repeat(43);
  const updateCalls = []; let updateResult = { exitCode: 0, stdout: 'Updated fixture.', stderr: '' };
  let saveFailure = null;
  const saved = new Map();
  let opens = 0;
  const openOptions = [];
  on('session.start', () => ({ cwd: '/fixture' }));
  on('session.attach', ($, e) => ({ clientId: e.clientId }));
  on('command.register', ($, e) => { registeredCommands.push(e.name); return { value: undefined }; });
  on('store.get', ($, e) => ({ value: saved.get(e.key) }));
  on('store.set', ($, e) => { saved.set(e.key, e.value); return { value: undefined }; });
  on('ui.open', ($, e) => { opens++; openOptions.push(e); return { value: { isPlaced: placements[Math.min(opens - 1, placements.length - 1)] } }; });
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['Host prompt band'] }));
  on('ui.close', () => ({ value: undefined }));
  on('ui.toast', () => ({ value: undefined }));
  on('process.run', async ($, e) => {
    if (e.argv[0] === '/bin/sh' && e.argv[1] === '-c') {
      expect(e.argv.slice(0,4)).toEqual(['/bin/sh','-c','exec "$HOME/Library/Application Support/AgentMix/bin/standmixer" update "$@"','standmixer-update']);
      expect(e.init.timeoutMs).toBe(600000);updateCalls.push(e.argv);return { value: updateResult };
    }
    if (e.argv[0] === '/usr/bin/open') { openedURLs.push(e.argv[1]); return { value: { exitCode: 0, stdout: '', stderr: '' } }; }
    if (e.argv[0] === '/bin/sh') return { value: { exitCode: 0, stdout: '/fixture/AgentMixHelper\n', stderr: '' } };
    expect(e.argv).toEqual(['/fixture/AgentMixHelper']);
    const request = JSON.parse(e.init.stdin);
    calls.push(request);
    if (request.action === 'openWeb') return { value: { exitCode: 0, stdout: JSON.stringify({ok: true, web: {url: openingURL}}), stderr: '' } };
    if (request.action === 'openMac') return { value: { exitCode: 0, stdout: JSON.stringify({ok: true, result: {message: 'Mac app opened.'}}), stderr: '' } };
    if (request.action === 'saveDraft' && saveFailure) return { value: { exitCode: 1, stdout: JSON.stringify({ ok: false, error: { message: saveFailure } }), stderr: '' } };
    if (request.action === 'checkAccounts') {
      expect(e.init.timeoutMs).toBe(30000);
      return { value: { exitCode: 0, stdout: JSON.stringify(accountResult || { ok: true, accounts: { checkedAt: '2026-11-03T12:00:00Z', providers: [{ platform: 'claude', status: 'unknown', detail: 'Identity not exposed.' }] } }), stderr: '' } };
    }
    if (request.action === 'installMac') {
      expect(e.init.timeoutMs).toBe(600000);
      if (installGate) {
        installGate.signalStarted();
        return { value: { exitCode: 0, stdout: JSON.stringify(await installGate.result), stderr: '' } };
      }
      return { value: { exitCode: 0, stdout: JSON.stringify({ ok: true, result: { message: 'Mac app built locally.', changedFiles: 0, notes: [] } }), stderr: '' } };
    }
    if (request.action === 'inspect' && inspectionGate) {
      expect(e.init.timeoutMs).toBe(120000);
      inspectionGate.signalStarted();
      return { value: { exitCode: 0, stdout: JSON.stringify(await inspectionGate.result), stderr: '' } };
    }
    let response;
    if (request.action === 'savePreset') {
      const existing = initial.savedPresets.find(preset => preset.name.toLowerCase() === request.name.toLowerCase());
      const savedPreset = { id: existing?.id || '00000000-0000-4000-8000-000000000001', name: request.name,
        configuration: { ...request.configuration, enabledPlatforms: request.platforms } };
      initial.savedPresets = [...initial.savedPresets.filter(preset => preset.id !== savedPreset.id), savedPreset];
      response = { ok: true, state: initial, result: { message: 'Preset saved' } };
    } else if (request.action === 'deletePreset') {
      initial.savedPresets = initial.savedPresets.filter(preset => preset.id !== request.presetID);
      response = { ok: true, state: initial, result: { message: 'Preset deleted' } };
    } else if (request.action === 'saveDraft') {
      initial.previousDraft = initial.configuration;
      initial.configuration = { ...request.configuration, enabledPlatforms: request.platforms };
      initial.hasSavedDraft = true;
      response = { ok: true, state: initial, result: { message: 'Draft saved' } };
    } else if (request.action === 'inspect') {
      expect(e.init.timeoutMs).toBe(120000);
      initial.inspection = { createdAt: '2026-11-02T00:00:00Z', expiresAt: '2026-11-02T00:15:00Z', reports: [], fromCache: false };
      response = { ok: true, inspection: initial.inspection };
    } else response = request.action === 'state' ? { ok: true, state: request.platforms ? { ...initial, enabledPlatforms: request.platforms, presets: state(request.platforms).presets } : initial }
      : request.action.startsWith('preview') ? { ok: true, preview: reviewed }
      : { ok: true, result: { message: 'Applied exactly the reviewed changes.', changedFiles: 1, notes: [] } };
    return { value: { exitCode: 0, stdout: JSON.stringify(response), stderr: '' } };
  });
  // A regression that initiates inference or a prompt fails immediately.
  on('model.complete', () => { throw new Error('Unexpected inference'); });
  on('prompt.submit', () => { throw new Error('Unexpected prompt submission'); });
  return { calls, registeredCommands, openedURLs, updateCalls, setUpdateResult: value => { updateResult = value; }, setOpeningURL: value => { openingURL = value; }, setSaveFailure: value => { saveFailure = value; }, saved, opens: () => opens, openOptions };
}

test('explicit update uses only the fixed launcher and never opens or applies settings', async ($, on) => {
  const fixture=harness(on);
  await $.command.run({command:'standmixer',args:'update'});
  expect(fixture.updateCalls[0]).toHaveLength(4);
  expect(fixture.calls).toEqual([]);expect(fixture.opens()).toBe(0);
  await $.command.run({command:'standmixer',args:'update --mac'});
  expect(fixture.updateCalls[1].slice(4)).toEqual(['--mac']);
  expect(fixture.calls).toEqual([]);
});

test('update rejects extra arguments and preserves an in-progress edit', async ($, on) => {
  const fixture=harness(on);
  for(const args of ['update --yes','update --mac extra','update https://example.invalid'])await $.command.run({command:'standmixer',args});
  expect(fixture.updateCalls).toEqual([]);
  await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  await ui.press({key:'edit'});await ui.select({key:'codex-implementation-member-0-model',value:'gpt-6-astra'});
  await $.command.run({command:'standmixer',args:'update'});
  expect((await ui.find({key:'codex-implementation-member-0-model'})).props.value).toBe('gpt-6-astra');
  expect(await ui.find({key:'save-edit'})).toBeDefined();expect(fixture.calls.map(x=>x.action)).toEqual(['state']);
});

test('update surfaces failure instead of claiming success or applying defaults', async ($, on) => {
  const fixture=harness(on);fixture.setUpdateResult({exitCode:37,stdout:'',stderr:'Network unavailable'});
  await $.command.run({command:'standmixer',args:'update'});const ui=await $.ui.mount({...pane,surface:'desktop'});
  expect(await ui.find({type:'Text',text:'StandMixer update did not complete.\nNetwork unavailable'})).toBeDefined();
  expect(fixture.calls).toEqual([]);expect(fixture.updateCalls).toHaveLength(1);
});

async function saveAndReview(ui) {
  if (await ui.find({ key: 'save-edit' })) await ui.press({ key: 'save-edit' });
  await ui.press({ key: 'review' });
}

test('first interactive load opens once and never applies settings', async ($, on) => {
  const fixture = harness(on);
  await $.session.start({ cwd: '/fixture', surface: 'terminal', isInteractive: true });
  expect(fixture.opens()).toBe(1);
  expect(fixture.openOptions[0].focus).toBe(true);
  expect(fixture.calls.map(call => call.action)).toEqual(['state']);
  expect(fixture.saved.get('settings-opened-v1')).toBe(true);
  await $.session.start({ cwd: '/fixture', surface: 'terminal', isInteractive: true });
  expect(fixture.opens()).toBe(1);
  const ui = await $.ui.mount({ ...pane, surface: 'terminal' });
  expect(await ui.find({ type: 'Text', text: 'No preset applied' })).toBeDefined();
  expect(await ui.find({ key: 'apply-reviewed' })).toBeUndefined();
});

test('early unplaced onboarding retries once when the main prompt has a wide measured viewport', async ($, on) => {
  const fixture = harness(on, state(), preview(), [false, true]);
  await $.session.start({ cwd: '/fixture', surface: 'terminal', isInteractive: true });
  expect(fixture.opens()).toBe(1);
  expect(fixture.saved.get('settings-opened-v1')).toBeUndefined();
  const band = { ...pane, component: 'AbovePrompt', requestId: 'main-band', surface: 'terminal',
    props: { bodyColumns: 160, maxRows: 8, hasSurvey: false, isWorking: false, scroll: { offset: 0, bodyRows: 8 }, view: {} } } as const;
  const ui = await $.ui.mount(band);
  expect(fixture.opens()).toBe(2);
  expect(fixture.saved.get('settings-opened-v1')).toBe(true);
  expect(await ui.find({ type: 'Text', text: 'Host prompt band' })).toBeDefined();
  expect(await ui.find({ key: 'open-agentmix' })).toBeUndefined();
  await ui.unmount();
  await $.ui.mount(band);
  expect(fixture.opens()).toBe(2);
  expect(fixture.calls.map(call => call.action)).toEqual(['state']);
});

test('narrow terminals offer a direct Open button without repeatedly trying automatic placement', async ($, on) => {
  const fixture = harness(on, state(), preview(), [false, true]);
  await $.session.start({ cwd: '/fixture', surface: 'terminal', isInteractive: true });
  const band = { ...pane, component: 'AbovePrompt', requestId: 'main-band', surface: 'terminal',
    viewport: { columns: 140, rows: 56 },
    props: { bodyColumns: 140, maxRows: 8, hasSurvey: false, isWorking: false, scroll: { offset: 0, bodyRows: 8 }, view: {} } } as const;
  const ui = await $.ui.mount(band);
  expect(fixture.opens()).toBe(1);
  expect(await ui.find({ type: 'Text', text: 'Host prompt band' })).toBeDefined();
  expect(await ui.find({ key: 'open-agentmix' })).toBeDefined();
  await ui.press({ key: 'open-agentmix' });
  expect(fixture.opens()).toBe(2);
  expect(fixture.saved.get('settings-opened-v1')).toBe(true);
  expect(await ui.find({ key: 'open-agentmix' })).toBeUndefined();
});

test('a readiness retry that is still unplaced is bounded and leaves the Open button', async ($, on) => {
  const fixture = harness(on, state(), preview(), [false]);
  await $.session.start({ cwd: '/fixture', surface: 'terminal', isInteractive: true });
  const band = { ...pane, component: 'AbovePrompt', requestId: 'main-band', surface: 'terminal',
    props: { bodyColumns: 160, maxRows: 8, hasSurvey: false, isWorking: false, scroll: { offset: 0, bodyRows: 8 }, view: {} } } as const;
  const ui = await $.ui.mount(band);
  expect(fixture.opens()).toBe(2);
  expect(await ui.find({ key: 'open-agentmix' })).toBeDefined();
  await ui.unmount();
  await $.ui.mount(band);
  expect(fixture.opens()).toBe(2);
  expect(fixture.saved.get('settings-opened-v1')).toBeUndefined();
});

test('headless startup registers only; explicit command opens without a model turn', async ($, on) => {
  const fixture = harness(on);
  await $.session.start({ cwd: '/fixture', surface: null, isInteractive: false });
  expect(fixture.calls.length).toBe(0);
  expect(fixture.opens()).toBe(0);
  expect(fixture.registeredCommands).toEqual(['standmixer']);
  expect(await $.command.run({ command: 'standmixer', args: '' })).toEqual({});
  expect(fixture.calls.map(call => call.action)).toEqual(['state']);
});

test('the uninstall argument opens the removal review without mutating settings', async ($, on) => {
  const current = state();
  current.installation.hasInstallation = true;
  const fixture = harness(on, current, preview(2, 'uninstall'));
  await $.command.run({ command: 'standmixer', args: 'uninstall --yes' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'previewUninstall']);
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ type: 'Text', text: 'Remove StandMixer settings' })).toBeDefined();
  expect(await ui.find({ key: 'apply-reviewed' })).toBeDefined();
  expect(fixture.calls.some(call => call.action === 'uninstall')).toBe(false);
});

test('preset and restore arguments prepare reviews and never apply automatically', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: 'high' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'preview']);
  expect(fixture.calls[1].configuration).toEqual(state().presets.find(preset => preset.id === 'high').configuration);
  await $.command.run({ command: 'standmixer', args: 'restore' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'preview', 'state', 'previewRestore']);
});

test('native command help answers directly without opening a pane or invoking a helper', async ($, on) => {
  const fixture = harness(on);
  const answer = await $.command.run({ command: 'standmixer', args: 'help' });
  expect(answer.text).toContain('uninstall to review removal');
  expect(fixture.opens()).toBe(0);
  expect(fixture.calls).toEqual([]);
});

test('Desktop attaching to a headless session gets first-open onboarding once', async ($, on) => {
  const fixture = harness(on);
  await $.session.start({ cwd: '/fixture', surface: null, isInteractive: false });
  await $.session.attach({ surface: 'desktop', clientId: 'desktop-fixture' });
  expect(fixture.opens()).toBe(1);
  await $.session.attach({ surface: 'desktop', clientId: 'desktop-fixture-2' });
  expect(fixture.opens()).toBe(1);
  expect(fixture.calls.map(call => call.action)).toEqual(['state']);
});

test('native controls and complete three-worker teams render in terminal, Desktop, and VS Code', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  for (const surface of ['terminal', 'desktop', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...pane, surface });
    await ui.press({ key: 'preset-high' });
    expect(await ui.find({ type: 'Button', key: 'preset-high', text: /High/ })).toBeDefined();
    expect(await ui.find({ type: 'Text', text: 'Fable 5.1' })).toBeDefined();
    await ui.press({ key: 'edit' });
    expect(await ui.find({ key: 'codex-ui-member-2-model' })).toBeDefined();
    expect(await ui.find({ key: 'edit-task' })).toBeUndefined();
    expect(await ui.find({ key: 'codex-coordinator-add-worker' })).toBeUndefined();
    const coordinator = await ui.find({ key: 'codex-coordinator-member-0-model' });
    expect(coordinator.props.options.some(option => option.value === 'claude-opus-5-5')).toBe(false);
    await ui.press({ key: 'cancel-edit' });
    await ui.unmount();
  }
  expect(fixture.calls.map(call => call.action)).toEqual(['state']);
});

test('compact review offers Apply immediately and full diff pages remain available', async ($, on) => {
  const fixture = harness(on, state(), preview(80));
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await saveAndReview(ui);
  expect(await ui.find({ key: 'apply-reviewed' })).toBeDefined();
  await ui.press({ key: 'show-diff' });
  expect(await ui.find({ type: 'Code' })).toBeDefined();
  let pages = 1;
  while (await ui.find({ key: 'review-next' })) {
    await ui.press({ key: 'review-next' }); pages++;
  }
  expect(pages).toBe(4);
  expect(await ui.find({ key: 'apply-reviewed' })).toBeDefined();
  await ui.press({ key: 'apply-reviewed' });
  expect(fixture.calls.find(call => call.action === 'apply')).toEqual({ action: 'apply', previewID: 'reviewed-exact-id' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'preview', 'apply', 'state']);
});

test('advanced edits stay local and returning from review discards its apply token', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'terminal' });
  await ui.press({ key: 'edit' });
  await ui.select({ key: 'codex-ui-member-0-model', value: 'gpt-6-astra' });
  await ui.press({ key: 'codex-ui-add-worker' });
  await ui.select({ key: 'codex-ui-member-1-model', value: 'claude-fable-5-1' });
  await ui.select({ key: 'codex-ui-member-1-effort', value: 'fixed' });
  await ui.select({ key: 'codex-ui-member-1-level', value: 'max' });
  expect(fixture.calls.length).toBe(1);
  await saveAndReview(ui);
  const route = fixture.calls[1].configuration.profiles[0].routes.find(route => route.category === 'ui');
  expect(route.modelID).toBe('gpt-6-astra');
  expect(route.additionalAgents[0].effort.value).toBe('max');
  await ui.press({ key: 'review-back' });
  expect(await ui.find({ key: 'apply-reviewed' })).toBeUndefined();
});

test('disabling a provider adapts the selected factory preset before direct Review', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'preset-high' });
  await ui.press({ key: 'edit' });
  await ui.press({ key: 'more' });
  await ui.press({ key: 'provider-codex' });
  expect(fixture.calls[1]).toEqual({ action: 'state', platforms: ['claude'] });
  expect(await ui.find({ type: 'Button', key: 'preset-high', text: /High/ })).toBeDefined();
  await saveAndReview(ui);
  expect(fixture.calls[2].platforms).toEqual(['claude']);
  expect(fixture.calls[2].configuration).toEqual(state(['claude']).presets.find(preset => preset.id === 'high').configuration);
});

test('custom assignments survive toggles, show unavailable models, and block Review until repaired', async ($, on) => {
  const current = state();
  current.hasSavedDraft = true;
  current.configuration.profiles[1].routes.find(route => route.category === 'review').modelID = 'claude-haiku-5-5';
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'edit' });
  await ui.press({ key: 'more' });
  await ui.press({ key: 'provider-codex' });
  const picker = await ui.find({ key: 'claude-implementation-member-0-model' });
  expect(picker.props.value).toBe('gpt-6.1-sol');
  expect(picker.props.options.find(option => option.value === 'gpt-6.1-sol').label).toContain('unavailable');
  expect(picker.props.options.some(option => option.value === 'gpt-6-astra')).toBe(false);
  await saveAndReview(ui);
  expect(await ui.find({ type: 'Text', text: /Some assignments use a disabled provider/ })).toBeDefined();
  expect(await ui.find({ key: 'apply-reviewed' })).toBeUndefined();
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'state', 'saveDraft']);
  await ui.press({ key: 'edit' });
  await ui.select({ key: 'claude-implementation-member-0-model', value: 'claude-fable-5-1' });
  await ui.press({ key: 'claude-implementation-add-worker' });
  await ui.select({ key: 'claude-implementation-result-mode', value: 'ai' });
  const judges = await ui.find({ key: 'claude-implementation-judge-model' });
  expect(judges.props.options.some(option => option.value.startsWith('gpt-'))).toBe(false);
  await saveAndReview(ui);
  expect(fixture.calls.at(-1).action).toBe('preview');
});

test('Advanced matches the core limit of three additional workers', async ($, on) => {
  harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'preset-high' });
  await ui.press({ key: 'edit' });
  await ui.press({ key: 'codex-ui-add-worker' });
  expect(await ui.find({ key: 'codex-ui-member-3-model' })).toBeDefined();
  expect(await ui.find({ key: 'codex-ui-add-worker' })).toBeUndefined();
  await ui.press({ key: 'codex-ui-member-3-remove' });
  expect(await ui.find({ key: 'codex-ui-add-worker' })).toBeDefined();
});

test('restore and removal remain inside More and review before changing files', async ($, on) => {
  const current = state();
  current.canRestore = true;
  current.installation.hasInstallation = true;
  const fixture = harness(on, current, preview(2, 'restore'));
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ key: 'restore' })).toBeUndefined();
  expect(await ui.find({ key: 'uninstall' })).toBeUndefined();
  await ui.press({ key: 'more' });
  expect(await ui.find({ key: 'uninstall' })).toBeDefined();
  await ui.press({ key: 'restore' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'previewRestore']);
  await ui.press({ key: 'apply-reviewed' });
  expect(fixture.calls[2]).toEqual({ action: 'restore', previewID: 'reviewed-exact-id' });
});

test('the process truncation flag produces an actionable error, without Apply', async ($, on) => {
  on('ui.open', () => ({ value: { isPlaced: true } }));
  on('store.set', () => ({ value: undefined }));
  on('process.run', ($, e) => ({ value: e.argv[0] === '/bin/sh'
    ? { exitCode: 0, stdout: '/fixture/AgentMixHelper\n', stderr: '' }
    : { exitCode: 0, stdout: '{', stderr: '', isStdoutTruncated: true } }));
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'terminal' });
  expect(await ui.find({ type: 'Text', text: /4 MiB limit/ })).toBeDefined();
  expect(await ui.find({ key: 'apply-reviewed' })).toBeUndefined();
});

test('helper errors are visible and never expose an Apply control', async ($, on) => {
  on('ui.open', () => ({ value: { isPlaced: true } }));
  on('store.set', () => ({ value: undefined }));
  on('process.run', ($, e) => ({ value: { exitCode: e.argv[0] === '/bin/sh' ? 0 : 1,
    stdout: e.argv[0] === '/bin/sh' ? '/fixture/AgentMixHelper\n' : JSON.stringify({ ok: false, error: { code: 'conflict', message: 'Settings changed since review.' } }), stderr: '' } }));
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'terminal' });
  expect(await ui.find({ type: 'Text', text: 'Settings changed since review.' })).toBeDefined();
  expect(await ui.find({ key: 'retry' })).toBeDefined();
  expect(await ui.find({ key: 'apply-reviewed' })).toBeUndefined();
});

test('long lines are retained across bounded review pages', () => {
  const sample = preview();
  sample.changes[0].diff.hunks[0].lines = [{ kind: 'addition', text: 'x'.repeat(220000) }];
  const pages = reviewPages(sample);
  expect(pages.length > 10).toBe(true);
  expect(pages.every(page => page.source.length < 17000)).toBe(true);
  expect(pages.map(page => page.source).join('').match(/x/g).length).toBe(220000);
});

test('persisted recipes select the matching factory card without claiming they are applied', async ($, on) => {
  const current = state();
  current.hasSavedDraft = true;
  current.configuration = current.presets.find(preset => preset.id === 'high').configuration;
  for (const profile of current.configuration.profiles) for (const route of profile.routes) for (const worker of route.additionalAgents) worker.id = 'different-identity';
  harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect((await ui.find({ key: 'preset-high' })).props.label).toBe('✓ High');
  expect((await ui.find({ key: 'preset-fast' })).props.label).toBe('Fast');
  expect(await ui.find({ type: 'Text', text: 'No preset applied' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: /Saved draft/ })).toBeUndefined();
  expect(await ui.find({ type: 'Text', text: 'Changed' })).toBeUndefined();
  expect((await ui.findAll({ type: 'Svg' })).length > 7).toBe(true);
});

test('model family levels match Mac identities and unknown custom models remain unrated', () => {
  const ratings = [['luna', 'codex', 1], ['haiku', 'claude', 1], ['terra', 'codex', 2], ['sonnet', 'claude', 2], ['sol', 'codex', 3], ['astra', 'codex', 4], ['opus', 'claude', 4]];
  for (const [id, platform, level] of ratings) expect(modelIdentity({ id, platform }).level).toBe(level);
  expect(modelIdentity({ id: 'claude-fable-5-1', platform: 'claude' }).level).toBe(4);
  expect(modelIdentity({ id: 'claude-fable-9', platform: 'claude' }).level).toBe(0);
  expect(modelIdentity({ id: 'custom-sol-powered', label: 'My Sol experiment', platform: 'codex' }).level).toBe(0);
  expect(modelIdentity({ id: 'gpt-6.1-sol', platform: 'claude' }).level).toBe(0);
});

test('recipe matching ignores inert UUID and Auto fields but preserves team order and result handling', () => {
  const current = state();
  const configuration = JSON.parse(JSON.stringify(current.presets[2].configuration));
  const route = configuration.profiles[0].routes.find(route => route.category === 'ui');
  route.additionalAgents[0].id = 'new-id';
  route.effort.value = 'ultra';
  expect(matchedPreset(configuration, ['claude', 'codex'], current.presets)).toBe('high');
  const before = routeKey(route);
  route.additionalAgents.reverse();
  expect(routeKey(route) === before).toBe(false);
  route.additionalAgents.reverse();
  route.resultMode = 'user';
  expect(recipeKey(configuration, ['codex', 'claude']) === recipeKey(current.presets[2].configuration, ['codex', 'claude'])).toBe(false);
});

test('verified current routes show changed details and a separate applied preset', async ($, on) => {
  const current = state();
  current.installation = { state: 'applied', summary: 'Applied', hasInstallation: true, installedPlatforms: ['codex', 'claude'], appliedConfiguration: current.configuration };
  harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ type: 'Text', text: 'Applied · Optimized' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'Changed' })).toBeUndefined();
  await ui.press({ key: 'preset-high' });
  expect((await ui.find({ key: 'current-codex-ui' })).props.label).toBe('Changed ▾');
  expect(await ui.find({ type: 'Text', text: 'Applied · Optimized' })).toBeDefined();
  await ui.press({ key: 'current-codex-ui' });
  expect(await ui.find({ type: 'Text', text: 'Verified StandMixer settings' })).toBeDefined();
  await saveAndReview(ui);
  expect(await ui.find({ type: 'Text', text: /Current: Sol/ })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: /To: Sol.*Astra.*Fable/ })).toBeDefined();
  expect(await ui.find({ key: 'apply-reviewed' })).toBeDefined();
});

test('drifted receipt cannot stand in for current worker truth', async ($, on) => {
  const current = state();
  current.installation = { state: 'drifted', summary: 'External changes', hasInstallation: true, installedPlatforms: ['codex', 'claude'], appliedConfiguration: current.configuration };
  current.nativeSettings = [{ platform: 'codex', sourcePath: '/fixture/.codex/config.toml', status: 'known', modelID: 'gpt-6-luna', effort: 'low', detail: 'Saved global default' }];
  harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'preset-high' });
  expect(await ui.find({ type: 'Text', text: 'Settings changed outside StandMixer' })).toBeDefined();
  expect(await ui.find({ key: 'current-codex-ui' })).toBeUndefined();
  expect(await ui.find({ key: 'current-codex-coordinator' })).toBeUndefined();
  await ui.press({ key: 'more' });
  expect(await ui.find({ type: 'Text', text: 'Saved global default: gpt-6-luna · Low' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: '/fixture/.codex/config.toml' })).toBeDefined();
});

test('saved presets retain the local draft and delete requires its concrete confirmation', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'preset-high' });
  await ui.press({ key: 'save-preset' });
  await ui.input({ key: 'preset-name', text: 'My high team', kind: 'change' });
  await ui.press({ key: 'confirm-save-preset' });
  expect(fixture.calls[1].action).toBe('savePreset');
  expect(fixture.calls[1].name).toBe('My high team');
  expect((await ui.find({ key: 'preset-high' })).props.label).toBe('✓ High');
  expect((await ui.find({ key: 'saved-presets' })).props.value).toBe('00000000-0000-4000-8000-000000000001');
  await ui.press({ key: 'delete-preset' });
  expect(fixture.calls.length).toBe(2);
  await ui.press({ key: 'cancel-delete-preset' });
  expect(fixture.calls.length).toBe(2);
  await ui.press({ key: 'delete-preset' });
  await ui.press({ key: 'confirm-delete-preset' });
  expect(fixture.calls[2]).toEqual({ action: 'deletePreset', presetID: '00000000-0000-4000-8000-000000000001' });
  expect((await ui.find({ key: 'preset-high' })).props.label).toBe('✓ High');
  expect(await ui.find({ key: 'saved-presets' })).toBeUndefined();
  expect(fixture.calls.some(call => call.action === 'apply')).toBe(false);
});

test('save draft exposes previous draft without applying either recipe', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'preset-high' });
  await ui.press({ key: 'edit' });
  await ui.press({ key: 'save-edit' });
  expect(fixture.calls[1].action).toBe('saveDraft');
  expect((await ui.find({ key: 'preset-high' })).props.label).toBe('✓ High');
  await ui.press({ key: 'previous-draft' });
  expect((await ui.find({ key: 'preset-optimized' })).props.label).toBe('✓ Optimized');
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'saveDraft']);
});

test('custom models use explicit provider, native coordinators, and supported efforts', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'edit' });
  await ui.press({ key: 'custom-models' });
  await ui.input({ key: 'custom-model-id', text: 'private-codex-model', kind: 'change' });
  await ui.input({ key: 'custom-model-label', text: 'Private model', kind: 'change' });
  await ui.press({ key: 'add-custom-model' });
  expect((await ui.find({ key: 'codex-coordinator-member-0-model' })).props.options.some(option => option.value === 'private-codex-model')).toBe(true);
  await ui.select({ key: 'codex-coordinator-member-0-model', value: 'private-codex-model' });
  await ui.select({ key: 'codex-coordinator-member-0-effort', value: 'fixed' });
  expect((await ui.find({ key: 'codex-coordinator-member-0-level' })).props.options.map(option => option.value)).toEqual(['low', 'medium', 'high']);
  expect(await ui.find({ key: 'remove-custom-private-codex-model' })).toBeUndefined();
  expect((await ui.find({ key: 'claude-coordinator-member-0-model' })).props.options.some(option => option.value === 'private-codex-model')).toBe(false);
  await saveAndReview(ui);
  expect(fixture.calls[1].configuration.customModels[0].platform).toBe('codex');
  expect(fixture.calls[1].configuration.customModels[0].supportedEfforts).toEqual(['low', 'medium', 'high']);
});

test('removing an unused saved custom model removes it from the draft catalog', async ($, on) => {
  const current = state();
  const model = { id: 'private-unused', label: 'Unused model', platform: 'codex', supportedEfforts: ['low'], isDiscovered: false };
  current.configuration.customModels = [model]; current.catalog = [...current.catalog, model];
  harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'edit' });
  await ui.press({ key: 'custom-models' });
  await ui.press({ key: 'remove-custom-private-unused' });
  expect((await ui.find({ key: 'codex-coordinator-member-0-model' })).props.options.some(option => option.value === 'private-unused')).toBe(false);
});

test('narrow native panes keep both providers and every task editable inline', async ($, on) => {
  harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  for (const surface of ['terminal', 'desktop', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...pane, surface, props: { ...pane.props, bodyColumns: 42 } });
    await ui.press({ key: 'preset-high' });
    await ui.press({ key: 'edit' });
    expect(await ui.find({ key: 'row-coordinator' })).toBeDefined();
    expect(await ui.find({ key: 'row-mechanical' })).toBeDefined();
    expect(await ui.find({ key: 'claude-ui-member-2-model' })).toBeDefined();
    expect(await ui.find({ key: 'edit-task' })).toBeUndefined();
    if (surface === 'terminal') expect(await ui.find({ type: 'Svg' })).toBeUndefined();
    await ui.press({ key: 'cancel-edit' });
    await ui.unmount();
  }
});

test('preference inspection is cached, bounded, and only manually refreshed', async ($, on) => {
  const current = state();
  delete current.inspection;
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state']);
  await $.command.run({ command: 'standmixer', args: '' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'state']);
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'more' });
  await ui.press({ key: 'refresh-preferences' });
  expect(fixture.calls[2]).toEqual({ action: 'inspect', platforms: ['codex', 'claude'], refresh: true });
});

test('observed usual preferences expose evidence without becoming current truth or changing the draft', async ($, on) => {
  const current = state();
  current.inspection.reports = [{ platform: 'codex', status: 'partial', summary: 'Found a usual Visual preference',
    routes: [{ category: 'ui', modelID: 'gpt-6-luna', scope: 'usual', evidence: [{ path: '/fixture/AGENTS.md', explanation: 'Visual preference' }], uncertainties: ['Effort unspecified'] }], notes: [], sources: [{ path: '/fixture/AGENTS.md' }] }];
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ key: 'current-codex-ui' })).toBeUndefined();
  expect(await ui.find({ type: 'Text', text: 'Changed' })).toBeUndefined();
  await ui.press({ key: 'more' });
  expect(await ui.find({ type: 'Text', text: /fixture\/AGENTS.md/ })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'Effort unspecified' })).toBeDefined();
  await saveAndReview(ui);
  expect(fixture.calls[1].configuration.profiles[0].routes.find(route => route.category === 'ui').modelID).toBe('gpt-6.1-sol');
});

test('loading a saved provider subset refreshes factory matches without replacing its recipe', async ($, on) => {
  const current = state();
  const saved = state(['claude']).presets.find(preset => preset.id === 'high').configuration;
  current.savedPresets = [{ id: '00000000-0000-4000-8000-000000000007', name: 'Claude team', configuration: saved }];
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.select({ key: 'saved-presets', value: current.savedPresets[0].id });
  expect(fixture.calls[1]).toEqual({ action: 'state', platforms: ['claude'] });
  expect((await ui.find({ key: 'preset-high' })).props.label).toBe('✓ High');
  await saveAndReview(ui);
  expect(fixture.calls[2].configuration).toEqual(saved);
  expect(fixture.calls[2].platforms).toEqual(['claude']);
});

test('an obsolete effort is visible and repairable instead of silently changed on render', async ($, on) => {
  const current = state();
  current.configuration.profiles[1].routes[0].modelID = 'claude-opus-5-5';
  current.configuration.profiles[1].routes[0].effort = { mode: 'fixed', value: 'max', minimum: 'low', maximum: 'high' };
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'edit' });
  const picker = await ui.find({ key: 'claude-coordinator-member-0-level' });
  expect(picker.props.value).toBe('max');
  expect(picker.props.options.find(option => option.value === 'max').label).toBe('Max · unsupported');
  await ui.select({ key: 'claude-coordinator-member-0-level', value: 'high' });
  await saveAndReview(ui);
  expect(fixture.calls[1].configuration.profiles[1].routes[0].effort.value).toBe('high');
});

function deferredInspection() {
  const gate = {};
  gate.started = new Promise(resolve => { gate.signalStarted = resolve; });
  gate.result = new Promise(resolve => { gate.finish = resolve; });
  return gate;
}
function delayedInspectionResult() {
  return { ok: true, inspection: { createdAt: '2026-11-02T00:00:00Z', expiresAt: '2026-11-02T01:00:00Z', fromCache: false,
    reports: [{ platform: 'claude', status: 'complete', summary: 'Delayed old preference', routes: [{ category: 'ui', modelID: 'claude-haiku-5-5', scope: 'usual', evidence: [{ path: '/fixture/old-AGENTS.md', explanation: 'Old preference' }], uncertainties: [] }], notes: [], sources: [{ path: '/fixture/old-AGENTS.md' }] }] } };
}

test('inspection keeps presets, inline editing, review, and Apply usable while pending', async ($, on) => {
  const current = state(); delete current.inspection;
  const gate = deferredInspection(), fixture = harness(on, current, preview(), [true], gate);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'more' });
  const opening = ui.press({ key: 'refresh-preferences' });
  await gate.started;
  expect(await ui.find({ type: 'Text', text: 'Reading current preferences…' })).toBeDefined();
  expect(await ui.find({ key: 'review' })).toBeDefined();
  await ui.press({ key: 'preset-high' });
  await ui.press({ key: 'edit' });
  await ui.select({ key: 'codex-ui-member-0-model', value: 'gpt-6-astra' });
  await saveAndReview(ui);
  expect(fixture.calls[2].configuration.profiles[0].routes.find(route => route.category === 'ui').modelID).toBe('gpt-6-astra');
  expect(await ui.find({ key: 'apply-reviewed' })).toBeDefined();
  await ui.press({ key: 'apply-reviewed' });
  expect(fixture.calls.find(call => call.action === 'apply')).toEqual({ action: 'apply', previewID: 'reviewed-exact-id' });
  gate.finish(delayedInspectionResult());
  await opening;
  await ui.press({ key: 'more' });
  expect(await ui.find({ type: 'Text', text: 'Delayed old preference' })).toBeUndefined();
  expect(await ui.find({ type: 'Text', text: 'Reading current preferences…' })).toBeUndefined();
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'inspect', 'saveDraft', 'preview', 'apply', 'state']);
});

test('late inspection after a provider change is discarded without touching its adapted draft', async ($, on) => {
  const current = state(); delete current.inspection;
  const gate = deferredInspection(), fixture = harness(on, current, preview(), [true], gate);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'more' });
  const opening = ui.press({ key: 'refresh-preferences' });
  await gate.started;
  await ui.press({ key: 'provider-codex' });
  expect(fixture.calls[2]).toEqual({ action: 'state', platforms: ['claude'] });
  gate.finish(delayedInspectionResult());
  await opening;
  expect(await ui.find({ type: 'Text', text: /Delayed old preference/ })).toBeUndefined();
  await saveAndReview(ui);
  expect(fixture.calls[3].platforms).toEqual(['claude']);
  expect(fixture.calls[3].configuration).toEqual(state(['claude']).presets.find(preset => preset.id === 'optimized').configuration);
});

test('inspection failures stay in Sources while native settings and editing remain usable', async ($, on) => {
  const current = state(); delete current.inspection;
  const gate = deferredInspection(), fixture = harness(on, current, preview(), [true], gate);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'more' });
  const opening = ui.press({ key: 'refresh-preferences' });
  await gate.started;
  await ui.press({ key: 'more' });
  await ui.press({ key: 'preset-high' });
  gate.finish({ ok: false, error: { code: 'timeout', message: 'Reader timed out.' } });
  await opening;
  expect((await ui.find({ key: 'preset-high' })).props.label).toBe('✓ High');
  expect(await ui.find({ type: 'Text', text: /Reader timed out/ })).toBeUndefined();
  expect(await ui.find({ key: 'review' })).toBeDefined();
  await ui.press({ key: 'more' });
  expect(await ui.find({ type: 'Text', text: 'Preferences unavailable: Reader timed out.' })).toBeDefined();
  expect(await ui.find({ key: 'refresh-preferences' })).toBeDefined();
  await saveAndReview(ui);
  expect(fixture.calls[2].configuration).toEqual(state().presets.find(preset => preset.id === 'high').configuration);
});

test('preset commands never inspect and an explicit later read cannot change the draft', async ($, on) => {
  const current = state(); delete current.inspection;
  const gate = deferredInspection(), fixture = harness(on, current, preview(), [true], gate);
  await $.command.run({ command: 'standmixer', args: 'high' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'preview']);
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ key: 'apply-reviewed' })).toBeDefined();
  await ui.press({ key: 'review-back' });
  await ui.press({ key: 'more' });
  const opening = ui.press({ key: 'refresh-preferences' });
  await gate.started;
  await ui.press({ key: 'more' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'preview', 'inspect']);
  await ui.press({ key: 'preset-fast' });
  gate.finish(delayedInspectionResult());
  await opening;
  expect((await ui.find({ key: 'preset-fast' })).props.label).toBe('✓ Fast');
  expect(await ui.find({ key: 'apply-reviewed' })).toBeUndefined();
  expect(await ui.find({ key: 'current-claude-ui' })).toBeUndefined();
  await ui.press({ key: 'more' });
  expect(await ui.find({ type: 'Text', text: 'Delayed old preference' })).toBeDefined();
});

test('a missing catalog model stays visible and repairable in the inline editor', async ($, on) => {
  const current = state();
  current.configuration.profiles[0].routes.find(route => route.category === 'ui').modelID = 'formerly-discovered-model';
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'edit' });
  const picker = await ui.find({ key: 'codex-ui-member-0-model' });
  expect(picker.props.value).toBe('formerly-discovered-model');
  expect(picker.props.options.find(option => option.value === 'formerly-discovered-model').label).toContain('currently unavailable');
  await ui.select({ key: 'codex-ui-member-0-model', value: 'gpt-6.1-sol' });
  await saveAndReview(ui);
  expect(fixture.calls[1].configuration.profiles[0].routes.find(route => route.category === 'ui').modelID).toBe('gpt-6.1-sol');
});

// Explicit row geometry only. Real terminal QA remains the authority for paint
// and wrapping; this budget catches invisible SVG leaves and padding regressions.
function terminalLogicalRows(node) {
  if (typeof node === 'string') return node.split('\n').length;
  const props = node.props || {}, children = node.children || [];
  if (node.type === 'Svg') throw new Error('Terminal tree contains an SVG');
  if (node.type !== 'Box') return node.type === 'Code' ? props.source.split('\n').length : 1;
  const heights = children.map(terminalLogicalRows);
  const horizontal = props.flexDirection === 'row' || props.flexDirection === 'row-reverse';
  const body = horizontal ? Math.max(0, ...heights) : heights.reduce((total, height) => total + height, 0) + (props.rowGap || 0) * Math.max(0, children.length - 1);
  return body + (props.borderStyle ? 2 : 0) + (props.paddingTop ?? props.paddingY ?? props.padding ?? 0) + (props.paddingBottom ?? props.paddingY ?? props.padding ?? 0)
    + (props.marginTop ?? props.marginY ?? props.margin ?? 0) + (props.marginBottom ?? props.marginY ?? props.margin ?? 0);
}

test('terminal draws every task glyph and High worker strength within a compact main-view row budget', async ($, on) => {
  const current = state();
  const high = current.presets.find(preset => preset.id === 'high').configuration;
  const workers = {
    codex: [['gpt-6-astra'], ['gpt-6-astra', 'claude-opus-5-5'], ['gpt-6-astra', 'claude-opus-5-5', 'claude-fable-5-1'], ['gpt-6-astra'], ['gpt-6-astra', 'claude-fable-5-1', 'claude-opus-5-5'], ['claude-opus-5-5', 'gpt-6-astra'], ['gpt-6-luna']],
    claude: [['claude-opus-5-5'], ['claude-opus-5-5', 'claude-fable-5-1'], ['claude-opus-5-5', 'claude-fable-5-1', 'gpt-6-astra'], ['claude-opus-5-5'], ['claude-fable-5-1', 'gpt-6-astra', 'claude-opus-5-5'], ['claude-opus-5-5', 'gpt-6-astra'], ['claude-haiku-5-5']],
  };
  for (const profile of high.profiles) profile.routes.forEach((route, index) => {
    route.modelID = workers[profile.platform][index][0];
    route.additionalAgents = workers[profile.platform][index].slice(1).map((modelID, workerIndex) => ({ id: profile.platform + '-' + index + '-' + workerIndex, modelID, effort: { ...route.effort } }));
  });
  current.installation = { state: 'applied', hasInstallation: true, installedPlatforms: ['codex', 'claude'], appliedConfiguration: current.configuration };
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'terminal', viewport: { columns: 168, rows: 70, isFullscreen: true }, props: { ...pane.props, bodyColumns: 74 } });
  await ui.press({ key: 'preset-high' });
  expect(await ui.find({ type: 'Svg' })).toBeUndefined();
  for (const glyph of ['◎', '↗', '▣', '‹›', '◇', '✓', '⌁']) expect(await ui.find({ type: 'Text', text: glyph })).toBeDefined();
  expect((await ui.findAll({ type: 'Text', text: /^[▂▄▆█]+$/ })).length).toBe(26);
  expect((await ui.findAll({ type: 'Text', text: '▂▄▆█' })).length).toBe(24);
  for (const task of ['coordinator', 'planning', 'ui', 'implementation', 'algorithms', 'review', 'mechanical']) expect((await ui.find({ key: 'row-' + task })).props.paddingY).toBe(0);
  expect(terminalLogicalRows(await ui.drawn()) <= fixture.openOptions[0].rows).toBe(true);
});

test('Controller Auto shows the current-model policy and hides effort while preserving native pins', async ($, on) => {
  const current = state();
  current.configuration.profiles[0].routes[0].modelID = 'auto';
  current.nativeSettings = [{ platform: 'codex', sourcePath: '/fixture/.codex/config.toml', status: 'known', modelID: 'gpt-6-luna', effort: 'low', detail: 'Saved global default' }];
  const fixture = harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ type: 'Text', text: 'Controller' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'Current model' })).toBeDefined();
  expect(await ui.find({ key: 'current-codex-coordinator' })).toBeUndefined();
  await ui.press({ key: 'edit' });
  const model = await ui.find({ key: 'codex-coordinator-member-0-model' });
  expect(model.props.options[0]).toEqual({ value: 'auto', label: 'Auto · Current model' });
  expect(await ui.find({ key: 'codex-coordinator-member-0-effort' })).toBeUndefined();
  await ui.select({ key: 'codex-coordinator-member-0-model', value: 'gpt-6.1-sol' });
  expect(await ui.find({ key: 'codex-coordinator-member-0-effort' })).toBeDefined();
  await ui.select({ key: 'codex-coordinator-member-0-effort', value: 'fixed' });
  await ui.select({ key: 'codex-coordinator-member-0-model', value: 'auto' });
  await saveAndReview(ui);
  const request = fixture.calls.find(call => call.action === 'preview');
  expect(request.configuration.profiles[0].routes[0].modelID).toBe('auto');
  expect(request.configuration.profiles[0].routes[0].effort.mode).toBe('auto');
});

test('Controller Auto compares a verified pinned policy and is absent from worker and judge choices', async ($, on) => {
  const current = state(), applied = JSON.parse(JSON.stringify(current.configuration));
  applied.profiles[0].routes[0].modelID = 'gpt-6.1-sol';
  current.configuration.profiles[0].routes[0].modelID = 'auto';
  current.installation = { state: 'applied', summary: 'Applied', hasInstallation: true, installedPlatforms: ['codex', 'claude'], appliedConfiguration: applied };
  harness(on, current);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ key: 'current-codex-coordinator' })).toBeDefined();
  await ui.press({ key: 'edit' });
  expect((await ui.find({ key: 'codex-ui-member-0-model' })).props.options.some(option => option.value === 'auto')).toBe(false);
  await ui.press({ key: 'codex-ui-add-worker' });
  await ui.select({ key: 'codex-ui-result-mode', value: 'ai' });
  const judge = await ui.find({ key: 'codex-ui-judge-model' });
  expect(judge.props.options.some(option => option.value === 'auto')).toBe(false);
  expect(judge.props.value).toBe('gpt-6.1-sol');
});

test('install-mac uses only its explicit helper action and opens build controls without inference', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: 'install-mac' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'installMac', 'state']);
  expect(fixture.calls[1]).toEqual({ action: 'installMac' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(await ui.find({ key: 'install-mac' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'Mac app built locally.' })).toBeDefined();
  expect(await ui.find({ key: 'review' })).toBeDefined();
});

test('a local Mac build leaves settings and pane dismissal available and prevents duplicate builds', async ($, on) => {
  let resolveInstall, signalStarted;
  const started = new Promise(resolve => { signalStarted = resolve; });
  const result = new Promise(resolve => { resolveInstall = resolve; });
  const fixture = harness(on, state(), preview(), [true], null, { signalStarted, result });
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'more' });
  const installing = ui.press({ key: 'install-mac' });
  await started;
  expect(await ui.find({ key: 'install-mac' })).toBeUndefined();
  expect(await ui.find({ type: 'Text', text: 'Building Mac app…' })).toBeDefined();
  expect(await ui.find({ key: 'edit' })).toBeDefined();
  expect(await ui.find({ key: 'close' })).toBeDefined();
  await ui.press({ key: 'edit' });
  expect(await ui.find({ key: 'codex-ui-member-0-model' })).toBeDefined();
  resolveInstall({ ok: true, result: { message: 'Mac app built locally.', changedFiles: 0, notes: [] } });
  await installing;
  expect(fixture.calls.filter(call => call.action === 'installMac').length).toBe(1);
  expect(await ui.find({ key: 'install-mac' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'Building Mac app…' })).toBeUndefined();
});

test('explicit CLI account checks show identity without guessing the Desktop sign-in or using inference', async ($, on) => {
  const accountResult = { ok: true, accounts: { checkedAt: '2026-11-03T12:00:00Z', providers: [
    { platform: 'claude', status: 'signedIn', email: 'cli-user@example.test', subscription: 'Max', detail: 'Public CLI status', cliPath: '/fixture/claude' },
    { platform: 'codex', status: 'unknown', detail: 'Identity is not exposed by this CLI.' },
  ] } };
  const fixture = harness(on, state(), preview(), [true], null, null, accountResult);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect(fixture.calls.map(call => call.action)).toEqual(['state']);
  expect(await ui.find({ key: 'check-accounts' })).toBeUndefined();
  await ui.press({ key: 'more' });
  expect(await ui.find({ type: 'Text', text: 'CLI account · Not checked' })).toBeDefined();
  await ui.press({ key: 'check-accounts' });
  expect(fixture.calls[1]).toEqual({ action: 'checkAccounts' });
  expect(await ui.find({ type: 'Text', text: 'CLI account · Signed in' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'cli-user@example.test' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'Plan: Max' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'CLI account · Unknown' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'CLI account · Signed out' })).toBeUndefined();
  expect(await ui.find({ type: 'Text', text: 'CLI-launched workers use this sign-in. Claude Desktop may use a different account.' })).toBeDefined();
  expect(await ui.find({ key: 'review' })).toBeDefined();
});

test('signed-out account status is separate from unknown and keeps settings usable', async ($, on) => {
  const fixture = harness(on, state(), preview(), [true], null, null, { ok: true, accounts: { checkedAt: '2026-11-03T12:00:00Z', providers: [{ platform: 'claude', status: 'signedOut', detail: 'Sign in with the CLI, then check again.' }] } });
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'more' });
  await ui.press({ key: 'check-accounts' });
  expect(await ui.find({ type: 'Text', text: 'CLI account · Signed out' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'Sign in with the CLI, then check again.' })).toBeDefined();
  await ui.press({ key: 'edit' });
  expect(await ui.find({ key: 'codex-ui-member-0-model' })).toBeDefined();
  expect(fixture.calls.map(call => call.action)).toEqual(['state', 'checkAccounts']);
});

test('failed account checks report unknown and never imply a signed-out CLI', async ($, on) => {
  harness(on, state(), preview(), [true], null, null, { ok: false, error: { message: 'Public account status is unavailable.' } });
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'more' });
  await ui.press({ key: 'check-accounts' });
  expect(await ui.find({ type: 'Text', text: 'CLI account · Unknown' })).toBeDefined();
  expect(await ui.find({ type: 'Text', text: 'CLI account · Signed out' })).toBeUndefined();
  expect(await ui.find({ type: 'Text', text: 'Public account status is unavailable.' })).toBeDefined();
  expect(await ui.find({ key: 'check-accounts' })).toBeDefined();
});

test('Advanced team mode changes review behavior without changing ordered model selections', async ($, on) => {
  const fixture = harness(on);
  await $.command.run({ command: 'standmixer', args: '' });
  const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  await ui.press({ key: 'edit' }); await ui.press({ key: 'codex-ui-add-worker' });
  const before = (await ui.find({ key: 'codex-ui-member-0-model' })).props.value;
  await ui.select({ key: 'codex-ui-team-mode', value: 'leadReview' });
  expect((await ui.find({ key: 'codex-ui-member-0-model' })).props.label).toBe('Lead');
  expect((await ui.find({ key: 'codex-ui-member-1-model' })).props.label).toBe('Reviewer 1');
  await saveAndReview(ui);
  const route = fixture.calls.find(call => call.action === 'preview').configuration.profiles[0].routes.find(route => route.category === 'ui');
  expect(route.teamMode).toBe('leadReview'); expect(route.modelID).toBe(before); expect(route.additionalAgents.length).toBe(1);
});

test('Edit makes every row editable; Cancel restores the draft with no writes', async ($, on) => {
  const initial = state(), before = JSON.parse(JSON.stringify(initial.configuration));initial.installation={...initial.installation,state:'applied',hasInstallation:true,installedPlatforms:['codex','claude'],appliedConfiguration:JSON.parse(JSON.stringify(before))};initial.installation.appliedConfiguration.profiles[0].routes.find(route=>route.category==='implementation').modelID='gpt-6-luna';const fixture = harness(on, initial);
  await $.command.run({ command: 'standmixer', args: '' });const ui = await $.ui.mount({ ...pane, surface: 'desktop' });
  expect((await ui.find({ key: 'edit' })).props.label).toBe('Edit…');await ui.press({ key: 'edit' });
  expect(await ui.find({ key: 'save-edit' })).toBeDefined();expect(await ui.find({ key: 'save-draft' })).toBeUndefined();expect(await ui.find({ key: 'review' })).toBeUndefined();
  for (const platform of ['codex','claude']) for (const task of ['coordinator','planning','ui','implementation','algorithms','review','mechanical']) expect(await ui.find({ key: platform + '-' + task + '-member-0-model' })).toBeDefined();
  expect(await ui.find({type:'Text',text:'Edited'})).toBeUndefined();await ui.select({ key: 'codex-implementation-member-0-model', value: 'gpt-6-astra' });expect(await ui.find({type:'Text',text:'Edited'})).toBeDefined();expect((await ui.find({key:'editor-codex-implementation'})).props.borderColor).toBe('#6fb3b8');await ui.press({key:'undo-draft'});expect(await ui.find({type:'Text',text:'Edited'})).toBeUndefined();await ui.press({key:'redo-draft'});expect(await ui.find({type:'Text',text:'Edited'})).toBeDefined();await ui.select({ key: 'codex-implementation-member-0-model', value: 'gpt-6.1-sol' });expect(await ui.find({type:'Text',text:'Edited'})).toBeUndefined();await ui.select({key:'codex-implementation-member-0-effort',value:'fixed'});expect(await ui.find({type:'Text',text:'Edited'})).toBeDefined();await ui.select({key:'codex-implementation-member-0-effort',value:'auto'});expect(await ui.find({type:'Text',text:'Edited'})).toBeUndefined();await ui.press({ key: 'preset-high' });
  await ui.press({ key: 'cancel-edit' });expect(fixture.calls.map(call=>call.action)).toEqual(['state']);await ui.press({key:'edit'});expect(await ui.find({type:'Text',text:'Edited'})).toBeUndefined();await ui.press({key:'cancel-edit'});await ui.press({ key: 'review' });expect(fixture.calls[1].configuration).toEqual(before);
});
test('Save writes only the draft and exits; failed Save keeps edits and Cancel intact', async ($, on) => {
  const fixture=harness(on);await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  await ui.press({key:'edit'});await ui.select({key:'codex-implementation-member-0-model',value:'gpt-6-astra'});fixture.setSaveFailure('Draft write failed.');await ui.press({key:'save-edit'});
  expect(await ui.find({key:'save-edit'})).toBeDefined();expect(await ui.find({key:'cancel-edit'})).toBeDefined();expect((await ui.find({key:'codex-implementation-member-0-model'})).props.value).toBe('gpt-6-astra');
  fixture.setSaveFailure(null);await ui.press({key:'save-edit'});expect(await ui.find({key:'save-edit'})).toBeUndefined();expect(await ui.find({key:'edit'})).toBeDefined();expect(fixture.calls.map(call=>call.action)).toEqual(['state','saveDraft','saveDraft']);
});

test('canonical StandMixer command shows the mixer and explicit interfaces without launching them', async ($, on) => {
  const fixture = harness(on);await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  expect(await ui.find({type:'Text',text:'StandMixer'})).toBeDefined();expect(await ui.find({type:'Svg',alt:'StandMixer'})).toBeDefined();expect(fixture.openedURLs.length).toBe(0);expect(await ui.find({key:'nav-activity'})).toBeUndefined();
  const interfaceButton = await ui.find({key:'interfaces'});expect(interfaceButton.props.label).toBe('Interface ▾');expect(interfaceButton.props.variant).toBe('secondary');expect(interfaceButton.props.plain).toBeUndefined();expect((await ui.find({key:'interfaces-control'})).props.borderStyle).toBe('round');
  await ui.press({key:'interfaces'});expect((await ui.find({key:'interfaces'})).props.label).toBe('Interface ▴');expect(await ui.find({type:'Text',text:'Native · Current'})).toBeDefined();expect((await ui.find({key:'interface-mac'})).props.label).toBe('Mac · Install…');expect(fixture.calls.map(x=>x.action)).toEqual(['state']);
});
test('explicit Web and Mac opening leaves the native Edit draft intact', async ($, on) => {
  const initial=state();initial.installedMac={isAvailable:true,detail:'Owned fixture app'};const fixture=harness(on,initial);await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  await ui.press({key:'edit'});await ui.select({key:'codex-implementation-member-0-model',value:'gpt-6-astra'});await ui.press({key:'interfaces'});expect((await ui.find({key:'interface-mac'})).props.label).toBe('Mac · Open');await ui.press({key:'interface-web'});await ui.press({key:'interface-mac'});
  expect(fixture.calls.map(x=>x.action)).toEqual(['state','openWeb','openMac']);expect(fixture.openedURLs).toEqual(['http://127.0.0.1:54321/#token='+'a'.repeat(43)]);expect(await ui.find({key:'save-edit'})).toBeDefined();expect((await ui.find({key:'codex-implementation-member-0-model'})).props.value).toBe('gpt-6-astra');await ui.press({key:'cancel-edit'});
});
test('native Web opening rejects untrusted addresses before invoking the system opener', async ($, on) => {
  const fixture=harness(on);fixture.setOpeningURL('https://example.test/#token=secret');await $.command.run({command:'standmixer',args:'web'});const ui=await $.ui.mount({...pane,surface:'desktop'});
  expect(fixture.openedURLs.length).toBe(0);expect(await ui.find({type:'Text',text:'The local Web interface returned an invalid address.'})).toBeDefined();expect(fixture.calls.map(x=>x.action)).toEqual(['state','openWeb']);
});

test('draft Undo and Redo stay local while editing and survive Save without applying native settings', async ($, on) => {
  const fixture=harness(on);await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  await ui.press({key:'edit'});await ui.select({key:'codex-implementation-member-0-model',value:'gpt-6-astra'});await ui.press({key:'undo-draft'});expect((await ui.find({key:'codex-implementation-member-0-model'})).props.value).toBe('gpt-6.1-sol');expect(fixture.calls.map(x=>x.action)).toEqual(['state']);
  await ui.press({key:'redo-draft'});expect((await ui.find({key:'codex-implementation-member-0-model'})).props.value).toBe('gpt-6-astra');await ui.press({key:'save-edit'});await ui.press({key:'undo-draft'});expect(fixture.calls[2].configuration.profiles[0].routes.find(x=>x.category==='implementation').modelID).toBe('gpt-6.1-sol');await ui.press({key:'redo-draft'});expect(fixture.calls.map(x=>x.action)).toEqual(['state','saveDraft','saveDraft','saveDraft']);
});
test('Cancel restores the Undo history from Edit entry and repeated selections add no history', async ($, on) => {
  const fixture=harness(on);await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  await ui.press({key:'preset-optimized'});expect(await ui.find({key:'undo-draft'})).toBeUndefined();await ui.press({key:'preset-fast'});await ui.press({key:'edit'});await ui.select({key:'codex-implementation-member-0-model',value:'gpt-6-astra'});await ui.press({key:'undo-draft'});await ui.press({key:'cancel-edit'});expect(await ui.find({key:'redo-draft'})).toBeUndefined();await ui.press({key:'undo-draft'});expect(await ui.find({key:'undo-draft'})).toBeUndefined();expect(fixture.calls.map(x=>x.action)).toEqual(['state']);
});
test('failed saved Undo keeps its history for retry and successful Apply clears it', async ($, on) => {
  const fixture=harness(on);await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  await ui.press({key:'edit'});await ui.select({key:'codex-implementation-member-0-model',value:'gpt-6-astra'});await ui.press({key:'save-edit'});fixture.setSaveFailure('Draft write failed.');await ui.press({key:'undo-draft'});expect(await ui.find({key:'redo-draft'})).toBeUndefined();expect((await ui.find({key:'undo-draft'})).props.dimColor).toBe(false);fixture.setSaveFailure(null);await ui.press({key:'undo-draft'});expect(await ui.find({key:'redo-draft'})).toBeDefined();await ui.press({key:'review'});await ui.press({key:'apply-reviewed'});expect(await ui.find({key:'undo-draft'})).toBeUndefined();expect(await ui.find({key:'redo-draft'})).toBeUndefined();
});

test('Redo of an unsaved native change never saves merely because Undo reached the saved baseline', async ($, on) => {
  const initial=state();initial.hasSavedDraft=true;const fixture=harness(on,initial);await $.command.run({command:'standmixer',args:''});const ui=await $.ui.mount({...pane,surface:'desktop'});
  await ui.press({key:'preset-fast'});await ui.press({key:'undo-draft'});await ui.press({key:'redo-draft'});expect(fixture.calls.map(x=>x.action)).toEqual(['state']);
  await ui.press({key:'undo-draft'});await ui.press({key:'edit'});await ui.press({key:'save-edit'});await ui.press({key:'redo-draft'});expect(fixture.calls.map(x=>x.action)).toEqual(['state','saveDraft']);
});
