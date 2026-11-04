// Native Claude Code mod. No Node, web view, prompt submission, or model calls.
// All settings, preset recipes, provider validation, and writes belong to the helper.
const PANE = 'standmixer';
const OPENED = 'settings-opened-v1';
const CONTROLLER_AUTO = 'Auto keeps the current native model and effort. Saved defaults stay unchanged. A pinned model applies to new sessions; this chat keeps its current model.';
const isAutoController = route => route?.category === 'coordinator' && route.modelID === 'auto';
import { TASKS, PLATFORM_NAMES, PROVIDER_COLORS, PRESET_DETAILS, LEVELS, title,
  effortLabel, routeKey, recipeKey, matchedPreset, modelIdentity, taskIcon, strengthMark, brandMark } from './presentation.js';
let view;

function freshView() {
  return { state: null, draft: null, platforms: [], preset: null, savedID: '', advanced: false, editSnapshot: null, undoStack: [], redoStack: [], historyCurrent: null, cleanKey: null, updateInfo: null, checkingUpdates: false,
    more: false, interfaces: false, openingInterface: false, interfaceMessage: '', interfaceError: false, installingMac: false, macInstallMessage: '', macInstallError: false, checkingAccounts: false, accounts: null, accountError: '', currentCell: '', busy: '', error: '', message: '',
    readingPreferences: false, preferenceWarning: '', preferenceGeneration: 0, inspectionFlight: null,
    presetName: '', savePanel: false, deletePending: false, customPanel: false,
    customID: '', customLabel: '', customPlatform: 'codex', customEfforts: ['low', 'medium', 'high'],
    preview: null, pages: [], page: 0, showDiff: false, helper: null,
    onboardingPending: false, onboardingRetried: false };
}
function clone(value) { return JSON.parse(JSON.stringify(value)); }
function autoEffort() { return { mode: 'auto', value: 'high', minimum: 'low', maximum: 'high' }; }
function routeIn(configuration, platform, task) {
  return configuration?.profiles.find(profile => profile.platform === platform)?.routes.find(route => route.category === task);
}
function routeFor(platform, task) { return routeIn(view.draft, platform, task); }
function catalog() {
  const savedCustom = view.state.configuration.customModels || [];
  const factoryIDs = new Set(view.state.presets.flatMap(preset => preset.configuration.profiles.flatMap(profile => profile.routes.flatMap(route => [route.modelID, ...(route.additionalAgents || []).map(worker => worker.modelID)]))));
  const base = view.state.catalog.filter(model => model.isDiscovered || factoryIDs.has(model.id) || !savedCustom.some(custom => custom.id === model.id));
  return [...base, ...(view.draft.customModels || []).filter(model => !base.some(known => known.id === model.id))].filter(model => model.id !== 'auto');
}
function modelFor(id) { return catalog().find(model => model.id === id); }
function invalidateInspection() { view.preferenceGeneration++; view.preferenceWarning = ''; }
function resetReview() { view.preview = null; view.pages = []; view.showDiff = false; view.page = 0; }
function syncSelection(preferred) {
  const presets = view.state.presets;
  const match = presets.find(preset => preset.id === preferred && recipeKey(preset.configuration, view.platforms) === recipeKey(view.draft, view.platforms));
  view.preset = match?.id || matchedPreset(view.draft, view.platforms, presets);
}
function stableDraft(value) {
  if (Array.isArray(value)) return value.map(stableDraft);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, stableDraft(value[key])]));
  return value;
}
function draftSnapshot() { return { draft: clone(view.draft), platforms: [...view.platforms], preset: view.preset, savedID: view.savedID, presets: clone(view.state.presets) }; }
function draftKey(snapshot) { const draft = clone(snapshot.draft), platforms = [...snapshot.platforms].sort(); draft.enabledPlatforms = platforms; return JSON.stringify(stableDraft([draft, platforms])); }
function resetDraftHistory() { view.undoStack = []; view.redoStack = []; view.historyCurrent = draftSnapshot(); view.cleanKey = draftKey(view.historyCurrent); }
function rememberDraft() {
  const next = draftSnapshot();
  if (view.historyCurrent && draftKey(next) !== draftKey(view.historyCurrent)) { view.undoStack.push({ ...view.historyCurrent, persisted: false }); if (view.undoStack.length > 50) view.undoStack.shift(); view.redoStack = []; }
  view.historyCurrent = next;
}
function draftSaved() { view.historyCurrent = draftSnapshot(); const key = draftKey(view.historyCurrent); if (key !== view.cleanKey) view.undoStack.forEach(entry => { entry.persisted = true; }); view.cleanKey = key; }
async function travelDraft($, redo = false) {
  const from = redo ? view.redoStack : view.undoStack, to = redo ? view.undoStack : view.redoStack;
  if (view.busy || !from.length) return;
  const target = clone(from[from.length - 1]), current = draftSnapshot(), persist = !view.advanced && target.persisted === true;
  await runAction($, redo ? 'Redoing draft…' : 'Undoing draft…', async () => {
    if (persist) { const response = await helperCall($, { action: 'saveDraft', configuration: target.draft, platforms: target.platforms }); view.state = response.state; }
    from.pop(); to.push({ ...current, persisted: target.persisted === true });
    view.draft = target.draft; view.platforms = target.platforms; view.preset = target.preset; view.savedID = target.savedID; view.state.presets = target.presets;
    if (view.savedID && !view.state.savedPresets.some(preset => preset.id === view.savedID)) view.savedID = '';
    syncSelection(view.preset);
    view.currentCell = ''; view.message = ''; view.error = ''; invalidateInspection(); resetReview(); view.historyCurrent = draftSnapshot();
    if (persist) view.cleanKey = draftKey(view.historyCurrent);
  });
}
function edited() { view.savedID = ''; view.message = ''; view.error = ''; view.deletePending = false; syncSelection(); resetReview(); rememberDraft(); }
function chooseConfiguration(configuration, preset, savedID = '') {
  const previousPlatforms = [...view.platforms].sort().join();
  const retainedModels = view.draft?.customModels || [];
  view.draft = clone(configuration);
  if (preset) view.draft.customModels = clone(retainedModels);
  view.platforms = (configuration.enabledPlatforms || view.platforms).filter(platform => view.state.availablePlatforms.includes(platform));
  if ([...view.platforms].sort().join() !== previousPlatforms) invalidateInspection();
  view.savedID = savedID; view.message = ''; view.error = ''; view.currentCell = ''; view.deletePending = false;
  syncSelection(preset); resetReview(); rememberDraft();
}
function disabledDependencies() {
  const dependencies = [];
  for (const profile of view.draft.profiles.filter(profile => view.platforms.includes(profile.platform))) {
    for (const route of profile.routes) {
      const ids = [route.modelID, ...(route.additionalAgents || []).map(worker => worker.modelID),
        ...(route.resultMode === 'ai' && route.judgeModelID ? [route.judgeModelID] : [])];
      for (const id of [...new Set(ids)]) {
        const model = modelFor(id);
        if (model && !view.platforms.includes(model.platform)) {
          const task = TASKS.find(([category]) => category === route.category)?.[1] || route.category;
          dependencies.push(`${PLATFORM_NAMES[profile.platform]} ${task}: ${model.label} needs ${PLATFORM_NAMES[model.platform]}`);
        }
      }
    }
  }
  return dependencies;
}
function currentAssignment(platform, task) {
  const installation = view.state.installation;
  if (installation.state === 'applied' && installation.installedPlatforms.includes(platform)) {
    const route = routeIn(installation.appliedConfiguration, platform, task);
    if (route) return { route, source: 'Verified StandMixer settings', complete: true };
  }
  if (task === 'coordinator') {
    const native = view.state.nativeSettings?.find(setting => setting.platform === platform && setting.status === 'known' && setting.modelID);
    if (native) return { route: { modelID: native.modelID, effort: native.effort ? { mode: 'fixed', value: native.effort } : null, additionalAgents: [] },
      source: native.sourcePath, complete: false };
  }
  return null;
}
function observedAssignment(platform, task) {
  const report = view.state.inspection?.reports.find(item => item.platform === platform && item.status !== 'failed');
  const route = report?.routes.find(item => item.category === task && item.modelID);
  return route ? { route, report, label: route.scope === 'usual' ? 'Usual' : 'Observed' } : null;
}
function assignmentChanged(platform, task) {
  const current = currentAssignment(platform, task), draft = routeFor(platform, task);
  if (!current || !draft) return false;
  if (current.complete) return routeKey(current.route) !== routeKey(draft);
  if (isAutoController(draft)) return false;
  return current.route.modelID !== draft.modelID || (draft.effort.mode === 'fixed' && current.route.effort && draft.effort.value !== current.route.effort.value);
}
function routeDescription(route) {
  if (!route) return 'Unknown';
  if (route.modelID === 'auto') return 'Auto · Current model';
  const workers = [route, ...(route.additionalAgents || [])];
  const names = workers.map(worker => (modelFor(worker.modelID)?.label || worker.modelID) + (worker.effort ? ' · ' + effortLabel(worker.effort) : ''));
  if (workers.length > 1) names.push(route.teamMode === 'leadReview' ? 'Lead + focused review' : 'Independent passes');
  if (workers.length > 1) names.push(route.resultMode === 'ai' ? 'Judge: ' + (modelFor(route.judgeModelID)?.label || route.judgeModelID)
    : route.resultMode === 'user' ? 'You choose the result' : 'Controller combines results');
  return names.join(' / ');
}
async function helperCall($, request) {
  if (!view.helper) {
    const bootstrap = await $.process.run(['/bin/sh', $.plugin.root + '/scripts/bootstrap.sh'], { timeoutMs: 30000 });
    const stable = bootstrap.stdout.trim();
    if (bootstrap.exitCode !== 0 || bootstrap.isStdoutTruncated || !stable.startsWith('/') || stable.includes('\n')) {
      throw new Error(bootstrap.stderr.trim() || 'The StandMixer helper could not be prepared. Install the complete StandMixer plugin package, then reopen /standmixer.');
    }
    view.helper = stable;
  }
  const result = await $.process.run([view.helper], { stdin: JSON.stringify(request), timeoutMs: request.action === 'installMac' ? 600000 : request.action === 'inspect' ? 120000 : 30000 });
  if (result.isStdoutTruncated) throw new Error('The helper response exceeds Claude Code’s 4 MiB limit. Reopen /standmixer to check current settings, or review this configuration in the StandMixer app.');
  let response;
  try { response = JSON.parse(result.stdout); }
  catch (_) { throw new Error('The StandMixer helper returned an incomplete response. Reopen /standmixer to refresh before retrying.'); }
  if (!response.ok || result.exitCode !== 0) throw new Error(response.error?.message || 'StandMixer could not complete this change.');
  return response;
}
async function checkAccounts($) {
  if (view.checkingAccounts) return;
  view.checkingAccounts = true; view.accounts = null; view.accountError = ''; $.ui.invalidate('ui.render');
  try { const response = await helperCall($, { action: 'checkAccounts' }); view.accounts = response.accounts; }
  catch (error) { view.accountError = error.message || String(error); }
  finally { view.checkingAccounts = false; $.ui.invalidate('ui.render'); }
}
function renderCLIAccount(elements, platform) {
  const { Text } = elements, account = view.accounts?.providers?.find(item => item.platform === platform);
  const label = account?.status === 'signedIn' ? 'Signed in' : account?.status === 'signedOut' ? 'Signed out' : account || view.accountError ? 'Unknown' : 'Not checked';
  return [Text({ bold: true, children: ['CLI account · ' + label] }),
    ...(account?.status === 'signedIn' ? [Text({ wrap: 'wrap', children: [account.email || 'Identity not reported'] })] : []),
    ...(account?.subscription ? [Text({ dimColor: true, wrap: 'wrap', children: ['Plan: ' + account.subscription] })] : []),
    ...(account?.detail ? [Text({ dimColor: true, wrap: 'wrap', children: [account.detail] })] : []),
    ...(account?.cliPath ? [Text({ dimColor: true, wrap: 'wrap', children: [account.cliPath] })] : []),
    ...(view.accounts?.checkedAt ? [Text({ dimColor: true, children: ['Checked ' + view.accounts.checkedAt] })] : []),
    ...(platform === 'claude' ? [Text({ dimColor: true, wrap: 'wrap', children: ['CLI-launched workers use this sign-in. Claude Desktop may use a different account.'] })] : [])];
}
async function installMac($) {
  if (view.installingMac) return;
  view.installingMac = true; view.macInstallMessage = 'Building Mac app…'; view.macInstallError = false; $.ui.invalidate('ui.render');
  try { const response = await helperCall($, { action: 'installMac' }); view.macInstallMessage = response.result?.message || 'Mac app installed.'; try { const refreshed = await helperCall($, { action: 'state' }); if (refreshed.state?.installedMac) view.state.installedMac = refreshed.state.installedMac; } catch (_) {} }
  catch (error) { view.macInstallMessage = error.message || String(error); view.macInstallError = true; }
  finally { view.installingMac = false; $.ui.invalidate('ui.render'); }
}
function safeWebURL(value) {
  if (typeof value !== 'string' || !/^http:\/\/127\.0\.0\.1:[0-9]{1,5}\/#token=[A-Za-z0-9_-]{43}$/.test(value)) throw new Error('The local Web interface returned an invalid address.');
  const port = Number(value.split(':')[2].split('/')[0]);
  if (port < 1 || port > 65535) throw new Error('The local Web interface returned an invalid address.');
  return value;
}
async function openInterface($, kind) {
  if (view.openingInterface) return;
  view.openingInterface = true; view.interfaceMessage = ''; view.interfaceError = false; $.ui.invalidate('ui.render');
  try {
    const response = await helperCall($, { action: kind === 'web' ? 'openWeb' : 'openMac' });
    if (kind === 'web') {
      const result = await $.process.run(['/usr/bin/open', safeWebURL(response.web?.url)], { timeoutMs: 15000 });
      if (result.exitCode !== 0) throw new Error('The browser could not open StandMixer.');
      view.interfaceMessage = 'Opened in browser.';
    } else view.interfaceMessage = response.result?.message || 'Mac app opened.';
  } catch (error) { view.interfaceMessage = error.message || String(error); view.interfaceError = true; }
  finally { view.openingInterface = false; $.ui.invalidate('ui.render'); }
}
function renderInterfaces($, elements) {
  const { Box, Text, Button } = elements, installed = view.state?.installedMac?.isAvailable;
  return Box({ flexDirection: 'column', rowGap: 0, children: [
    Box({ flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: [
      Text({ dimColor: true, children: ['Native · Current'] }),
      ...(view.openingInterface ? [Text({ dimColor: true, children: ['Opening…'] })] : [
        Button({ key: 'interface-web', label: 'Web · Open in browser…', plain: true, onPress: async () => { await openInterface($, 'web'); } }),
        ...(view.installingMac ? [Text({ dimColor: true, children: ['Building Mac app…'] })] : [Button({ key: 'interface-mac', label: installed ? 'Mac · Open' : 'Mac · Install…', plain: true, onPress: async () => { if (view.state?.installedMac?.isAvailable) await openInterface($, 'mac'); else await installMac($); } })]),
      ]),
    ] }),
    ...(view.interfaceMessage ? [Text({ color: view.interfaceError ? 'red' : undefined, dimColor: !view.interfaceError, wrap: 'wrap', children: [view.interfaceMessage] })] : []),
    ...(view.macInstallMessage && !view.installingMac ? [Text({ color: view.macInstallError ? 'red' : undefined, dimColor: !view.macInstallError, wrap: 'wrap', children: [view.macInstallMessage] })] : []),
  ] });
}
async function runAction($, label, action) {
  if (view.busy) return;
  view.busy = label; view.error = ''; $.ui.invalidate('ui.render');
  try { await action(); }
  catch (error) { view.error = error.message || String(error); }
  finally { view.busy = ''; $.ui.invalidate('ui.render'); }
}
async function loadState($, preserveDraft = false) {
  invalidateInspection();
  const response = await helperCall($, { action: 'state', ...(preserveDraft ? { platforms: view.platforms } : {}) });
  view.state = response.state;
  if (!preserveDraft || !view.draft) {
    view.draft = clone(response.state.configuration);
    view.platforms = [...response.state.enabledPlatforms];
    view.savedID = '';
  }
  syncSelection(view.preset); resetReview();
  if (!preserveDraft || !view.historyCurrent) resetDraftHistory(); else view.historyCurrent = draftSnapshot();
}
function beginEdit($) {
  if (view.busy || view.advanced) return;
  view.editSnapshot = { draft: clone(view.draft), platforms: [...view.platforms], preset: view.preset, savedID: view.savedID, presets: clone(view.state.presets), undoStack: clone(view.undoStack), redoStack: clone(view.redoStack) };
  view.advanced = true; view.currentCell = ''; view.savePanel = false; view.deletePending = false; resetReview(); $.ui.invalidate('ui.render');
}
function cancelEdit($) {
  if (view.busy || !view.editSnapshot) return;
  const before = view.editSnapshot;
  view.draft = before.draft; view.platforms = before.platforms; view.preset = before.preset; view.savedID = before.savedID; view.state.presets = before.presets; view.undoStack = before.undoStack; view.redoStack = before.redoStack; view.historyCurrent = draftSnapshot();
  view.advanced = false; view.editSnapshot = null; view.customPanel = false; view.currentCell = ''; view.error = ''; view.message = ''; resetReview(); $.ui.invalidate('ui.render');
}
async function saveEdit($) {
  if (!view.advanced || view.busy) return;
  await runAction($, 'Saving draft…', async () => {
    const response = await helperCall($, { action: 'saveDraft', configuration: clone(view.draft), platforms: [...view.platforms] });
    view.state = response.state; view.advanced = false; view.editSnapshot = null; view.customPanel = false; syncSelection(view.preset); resetReview(); draftSaved(); view.message = 'Draft saved';
  });
}
async function saveDraft($) {
  await runAction($, 'Saving draft…', async () => {
    const response = await helperCall($, { action: 'saveDraft', configuration: view.draft, platforms: view.platforms });
    view.state = response.state; syncSelection(view.preset); resetReview(); draftSaved(); view.message = 'Draft saved';
  });
}
async function savePreset($) {
  if (view.advanced) return;
  if (!view.presetName.trim()) { view.error = 'Give this preset a name.'; $.ui.invalidate('ui.render'); return; }
  await runAction($, 'Saving preset…', async () => {
    const name = view.presetName.trim();
    const response = await helperCall($, { action: 'savePreset', name, configuration: view.draft, platforms: view.platforms });
    view.state = response.state;
    view.savedID = view.state.savedPresets.find(preset => preset.name.toLowerCase() === name.toLowerCase())?.id || '';
    view.presetName = ''; view.savePanel = false; view.message = 'Preset saved'; syncSelection(view.preset); resetReview();
  });
}
async function toggleProvider($, platform) {
  if (view.busy || !view.state.availablePlatforms.includes(platform)) return;
  const selected = view.platforms.includes(platform) ? view.platforms.filter(value => value !== platform) : [...view.platforms, platform];
  if (!selected.length) return;
  await runAction($, 'Refreshing providers…', async () => {
    invalidateInspection();
    const activePreset = view.preset;
    const response = await helperCall($, { action: 'state', platforms: selected });
    view.state = response.state; view.platforms = [...response.state.enabledPlatforms];
    const adapted = activePreset && view.state.presets.find(preset => preset.id === activePreset);
    if (adapted) view.draft = { ...clone(adapted.configuration), customModels: view.draft.customModels };
    view.draft.enabledPlatforms = [...view.platforms];
    view.savedID = ''; view.currentCell = ''; view.message = ''; syncSelection(activePreset); resetReview(); rememberDraft();
  });
}
async function inspectPreferences($, refresh = false) {
  if ((!refresh && view.state.inspection) || !view.platforms.length) return;
  if (view.inspectionFlight) return view.inspectionFlight;
  const owner = view, generation = ++view.preferenceGeneration, platforms = [...view.platforms];
  owner.readingPreferences = true; owner.preferenceWarning = ''; $.ui.invalidate('ui.render');
  const flight = (async () => {
    try {
      const response = await helperCall($, { action: 'inspect', platforms, ...(refresh ? { refresh: true } : {}) });
      if (view === owner && owner.preferenceGeneration === generation) owner.state.inspection = response.inspection;
    } catch (error) {
      if (view === owner && owner.preferenceGeneration === generation) owner.preferenceWarning = error.message || String(error);
    } finally {
      if (view === owner) {
        owner.readingPreferences = false; owner.inspectionFlight = null; $.ui.invalidate('ui.render');
      }
    }
  })();
  owner.inspectionFlight = flight;
  await flight;
}
async function openSettings($, automatic) {
  await runAction($, 'Preparing · reading current settings…', async () => {
    const opened = await $.ui.open({ id: PANE, title: 'StandMixer', rows: 38, columns: 100,
      closeOnEscape: true, focus: true });
    if (opened.isPlaced) {
      view.onboardingPending = false;
      await $.store.set(OPENED, true);
    } else if (automatic) view.onboardingPending = true;
    await loadState($, view.advanced);
  });
  void checkUpdates($);
}

async function checkUpdates($) {
  if (!view.state?.canCheckUpdates || view.checkingUpdates) return;
  view.checkingUpdates = true;
  try {
    const response = await helperCall($, { action: 'checkUpdates' });
    view.updateInfo = response.update || null;
    $.ui.invalidate('ui.render');
  } catch (_) { /* Version checks never interrupt settings or request model help. */ }
  finally { view.checkingUpdates = false; }
}

async function retryOnboarding($) {
  view.onboardingRetried = true;
  const opened = await $.ui.open({ id: PANE, title: 'StandMixer', rows: 38, columns: 100,
    closeOnEscape: true, focus: true });
  if (opened.isPlaced) {
    view.onboardingPending = false;
    await $.store.set(OPENED, true);
  }
}

// Every line of every changed file remains reachable; no diff is cut to fit a tree.
// Pages also stay below the host's 100,000-character tree limit.
export function reviewPages(preview) {
  const pages = [];
  for (const change of preview.changes.filter(change => change.isChanged)) {
    const lines = [];
    for (const hunk of change.diff.hunks) {
      lines.push(`@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@`);
      for (const line of hunk.lines) {
        const prefix = line.kind === 'addition' ? '+' : line.kind === 'removal' ? '-' : ' ';
        // Very long source lines are continued, never silently shortened.
        for (let start = 0; start < Math.max(line.text.length, 1); start += 12000) {
          lines.push(prefix + line.text.slice(start, start + 12000));
        }
      }
    }
    if (change.diff.hasFinalNewlineChange) lines.push('\\ No newline at end of file (changed)');
    if (lines.length === 0) lines.push(change.isDeletion ? '(Delete empty file)' : '(Create empty file)');
    let current = [], length = 0;
    const filePages = [];
    for (const line of lines) {
      if (current.length && (current.length >= 26 || length + line.length > 16000)) {
        filePages.push(current.join('\n')); current = []; length = 0;
      }
      current.push(line); length += line.length + 1;
    }
    if (current.length) filePages.push(current.join('\n'));
    filePages.forEach((source, index) => pages.push({ path: change.path, reason: change.reason, source,
      part: index + 1, parts: filePages.length, added: change.diff.addedLineCount, removed: change.diff.removedLineCount,
      isCoarse: change.diff.isCoarse }));
  }
  return pages;
}
async function prepareReview($, kind) {
  if (view.advanced) return;
  await runAction($, 'Preparing changes for review…', async () => {
    if (kind === 'apply') {
      const disabled = disabledDependencies();
      if (disabled.length) throw new Error('Some assignments use a disabled provider. Enable that provider or change the assignments. ' + disabled.join('; '));
    }
    const request = kind === 'apply' ? { action: 'preview', configuration: view.draft, platforms: view.platforms }
      : { action: kind === 'restore' ? 'previewRestore' : 'previewUninstall' };
    const response = await helperCall($, request);
    view.preview = response.preview; view.pages = reviewPages(response.preview); view.page = 0; view.showDiff = false;
    view.more = false;
  });
}
async function applyReviewed($) {
  if (view.advanced || !view.preview) return;
  const preview = view.preview;
  await runAction($, preview.kind === 'apply' ? 'Applying reviewed changes…' : 'Restoring reviewed settings…', async () => {
    invalidateInspection();
    const response = await helperCall($, { action: preview.kind, previewID: preview.id });
    view.undoStack = []; view.redoStack = []; view.historyCurrent = draftSnapshot();
    resetReview();
    view.message = [response.result.message, ...(response.result.notes || []), 'Start a new chat to load the updated routing.'].join(' ');
    await loadState($, view.advanced);
  });
}

function renderWorker(elements, worker, platform) {
  const { Box, Text } = elements;
  if (worker.modelID === 'auto') return Box({ flexDirection: 'row', columnGap: 1, children: [Text({ bold: true, children: ['Auto'] }), Text({ dimColor: true, children: ['Current model'] })] });
  const model = modelFor(worker.modelID), identity = modelIdentity(model), provider = model?.platform;
  return Box({ flexDirection: 'column', children: [
    Box({ flexDirection: 'row', columnGap: 1, alignItems: 'center', children: [strengthMark(elements, model),
      Text({ color: identity.color, bold: true, wrap: 'wrap', children: [model?.label || worker.modelID] }),
    ] }),
    ...((provider && provider !== platform) || worker.effort?.mode !== 'auto' ? [Text({ wrap: 'wrap', children: [
      ...(provider && provider !== platform ? [Text({ color: PROVIDER_COLORS[provider], ...(elements.Svg ? { backgroundColor: provider === 'codex' ? '#638ad01a' : '#a17bc71a' } : {}), children: [' via ' + (provider === 'codex' ? 'Codex ' : 'Claude ')] })] : []),
      ...(worker.effort && worker.effort.mode !== 'auto' ? [Text({ dimColor: true, children: [(provider !== platform ? ' · ' : '') + effortLabel(worker.effort)] })] : []),
    ] })] : []),
    ...(provider && !view.platforms.includes(provider) ? [Text({ color: 'yellow', children: ['Provider disabled'] })] : []),
  ] });
}

function renderCell($, elements, platform, category) {
  const { Box, Text, Button } = elements;
  const route = routeFor(platform, category), key = platform + '-' + category;
  const changed = assignmentChanged(platform, category);
  if (view.advanced) return renderRouteEditor($, elements, platform, category);
  const children = route ? [route, ...(route.additionalAgents || [])].map(worker => renderWorker(elements, worker, platform)) : [Text({ dimColor: true, children: ['Unassigned'] })];
  if (changed) children.push(Box({ flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: [
    ...(changed && !view.busy ? [Box({ ...(elements.terminal ? {} : { borderStyle: 'round', borderColor: '#b3933d', paddingX: 1 }), children: [
      Button({ key: 'current-' + key, label: view.currentCell === key ? 'Changed ▴' : 'Changed ▾', plain: true,
        onPress: () => { view.currentCell = view.currentCell === key ? '' : key; $.ui.invalidate('ui.render'); } }),
    ] })] : []),
  ] }));
  return Box({ flexDirection: 'column', rowGap: 0, children });
}

function renderAssignmentDetails(elements, platform, category) {
  const { Box, Text } = elements;
  const current = currentAssignment(platform, category), observed = observedAssignment(platform, category);
  if (!current && !observed) return null;
  const label = TASKS.find(([id]) => id === category)[1];
  return Box({ flexDirection: 'column', borderStyle: 'round', borderColor: '#808080', borderDimColor: true, paddingX: 1, children: [
    ...(current ? [Text({ bold: true, children: [PLATFORM_NAMES[platform] + ' · current ' + label.toLowerCase()] }),
      Text({ wrap: 'wrap', children: [routeDescription(current.route)] }),
      Text({ dimColor: true, wrap: 'wrap', children: [current.source] })] : []),
    ...(observed ? [Text({ bold: true, children: [observed.label + ' preference'] }), Text({ wrap: 'wrap', children: [routeDescription(observed.route)] }),
      ...observed.route.evidence.map(source => Text({ dimColor: true, wrap: 'wrap', children: [source.path + (source.explanation ? ' · ' + source.explanation : '')] })),
      ...observed.route.uncertainties.map(note => Text({ dimColor: true, wrap: 'wrap', children: [note] }))] : []),
  ] });
}

function renderMatrix($, elements, event) {
  const { Box, Text } = elements;
  const platforms = ['codex', 'claude'].filter(platform => view.platforms.includes(platform));
  const columns = event.props.bodyColumns || 80, narrow = columns < 68;
  const labelWidth = Math.min(22, Math.max(16, Math.floor(columns * .25)));
  const cell = (children, width) => Box({ ...(width ? { width, flexShrink: 0 } : { flexGrow: 1, flexShrink: 1 }), paddingX: 1, flexDirection: 'column', children });
  const rows = [];
  if (!narrow) rows.push(Box({ flexDirection: 'row', paddingY: elements.terminal ? 0 : 1, children: [cell([Text({ dimColor: true, children: ['TASK'] })], labelWidth),
    ...platforms.map(platform => cell([Text({ bold: true, children: [Text({ color: PROVIDER_COLORS[platform], children: ['● '] }), PLATFORM_NAMES[platform]] })], Math.max(16, Math.floor((columns - labelWidth - 2) / platforms.length)))),
  ] }));
  TASKS.forEach(([category, label], index) => {
    const labelNode = Box({ flexDirection: 'row', columnGap: 1, alignItems: 'center', children: [taskIcon(elements, category), Text({ bold: true, wrap: 'wrap', children: [label] })] });
    const body = narrow ? [labelNode, ...platforms.map(platform => Box({ flexDirection: 'column', marginTop: 1, children: [
      Text({ color: PROVIDER_COLORS[platform], children: [PLATFORM_NAMES[platform]] }), renderCell($, elements, platform, category),
    ] }))] : [cell([labelNode], labelWidth), ...platforms.map(platform => cell([renderCell($, elements, platform, category)], Math.max(16, Math.floor((columns - labelWidth - 2) / platforms.length))))];
    rows.push(Box({ key: 'row-' + category, flexDirection: narrow ? 'column' : 'row', paddingY: elements.terminal ? 0 : 1,
      ...(event.surface !== 'terminal' && index % 2 === 0 ? { backgroundColor: '#8080800d' } : {}), children: body }));
    const currentPlatform = platforms.find(platform => view.currentCell === platform + '-' + category && assignmentChanged(platform, category));
    if (currentPlatform) rows.push(renderAssignmentDetails(elements, currentPlatform, category));
  });
  return Box({ key: 'assignment-table', flexDirection: 'column', borderStyle: 'round', borderColor: '#808080', borderDimColor: true, children: rows });
}

function renderRouteEditor($, elements, platform, task) {
  const { Box, Text, Button, Select } = elements;
  const redraw = () => $.ui.invalidate('ui.render'), route = routeFor(platform, task), key = platform + '-' + task;
  const baseline = routeIn(view.editSnapshot?.draft, platform, task), isEdited = !!baseline && routeKey(baseline) !== routeKey(route);
  const select = (suffix, label, value, options, update) => Select({ key: key + '-' + suffix, label, value, options,
    onSelect: value => { if (view.busy) return; update(value); edited(); redraw(); } });
  const options = values => values.map(value => ({ value, label: title(value) }));
  const models = catalog().filter(model => view.state.availablePlatforms.includes(model.platform) && view.platforms.includes(model.platform) && (task !== 'coordinator' || model.platform === platform));
  const modelOptions = [...(task === 'coordinator' ? [{ value: 'auto', label: 'Auto · Current model' }] : []), ...models.map(model => ({ value: model.id, label: `${model.label} · ${PLATFORM_NAMES[model.platform]}` }))];
  const availableOptions = id => modelOptions.some(option => option.value === id) ? modelOptions
    : [{ value: id, label: (modelFor(id)?.label || id) + ' · currently unavailable' }, ...modelOptions];
  const children = isEdited ? [Text({ color: '#6fb3b8', bold: true, children: ['Edited'] })] : [];
  [route, ...(route.additionalAgents || [])].forEach((worker, index) => {
    const prefix = 'member-' + index, selectedModel = modelFor(worker.modelID);
    const supported = LEVELS.filter(level => (selectedModel?.supportedEfforts || LEVELS).includes(level) && (selectedModel?.platform !== 'claude' || level !== 'ultra') && !(platform === 'claude' && task === 'coordinator' && level === 'max'));
    const effortOptions = value => supported.includes(value) ? options(supported) : [{ value, label: title(value) + ' · unsupported' }, ...options(supported)];
    const fields = [select(prefix + '-model', task === 'coordinator' ? 'Model' : route.teamMode === 'leadReview' ? index === 0 ? 'Lead' : `Reviewer ${index}` : `Worker ${index + 1}`, worker.modelID, availableOptions(worker.modelID),
      value => { worker.modelID = value; if (index > 0) worker.modelPlatform = modelFor(value)?.platform; worker.effort = autoEffort(); }),
      ...(isAutoController(route) ? [] : [select(prefix + '-effort', 'Effort', worker.effort.mode, [{ value: 'auto', label: 'Auto' }, { value: 'fixed', label: 'Fixed' }, { value: 'range', label: 'Range' }],
        value => { worker.effort.mode = value; worker.effort.value = supported.includes(worker.effort.value) ? worker.effort.value : supported[supported.length - 1]; worker.effort.minimum = supported[0]; worker.effort.maximum = supported[supported.length - 1]; })]),
    ];
    if (!isAutoController(route) && worker.effort.mode === 'fixed') fields.push(select(prefix + '-level', 'Level', worker.effort.value, effortOptions(worker.effort.value), value => { if (supported.includes(value)) worker.effort.value = value; }));
    if (!isAutoController(route) && worker.effort.mode === 'range') {
      fields.push(select(prefix + '-minimum', 'Min', worker.effort.minimum, effortOptions(worker.effort.minimum), value => { if (!supported.includes(value)) return; worker.effort.minimum = value; if (LEVELS.indexOf(value) > LEVELS.indexOf(worker.effort.maximum)) worker.effort.maximum = value; }));
      fields.push(select(prefix + '-maximum', 'Max', worker.effort.maximum, effortOptions(worker.effort.maximum), value => { if (!supported.includes(value)) return; worker.effort.maximum = value; if (LEVELS.indexOf(value) < LEVELS.indexOf(worker.effort.minimum)) worker.effort.minimum = value; }));
    }
    if (index > 0) fields.push(Button({ key: key + '-' + prefix + '-remove', label: 'Remove', plain: true, onPress: () => {
      if (view.busy) return; route.additionalAgents.splice(index - 1, 1); edited(); redraw();
    } }));
    children.push(Box({ flexDirection: 'column', flexWrap: 'wrap', columnGap: 1, children: fields }));
  });
  if (task !== 'coordinator') {
    if (route.additionalAgents.length < 3) children.push(Button({ key: key + '-add-worker', label: '+ Worker', plain: true, onPress: () => {
      if (view.busy || !models.length || route.additionalAgents.length >= 3) return;
      const id = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, char => { const value = Math.floor(Math.random() * 16); return (char === 'x' ? value : (value & 3) | 8).toString(16); });
      route.additionalAgents.push({ id, modelID: models[0].id, modelPlatform: models[0].platform, effort: autoEffort() }); edited(); redraw();
    } }));
    if (route.additionalAgents.length) {
      children.push(select('team-mode', 'Team mode', route.teamMode || 'parallel', [{ value: 'leadReview', label: 'Lead + review' }, { value: 'parallel', label: 'Independent passes' }], value => { if (['leadReview', 'parallel'].includes(value)) route.teamMode = value; }));
      children.push(select('result-mode', 'Results', route.resultMode, [{ value: 'coordinator', label: 'Controller combines' }, { value: 'user', label: 'You choose' }, { value: 'ai', label: 'Judge compares' }],
        value => { route.resultMode = value; if (value === 'ai' && !route.judgeModelID) route.judgeModelID = route.modelID; }));
      if (route.resultMode === 'ai') children.push(select('judge-model', 'Judge', route.judgeModelID, availableOptions(route.judgeModelID), value => { route.judgeModelID = value; }));
    }
  }
  return Box({ key: 'editor-' + key, ...(isEdited ? { borderStyle: 'round', borderColor: '#6fb3b8', paddingX: 1 } : {}), flexDirection: 'column', rowGap: 1, children });
}

