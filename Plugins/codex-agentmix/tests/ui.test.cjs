const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');

const html = fs.readFileSync(path.join(__dirname, '../ui/index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*)<\/script>/)[1];
const plain = value => JSON.parse(JSON.stringify(value));
const clone = plain;
const auto = {mode:'auto', value:'high', minimum:'low', maximum:'high'};
const categories = ['coordinator','planning','ui','implementation','algorithms','review','mechanical'];
const models = [
  ['gpt-6.1-sol','Sol 6.1','codex'], ['gpt-6-astra','Astra 6','codex'],
  ['gpt-6.1-terra','Terra 6.1','codex'], ['gpt-6-luna','Luna 6','codex'],
  ['claude-opus-5-5','Opus 5.5','claude'], ['claude-fable-5-1','Fable 5.1','claude'],
  ['claude-sonnet-5-5','Sonnet 5.5','claude'], ['claude-haiku-5-5','Haiku 5.5','claude'],
].map(([id,label,platform])=>({id,label,platform,supportedEfforts:platform==='codex'?['low','medium','high','xhigh','max','ultra']:['low','medium','high','xhigh','max'],isDiscovered:false}));
function configuration(){return {customModels:[],enabledPlatforms:['codex','claude'],profiles:['codex','claude'].map(platform=>({platform,routes:categories.map(category=>({category,modelID:category==='coordinator'?'auto':platform==='codex'?'gpt-6.1-sol':'claude-opus-5-5',effort:clone(auto),additionalAgents:[],resultMode:'coordinator'}))}))};}
function data(){const config=configuration();const presets=['fast','optimized','high'].map(id=>({id,title:'StandMixer '+id,configuration:clone(config)}));presets[0].configuration.profiles[0].routes[6].modelID='gpt-6-luna';presets[2].configuration.profiles[0].routes[2].additionalAgents=[{id:'0c471eef-8bcc-4975-97ca-89a83bbb82de',modelID:'claude-fable-5-1',effort:clone(auto)}];return {configuration:config,hasSavedDraft:false,previousDraft:clone(config),enabledPlatforms:['codex','claude'],preferredPlatforms:['codex','claude'],availablePlatforms:['codex','claude'],presets,catalog:clone(models),connections:[],installation:{state:'notInstalled',summary:'Nothing applied',hasInstallation:false,installedPlatforms:[]},savedPresets:[],nativeSettings:[],canRestore:false,notes:[]};}
function preview(kind='apply'){return {id:'review-exact-id',kind,expiresAt:new Date(Date.now()+3600000).toISOString(),changedFiles:1,conflicts:[],changes:[{path:'/fixture/.codex/config.toml',reason:'Update saved model',isChanged:true,isDeletion:false,diff:{addedLineCount:1,removedLineCount:1,isCoarse:false,hasFinalNewlineChange:false,hunks:[{oldStart:1,oldCount:1,newStart:1,newCount:1,lines:[{kind:'removal',text:'model = "old"',oldLineNumber:1},{kind:'addition',text:'model = "new"',newLineNumber:1}]}]}}]};}
function load(window){const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{innerHTML:'',textContent:'',dataset:{},setAttribute(){},querySelectorAll(){return []},getBoundingClientRect(){return {height:680}}});return nodes.get(id);};const document={getElementById:node,querySelectorAll:()=>[],querySelector:()=>null,documentElement:{dataset:{},style:{setProperty(){}}}};const context={module:{exports:{}},console,URLSearchParams,AbortController,setTimeout,clearTimeout,crypto:webcrypto,window,document,requestAnimationFrame:()=>0};vm.runInNewContext(script,context,{filename:'agentmix-inline.js'});return {api:context.module.exports,nodes,document};}
function ready(){const loaded=load();loaded.api.acceptState(data());return loaded;}

