export const modelCatalog = [
  ['gpt-6.1-sol', 'Sol 6.1', 'codex'], ['gpt-6-astra', 'Astra 6', 'codex'],
  ['gpt-6-luna', 'Luna 6', 'codex'], ['gpt-6.1-terra', 'Terra 6.1', 'codex'], ['claude-sonnet-5-5', 'Sonnet 5.5', 'claude'], ['claude-opus-5-5', 'Opus 5.5', 'claude'],
  ['claude-fable-5-1', 'Fable 5.1', 'claude'], ['claude-haiku-5-5', 'Haiku 5.5', 'claude'],
].map(([id, label, platform]) => ({ id, label, platform, supportedEfforts: ['low', 'medium', 'high', 'xhigh', 'max'] }));
const categories = ['coordinator', 'planning', 'ui', 'implementation', 'algorithms', 'review', 'mechanical'];
export const auto = { mode: 'auto', value: 'high', minimum: 'low', maximum: 'high' };
export function configuration(high = false, platforms = ['codex', 'claude']) {
  return { customModels: [], enabledPlatforms: platforms, profiles: ['codex', 'claude'].map(platform => ({
    platform, routes: categories.map((category, index) => ({
      category, modelID: category === 'coordinator' ? 'auto' : platform === 'codex' ? 'gpt-6.1-sol'
        : category === 'implementation' ? platforms.length === 1 ? 'claude-fable-5-1' : 'gpt-6.1-sol' : 'claude-opus-5-5', effort: { ...auto },
      additionalAgents: high && category === 'ui' ? [
        { id: `00000000-0000-4000-8000-00000000000${index}`, modelID: platforms.length === 1 && platform === 'claude' ? 'claude-fable-5-1' : 'gpt-6-astra', effort: { ...auto } },
        { id: `00000000-0000-4000-8000-00000000010${index}`, modelID: platforms.length === 1 && platform === 'codex' ? 'gpt-6-astra' : 'claude-fable-5-1', effort: { ...auto } },
      ] : [], resultMode: 'coordinator',
    })),
  })) };
}
export function state(platforms = ['codex', 'claude']) {
  const presets = ['fast', 'optimized', 'high'].map(id => ({ id, title: 'StandMixer ' + id, configuration: configuration(id === 'high', platforms) }));
  for (const profile of presets[0].configuration.profiles) profile.routes.find(route => route.category === 'mechanical').modelID = profile.platform === 'codex' ? 'gpt-6-luna' : 'claude-haiku-5-5';
  return { configuration: configuration(false, platforms), enabledPlatforms: platforms,
    availablePlatforms: ['codex', 'claude'], catalog: modelCatalog, hasSavedDraft: false,
    presets,
    installation: { state: 'notInstalled', summary: 'Nothing applied', hasInstallation: false, installedPlatforms: [] },
    canRestore: false, notes: [], connections: [], savedPresets: [], nativeSettings: [], inspection: { createdAt: '2026-11-02T00:00:00Z', expiresAt: '2026-11-02T00:15:00Z', reports: [], fromCache: true },
  };
}
export function preview(lines = 2, kind = 'apply') {
  return { id: 'reviewed-exact-id', kind, changedFiles: 1, conflicts: [], hasInstallation: true,
    changes: [{ path: '/fixture/.codex/config.toml', reason: 'Update native model', isChanged: true, isDeletion: false,
      before: 'model = "old"\n', after: 'model = "new"\n', diff: {
        hunks: [{ oldStart: 1, oldCount: 1, newStart: 1, newCount: lines,
          lines: Array.from({ length: lines }, (_, index) => ({ kind: index === 0 ? 'removal' : 'addition', text: `model-line-${index}` })) }],
        addedLineCount: lines - 1, removedLineCount: 1, isCoarse: false, isUnchanged: false, hasFinalNewlineChange: false,
      } }],
  };
}
export const pane = {
  plugin: 'standmixer', component: 'Pane', requestId: 'standmixer',
  viewport: { columns: 160, rows: 50, isFullscreen: true },
  props: { title: 'StandMixer', isFocused: true, bodyColumns: 80, placement: 'inline',
    scroll: { offset: 0, bodyRows: 34 }, view: {} },
};