function renderPresets($, elements, columns) {
  const { Box, Text, Button, Select, Input } = elements, redraw = () => $.ui.invalidate('ui.render');
  const cards = view.state.presets.map(preset => Box({ key: 'card-' + preset.id, flexGrow: 1, flexShrink: 1, flexDirection: 'column', paddingX: 1,
    borderStyle: 'round', borderColor: view.preset === preset.id ? '#638ad0' : '#808080', borderDimColor: view.preset !== preset.id, children: [
      Button({ key: 'preset-' + preset.id, label: (view.preset === preset.id ? '✓ ' : '') + title(preset.id), variant: view.preset === preset.id ? 'primary' : 'secondary',
        hotkey: preset.id === 'fast' ? '1' : preset.id === 'optimized' ? '2' : '3', onPress: () => { if (view.busy) return; chooseConfiguration(preset.configuration, preset.id); redraw(); } }),
      Text({ dimColor: true, wrap: 'wrap', children: [PRESET_DETAILS[preset.id] || 'Saved mix'] }),
    ] }));
  const children = [Box({ flexDirection: columns < 44 ? 'column' : 'row', columnGap: 1, children: cards })];
  const saved = view.state.savedPresets || [];
  children.push(Box({ flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: [
    ...(saved.length ? [Select({ key: 'saved-presets', label: 'Saved', value: view.savedID || '', options: [{ value: '', label: 'Choose a saved preset' }, ...saved.map(preset => ({ value: preset.id, label: preset.name }))],
      onSelect: async id => { if (view.busy) return; const preset = saved.find(value => value.id === id); if (preset) { const platforms = [...view.platforms].sort().join(); chooseConfiguration(preset.configuration, null, id); redraw(); if (platforms !== [...view.platforms].sort().join()) await runAction($, 'Refreshing providers…', async () => { await loadState($, true); }); } } })] : []),
    ...(!view.advanced ? [Button({ key: 'save-preset', label: 'Save as…', plain: true, onPress: () => { if (view.busy) return; view.savePanel = !view.savePanel; view.presetName = saved.find(preset => preset.id === view.savedID)?.name || ''; redraw(); } })] : []),
    ...(view.savedID && !view.advanced ? [Button({ key: 'delete-preset', label: 'Delete', plain: true, dimColor: true, onPress: () => { if (view.busy) return; view.deletePending = !view.deletePending; redraw(); } })] : []),
    ...(view.state.previousDraft ? [Button({ key: 'previous-draft', label: 'Previous draft', plain: true, dimColor: true, onPress: async () => { if (view.busy) return; const platforms = [...view.platforms].sort().join(); chooseConfiguration(view.state.previousDraft); redraw(); if (platforms !== [...view.platforms].sort().join()) await runAction($, 'Refreshing providers…', async () => { await loadState($, true); }); } })] : []),
    ...(!view.preset ? [Text({ dimColor: true, children: [view.savedID ? saved.find(preset => preset.id === view.savedID)?.name || 'Saved preset' : 'Custom mix'] })] : []),
  ] }));
  if (view.savePanel) children.push(Box({ borderStyle: 'round', borderColor: '#808080', borderDimColor: true, paddingX: 1, flexDirection: 'column', children: [
    Input({ key: 'preset-name', label: 'Preset name', value: view.presetName, placeholder: 'My team', submitLabel: 'save', onInput: value => { view.presetName = value; }, onSubmit: async value => { view.presetName = value; await savePreset($); } }),
    Button({ key: 'confirm-save-preset', label: 'Save preset', onPress: async () => { await savePreset($); } }),
  ] }));
  if (view.deletePending) children.push(Box({ flexDirection: 'row', columnGap: 1, flexWrap: 'wrap', children: [Text({ children: ['Delete this saved preset?'] }),
    Button({ key: 'confirm-delete-preset', label: 'Delete preset', onPress: async () => { await runAction($, 'Deleting preset…', async () => {
      const response = await helperCall($, { action: 'deletePreset', presetID: view.savedID }); view.state = response.state; view.savedID = ''; view.deletePending = false; view.message = 'Preset deleted'; resetReview();
    }); } }), Button({ key: 'cancel-delete-preset', label: 'Cancel', plain: true, onPress: () => { view.deletePending = false; redraw(); } }),
  ] }));
  return Box({ flexDirection: 'column', rowGap: elements.terminal ? 0 : 1, children });
}