test('the deliverable is self contained and compatible with a hashed script CSP',()=>{
  assert.doesNotThrow(()=>new vm.Script(script));
  assert(!/<(?:script|link)[^>]+(?:src|href)=/i.test(html));
  assert(!/\son(?:click|change|load|submit)=/i.test(html));
  assert(!/eval\s*\(|new Function\s*\(/.test(script));
});
test('model strength matches all eight approved families, with unknown versions unrated',()=>{
  const {api}=load();assert.deepEqual(models.map(api.modelIdentity),[3,4,2,1,4,4,2,1]);
  assert.equal(api.modelIdentity({id:'claude-fable-6',label:'Fable 6',platform:'claude'}),0);
  assert.equal(api.modelIdentity({id:'my-sol-fast',label:'Custom Sol',platform:'codex'}),0);
});
test('factory identity ignores UUIDs and inactive effort fields, but keeps model order',()=>{
  const {api}=ready(),before=configuration(),after=clone(before);
  after.profiles[0].routes[0].effort.value='ultra';
  assert.equal(api.recipeKey(before,['codex','claude']),api.recipeKey(after,['claude','codex']));
  const r=after.profiles[0].routes[1];r.additionalAgents=[{id:'one',modelID:'gpt-6-astra',effort:clone(auto)}];
  const another=clone(after);another.profiles[0].routes[1].additionalAgents[0].id='two';
  assert.equal(api.recipeKey(after,['codex']),api.recipeKey(another,['codex']));
  another.profiles[0].routes[1].modelID='gpt-6-astra';another.profiles[0].routes[1].additionalAgents[0].modelID='gpt-6.1-sol';
  assert.notEqual(api.recipeKey(after,['codex']),api.recipeKey(another,['codex']));
});
test('unknown current settings never produce a Changed badge',()=>{
  const {api}=ready(),r=configuration().profiles[0].routes[1];
  assert.equal(api.knownChanges(null,r),false);assert.equal(api.knownChanges({modelID:r.modelID},r),false);
  assert.equal(api.knownChanges({modelID:'gpt-6-luna'},r),true);
  assert(!api.assignment('codex','planning').includes('change-badge'));
});
test('only known native coordinator changes are compared; expired inspection is excluded',()=>{
  const {api}=ready();api.state.data.nativeSettings=[{platform:'codex',status:'known',modelID:'gpt-6-luna',sourcePath:'/fixture/config.toml',detail:'Saved defaults only'}];
  assert(!api.assignment('codex','coordinator').includes('change-badge'));
  api.state.draft.profiles[0].routes[0].modelID='gpt-6.1-sol';
  assert(api.assignment('codex','coordinator').includes('change-badge'));
  api.state.inspection={expiresAt:'2020-01-01T00:00:00Z',reports:[{platform:'codex',status:'complete',routes:[{category:'planning',modelID:'gpt-6-luna'}]}]};
  assert.equal(api.observed('codex','planning'),null);
});
test('applied records supply worker comparison only while files match',()=>{
  const {api}=ready(),applied=configuration();applied.profiles[0].routes[1].modelID='gpt-6-luna';
  api.state.data.installation={state:'applied',appliedConfiguration:applied,installedPlatforms:['codex']};
  assert(api.knownChanges(api.observed('codex','planning'),api.state.draft.profiles[0].routes[1]));
  api.state.data.installation.state='drifted';assert.equal(api.observed('codex','planning'),null);
});
test('matrix has one shared task label per row and explicit cross-provider badges',()=>{
  const {api}=ready();api.state.draft.profiles[0].routes[2].modelID='claude-opus-5-5';
  const rendered=api.matrix();assert.equal((rendered.match(/<tr>/g)||[]).length,8);
  assert.equal((rendered.match(/Review & Security/g)||[]).length,1);
  assert(rendered.includes('via Claude Code'));assert(rendered.includes('via claude'));
  assert.equal((rendered.match(/>Auto<\/span>/g)||[]).length,2);
});
test('coordinator editor rejects a cross-provider model and team expansion',()=>{
  const {api}=ready();const r=api.state.draft.profiles[0].routes[0];
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'model',index:'0'},value:'claude-opus-5-5'});
  assert.equal(r.modelID,'auto');
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'team'},value:'4'});
  assert.equal(r.additionalAgents.length,0);
});
test('inline team and result controls preserve ordered workers and reset a one-agent result',()=>{
  const {api}=ready();const edit=(field,value)=>api.editField({dataset:{platform:'codex',task:'ui',field,index:'0'},value});
  edit('team','4');const r=api.state.draft.profiles[0].routes[2];assert.equal(r.additionalAgents.length,3);assert.equal(new Set(r.additionalAgents.map(x=>x.id)).size,3);
  edit('result','ai');assert.equal(r.judgeModelID,'gpt-6.1-sol');
  edit('team','1');assert.equal(r.resultMode,'coordinator');assert.equal(r.judgeModelID,undefined);assert.equal(api.state.dirty,false);
});
test('model replacement translates unsupported fixed effort to a supported level',()=>{
  const {api}=ready();const r=api.state.draft.profiles[0].routes[2];r.effort={...auto,mode:'fixed',value:'ultra'};
  api.editField({dataset:{platform:'codex',task:'ui',field:'model',index:'0'},value:'claude-opus-5-5'});
  assert.equal(r.effort.value,'max');
});
test('exact diff display escapes file names and source text',()=>{
  const {api}=ready(),file=preview().changes[0];file.path='<img src=x onerror=alert(1)>';file.diff.hunks[0].lines[0].text='</span><script>bad()</script>';
  const rendered=api.diffFile(file,0);assert(!rendered.includes('<script>'));assert(!rendered.includes('<img'));assert(rendered.includes('&lt;script&gt;'));assert(rendered.includes('line-number'));
});
test('Apply, restore and uninstall submit only the immutable reviewed ID',()=>{
  const {api}=ready();for(const kind of ['apply','restore','uninstall'])assert.deepEqual(plain(api.reviewRequest(preview(kind))),{action:kind,previewID:'review-exact-id'});
  assert.throws(()=>api.reviewRequest({...preview(),expiresAt:'2020-01-01T00:00:00Z'}),/expired/);
  assert.throws(()=>api.reviewRequest({...preview(),kind:'saveDraft'}),/fresh review/);
});
test('opening, rendering and switching preset never applies settings or starts inspection',async()=>{
  const {api}=ready(),calls=[];api.setBridge({ready:false,action:async r=>{calls.push(r);return {ok:true,state:data()}}});
  api.render();await api.handleAction('preset',{id:'fast'});await api.handleAction('advanced');
  assert.equal(calls.length,0);assert.equal(api.state.selected,'fast');assert.equal(api.state.advanced,true);
});
test('preparing a preview and explicit Apply are separate actions with an exact-ID commit',async()=>{
  const {api}=ready(),calls=[];api.setBridge({ready:false,action:async r=>{calls.push(plain(r));return r.action==='preview'?{ok:true,preview:preview()}:{ok:true,state:data(),result:{message:'Applied'}};}});
  await api.prepare();assert.deepEqual(calls.map(x=>x.action),['preview']);assert.equal(api.state.modal.kind,'review');
  await api.applyReview();assert.deepEqual(calls[1],{action:'apply',previewID:'review-exact-id'});assert.equal(api.state.modal,null);
});
test('a failed Apply retains the reviewed diff and shows the backend error',async()=>{
  const {api}=ready();api.state.preview=preview();api.state.modal={kind:'review'};api.setBridge({ready:false,action:async()=>{throw Error('Settings changed after review.');}});
  await api.applyReview();assert.equal(api.state.preview.id,'review-exact-id');assert.equal(api.state.modal.kind,'review');assert.match(api.state.modalError,/Settings changed/);assert.equal(api.state.busy,false);
});
test('HTTP transport authenticates same-origin requests and never includes tokens in bodies',async()=>{
  const {api}=load(),calls=[];const win={location:{hash:'#token=fixture-secret',hostname:'127.0.0.1'},addEventListener(){},removeEventListener(){},parent:null,fetch:async(...args)=>{calls.push(args);return {json:async()=>({ok:true,state:data()})}}};win.parent=win;
  const bridge=new api.Bridge(win);await bridge.connect();await bridge.action({action:'state'});
  assert.equal(calls[0][0],'/api');assert.equal(calls[0][1].headers.Authorization,'Bearer fixture-secret');assert.equal(calls[0][1].body,'{"action":"state"}');assert.equal(calls[0][1].redirect,'error');bridge.dispose();
});
test('HTTP mode refuses a non-loopback host',async()=>{
  const {api}=load(),win={location:{hash:'#token=x',hostname:'example.com'},addEventListener(){},removeEventListener(){},parent:{}};
  const bridge=new api.Bridge(win);await assert.rejects(()=>bridge.connect(),/local helper/);bridge.dispose();
});
test('MCP handshake uses the official names and ignores messages from unrelated windows',async()=>{
  const {api}=load(),messages=[],listeners={};const parent={postMessage:m=>messages.push(plain(m))};const win={location:{hash:'',hostname:''},parent,addEventListener:(name,fn)=>listeners[name]=fn,removeEventListener(){}};
  const bridge=new api.Bridge(win),connected=bridge.connect();assert.equal(messages[0].method,'ui/initialize');assert.equal(messages[0].params.appInfo.name,'StandMixer');
  listeners.message({source:{},data:{jsonrpc:'2.0',id:messages[0].id,result:{}}});assert.equal(bridge.ready,false);
  listeners.message({source:parent,data:{jsonrpc:'2.0',id:messages[0].id,result:{protocolVersion:'2026-01-26',hostContext:{theme:'dark'}}}});await connected;
  assert.equal(messages[1].method,'ui/notifications/initialized');assert.equal(bridge.hostContext.theme,'dark');
  const response=bridge.action({action:'state'}),call=messages[2];assert.deepEqual(call.params,{name:'standmixer_action',arguments:{action:'state'}});
  listeners.message({source:parent,data:{jsonrpc:'2.0',id:call.id,result:{structuredContent:{ok:true,state:data()}}}});assert.equal((await response).ok,true);bridge.dispose();
});
test('structured and text-only MCP responses decode, and malformed responses fail explicitly',()=>{
  const {api}=load();assert.equal(api.unpack({structuredContent:{ok:true}}).ok,true);assert.equal(api.unpack({content:[{type:'text',text:'{"ok":false,"error":{"message":"conflict"}}'}]}).ok,false);assert.throws(()=>api.unpack({content:[]}),/unreadable/);
});
test('closing the panel cancels an in-flight HTTP request without retrying it',async()=>{
  const {api}=load();let calls=0,signal;
  const win={location:{hash:'#token=fixture-secret',hostname:'127.0.0.1'},addEventListener(){},removeEventListener(){},parent:null,fetch:async(_url,options)=>{calls++;signal=options.signal;return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>reject(Error('aborted'))));}};win.parent=win;
  const bridge=new api.Bridge(win);await bridge.connect();const request=bridge.action({action:'inspect'});bridge.dispose();
  await assert.rejects(request,/interrupted/);assert.equal(signal.aborted,true);assert.equal(calls,1);
});
test('closing the panel propagates MCP cancellation for pending request IDs',async()=>{
  const {api}=load(),messages=[];const win={location:{hash:'',hostname:''},parent:{postMessage:m=>messages.push(plain(m))},addEventListener(){},removeEventListener(){}};
  const bridge=new api.Bridge(win);bridge.ready=true;const request=bridge.action({action:'inspect'}),id=messages[0].id;bridge.dispose();
  await assert.rejects(request,/closed/);assert.deepEqual(messages[1],{jsonrpc:'2.0',method:'notifications/cancelled',params:{requestId:id,reason:'StandMixer panel closed'}});
});
test('removing a saved custom definition also removes it from the editable catalog',()=>{
  const {api}=ready(),custom={id:'custom-worker',label:'Custom worker',platform:'codex',supportedEfforts:['low']};
  api.state.data.configuration.customModels=[clone(custom)];api.state.data.catalog.push(clone(custom));api.state.draft.customModels=[clone(custom)];assert(api.catalog().some(x=>x.id===custom.id));
  api.state.draft.customModels=[];assert(!api.catalog().some(x=>x.id===custom.id));
});
test('a zero-change review has an active Done action and no disabled Apply dead end',async()=>{
  const {api}=ready();
  for(const kind of ['apply','restore','uninstall']){
    api.state.preview={...preview(kind),changedFiles:0,changes:[]};api.state.modal={kind:'review'};
    const rendered=api.reviewDialog();
    assert.match(rendered,/class="button primary" data-action="closeModal">Done<\/button>/);
    assert(!rendered.includes('data-action="applyReview"'));assert(!rendered.includes('0 files will change'));
    await api.handleAction('closeModal');assert.equal(api.state.modal,null);
  }
});
test('dismissing a pending preview cancels it immediately and suppresses late results',async()=>{
  const {api}=ready();let resolve,signal;
  api.setBridge({ready:false,action:(_request,options)=>{signal=options.signal;return new Promise(done=>{resolve=done;});}});
  const pending=api.prepare();assert.equal(api.state.modal.preparing,true);assert(api.reviewDialog().includes('>Cancel</button>'));
  await api.handleAction('closeModal');assert.equal(signal.aborted,true);assert.equal(api.state.modal,null);assert.equal(api.state.busy,false);
  resolve({ok:true,preview:preview()});await pending;
  assert.equal(api.state.modal,null);assert.equal(api.state.preview,null);assert.equal(api.state.modalError,null);assert.equal(api.state.notice,null);
});
test('preview cancellation reaches the individual HTTP request while keeping the panel connected',async()=>{
  const {api}=load();let signal;
  const win={location:{hash:'#token=fixture-secret',hostname:'127.0.0.1'},addEventListener(){},removeEventListener(){},parent:null,fetch:async(_url,options)=>{signal=options.signal;return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>reject(Error('aborted'))));}};win.parent=win;
  const bridge=new api.Bridge(win),controller=new AbortController();await bridge.connect();
  const pending=bridge.action({action:'preview'},{signal:controller.signal});controller.abort();
  await assert.rejects(pending,/interrupted/);assert.equal(signal.aborted,true);assert.equal(bridge.ready,true);bridge.dispose();
});
test('preview cancellation sends the matching MCP cancellation notification',async()=>{
  const {api}=load(),messages=[],controller=new AbortController();
  const win={location:{hash:'',hostname:''},parent:{postMessage:m=>messages.push(plain(m))},addEventListener(){},removeEventListener(){}};
  const bridge=new api.Bridge(win);bridge.ready=true;
  const pending=bridge.action({action:'preview'},{signal:controller.signal}),id=messages[0].id;controller.abort();
  await assert.rejects(pending,/cancelled/);assert.deepEqual(messages[1],{jsonrpc:'2.0',method:'notifications/cancelled',params:{requestId:id,reason:'StandMixer review dismissed'}});assert.equal(bridge.ready,true);bridge.dispose();
});
test('an explicit Apply commit briefly holds the review until its result arrives',async()=>{
  const {api}=ready();let resolve;api.state.modal={kind:'review'};api.state.preview=preview();
  api.setBridge({ready:false,action:()=>new Promise(done=>{resolve=done;})});
  const pending=api.applyReview();await api.handleAction('closeModal');assert.equal(api.state.modal.kind,'review');assert.equal(api.state.committing,true);
  resolve({ok:true,state:data(),result:{message:'Applied'}});await pending;assert.equal(api.state.modal,null);assert.equal(api.state.committing,false);
});
test('Uninstall is absent from the sidebar and reachable only through a reviewed Sources action',async()=>{
  const {api,nodes}=ready(),calls=[];api.state.data.installation.hasInstallation=true;
  assert(!api.sidebar().includes('Uninstall'));assert(!api.sidebar().includes('previewUninstall'));
  api.setBridge({ready:false,action:async request=>{calls.push(plain(request));return {ok:true,preview:preview('uninstall')};}});
  await api.handleAction('sources');assert.match(nodes.get('modal-root').innerHTML,/data-action="previewUninstall">[\s\S]*?Uninstall StandMixer/);
  assert.equal(calls.length,0);await api.handleAction('previewUninstall');
  assert.deepEqual(calls,[{action:'previewUninstall'}]);assert.equal(api.state.modal.kind,'review');assert.equal(api.state.preview.kind,'uninstall');
});
test('URL inspection flags cannot trigger inference when opening the local panel',async()=>{
  const calls=[],win={location:{hash:'#token=fixture-secret&inspect=true',hostname:'127.0.0.1'},addEventListener(){},removeEventListener(){},fetch:async(_url,options)=>{calls.push(JSON.parse(options.body));return {json:async()=>({ok:true,state:data()})};}};win.parent=win;
  const {api}=load(win);await api.initialize();
  assert.deepEqual(calls.map(x=>x.action),['state']);assert.equal(api.state.inspecting,false);
});
test('MCP opening arguments cannot trigger inference before or after state arrives',async()=>{
  const calls=[],listeners={},win={location:{hash:'',hostname:''},addEventListener:(name,fn)=>{listeners[name]=fn;},removeEventListener(){}};
  win.parent={postMessage:message=>{if(message.method==='ui/initialize')queueMicrotask(()=>{
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',method:'ui/notifications/tool-input',params:{arguments:{inspect:true}}}});
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{hostContext:{}}}});
  });else if(message.method==='tools/call'){calls.push(plain(message.params.arguments));queueMicrotask(()=>listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{structuredContent:{ok:true,state:data()}}}}));}}};
  const {api}=load(win);await api.initialize();
  listeners.message({source:win.parent,data:{jsonrpc:'2.0',method:'ui/notifications/tool-input',params:{arguments:{inspect:true}}}});
  await new Promise(resolve=>setImmediate(resolve));assert.deepEqual(calls.map(x=>x.action),['state']);assert.equal(api.state.inspecting,false);
});
test('acknowledgement-only MCP opening loads state through the app-only tool',async()=>{
  const calls=[],listeners={},win={location:{hash:'',hostname:''},addEventListener:(name,fn)=>{listeners[name]=fn;},removeEventListener(){}};
  win.parent={postMessage:message=>{if(message.method==='ui/initialize')queueMicrotask(()=>{
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',method:'ui/notifications/tool-result',params:{structuredContent:{ok:true,result:{message:'StandMixer panel opened.'}}}}});
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{hostContext:{}}}});
  });else if(message.method==='tools/call'){calls.push(plain(message.params));queueMicrotask(()=>listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{structuredContent:{ok:true,state:data()}}}}));}}};
  const {api}=load(win);await api.initialize();
  assert.deepEqual(calls,[{name:'standmixer_action',arguments:{action:'state'}}]);
  assert.equal(api.state.data.presets.length,3);assert.equal(api.state.notice,null);assert.equal(api.state.inspecting,false);
});
test('late inspections cannot replace state after Apply, restore, or uninstall',async()=>{
  for(const kind of ['apply','restore','uninstall']){
    const {api}=ready();let resolveInspection,inspectionSignal;
    api.setBridge({ready:false,action:async(request,options)=>{if(request.action==='inspect'){inspectionSignal=options.signal;return new Promise(resolve=>{resolveInspection=resolve;});}return {ok:true,state:data(),result:{message:'Completed '+kind}};}});
    const pending=api.inspect(true);api.state.modal={kind:'review'};api.state.preview=preview(kind);
    await api.applyReview();assert.equal(inspectionSignal.aborted,true);assert.equal(api.state.inspection,null);
    resolveInspection({ok:true,inspection:{reports:[{platform:'codex',status:'complete',summary:'Stale pre-apply report',routes:[]}]}});await pending;
    assert.equal(api.state.inspection,null);assert.equal(api.state.inspecting,false);assert.equal(api.state.notice.text,'Completed '+kind);
  }
});
test('provider changes and connection reloads cancel and discard their earlier inspections',async()=>{
  for(const [action,detail] of [['togglePlatform',{platform:'claude'}],['connections',{}]]){
    const {api}=ready();let resolveInspection,inspectionSignal;
    api.setBridge({ready:false,action:async(request,options)=>{if(request.action==='inspect'){inspectionSignal=options.signal;return new Promise(resolve=>{resolveInspection=resolve;});}return {ok:true,state:data()};}});
    const pending=api.inspect();await api.handleAction(action,detail);assert.equal(inspectionSignal.aborted,true);
    resolveInspection({ok:true,inspection:{reports:[{platform:'claude',status:'complete',summary:'Outdated provider selection',routes:[]}]}});await pending;
    assert.equal(api.state.inspection,null);assert.equal(api.state.inspecting,false);assert.equal(api.state.notice,null);
  }
});
test('completion of a cancelled inspection cannot clear a newer inspection flight',async()=>{
  const {api}=ready(),pending=[];api.setBridge({ready:false,action:async request=>request.action==='inspect'?new Promise(resolve=>pending.push(resolve)):{ok:true,state:data()}});
  const first=api.inspect();await api.handleAction('connections');const second=api.inspect();
  pending[0]({ok:true,inspection:{reports:[],marker:'old'}});await first;assert.equal(api.state.inspecting,true);assert.equal(api.state.inspection,null);
  pending[1]({ok:true,inspection:{reports:[],marker:'new'}});await second;assert.equal(api.state.inspecting,false);assert.equal(api.state.inspection.marker,'new');
});
test('observer findings remain in Sources and cannot create or override authoritative Changed badges',()=>{
  const {api}=ready();api.state.data.nativeSettings=[{platform:'codex',status:'known',modelID:'gpt-6.1-sol',sourcePath:'/fixture/config.toml',detail:'Saved global defaults'}];
  for(const status of ['complete','partial']){
    api.state.inspection={expiresAt:new Date(Date.now()+60000).toISOString(),reports:[{platform:'codex',status,summary:'Observed preferences',routes:[{category:'planning',modelID:'gpt-6-luna',scope:'usual',evidence:[],uncertainties:['May be project-specific']},{category:'coordinator',modelID:'gpt-6-astra',scope:'current',evidence:[],uncertainties:[]}]}]};
    assert.equal(api.observed('codex','planning'),null);assert.equal(api.observed('codex','coordinator').modelID,'gpt-6.1-sol');
    assert(!api.assignment('codex','planning').includes('change-badge'));assert(!api.assignment('codex','coordinator').includes('change-badge'));
    const sources=api.sourceCard('codex');assert(sources.includes('Preference observations'));assert(sources.includes('May be project-specific'));assert(sources.includes('not verified current settings'));
  }
});

