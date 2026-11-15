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
  ['claude-opus-5-5','Opus 5.5','claude'], ['claude-fable-5-1','Fable 5.1','claude'], ['claude-fable-5-2','Fable 5.2','claude'],
  ['claude-sonnet-5-5','Sonnet 5.5','claude'], ['claude-haiku-5-5','Haiku 5.5','claude'],
].map(([id,label,platform])=>({id,label,platform,supportedEfforts:platform==='codex'?['low','medium','high','xhigh','max','ultra']:['low','medium','high','xhigh','max'],isDiscovered:false}));
function configuration(){return {customModels:[],enabledPlatforms:['codex','claude'],profiles:['codex','claude'].map(platform=>({platform,routes:categories.map(category=>({category,modelID:category==='coordinator'?'auto':platform==='codex'?'gpt-6.1-sol':'claude-opus-5-5',effort:clone(auto),additionalAgents:[],resultMode:'coordinator'}))}))};}
function data(){const config=configuration();const presets=['fast','optimized','high'].map(id=>({id,title:'StandMixer '+id,configuration:clone(config)}));presets[0].configuration.profiles[0].routes[6].modelID='gpt-6-luna';presets[2].configuration.profiles[0].routes[2].additionalAgents=[{id:'0c471eef-8bcc-4975-97ca-89a83bbb82de',modelID:'claude-fable-5-1',effort:clone(auto)}];return {configuration:config,canConnectClaude:false,hasSavedDraft:false,previousDraft:clone(config),enabledPlatforms:['codex','claude'],preferredPlatforms:['codex','claude'],availablePlatforms:['codex','claude'],presets,catalog:clone(models),connections:[],installation:{state:'notInstalled',summary:'Nothing applied',hasInstallation:false,installedPlatforms:[]},savedPresets:[],nativeSettings:[],canRestore:false,notes:[]};}
function preview(kind='apply'){return {id:'review-exact-id',kind,expiresAt:new Date(Date.now()+3600000).toISOString(),changedFiles:1,conflicts:[],changes:[{path:'/fixture/.codex/config.toml',reason:'Update saved model',isChanged:true,isDeletion:false,diff:{addedLineCount:1,removedLineCount:1,isCoarse:false,hasFinalNewlineChange:false,hunks:[{oldStart:1,oldCount:1,newStart:1,newCount:1,lines:[{kind:'removal',text:'model = "old"',oldLineNumber:1},{kind:'addition',text:'model = "new"',newLineNumber:1}]}]}}]};}
function load(window,overrides={}){const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{innerHTML:'',textContent:'',dataset:{},setAttribute(){},querySelectorAll(){return []},getBoundingClientRect(){return {height:680}}});return nodes.get(id);};const document={getElementById:node,querySelectorAll:()=>[],querySelector:()=>null,documentElement:{dataset:{},style:{setProperty(){}}}};const context={module:{exports:{}},console,URLSearchParams,AbortController,setTimeout,clearTimeout,crypto:webcrypto,FormData:class {constructor(form){this.entries=Object.entries(form.values||{});}[Symbol.iterator](){return this.entries[Symbol.iterator]();}},window,document,requestAnimationFrame:()=>0,...overrides};vm.runInNewContext(script,context,{filename:'standmixer-inline.js'});return {api:context.module.exports,nodes,document};}
function ready(){const loaded=load();loaded.api.acceptState(data());return loaded;}
function connectionReady(){const loaded=ready();loaded.api.state.data.canConnectClaude=true;return loaded;}