function renderConnections($, elements) {
  const { Box, Text, Button } = elements;
  const children = [Text({ bold: true, children: ['Connections & sources'] })];
  for (const platform of ['codex', 'claude']) {
    const connection = view.state.connections.find(item => item.platform === platform);
    const native = view.state.nativeSettings?.find(item => item.platform === platform);
    children.push(Box({ flexDirection: 'column', borderStyle: 'round', borderColor: PROVIDER_COLORS[platform], paddingX: 1, children: [
      Button({ key: 'provider-' + platform, label: `${view.platforms.includes(platform) ? '✓ ' : ''}${PLATFORM_NAMES[platform]}${view.state.availablePlatforms.includes(platform) ? '' : ' · not detected'}`, onPress: async () => { await toggleProvider($, platform); } }),
      Text({ dimColor: true, wrap: 'wrap', children: [connection?.version || connection?.detail || 'Not detected'] }),
      ...(connection?.path ? [Text({ wrap: 'wrap', children: [connection.path] })] : []),
      ...(connection?.compatibilityWarning ? [Text({ color: 'yellow', wrap: 'wrap', children: [connection.compatibilityWarning] })] : []),
      ...renderCLIAccount(elements, platform),
      ...(native ? [Text({ dimColor: true, wrap: 'wrap', children: [native.status === 'known' ? 'Saved global default: ' + (native.modelID || 'Unset') + (native.effort ? ' · ' + title(native.effort) : '') : native.detail] }), Text({ dimColor: true, wrap: 'wrap', children: [native.sourcePath] })] : []),
    ] }));
  }
  children.push(view.checkingAccounts ? Text({ dimColor: true, children: ['Checking CLI accounts…'] })
    : Button({ key: 'check-accounts', label: 'Check CLI accounts', plain: true, onPress: async () => { await checkAccounts($); } }));
  children.push(Text({ dimColor: true, wrap: 'wrap', children: ['Reads public CLI sign-in status without model calls. StandMixer does not switch accounts or log you out.'] }));
  if (view.accountError) children.push(Text({ color: 'yellow', wrap: 'wrap', children: [view.accountError] }));
  children.push(Text({ dimColor: true, wrap: 'wrap', children: ['CLI detection does not verify model access. Saved global defaults can be overridden in a chat or project.'] }));
  children.push(Button({ key: 'refresh', label: 'Refresh connections', onPress: async () => { await runAction($, 'Refreshing…', async () => { await loadState($, true); }); } }));
  if (view.preferenceWarning) children.push(Text({ color: 'yellow', wrap: 'wrap', children: ['Preferences unavailable: ' + view.preferenceWarning] }));
  children.push(Text({ dimColor: true, wrap: 'wrap', children: ['Reading preferences uses the selected CLIs’ quick models and account allowance.'] }));
  if (!view.readingPreferences) children.push(Button({ key: 'refresh-preferences', label: view.state.inspection ? 'Read preferences again' : 'Read preferences', plain: true, onPress: async () => { await inspectPreferences($, true); } }));
  if (view.state.inspection) {
    children.push(Text({ bold: true, children: ['Current & usual preferences'] }));
    for (const report of view.state.inspection.reports) {
      children.push(Text({ wrap: 'wrap', children: [PLATFORM_NAMES[report.platform] + ' · ' + (report.summary || report.status)] }));
      if (report.error) children.push(Text({ dimColor: true, wrap: 'wrap', children: [report.error] }));
      for (const source of report.sources || []) children.push(Text({ dimColor: true, wrap: 'wrap', children: [source.path + (source.explanation ? ' · ' + source.explanation : '')] }));
      for (const note of report.notes || []) children.push(Text({ dimColor: true, wrap: 'wrap', children: [note] }));
      for (const route of report.routes || []) {
        for (const source of route.evidence || []) children.push(Text({ dimColor: true, wrap: 'wrap', children: [source.path + (source.explanation ? ' · ' + source.explanation : '')] }));
        for (const note of route.uncertainties || []) children.push(Text({ dimColor: true, wrap: 'wrap', children: [note] }));
      }
    }
  }
  for (const note of view.state.notes || []) children.push(Text({ dimColor: true, wrap: 'wrap', children: [note] }));
  children.push(view.installingMac ? Text({ key: 'install-mac-progress', dimColor: true, children: ['Building Mac app…'] })
    : Button({ key: 'install-mac', label: view.state.installedMac?.isAvailable ? 'Open Mac app' : 'Install Mac app', plain: true, onPress: async () => { if (view.state.installedMac?.isAvailable) await openInterface($, 'mac'); else await installMac($); } }));
  if (view.macInstallMessage && !view.installingMac) children.push(Text({ dimColor: !view.macInstallError, ...(view.macInstallError ? { color: 'yellow' } : {}), wrap: 'wrap', children: [view.macInstallMessage] }));
  children.push(Text({ dimColor: true, wrap: 'wrap', children: ['Optional local source build; requires Apple developer tools. Settings remain usable while it builds.'] }));
  if (view.state.canRestore && !view.advanced) children.push(Button({ key: 'restore', label: 'Restore applied settings…', plain: true, onPress: async () => { await prepareReview($, 'restore'); } }));
  if (view.state.installation.hasInstallation && !view.advanced) children.push(Button({ key: 'uninstall', label: 'Remove StandMixer settings…', plain: true, onPress: async () => { await prepareReview($, 'uninstall'); } }));
  children.push(Text({ dimColor: true, wrap: 'wrap', children: ['Manage the plugin in /plugin. Recovery backups are retained.'] }));
  return Box({ flexDirection: 'column', rowGap: 1, children });
}