test('Controller Auto preserves the native-model distinction and hides effort controls',()=>{
  const {api}=ready(),r=api.state.draft.profiles[0].routes[0];
  api.state.data.nativeSettings=[{platform:'codex',status:'known',modelID:'gpt-6-luna',effort:'low',sourcePath:'/fixture/config.toml'}];
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'model',index:'0'},value:'auto'});
  assert.equal(r.modelID,'auto');assert.deepEqual(plain(r.effort),auto);
  const rendered=api.assignment('codex','coordinator');
  assert.match(rendered,/>Auto<\/span>/);assert.match(rendered,/Current model/);assert(!rendered.includes('change-badge'));assert(!rendered.includes('Unrated model'));
  api.state.advanced=true;const advanced=api.assignment('codex','coordinator');
  assert.match(advanced,/<option value="auto" selected>Auto · Current model<\/option>/);assert(!advanced.includes('data-field="effort"'));assert(!advanced.includes('data-field="team"'));
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'effort',index:'0'},value:'ultra'});assert.equal(r.effort.mode,'auto');
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'model',index:'0'},value:'gpt-6.1-sol'});
  assert.equal(r.modelID,'gpt-6.1-sol');assert(api.assignment('codex','coordinator').includes('data-field="effort"'));
});
test('Controller Auto compares known StandMixer policy and cannot be selected for workers or judges',()=>{
  const {api}=ready(),applied=configuration(),r=api.state.draft.profiles[0].routes[0];r.modelID='auto';applied.profiles[0].routes[0].modelID='gpt-6.1-sol';
  api.state.data.installation={state:'applied',appliedConfiguration:applied,installedPlatforms:['codex']};
  assert(api.assignment('codex','coordinator').includes('change-badge'));
  applied.profiles[0].routes[0].modelID='auto';assert(!api.assignment('codex','coordinator').includes('change-badge'));
  const worker=api.state.draft.profiles[0].routes[2];
  api.editField({dataset:{platform:'codex',task:'ui',field:'model',index:'0'},value:'auto'});assert.equal(worker.modelID,'gpt-6.1-sol');
  api.editField({dataset:{platform:'codex',task:'ui',field:'team'},value:'2'});
  api.editField({dataset:{platform:'codex',task:'ui',field:'result'},value:'ai'});assert.equal(worker.judgeModelID,'gpt-6.1-sol');
  api.editField({dataset:{platform:'codex',task:'ui',field:'judge'},value:'auto'});assert.equal(worker.judgeModelID,'gpt-6.1-sol');
});
test('optional Mac build is available in Interface and Sources without locking settings',async()=>{
  const {api,nodes}=ready(),calls=[];let finish;
  api.setBridge({ready:false,action:request=>{calls.push(plain(request));if(request.action==='state')return Promise.resolve({ok:true,state:{installedMac:{isAvailable:true}}});return new Promise(resolve=>{finish=resolve;});}});
  assert(api.sidebar().includes('installMac'));await api.handleAction('sources');assert(nodes.get('modal-root').innerHTML.includes('data-action="installMac"'));
  const build=api.handleAction('installMac');assert(api.state.installingMac);assert.equal(api.state.busy,false);assert.match(api.macInstallControl(),/disabled.*Building Mac app/s);
  await api.handleAction('installMac');assert.deepEqual(calls,[{action:'installMac'}]);
  await api.handleAction('advanced');assert.equal(api.state.advanced,true);
  await api.handleAction('closeModal');assert.equal(api.state.modal,null);assert(api.state.installingMac);
  finish({ok:true,result:{message:'Built locally at ~/Applications/StandMixer.app'}});await build;
  assert.equal(api.state.installingMac,false);assert.match(api.state.macInstallMessage,/Built locally/);assert.equal(api.state.modal,null);
});
test('failed Mac build shows its concrete error and can be explicitly retried',async()=>{
  const {api}=ready();let calls=0;api.setBridge({ready:false,action:async()=>{calls++;throw Error('Install Apple developer tools with xcode-select --install.');}});
  await api.installMac();assert.equal(api.state.installingMac,false);assert.equal(api.state.macInstallError,true);assert.match(api.macInstallControl(),/xcode-select --install/);assert.equal(api.state.busy,false);
  await api.installMac();assert.equal(calls,2);
});