test('the loaded panel version is visible even when helper metadata differs',()=>{
  const {api}=ready();api.state.data.releaseVersion='99.0.0';
  assert.match(api.brand(),new RegExp('v'+api.PANEL_VERSION.replaceAll('.','\\.')));
  assert(!api.brand().includes('99.0.0'));
  assert.match(api.brand(),/aria-label="StandMixer panel version/);
});
test('Expand is offered only for an inline panel with host support',async()=>{
  const {api,nodes}=ready(),calls=[];api.setBridge({rpc:async(method,params)=>{calls.push({method,params});return {mode:'fullscreen'};}});
  api.state.host={displayMode:'fullscreen',availableDisplayModes:['inline','fullscreen']};api.render();
  assert(!nodes.get('root').innerHTML.includes('data-action="expand"'));
  await api.handleAction('expand');assert.equal(calls.length,0);
  api.state.host={displayMode:'inline',availableDisplayModes:['inline']};assert.equal(api.canExpand(),false);
  api.state.host.availableDisplayModes.push('fullscreen');api.render();
  assert(nodes.get('root').innerHTML.includes('data-action="expand"'));
  await api.handleAction('expand');
  assert.deepEqual(plain(calls),[{method:'ui/request-display-mode',params:{mode:'fullscreen'}}]);
  assert.equal(api.state.host.displayMode,'fullscreen');
  assert(!nodes.get('root').innerHTML.includes('data-action="expand"'));
});
test('a host that keeps the inline mode does not leave a dead expand button',async()=>{
  const {api,nodes}=ready();api.state.host={displayMode:'inline',availableDisplayModes:['inline','fullscreen']};
  api.setBridge({rpc:async()=>({mode:'inline'})});await api.handleAction('expand');
  assert.equal(api.state.expanding,false);assert.match(api.state.notice.text,/kept this panel/);
  assert(!nodes.get('root').innerHTML.includes('data-action="expand"'));
});

test('the deliverable is self contained and compatible with a hashed script CSP',()=>{
  assert.doesNotThrow(()=>new vm.Script(script));
  assert(!/<(?:script|link)[^>]+(?:src|href)=/i.test(html));
  assert(!/\son(?:click|change|load|submit)=/i.test(html));
  assert(!/eval\s*\(|new Function\s*\(/.test(script));
});
test('model strength matches all eight approved families, with unknown versions unrated',()=>{
  const {api}=load();assert.deepEqual(models.map(api.modelIdentity),[2,3,1,1,3,3,3,2,1]);
  assert.equal(api.modelIdentity({id:'claude-fable-5-2',label:'Fable 5.2',platform:'claude'}),3);
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
test('only known native coordinator changes are compared; legacy inspection is ignored',()=>{
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
  const rendered=api.matrix();assert.equal((rendered.match(/class="group-row"/g)||[]).length,6);assert(!rendered.includes('<select'));
  assert.match(rendered,/Code review/);assert.match(rendered,/Planning &amp; algorithms/);
  assert(rendered.includes('via Claude Code'));assert(rendered.includes('via claude'));
  assert.equal((rendered.match(/>Auto<\/button>/g)||[]).length,2);
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
  const bridge=new api.Bridge(win);await bridge.connect();const request=bridge.action({action:'state'});bridge.dispose();
  await assert.rejects(request,/interrupted/);assert.equal(signal.aborted,true);assert.equal(calls,1);
});
test('closing the panel propagates MCP cancellation for pending request IDs',async()=>{
  const {api}=load(),messages=[];const win={location:{hash:'',hostname:''},parent:{postMessage:m=>messages.push(plain(m))},addEventListener(){},removeEventListener(){}};
  const bridge=new api.Bridge(win);bridge.ready=true;const request=bridge.action({action:'state'}),id=messages[0].id;bridge.dispose();
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
  await assert.rejects(pending,/cancelled/);assert.deepEqual(messages[1],{jsonrpc:'2.0',method:'notifications/cancelled',params:{requestId:id,reason:'StandMixer request cancelled'}});assert.equal(bridge.ready,true);bridge.dispose();
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
  assert.deepEqual(calls.map(x=>x.action),['state']);assert.equal(api.inspect,undefined);
});
test('MCP opening arguments cannot trigger inference before or after state arrives',async()=>{
  const calls=[],listeners={},win={location:{hash:'',hostname:''},addEventListener:(name,fn)=>{listeners[name]=fn;},removeEventListener(){}};
  win.parent={postMessage:message=>{if(message.method==='ui/initialize')queueMicrotask(()=>{
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',method:'ui/notifications/tool-input',params:{arguments:{inspect:true}}}});
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{hostContext:{}}}});
  });else if(message.method==='tools/call'){calls.push(plain(message.params.arguments));queueMicrotask(()=>listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{structuredContent:{ok:true,state:data()}}}}));}}};
  const {api}=load(win);await api.initialize();
  listeners.message({source:win.parent,data:{jsonrpc:'2.0',method:'ui/notifications/tool-input',params:{arguments:{inspect:true}}}});
  await new Promise(resolve=>setImmediate(resolve));assert.deepEqual(calls.map(x=>x.action),['state']);assert.equal(api.inspect,undefined);
});
test('acknowledgement-only MCP opening loads state through the app-only tool',async()=>{
  const calls=[],listeners={},win={location:{hash:'',hostname:''},addEventListener:(name,fn)=>{listeners[name]=fn;},removeEventListener(){}};
  win.parent={postMessage:message=>{if(message.method==='ui/initialize')queueMicrotask(()=>{
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',method:'ui/notifications/tool-result',params:{structuredContent:{ok:true,result:{message:'StandMixer panel opened.'}}}}});
    listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{hostContext:{}}}});
  });else if(message.method==='tools/call'){calls.push(plain(message.params));queueMicrotask(()=>listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{structuredContent:{ok:true,state:data()}}}}));}}};
  const {api}=load(win);await api.initialize();
  assert.deepEqual(calls,[{name:'standmixer_action',arguments:{action:'state'}}]);
  assert.equal(api.state.data.presets.length,3);assert.equal(api.state.notice,null);assert.equal(api.inspect,undefined);
});
test('Sources and provider details expose only saved defaults and CLI installation data',async()=>{
  const {api,nodes}=ready(),calls=[];
  api.state.data.connections=[{platform:'codex',isInstalled:true,version:'codex 1.2.3',path:'/fixture/codex'}];
  api.state.data.nativeSettings=[{platform:'codex',status:'known',modelID:'gpt-6-luna',effort:'low',sourcePath:'/fixture/config.toml',detail:'Saved global defaults'}];
  api.setBridge({ready:false,action:async request=>{calls.push(plain(request));return {ok:true,state:data()};}});
  for(const [action,detail] of [['sources',{}],['connection',{platform:'codex'}]]){
    await api.handleAction(action,detail);const shown=nodes.get('modal-root').innerHTML;
    assert.match(shown,/codex 1.2.3/);assert.match(shown,/fixture\/config.toml/);assert.match(shown,/Luna 6/);assert.match(shown,/Effort: Low/);
    assert(!/Read preferences|Check CLI accounts|CLI account|Preference report|data-action="(?:inspect|checkAccounts)"/.test(shown));
  }
  await api.handleAction('inspect');await api.handleAction('checkAccounts');
  assert.deepEqual(calls,[]);assert.equal(api.inspect,undefined);assert.equal(api.checkAccounts,undefined);
});
test('Claude connection is optional, limited to supported native panels, and separate from Codex details',async()=>{
  const {api,nodes}=connectionReady(),calls=[];
  api.setBridge({http:false,action:async request=>{calls.push(request);return {ok:true};}});
  assert.match(api.sourceCard('claude'),/Connect Claude for Codex/);
  assert.match(api.sourceCard('claude'),/Let Codex launch Claude Code workers/);
  assert(!api.sourceCard('codex').includes('openClaudeConnection'));
  for(const [action,detail] of [['sources',{}],['connection',{platform:'claude'}]]){
    await api.handleAction(action,detail);assert(nodes.get('modal-root').innerHTML.includes('openClaudeConnection'));
  }
  assert.deepEqual(calls,[]);
  for(const [http,capability] of [[true,true],[false,false],[false,undefined]]){
    api.setBridge({http,action:async request=>{calls.push(request);return {ok:true};}});
    api.state.data.canConnectClaude=capability;
    assert(!api.sourceCard('claude').includes('openClaudeConnection'));
    await api.handleAction('closeModal');await api.handleAction('openClaudeConnection');
    assert.equal(api.state.modal,null);assert.deepEqual(calls,[]);
  }
});
test('opening Claude connection checks existing sign-in once and an existing connection needs only Done',async()=>{
  const {api,nodes}=connectionReady(),calls=[];
  api.setBridge({action:async(request,options)=>{calls.push({request:plain(request),signal:options.signal});return {ok:true,claudeConnection:{state:'connected',detail:'Ready for Claude Code workers.',email:'private@example.test',cliPath:'/private/fixture/claude',authURL:'https://example.test/private-auth'}};}});
  const draft=plain(api.state.draft);
  await api.handleAction('openClaudeConnection');
  assert.deepEqual(calls.map(x=>x.request),[{action:'checkClaudeConnection'}]);assert.equal(calls[0].signal.aborted,false);
  assert.equal(api.state.busy,false);assert.equal(api.state.claudeConnectionJob,null);
  const shown=nodes.get('modal-root').innerHTML;
  assert.match(shown,/Claude Code is connected/);assert.match(shown,/>Done<\/button>/);
  assert(!/Continue with Claude|private@example|private-auth|\/private\/fixture/.test(shown));
  await api.handleAction('connectClaude');assert.equal(calls.length,1);
  await api.handleAction('closeModal');assert.equal(api.state.modal,null);assert.equal(api.state.claudeConnection,null);
  assert.deepEqual(plain(api.state.draft),draft);
});
test('sign-in opens only after Continue with Claude and waits without polling or locking settings',async()=>{
  const {api,nodes}=connectionReady(),calls=[];let finish,loginSignal;
  api.setBridge({action:(request,options)=>{
    calls.push(plain(request));
    if(request.action==='checkClaudeConnection')return Promise.resolve({ok:true,claudeConnection:{state:'signInRequired',detail:'Claude Code needs a sign-in.'}});
    loginSignal=options.signal;return new Promise(resolve=>{finish=resolve;});
  }});
  await api.handleAction('openClaudeConnection');
  assert.deepEqual(calls,[{action:'checkClaudeConnection'}]);
  assert.match(nodes.get('modal-root').innerHTML,/Claude Desktop may use a different login/);
  assert.match(nodes.get('modal-root').innerHTML,/>Continue with Claude<\/button>/);
  const pending=api.handleAction('connectClaude');
  assert.equal(api.state.claudeConnection.state,'connecting');assert.equal(api.state.busy,false);
  assert.match(nodes.get('modal-root').innerHTML,/Finish signing in in your browser/);
  assert.match(nodes.get('modal-root').innerHTML,/>Cancel<\/button>/);
  assert(!/<input|<a |data-action="recheckClaudeConnection"|data-action="connectClaude"/.test(nodes.get('modal-root').innerHTML));
  await api.handleAction('connectClaude');await api.handleAction('recheckClaudeConnection');
  assert.deepEqual(calls,[{action:'checkClaudeConnection'},{action:'connectClaude'}]);
  finish({ok:true,claudeConnection:{state:'connected',detail:'Connected through Claude Code.'}});await pending;
  assert.equal(loginSignal.aborted,false);assert.equal(api.state.claudeConnection.state,'connected');
  assert.match(nodes.get('modal-root').innerHTML,/>Done<\/button>/);
  assert.deepEqual(calls,[{action:'checkClaudeConnection'},{action:'connectClaude'}]);
});
test('unknown, missing, and failed Claude checks offer Recheck without assuming sign-out',async()=>{
  for(const result of [{state:'unavailable',detail:'The network is unavailable.'},{state:'missing',detail:'Install Claude Code to connect.'},{state:'newFutureState',detail:'Unknown'},null]){
    const {api,nodes}=connectionReady();let attempts=0;
    api.setBridge({action:async request=>{assert.equal(request.action,'checkClaudeConnection');attempts++;return {ok:true,claudeConnection:attempts===1?result:{state:'connected',detail:'Connected.'}};}});
    await api.handleAction('openClaudeConnection');const shown=nodes.get('modal-root').innerHTML;
    assert.match(shown,/>Recheck<\/button>/);assert(!shown.includes('Continue with Claude'));
    await api.handleAction('connectClaude');assert.equal(attempts,1);
    await api.handleAction('recheckClaudeConnection');assert.equal(attempts,2);assert.equal(api.state.claudeConnection.state,'connected');
  }
  const {api,nodes}=connectionReady();let attempts=0;
  api.setBridge({action:async()=>{attempts++;throw Error('The check was interrupted.');}});
  await api.handleAction('openClaudeConnection');assert.equal(api.state.claudeConnection.state,'unavailable');
  assert.match(nodes.get('modal-root').innerHTML,/The check was interrupted/);
  assert(!nodes.get('modal-root').innerHTML.includes('Continue with Claude'));
  await api.handleAction('recheckClaudeConnection');assert.equal(attempts,2);
});
test('failed Claude sign-in returns to an explicit recheck and never retries login automatically',async()=>{
  const {api,nodes}=connectionReady(),calls=[];
  api.setBridge({action:async request=>{calls.push(request.action);if(request.action==='connectClaude')throw Error('The browser sign-in timed out.');return {ok:true,claudeConnection:{state:'signInRequired',detail:'Sign in to continue.'}};}});
  await api.handleAction('openClaudeConnection');await api.handleAction('connectClaude');
  assert.equal(api.state.claudeConnection.state,'unavailable');
  assert.match(nodes.get('modal-root').innerHTML,/>Recheck<\/button>/);
  await api.handleAction('connectClaude');assert.deepEqual(calls,['checkClaudeConnection','connectClaude']);
  await api.handleAction('recheckClaudeConnection');assert.match(nodes.get('modal-root').innerHTML,/>Continue with Claude<\/button>/);
});
test('dismissing Claude checks or login aborts the request and ignores a late result',async()=>{
  for(const login of [false,true]){
    const {api}=connectionReady(),calls=[];let finish,signal;
    api.setBridge({action:(request,options)=>{
      calls.push(request.action);
      if(login&&request.action==='checkClaudeConnection')return Promise.resolve({ok:true,claudeConnection:{state:'signInRequired',detail:'Sign in.'}});
      signal=options.signal;return new Promise(resolve=>{finish=resolve;});
    }});
    let pending=api.handleAction('openClaudeConnection');
    if(login){await pending;pending=api.handleAction('connectClaude');}
    await api.handleAction('closeModal');assert.equal(signal.aborted,true);assert.equal(api.state.modal,null);
    assert.equal(api.state.claudeConnectionJob,null);assert.equal(api.state.busy,false);
    finish({ok:true,claudeConnection:{state:'connected',detail:'Late result'}});await pending;
    assert.equal(api.state.modal,null);assert.equal(api.state.claudeConnection,null);assert.equal(api.state.notice,null);
    assert.deepEqual(calls,login?['checkClaudeConnection','connectClaude']:['checkClaudeConnection']);
    await api.handleAction('advanced');assert.equal(api.state.advanced,true);
  }
});
test('changing dialogs cancels Claude login and an older completion cannot replace a new check',async()=>{
  const {api,nodes}=connectionReady();let oldFinish,oldSignal;
  api.setBridge({action:(_request,options)=>{oldSignal=options.signal;return new Promise(resolve=>{oldFinish=resolve;});}});
  const previous=api.handleAction('openClaudeConnection');await api.handleAction('sources');
  assert.equal(oldSignal.aborted,true);assert.equal(api.state.modal.kind,'sources');
  api.setBridge({action:async()=>({ok:true,claudeConnection:{state:'signInRequired',detail:'Fresh result'}})});
  await api.handleAction('openClaudeConnection');
  oldFinish({ok:true,claudeConnection:{state:'connected',detail:'Old result'}});await previous;
  assert.equal(api.state.claudeConnection.state,'signInRequired');assert.match(nodes.get('modal-root').innerHTML,/Fresh result/);
  assert(!nodes.get('modal-root').innerHTML.includes('Old result'));
});
test('Claude dialog cancellation and MCP panel teardown cancel the matching backend request',async()=>{
  for(const teardown of [false,true]){
    const {api}=connectionReady(),messages=[];
    const win={location:{hash:'',hostname:''},parent:{postMessage:m=>messages.push(plain(m))},addEventListener(){},removeEventListener(){}};
    const bridge=new api.Bridge(win);bridge.ready=true;api.setBridge(bridge);
    const pending=api.handleAction('openClaudeConnection'),request=messages[0],signal=api.state.claudeConnectionJob.signal;
    if(teardown)bridge.receive({source:win.parent,data:{jsonrpc:'2.0',id:'teardown',method:'ui/resource-teardown'}});
    else await api.handleAction('closeModal');
    await pending;
    assert.equal(signal.aborted,true);assert.equal(api.state.modal,null);assert.equal(api.state.claudeConnectionJob,null);
    assert(messages.some(m=>m.method==='notifications/cancelled'&&m.params.requestId===request.id));
    assert.equal(bridge.ready,!teardown);bridge.dispose();
  }
});
test('Claude check and login have bounded deadlines that cancel the backend on timeout',async()=>{
  for(const [action,timeout] of [['checkClaudeConnection',20000],['connectClaude',350000]]){
    let timer;const messages=[];
    const {api}=load(undefined,{setTimeout:(callback,milliseconds)=>{timer={callback,milliseconds};return 1;},clearTimeout(){}});
    const win={location:{hash:'',hostname:''},parent:{postMessage:m=>messages.push(plain(m))},addEventListener(){},removeEventListener(){}};
    const bridge=new api.Bridge(win);bridge.ready=true;
    const pending=bridge.action({action}),id=messages[0].id;assert.equal(timer.milliseconds,timeout);
    timer.callback();await assert.rejects(pending,/unresolved/);
    assert.deepEqual(messages[1],{jsonrpc:'2.0',method:'notifications/cancelled',params:{requestId:id,reason:'StandMixer request timed out'}});
    assert.equal(bridge.pending.size,0);bridge.dispose();
  }
});
test('automatic connection triggers resolve every Codex worker role through the catalog and ignore the reverse direction',()=>{
  const {api}=connectionReady(),before=configuration();
  for(const role of ['lead','team','judge','escalation']){
    const after=clone(before),route=after.profiles[0].routes[1];
    if(role==='lead')route.modelID='claude-opus-5-5';
    if(role==='team')route.additionalAgents=[{modelID:'claude-opus-5-5',effort:clone(auto)}];
    if(role==='judge'){route.resultMode='ai';route.judgeModelID='claude-opus-5-5';}
    if(role==='escalation')route.stuckEscalation=[{modelID:'claude-opus-5-5',effort:clone(auto)}];
    assert(api.introducesClaudeForCodex(before,after),role);
    assert(!api.introducesClaudeForCodex(after,after),role);
  }
  const reverse=clone(before);reverse.profiles[1].routes[1].modelID='gpt-6-astra';
  assert(!api.introducesClaudeForCodex(before,reverse));
  const unknown=clone(before);unknown.profiles[0].routes[1].modelID='claude-looking-unknown';
  assert(!api.introducesClaudeForCodex(before,unknown));
  unknown.profiles[0].routes[1].modelID='custom-claude';api.state.data.catalog.push({id:'custom-claude',label:'Custom',platform:'claude'});
  assert(api.introducesClaudeForCodex(before,unknown));
});
test('Not now suppresses repeated checks but an explicit new Claude choice re-arms the prompt',async()=>{
  const {api,nodes}=connectionReady(),calls=[];let finish;
  api.setBridge({action:request=>{calls.push(plain(request));if(request.action==='checkClaudeConnection')return new Promise(resolve=>{finish=resolve;});return Promise.resolve({ok:true,state:data()});}});
  await api.editInlineField({dataset:{platform:'codex',task:'planning',field:'model',index:'0',inline:'true'},value:'claude-opus-5-5'});
  assert.equal(api.state.modal,null);assert.equal(api.state.busy,false);assert.equal(api.state.savingDraft,false);
  assert(calls.some(x=>x.action==='saveDraft'&&x.configuration.profiles[0].routes[1].modelID==='claude-opus-5-5'));
  const check=api.state.claudeQuietPromise;finish({ok:true,claudeConnection:{state:'signInRequired',detail:'Sign in needed.'}});await check;
  assert.match(nodes.get('modal-root').innerHTML,/>Not now<\/button>/);
  await api.handleAction('closeModal');assert.equal(api.state.claudePromptSuppressed,true);
  await api.offerClaudeConnection();assert.equal(calls.filter(x=>x.action==='checkClaudeConnection').length,1);
  await api.editInlineField({dataset:{platform:'codex',task:'planning',field:'model',index:'0',inline:'true'},value:'claude-fable-5-2'});
  assert.equal(calls.filter(x=>x.action==='checkClaudeConnection').length,2);
  const nextCheck=api.state.claudeQuietPromise;finish({ok:true,claudeConnection:{state:'signInRequired',detail:'Sign in needed.'}});await nextCheck;
  assert.equal(api.state.modal.kind,'claudeConnection');await api.handleAction('closeModal');
  api.setBridge({action:async()=>({ok:true,claudeConnection:{state:'connected',detail:'Connected.'}})});
  await api.handleAction('openClaudeConnection');assert.equal(api.state.claudePromptSuppressed,false);assert.equal(api.state.claudeConnectionConfirmed,true);
});
test('connected checks stay quiet and unknown checks show a problem without blaming sign-in',async()=>{
  for(const status of ['connected','unavailable']){
    const {api,nodes}=connectionReady(),calls=[];
    api.setBridge({action:async request=>{calls.push(request.action);return request.action==='state'?{ok:true,state:{...data(),canConnectClaude:true}}:{ok:true,claudeConnection:{state:status,detail:'Fixture'}};}});
    api.render();await api.handleAction('sources');await api.handleAction('closeModal');await api.handleAction('connections');
    api.editField({dataset:{platform:'claude',task:'planning',field:'model',index:'0'},value:'gpt-6-astra'});
    assert.deepEqual(calls,['state']);
    api.editField({dataset:{platform:'codex',task:'planning',field:'model',index:'0'},value:'claude-opus-5-5'});
    await api.state.claudeQuietPromise;
    if(status==='connected')assert.equal(api.state.modal,null);else{assert.equal(api.state.modal.kind,'claudeConnection');assert.match(nodes.get('modal-root').innerHTML,/>Recheck<\/button>/);assert(!nodes.get('modal-root').innerHTML.includes('Continue with Claude'));}
    assert.deepEqual(calls,['state','checkClaudeConnection']);
    assert.equal(api.state.claudeConnectionConfirmed,status==='connected');
  }
});
test('selecting a preset with Codex Claude workers checks quietly and missing CLI offers Not now',async()=>{
  const {api,nodes}=connectionReady(),calls=[];
  api.setBridge({action:async request=>{calls.push(request.action);return {ok:true,claudeConnection:{state:'missing',detail:'Install Claude Code.'}};}});
  await api.handleAction('preset',{id:'high'});await api.state.claudeQuietPromise;
  assert.deepEqual(calls,['checkClaudeConnection']);assert.match(nodes.get('modal-root').innerHTML,/Not now/);
  assert.equal(api.state.selected,'high');await api.handleAction('closeModal');assert.equal(api.state.selected,'high');
});
test('Review checks an existing cross-provider preset and Not now resumes only its exact preview',async()=>{
  const {api}=connectionReady(),calls=[];api.state.draft.profiles[0].routes[1].modelID='claude-opus-5-5';
  api.setBridge({action:async request=>{calls.push(plain(request));return request.action==='checkClaudeConnection'?{ok:true,claudeConnection:{state:'signInRequired',detail:'Sign in.'}}:{ok:true,preview:preview()};}});
  api.render();assert.deepEqual(calls,[]);
  await api.prepare();assert.equal(api.state.modal.kind,'claudeConnection');assert.deepEqual(calls.map(x=>x.action),['checkClaudeConnection']);
  await api.handleAction('closeModal');assert.equal(api.state.modal.kind,'review');
  assert.deepEqual(calls.map(x=>x.action),['checkClaudeConnection','preview']);assert.equal(calls[1].configuration.profiles[0].routes[1].modelID,'claude-opus-5-5');
  await api.handleAction('closeModal');await api.prepare();assert.deepEqual(calls.map(x=>x.action),['checkClaudeConnection','preview','preview']);
});
test('editing and saving only Claude then reviewing does not authenticate an unchanged applied Codex profile',async()=>{
  for(const installationState of ['applied','drifted']){
    const {api}=connectionReady(),calls=[],incoming=data();incoming.canConnectClaude=true;
    incoming.configuration.profiles[0].routes[1].modelID='claude-opus-5-5';
    incoming.installation={state:installationState,appliedConfiguration:clone(incoming.configuration),installedPlatforms:['codex','claude']};
    api.acceptState(incoming);
    api.setBridge({action:async request=>{calls.push(request.action);if(request.action==='saveDraft')return {ok:true,state:{...incoming,configuration:clone(request.configuration)}};return {ok:true,preview:preview()};}});
    await api.handleAction('advanced');
    api.editField({dataset:{platform:'claude',task:'planning',field:'model',index:'0'},value:'claude-fable-5-2'});
    await api.saveEdit();assert.equal(api.claudePreviewNeedsCheck(),false);
    await api.prepare();assert.equal(api.state.modal.kind,'review');
    assert.deepEqual(calls,['saveDraft','preview']);
  }
});
test('a changed or newly enabled Codex profile remains eligible for a preview connection check',()=>{
  const {api}=connectionReady(),baseline=configuration();baseline.profiles[0].routes[1].modelID='claude-opus-5-5';
  api.state.draft=clone(baseline);api.state.data.installation={appliedConfiguration:clone(baseline),installedPlatforms:['codex','claude']};
  assert.equal(api.claudePreviewNeedsCheck(),false);
  api.state.draft.profiles[0].routes[1].effort={...auto,mode:'fixed',value:'max'};
  assert.equal(api.claudePreviewNeedsCheck(),true);
  api.state.draft=clone(baseline);api.state.data.installation.installedPlatforms=['claude'];
  assert.equal(api.claudePreviewNeedsCheck(),true);
});
test('successful optional sign-in resumes only the user-requested preview on Done',async()=>{
  const {api}=connectionReady(),calls=[];api.state.draft.profiles[0].routes[1].modelID='claude-opus-5-5';
  api.setBridge({action:async request=>{calls.push(request.action);return request.action==='preview'?{ok:true,preview:preview()}:{ok:true,claudeConnection:{state:request.action==='connectClaude'?'connected':'signInRequired',detail:'Fixture'}};}});
  await api.prepare();await api.handleAction('connectClaude');assert.equal(api.state.modal.kind,'claudeConnection');
  await api.handleAction('closeModal');assert.equal(api.state.modal.kind,'review');assert.deepEqual(calls,['checkClaudeConnection','connectClaude','preview']);
});
test('legacy inspection and account payloads never appear or affect current comparisons',async()=>{
  for(const status of ['complete','partial']){
    const {api,nodes}=ready(),incoming=data();
    incoming.nativeSettings=[{platform:'codex',status:'known',modelID:'gpt-6.1-sol',sourcePath:'/fixture/config.toml',detail:'Saved global defaults'}];
    incoming.inspection={expiresAt:new Date(Date.now()+60000).toISOString(),reports:[{platform:'codex',status,summary:'Legacy report',routes:[{category:'planning',modelID:'gpt-6-luna',scope:'usual',evidence:[],uncertainties:['Legacy uncertainty']},{category:'coordinator',modelID:'gpt-6-astra',scope:'current',evidence:[],uncertainties:[]}]}]};
    incoming.accounts={providers:[{platform:'codex',status:'signedIn',email:'legacy-account@example.test'}]};
    api.acceptState(incoming);api.state.inspection=incoming.inspection;
    assert.equal(api.observed('codex','planning'),null);assert.equal(api.observed('codex','coordinator').modelID,'gpt-6.1-sol');
    assert(!api.assignment('codex','planning').includes('change-badge'));assert(!api.assignment('codex','coordinator').includes('change-badge'));
    await api.handleAction('sources');assert(!/Legacy|legacy-account|Preference observations|CLI account/.test(nodes.get('modal-root').innerHTML));
    const applied=configuration();applied.profiles[0].routes[1].modelID='gpt-6-astra';
    api.state.data.installation={state:'applied',appliedConfiguration:applied,installedPlatforms:['codex']};
    assert.equal(api.observed('codex','planning').modelID,'gpt-6-astra');
    api.state.data.installation.state='drifted';assert.equal(api.observed('codex','planning'),null);
  }
});
test('provider changes, refresh, presets, and reviewed commits never request inspection or accounts',async()=>{
  for(const kind of ['apply','restore','uninstall']){
    const {api,nodes}=ready(),calls=[],incoming=data();
    incoming.inspection={reports:[{platform:'codex',summary:'Legacy result',routes:[{category:'planning',modelID:'gpt-6-luna'}]}]};
    api.setBridge({ready:false,action:async request=>{calls.push(plain(request));return {ok:true,state:incoming,result:{message:'Completed '+kind}};}});
    await api.handleAction('togglePlatform',{platform:'claude'});await api.handleAction('connections');await api.handleAction('preset',{id:'fast'});
    api.state.modal={kind:'review'};api.state.preview=preview(kind);await api.applyReview();await api.handleAction('sources');
    assert.deepEqual(calls.map(x=>x.action),['state','state',kind]);assert.equal(api.observed('codex','planning'),null);
    assert(!nodes.get('modal-root').innerHTML.includes('Legacy result'));assert.equal(api.state.notice.text,'Completed '+kind);
  }
});