function customModelUsed(id) {
  return view.draft.profiles.some(profile => profile.routes.some(route => route.modelID === id || route.additionalAgents.some(worker => worker.modelID === id) || (route.resultMode === 'ai' && route.judgeModelID === id)));
}
function renderCustomModels($, elements) {
  const { Box, Text, Button, Select, Input } = elements, redraw = () => $.ui.invalidate('ui.render');
  const add = () => {
    if (view.busy) return;
    const id = view.customID.trim(), label = view.customLabel.trim();
    if (id === 'auto') { view.error = 'Auto is reserved for the Controller setting.'; redraw(); return; }
    if (!id || !label || !view.customEfforts.length) { view.error = 'Enter a model ID, label, and at least one supported effort.'; redraw(); return; }
    if (catalog().some(model => model.id === id)) { view.error = 'This model ID is already in the catalog.'; redraw(); return; }
    if (/[\r\n\0]/.test(id + label)) { view.error = 'Model IDs and labels must be a single line.'; redraw(); return; }
    view.draft.customModels.push({ id, label, platform: view.customPlatform, supportedEfforts: LEVELS.filter(level => view.customEfforts.includes(level)), isDiscovered: false });
    view.customID = ''; view.customLabel = ''; edited(); redraw();
  };
  const children = [Text({ bold: true, children: ['Custom models'] })];
  for (const model of view.draft.customModels || []) children.push(Box({ flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: [
    Text({ children: [model.label + ' · ' + PLATFORM_NAMES[model.platform]] }),
    Text({ dimColor: true, wrap: 'wrap', children: [model.id] }),
    ...(customModelUsed(model.id) ? [Text({ dimColor: true, children: ['In use'] })] : [Button({ key: 'remove-custom-' + model.id, label: 'Remove', plain: true, onPress: () => { if (view.busy) return; view.draft.customModels = view.draft.customModels.filter(item => item.id !== model.id); edited(); redraw(); } })]),
  ] }));
  const field = (key, label, property) => Input({ key, label, value: view[property], onInput: value => { view[property] = value; }, onSubmit: value => { view[property] = value; redraw(); } });
  children.push(field('custom-model-id', 'Model ID', 'customID'), field('custom-model-label', 'Label', 'customLabel'));
  children.push(Select({ key: 'custom-model-provider', label: 'Provider', value: view.customPlatform, options: ['codex', 'claude'].map(value => ({ value, label: PLATFORM_NAMES[value] })), onSelect: value => { view.customPlatform = value; if (value === 'claude') view.customEfforts = view.customEfforts.filter(level => level !== 'ultra'); redraw(); } }));
  children.push(Text({ dimColor: true, children: ['Supported efforts'] }));
  children.push(Box({ flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: LEVELS.filter(level => view.customPlatform !== 'claude' || level !== 'ultra').map(level => Button({ key: 'custom-effort-' + level, label: (view.customEfforts.includes(level) ? '✓ ' : '') + title(level), plain: true, onPress: () => { view.customEfforts = view.customEfforts.includes(level) ? view.customEfforts.filter(value => value !== level) : [...view.customEfforts, level]; redraw(); } })) }));
  children.push(Button({ key: 'add-custom-model', label: 'Add model to draft', onPress: add }));
  return Box({ borderStyle: 'round', borderColor: '#808080', borderDimColor: true, paddingX: 1, flexDirection: 'column', rowGap: 1, children });
}

