(() => {
'use strict';
const DATA = JSON.parse(document.getElementById('architecture-data').textContent);
const NODES = Object.fromEntries(DATA.nodes.map(n => [n.id, n]));
const MAIN_STEP_INDICES = [0, 1, 2, 3, 4, 5, 7, 8];
const STEPS = MAIN_STEP_INDICES.map(i => DATA.steps[i]);
const STEP_SHORT = ['点击发送','检查与反馈','会话与历史','运行准入','准备请求','流式显示','判定与保存','完成收尾'];
const STAGES = ['接收输入','接收输入','准备执行','准备执行','模型交互','模型交互','保存与收尾','保存与收尾'];
const ROOTS = ['ui','agent','providers','config','storage','tools','sync','ish','native','os'];
const CAPS=DATA.capabilities;
const CAP_BY_ID=Object.fromEntries(CAPS.items.map(c=>[c.id,c]));
let capQuery='';
const DIAG_IDS = ['send','stream','history'];
const DIAG_SHORT = ['点击发送没有反应','回复生成到一半停止','历史记录出现异常'];
const BRANCH_TITLES = {tools:'工具调用分支', failure:'请求失败与恢复', stop:'用户停止生成'};
const DETAIL_SCOPES = {agent:'agent', mcp:'mcp'};
// Reading hierarchy describes responsibilities. Source paths describe code ownership.
// Collaborators keep their own parent even when they appear inside another module's diagram.
const PARENT = Object.fromEntries(DATA.nodes.map(n => [n.id, ['ios','external'].includes(n.parent) ? null : n.parent]));
PARENT.mcp = 'config';
PARENT.mcpui = 'ui';
PARENT.cli = 'ish';
const OWN_NODES = {agent: new Set(['send','session','context','loop','stream']), mcp:new Set(['mcp','mcpdisk','override','mcpsnippet','refresh','mcpsync'])};
const SCOPES = JSON.parse(JSON.stringify(DATA.scopes));
SCOPES.overview.bounds = [
 {x:16,y:38,w:764,h:660,label:'设备本地 · iOS 应用及内嵌执行环境'},
 {x:800,y:38,w:228,h:425,label:'设备之外 · 模型与同步服务'},
 {x:800,y:491,w:228,h:207,label:'设备本地 · iOS 系统框架'}
];
SCOPES.agent.bounds[0].label = 'Agent 内部职责 · 阅读分组';
SCOPES.agent.bounds[1].label = '协作方 · 界面 / 存储';
SCOPES.agent.bounds[2].label = '协作方 · 模型 / 工具';
SCOPES.mcp.bounds[0].label = 'MCPStore · 配置、方法与数据';
SCOPES.mcp.bounds[1].label = '调用方';
SCOPES.mcp.bounds[2].label = '协作模块';
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pad = i => String(i).padStart(2, '0');
const unique = a => [...new Set(a)];
function ancestry(id) {
 const result = []; const seen = new Set();
 while (id && NODES[id] && !seen.has(id)) {result.unshift(id); seen.add(id); id = PARENT[id];}
 return result;
}
function rootOf(id) {return ancestry(id)[0] || 'agent';}
function scopeOf(route) {return route.page === 'architecture' ? 'overview' : DETAIL_SCOPES[route.id] || null;}
function pathOf(route) {
 if (route.page === 'architecture') return '/architecture';
 if (route.page === 'capabilities') return '/capabilities';
 if (route.page === 'module') return '/module/' + route.id;
 if (route.page === 'flow') return '/flow/' + (route.branch || pad(route.step));
 if (route.page === 'diagnostics') return '/diagnostics/' + route.id;
 return '/sources';
}
function serialize(route) {
 const params = new URLSearchParams();
 if ((route.page === 'architecture' || route.page === 'module') && route.selected) params.set('node',route.selected);
 if (route.page === 'flow' && route.branch) params.set('at',pad(route.at || 6));
 if (['module','capabilities'].includes(route.page) && route.from) params.set('from',route.from);
 if(route.page==='capabilities') {
  if(route.tab==='limits')params.set('tab','limits');
  if(route.group&&route.group!=='all')params.set('group',route.group);
  if(route.focus)params.set('item',route.focus);
 }
 return '#' + pathOf(route) + (params.size ? '?' + params.toString() : '');
}
function validReturn(value) {
 if(typeof value !== 'string')return '';
 if(/^\/capabilities(?:\?(?:tab=limits|group=(?:personal|system|media|app)|item=[a-z]+)(?:&(?:tab=limits|group=(?:personal|system|media|app)|item=[a-z]+))*)?$/.test(value))return value;
 if(/^\/(flow\/(0[1-8]|tools|failure|stop)(\?at=0[1-8])?|diagnostics\/(send|stream|history))$/.test(value))return value;
 const m=value.match(/^\/module\/([a-z]+)(?:\?node=([a-z]+))?$/);
 return m && NODES[m[1]] && (!m[2] || NODES[m[2]]) ? value : '';
}
function parseRoute(hash) {
 let value = (hash || '').replace(/^#/, '') || ENTRY_ROUTE;
 // Previous edition links remain usable; unused view/scope/step fields are discarded.
 if (value.startsWith('view=')) {
  const old = new URLSearchParams(value);
  if (old.get('view') === 'flow') {
   const oldStep = Number(old.get('step') || 1);
   if (oldStep === 7) value = '/flow/tools?at=06';
   else value = '/flow/' + pad(Math.max(1,Math.min(8,oldStep > 7 ? oldStep - 1 : oldStep)));
  } else if (old.get('view') === 'diagnostics') value='/diagnostics/send';
  else if (old.get('view') === 'evidence') value='/sources';
  else {
   const scope = ['agent','mcp'].includes(old.get('scope')) ? old.get('scope') : 'overview';
   value = scope === 'overview' ? '/architecture' : '/module/' + scope;
   if (NODES[old.get('node')]) value += '?node=' + encodeURIComponent(old.get('node'));
  }
 }
 const atQuestion = value.indexOf('?');
 const path = (atQuestion >= 0 ? value.slice(0,atQuestion) : value).split('/').filter(Boolean);
 const params = new URLSearchParams(atQuestion >= 0 ? value.slice(atQuestion + 1) : '');
 let route;
 if (path[0] === 'module' && NODES[path[1]]) route={page:'module',id:path[1],from:validReturn(params.get('from'))};
 else if (path[0] === 'flow') {
  if (Object.hasOwn(BRANCH_TITLES,path[1])) route={page:'flow',branch:path[1],at:Math.max(1,Math.min(8,Math.floor(Number(params.get('at'))) || 6))};
  else route={page:'flow',step:Math.max(1,Math.min(8,Math.floor(Number(path[1])) || 1))};
 } else if (path[0] === 'diagnostics') route={page:'diagnostics',id:DIAG_IDS.includes(path[1]) ? path[1] : 'send'};
 else if (path[0] === 'capabilities') route={page:'capabilities',tab:params.get('tab')==='limits'?'limits':'integrated',group:CAPS.groups.some(g=>g.id===params.get('group'))?params.get('group'):'all',focus:CAP_BY_ID[params.get('item')]?params.get('item'):'',from:validReturn(params.get('from'))};
 else if (path[0] === 'sources') route={page:'sources'};
 else route={page:'architecture'};
 const scope=scopeOf(route);
 route.selected=scope && SCOPES[scope].nodes.some(n=>n[0]===params.get('node')) ? params.get('node') : null;
 return route;
}
let route = parseRoute(location.hash);
let lastRenderedHash = '';
let lastFlow = {page:'flow',step:1};
let queryByPage = Object.create(null);
let sourceQuery = '';
const scrollPositions = new Map();
const href = r => esc(serialize(r));
const flowRoute = step => ({page:'flow',step});
function contextOrigin() {
 if (route.page==='flow') return serialize(route).slice(1);
 if (route.page==='diagnostics') return pathOf(route);
 if (route.page==='capabilities') return serialize({...route,from:''}).slice(1);
 return route.from || '';
}
function moduleRoute(id, selected = null) {
 let from=contextOrigin();
 if(route.page==='module' && !from && id!==route.id && !ancestry(id).includes(route.id) && !ancestry(route.id).includes(id)) {
  from=serialize({...route,from:''}).slice(1);
 }
 if(from && parseRoute(from).page==='module' && parseRoute(from).id===id)from='';
 return {page:'module',id,selected,from};
}
function sourceURL(ref) {
 return `https://github.com/${DATA.meta.repo}/${ref.kind==='目录'?'tree':'blob'}/${DATA.meta.sha}/${ref.path.split('/').map(encodeURIComponent).join('/')}${ref.lines?'#L'+ref.lines[0]+'-L'+ref.lines[1]:''}`;
}
function refsHTML(refs) {
 return `<div class="refs">${refs.map(r=>`<a class="ref" href="${esc(sourceURL(r))}" target="_blank" rel="noopener"><strong>${esc(r.symbol)} ↗</strong><span class="path">${esc(r.path)}</span><span class="range">${esc(r.kind)} · ${r.lines?'L'+r.lines[0]+'–L'+r.lines[1]:'按关键符号定位'} · ${DATA.meta.sha.slice(0,8)}</span></a>`).join('')}</div>`;
}
function sourceDetails(refs, label='对应源码与核查范围') {
 return `<details class="card sources-panel"><summary>${esc(label)} <span class="micro">· ${refs.length} 处依据</span></summary><div class="sources-body">${refsHTML(refs)}</div></details>`;
}
function breadcrumb(items) {
 return `<nav class="breadcrumbs" aria-label="当前位置">${items.map(([text,r],i)=>(i?'<span class="sep" aria-hidden="true">/</span>':'')+(r?`<a href="${href(r)}" data-nav>${esc(text)}</a>`:`<span aria-current="page">${esc(text)}</span>`)).join('')}</nav>`;
}
function moduleBreadcrumb(id) {
 const ids=ancestry(id);
 return breadcrumb([['整体架构',{page:'architecture'}],...ids.map((n,i)=>[NODES[n].title,i===ids.length-1?null:moduleRoute(n)])]);
}
function head(kicker,title,subtitle) {
 return `<header class="page-head"><div class="eyebrow">${esc(kicker)}</div><h1>${esc(title)}</h1><p>${esc(subtitle)}</p></header>`;
}
function footer() {return `<footer class="footer"><span>${esc(DATA.meta.repo)} · 源码基线 <code>${DATA.meta.sha.slice(0,12)}</code> · 原核查 ${DATA.meta.date}</span><a href="#/sources" data-nav>分析范围与待验证事项 →</a></footer>`;}
function returnTitle(from) {
 const origin = parseRoute(from);
 if (origin.page==='flow') return origin.branch ? BRANCH_TITLES[origin.branch] : `消息流程 · 第 ${pad(origin.step)} 步「${STEP_SHORT[origin.step-1]}」`;
 if (origin.page==='diagnostics') return `问题定位 · ${DIAG_SHORT[DIAG_IDS.indexOf(origin.id)]}`;
 if (origin.page==='capabilities') return origin.tab==='limits'?'能力清单 · 缺口与边界':'原生能力清单';
 if (origin.page==='module') return NODES[origin.id].title+(DETAIL_SCOPES[origin.id]?'关系图':'详情');
 return '原阅读位置';
}
function returnStrip() {
 return route.from ? `<div class="back-context"><a href="${esc('#'+route.from)}" data-nav data-return>← 返回${esc(returnTitle(route.from))}</a><span>已保留原来的阅读位置</span></div>` : '';
}
function navigationHTML() {
 const architectureActive=['architecture','module'].includes(route.page);
 const activeRoot = route.page==='module' ? rootOf(route.id) : null;
 let tree='';
 if (architectureActive) {
  const item=(id,depth=0)=>`<a class="nav-sub ${route.id===id?'current':''} ${depth?'deep':''}" href="${href({page:'module',id})}" data-nav ${route.id===id?'aria-current="page"':''}><span class="branch-dot"></span>${esc(NODES[id].title)}</a>`;
  tree=`<div class="nav-subtree" aria-label="模块层级">${item('agent')}${activeRoot==='agent'?['send','session','context','loop','stream'].map(n=>item(n,1)).join(''):''}${item('config')}${activeRoot==='config'?item('mcp',1):''}${item('ish')}${item('native')}${item('os')}</div>`;
 }
 const navItem=(num,title,short,r,on)=>`<a class="nav-link ${on?'active':''}" href="${href(r)}" data-nav ${on?'aria-current="page"':''}><span class="nav-num">${num}</span><span class="nav-full">${title}</span><span class="nav-short">${short}</span></a>`;
 return `<div class="nav-label">阅读路径</div><nav class="main-nav" aria-label="主导航"><div class="reading-nav-wrap">${navItem('01','整体架构','整体架构',{page:'architecture'},architectureActive)}${tree}</div>${navItem('02','发送消息','消息流程',lastFlow,route.page==='flow')}${navItem('03','原生能力清单','能力清单',{page:'capabilities',tab:'integrated',group:'all'},route.page==='capabilities')}${navItem('04','问题定位','问题定位',{page:'diagnostics',id:'send'},route.page==='diagnostics')}<div class="reference-nav"><div class="nav-rule"></div><div class="nav-label">参考资料</div>${navItem('↗','版本与源码','源码依据',{page:'sources'},route.page==='sources')}</div></nav><div class="sidebar-foot"><strong>两条阅读路径</strong>架构：整体 → 模块 → 子模块。<br>流程：输入 → 处理 → 保存。<br><br>图中单击查看摘要，详情页保留上级位置。<br><br><code>${esc(DATA.meta.branch)}</code><br>固定提交 · 源码静态阅读</div>`;
}
function miniMap(id) {
 let selected=rootOf(id);
 if (!ROOTS.includes(selected)) selected={llm:'providers',cloud:'sync',os:'native'}[id] || 'agent';
 const positions=Object.fromEntries(ROOTS.map((n,i)=>[n,[n==='os'?190:8+(i%3)*91,10+Math.floor(i/3)*44]]));
 const names={ui:'界面',agent:'Agent',providers:'模型接入',config:'配置',storage:'消息存储',tools:'工具执行',sync:'同步',native:'原生桥接',ish:'iSH',os:'iOS 框架'};
 const pairs=[['ui','agent'],['agent','providers'],['agent','config'],['agent','storage'],['agent','tools'],['tools','ish'],['ish','native'],['native','os'],['config','sync']];
 return `<svg class="mini-map" viewBox="0 0 284 180" role="img" aria-label="${esc(NODES[id].title)}在整体中的位置：${esc(NODES[selected].title)}"><title>当前所属阅读分组：${esc(NODES[selected].title)}</title>${pairs.map(([a,b])=>{let A=positions[a],B=positions[b];return `<path d="M ${A[0]+37} ${A[1]+14} L ${B[0]+37} ${B[1]+14}" fill="none" stroke="#d3ddea" stroke-width="1.1"/>`}).join('')}${ROOTS.map(n=>{let [x,y]=positions[n],on=n===selected;return `<g><rect x="${x}" y="${y}" width="74" height="29" rx="5" fill="${on?'#315fd4':'#fff'}" stroke="${on?'#315fd4':'#d6e0ed'}"/><text x="${x+37}" y="${y+19}" text-anchor="middle" fill="${on?'#fff':'#7b8ea9'}">${names[n]}</text></g>`}).join('')}</svg>`;
}
function locationHTML(id) {
 return `<aside class="card location-card"><h2>在整体中的位置</h2><div class="reading-trail">整体架构${ancestry(id).map((n,i)=>`<span> → </span>${i===ancestry(id).length-1?`<strong>${esc(NODES[n].title)}</strong>`:esc(NODES[n].title)}`).join('')}</div>${miniMap(id)}<p class="explain">高亮表示所属阅读分组；具体代码目录见源码。</p></aside>`;
}

// Diagram geometry is retained from the first edition.
const manualOverview={
'ui-agent':{p:'M 255 135 L 300 135',l:[279,119]},'agent-providers':{p:'M 510 135 L 550 135',l:[530,119]},'providers-llm':{p:'M 760 135 L 810 135',l:[785,119]},
'agent-config':{p:'M 355 175 L 355 232 L 150 232 L 150 300',l:[228,220]},'agent-storage':{p:'M 405 175 L 405 300',l:[450,225]},'agent-tools':{p:'M 455 175 L 455 252 L 655 252 L 655 300',l:[572,239]},
'agent-ui':{p:'M 352 95 L 352 69 L 150 69 L 150 95',l:[250,59]},'tools-ish':{p:'M 655 380 L 655 525',l:[710,444]},'ish-native':{p:'M 600 605 L 600 650 L 455 650 L 455 605',l:[530,638]},'native-os':{p:'M 405 605 L 405 682 L 915 682 L 915 605',l:[767,671]},
'config-sync':{p:'M 150 380 L 150 525',l:[195,457]},'storage-sync':{p:'M 355 380 L 355 444 L 248 444 L 248 525',l:[348,432]},'sync-cloud':{p:'M 255 565 L 279 565 L 279 479 L 915 479 L 915 380',l:[535,467]}
};
const manualAgent={
'ui-send':{p:'M 209 149 L 270 149',l:[239,133]},'send-session':{p:'M 475 149 L 540 149',l:[508,133]},
'session-context':{p:'M 650 188 L 650 300',l:[717,231]},'context-loop':{p:'M 540 339 L 475 339',l:[508,325]},
'loop-providers':{p:'M 415 300 L 415 251 L 917 251 L 917 300',l:[819,239]},
'providers-stream':{p:'M 917 378 L 917 461 L 371 461 L 371 535',l:[733,450]},
'stream-ui':{p:'M 270 574 L 234 574 L 234 222 L 115 222 L 115 188',l:[153,210]},
'stream-loop':{p:'M 340 535 L 340 378',l:[398,495]},
'loop-tools':{p:'M 475 355 L 506 355 L 506 508 L 917 508 L 917 535',l:[641,496]},
'tools-loop':{p:'M 824 594 L 789 594 L 789 414 L 443 414 L 443 378',l:[665,403]},
'loop-storage':{p:'M 293 378 L 293 494 L 115 494 L 115 535',l:[185,483]}
};
const manualMcp={
'mcpui-mcp':{p:'M 208 150 L 270 150',l:[238,133]},'mcp-mcpdisk':{p:'M 470 150 L 542 150',l:[506,133]},
'mcp-override':{p:'M 450 190 L 450 243 L 648 243 L 648 315',l:[549,231]},
'mcp-mcpsnippet':{p:'M 370 190 L 370 315',l:[418,279]},'mcpsnippet-agent':{p:'M 270 355 L 208 355',l:[237,337]},
'mcpui-refresh':{p:'M 100 190 L 100 253 L 237 253 L 237 585 L 270 585',l:[165,241]},
'refresh-ish':{p:'M 420 545 L 420 464 L 795 464 L 795 150 L 818 150',l:[538,452]},
'ish-cli':{p:'M 914 190 L 914 315',l:[968,268]},'cli-mcpdisk':{p:'M 818 355 L 785 355 L 785 220 L 690 220 L 690 190',l:[735,209]},
'mcp-mcpsync':{p:'M 470 174 L 495 174 L 495 505 L 648 505 L 648 545',l:[572,493]},
'mcpsync-sync':{p:'M 757 585 L 818 585',l:[788,568]}
};
function routeEdge(e,positions,scope){const map=scope==='mcp'?manualMcp:scope==='agent'?manualAgent:null;if(map&&map[e.a+'-'+e.b])return map[e.a+'-'+e.b];if(scope==='overview'&&manualOverview[e.a+'-'+e.b])return manualOverview[e.a+'-'+e.b];let A=positions[e.a],B=positions[e.b];if(!A||!B)return null;let [ax,ay,aw,ah]=A,[bx,by,bw,bh]=B;let x1=ax+aw/2,y1=ay+ah/2,x2=bx+bw/2,y2=by+bh/2;
 if(Math.abs(y1-y2)<15){let forward=x2>x1;x1=forward?ax+aw:ax;x2=forward?bx:bx+bw;return {p:`M ${x1} ${y1} L ${x2} ${y2}`,l:[(x1+x2)/2,y1-15]}}
 if(Math.abs(x1-x2)<20){let down=y2>y1;y1=down?ay+ah:ay;y2=down?by:by+bh;return {p:`M ${x1} ${y1} L ${x2} ${y2}`,l:[x1+53,(y1+y2)/2]}}
 let down=y2>y1;y1=down?ay+ah:ay;y2=down?by:by+bh;let mid=(y1+y2)/2;return {p:`M ${x1} ${y1} L ${x1} ${mid} L ${x2} ${mid} L ${x2} ${y2}`,l:[(x1+x2)/2,mid-12]};}

function graphSVG(scope, selected, query='') {
 const S=SCOPES[scope], positions=Object.fromEntries(S.nodes.map(([id,...p])=>[id,p]));
 const q=query.trim().toLowerCase();
 const related=new Set([selected]);
 S.edges.forEach(e=>{if(e.a===selected)related.add(e.b);if(e.b===selected)related.add(e.a)});
 const bounds=S.bounds.map((b,i)=>`<rect class="boundary ${i===0?'local':''}" x="${b.x}" y="${b.y}" width="${b.w}" height="${b.h}" rx="13"/><text class="boundary-label" x="${b.x+14}" y="${b.y+23}">${esc(b.label)}</text>`).join('');
 const shortLabels={overview:{'ui-agent':'发送','agent-providers':'请求','providers-llm':'API'},agent:{'ui-send':'调用','send-session':'await','context-loop':'上下文'},mcp:{'mcpui-mcp':'操作','mcp-mcpdisk':'读写 JSON','mcpsnippet-agent':'提示词','mcpsync-sync':'dirty'}};
 const edges=S.edges.map(e=>{
  const edgeLabel=shortLabels[scope]?.[e.a+'-'+e.b] || e.label;
  const r=routeEdge(e,positions,scope);if(!r)return '';
  const on=selected&&(e.a===selected||e.b===selected), style=selected?(on?'active':'dim'):'';
  const provisional=['doc','overview'].includes(e.kind);
  const width=[...edgeLabel].reduce((sum,c)=>sum+(/[\u0000-\u007f]/.test(c)?5.8:11),12);
  return `<path class="edge ${style} ${provisional?'doc':''}" d="${r.p}" marker-end="url(#arrow-${on?'active':'base'})"/><g class="edge-label ${style}"><rect x="${r.l[0]-width/2}" y="${r.l[1]-11}" width="${width}" height="16" rx="4" fill="#f8fafd"/><text class="label" x="${r.l[0]}" y="${r.l[1]}" text-anchor="middle">${esc(edgeLabel)}</text></g>`;
 }).join('');
 const shapes=S.nodes.map(([id,x,y,w,h])=>{
  const n=NODES[id], match=!q||searchText(n).includes(q);
  const faded=q?!match:(selected&&!related.has(id));
  const maxChars=Math.floor((w-27)/6);
  const subtitle=n.subtitle.length>maxChars?n.subtitle.slice(0,maxChars-1)+'…':n.subtitle;
  return `<g class="node ${id===selected?'selected':''} ${faded?'dim':''}" data-select-node="${id}" role="button" tabindex="0" aria-pressed="${id===selected?'true':'false'}" aria-label="查看${esc(n.title)}摘要"><title>${esc(n.title)} · ${esc(n.summary)}</title><rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10"/><text class="title" x="${x+14}" y="${y+33}">${esc(n.title)}</text><text class="subtitle" x="${x+14}" y="${y+55}">${esc(subtitle)}</text>${(DETAIL_SCOPES[id]||id==='config')&&id!==route.id?`<text class="tag-text" x="${x+w-12}" y="${y+17}" text-anchor="end">＋</text>`:''}</g>`;
 }).join('');
 return `<svg class="graph" viewBox="0 0 ${S.w} ${S.h}" role="group" aria-label="${esc(scope==='overview'?'整体架构关系图':scope==='agent'?'Agent 内部职责与协作模块':'MCP 内部职责与协作模块')}"><defs><marker id="arrow-base" markerWidth="7" markerHeight="7" refX="6" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L6,3 L0,6" fill="#9cacc4"/></marker><marker id="arrow-active" markerWidth="7" markerHeight="7" refX="6" refY="3" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L6,3 L0,6" fill="#4c75cc"/></marker></defs>${bounds}${edges}${shapes}</svg>`;
}
function searchText(n) {return [n.title,n.subtitle,n.role,...n.refs.map(r=>r.path+' '+r.symbol)].join(' ').toLowerCase();}
function relationItems(scope,id) {return SCOPES[scope].edges.filter(e=>e.a===id||e.b===id);}
function allRelations(id) {
 const seen=new Set(),result=[];
 for(const scope of Object.values(SCOPES)) for(const e of scope.edges) {
  const key=e.a+'|'+e.b;
  if((e.a===id||e.b===id)&&!seen.has(key)){seen.add(key);result.push(e);}
 }
 return result;
}
function searchResults(scope,q) {
 if(!q.trim())return '';
 const matches=SCOPES[scope].nodes.filter(([id])=>searchText(NODES[id]).includes(q.trim().toLowerCase()));
 return `<span>${matches.length?`本图找到 ${matches.length} 个节点`:'本图匹配 0 项。可清空输入后选择节点。'}</span>${matches.map(([id])=>`<button class="result-btn" data-select-node="${id}">${esc(NODES[id].title)}</button>`).join('')}`;
}
function previewHTML(scope, selected) {
 if(!selected) return `<div class="empty-preview"><div class="preview-label">图中节点摘要</div><h2>先选择一个模块</h2><p class="muted">单击图中的方框，查看它的职责和直接连接。进入详情页后，再阅读内部结构与代码。</p><div class="rule"></div><p class="micro">选中节点只更新本图与摘要，当前页面位置保持不变。</p></div>`;
 const n=NODES[selected], edges=relationItems(scope,selected), isSelf=route.page==='module'&&selected===route.id;
 const place=scope==='overview'?'整体中的模块':OWN_NODES[scope].has(selected)?'本模块的内部职责 / 数据':'本图中的协作方';
 const buttonText=isSelf?'查看本页职责说明':selected==='agent'?'进入 Agent 内部':selected==='mcp'?'进入 MCP 内部':'阅读模块详情';
 return `<div class="preview-main"><div class="preview-label">当前选中 · ${place}</div><h2 id="preview-title">${esc(n.title)}</h2><div class="subtitle">${esc(n.subtitle)}</div><p>${esc(n.summary)}</p><div class="runtime">运行位置：${esc(n.runtime)}</div></div><div class="relation-mini"><h3>直接连接 <span class="micro">${edges.length} 条</span></h3>${edges.slice(0,5).map(e=>{const incoming=e.b===selected,other=incoming?e.a:e.b;return `<div class="relation-row"><span class="arrow">${incoming?'←':'→'}</span><div><span class="rel-name">${esc(NODES[other].title)}</span><span class="rel-label">${esc(e.label)}</span></div></div>`}).join('')}${edges.length>5?'<p class="micro">完整连接见模块详情。</p>':''}</div><div class="actions">${isSelf?`<a href="#module-info" data-scroll="module-info" class="btn primary">${buttonText} ↑</a>`:`<a href="${href(moduleRoute(selected))}" data-nav class="btn primary">${buttonText} →</a>`}</div><div class="preview-status">核查范围：${esc(n.level)}</div>`;
}
function mapHTML(scope, selected) {
 const q=queryByPage[pathOf(route)]||'';
 return `<div class="map-layout"><section class="card map-card" aria-label="关系图"><div class="map-toolbar"><div class="map-heading">${scope==='overview'?'模块与连接':'内部组成与协作关系'}<small>单击查看摘要；从摘要进入详情。</small></div><label class="search"><span aria-hidden="true">⌕</span><input id="map-search" type="search" value="${esc(q)}" placeholder="在本图查找模块 / 符号" aria-label="在当前图中查找模块、文件或符号"><button type="button" data-clear-search aria-label="清空图中搜索">×</button></label></div><div id="map-results" class="search-results" aria-live="polite" ${q?'':'hidden'}>${searchResults(scope,q)}</div><div class="graph-scroll" id="graph-container">${graphSVG(scope,selected,q)}</div><div class="map-caption"><span><i class="legend-line"></i>代码接口关系</span><span><i class="legend-line dashed"></i>文档 / 概览关系</span><span>蓝色：选中节点及其连接</span>${selected?`<a class="stack-only" href="#node-preview" data-scroll="node-preview">查看选中摘要 ↓</a>`:''}</div></section><aside class="card preview" id="node-preview" aria-label="选中节点摘要">${previewHTML(scope,selected)}</aside></div>`;
}
function overviewPage() {
 return `${breadcrumb([['整体架构',null]])}${head('01 / 看清各部分的关系','整体架构','先看各部分如何协作。选中模块查看摘要，进入详情后再展开它的内部职责。')}${mapHTML('overview',route.selected)}<div class="journey"><section class="card journey-card"><div class="journey-no">A</div><div><h2>沿架构层级深入</h2><p>从 Agent 进入发送入口、上下文和主循环。每一层都保留明确的上级位置。</p><a class="text-link" href="#/module/agent" data-nav>整体架构 → Agent 内部 →</a></div></section><section class="card journey-card"><div class="journey-no">B</div><div><h2>沿一条消息逐步阅读</h2><p>用同一句示例消息追踪 8 个主流程步骤，在第 6 步后展开工具等条件分支。</p><a class="text-link" href="#/flow/01" data-nav>开始阅读发送消息流程 →</a></div></section></div><section class="scope-strip"><strong>本版展开范围：iOS 主线、MCP、iSH 与原生能力。</strong> 仓库其他部分保留入口，后续按阅读顺序核查。<div class="paths"><span class="tag code">src/ios · 当前主线</span><span class="tag code">src/android · 目录定位</span><span class="tag code">src/shared · 共享内容</span><span class="tag code">deps · 原生依赖</span><span class="tag code">docs · 文档</span></div></section>${footer()}`;
}
function relatedFlowLinks(id) {
 let related=[];
 STEPS.forEach((s,i)=>{if(s.node===id)related.push([i+1,s.title]);});
 const extras={config:[5],mcp:[5],providers:[5],storage:[3,7],mcpui:[5],mcpdisk:[5],override:[5],mcpsnippet:[5],mcpsync:[5],llm:[5,6]};
 for(const i of extras[id]||[]) if(!related.some(r=>r[0]===i))related.push([i,STEPS[i-1].title]);
 let html=related.map(([i,title])=>`<a class="related-step" href="${href(flowRoute(i))}" data-nav><span class="num">${pad(i)}</span>${esc(title)} →</a>`).join('');
 if(['tools','ish','native','os','cli','refresh'].includes(id))html+=`<a class="related-step" href="#/flow/tools?at=06" data-nav><span class="num">A</span>工具调用分支 →</a>`;
 return html;
}
function modulePage() {
 const n=NODES[route.id], scope=scopeOf(route), relations=allRelations(n.id);
 const codePaths=unique(n.refs.filter(r=>r.kind==='源码').map(r=>r.path));
 const flowLinks=relatedFlowLinks(n.id);
 const children=n.id==='config'?`<section class="section-space"><h2 class="section-title">继续深入本模块</h2><div class="child-card"><div><h3>MCP 配置中心</h3><p>从服务器配置、会话开关到提示词片段，查看 MCP 如何为请求准备可用服务器信息。</p></div><a class="btn primary" href="${href(moduleRoute('mcp'))}" data-nav>进入 MCP 内部 →</a></div></section>`:'';
 const diagram=scope?`<section class="section-space"><h2 class="section-title">内部结构与协作边界</h2><p class="module-boundary-note">${scope==='agent'?'中间区域展开 Agent 的内部职责；两侧保留界面、存储、模型与工具协作方。':'中间区域展开 MCPStore 的方法和数据；两侧保留调用方、iSH 与同步协作方。'} 选择协作方时，详情页使用它自己的上级路径。</p>${mapHTML(scope,route.selected)}</section>`:'';
 return `${returnStrip()}${moduleBreadcrumb(n.id)}${head('01 / 模块详解',n.title,n.summary)}<div class="module-intro" id="module-info"><section class="card responsibility"><h2>它负责什么</h2><p>${esc(n.role)}</p><div class="module-facts"><span class="tag outline">${esc(n.runtime)}</span><span class="tag">${PARENT[n.id]?'上级：'+esc(NODES[PARENT[n.id]].title):'整体中的独立职责'}</span></div><div class="preview-status">核查范围：${esc(n.level)}</div></section>${locationHTML(n.id)}</div>${children}${diagram}${moduleDeepDive(n.id)}<section class="section-space module-grid"><div class="card info-card"><h2>数据和状态</h2><dl><div class="data-row"><dt>输入</dt><dd>${esc(n.inputs)}</dd></div><div class="data-row"><dt>输出</dt><dd>${esc(n.outputs)}</dd></div><div class="data-row"><dt>关键状态</dt><dd>${esc(n.states)}</dd></div></dl></div><div class="card info-card"><h2>与其他部分如何连接</h2><div class="relations-full">${relations.length?relations.map(e=>{let other=e.a===n.id?e.b:e.a;return `<div class="relation-full"><div class="heading"><span>${e.a===n.id?'交给 →':'来自 ←'}</span><a href="${href(moduleRoute(other))}" data-nav>${esc(NODES[other].title)}</a>${['doc','overview'].includes(e.kind)?'<span class="tag pending">概览关系</span>':''}</div><p>${esc(e.label)}</p></div>`}).join(''):'<p class="muted">本版先保留职责与源码入口，完整调用关系列入后续核查。</p>'}</div></div></section>${flowLinks?`<section class="section-space"><h2 class="section-title">在发送消息中何时参与</h2><div class="related-steps">${flowLinks}</div></section>`:''}<section class="section-space"><h2 class="section-title">对应到代码</h2>${codePaths.length?`<p class="section-desc">${codePaths.map(p=>`<code>${esc(p)}</code>`).join('<br>')}</p>`:''}${sourceDetails(n.refs)}<p class="micro" style="margin-top:9px">职责分组用于阅读；实际类型、路径与行号以固定提交中的源码为准。</p></section><div class="module-bottom"><a class="btn" href="${href(PARENT[n.id]?moduleRoute(PARENT[n.id]):{page:'architecture',selected:SCOPES.overview.nodes.some(x=>x[0]===n.id)?n.id:null})}" data-nav>← 返回${PARENT[n.id]?esc(NODES[PARENT[n.id]].title):'整体架构'}</a>${route.from?`<a class="text-link" href="${esc('#'+route.from)}" data-nav data-return>返回${esc(returnTitle(route.from))} →</a>`:''}</div>${footer()}`;
}
function capRoute(tab='integrated', group='all', focus='') {
 let from=route.page==='capabilities'?route.from:(contextOrigin() || (route.page==='module'?serialize({...route,from:''}).slice(1):''));
 return {page:'capabilities',tab,group,focus,from};
}
function nativeChain(active) {
 const items=[['ish','01','执行命令','独立进程、会话路径、输出与退出码'],['native','02','桥接具体能力','匹配处理器、参数、权限与结果封装'],['os','03','调用系统框架','访问授权对象，等待系统完成结果']];
 return `<section class="section-space"><h2 class="section-title">这三部分怎样衔接</h2><nav class="native-chain" aria-label="命令到系统能力的关系">${items.map(([id,num,title,text],i)=>`${i?'<span class="native-chain-arrow" aria-hidden="true">→</span>':''}<a class="card native-stage ${id===active?'current':''}" href="${href(moduleRoute(id))}" data-nav ${id===active?'aria-current="page"':''}><span class="eyebrow">${num} · ${esc(NODES[id].title)}</span><strong>${title}</strong><span>${text}</span></a>`).join('')}</nav><p class="chain-note">图示追踪调用方向；结果经系统回调 → 处理器输出 → 命令结果 → Agent 返回。三个环节都运行于设备侧，部分系统服务和后续模型请求涉及联网。</p></section>`;
}
function capGateway() {
 return `<section class="card cap-gateway section-space"><div class="heading-row"><div><div class="eyebrow">单独查阅 / 已接入与当前缺口</div><h2>原生能力清单 <span class="cap-number">27 组注册</span></h2></div><a class="btn primary" href="${href(capRoute())}" data-nav>打开完整清单 →</a></div><p>按处理器注册口径整理。每项并列说明常用操作、访问条件、当前接口缺口与源码依据。</p><div class="cap-group-grid">${CAPS.groups.map(g=>`<a href="${href(capRoute('integrated',g.id))}" data-nav class="cap-group-link"><strong>${g.title}<span>${CAPS.items.filter(c=>c.group===g.id).length}</span></strong><small>${g.hint}</small></a>`).join('')}</div><a class="text-link" href="${href(capRoute('limits'))}" data-nav>查看尚未接入、范围限制与待核验事项 →</a></section>`;
}
function frameworkCrosswalk() {
 return `<section class="section-space"><h2 class="section-title">系统框架与已接入操作的对应关系</h2><p class="section-desc">点击能力名称，进入同一份清单中的对应条目。框架名称表示底层接口，项目命令决定当前可以执行的操作。</p><div class="card framework-table">${DATA.frameworks.map(f=>`<div class="framework-row"><div><h3>${esc(f.name)}</h3><span class="micro">${esc(f.title)}</span></div><div><p>${esc(f.description)}</p><div class="cap-chips">${f.capabilities.map(id=>`<a class="tag outline" href="${href(capRoute('integrated','all',id))}" data-nav>${esc(CAP_BY_ID[id].title)} ↗</a>`).join('')}</div></div></div>`).join('')}</div><p class="chain-note">FFmpeg 使用原生第三方库；会话、配置、模型辅助调用与日志使用 MinisX 自身模块。它们在原生注册清单中分别归类。</p></section>`;
}
function moduleDeepDive(id) {
 const guide=DATA.moduleGuides[id];if(!guide)return '';
 const example=id==='os'?'从处理器参数到系统结果':'例子：查看今天的日历事件';
 return `${nativeChain(id)}${capGateway()}${id==='os'?frameworkCrosswalk():''}<section class="section-space"><h2 class="section-title">${example}</h2><div class="example-strip"><span class="tag outline">静态路径示例</span><code>shell_execute → apple-calendar list --today --compact</code></div><p class="section-desc" style="margin-top:12px">${esc(guide.intro)}</p><div class="card native-walkthrough">${guide.steps.map(([title,text,connection],i)=>`<div class="native-step"><div class="native-step-num">${pad(i+1)}</div><div><h3>${esc(title)}</h3><p>${esc(text)}</p><div class="native-handoff">${esc(connection)}</div></div></div>`).join('')}</div></section><section class="section-space"><h2 class="section-title">理解这个环节的关键细节</h2><div class="native-notes">${guide.details.map(([title,text])=>`<article class="card native-note"><h3>${esc(title)}</h3><p>${esc(text)}</p></article>`).join('')}</div></section>${id==='native'?`<section class="section-space"><h2 class="section-title">成功和失败各返回什么</h2><div class="native-result-grid"><article class="card native-note"><span class="tag verified">成功结构示意</span><pre><code>${esc(JSON.stringify({ok:true,tool:'apple-calendar',action:'list',data:{events:[],count:0}},null,2))}</code></pre><p>保留了理解链路所需字段。示例中的空数组仅演示形状，真实查询还可能包含时间范围等字段。</p></article><article class="card native-note"><span class="tag pending">失败结构示意</span><pre><code>${esc(JSON.stringify({ok:false,tool:'apple-calendar',action:'list',error:{code:'authorization_denied',message:'Calendar access not granted'}},null,2))}</code></pre><p>处理器错误由 JSON 和退出码共同表达。排查时把命令输入、exitCode 和 error.code 对应起来。</p></article></div><p class="chain-note">公共封装还添加 timestamp；--quiet 会只输出 data 或 error。上面的内容为教学示意，设备上尚未执行。</p></section>`:''}<section class="section-space">${sourceDetails(guide.refs,'本节执行链路的源码依据')}</section>`;
}
function capItem(c) {
 const focus=route.focus===c.id;
 return `<details class="card capability-card" id="cap-${c.id}" ${focus?'open':''}><summary><div class="cap-identity"><h3>${esc(c.title)}</h3><code>${esc(c.command)}</code><span class="micro">${esc(c.platform)}</span></div><div class="cap-operations"><div><span class="cap-field">读取 / 查询</span><p>${esc(c.read)}</p></div><div><span class="cap-field">写入 / 执行</span><p>${esc(c.write)}</p></div></div><div class="cap-gap"><span class="cap-field">当前缺口 / 范围边界</span>${c.gaps.map(t=>`<p>${esc(t)}</p>`).join('')}<span class="cap-expand">展开条件与源码 <span aria-hidden="true">＋</span></span></div></summary><div class="cap-detail"><div class="cap-conditions"><strong>实际执行条件</strong><p>${esc(c.conditions)}</p><p class="micro">注册入口：<code>${esc(c.registration)}</code> · <a href="${esc(sourceURL(CAPS.registry))}" target="_blank" rel="noopener">ISHKernel 启动注册 ↗</a></p><span class="tag verified">静态核查：${esc(c.depth)}</span><p class="micro">注册入口已核对；具体操作按本项列出的读取深度说明。实机授权、返回字段与执行结果仍待验证。</p></div>${refsHTML(c.refs)}<div class="cap-item-actions"><a class="text-link" href="${href(moduleRoute('native'))}" data-nav>回到原生桥接的执行关系 →</a><a class="text-link" href="${href(moduleRoute('os'))}" data-nav>查看 iOS 框架与权限边界 →</a></div></div></details>`;
}
function capResults() {
 const q=capQuery.trim().toLowerCase();
 if(route.tab==='limits') {
  const levels={missing:['接口尚未接入','pending'],scoped:['已实现操作有范围限制','outline'],unverified:['完整路径待核验','']};
  const gaps=CAPS.gaps.filter(c=>[c.title,c.summary,c.interpretation,...c.related.map(x=>CAP_BY_ID[x].command)].join(' ').toLowerCase().includes(q));
  return `<div class="cap-count" role="status" aria-live="polite">${gaps.length} 类${q?'匹配结果':'重点缺口、范围边界与待核验事项'}。各能力行还列出细分限制；结论限定于本版源码与已读取入口。</div><div class="limit-grid">${gaps.map(c=>`<article class="card limit-card"><span class="tag ${levels[c.status][1]}">${levels[c.status][0]}</span><h3>${esc(c.title)}</h3><p>${esc(c.summary)}</p><div class="limit-interpretation">${esc(c.interpretation)}</div>${c.related.length?`<div class="cap-chips">${c.related.map(id=>`<a href="${href(capRoute('integrated','all',id))}" data-nav class="tag outline">${esc(CAP_BY_ID[id].title)} →</a>`).join('')}</div>`:''}${sourceDetails(c.refs,'确认依据')}</article>`).join('')}</div>${gaps.length?'':'<div class="notice">当前关键词没有匹配条目。<button class="btn" data-clear-caps>清空搜索</button></div>'}`;
 }
 const entries=CAPS.items.filter(c=>(route.group==='all'||c.group===route.group)&&[c.title,c.command,c.platform,c.read,c.write,c.conditions,...c.gaps].join(' ').toLowerCase().includes(q));
 return `<div class="cap-count" role="status" aria-live="polite">显示 ${entries.length} / 27 组注册处理器。各行直接列出操作和边界，展开后查看条件与源码。</div>${CAPS.groups.map(g=>{const group=entries.filter(c=>c.group===g.id);return group.length?`<section class="cap-category"><div class="heading-row"><h2>${g.title} <span class="tag">${group.length} 组</span></h2><span class="micro">${g.hint}</span></div><div class="cap-row-label" aria-hidden="true"><span>能力 / 项目命令</span><span>当前已接入的操作</span><span>当前缺口与边界</span></div>${group.map(capItem).join('')}</section>`:''}).join('')}${entries.length?'':'<div class="notice">当前筛选没有匹配条目。<button class="btn" data-clear-caps>清空搜索</button></div>'}`;
}
function capabilitiesPage() {
 return `${returnStrip()}${breadcrumb([['整体架构',{page:'architecture'}],['原生能力桥接',moduleRoute('native')],['原生能力清单',null]])}${head('03 / 按能力查操作和边界','原生能力清单','先确认项目已经接入哪些操作，再检查访问范围、权限和运行条件。各条目对应原生桥接中的处理器。')}<div class="cap-summary-band"><div><strong>27</strong><span>组处理器注册</span></div><div><strong>21</strong><span>个 apple-* 命令组</span></div><div><strong>6</strong><span>组 ffmpeg / minis-* 工具</span></div><p>${esc(CAPS.scope)}</p></div><div class="cap-controls"><nav class="cap-tabs" aria-label="能力清单视图"><a class="${route.tab!=='limits'?'current':''}" href="${href(capRoute())}" data-nav ${route.tab!=='limits'?'aria-current="page"':''}>已接入能力 <span>27</span></a><a class="${route.tab==='limits'?'current':''}" href="${href(capRoute('limits'))}" data-nav ${route.tab==='limits'?'aria-current="page"':''}>缺口与边界 <span>11</span></a></nav><label class="search cap-search"><span aria-hidden="true">⌕</span><input id="capability-search" type="search" value="${esc(capQuery)}" placeholder="搜索能力、命令或限制" aria-label="搜索能力、命令或限制"><button type="button" data-clear-caps aria-label="清空能力搜索">×</button></label></div>${route.tab==='limits'?`<section class="notice cap-legend"><strong>阅读“暂不支持”时分清三种情况</strong>接口尚未接入：当前项目缺少对应封装。范围限制：已有操作作用于特定对象。待核验：完整执行路径还需单独分析。系统能否提供某项功能，应结合对应 API 与运行条件进一步确认。</section>`:`<nav class="cap-filter-chips" aria-label="按能力类别筛选"><a class="tag ${route.group==='all'?'selected':''}" href="${href(capRoute())}" data-nav>全部</a>${CAPS.groups.map(g=>`<a class="tag ${route.group===g.id?'selected':''}" href="${href(capRoute('integrated',g.id))}" data-nav>${g.title}</a>`).join('')}</nav>`}<div id="capability-results">${capResults()}</div><section class="section-space"><h2 class="section-title">与清单相邻的 Agent 能力</h2><p class="section-desc">以下入口按自己的工具路径实现，采用独立统计口径。</p><div class="adjacent-tools">${CAPS.relatedTools.map(t=>`<article class="card native-note"><h3>${esc(t.title)}</h3><code>${esc(t.commands)}</code><p>${esc(t.note)}</p></article>`).join('')}</div></section><section class="section-space">${sourceDetails([CAPS.registry,{path:'docs/specs/ios-device-data-capabilities.md',symbol:'完整能力清单及静态核查边界',kind:'项目文档'}],'清单口径与总依据')}</section><div class="module-bottom"><a class="btn" href="${href(moduleRoute('native'))}" data-nav>← 查看原生能力桥接</a><a class="text-link" href="${href(moduleRoute('ish'))}" data-nav>iSH 怎样执行这些命令 →</a></div>${footer()}`;
}

function timelineHTML(current, branch=null) {
 return `<section class="card timeline" aria-label="发送消息主流程"><div class="timeline-scroll"><ol class="timeline-list">${STEPS.map((s,i)=>`<li class="timeline-step ${i+1===current?'current':i+1<current?'complete':''}"><a href="${href(flowRoute(i+1))}" data-nav ${i+1===current&&!branch?'aria-current="step"':''} title="${esc(s.title)}"><span class="step-circle">${pad(i+1)}</span><span>${STEP_SHORT[i]}</span></a></li>`).join('')}</ol></div><div class="timeline-branch"><span class="section-label">条件分支</span><a href="#/flow/tools?at=06" data-nav class="${branch==='tools'?'active':''}">A 工具调用 · 06 → 05</a><a href="${href({page:'flow',branch:'failure',at:current})}" data-nav class="${branch==='failure'?'active':''}">B 请求失败</a><a href="${href({page:'flow',branch:'stop',at:current})}" data-nav class="${branch==='stop'?'active':''}">C 用户停止</a><span>主流程共 8 步；分支单独展开。</span></div></section>`;
}
const CONCEPTS = {
 1:[['绑定','输入框与会话对象共享 inputText。界面提交时，会话对象读取这份文本。'],['直接调用','performSend() 在当前位置调用 vm.send()，后者先执行自己的同步部分。']],
 2:[['可观察状态','界面订阅状态变化。messages 或处理标记更新后，界面得到更新信号。'],['Task','Task 承载后续异步工作；本步骤在同步更新界面后创建它。']],
 3:[['同一消息的三个表示','ChatMessage 用于显示，AgentMessage 用于模型历史，RawMessage 用于持久化。保存成功后通过 ID 关联。'],['await','任务等待会话或数据库操作的结果；等待期间可以让出执行机会。']],
 4:[['并发名额','会话在进入 Agent 循环前申请运行名额。等待名额时用 isSuspended 表示暂停状态。'],['defer','离开当前作用域时执行清理；这里用于释放已取得的会话名额。']],
 5:[['上下文','本次模型请求携带的历史、系统提示、当前消息与工具定义。'],['Provider','模型接入对象提供统一接口，把不同模型的回复整理为应用理解的事件。']],
 6:[['增量事件','textDelta 携带新到的一段文本。程序累积内容，再更新对应的显示块。'],['MainActor','界面相关状态修改归到主执行域。流处理把显示更新交回这里。']],
 7:[['结束原因','stopReason 用于区分正常结束、输出额度耗尽、拒绝等结果；缺失结束信号也有单独处理。'],['提交点','流式显示先发生，历史与数据库在指定位置保存；这几个状态需要分别核对。']],
 8:[['数据库基线','数量、排序与顺序哈希记录本机已知的数据状态，用于后续重载判断。'],['任务所有权','取消后可能有新任务处理排队消息。旧任务在收尾前检查自身是否已经取消。']]
};
function flowSidebar(nodeId, step, extra='') {
 const n=NODES[nodeId];
 return `<aside class="flow-side"><section class="card flow-side-card"><h2>当前负责模块</h2><h3>${esc(n.title)}</h3><div class="reading-trail">${ancestry(nodeId).map(x=>esc(NODES[x].title)).join(' → ')}</div>${miniMap(nodeId)}<p>完整关系在架构页展开，返回后继续当前步骤。</p><a class="btn wide" href="${href(moduleRoute(nodeId))}" data-nav>查看模块关系 →</a></section>${step?`<section class="card flow-side-card"><h2>读这一步需要的概念</h2>${(CONCEPTS[step]||[]).map(([title,desc])=>`<div class="concept"><strong>${esc(title)}</strong><p>${esc(desc)}</p></div>`).join('')}</section>`:''}${extra}</aside>`;
}
function flowFields(step) {
 const s=STEPS[step-1];
 return `<dl class="flow-fields"><div class="flow-field"><dt>如何触发</dt><dd>${esc(s.trigger)}</dd></div><div class="flow-field owner"><dt>由谁负责</dt><dd>${esc(s.owner)}</dd></div><div class="flow-field"><dt>接收什么</dt><dd>${esc(s.input)}</dd></div><div class="flow-field"><dt>做了什么</dt><dd>${esc(s.process)}</dd></div><div class="flow-field"><dt>留下什么</dt><dd>${esc(s.output)}</dd></div></dl>`;
}
function flowPage() {
 const k=route.step,s=STEPS[k-1];
 const connection=k===6?'processStreamEvents() 把 StreamResult 返回主循环。主路径在工具列表为空时进入第 07 步；包含完整工具调用时，先进入分支 A。':s.connect;
 const next=k<8?`<a class="next-link" href="${href(flowRoute(k+1))}" data-nav><small>${k===6?'主路径：工具列表为空':'继续主流程'}</small><span>下一步 · ${pad(k+1)} ${STEP_SHORT[k]} →</span></a>`:`<a class="next-link" href="#/architecture" data-nav><small>主流程已到末尾</small><span>回到整体架构 →</span></a>`;
 return `${breadcrumb([['发送消息',flowRoute(1)],['第 '+pad(k)+' 步 · '+STEP_SHORT[k-1],null]])}${head('02 / 跟踪一条消息','发送消息','按照执行顺序阅读每一步。工具、失败和停止作为条件分支展开，主流程编号始终保持一致。')}<div class="example-strip"><span class="label">贯穿示例</span><strong>“请解释什么是概率密度。”</strong><span class="assumption">普通文本 · 无附件 · 无排队 · 上下文容量充足</span></div>${timelineHTML(k)}<div class="flow-layout"><article class="card flow-article" id="step-article"><header class="step-heading"><div class="big-step">${pad(k)}</div><div><div class="stage">${STAGES[k-1]}</div><h2>${esc(s.title)}</h2></div></header><div class="message-now"><strong>同一条消息此刻在哪里</strong>${esc(s.example)}</div>${flowFields(k)}<div class="handoff"><strong>${k===8?'如何回到可输入状态':'如何交给下一环节'}</strong>${esc(connection)}</div>${k===6?`<div class="branch-invitation"><strong>模型同时提出了工具调用？</strong><p>先完成工具执行、归并并保存结果，再携带结果进入下一轮模型请求。</p><a class="text-link" href="#/flow/tools?at=06" data-nav>展开分支 A · 工具调用 →</a></div>`:''}${k===5?`<details class="card sources-panel"><summary>模型决定什么，程序控制什么？</summary><div class="sources-body"><div class="decision-columns"><div><h3>模型生成</h3><p>回复内容、工具名称、参数，以及基于工具结果形成的后续输出。</p></div><div><h3>程序控制</h3><p>请求材料、工具定义、参数校验、并发、取消、保存和界面更新。</p></div></div></div></details>`:''}${sourceDetails(s.refs)}<nav class="flow-next" aria-label="前后步骤">${k>1?`<a class="previous-link" href="${href(flowRoute(k-1))}" data-nav>← ${pad(k-1)} ${STEP_SHORT[k-2]}</a>`:'<span class="micro">主流程起点</span>'}${next}</nav></article>${flowSidebar(s.node,k)}</div>${footer()}`;
}
function branchPage() {
 const kind=route.branch,at=route.at||6;
 const stepBack=flowRoute(at);
 let body='',node='loop',refs=[];
 if(kind==='tools') {
  node='tools';refs=DATA.steps[6].refs;
  body=`<div class="branch-trigger"><strong>进入条件：</strong>第 06 步返回的 StreamResult 中包含完整工具调用。当前贯穿示例采用直接回答路径；这里展示条件成立时的执行去向。</div><div class="branch-chain"><span>06 收到工具调用</span>→<span>执行并保存结果</span>→<a href="#/flow/05" data-nav>05 下一轮模型请求 ↶</a></div>${[
    ['A1','接收并检查','读取工具 ID、名称、最终参数和显示块索引。executeSingleToolUse() 先处理取消、循环检测和参数校验，再进入对应工具的执行路径。'],
    ['A2','执行具体工具','runAgentLoop() 使用 TaskGroup 调度调用，当前并发上限为 10。shell 子路径继续交给 iSH；其他工具按各自入口执行。具体工具和参数由模型返回。'],
    ['A3','将结果放回同一条会话','按原始工具调用顺序归并 ToolExecOutcome，生成 toolResult。内部消息采用 role=user 携带工具结果，随后将助手调用与工具结果保存。'],
    ['A4','交回模型继续判断','满足继续条件时，循环重新取得包含工具结果的有效历史，再请求模型。后续仍可产生工具调用，也可输出最终回复并进入结束路径。']
   ].map(([n,t,p])=>`<section class="branch-step"><div class="num">${n}</div><div><h3>${t}</h3><p>${p}</p></div></section>`).join('')}<div class="handoff"><strong>本分支的出口</strong>工具执行与结果回填由程序负责；模型在下一轮收到结果后生成后续内容。继续执行沿第 05 → 06 步循环。</div>`;
 } else if(kind==='failure') {
  refs=DATA.branches[1].refs;
  body=`<div class="branch-trigger"><strong>进入条件：</strong>模型请求或流处理出现错误，或者流结束后缺少有效的终止信息。此页保留你进入分支时的主流程位置。</div><p>${esc(DATA.branches[1].text)}</p>${[
   ['B1','先确定中断发生在哪里','请求建立失败、读取事件时抛错、流结束但 stopReason 缺失，需要分别定位。核对本轮请求、StreamResult 与界面错误状态。'],
   ['B2','经过恢复入口','程序在 streamWithGroupFallback() 与 processStreamEvents() 周围衔接重试和组内回退。具体次数、退避及错误分类列入 +Fallback.swift 的后续阅读。'],
   ['B3','确认最终状态','正常返回却缺少 stopReason 的路径会标记异常中断并开放 Resume。达到输出上限、模型拒绝和空回复也有对应分支，分别检查 error 与 canResume。']
  ].map(([n,t,p])=>`<section class="branch-step"><div class="num">${n}</div><div><h3>${t}</h3><p>${p}</p></div></section>`).join('')}<div class="handoff"><strong>需要同时核对的证据</strong>流结束原因、已有文本、自动恢复记录以及最终保存的错误信息。排查原因需要结合运行日志确认。</div>`;
 } else {
  refs=DATA.branches[2].refs;
  body=`<div class="branch-trigger"><strong>进入条件：</strong>用户点击停止，界面调用会话对象的 cancel()。停止时刻决定后续需要清理或保留的状态。</div><p>${esc(DATA.branches[2].text)}</p>${[
   ['C1','传递停止意图','取消会话名额等待、请求停止当前命令，并取消 currentTask。userDidCancel 表示用户停止意图，isProcessing 随即更新。'],
   ['C2','按现有内容完成清理','清理路径区分空占位、已显示文本、工具调用和已提交历史。检查 blocks、agentHistory、committedBlockCount 与 canResume 的对应关系。'],
   ['C3','检查排队消息','promptQueue 中仍有消息时，新任务可以继续处理队列。判断停止后的活动状态时，需要同时观察旧任务取消与新任务启动。']
  ].map(([n,t,p])=>`<section class="branch-step"><div class="num">${n}</div><div><h3>${t}</h3><p>${p}</p></div></section>`).join('')}<div class="handoff"><strong>本分支的观察重点</strong>区分本次生成的停止、已显示内容的保留，以及排队消息是否启动下一次运行。</div>`;
 }
 const subtitle=kind==='tools'?'从第 06 步分流，完成工具执行后回到第 05 步。':'这是执行中的条件分支；阅读后可以返回进入时的主流程步骤。';
 return `${breadcrumb([['发送消息',flowRoute(1)],['第 '+pad(at)+' 步 · '+STEP_SHORT[at-1],stepBack],[BRANCH_TITLES[kind],null]])}${head('02 / 条件分支 '+({tools:'A',failure:'B',stop:'C'}[kind]),BRANCH_TITLES[kind],subtitle)}${timelineHTML(at,kind)}<div class="flow-layout"><article class="card branch-article">${body}${sourceDetails(refs)}<nav class="flow-next" aria-label="分支出口"><a class="previous-link" href="${href(stepBack)}" data-nav>← 返回第 ${pad(at)} 步</a>${kind==='tools'?'<a class="next-link" href="#/flow/05" data-nav><small>执行后的继续路径</small><span>05 准备下一轮模型请求 →</span></a>':`<a class="next-link" href="${href({page:'diagnostics',id:kind==='failure'?'stream':'history'})}" data-nav><small>沿证据排查</small><span>查看相关排查示例 →</span></a>`}</nav></article>${flowSidebar(node,null,`<section class="card flow-side-card"><h2>当前所在位置</h2><p>${kind==='tools'?'工具执行是模型交互中的循环分支。八步主线保留直接回答的阅读顺序。':'分支可能发生在多个执行位置。返回入口保留当前阅读步骤。'}</p></section>`)}</div>${footer()}`;
}
function diagnosticsPage() {
 const index=DIAG_IDS.indexOf(route.id),d=DATA.diagnostics[index];
 const targets=[[1,2,4,5],[6,7],[3,7,8]][index];
 const nodeTargets=[['ui','send','agent'],['stream','loop','providers'],['storage','session','sync']][index];
 return `${breadcrumb([['问题定位',{page:'diagnostics',id:'send'}],[DIAG_SHORT[index],null]])}${head('04 / 从现象回到执行位置','问题定位','先固定同一次会话与运行，再沿相关环节取证。可能原因作为假设，日志、状态与保存结果用于确认。')}<nav class="diagnostic-tabs" aria-label="选择排查现象">${DIAG_IDS.map((id,i)=>`<a class="diagnostic-tab ${id===route.id?'active':''}" href="${href({page:'diagnostics',id})}" data-nav ${id===route.id?'aria-current="page"':''}><span class="num">${pad(i+1)}</span>${DIAG_SHORT[i]}</a>`).join('')}</nav><div class="diag-layout"><article class="card diag-article"><h2>${esc(d.title)}</h2><div class="hypothesis"><strong>候选假设</strong>${esc(d.hypothesis)}</div>${d.checks.map((check,i)=>`<div class="check-row"><div class="num">${pad(i+1)}</div><div>${esc(check)}</div></div>`).join('')}<div class="proof"><strong>如何用证据确认</strong>${esc(d.proof)}</div>${sourceDetails(d.refs,'验证入口与源码')}<p class="micro" style="margin-top:15px">日志与状态来自原有源码分析；回归用例属于后续验证建议。此导览记录静态路径和验证入口。</p></article><aside class="card diag-help"><h3>回到相关流程</h3>${targets.map(k=>`<a href="${href(flowRoute(k))}" data-nav>第 ${pad(k)} 步 · ${STEP_SHORT[k-1]} →</a>`).join('')}<div class="rule"></div><h3>查看相关模块</h3>${nodeTargets.map(id=>`<a href="${href(moduleRoute(id))}" data-nav>${esc(NODES[id].title)} →</a>`).join('')}<div class="rule"></div><p>使用 sessionId、vmInstanceId 和本轮日志标记关联证据，再比较输入、等待点和结果状态。</p></aside></div>${footer()}`;
}
function allSourceRefs() {
 const refs=[...DATA.nodes.flatMap(n=>n.refs),...DATA.steps.flatMap(s=>s.refs),...DATA.branches.flatMap(b=>b.refs),...DATA.diagnostics.flatMap(d=>d.refs),...CAPS.items.flatMap(c=>c.refs),...CAPS.gaps.flatMap(c=>c.refs),...Object.values(DATA.moduleGuides).flatMap(g=>g.refs),...DATA.frameworks.flatMap(f=>f.refs)];
 const map=new Map();
 for(const r of refs) {if(!map.has(r.path))map.set(r.path,[]);const list=map.get(r.path);if(!list.some(x=>x.symbol===r.symbol&&JSON.stringify(x.lines)===JSON.stringify(r.lines)))list.push(r);}
 return [...map.entries()].sort((a,b)=>a[0].localeCompare(b[0]));
}
function sourceIndexHTML() {
 const all=allSourceRefs(), q=sourceQuery.trim().toLowerCase();
 const matches=all.filter(([path,refs])=>[path,...refs.map(r=>r.symbol)].join(' ').toLowerCase().includes(q));
 return `<p class="micro" style="margin-top:10px">${q?'搜索匹配':'索引包含'} ${matches.length} 个文件。每个文件仅表示已用到相关片段，完整核查范围见模块说明。</p><div class="source-grid">${matches.map(([path,refs])=>`<details class="card sources-panel" style="margin:0"><summary><code>${esc(path)}</code><span class="micro"> · ${refs.length} 处</span></summary><div class="sources-body">${refsHTML(refs)}</div></details>`).join('')}</div>`;
}
function sourcesPage() {
 return `${breadcrumb([['参考资料',null],['版本与源码',null]])}${head('参考 / 核查与继续阅读','版本、依据与后续阅读','第三版沿用固定提交，并补充 iSH 执行、原生桥接、系统框架和能力清单。每个条目保留本次实际核查深度。')}<div class="source-columns"><section class="card source-card"><h2>分析基线</h2><dl class="baseline-table"><div><dt>仓库</dt><dd><code>${esc(DATA.meta.repo)}</code></dd></div><div><dt>分支</dt><dd><code>${esc(DATA.meta.branch)}</code></dd></div><div><dt>提交</dt><dd><a href="https://github.com/${DATA.meta.repo}/commit/${DATA.meta.sha}" target="_blank" rel="noopener"><code>${DATA.meta.sha}</code> ↗</a></dd></div><div><dt>原核查日期</dt><dd>${DATA.meta.date}</dd></div><div><dt>当前版次</dt><dd>阅读版 v3 · iSH、原生桥接与能力边界</dd></div></dl><p>${esc(DATA.meta.boundaries)}</p><div class="rule"></div><h2>证据怎样阅读</h2><div class="source-level"><span class="tag verified">相关源码已核实</span><p>原导览读取了对应实现或调用入口。每个模块保留具体路径、符号和核查范围。</p></div><div class="source-level"><span class="tag pending">文档 / 概览定位</span><p>部分节点依据已有文档或协作接口定位，内部实现列入后续阅读。图中相关连接采用虚线。</p></div><div class="source-level"><span class="tag">运行验证待完成</span><p>示例消息用于追踪数据。模型输出、设备行为与真实故障原因需要实际运行验证。</p></div></section><section class="card source-card"><h2>后续阅读顺序</h2>${DATA.roadmap.map(r=>`<div class="roadmap-item"><div class="num">${pad(r[0])}</div><div><h3>${esc(r[1])}</h3><code>${esc(r[2])}</code><p>${esc(r[3])}</p></div></div>`).join('')}</section></div><section class="notice"><strong>图的层级与连线含义</strong>面包屑表达本导览的职责层级；模块详情给出实际源码路径。协作方在关系图中保留连接，进入详情时使用自身上级。实线和虚线区分依据层级，交叉线段只表示线条经过。</section><section class="card source-card section-space"><h2>保留的源码 / 文档差异</h2><p>旧 iSH 概述描述 FIFO 串行执行。固定提交中的 <code>Agent/ISH/ISHExecutionCoordinator.swift</code> 支持同会话与跨会话并发，<code>execute()</code> 登记调用并准备会话 fsContext 后继续执行独立命令。导览采用该执行入口的行为。</p>${sourceDetails([{path:'docs/specs/ios-sandbox-ish-summary.md',symbol:'旧概述第 2.4 节与第 5 节',kind:'项目文档'}, {path:'src/ios/Agent/ISH/ISHExecutionCoordinator.swift',symbol:'当前 execute() 与执行跟踪',lines:[26,136],kind:'源码'}])}</section><section class="card source-index"><div class="heading-row"><h2>源码索引</h2><label class="search source-filter"><span aria-hidden="true">⌕</span><input id="source-search" type="search" value="${esc(sourceQuery)}" aria-label="搜索源码文件或函数" placeholder="按文件名 / 函数查找"></label></div><div id="source-index-list">${sourceIndexHTML()}</div></section><section class="notice"><strong>文件与验证边界</strong>页面内嵌图文、样式和脚本；打开 GitHub 源码链接需要联网。本版保留原有代码分析基线，应用编译、真实请求、手机数据和云同步属于待运行验证范围。生成文件位于本次会话的交付目录，仓库保持原样。网页自身的验证记录见交付包中的 validation.json。</section>${footer()}`;
}
function render() {
 if(route.page==='flow')lastFlow={...route};
 document.getElementById('sidebar').innerHTML=navigationHTML();
 const main=document.getElementById('main');
 main.innerHTML=route.page==='architecture'?overviewPage():route.page==='module'?modulePage():route.page==='flow'?(route.branch?branchPage():flowPage()):route.page==='diagnostics'?diagnosticsPage():route.page==='capabilities'?capabilitiesPage():sourcesPage();
 const name=route.page==='module'?NODES[route.id].title:route.page==='flow'?(route.branch?BRANCH_TITLES[route.branch]:`${pad(route.step)} ${STEPS[route.step-1].title}`):{architecture:'整体架构',diagnostics:'问题定位',capabilities:'原生能力清单',sources:'版本与源码'}[route.page];
 document.title=name+' · MinisX 架构导览 v3';
 main.dataset.page=route.page;
 main.dataset.step=route.page==='flow'&&!route.branch?String(route.step):'';
 main.dataset.module=route.page==='module'?route.id:'';
 lastRenderedHash=serialize(route);
 // Scroll only the timeline container; never move the document as a side effect.
 const timeline=main.querySelector('.timeline-scroll'),current=main.querySelector('.timeline-step.current');
 if(timeline&&current&&timeline.scrollWidth>timeline.clientWidth) {
  const relative=current.getBoundingClientRect().left-timeline.getBoundingClientRect().left;
  timeline.scrollLeft=Math.max(0,relative-(timeline.clientWidth-current.clientWidth)/2);
 }
}
function navigationKey(r) {return pathOf(r)+(r.page==='module'&&r.from?'|'+r.from:'');}
function navigate(next, options={}) {
 const old=serialize(route),target=serialize(next);
 if(old===target) return;
 scrollPositions.set(old,window.scrollY);
 const stay=options.keepScroll??(navigationKey(route)===navigationKey(next));
 const oldScroll=window.scrollY;
 if(next.page==='capabilities'&&next.focus)capQuery='';
 route=next;
 try {history.pushState({atlas:true},'',target);} catch(_) {location.hash=target;}
 render();
 window.scrollTo(0,options.restoreSaved?(scrollPositions.get(target)||0):(stay?oldScroll:0));
 if(!stay)document.getElementById('main').focus({preventScroll:true});
 if(next.page==='capabilities'&&next.focus) requestAnimationFrame(()=>document.getElementById('cap-'+next.focus)?.scrollIntoView({block:'start'}));
}
function restoreNavigation() {
 const next=parseRoute(location.hash),canonical=serialize(next);
 if(canonical===lastRenderedHash)return;
 scrollPositions.set(lastRenderedHash,window.scrollY);
 route=next;render();
 requestAnimationFrame(()=>window.scrollTo(0,scrollPositions.get(canonical)||0));
}
function updateGraphSearch() {
 const scope=scopeOf(route);if(!scope)return;
 const query=queryByPage[pathOf(route)]||'';
 document.getElementById('graph-container').innerHTML=graphSVG(scope,route.selected,query);
 const results=document.getElementById('map-results');
 results.hidden=!query.trim();results.innerHTML=searchResults(scope,query);
}
let toastTimer;
function toast(text) {
 clearTimeout(toastTimer);const el=document.getElementById('toast');el.textContent=text;el.hidden=false;
 toastTimer=setTimeout(()=>{el.hidden=true;},2300);
}
document.addEventListener('click',e=>{
 const nav=e.target.closest('a[data-nav]');
 if(nav) {
  if(e.metaKey||e.ctrlKey||e.shiftKey||e.altKey||e.button!==0)return;
  e.preventDefault();navigate(parseRoute(nav.getAttribute('href')),{restoreSaved:nav.hasAttribute('data-return')});return;
 }
 const clearCaps=e.target.closest('[data-clear-caps]');
 if(clearCaps){capQuery='';const input=document.getElementById('capability-search');if(input)input.value='';document.getElementById('capability-results').innerHTML=capResults();input?.focus();return;}
 const select=e.target.closest('[data-select-node]');
 if(select) {
  const scope=scopeOf(route),id=select.dataset.selectNode;
  if(scope&&SCOPES[scope].nodes.some(n=>n[0]===id)) {
   navigate({...route,selected:id},{keepScroll:true});
   if(e.detail===0)document.querySelector(`#graph-container [data-select-node="${id}"]`)?.focus({preventScroll:true});
  }
  return;
 }
 const scroll=e.target.closest('[data-scroll]');
 if(scroll) {e.preventDefault();document.getElementById(scroll.dataset.scroll)?.scrollIntoView({block:'start'});return;}
 if(e.target.closest('[data-clear-search]')) {
  queryByPage[pathOf(route)]='';const input=document.getElementById('map-search');if(input){input.value='';updateGraphSearch();input.focus();}
 }
});
document.addEventListener('keydown',e=>{
 const node=e.target.closest('svg [data-select-node]');
 if(node&&(e.key==='Enter'||e.key===' ')) {e.preventDefault();node.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
});
document.addEventListener('input',e=>{
 if(e.target.id==='map-search') {queryByPage[pathOf(route)]=e.target.value;updateGraphSearch();}
 if(e.target.id==='capability-search'){capQuery=e.target.value;const results=document.getElementById('capability-results');if(results)results.innerHTML=capResults();}
 if(e.target.id==='source-search') {sourceQuery=e.target.value;document.getElementById('source-index-list').innerHTML=sourceIndexHTML();}
});
window.addEventListener('popstate',restoreNavigation);
window.addEventListener('hashchange',restoreNavigation);
try {history.scrollRestoration='manual';history.replaceState({atlas:true},'',serialize(route));} catch(_) { /* Restricted preview environments keep in-memory navigation. */ }
render();
})();