test('CLI accounts are checked only from an explicit Sources action and stay distinct from Desktop',async()=>{
  const {api,nodes}=ready(),calls=[];api.setBridge({ready:false,action:async request=>{calls.push(plain(request));return {ok:true,accounts:{checkedAt:'2026-11-03T12:00:00Z',providers:[{platform:'claude',status:'signedIn',email:'cli-user@example.test',subscription:'Max',detail:'Public CLI status',cliPath:'/fixture/claude'},{platform:'codex',status:'unknown',detail:'Identity is not exposed by this CLI.'}]}};}});
  await api.handleAction('sources');assert.equal(calls.length,0);assert.match(nodes.get('modal-root').innerHTML,/Not checked/);assert(!api.sidebar().includes('checkAccounts'));
  await api.handleAction('checkAccounts');assert.deepEqual(calls,[{action:'checkAccounts'}]);
  const claude=api.cliAccount('claude');assert.match(claude,/CLI account · Signed in/);assert.match(claude,/cli-user@example.test/);assert.match(claude,/Plan: Max/);assert.match(claude,/Claude Desktop may use a different account/);
  const codex=api.cliAccount('codex');assert.match(codex,/CLI account · Unknown/);assert(!codex.includes('Signed out'));assert(!api.state.dirty);
  assert.match(api.accountControls(),/does not switch accounts or log you out/);
});
test('unknown, signed-out and failed account checks never retain a misleading sign-in',async()=>{
  const {api}=ready();api.state.accounts={checkedAt:'earlier',providers:[{platform:'claude',status:'signedIn',email:'old@example.test'}]};
  let finish;api.setBridge({ready:false,action:()=>new Promise(resolve=>{finish=resolve;})});const checking=api.checkAccounts();assert(api.state.checkingAccounts);assert.equal(api.state.accounts,null);assert.equal(api.state.busy,false);
  await api.checkAccounts();await api.handleAction('advanced');assert(api.state.advanced);
  finish({ok:true,accounts:{checkedAt:'now',providers:[{platform:'claude',status:'signedOut',detail:'Sign in using the CLI, then check again.'}]}});await checking;
  assert.match(api.cliAccount('claude'),/Signed out/);assert(!api.cliAccount('claude').includes('old@example.test'));
  api.setBridge({ready:false,action:async()=>{throw Error('Account status could not be checked.');}});await api.checkAccounts();assert.equal(api.state.accounts,null);assert.match(api.accountControls(),/could not be checked/);assert.match(api.cliAccount('claude'),/Unknown/);
});
test('public CLI account fields are escaped before display',()=>{
  const {api}=ready();api.state.accounts={checkedAt:'<time>',providers:[{platform:'claude',status:'signedIn',email:'<img src=x>',subscription:'<plan>',detail:'<script>unsafe</script>',cliPath:'<path>'}]};
  const shown=api.cliAccount('claude');assert(!shown.includes('<script>'));assert(!shown.includes('<img'));assert.match(shown,/&lt;plan&gt;/);assert.match(shown,/&lt;path&gt;/);
});