function renderReview($, elements) {
  const { Box, Text, Button, Code, Select } = elements;
  const preview = view.preview;
  const page = view.pages[view.page];
  const label = preview.kind === 'uninstall' ? 'Remove StandMixer settings' : preview.kind === 'restore' ? 'Restore previous settings' : 'Review changes';
  const changes = preview.changes.filter(change => change.isChanged);
  const native = changes.filter(change => /\/(config\.toml|settings\.json)$/.test(change.path));
  const workers = changes.filter(change => change.reason.startsWith('Shared worker:'));
  const routing = changes.filter(change => change.reason.includes('routing'));
  const otherCount = changes.length - native.length - workers.length - routing.length;
  const children = [Text({ bold: true, children: [label] }),
    Text({ dimColor: true, wrap: 'wrap', children: [[`${preview.changedFiles} changed files`,
      ...(workers.length ? [`${workers.length} shared workers`] : []),
      ...(routing.length ? [`${routing.length} routing files`] : []),
      ...(otherCount > 0 ? [`${otherCount} integration files`] : []),
    ].join(' · ')] }),
    ...preview.conflicts.map(conflict => Text({ color: 'yellow', wrap: 'wrap', children: [conflict] })),
  ];
  if (!view.busy) {
    children.push(Box({ flexDirection: 'row', columnGap: 1, children: [
      Button({ key: 'review-back', label: 'Back to settings', hotkey: 'b', onPress: () => { resetReview(); $.ui.invalidate('ui.render'); } }),
      ...(page ? [Button({ key: 'show-diff', label: view.showDiff ? 'Hide file details' : 'Full file diff', hotkey: 'd', onPress: () => { view.showDiff = !view.showDiff; $.ui.invalidate('ui.render'); } })] : []),
    ] }));
    if (preview.changedFiles > 0 || (preview.kind === 'uninstall' && preview.hasInstallation)) children.push(Button({
      key: 'apply-reviewed', label: preview.kind === 'apply' ? 'Apply reviewed changes' : preview.kind === 'restore' ? 'Restore reviewed changes' : 'Remove reviewed settings',
      variant: 'primary', hotkey: 'a', onPress: async () => { await applyReviewed($); },
    }));
  }
  if (preview.kind === 'apply') {
    for (const platform of view.platforms) {
      const rows = TASKS.filter(([task]) => !currentAssignment(platform, task) || assignmentChanged(platform, task));
      if (!rows.length) continue;
      children.push(Box({ borderStyle: 'round', borderColor: PROVIDER_COLORS[platform], paddingX: 1, flexDirection: 'column', children: [
        Text({ bold: true, children: [PLATFORM_NAMES[platform]] }),
        ...rows.map(([task, name]) => {
          const current = currentAssignment(platform, task);
          return Box({ flexDirection: 'column', marginBottom: 1, children: [
            Text({ bold: true, children: [name] }),
            ...(current ? [Text({ dimColor: true, wrap: 'wrap', children: ['Current: ' + routeDescription(current.route)] })] : []),
            Text({ wrap: 'wrap', children: [(current ? 'To: ' : 'Set: ') + routeDescription(routeFor(platform, task))] }),
          ] });
        }),
      ] }));
    }
  }
  // Native default changes are the compact first review. Generated routing and
  // workers remain available in the full file picker below.
  for (const change of native) {
    const changedLines = change.diff.hunks.flatMap(hunk => hunk.lines)
      .filter(line => line.kind !== 'context')
      .map(line => (line.kind === 'addition' ? '+' : '-') + line.text);
    const source = changedLines.join('\n');
    children.push(Text({ bold: true, wrap: 'wrap', children: [change.path] }));
    if (source.length < 10000 && changedLines.length <= 16) children.push(Code({ source, format: 'diff', wrap: 'wrap' }));
    else children.push(Text({ dimColor: true, children: [`+${change.diff.addedLineCount} −${change.diff.removedLineCount} lines · see full diff`] }));
  }
  if (!changes.length) children.push(Text({ children: ['No file contents need changing.'] }));
  if (view.showDiff && page) {
    children.push(Select({ key: 'review-file', label: 'File', value: page.path,
      options: changes.map(change => ({ value: change.path, label: change.path })),
      onSelect: value => { if (!view.busy) { view.page = view.pages.findIndex(part => part.path === value); $.ui.invalidate('ui.render'); } },
    }));
    children.push(Text({ dimColor: true, wrap: 'wrap', children: [page.reason + ` · +${page.added} −${page.removed}${page.parts > 1 ? ` · part ${page.part}/${page.parts}` : ''}`] }));
    if (page.isCoarse) children.push(Text({ dimColor: true, children: ['Large file: complete replacement shown.'] }));
    children.push(Code({ source: page.source, format: 'diff', wrap: 'wrap' }));
    if (!view.busy) children.push(Box({ flexDirection: 'row', columnGap: 1, children: [
      ...(view.page > 0 ? [Button({ key: 'review-previous', label: 'Previous', hotkey: 'p', onPress: () => { view.page--; $.ui.invalidate('ui.render'); } })] : []),
      ...(view.page + 1 < view.pages.length ? [Button({ key: 'review-next', label: 'Next', hotkey: 'n', onPress: () => { view.page++; $.ui.invalidate('ui.render'); } })] : []),
    ] }));
  }
  return Box({ flexDirection: 'column', rowGap: 1, children });
}

