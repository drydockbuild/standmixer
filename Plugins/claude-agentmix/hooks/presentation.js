// Native presentation helpers: recipe identity excludes worker UUIDs and unused effort fields.
export const TASKS = [
  ['coordinator', 'Controller', '◎'], ['planning', 'Planning', '↗'], ['ui', 'Visual', '▣'],
  ['implementation', 'Implementation', '‹›'], ['algorithms', 'Algorithms', '◇'],
  ['review', 'Review & Security', '✓'], ['mechanical', 'Mechanical work', '⌁'],
];
export const PLATFORM_NAMES = { codex: 'Codex', claude: 'Claude Code' };
export const PROVIDER_COLORS = { codex: '#638ad0', claude: '#a17bc7' };
export const PRESET_DETAILS = { fast: 'Lightweight', optimized: 'Matched to the task', high: 'Multiple agents' };
export const LEVELS = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
export const title = value => value ? value.charAt(0).toUpperCase() + value.slice(1) : '';
export function effortLabel(effort) {
  if (!effort || effort.mode === 'auto') return 'Auto';
  return effort.mode === 'range' ? `${title(effort.minimum)}–${title(effort.maximum)}` : title(effort.value);
}
function effortKey(effort) {
  if (!effort || effort.mode === 'auto') return 'auto';
  return effort.mode === 'fixed' ? 'fixed:' + effort.value : 'range:' + effort.minimum + ':' + effort.maximum;
}
export function routeKey(route) {
  if (!route) return null;
  const workers = [route, ...(route.additionalAgents || [])].map(worker => [worker.modelID, effortKey(worker.effort)]);
  const result = workers.length > 1 ? (route.resultMode || 'coordinator') : 'coordinator';
  return JSON.stringify([workers, result, result === 'ai' ? route.judgeModelID : null, workers.length > 1 ? route.teamMode || 'parallel' : null]);
}
export function recipeKey(configuration, platforms) {
  if (!configuration) return null;
  return JSON.stringify([...platforms].sort().map(platform => [platform, TASKS.map(([task]) =>
    routeKey(configuration.profiles.find(profile => profile.platform === platform)?.routes.find(route => route.category === task)))]));
}
export function matchedPreset(configuration, platforms, presets) {
  if (!configuration || !platforms.length) return null;
  const key = recipeKey(configuration, platforms);
  return presets.find(preset => recipeKey(preset.configuration, platforms) === key)?.id || null;
}
export function modelIdentity(model) {
  const id = (model?.id || '').toLowerCase().split('[')[0];
  const label = (model?.label || '').toLowerCase();
  const families = model?.platform === 'codex' ? [['luna', 1], ['terra', 2], ['sol', 3], ['astra', 4]]
    : model?.platform === 'claude' ? [['haiku', 1], ['sonnet', 2], ['fable', 4], ['opus', 4]] : [];
  const match = families.find(([family]) => {
    if (family === 'fable' && id !== 'claude-fable-5-1' && label !== 'fable 5.1') return false;
    const pattern = model.platform === 'codex' ? '^gpt-[0-9][a-z0-9.]*-' + family + '(?:[-._][a-z0-9]+)*$'
      : '^claude-(?:[0-9][a-z0-9.]*-)*' + family + '(?:[-._][a-z0-9]+)*$';
    return id === family || new RegExp(pattern).test(id) || new RegExp('^(?:claude )?' + family + '(?: [0-9][a-z0-9. -]*)?$').test(label);
  });
  const level = match?.[1] || 0;
  return { level, color: ['#8b8c92', '#4b9b72', '#b3933d', '#cf884d', '#c66b76'][level] };
}
const glyphs = {
  coordinator: '<circle cx="12" cy="4" r="2.5"/><circle cx="5" cy="19" r="2.5"/><circle cx="19" cy="19" r="2.5"/><circle cx="12" cy="12" r="2.5"/><path d="M12 6.5v3M7 17l3-3m4 0 3 3"/>',
  planning: '<circle cx="5" cy="19" r="2.5"/><path d="M5 16v-5h7V5h6m0 5V2l5 3-5 3"/>',
  ui: '<rect x="2" y="4" width="20" height="16" rx="3"/><path d="M2 9h20M8 9v11m-3-13h.1"/><rect x="11" y="12" width="8" height="5" rx="1"/>',
  implementation: '<path d="m8 6-5 6 5 6m8-12 5 6-5 6M14 4l-4 16"/>',
  algorithms: '<path d="m12 2 5 5-5 5-5-5 5-5m0 10v3H5v3m7-3h7v3"/><rect x="2" y="18" width="6" height="4" rx="1"/><rect x="16" y="18" width="6" height="4" rx="1"/>',
  review: '<path d="m12 2 9 3-1 8q-1 6-8 9-7-3-8-9L3 5Zm-5 10 3.5 3.5L17 8.5"/>',
  mechanical: '<path d="M18 3q-7-2-6 5l-8.5 8.5q-3 6 4 4L16 12q7 1 5-6l-3 3-3-3Z"/>',
};
export function taskIcon(elements, task) {
  const info = TASKS.find(([id]) => id === task);
  return elements.Svg ? elements.Svg({ source: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="none" stroke="#8094b7" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' + glyphs[task] + '</g></svg>', width: 20, height: 20, alt: info[1] })
    : elements.Text({ color: '#8094b7', children: [info[2]] });
}
export function strengthMark(elements, model) {
  const { level, color } = modelIdentity(model);
  if (!level) return elements.Text({ dimColor: true, children: ['·'] });
  if (!elements.Svg) return elements.Text({ color, children: ['▂▄▆█'.slice(0, level)] });
  return elements.Svg({ source: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 16">' + [0, 1, 2, 3].map(index => `<rect x="${index * 4.5}" y="${12 - index * 3}" width="3" height="${4 + index * 3}" rx=".8" fill="${index < level ? color : '#80808040'}"/>`).join('') + '</svg>', width: 16, height: 14, alt: `Model level ${level} of 4` });
}


export function brandMark(elements) {
  return elements.Svg ? elements.Svg({ source: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64"><g transform="translate(0 5)"><g fill="none" stroke="#6FB3B8" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 46V23H10V19C10 13.5 14.5 9 20 9H42C47.5 9 52 13.5 52 19V23H23V46"/><path d="M28 29H51C50.2 37.5 46.4 42 39.5 42S29 37.5 28 29Z"/><path d="M39.5 23V33"/><path d="M10 46H53" stroke="#F59E0B"/></g><circle cx="18" cy="17" r="1.8" fill="#6FB3B8"/></g></svg>', width: 30, height: 30, alt: 'StandMixer' }) : null;
}