test('team mode distinguishes lead review from independent passes without changing worker order',()=>{
  const {api}=ready(),route=api.state.draft.profiles[0].routes[2];route.additionalAgents=[{id:'second',modelID:'gpt-6-astra',effort:clone(auto)}];
  const legacy=api.routeKey(route);api.editField({dataset:{platform:'codex',task:'ui',field:'teamMode'},value:'leadReview'});assert.notEqual(api.routeKey(route),legacy);assert.equal(route.modelID,'gpt-6.1-sol');assert.equal(route.additionalAgents[0].modelID,'gpt-6-astra');api.state.advanced=true;assert.match(api.assignment('codex','ui'),/Lead/);assert.match(api.assignment('codex','ui'),/Reviewer 1/);
});

test('Applied badge describes the displayed semantic recipe including enabled platforms and team mode',()=>{
  const {api}=ready(),applied=clone(api.state.draft);api.state.data.installation={state:'applied',appliedConfiguration:applied,installedPlatforms:['claude','codex']};
  assert.equal(api.installationLabel(),'Applied');
  api.state.draft.profiles[0].routes[1].modelID='gpt-6-astra';assert.equal(api.installationLabel(),'Unapplied changes');
  api.state.draft=clone(applied);api.state.draft.profiles[0].routes[0].effort.value='ultra';assert.equal(api.installationLabel(),'Applied');
  api.state.platforms=['codex'];assert.equal(api.installationLabel(),'Unapplied changes');api.state.platforms=['codex','claude'];
  for(const config of [applied,api.state.draft])config.profiles[0].routes[2].additionalAgents=[{id:crypto.randomUUID(),modelID:'gpt-6-astra',effort:clone(auto)}];
  assert.equal(api.installationLabel(),'Applied');api.state.draft.profiles[0].routes[2].teamMode='leadReview';assert.equal(api.installationLabel(),'Unapplied changes');
  api.state.data.installation.state='drifted';assert.equal(api.installationLabel(),'Settings changed');
  api.state.data.installation={state:'applied',installedPlatforms:['codex']};assert.equal(api.installationLabel(),'No preset applied');
});