function renderSettings($, event) {
  const resolved = $.ui.resolve(event);
  // Some terminal hosts expose an Svg factory even though they cannot paint it.
  // Surface identity, not the factory's presence, selects the text fallback.
  const elements = { ...resolved, terminal: event.surface === 'terminal', ...(event.surface === 'terminal' ? { Svg: undefined } : {}) };
  const { Box, Text, Button } = elements;
  const installation = view.state?.installation;
  let status = 'No preset applied';
  if (installation?.hasInstallation) {
    if (installation.state === 'applied') {
      const preset = matchedPreset(installation.appliedConfiguration, installation.installedPlatforms, view.state.presets);
      const saved = view.state.savedPresets.find(item => recipeKey(item.configuration, installation.installedPlatforms) === recipeKey(installation.appliedConfiguration, installation.installedPlatforms));
      status = installation.appliedConfiguration ? 'Applied · ' + (preset ? title(preset) : saved?.name || 'Custom') : 'Applied';
    } else status = installation.state === 'drifted' ? 'Settings changed outside StandMixer' : 'Installation needs review';
  }
  const children = [Box({ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', columnGap: 1, children: [
    Box({ flexDirection: 'row', alignItems: 'center', columnGap: 1, children: [...(elements.Svg ? [brandMark(elements)] : []), Text({ bold: true, children: ['StandMixer'] })] }),
    Box({ flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap', columnGap: 1, children: [
      ...(view.state ? [Box({ key: 'interfaces-control', ...(elements.terminal ? {} : { borderStyle: 'round', borderColor: '#6FB3B8', paddingX: 1 }), children: [Button({ key: 'interfaces', label: view.interfaces ? 'Interface ▴' : 'Interface ▾', variant: 'secondary', onPress: () => { view.interfaces = !view.interfaces; $.ui.invalidate('ui.render'); } })] })] : []),
      ...(view.state ? [Box({ ...(elements.terminal ? {} : { borderStyle: 'round', borderColor: installation?.state === 'applied' ? '#4b9b72' : '#808080', borderDimColor: installation?.state !== 'applied' }), paddingX: 1, children: [Text({ dimColor: installation?.state !== 'applied', children: [status] })] })] : []),
      ...(view.state && view.undoStack.length ? [Button({ key: 'undo-draft', label: 'Undo', variant: 'secondary', dimColor: !!view.busy, onPress: async () => { await travelDraft($); } })] : []),
      ...(view.state && view.redoStack.length ? [Button({ key: 'redo-draft', label: 'Redo', plain: true, dimColor: !!view.busy, onPress: async () => { await travelDraft($, true); } })] : []),
      ...(view.state && !view.busy ? (view.advanced ? [Button({ key: 'cancel-edit', label: 'Cancel', plain: true, onPress: () => { cancelEdit($); } }), Button({ key: 'save-edit', label: 'Save', variant: 'primary', onPress: async () => { await saveEdit($); } })] : [Button({ key: 'edit', label: 'Edit…', plain: true, onPress: () => { beginEdit($); } })]) : []),
    ] }),
  ] })];
  if (view.interfaces && view.state) children.push(renderInterfaces($, elements));
  if (view.updateInfo) children.push(Text({ color: '#6FB3B8', wrap: 'wrap', children: ['Update ' + view.updateInfo.latestVersion + ' available · /standmixer update'] }));
  if (view.busy) children.push(Text({ color: '#638ad0', children: [view.busy] }));
  if (view.readingPreferences) children.push(Text({ dimColor: true, children: ['Reading current preferences…'] }));
  if (view.error) children.push(Text({ color: 'red', wrap: 'wrap', children: [view.error] }));
  if (view.message) children.push(Text({ color: 'green', wrap: 'wrap', children: [view.message] }));
  if (!view.state) {
    if (!view.busy) children.push(Button({ key: 'retry', label: 'Retry', onPress: async () => { await runAction($, 'Reading current settings…', async () => { await loadState($); }); } }));
    return Box({ flexDirection: 'column', rowGap: elements.terminal ? 0 : 1, children });
  }
  if (view.preview) children.push(renderReview($, elements));
  else {
    children.push(renderPresets($, elements, event.props.bodyColumns || 80));
    if (!view.busy) children.push(Box({ flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: [
      ...(view.platforms.length && !view.advanced ? [Button({ key: 'review', label: 'Review changes', variant: 'primary', hotkey: 'r', onPress: async () => { await prepareReview($, 'apply'); } })] : []),
      Button({ key: 'more', label: view.more ? 'Hide connections' : 'Connections', hotkey: 'm', plain: true, onPress: () => { view.more = !view.more; $.ui.invalidate('ui.render'); } }),
    ] }));
    if (view.platforms.length) children.push(renderMatrix($, elements, event));
    else children.push(Text({ color: 'yellow', children: ['Install Codex or Claude Code to configure a team.'] }));
    if (view.advanced && !view.busy) {
      children.push(Box({ flexDirection: 'row', flexWrap: 'wrap', columnGap: 1, children: [
        Button({ key: 'custom-models', label: view.customPanel ? 'Hide custom models' : 'Custom models…', plain: true, onPress: () => { view.customPanel = !view.customPanel; $.ui.invalidate('ui.render'); } }),
      ] }));
      if (view.customPanel) children.push(renderCustomModels($, elements));
    }
    if (view.more && !view.busy) children.push(renderConnections($, elements));
  }
  children.push(Button({ key: 'close', label: 'Close', role: 'dismiss', plain: true, onPress: async () => { await $.ui.close({ id: PANE }); } }));
  return Box({ flexDirection: 'column', rowGap: elements.terminal ? 0 : 1, children });
}