test('Controller Auto preserves the native-model distinction and hides effort controls',()=>{
  const {api}=ready(),r=api.state.draft.profiles[0].routes[0];
  api.state.data.nativeSettings=[{platform:'codex',status:'known',modelID:'gpt-6-luna',effort:'low',sourcePath:'/fixture/config.toml'}];
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'model',index:'0'},value:'auto'});
  assert.equal(r.modelID,'auto');assert.deepEqual(plain(r.effort),auto);
  const rendered=api.assignment('codex','coordinator');
  assert.match(rendered,/>Auto<\/button>/);assert.match(rendered,/Current model/);assert(!rendered.includes('change-badge'));assert(!rendered.includes('Unrated model'));
  api.state.advanced=true;const advanced=api.assignment('codex','coordinator',true);
  assert.match(advanced,/<option value="auto" selected>Auto · Current model<\/option>/);assert(!advanced.includes('data-field="effort"'));assert(!advanced.includes('data-field="team"'));
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'effort',index:'0'},value:'ultra'});assert.equal(r.effort.mode,'auto');
  api.editField({dataset:{platform:'codex',task:'coordinator',field:'model',index:'0'},value:'gpt-6.1-sol'});
  assert.equal(r.modelID,'gpt-6.1-sol');assert(api.assignment('codex','coordinator',true).includes('data-field="effort"'));
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