test('Edit stages every row, Cancel restores the entry snapshot, and native review waits for Save',async()=>{
  const {api,nodes}=ready(),calls=[];api.state.dirty=true;api.state.selected='high';api.state.draft.customModels=[{id:'unused-custom',label:'Custom',platform:'codex',supportedEfforts:['low']}];
  const before=plain(api.state.draft),applied=clone(before);applied.profiles[0].routes[3].modelID='gpt-6-luna';api.state.data.installation={state:'applied',appliedConfiguration:applied,installedPlatforms:['codex','claude']};api.setBridge({ready:false,action:async request=>{calls.push(plain(request));return {ok:true,state:data()};}});
  await api.handleAction('edit');api.render();assert(api.state.advanced);assert(nodes.get('root').innerHTML.includes('data-action="saveEdit"'));assert(!api.sidebar().includes('Advanced'));assert(!nodes.get('root').innerHTML.includes('data-action="saveDraft"'));assert.equal((api.matrix().match(/data-field="model"/g)||[]).length,14);
  const marker=()=>api.assignment('codex','implementation').includes('>Edited</span>');assert.equal(marker(),false);assert(!api.assignment('codex','implementation').includes('data-action="compare"'));
  api.editField({dataset:{platform:'codex',task:'implementation',field:'model',index:'0'},value:'gpt-6-astra'});assert(marker());assert.match(api.assignment('codex','implementation'),/class="edited-control"/);api.editField({dataset:{platform:'codex',task:'implementation',field:'model',index:'0'},value:'gpt-6.1-sol'});assert.equal(marker(),false);api.editField({dataset:{platform:'codex',task:'implementation',field:'effort',index:'0'},value:'low'});assert(marker());api.editField({dataset:{platform:'codex',task:'implementation',field:'effort',index:'0'},value:'auto'});assert.equal(marker(),false);await api.handleAction('removeCustom',{id:'unused-custom'});await api.prepare();assert.equal(calls.length,0);
  await api.handleAction('cancelEdit');assert.deepEqual(plain(api.state.draft),before);assert.equal(api.state.selected,'high');assert.equal(api.state.dirty,true);assert.equal(api.state.advanced,false);assert.equal(calls.length,0);assert(api.assignment('codex','implementation').includes('data-action="compare"'));api.beginEdit();assert.equal(marker(),false);api.cancelEdit();
});
test('Save commits only the staged draft once, while a failed Save preserves editing',async()=>{
  const {api}=ready(),calls=[];let fail=true;api.setBridge({ready:false,action:async request=>{calls.push(plain(request));if(fail)throw Error('Draft could not be saved.');const value=data();value.configuration=plain(request.configuration);return {ok:true,state:value};}});
  await api.handleAction('edit');api.editField({dataset:{platform:'codex',task:'implementation',field:'model',index:'0'},value:'gpt-6-astra'});
  await api.handleAction('saveEdit');assert(api.state.advanced);assert(api.state.editSnapshot);assert.equal(api.state.draft.profiles[0].routes[3].modelID,'gpt-6-astra');
  fail=false;await api.handleAction('saveEdit');assert.equal(api.state.advanced,false);assert.equal(api.state.editSnapshot,null);assert.deepEqual(calls.map(x=>x.action),['saveDraft','saveDraft']);await api.handleAction('saveEdit');assert.equal(calls.length,2);
});