async function runCommand($, event) {
    // Routing arguments only select a view or prepare review. Software updates
    // are separate, explicit commands and never apply a routing preset.
    const words = (event.args || '').trim().toLowerCase().split(/\s+/), action = words[0];
    if (action === 'update') {
      if (words.length > 2 || (words.length === 2 && words[1] !== '--mac')) return { text: 'Use /standmixer update, or /standmixer update --mac to also rebuild the Mac app.' };
      if (view.busy || view.installingMac) return { text: 'Another StandMixer operation is still running. Wait for it to finish before updating.' };
      const withMac = words[1] === '--mac';
      view.error = ''; view.message = ''; resetReview();
      view.busy = withMac ? 'Updating StandMixer and the Mac app…' : 'Updating StandMixer…';
      $.ui.invalidate('ui.render');
      try {
        const result = await $.process.run(['/bin/sh', '-c', 'exec "$HOME/Library/Application Support/AgentMix/bin/standmixer" update "$@"', 'standmixer-update', ...(withMac ? ['--mac'] : [])], { timeoutMs: 600000 });
        const output = [result.stdout, result.stderr].filter(Boolean).join('\n').trim();
        const message = result.exitCode === 0
          ? 'StandMixer updated. Presets and model defaults were kept. Run /reload-plugins to load the update.' + (withMac ? ' Reopen the Mac app to use its updated build.' : '')
          : 'StandMixer update did not complete.\n' + (output.slice(-6000) || 'Check the installed launcher and retry.');
        if (result.exitCode === 0) view.message = message; else view.error = message;
        return { text: message };
      } catch (error) {
        const message = 'StandMixer update did not complete: ' + (error.message || String(error));
        view.error = message; return { text: message };
      } finally { view.busy = ''; $.ui.invalidate('ui.render'); }
    }
    if (action === 'help') return { text: '/standmixer opens settings. Use fast, optimized, or high to preview a preset; uninstall to review removal; restore to review the last backup; web to open in your browser; mac to open the installed Mac app; install-mac to build it locally; update to refresh plugins and source, or update --mac to also rebuild the app. Apply changes with the button in the pane.' };
    if (!['', 'status', 'settings', 'fast', 'optimized', 'high', 'uninstall', 'restore', 'install-mac', 'web', 'mac'].includes(action)) {
      return { text: 'Use /standmixer to open settings, or /standmixer help for commands.' };
    }
    await openSettings($, false);
    if (view.error || !view.state || view.busy) return {};
    if (action === 'web' || action === 'mac') { view.interfaces = true; await openInterface($, action); }
    else if (action === 'install-mac') { view.more = true; await installMac($); }
    else if (action === 'uninstall' || action === 'restore') await prepareReview($, action);
    else if (['fast', 'optimized', 'high'].includes(action)) {
      const preset = view.state.presets.find(preset => preset.id === action);
      if (preset) {
        chooseConfiguration(preset.configuration, preset.id);
        await prepareReview($, 'apply');
      }
    }
    return {};
  }

