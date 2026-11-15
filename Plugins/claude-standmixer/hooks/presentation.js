// Native presentation helpers: recipe identity excludes worker UUIDs and unused effort fields.
export const GROUPS=[['planning','Planning & algorithms',['quickIdeas','algorithms']],['ui','Design & UI',['uiBuild','uiReview']],['implementation','General coding',['routineCoding','debugging']],['review','Code review',['developmentSecurity','securityReview']],['research','Research & writing',['draftingEditing','deepAnalysis']],['mechanical','Routine tasks',['computerUse']]];
export const CHILDREN={quickIdeas:['Quick ideas','Names and rough nontechnical options. Algorithm design and invention work stay with Planning & algorithms.'],algorithms:['Algorithms','Existing algorithm-specific assignment.'],uiBuild:['UI implementation','Implementing the chosen interface.'],uiReview:['UI review','Reviewing the interface and interaction.'],routineCoding:['Routine coding','Bounded implementation with a known approach.'],debugging:['Debugging / root cause','Trace difficult failures and test the underlying cause.'],developmentSecurity:['Development security','Bounded security checks during private development, including authentication, permissions, and secret handling.'],securityReview:['Release security','Assess warranted release risks before public exposure, including internet-reachable staging or test systems. Ordinary pre-release changes use Code review.'],draftingEditing:['Drafting & editing','Wording and editing from settled content; substantive technical reasoning uses its reasoning route.'],deepAnalysis:['Deep analysis','Develop new conclusions, resolve conflicting evidence, or test consequential assumptions.'],computerUse:['Computer use','Operate the interface with the selected worker.']};
export const TASKS=[['coordinator','Controller'],...GROUPS.flatMap(([id,label,children])=>[[id,label],...children.map(child=>[child,CHILDREN[child][0]])])];
export const PARENTS=Object.fromEntries(GROUPS.flatMap(([id,,children])=>children.map(child=>[child,id])));
export const taskLabel=t=>TASKS.find(x=>x[0]===t)?.[1]||t;
export const PLATFORM_NAMES = { codex: 'Codex', claude: 'Claude Code' };
export const PROVIDER_COLORS = { codex: '#638ad0', claude: '#a17bc7' };
export const PRESET_DETAILS = { fast: 'Lightweight', optimized: 'Matched to the task', high: 'More deliberate work' };
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
export function routeKey(r){if(!r)return null;const flags=[!!r.inheritsModel,!!r.inheritsEffort,!!r.inheritsTeam],team=[[flags[0]?'parent':r.modelID,flags[1]?'parent':effortKey(r.effort)],...(flags[2]?[]:(r.additionalAgents||[]).map(a=>[a.modelID,effortKey(a.effort)]))],mode=team.length>1?r.resultMode||'coordinator':'coordinator';return JSON.stringify([flags,team,flags[2]?'parent':mode,mode==='ai'?r.judgeModelID:null,team.length>1?r.teamMode||'parallel':null,(r.stuckEscalation||[]).map(a=>[a.modelID,effortKey(a.effort)])]);}
function routeFor(c,p,t){return c?.profiles?.find(x=>x.platform===p)?.routes?.find(x=>x.category===t);}
export function recipeKey(c,ps){return c?JSON.stringify([...ps].sort().map(p=>[p,(c.profiles?.find(x=>x.platform===p)?.routes||[]).map(r=>[r.category,routeKey(r)]).sort((a,b)=>a[0].localeCompare(b[0]))])):null;}
export function matchedPreset(configuration, platforms, presets) {
  if (!configuration || !platforms.length) return null;
  const key = recipeKey(configuration, platforms);
  return presets.find(preset => recipeKey(preset.configuration, platforms) === key)?.id || null;
}
export function modelIdentity(model) {
  const id = (model?.id || '').toLowerCase().split('[')[0];
  const label = (model?.label || '').toLowerCase();
  const families = model?.platform === 'codex' ? [['luna', 1], ['terra', 1], ['sol', 2], ['astra', 3]]
    : model?.platform === 'claude' ? [['haiku', 1], ['sonnet', 2], ['fable', 3], ['opus', 3]] : [];
  const match = families.find(([family]) => {
    if (family === 'fable' && !['claude-fable-5-1','claude-fable-5-2'].includes(id) && !['fable 5.1','fable 5.2'].includes(label)) return false;
    const pattern = model.platform === 'codex' ? '^gpt-[0-9][a-z0-9.]*-' + family + '(?:[-._][a-z0-9]+)*$'
      : '^claude-(?:[0-9][a-z0-9.]*-)*' + family + '(?:[-._][a-z0-9]+)*$';
    return id === family || new RegExp(pattern).test(id) || new RegExp('^(?:claude )?' + family + '(?: [0-9][a-z0-9. -]*)?$').test(label);
  });
  const level = match?.[1] || 0;
  return { level, color: ['#8b8c92', '#bd713a', '#ad8a34', '#43845f'][level] };
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
  return elements.Svg ? elements.Svg({ source: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><g fill="none" stroke="#8094b7" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' + (glyphs[task] || glyphs[PARENTS[task]] || glyphs.planning) + '</g></svg>', width: 20, height: 20, alt: info[1] })
    : elements.Text({ color: '#8094b7', children: [info?.[2] || '·'] });
}
export function strengthMark(elements, model) {
  const {level,color}=modelIdentity(model),label=level?'Model tier '+level+' of 3':'Model tier not assigned';
  if(!elements.Svg)return elements.Box({flexDirection:'column',children:[0,1,2].map(index=>elements.Text({color,children:[index>=3-level?'•':'◦']}))});
  return elements.Svg({source:'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 5 15">'+[0,1,2].map(index=>'<circle cx="2.5" cy="'+(2.5+index*5)+'" r="1.5" fill="'+(index>=3-level?color:'#80808040')+'"/>').join('')+'</svg>',width:5,height:15,alt:label});
}



export function brandMark(elements) {
  return elements.Svg ? elements.Svg({ source: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64"><g transform="translate(0 5)"><g fill="none" stroke="#6FB3B8" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14 46V23H10V19C10 13.5 14.5 9 20 9H42C47.5 9 52 13.5 52 19V23H23V46"/><path d="M28 29H51C50.2 37.5 46.4 42 39.5 42S29 37.5 28 29Z"/><path d="M39.5 23V33"/><path d="M10 46H53" stroke="#F59E0B"/></g><circle cx="18" cy="17" r="1.8" fill="#6FB3B8"/></g></svg>', width: 30, height: 30, alt: 'StandMixer' }) : null;
}

export function effectiveRoute(configuration, platform, task) {
  const route=routeFor(configuration,platform,task),parent=PARENTS[task]&&routeFor(configuration,platform,PARENTS[task]);
  if(!route||!parent)return route;
  return {...route,...(route.inheritsModel?{modelID:parent.modelID}:{}),...(route.inheritsEffort?{effort:parent.effort}:{}),...(route.inheritsTeam?{additionalAgents:parent.additionalAgents,teamMode:parent.teamMode,resultMode:parent.resultMode,judgeModelID:parent.judgeModelID}:{})};
}
export function effortMark(elements, effort) {
  const mode=effort?.mode||'auto',label='Effort: '+effortLabel(effort);
  if(mode==='auto')return elements.Text({dimColor:true,children:['Auto']});
  const minimum=LEVELS.indexOf(mode==='range'?effort.minimum:effort.value)+1,maximum=LEVELS.indexOf(mode==='range'?effort.maximum:effort.value)+1,count=maximum>5?6:5;
  if(!elements.Svg)return elements.Text({color:'#6fb3b8',children:[Array.from({length:count},(_,i)=>i<minimum?'▰':i<maximum?'▧':'▱').join('')]});
  return elements.Svg({source:'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 '+(count*7)+' 18">'+Array.from({length:count},(_,i)=>'<rect x="'+(i*7)+'" y="'+(14-i*2)+'" width="5" height="'+(4+i*2)+'" rx="1" fill="'+(i<minimum?'#6fb3b8':i<maximum?'#6fb3b866':'#80808033')+'"/>').join('')+'</svg>',width:count*7,height:18,alt:label+(mode==='range'?' (range)':'')});
}