test('StandMixer has a shared mixer mark and explicit Web/Mac interface choices',()=>{
  const {api}=ready();assert.match(api.brand(),/StandMixer/);assert(!api.sidebar().includes('Activity'));assert.match(api.brand(),/M10 46H53/);assert.match(api.interfacePicker(),/Web · Current/);assert.match(api.interfacePicker(),/Mac · Install/);
  api.state.data.installedMac={isAvailable:true};assert.match(api.interfacePicker(),/data-action="openMac"/);assert(!api.interfacePicker().includes('data-action="installMac"'));
  api.setBridge({http:true});assert(!api.interfacePicker().includes('Open in browser'));
});
test('explicit interface launch preserves an unsaved Edit draft and uses host opening only after validation',async()=>{
  const {api}=ready(),calls=[],links=[],url='http://127.0.0.1:54321/#token='+'a'.repeat(43);
  api.setBridge({action:async request=>{calls.push(plain(request));return request.action==='openWeb'?{ok:true,web:{url}}:{ok:true,result:{message:'Opened Mac.'}};},rpc:async(method,args)=>{links.push({method,...args});return {};}});
  api.beginEdit();api.editField({dataset:{platform:'codex',task:'planning',field:'model',index:'0'},value:'gpt-6-astra'});const draft=plain(api.state.draft);
  await api.openInterface('web');await api.openInterface('mac');assert.deepEqual(calls,[{action:'openWeb'},{action:'openMac'}]);assert.deepEqual(links,[{method:'ui/open-link',url}]);assert.equal(api.state.advanced,true);assert.deepEqual(plain(api.state.draft),draft);assert(api.state.editSnapshot);
});
test('interface opening refuses remote or malformed URLs and respects host denial without a fallback launch',async()=>{
  const {api}=ready();let links=0;api.setBridge({action:async()=>({ok:true,web:{url:'https://example.test/#token=secret'}}),rpc:async()=>{links++;return {};}});
  await api.openInterface('web');assert.equal(links,0);assert.equal(api.state.interfaceError,true);assert.match(api.state.interfaceMessage,/invalid address/);
  for(const invalid of ['file:///tmp/x','http://127.0.0.1:0/#token='+'a'.repeat(43),'http://127.0.0.1:54321/path#token='+'a'.repeat(43),'http://127.0.0.1:54321/#token=short'])assert.throws(()=>api.safeWebURL(invalid),/invalid address/);
  api.setBridge({action:async()=>({ok:true,web:{url:'http://127.0.0.1:54321/#token='+'a'.repeat(43)}}),rpc:async()=>{links++;return {isError:true};}});await api.openInterface('web');assert.equal(links,1);assert.match(api.state.interfaceMessage,/host did not open/);assert.equal(api.state.interfaceError,true);
});