export function register(on) {
  view = freshView();
  on('session.start', async ($, event, next) => {
    await $.command.register({ name: 'standmixer', description: 'Choose and customize StandMixer teams for Claude Code and Codex', immediate: true });
    if (event.surface && ['terminal', 'desktop', 'vscode'].includes(event.surface) && !(await $.store.get(OPENED))) await openSettings($, true);
    return next(event);
  });
  on('session.attach', async ($, event, next) => {
    if (['desktop', 'vscode'].includes(event.surface) && !(await $.store.get(OPENED))) await openSettings($, true);
    return next(event);
  });
  on('command.run', { command: 'standmixer' }, runCommand);
  on('ui.render', { component: 'AbovePrompt' }, async ($, event, next) => {
    const existing = await next(event);
    if (!view.onboardingPending || view.busy || !(event.props.bodyColumns > 0)) return existing;
    // The first session hook can run before the prompt has a measured viewport.
    // Retry once when it does. Native terminal policy requires 144 columns for
    // a pane opened automatically; a user-pressed button works at any width.
    const canPlace = event.surface !== 'terminal' || event.viewport?.columns >= 144;
    if (canPlace && !view.onboardingRetried) await retryOnboarding($);
    if (!view.onboardingPending) return existing;
    const { Box, Button } = $.ui.resolve(event);
    return Box({ flexDirection: 'column', children: [existing,
      Button({ key: 'open-agentmix', label: 'Open StandMixer', onPress: async () => { await openSettings($, false); } }),
    ] });
  });
  on('ui.render', { component: 'Pane' }, async ($, event, next) => {
    if (event.requestId !== PANE) return next(event);
    return renderSettings($, event);
  });
}