test('saved default and CLI source fields are escaped, with unavailable defaults left unknown',()=>{
  const {api}=ready();api.state.data.connections=[{platform:'codex',isInstalled:true,version:'<version>',path:'<path>'}];
  api.state.data.nativeSettings=[{platform:'codex',status:'unavailable',modelID:'gpt-6-luna',sourcePath:'<source>',detail:'<script>unsafe</script>'}];
  const shown=api.sourceCard('codex');assert(!shown.includes('<script>'));assert.match(shown,/&lt;version&gt;/);assert.match(shown,/&lt;source&gt;/);
  assert.match(shown,/>Unknown</);assert(!shown.includes('Luna 6'));assert.equal(api.observed('codex','coordinator'),null);
});
test('team mode distinguishes lead review from independent passes without changing worker order',()=>{
  const {api}=ready(),route=api.state.draft.profiles[0].routes[2];route.additionalAgents=[{id:'second',modelID:'gpt-6-astra',effort:clone(auto)}];
  const legacy=api.routeKey(route);api.editField({dataset:{platform:'codex',task:'ui',field:'teamMode'},value:'leadReview'});assert.notEqual(api.routeKey(route),legacy);assert.equal(route.modelID,'gpt-6.1-sol');assert.equal(route.additionalAgents[0].modelID,'gpt-6-astra');api.state.advanced=true;assert.match(api.assignment('codex','ui',true),/Lead/);assert.match(api.assignment('codex','ui',true),/Worker 2/);
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

test('Edit stages one row, Cancel restores the entry snapshot, and native review waits for Save',async()=>{
  const {api,nodes}=ready(),calls=[];api.state.dirty=true;api.state.selected='high';api.state.draft.customModels=[{id:'unused-custom',label:'Custom',platform:'codex',supportedEfforts:['low']}];
  const before=plain(api.state.draft),applied=clone(before);applied.profiles[0].routes[3].modelID='gpt-6-luna';api.state.data.installation={state:'applied',appliedConfiguration:applied,installedPlatforms:['codex','claude']};api.setBridge({ready:false,action:async request=>{calls.push(plain(request));return {ok:true,state:data()};}});
  await api.handleAction('edit');api.render();assert(api.state.advanced);assert(nodes.get('root').innerHTML.includes('data-action="saveEdit"'));assert(!api.sidebar().includes('Advanced'));assert(!nodes.get('root').innerHTML.includes('data-action="saveDraft"'));assert.equal((api.matrix().match(/data-field="model"/g)||[]).length,2);await api.handleAction('editRow',{task:'implementation'});assert.equal((api.matrix().match(/class="row-editor"/g)||[]).length,1);
  const marker=()=>api.assignment('codex','implementation').includes('>Edited</span>');assert.equal(marker(),false);assert(!api.assignment('codex','implementation').includes('data-action="compare"'));
  api.editField({dataset:{platform:'codex',task:'implementation',field:'model',index:'0'},value:'gpt-6-astra'});assert(marker());assert.match(api.assignment('codex','implementation',true),/class="edited-control"/);api.editField({dataset:{platform:'codex',task:'implementation',field:'model',index:'0'},value:'gpt-6.1-sol'});assert.equal(marker(),false);api.editField({dataset:{platform:'codex',task:'implementation',field:'effort',index:'0'},value:'low'});assert(marker());api.editField({dataset:{platform:'codex',task:'implementation',field:'effort',index:'0'},value:'auto'});assert.equal(marker(),false);await api.handleAction('removeCustom',{id:'unused-custom'});await api.prepare();assert.equal(calls.length,0);
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

test('version checks are capability-gated and never block or overwrite edits',async()=>{
  const {api,nodes}=ready();let calls=0,finish;const pending=new Promise(resolve=>{finish=resolve;});
  api.setBridge({action:async request=>{assert.equal(request.action,'checkUpdates');calls++;return pending;}});
  await api.checkUpdates();assert.equal(calls,0);
  api.state.data.canCheckUpdates=true;const check=api.checkUpdates();assert.equal(api.state.busy,false);
  await api.checkUpdates();assert.equal(calls,1);
  api.beginEdit();api.editField({dataset:{platform:'codex',task:'planning',field:'model',index:'0'},value:'gpt-6-astra'});
  const draft=plain(api.state.draft),markup=nodes.get('root').innerHTML;
  finish({ok:true,update:{currentVersion:'0.1.2',latestVersion:'0.2.0'}});await check;
  assert.deepEqual(plain(api.state.draft),draft);assert.equal(nodes.get('root').innerHTML,markup);
  assert(api.updateNotice().includes('Update available · 0.2.0'));
});
test('offline or current-version responses never create errors or an update notice',async()=>{
  const {api}=ready();api.state.data.canCheckUpdates=true;
  api.setBridge({action:async()=>{throw Error('Offline');}});await api.checkUpdates();
  assert.equal(api.state.notice,null);assert.equal(api.updateNotice(),'');assert.equal(api.state.busy,false);
  api.setBridge({action:async()=>({ok:true})});await api.checkUpdates();assert.equal(api.updateNotice(),'');
});


test('Check now bypasses the cache without changing edits and shows the version and last check',async()=>{
  const {api}=ready();api.state.data.canCheckUpdates=true;api.state.data.releaseVersion='0.1.5';
  const before=plain(api.state.draft),requests=[];
  api.setBridge({action:async request=>{requests.push(plain(request));return {ok:true,updateStatus:{currentVersion:'0.1.5',latestVersion:'0.1.5',checkedAt:'2026-11-05T12:00:00Z',outcome:'current'}};}});
  await api.checkUpdates(true);assert.deepEqual(requests,[{action:'checkUpdates',refresh:true}]);
  assert.deepEqual(plain(api.state.draft),before);assert.match(api.updateControls(),new RegExp('StandMixer '+api.PANEL_VERSION.replaceAll('.','\\.')));assert.match(api.updateControls(),/Last checked/);assert.match(api.updateControls(),/Up to date/);
  assert.equal(api.state.checkingUpdates,false);assert.equal(api.updateNotice(),'');
});


test('Fable 5.2 is selectable with a cross-provider badge',()=>{
  const {api}=ready();api.beginEdit();api.editField({dataset:{platform:'codex',task:'algorithms',field:'model',index:'0'},value:'claude-fable-5-2'});
  assert.equal(api.state.draft.profiles.find(p=>p.platform==='codex').routes.find(r=>r.category==='algorithms').modelID,'claude-fable-5-2');
  assert.match(api.assignment('codex','algorithms'),/Fable 5.2/);
});


test('main view shows fixed and range efforts even when applied, and hides Auto',()=>{
 const {api}=ready();const route=api.state.draft.profiles.find(p=>p.platform==='codex').routes.find(r=>r.category==='algorithms');
 assert.doesNotMatch(api.assignment('codex','algorithms'),/effort-badge/);
 route.effort={mode:'fixed',value:'high'};api.state.data.installation.appliedConfiguration=clone(api.state.draft);
 assert.match(api.assignment('codex','algorithms'),/aria-label="Effort: High"/);
 route.additionalAgents=[{id:'second',modelID:'claude-opus-5-5',effort:{mode:'range',minimum:'low',maximum:'max'}}];
 const html=api.assignment('codex','algorithms');assert.match(html,/Effort: Low–Max/);assert.match(html,/via Claude Code/);
 route.effort={mode:'auto'};route.additionalAgents=[];assert.doesNotMatch(api.assignment('codex','algorithms'),/effort-badge/);
});

function withChildren(api){
  for(const profile of api.state.draft.profiles){
    if(!profile.routes.some(route=>route.category==='research'))profile.routes.push({...clone(profile.routes[1]),category:'research'});
    for(const [child,parent] of Object.entries(api.PARENTS)){
      if(profile.routes.some(route=>route.category===child))continue;
      const route=clone(profile.routes.find(route=>route.category===parent));
      profile.routes.push({...route,category:child,inheritsModel:true,inheritsEffort:true,inheritsTeam:true});
    }
  }
}
test('six comparison groups keep inherited children collapsed and remember manual disclosure',async()=>{
  const {api}=ready();withChildren(api);
  assert.equal(api.GROUPS.length,6);assert(!api.matrix().includes('<select'));
  assert(!api.matrix().includes('data-route-id="uiBuild"'));
  await api.handleAction('disclose',{task:'ui'});assert(api.matrix().includes('data-route-id="uiBuild"'));
  await api.handleAction('disclose',{task:'ui'});api.editField({dataset:{platform:'codex',task:'uiBuild',field:'effort',index:'0'},value:'max'});
  assert(!api.matrix().includes('data-route-id="uiBuild"'));await api.handleAction('disclose',{task:'ui'});assert(api.matrix().includes('data-route-id="uiBuild"'));assert.match(api.assignment('codex','uiBuild'),/data-effort="max"/);
  await api.handleAction('editRow',{task:'implementation'});assert.equal((api.matrix().match(/class="row-editor"/g)||[]).length,1);
  await api.handleAction('editRow',{task:'review'});assert.equal((api.matrix().match(/class="row-editor"/g)||[]).length,1);assert(api.matrix().includes('Codex Code review Model'));
});
test('child model, effort, and ordered team inheritance resolve and reset independently',async()=>{
  const {api}=ready();withChildren(api);const parent=api.state.draft.profiles[0].routes.find(r=>r.category==='review'),child=api.state.draft.profiles[0].routes.find(r=>r.category==='securityReview');
  parent.modelID='gpt-6-astra';parent.effort={mode:'fixed',value:'max'};parent.additionalAgents=[{id:'second',modelID:'claude-fable-5-2',effort:{mode:'fixed',value:'high'}}];
  assert.equal(api.getEffective('codex','securityReview').modelID,'gpt-6-astra');assert.equal(api.getEffective('codex','securityReview').additionalAgents[0].modelID,'claude-fable-5-2');
  api.editField({dataset:{platform:'codex',task:'securityReview',field:'model',index:'0'},value:'claude-fable-5-2'});
  assert.equal(child.inheritsModel,false);assert.equal(child.inheritsEffort,true);assert.equal(child.inheritsTeam,true);
  api.editField({dataset:{platform:'codex',task:'securityReview',field:'effort',index:'0'},value:'medium'});assert.equal(child.inheritsEffort,false);assert.equal(parent.effort.value,'max');
  api.editField({dataset:{platform:'codex',task:'securityReview',field:'model',index:'1'},value:'gpt-6-luna'});assert.equal(child.inheritsTeam,false);assert.equal(parent.additionalAgents[0].modelID,'claude-fable-5-2');
  api.editField({dataset:{platform:'codex',task:'securityReview',field:'effort',index:'0'},value:'parent'});assert.equal(api.getEffective('codex','securityReview').effort.value,'max');assert.equal(child.inheritsModel,false);
  await api.handleAction('inheritAll',{platform:'codex',task:'securityReview'});assert(child.inheritsModel&&child.inheritsEffort&&child.inheritsTeam);assert.equal(api.getEffective('codex','securityReview').modelID,'gpt-6-astra');
});
test('recipe identity includes inheritance policy while ignoring inactive inherited snapshots',()=>{
  const {api}=ready();withChildren(api);const before=clone(api.state.draft),after=clone(before),route=after.profiles[0].routes.find(r=>r.category==='uiBuild');
  route.modelID='gpt-6-luna';assert.equal(api.recipeKey(before,['codex']),api.recipeKey(after,['codex']));route.inheritsModel=false;assert.notEqual(api.recipeKey(before,['codex']),api.recipeKey(after,['codex']));
});
test('effort indicators represent fixed, range, Auto and Ultra without rating models',()=>{
  const {api}=ready();assert.match(api.effortBars({mode:'fixed',value:'max'}),/data-effort="max"/);assert.equal((api.effortBars({mode:'fixed',value:'max'}).match(/class="filled"/g)||[]).length,5);
  const range=api.effortBars({mode:'range',minimum:'medium',maximum:'max'});assert.equal((range.match(/class="filled"/g)||[]).length,2);assert.equal((range.match(/class="range"/g)||[]).length,3);assert.match(range,/Effort: Medium–Max/);
  assert.match(api.effortBars(auto),/Auto, follows caller/);assert(!api.effortBars(auto).includes('<i'));assert.equal((api.effortBars({mode:'fixed',value:'ultra'}).match(/class="filled"/g)||[]).length,6);
  assert(!api.assignment('codex','planning').includes('Model level'));
});


test('When stuck is an ordered independent policy with local edits, identity, and no parallel team mutation',async()=>{
  const {api}=ready();withChildren(api);const route=api.state.draft.profiles[0].routes.find(r=>r.category==='debugging');
  route.stuckEscalation=['claude-fable-5-2','gpt-6-astra','claude-opus-5-5'].map((modelID,index)=>({id:'step-'+index,modelID,effort:{mode:'fixed',value:'max'}}));
  const before=api.routeKey(route),copy=clone(route);copy.stuckEscalation[0].id='new-id';assert.equal(api.routeKey(copy),before);copy.stuckEscalation.reverse();assert.notEqual(api.routeKey(copy),before);
  const shown=api.escalationSummary('codex',route);assert(shown.indexOf('Fable 5.2')<shown.indexOf('Astra 6'));assert(shown.indexOf('Astra 6')<shown.indexOf('Opus 5.5'));assert.match(shown,/via Claude Code/);
  api.editField({dataset:{platform:'codex',task:'debugging',field:'stuckEffort',escalationIndex:'0'},value:'medium'});assert.equal(route.stuckEscalation[0].effort.value,'medium');assert.equal(route.inheritsEffort,true);assert.equal(route.additionalAgents.length,0);
  api.editField({dataset:{platform:'codex',task:'debugging',field:'stuckModel',escalationIndex:'0'},value:'gpt-6-astra'});assert.equal(route.stuckEscalation[0].modelID,'claude-fable-5-2');assert.match(api.state.notice.text,/different model/);
  await api.handleAction('moveEscalation',{platform:'codex',task:'debugging',index:'1',direction:'up'});assert.equal(route.stuckEscalation[0].modelID,'gpt-6-astra');assert.equal(route.additionalAgents.length,0);
  await api.handleAction('inheritAll',{platform:'codex',task:'debugging'});assert.equal(route.stuckEscalation.length,3);await api.handleAction('removeEscalation',{platform:'codex',task:'debugging',index:'1'});assert.equal(route.stuckEscalation.length,2);
});

test('manual collapse hides differing and equal pins while assignment tiers remain unchanged',async()=>{
  const {api}=ready();withChildren(api);api.state.expanded.ui=false;
  assert(!api.matrix().includes('inherits parent settings'));assert(!api.matrix().includes('data-route-id="uiBuild"'));
  const route=api.state.draft.profiles[0].routes.find(r=>r.category==='uiBuild');route.inheritsEffort=false;route.effort={mode:'fixed',value:'medium'};
  assert(!api.matrix().includes('data-route-id="uiBuild"'));const effortOnly=api.assignment('codex','uiBuild');assert.match(effortOnly,/data-effort="medium"/);assert(effortOnly.includes('Sol 6.1'));
  route.effort=clone(api.getEffective('codex','ui').effort);assert.equal(api.childVisible('uiBuild',api.state.platforms),false);assert(!api.matrix().includes('data-route-id="uiBuild"'));
  const shown=api.assignment('codex','planning');assert.match(shown,/Model tier 2 of 3/);assert.equal((shown.match(/class="model-tier"/g)||[]).length,1);assert(!shown.includes('Model level'));
});


test('matrix dividers belong to complete semantic groups and collapse removes child editors and differences',async()=>{
  const {api}=ready();withChildren(api);api.state.expanded.planning=true;
  let markup=api.matrix(),groups=[...markup.matchAll(/<tbody class="route-group" data-route-group="([^"]+)">([\s\S]*?)<\/tbody>/g)];
  assert.equal(groups.length,6);const planning=groups.find(group=>group[1]==='planning')[2];assert(planning.includes('data-route-id="planning"'));assert(planning.includes('data-route-id="quickIdeas"'));
  await api.handleAction('editRow',{task:'quickIdeas'});markup=api.matrix();assert.match(markup,/<tbody class="route-group" data-route-group="planning">[\s\S]*?class="row-editor"[\s\S]*?<\/tbody>/);
  api.state.expanded.planning=false;const route=api.state.draft.profiles[0].routes.find(route=>route.category==='quickIdeas');route.inheritsEffort=false;route.effort={mode:'fixed',value:'medium'};
  markup=api.matrix();const collapsed=markup.match(/<tbody class="route-group" data-route-group="planning">([\s\S]*?)<\/tbody>/)[1];assert(!collapsed.includes('override-row'));assert(!collapsed.includes('data-route-id="quickIdeas"'));assert(!collapsed.includes('row-editor'));
  assert.match(html,/tbody\.route-group:not\(:last-of-type\)>tr:last-child>th/);assert.match(html,/tbody>tr>th,\.matrix tbody>tr>td\{border-bottom:0\}/);assert.match(html,/child-row>th\{padding-left:45px\}/);
});
test('legend reuses separated effort bars and refresh has two clean circular arrowheads',()=>{
  const {api}=ready(),legend=api.matrixLegend();assert(!/[▂▄▅▆█]/.test(legend));assert.equal((legend.match(/class="effort-meter"/g)||[]).length,2);assert.match(legend,/data-effort="low"/);assert.match(legend,/data-effort="max"/);
  const refresh=api.sidebar().match(/<button[^>]*data-action="connections"[\s\S]*?<\/button>/)[0];assert.match(refresh,/data-label="Refresh connections"/);assert.match(refresh,/viewBox="0 0 24 24"/);assert.equal((refresh.match(/<path /g)||[]).length,4);assert.match(refresh,/M21 3v5h-5/);assert.match(refresh,/M8 16H3v5/);assert.match(html,/\[data-action="connections"\] \.icon\{width:16px;height:16px\}/);
});


test('reopened Computer use retains Medium effort in both complete profile assignments',async()=>{
  const {api}=ready();withChildren(api);api.state.expanded.mechanical=false;
  for(const profile of api.state.draft.profiles){
    const parent=profile.routes.find(r=>r.category==='mechanical'),child=profile.routes.find(r=>r.category==='computerUse');
    parent.modelID='gpt-6-luna';parent.effort={mode:'fixed',value:'medium'};
    child.inheritsModel=false;child.modelID='gpt-6-astra';
  }
  assert(!api.matrix().includes('data-route-id="computerUse"'));await api.handleAction('disclose',{task:'mechanical'});
  const markup=api.matrix(),row=markup.match(/<tr class="child-row" data-route-id="computerUse">([\s\S]*?)<\/tr>/)[1];
  assert.equal((row.match(/Astra 6/g)||[]).length,2);assert.equal((row.match(/data-effort="medium"/g)||[]).length,2);
  assert.match(row,/via Codex/);assert.doesNotMatch(row,/Pinned|2 agents/);
});
test('visible Release security exceptions show ordered lead and extra with Max effort in both profiles',()=>{
  const {api}=ready();withChildren(api);api.state.expanded.review=true;
  for(const profile of api.state.draft.profiles){
    const parent=profile.routes.find(r=>r.category==='review'),child=profile.routes.find(r=>r.category==='securityReview');
    parent.modelID='gpt-6-astra';parent.effort={mode:'fixed',value:'max'};
    child.inheritsTeam=false;child.additionalAgents=[{id:'extra',modelID:'claude-fable-5-2',effort:{mode:'fixed',value:'max'}}];
  }
  for(const platform of ['codex','claude']){
    const cell=api.assignment(platform,'securityReview');
    assert(cell.indexOf('Astra 6')<cell.indexOf('Fable 5.2'));assert.equal((cell.match(/data-effort="max"/g)||[]).length,2);
    assert.equal((cell.match(/class="model-provider"/g)||[]).length,2);assert.doesNotMatch(cell,/Pinned|2 agents/);
    assert.match(cell,platform==='codex'?/via Claude Code/:/via Codex/);
  }
  api.state.draft.profiles[1].routes.find(r=>r.category==='securityReview').inheritsTeam=true;
  assert.match(api.assignment('claude','securityReview'),/Astra 6/);assert.match(api.assignment('claude','securityReview'),/data-effort="max"/);
});
test('provider sublines keep native and crossover assignment members on the same grid row',()=>{
  const {api}=ready();api.state.draft.profiles[0].routes.find(r=>r.category==='planning').modelID='claude-fable-5-2';
  for(const platform of ['codex','claude'])assert.equal((api.assignment(platform,'planning').match(/class="model-provider"/g)||[]).length,1);
  assert.match(html,/model-with-provider\{display:contents\}/);assert.match(html,/model-with-provider>\.model-name\{grid-column:1;grid-row:1/);
  assert.match(html,/model-line>\.effort-meter\{grid-column:2;grid-row:1\}/);assert.match(html,/model-provider\{grid-column:1 \/ -1;grid-row:2;min-height:15px/);
});


function inlineElement(task,field,value,{platform='codex',index=0}={}){return {dataset:{platform,task,field,index:String(index),inline:'true'},value};}
function savedReply(request){const state=data();state.configuration=clone(request.configuration);state.enabledPlatforms=[...request.platforms];state.hasSavedDraft=true;return {ok:true,state};}
test('model names and effort bars open one directly anchored field selector without global Edit',async()=>{
  const {api,nodes}=ready();api.render();let markup=nodes.get('root').innerHTML;
  assert.match(markup,/aria-label="Change Codex Planning &amp; algorithms Model"/);assert.match(markup,/aria-label="Change Codex Planning &amp; algorithms Effort"/);
  assert.doesNotMatch(markup,/data-action="edit"|data-action="saveEdit"|data-action="cancelEdit"/);
  await api.handleAction('openField',{platform:'codex',task:'planning',index:'0',field:'model'});
  assert.equal(api.state.advanced,false);assert.equal(api.state.modal,null);assert.match(api.assignment('codex','planning'),/<span class="field-picker"[^>]*>[\s\S]*?<select data-inline="true"/);
  await api.handleAction('openField',{platform:'claude',task:'review',index:'0',field:'effort'});
  assert.equal((api.matrix().match(/class="field-picker"/g)||[]).length,1);assert.match(api.assignment('claude','review'),/<option value="range">Range…/);
  api.closeField();assert.doesNotMatch(api.matrix(),/class="field-picker"/);
  await api.handleAction('moreSettings',{task:'review'});assert.equal(api.state.advanced,false);assert.match(api.matrix(),/class="row-more"/);assert.doesNotMatch(api.moreSettings('codex','review'),/data-field="model"|data-field="effort"/);
});
test('direct model and effort choices autosave only the draft and retain independent inheritance',async()=>{
  const {api}=ready(),calls=[];withChildren(api);api.setBridge({action:async request=>{calls.push(plain(request));return savedReply(request);}});
  const child=api.state.draft.profiles[0].routes.find(r=>r.category==='computerUse');
  await api.editInlineField(inlineElement('computerUse','model','gpt-6-astra'));
  assert.equal(child.modelID,'gpt-6-astra');assert.equal(child.inheritsModel,false);assert.equal(child.inheritsEffort,true);assert.equal(child.inheritsTeam,true);
  await api.editInlineField(inlineElement('computerUse','effort','medium'));
  assert.equal(child.effort.value,'medium');assert.equal(child.inheritsEffort,false);assert.equal(api.state.dirty,false);assert.equal(api.state.busy,false);
  await api.editInlineField(inlineElement('computerUse','model','parent'));assert.equal(child.inheritsModel,true);assert.equal(child.inheritsEffort,false);
  assert.deepEqual(calls.map(r=>r.action),['saveDraft','saveDraft','saveDraft']);assert.equal(api.state.preview,null);
});
test('extra team members and Controller Auto use direct choices with native-only controller constraints',async()=>{
  const {api}=ready(),calls=[];withChildren(api);api.setBridge({action:async request=>{calls.push(plain(request));return savedReply(request);}});
  const parent=api.state.draft.profiles[0].routes.find(r=>r.category==='review'),child=api.state.draft.profiles[0].routes.find(r=>r.category==='securityReview');
  parent.additionalAgents=[{id:'second',modelID:'claude-fable-5-2',effort:{mode:'fixed',value:'max'}}];
  assert.match(api.assignment('codex','securityReview'),/data-index="1" data-field="model"/);
  await api.editInlineField(inlineElement('securityReview','effort','medium',{index:1}));
  assert.equal(child.inheritsTeam,false);assert.equal(child.inheritsModel,true);assert.equal(child.inheritsEffort,true);assert.equal(parent.additionalAgents[0].effort.value,'max');assert.equal(child.additionalAgents[0].effort.value,'medium');
  await api.editInlineField(inlineElement('coordinator','model','claude-fable-5-2'));assert.equal(calls.length,1);assert.equal(api.getEffective('codex','coordinator').modelID,'auto');
  await api.editInlineField(inlineElement('coordinator','model','gpt-6-astra'));assert.match(api.assignment('codex','coordinator'),/Change Codex Controller Effort/);
  await api.editInlineField(inlineElement('coordinator','model','auto'));assert.doesNotMatch(api.assignment('codex','coordinator'),/Change Codex Controller Effort/);
});
test('rapid direct edits serialize and coalesce saves without accepting stale response drafts',async()=>{
  const {api}=ready(),requests=[],finish=[];api.setBridge({action:request=>{requests.push(plain(request));return new Promise(resolve=>finish.push(resolve));}});
  const first=api.editInlineField(inlineElement('planning','model','gpt-6-astra'));await Promise.resolve();assert.equal(requests.length,1);
  api.editInlineField(inlineElement('planning','model','gpt-6-luna'));api.editInlineField(inlineElement('planning','model','gpt-6.1-terra'));
  assert.equal(api.getEffective('codex','planning').modelID,'gpt-6.1-terra');assert.equal(api.state.busy,false);assert.equal(requests.length,1);
  finish[0](savedReply(requests[0]));await new Promise(setImmediate);
  assert.equal(api.getEffective('codex','planning').modelID,'gpt-6.1-terra');assert.equal(requests.length,2);assert.equal(requests[1].configuration.profiles[0].routes[1].modelID,'gpt-6.1-terra');
  finish[1](savedReply(requests[1]));await first;assert.equal(api.state.dirty,false);assert.equal(api.state.savingDraft,false);assert.equal(api.state.draftSavePromise,null);
});
test('failed automatic save keeps the chosen draft and history, and Retry persists that draft',async()=>{
  const {api,nodes}=ready(),requests=[];let fail=true;api.setBridge({action:async request=>{requests.push(plain(request));if(fail)throw Error('Disk is full');return savedReply(request);}});
  await api.editInlineField(inlineElement('planning','model','gpt-6-astra'));
  assert.equal(api.getEffective('codex','planning').modelID,'gpt-6-astra');assert.equal(api.state.undoStack.length,1);assert.equal(api.state.dirty,true);assert.match(api.state.draftSaveError,/Disk is full/);assert.match(nodes.get('root').innerHTML,/data-action="retryDraftSave"/);
  fail=false;await api.handleAction('retryDraftSave');assert.equal(api.state.dirty,false);assert.equal(api.state.draftSaveError,'');assert.deepEqual(requests.map(r=>r.action),['saveDraft','saveDraft']);
});
test('Undo and Redo of direct choices autosave in order, including while a save is pending',async()=>{
  const {api}=ready(),requests=[],finish=[];api.setBridge({action:request=>{requests.push(plain(request));return new Promise(resolve=>finish.push(resolve));}});
  const save=api.editInlineField(inlineElement('planning','model','gpt-6-astra'));await Promise.resolve();
  const undo=api.travelDraft();assert.equal(api.getEffective('codex','planning').modelID,'gpt-6.1-sol');assert.equal(api.state.redoStack.length,1);
  finish[0](savedReply(requests[0]));await new Promise(setImmediate);assert.equal(requests.length,2);assert.equal(requests[1].configuration.profiles[0].routes[1].modelID,'gpt-6.1-sol');
  finish[1](savedReply(requests[1]));await save;await undo;
  const redo=api.travelDraft(true);await Promise.resolve();assert.equal(api.getEffective('codex','planning').modelID,'gpt-6-astra');finish[2](savedReply(requests[2]));await redo;assert.equal(api.state.dirty,false);
});
test('range picker stays open for supported bounds and closing never rolls back chosen edits',async()=>{
  const {api}=ready();api.setBridge({action:async request=>savedReply(request)});
  const route=api.state.draft.profiles[0].routes.find(r=>r.category==='planning');route.effort={mode:'fixed',value:'max'};
  api.openField({platform:'codex',task:'planning',index:'0',field:'effort'});await api.editInlineField(inlineElement('planning','effort','range'));
  assert.equal(api.state.fieldPicker.field,'effort');assert.equal(route.effort.minimum,'low');assert.equal(route.effort.maximum,'max');assert.match(api.assignment('codex','planning'),/Minimum effort/);
  await api.editInlineField(inlineElement('planning','minimum','medium'));api.closeField();assert.equal(route.effort.minimum,'medium');assert.equal(api.state.dirty,false);
});
test('direct edits invalidate old reviews; preview waits for saving and only explicit Apply commits its reviewed ID',async()=>{
  const {api}=ready(),requests=[];let finishSave;api.state.preview=preview();api.setBridge({action:request=>{requests.push(plain(request));if(request.action==='saveDraft')return new Promise(resolve=>{finishSave=()=>resolve(savedReply(request));});if(request.action==='preview')return Promise.resolve({ok:true,preview:preview()});if(request.action==='apply')return Promise.resolve({ok:true,state:data()});throw Error('Unexpected action');}});
  const save=api.editInlineField(inlineElement('planning','model','gpt-6-astra'));await Promise.resolve();assert.equal(api.state.preview,null);
  const review=api.prepare();await Promise.resolve();assert.deepEqual(requests.map(r=>r.action),['saveDraft']);finishSave();await save;await review;
  assert.deepEqual(requests.map(r=>r.action),['saveDraft','preview']);assert.equal(requests[1].configuration.profiles[0].routes[1].modelID,'gpt-6-astra');
  await api.applyReview();assert.deepEqual(requests[2],{action:'apply',previewID:'review-exact-id'});
});


test('Review after a failed autosave validates the current choice and Apply still requires explicit review',async()=>{
  const {api}=ready(),requests=[];api.setBridge({action:async request=>{requests.push(plain(request));if(request.action==='saveDraft')throw Error('Draft storage unavailable');if(request.action==='preview')return {ok:true,preview:preview()};if(request.action==='apply')return {ok:true,state:data()};throw Error('Unexpected action');}});
  await api.editInlineField(inlineElement('planning','model','gpt-6-astra'));await api.prepare();
  assert.deepEqual(requests.map(r=>r.action),['saveDraft','preview']);assert.equal(requests[1].configuration.profiles[0].routes[1].modelID,'gpt-6-astra');assert.equal(api.getEffective('codex','planning').modelID,'gpt-6-astra');
  await api.applyReview();assert.deepEqual(requests[2],{action:'apply',previewID:'review-exact-id'});assert.equal(api.state.draftSaveError,'');
});


test('tool changes continue autosaving after a direct choice and expose Retry on save failure',async()=>{
  const {api,nodes}=ready(),requests=[];let fail=false,saved=data();api.setBridge({action:async request=>{requests.push(plain(request));if(request.action==='state'){const response=clone(saved);response.enabledPlatforms=[...request.platforms];return {ok:true,state:response};}if(fail)throw Error('Cannot save selected tools');saved=savedReply(request).state;return {ok:true,state:clone(saved)};}});
  await api.editInlineField(inlineElement('planning','model','gpt-6-astra'));await api.handleAction('togglePlatform',{platform:'claude'});await api.state.draftSavePromise;
  assert.deepEqual(requests.map(r=>r.action),['saveDraft','state','saveDraft']);assert.deepEqual(saved.enabledPlatforms,['codex']);assert.equal(api.state.dirty,false);
  fail=true;await api.handleAction('togglePlatform',{platform:'claude'});await api.state.draftSavePromise;
  assert.deepEqual(plain(api.state.platforms),['codex','claude']);assert.deepEqual(saved.enabledPlatforms,['codex']);assert.equal(api.state.dirty,true);assert.match(nodes.get('root').innerHTML,/data-action="retryDraftSave"/);
  fail=false;await api.handleAction('retryDraftSave');assert.deepEqual(saved.enabledPlatforms,['codex','claude']);assert.equal(api.state.dirty,false);
});
test('custom model additions and removals autosave, retain failures, and preserve legacy Edit staging',async()=>{
  const {api}=ready(),requests=[];let fail=false;api.setBridge({action:async request=>{requests.push(plain(request));if(fail)throw Error('Draft cannot be saved');return savedReply(request);}});
  await api.editInlineField(inlineElement('planning','model','gpt-6-astra'));
  const form={id:'custom-model-form',values:{id:'custom-test',label:'Custom test',platform:'codex',efforts:'low, medium, high'},reset(){}};
  await api.submitForm(form);await api.state.draftSavePromise;assert.equal(requests.at(-1).configuration.customModels[0].id,'custom-test');assert.equal(api.state.dirty,false);
  fail=true;await api.handleAction('removeCustom',{id:'custom-test'});await api.state.draftSavePromise;assert.equal(api.state.draft.customModels.length,0);assert.equal(api.state.dirty,true);assert.match(api.state.draftSaveError,/cannot be saved/);
  fail=false;await api.handleAction('retryDraftSave');assert.equal(requests.at(-1).configuration.customModels.length,0);assert.equal(api.state.dirty,false);
  const count=requests.length;api.beginEdit();await api.submitForm(form);await Promise.resolve();assert.equal(requests.length,count);assert.equal(api.state.draft.customModels.length,1);api.cancelEdit();assert.equal(api.state.draft.customModels.length,0);
});
test('completed autosaves refresh Previous draft metadata while newer local and queued choices remain intact',async()=>{
  const {api}=ready(),requests=[],finish=[],initial=plain(api.state.draft);api.setBridge({action:request=>{requests.push(plain(request));return new Promise(resolve=>finish.push(resolve));}});
  const save=api.editInlineField(inlineElement('planning','model','gpt-6-astra'));await Promise.resolve();
  api.editInlineField(inlineElement('planning','model','gpt-6-luna'));
  const first=savedReply(requests[0]);first.state.previousDraft=initial;first.state.savedPresets=[{id:'new-saved',name:'Stored preset',configuration:initial}];finish[0](first);await new Promise(setImmediate);
  assert.equal(api.getEffective('codex','planning').modelID,'gpt-6-luna');assert.equal(api.state.data.previousDraft.profiles[0].routes[1].modelID,'gpt-6.1-sol');assert.equal(api.state.data.savedPresets[0].id,'new-saved');assert.equal(requests.length,2);
  const second=savedReply(requests[1]);second.state.previousDraft=clone(requests[0].configuration);finish[1](second);await save;
  assert.equal(api.state.data.previousDraft.profiles[0].routes[1].modelID,'gpt-6-astra');assert.equal(api.getEffective('codex','planning').modelID,'gpt-6-luna');
  await api.handleAction('savedPreset',{id:'previous'});await Promise.resolve();assert.equal(api.getEffective('codex','planning').modelID,'gpt-6-astra');assert.equal(requests[2].configuration.profiles[0].routes[1].modelID,'gpt-6-astra');
  const last=savedReply(requests[2]);last.state.previousDraft=clone(requests[1].configuration);finish[2](last);await api.state.draftSavePromise;assert.equal(api.state.data.previousDraft.profiles[0].routes[1].modelID,'gpt-6-luna');
});


test('legacy Edit remains staged after an earlier automatic save, including Undo, Redo, and preset selection',async()=>{
  const {api}=ready(),requests=[];api.setBridge({action:async request=>{requests.push(plain(request));return savedReply(request);}});
  await api.editInlineField(inlineElement('planning','model','gpt-6-astra'));const baseline=plain(api.state.draft);api.beginEdit();
  api.editField(inlineElement('planning','model','gpt-6-luna'));await api.travelDraft();await api.travelDraft(true);api.selectConfiguration(api.state.data.presets[0].configuration,'fast');await Promise.resolve();
  assert.equal(requests.length,1);api.cancelEdit();assert.deepEqual(plain(api.state.draft),baseline);
});


test('manual collapse hides every configured child and reopening restores choices without saving',async()=>{
  const {api}=ready(),calls=[];withChildren(api);api.setBridge({action:async request=>{calls.push(plain(request));throw Error('Disclosure must not save');}});
  for(const profile of api.state.draft.profiles)for(const route of profile.routes.filter(route=>api.PARENTS[route.category])){
    route.inheritsModel=false;route.modelID='gpt-6-astra';route.inheritsEffort=false;route.effort={mode:'fixed',value:'medium'};route.inheritsTeam=false;
    route.additionalAgents=[{id:'child-worker',modelID:'claude-fable-5-2',effort:{mode:'fixed',value:'max'}}];
    if(route.category==='debugging')route.stuckEscalation=[{id:'next',modelID:'claude-opus-5-5',effort:{mode:'fixed',value:'max'}}];
  }
  const draft=plain(api.state.draft),generation=api.state.generation,history=plain(api.state.undoStack),dirty=api.state.dirty;
  for(const [task,,children] of api.GROUPS){
    assert.equal(api.isExpanded(task),true);await api.handleAction('disclose',{task});assert.equal(api.isExpanded(task),false);
    const markup=api.matrix(),group=markup.match(new RegExp('<tbody class="route-group" data-route-group="'+task+'">([\\s\\S]*?)<\\/tbody>'))[1];
    assert.match(group,/class="disclosure"[^>]*aria-expanded="false"/);assert(!group.includes('child-row'));assert(!group.includes('When stuck'));assert(!group.includes('collapsed-summary'));
    for(const child of children)assert(!group.includes('data-route-id="'+child+'"'));
    await api.handleAction('disclose',{task});for(const child of children)assert(api.matrix().includes('data-route-id="'+child+'"'));
  }
  assert.deepEqual(plain(api.state.draft),draft);assert.deepEqual(plain(api.state.undoStack),history);assert.equal(api.state.generation,generation);assert.equal(api.state.dirty,dirty);assert.deepEqual(calls,[]);
});
test('closing a child picker preserves its in-flight autosave and hides child More settings and editors',async()=>{
  const {api}=ready(),requests=[];withChildren(api);let finish;
  api.setBridge({action:request=>{requests.push(plain(request));return new Promise(resolve=>{finish=()=>resolve(savedReply(request));});}});
  await api.handleAction('disclose',{task:'ui'});api.openField({platform:'codex',task:'uiBuild',index:'0',field:'effort'});
  const saving=api.editInlineField(inlineElement('uiBuild','effort','range'));await Promise.resolve();
  assert.equal(api.state.fieldPicker.task,'uiBuild');const chosen=plain(api.state.draft),savePromise=api.state.draftSavePromise;
  await api.handleAction('disclose',{task:'ui'});assert.equal(api.state.fieldPicker,null);assert.equal(api.state.draftSavePromise,savePromise);assert.equal(requests.length,1);assert.deepEqual(plain(api.state.draft),chosen);assert(!api.matrix().includes('data-route-id="uiBuild"'));
  finish();await saving;assert.equal(api.state.dirty,false);assert(!api.matrix().includes('data-route-id="uiBuild"'));
  await api.handleAction('disclose',{task:'ui'});assert.match(api.assignment('codex','uiBuild'),/data-mode="range"/);assert.equal(api.state.fieldPicker,null);
  await api.handleAction('moreSettings',{task:'uiBuild'});assert(api.matrix().includes('row-more'));await api.handleAction('disclose',{task:'ui'});assert.equal(api.state.moreTask,null);assert(!api.matrix().includes('row-more'));
  await api.handleAction('disclose',{task:'ui'});await api.handleAction('editRow',{task:'uiBuild'});api.editField(inlineElement('uiBuild','model','gpt-6-astra'));
  const edited=plain(api.state.draft);await api.handleAction('disclose',{task:'ui'});assert.equal(api.state.editingTask,null);assert.equal(api.state.advanced,true);assert.deepEqual(plain(api.state.draft),edited);assert.equal(requests.length,1);
  await api.handleAction('disclose',{task:'ui'});assert.match(api.assignment('codex','uiBuild'),/Astra 6/);assert(!api.matrix().includes('row-editor'));
});

function autoConnectionHost(incoming,connection){
 const calls=[],listeners={},win={location:{hash:'',hostname:''},addEventListener:(name,fn)=>{listeners[name]=fn;},removeEventListener(){}};
 win.parent={postMessage:message=>{if(message.method==='ui/initialize')queueMicrotask(()=>listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{hostContext:{}}}}));else if(message.method==='tools/call'){const request=plain(message.params.arguments);calls.push(request);const result=request.action==='state'?{ok:true,state:incoming}:{ok:true,claudeConnection:connection};queueMicrotask(()=>listeners.message({source:win.parent,data:{jsonrpc:'2.0',id:message.id,result:{structuredContent:result}}}));}}};
 return {...load(win),calls};
}
test('opening a configured MCP panel checks Claude and presents failures without starting login',async()=>{
 for(const state of ['signInRequired','connected','unavailable','missing']){
  const incoming=data();incoming.canConnectClaude=true;incoming.configuration.profiles[0].routes[1].modelID='claude-opus-5-5';
  const {api,nodes,calls}=autoConnectionHost(incoming,{state,detail:'Fixture status'});await api.initialize();
  assert.deepEqual(calls.map(x=>x.action),['state','checkClaudeConnection']);
  if(state==='connected')assert.equal(api.state.modal,null);else assert.equal(api.state.modal.kind,'claudeConnection');
  if(state==='signInRequired')assert.match(nodes.get('modal-root').innerHTML,/Continue with Claude/);
  if(state==='unavailable'){assert.match(nodes.get('modal-root').innerHTML,/>Recheck<\/button>/);assert(!nodes.get('modal-root').innerHTML.includes('Continue with Claude'));}
  if(state==='missing')assert.match(nodes.get('modal-root').innerHTML,/Claude Code setup instructions/);
 }
});
test('opening native-only or reversed routes does not check an independent Claude login',async()=>{
 const incoming=data();incoming.canConnectClaude=true;incoming.configuration.profiles[1].routes[1].modelID='gpt-6-astra';
 const {api,calls}=autoConnectionHost(incoming,{state:'signInRequired'});await api.initialize();
 assert.deepEqual(calls.map(x=>x.action),['state']);assert.equal(api.state.modal,null);
});
test('opening preserves a required missing provider and uses applied routes masked by a proposal',async()=>{
 for(const masked of [false,true]){
  const incoming=data();incoming.canConnectClaude=true;const required=clone(incoming.configuration);required.profiles[0].routes[1].modelID='claude-opus-5-5';
  incoming.installation={state:'applied',installedPlatforms:['codex','claude'],appliedConfiguration:required};
  incoming.configuration=masked?clone(incoming.configuration):clone(required);incoming.configuration.enabledPlatforms=['codex'];incoming.enabledPlatforms=['codex'];incoming.availablePlatforms=['codex'];incoming.preferredPlatforms=['codex','claude'];
  const {api,calls}=autoConnectionHost(incoming,{state:'missing',detail:'Install Claude Code.'});await api.initialize();
  assert.deepEqual(calls.map(x=>x.action),['state','checkClaudeConnection']);assert.equal(api.state.claudeConnection.state,'missing');
 }
});
test('re-enabling either provider rechecks after prior connection and after Not now',async()=>{
 for(const platform of ['claude','codex'])for(const initial of ['connected','signInRequired']){
  const {api}=connectionReady();api.state.draft.profiles[0].routes[1].modelID='claude-opus-5-5';for(const preset of api.state.data.presets)preset.configuration.profiles[0].routes[1].modelID='claude-opus-5-5';let status=initial;const calls=[];
  api.setBridge({action:async request=>{calls.push(request.action);if(request.action==='state'){const next=data();next.canConnectClaude=true;next.configuration=plain(api.state.draft);next.enabledPlatforms=[...request.platforms];next.preferredPlatforms=[...request.platforms];for(const preset of next.presets)preset.configuration.profiles[0].routes[1].modelID=request.platforms.includes('claude')?'claude-opus-5-5':'gpt-6.1-sol';return {ok:true,state:next};}return {ok:true,claudeConnection:{state:status,detail:'Fixture'}};}});
  await api.offerClaudeConnection();if(initial==='signInRequired')await api.handleAction('closeModal');
  status='signInRequired';await api.handleAction('togglePlatform',{platform});assert.equal(api.state.modal,null);
  await api.handleAction('togglePlatform',{platform});assert.equal(api.state.modal?.kind,'claudeConnection',platform+' after '+initial);
  assert.equal(calls.filter(x=>x==='checkClaudeConnection').length,2);assert(!calls.includes('connectClaude'));
 }
});
test('disabling Claude cancels a quiet check and discards its late failure',async()=>{
 const {api}=connectionReady();api.state.draft.profiles[0].routes[1].modelID='claude-opus-5-5';let finish,signal;
 api.setBridge({action:(request,options)=>{if(request.action==='checkClaudeConnection'){signal=options.signal;return new Promise(resolve=>{finish=resolve;});}const next=data();next.canConnectClaude=true;next.configuration=plain(api.state.draft);next.enabledPlatforms=request.platforms;next.preferredPlatforms=request.platforms;return Promise.resolve({ok:true,state:next});}});
 const check=api.offerClaudeConnection();await api.handleAction('togglePlatform',{platform:'claude'});assert.equal(signal.aborted,true);
 finish({ok:true,claudeConnection:{state:'signInRequired',detail:'Late'}});await check;
 assert.equal(api.state.modal,null);assert.equal(api.state.claudePendingPrompt,null);
});
test('connection failures defer across settings work instead of disappearing',async()=>{
 for(const blocker of ['busy','modal']){
  const {api}=connectionReady();api.state.draft.profiles[0].routes[1].modelID='claude-opus-5-5';let finish;
  api.setBridge({action:()=>new Promise(resolve=>{finish=resolve;})});const check=api.offerClaudeConnection();
  if(blocker==='busy')api.state.busy=true;else api.state.modal={kind:'sources'};
  finish({ok:true,claudeConnection:{state:'signInRequired',detail:'Needs login'}});await check;
  assert(api.state.claudePendingPrompt);assert.notEqual(api.state.modal?.kind,'claudeConnection');
  if(blocker==='busy'){api.state.busy=false;api.render();}else await api.handleAction('closeModal');
  assert.equal(api.state.modal.kind,'claudeConnection');
 }
});
test('failed automatic RPC surfaces Recheck without issuing a login request',async()=>{
 const {api,nodes}=connectionReady(),calls=[];api.state.draft.profiles[0].routes[1].modelID='claude-opus-5-5';
 api.setBridge({action:async request=>{calls.push(request.action);throw Error('Connection unavailable');}});
 await api.offerClaudeConnection();assert.equal(api.state.claudeConnection.state,'unavailable');
 assert.match(nodes.get('modal-root').innerHTML,/>Recheck<\/button>/);await api.handleAction('connectClaude');assert.deepEqual(calls,['checkClaudeConnection']);
});

test('a new Claude choice cancels a pending old check and ignores its connected result',async()=>{
 const {api}=connectionReady(),checks=[];
 api.setBridge({action:(request,options)=>{assert.equal(request.action,'checkClaudeConnection');return new Promise(resolve=>checks.push({resolve,signal:options.signal}));}});
 const field={platform:'codex',task:'planning',field:'model',index:'0'};
 api.editField({dataset:field,value:'claude-opus-5-5'});const first=api.state.claudeQuietPromise;
 api.editField({dataset:field,value:'claude-fable-5-2'});const second=api.state.claudeQuietPromise;
 assert.equal(checks.length,2);assert.equal(checks[0].signal.aborted,true);assert.notEqual(first,second);
 checks[0].resolve({ok:true,claudeConnection:{state:'connected',detail:'Stale'}});await first;
 assert.equal(api.state.claudeConnectionConfirmed,false);assert.equal(api.state.claudeQuietPromise,second);
 checks[1].resolve({ok:true,claudeConnection:{state:'signInRequired',detail:'Fresh'}});await second;
 assert.equal(api.state.modal.kind,'claudeConnection');assert.equal(api.state.claudeConnection.detail,'Fresh');
});

test('opening requirement survives entering Edit without changing the saved routes',async()=>{
 const {api}=connectionReady();const required=plain(api.state.draft);required.profiles[0].routes[1].modelID='claude-opus-5-5';
 api.state.data.installation={state:'applied',installedPlatforms:['codex','claude'],appliedConfiguration:required};
 let finish;api.setBridge({action:()=>new Promise(resolve=>{finish=resolve;})});
 const check=api.offerClaudeConnection(false,true);api.beginEdit();
 finish({ok:true,claudeConnection:{state:'missing',detail:'Install Claude Code.'}});await check;
 assert.equal(api.state.modal?.kind,'claudeConnection');assert.equal(api.state.claudeConnection.state,'missing');
 assert.equal(api.state.advanced,true);
});