test('draft Undo and Redo are local, invalidate review, and dirty clears on return to baseline',async()=>{
  const {api}=ready(),calls=[];api.setBridge({action:async request=>{calls.push(plain(request));throw Error('No request expected');}});
  api.selectConfiguration(api.state.data.presets[0].configuration,'fast');assert(api.state.dirty);assert.equal(api.state.undoStack.length,1);
  api.state.preview=preview();await api.travelDraft();assert.equal(api.state.dirty,false);assert.equal(api.state.preview,null);assert.equal(api.state.undoStack.length,0);assert.equal(api.state.redoStack.length,1);
  await api.travelDraft(true);assert(api.state.dirty);api.selectConfiguration(api.state.data.presets[1].configuration,'optimized');assert.equal(api.state.dirty,false);const count=api.state.undoStack.length;api.selectConfiguration(api.state.data.presets[1].configuration,'optimized');assert.equal(api.state.undoStack.length,count);assert.equal(calls.length,0);
});
test('Undo survives Edit Save and saves only draft state when reversing a saved change',async()=>{
  const {api}=ready(),calls=[],saved=data();api.setBridge({action:async request=>{calls.push(plain(request));if(request.action==='saveDraft'){saved.configuration=clone(request.configuration);saved.enabledPlatforms=[...request.platforms];saved.hasSavedDraft=true;}return {ok:true,state:clone(saved),result:{message:'Draft saved'}};}});
  api.beginEdit();api.editField({dataset:{platform:'codex',task:'planning',field:'model',index:'0'},value:'gpt-6-astra'});assert(api.assignment('codex','planning').includes('>Edited</span>'));await api.travelDraft();assert(!api.assignment('codex','planning').includes('>Edited</span>'));await api.travelDraft(true);assert(api.assignment('codex','planning').includes('>Edited</span>'));await api.saveEdit();assert(!api.assignment('codex','planning').includes('>Edited</span>'));assert.equal(api.state.undoStack.length,1);assert.equal(api.state.dirty,false);
  await api.travelDraft();assert.equal(api.state.draft.profiles[0].routes[1].modelID,'gpt-6.1-sol');assert.equal(api.state.dirty,false);await api.travelDraft(true);assert.equal(api.state.draft.profiles[0].routes[1].modelID,'gpt-6-astra');assert.deepEqual(calls.map(x=>x.action),['saveDraft','saveDraft','saveDraft']);
});
test('failed saved Undo retains the current draft/history, and metadata refresh preserves Undo',async()=>{
  const {api}=ready(),saved=data();let fail=false;api.setBridge({action:async request=>{if(request.action==='saveDraft'){if(fail)throw Error('Draft write failed');saved.configuration=clone(request.configuration);saved.enabledPlatforms=[...request.platforms];saved.hasSavedDraft=true;}return {ok:true,state:clone(saved)};}});
  api.selectConfiguration(api.state.data.presets[0].configuration,'fast');await api.handleAction('saveDraft');const before=plain(api.state.draft);fail=true;await api.travelDraft();assert.deepEqual(plain(api.state.draft),before);assert.equal(api.state.undoStack.length,1);assert.equal(api.state.redoStack.length,0);assert.match(api.state.notice.text,/Draft write failed/);
  await api.handleAction('connections');assert.equal(api.state.undoStack.length,1);fail=false;await api.travelDraft();assert.equal(api.state.dirty,false);
});
test('Edit Cancel restores entry history, a new edit clears Redo, and Apply clears both stacks',async()=>{
  const {api}=ready();api.selectConfiguration(api.state.data.presets[0].configuration,'fast');api.beginEdit();api.editField({dataset:{platform:'codex',task:'planning',field:'model',index:'0'},value:'gpt-6-astra'});await api.travelDraft();api.cancelEdit();assert.equal(api.state.undoStack.length,1);assert.equal(api.state.redoStack.length,0);assert.equal(api.state.draft.profiles[0].routes[6].modelID,'gpt-6-luna');
  await api.travelDraft();api.editField({dataset:{platform:'codex',task:'planning',field:'model',index:'0'},value:'gpt-6-astra'});assert.equal(api.state.redoStack.length,0);api.setBridge({action:async request=>request.action==='preview'?{ok:true,preview:preview()}:{ok:true,state:data(),result:{message:'Applied'}}});await api.prepare();await api.applyReview();assert.equal(api.state.undoStack.length,0);assert.equal(api.state.redoStack.length,0);
});
test('draft shortcuts leave text Undo alone and applied restore lives only in Sources',async()=>{
  const {api,nodes}=ready();api.state.data.canRestore=true;api.selectConfiguration(api.state.data.presets[0].configuration,'fast');let prevented=false;const event={metaKey:true,ctrlKey:false,altKey:false,shiftKey:false,key:'z',preventDefault(){prevented=true},target:{closest:()=>({})}};
  assert.equal(api.draftShortcut(event),false);assert.equal(prevented,false);assert.equal(api.state.undoStack.length,1);event.target={closest:()=>null};assert.equal(api.draftShortcut(event),true);assert.equal(prevented,true);await Promise.resolve();assert.equal(api.state.dirty,false);
  assert(!api.sidebar().includes('previewRestore'));await api.handleAction('sources');assert.match(nodes.get('modal-root').innerHTML,/Restore applied settings/);assert(nodes.get('modal-root').innerHTML.includes('data-action="previewRestore"'));
});

test('Redo of an originally unsaved change stays local even after Undo reaches the saved baseline',async()=>{
  const {api}=ready(),saved=data(),calls=[];saved.hasSavedDraft=true;api.acceptState(saved);api.setBridge({action:async request=>{calls.push(plain(request));if(request.action==='saveDraft'){saved.configuration=clone(request.configuration);saved.enabledPlatforms=[...request.platforms];}return {ok:true,state:clone(saved)};}});
  api.selectConfiguration(api.state.data.presets[0].configuration,'fast');await api.travelDraft();assert.equal(api.state.dirty,false);await api.travelDraft(true);assert.equal(api.state.dirty,true);assert.equal(calls.length,0);
  await api.travelDraft();await api.handleAction('saveDraft');assert.equal(calls.length,1);await api.travelDraft(true);assert.equal(calls.length,1);assert.equal(api.state.dirty,true);
});
