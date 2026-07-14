#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json

DATA = json.load(open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\chain_data.json", encoding='utf-8'))
S = DATA['summary']; MAT = DATA['materials']; EDGES = DATA['edges']; BUILD = DATA['buildings']

# ===== Era taxonomy (from scripts/economy/technology_taxonomy.gd) =====
ERAS = [
    ("stone","石器时代"),("bronze","青铜时代"),("classical","古典时代"),("feudal","封建时代"),
    ("exploration","探索时代"),("enlightenment","启蒙时代"),("steam","蒸汽时代"),("electrical","电气时代"),
    ("atomic","原子时代"),("information","信息时代"),("ai","人工智能时代"),
]
ERA_IDX = {e[0]: i for i, e in enumerate(ERAS)}
ERA_TAGS = {  # tech tag -> era id
    "tech.hunting":"stone","tech.gathering":"stone","tech.stone_knapping":"stone","tech.fire_control":"stone",
    "tech.pottery":"bronze","tech.bronze_casting":"bronze",
    "tech.writing":"classical","tech.masonry":"classical",
    "tech.manuscript_culture":"feudal","tech.guild_organization":"feudal",
    "tech.oceanic_navigation":"exploration","tech.printing_press":"exploration",
    "tech.experimental_science":"enlightenment","tech.precision_engineering":"enlightenment",
    "tech.coke_smelting":"steam","tech.steam_power":"steam",
    "tech.electrification":"electrical","tech.radio":"electrical","tech.electrochemistry":"electrical",
    "tech.geological_prospecting":"atomic","tech.advanced_metallurgy":"atomic","tech.nuclear_fission":"atomic",
    "tech.digital_computing":"information","tech.networked_computing":"information","tech.legacy_modern_economy":"information",
    "tech.machine_learning":"ai","tech.autonomous_systems":"ai",
}
def era_of(tech_tags):
    idxs = [ERA_IDX[ERA_TAGS[t]] for t in tech_tags if t in ERA_TAGS]
    return min(idxs) if idxs else 0

# ===== Chain (产业链) taxonomy =====
INDUSTRY_CHAIN = {
    'industry.metals':'金属冶金','industry.energy':'能源','industry.food':'食品',
    'industry.textile':'纺织','industry.chemicals':'化工','industry.machinery':'机械装备',
    'industry.construction':'建筑建材','industry.forestry':'林业造纸',
    'industry.tools':'机械装备','industry.consumer':'文化医药消费',
}
# token -> chain (keyword fallback for nodes without usable industry tag)
TOK = {
 '金属冶金': {'ore','iron','copper','tin','lead','zinc','gold','silver','manganese','bauxite','rare','earth','steel','pig','alloy','bronze','wire','cable','metal','aluminum','alumin','nickel','ingot'},
 '能源': {'coal','coke','oil','crude','gas','fuel','electricity','petro','lubricant','nuclear','refined','steam','power','energy','reactor','isotope','natural'},
 '食品': {'grain','wheat','corn','rice','potato','vegetable','spice','meat','fish','dairy','milk','bread','flour','beverage','food','livestock','horse','fur','hide','game','herb','latex','gather','medicinal','plantation','pasture','arable','paddy','fertile','marine','wild','salt'},
 '纺织': {'fiber','yarn','cloth','textile','clothing','footwear','leather','sailcloth','wool','cotton','flax'},
 '化工': {'chemical','fertilizer','explosive','plastic','soap','detergent','pharma','medicine','reagent','saltpeter','sulfur'},
 '机械装备': {'machinery','engine','machine','tool','instrument','vehicle','equipment','rail','automotive','battery','motor','component','precision','parts'},
 '建筑建材': {'stone','brick','cement','concrete','masonry','construction','cut','dressed','pottery','tile','raw_stone','cut_stone','limestone','clay','sand','glass','lime','silica'},
 '林业造纸': {'timber','log','lumber','wood','pulp','paper','furniture','printed','manuscript','codex','book','parchment','papyrus'},
 '电子电气': {'chip','chips','semiconductor','semiconductors','computer','telecom','radio','appliance','autonomous','scientific','navigation','electronic','electrical','electric','advanced','reactor','isotope','battery','motor','engine','wire','cable'},
 '文化医药消费': {'jewel','consumer','household','culture','medical','communication','codice'},
}
CHAIN_ORDER = ['金属冶金','能源','食品','纺织','化工','机械装备','建筑建材','林业造纸','电子电气','文化医药消费','初级原料','其他']

def kw_chain(gid):
    toks = set(gid.lower().split('_'))
    for ch in ['金属冶金','能源','食品','纺织','化工','机械装备','建筑建材','林业造纸','电子电气','文化医药消费']:
        if toks & TOK[ch]:
            return ch
    return '初级原料'

# resolve chain for each node (resource / good / building)
good_chain = {}
for k, m in MAT.items():
    if m['type'] != 'good':
        continue
    gid = m['id']
    tt = m.get('tech_tags', [])
    ind = [t for t in tt if t.startswith('industry.')]
    if ind and ind[0] != 'industry.primary':
        good_chain[gid] = INDUSTRY_CHAIN.get(ind[0], kw_chain(gid))
    else:
        good_chain[gid] = kw_chain(gid)

node_chain = {}
node_era = {}
for k, m in MAT.items():
    if m['type'] == 'resource':
        gid = m['id']
        node_chain[k] = good_chain.get(gid, kw_chain(gid))
        node_era[k] = era_of(MAT.get(('G', gid), {}).get('tech_tags', [])) if ('G', gid) in MAT else 0
    else:
        gid = m['id']
        node_chain[k] = good_chain.get(gid, '初级原料')
        node_era[k] = era_of(m.get('tech_tags', []))

build_chain = {}
build_era = {}
for b in BUILD:
    tt = b.get('tech_tags', [])
    ind = [t for t in tt if t.startswith('industry.')]
    if ind and ind[0] != 'industry.primary':
        ch = INDUSTRY_CHAIN.get(ind[0], None)
    elif b['outputs']:
        ch = good_chain.get(b['outputs'][0]['good'], None)
    else:
        ch = None
    if not ch:
        ch = kw_chain(b['id'])
    build_chain[b['id']] = ch
    build_era[b['id']] = era_of(tt)

# refine material era from producing/extracting buildings (raw goods often lack tech.* tags)
from collections import defaultdict
good_producers = defaultdict(list); res_extractors = defaultdict(list)
for e in EDGES: good_producers[e['to']].append(e['b'])
for b in BUILD:
    for r in b['resources']: res_extractors['R:'+r['res']].append(b['id'])
for k, m in MAT.items():
    if m['type'] == 'good':
        eras = [build_era[p] for p in good_producers.get(k, []) if p in build_era]
        if eras:
            node_era[k] = min(node_era[k], min(eras)) if node_era[k] else min(eras)
    else:
        ex = [build_era[x] for x in res_extractors.get(k, []) if x in build_era]
        if ex:
            node_era[k] = min(node_era[k], min(ex)) if node_era[k] else min(ex)

# ===== Layout (tiers) =====
tiers = {}
for k, m in MAT.items():
    tiers.setdefault(m['tier'], []).append(k)
for t in tiers:
    tiers[t].sort(key=lambda k: (node_chain[k], MAT[k]['display']))
COL_W = 240; ROW_H = 30; PAD_TOP = 40
pos = {}
for t in range(0, max(tiers)+1):
    nodes = tiers.get(t, [])
    x = 60 + t*COL_W
    for i, k in enumerate(nodes):
        pos[k] = (x, PAD_TOP + i*ROW_H)
build_pos = {}
for b in BUILD:
    ins = [('G', i['good']) for i in b['inputs']] + [('R', r['res']) for r in b['resources']]
    outs = [('G', o['good']) for o in b['outputs']]
    def tk(p, n): return p+':'+n
    in_keys = [tk(p, n) for (p, n) in ins if tk(p, n) in pos]
    out_keys = [tk(p, n) for (p, n) in outs if tk(p, n) in pos]
    xs = [pos[kk][0] for kk in in_keys+out_keys]; ys = [pos[kk][1] for kk in in_keys+out_keys]
    if xs:
        build_pos[b['id']] = ((min(xs)+max(xs))/2, sum(ys)/len(ys), in_keys, out_keys)
    else:
        build_pos[b['id']] = (60 + (max(tiers)+1)*COL_W, 0, in_keys, out_keys)

W = 60 + (max(tiers)+1)*COL_W + 120
H = PAD_TOP + max((len(tiers[t]) for t in tiers), default=1)*ROW_H + 60

# attach chain/era to data
mat_out = {}
for k, m in MAT.items():
    mm = dict(m); mm['chain'] = node_chain[k]; mm['era'] = node_era[k]
    mat_out[k] = mm
build_out = []
for b in BUILD:
    bb = dict(b); bb['chain'] = build_chain[b['id']]; bb['era'] = build_era[b['id']]
    build_out.append(bb)

# ===== HTML =====
CAT_COLORS = {
    'primary':'#8d6e63','raw_materials':'#a1887f','metals':'#607d8b','forestry':'#558b2f',
    'food':'#ef6c00','textile':'#ad1457','textiles':'#c2185b','chemicals':'#7e57c2',
    'energy':'#fbc02d','machinery':'#1565c0','tools':'#00838f','construction':'#6d4c41',
    'electrical':'#3949ab','electronics':'#1e88e5','communication':'#039be5','instruments':'#00897b',
    'medical':'#26a69a','nuclear':'#5e35b1','paper':'#9e9d24','culture':'#8e24aa',
    'household_goods':'#d81b60','consumer':'#e53935','transport_equipment':'#43a047',
}
def cat_color(c): return CAT_COLORS.get(c, '#90a4ae')

jsdata = {'materials': mat_out, 'edges': EDGES, 'buildings': build_out,
          'pos': pos, 'build_pos': build_pos, 'cat_colors': CAT_COLORS,
          'max_tier': max(tiers), 'eras': ERAS, 'chains': CHAIN_ORDER}
html = []
html.append('<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">')
html.append('<title>Project.Keynes 产业链结构图（可查询）</title>')
html.append('<style>')
html.append('''
* { box-sizing: border-box; }
body { margin:0; font-family:"Segoe UI","Microsoft YaHei",sans-serif; background:#0f1419; color:#e6edf3; overflow:hidden; }
#app { display:flex; height:100vh; }
#sidebar { width:280px; min-width:280px; background:#161b22; border-right:1px solid #30363d; display:flex; flex-direction:column; }
#sidebar h1 { font-size:14px; margin:0; padding:12px 14px 6px; color:#58a6ff; }
#stats { font-size:11px; color:#8b949e; padding:0 14px 8px; line-height:1.6; border-bottom:1px solid #30363d; }
#toolbar { padding:10px 14px; border-bottom:1px solid #30363d; }
#toolbar label { display:block; font-size:12px; color:#c9d1d9; margin:8px 0 3px; }
#toolbar select, #toolbar button { width:100%; padding:6px 8px; background:#0d1117; border:1px solid #30363d; color:#e6edf3; border-radius:5px; font-size:12px; }
.row { display:flex; gap:6px; }
.row > * { flex:1; }
#count { font-size:12px; color:#8b949e; padding:8px 14px; border-top:1px solid #30363d; border-bottom:1px solid #30363d; }
#count b { color:#58a6ff; }
#legend { padding:8px 14px; overflow-y:auto; flex:1; font-size:12px; }
.legrow { display:flex; align-items:center; gap:6px; padding:2px 0; }
.swatch { width:12px; height:12px; border-radius:3px; flex:none; }
#canvasWrap { flex:1; position:relative; overflow:hidden; background:#0d1117; }
svg { width:100%; height:100%; display:block; cursor:grab; }
svg.grabbing { cursor:grabbing; }
.node rect, .node text { cursor:pointer; }
.tooltip { position:fixed; pointer-events:none; background:#1c2128; border:1px solid #58a6ff; border-radius:6px; padding:8px 10px; font-size:12px; color:#e6edf3; max-width:340px; display:none; z-index:50; box-shadow:0 4px 16px rgba(0,0,0,.5); }
.tooltip b { color:#58a6ff; }
.edge { stroke:#3a4452; stroke-width:1; fill:none; }
.edge.hot { stroke:#58a6ff; stroke-width:2; }
.node.hot rect { stroke:#58a6ff; stroke-width:2.5; }
.dim { display:none !important; }
button { background:#21262d; color:#c9d1d9; border:1px solid #30363d; border-radius:5px; padding:6px 9px; font-size:12px; cursor:pointer; }
button:hover { background:#30363d; }
.ghost { color:#8b949e; font-size:11px; padding:3px 0; }
.resrect { fill:#3d2c1e; stroke:#b5793a; }
.bld { fill:#11324a; stroke:#58a6ff; }
#hint { position:absolute; left:12px; bottom:10px; font-size:11px; color:#586069; }
#search { width:100%; padding:6px 8px; background:#0d1117; border:1px solid #30363d; color:#e6edf3; border-radius:4px; margin-top:8px; }
''')
html.append('</style></head><body><div id="app">')
html.append('<div id="sidebar">')
html.append('<h1>产业链结构图 · 可查询</h1>')
html.append('<div id="stats">')
html.append(f"自然资源 <b>{S['n_resources_used']}</b> · 物资 <b>{S['n_goods_used']}</b> · 建筑 <b>{S['n_buildings']}</b><br>生产链路 <b>{S['n_edges']}</b> · 时代 11 个 · 产业链 {len(CHAIN_ORDER)} 类")
html.append('</div>')
html.append('<div id="toolbar">')
html.append('<label>① 按产业链查询</label><select id="selChain"></select>')
html.append('<label>② 按时代查询（累计至该时代）</label><select id="selEra"></select>')
html.append('<div class="row" style="margin-top:8px"><button id="btnReset">重置筛选</button><button id="btnFit">适配视图</button><button id="btnBld">建筑图层</button></div>')
html.append('<input id="search" placeholder="搜索节点/建筑…">')
html.append('<div class="ghost">拖拽平移 · 滚轮缩放 · 悬停看配方 · 点击高亮上下游</div>')
html.append('</div>')
html.append('<div id="count"></div>')
html.append('<div id="legend"></div>')
html.append('</div>')
html.append('<div id="canvasWrap"><svg id="svg"><g id="viewport"></g></svg>')
html.append('<div id="hint">Tier 0 = 自然资源 → Tier '+str(max(tiers))+' = 终端产品</div>')
html.append('</div></div>')

html.append('<script>const DATA = '+json.dumps(jsdata, ensure_ascii=False)+';</script>')
html.append('''
<script>
const SVGNS="http://www.w3.org/2000/svg";
const svg=document.getElementById('svg'); const vp=document.getElementById('viewport');
const NODE_W=150, NODE_H=22, BW=96, BH=18;
const mat=DATA.materials, edges=DATA.edges, builds=DATA.buildings;
const pos=DATA.pos, bpos=DATA.build_pos, colors=DATA.cat_colors;
const buildById={}; builds.forEach(b=>buildById[b.id]=b);
const byKey={}; Object.keys(mat).forEach(k=>byKey[k]=mat[k]);

const edgeLayer=document.createElementNS(SVGNS,'g');
const nodeLayer=document.createElementNS(SVGNS,'g');
const bldLayer=document.createElementNS(SVGNS,'g');
vp.appendChild(edgeLayer); vp.appendChild(nodeLayer); vp.appendChild(bldLayer);
function el(t,a){const e=document.createElementNS(SVGNS,t);for(const k in a)e.setAttribute(k,a[k]);return e;}

const edgeEls=[];
edges.forEach(e=>{
  const a=pos[e.from], b=pos[e.to]; if(!a||!b)return;
  const x1=a[0]+NODE_W,y1=a[1]+NODE_H/2,x2=b[0],y2=b[1]+NODE_H/2,mx=(x1+x2)/2;
  const p=el('path',{d:`M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`,class:'edge'});
  p._e=e; p.addEventListener('mouseover',ev=>showTip(ev,edgeTip(e)));
  p.addEventListener('mousemove',moveTip); p.addEventListener('mouseout',hideTip);
  edgeLayer.appendChild(p); edgeEls.push(p);
});
const nodeEls={};
Object.keys(mat).forEach(k=>{
  const m=mat[k],[x,y]=pos[k]; const g=el('g',{class:'node'}); g._k=k;
  g.dataset.chain=m.chain; g.dataset.era=m.era;
  const isRes=m.type==='resource';
  const rect=el('rect',{x,y,width:NODE_W,height:NODE_H,rx:5,
     class:isRes?'resrect':'', fill:isRes?'#3d2c1e':(colors[m.category]||'#90a4ae')});
  if(!isRes)rect.setAttribute('stroke','#0d1117');
  const t=el('text',{x:x+NODE_W/2,y:y+NODE_H/2+4,'text-anchor':'middle','font-size':11,fill:'#fff'});
  t.textContent=m.display; g.appendChild(rect); g.appendChild(t);
  g.addEventListener('mouseover',ev=>showTip(ev,nodeTip(k)));
  g.addEventListener('mousemove',moveTip); g.addEventListener('mouseout',hideTip);
  g.addEventListener('click',()=>focusChain(k));
  nodeLayer.appendChild(g); nodeEls[k]=g;
});
const bldEls={};
builds.forEach(b=>{const p=bpos[b.id];if(!p)return;const[x,y]=p;
  const g=el('g',{class:'node bldnode',style:'display:none'}); g._b=b.id;
  g.dataset.chain=b.chain; g.dataset.era=b.era;
  const rect=el('rect',{x:x-BW/2,y:y-BH/2,width:BW,height:BH,rx:4,class:'bld'});
  const t=el('text',{x:x,y:y+4,'text-anchor':'middle','font-size':9,fill:'#bfe0ff'});
  t.textContent=b.display.length>9?b.display.slice(0,8)+'…':b.display;
  g.appendChild(rect); g.appendChild(t);
  g.addEventListener('mouseover',ev=>showTip(ev,buildTip(b)));
  g.addEventListener('mousemove',moveTip); g.addEventListener('mouseout',hideTip);
  g.addEventListener('click',()=>focusBuild(b.id));
  bldLayer.appendChild(g); bldEls[b.id]=g;
});
let bldEdgeLayer=null;
function drawBldEdges(){ if(bldEdgeLayer)return; bldEdgeLayer=el('g',{}); bldLayer.appendChild(bldEdgeLayer);
  builds.forEach(b=>{const p=bpos[b.id];if(!p)return;const[x,y]=p;
    p[2].forEach(ik=>{const a=pos[ik];if(!a)return;bldEdgeLayer.appendChild(el('path',{d:`M${a[0]+NODE_W},${a[1]+NODE_H/2} L${x-BW/2},${y}`,class:'edge'}));});
    p[3].forEach(ok=>{const c=pos[ok];if(!c)return;bldEdgeLayer.appendChild(el('path',{d:`M${x+BW/2},${y} L${c[0]},${c[1]+NODE_H/2}`,class:'edge'}));});
  });
}
let bldOn=false;
document.getElementById('btnBld').onclick=function(){bldOn=!bldOn;this.textContent=bldOn?'隐藏建筑':'建筑图层';
  Object.values(bldEls).forEach(g=>{g.style.display=bldOn?'':'none';});
  if(bldOn)drawBldEdges(); applyFilter(false);};
// pan/zoom
let tx=0,ty=0,scale=1,drag=false,sx=0,sy=0;
function applyT(){vp.setAttribute('transform',`translate(${tx},${ty}) scale(${scale})`);}
svg.addEventListener('mousedown',e=>{if(e.target===svg||e.target===vp){drag=true;svg.classList.add('grabbing');sx=e.clientX-tx;sy=e.clientY-ty;}});
window.addEventListener('mouseup',()=>{drag=false;svg.classList.remove('grabbing');});
window.addEventListener('mousemove',e=>{if(drag){tx=e.clientX-sx;ty=e.clientY-sy;applyT();}});
svg.addEventListener('wheel',e=>{e.preventDefault();const f=e.deltaY<0?1.1:0.9;
  const r=svg.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top;
  tx=mx-(mx-tx)*f;ty=my-(my-ty)*f;scale*=f;applyT();},{passive:false});

// tooltips
const tip=document.createElement('div');tip.className='tooltip';document.body.appendChild(tip);
function showTip(ev,h){tip.innerHTML=h;tip.style.display='block';moveTip(ev);}
function moveTip(ev){tip.style.left=(ev.clientX+14)+'px';tip.style.top=(ev.clientY+14)+'px';}
function hideTip(){tip.style.display='none';}
function nodeTip(k){const m=mat[k];let s=`<b>${m.display}</b> <span style="color:#8b949e">(${k})</span><br>`;
  s+=`产业链：<b style="color:#7ee787">${m.chain}</b> · 时代：<b style="color:#d2a8ff">${DATA.eras[m.era][1]}</b><br>`;
  if(m.type==='resource')s+='类型：自然资源（地图生成沉积）<br>';
  else s+=`类别：${m.category||'-'} · 基准价：${m.price||'-'}<br>`;
  s+=`层级：Tier ${m.tier}<br><br><b>由以下建筑产出：</b><br>`;
  edges.filter(e=>e.to===k).forEach(e=>{s+=`· ${e.bd}<br>`;});
  if(m.type==='good'){s+='<br><b>作为原料供：</b><br>';edges.filter(e=>e.from===k).forEach(e=>{s+=`· ${e.bd} → ${byKey[e.to]?byKey[e.to].display:e.to}<br>`;});}
  return s;}
function edgeTip(e){let s=`<b>${buildById[e.b]?buildById[e.b].display:e.b}</b><br>`;
  s+=`原料：${byKey[e.from]?byKey[e.from].display:e.from}`; if(e.qty_in)s+=` ×${e.qty_in}`;
  s+=`<br>产出：${byKey[e.to]?byKey[e.to].display:e.to}`; if(e.qty_out)s+=` ×${e.qty_out}`; return s;}
function buildTip(b){let s=`<b>${b.display}</b> <span style="color:#8b949e">(${b.id})</span><br>类型：${b.kind||'-'} · 产业链：<b style="color:#7ee787">${b.chain}</b> · 时代：${DATA.eras[b.era][1]}<br>`;
  if(b.resources.length)s+='<br><b>提取资源：</b><br>'+b.resources.map(r=>`· ${r.res} ×${r.qty}`).join('<br>');
  if(b.inputs.length)s+='<br><b>消耗物资：</b><br>'+b.inputs.map(i=>`· ${i.good} ×${i.qty}`).join('<br>');
  if(b.outputs.length)s+='<br><b>产出物资：</b><br>'+b.outputs.map(o=>`· ${o.good} ×${o.qty}`).join('<br>');
  return s;}

// highlight chain
function clearHot(){document.querySelectorAll('.hot').forEach(e=>e.classList.remove('hot'));}
function focusChain(k){clearHot();const up=new Set(),down=new Set();
  (function wu(x){up.add(x);edges.filter(e=>e.to===x).forEach(e=>{if(!up.has(e.from))wu(e.from);});})(k);
  (function wd(x){down.add(x);edges.filter(e=>e.from===x).forEach(e=>{if(!down.has(e.to))wd(e.to);});})(k);
  const keep=new Set([...up,...down]);
  keep.forEach(kk=>{if(nodeEls[kk])nodeEls[kk].classList.add('hot');});
  edgeEls.forEach(p=>{if(keep.has(p._e.from)&&keep.has(p._e.to))p.classList.add('hot');});
  applyFilter(true);}
function focusBuild(bid){clearHot();const b=buildById[bid];if(!b)return;const keep=new Set();
  b.resources.forEach(r=>keep.add('R:'+r.res));b.inputs.forEach(i=>keep.add('G:'+i.good));b.outputs.forEach(o=>keep.add('G:'+o.good));
  keep.forEach(kk=>{if(nodeEls[kk])nodeEls[kk].classList.add('hot');});
  if(bldEls[bid])bldEls[bid].classList.add('hot');
  edgeEls.forEach(p=>{if(keep.has(p._e.from)&&keep.has(p._e.to))p.classList.add('hot');});
  applyFilter(true);}

// ===== filters =====
const selChain=document.getElementById('selChain'), selEra=document.getElementById('selEra');
DATA.chains.forEach(c=>{const o=document.createElement('option');o.value=c;o.textContent=c;selChain.appendChild(o);});
selChain.insertBefore(new Option('全部产业链','__all'),selChain.firstChild);
DATA.eras.forEach(([id,name])=>{const o=document.createElement('option');o.value=id;o.textContent=name;selEra.appendChild(o);});
selEra.insertBefore(new Option('全部时代','__all'),selEra.firstChild);

function applyFilter(keepHot){
  const ch=selChain.value, ea=selEra.value;
  const ERA_IDX={}; DATA.eras.forEach(([id],i)=>{ERA_IDX[id]=i;});
  const eaIdx = ea==='__all'?999:ERA_IDX[ea];
  // also respect search
  const q=(document.getElementById('search').value||'').trim().toLowerCase();
  function visNode(k,m){
    if(ch!=='__all' && m.chain!==ch) return false;
    if(eaIdx<999 && m.era>eaIdx) return false;
    if(q){ const hit=m.display.toLowerCase().includes(q)||k.toLowerCase().includes(q); if(!hit) return false; }
    return true;
  }
  let nv=0;
  Object.keys(mat).forEach(k=>{const m=mat[k];const v=visNode(k,m);nodeEls[k].classList.toggle('dim',!v);if(v)nv++;});
  edgeEls.forEach(p=>{const f=pos[p._e.from],t=pos[p._e.to];
    const fv=!nodeEls[p._e.from].classList.contains('dim'), tv=!nodeEls[p._e.to].classList.contains('dim');
    p.classList.toggle('dim',!(fv&&tv));});
  // buildings
  let bv=0;
  builds.forEach(b=>{ if(!bldOn){ if(bldEls[b.id])bldEls[b.id].style.display='none'; return; }
    const v=visNode('B:'+b.id,b); if(bldEls[b.id]){bldEls[b.id].style.display='';bldEls[b.id].classList.toggle('dim',!v);} if(v)bv++; });
  // count
  let desc=[];
  if(ch!=='__all')desc.push('产业链：'+ch);
  if(ea!=='__all')desc.push('时代：'+DATA.eras[eaIdx][1]+(eaIdx<10?'（及以前）':''));
  if(q)desc.push('搜索：'+q);
  const cnt=document.getElementById('count');
  cnt.innerHTML=`显示 <b>${nv}</b> 物资/资源`+(bldOn?` · <b>${bv}</b> 建筑`:'')+(desc.length?(' · '+desc.join(' · ')):'');
  if(!keepHot) clearHot();
  fitToVisible();
}
function fitToVisible(){
  const vis=Object.keys(mat).filter(k=>!nodeEls[k].classList.contains('dim')).map(k=>pos[k]);
  if(!vis.length)return;
  const xs=vis.map(p=>p[0]),ys=vis.map(p=>p[1]);
  const minX=Math.min(...xs)-10,minY=Math.min(...ys)-10,maxX=Math.max(...xs)+NODE_W+10,maxY=Math.max(...ys)+NODE_H+10;
  const cw=svg.clientWidth,ch=svg.clientHeight;
  const s=Math.min(cw/(maxX-minX),ch/(maxY-minY),1.6);
  scale=s;
  tx=(cw-(maxX-minX)*s)/2 - minX*s;
  ty=(ch-(maxY-minY)*s)/2 - minY*s;
  applyT();
}
selChain.onchange=()=>applyFilter(false);
selEra.onchange=()=>applyFilter(false);
document.getElementById('btnReset').onclick=()=>{selChain.value='__all';selEra.value='__all';document.getElementById('search').value='';clearHot();applyFilter(false);};
document.getElementById('btnFit').onclick=fitToVisible;
document.getElementById('search').addEventListener('input',()=>applyFilter(false));

// legend (chains)
const legend=document.getElementById('legend');
legend.innerHTML='<div style="color:#8b949e;margin-bottom:4px">产业链图例</div>';
DATA.chains.forEach(c=>{const n=Object.values(mat).filter(m=>m.chain===c).length;
  const row=document.createElement('div');row.className='legrow';
  const sw=document.createElement('span');sw.className='swatch';sw.style.background=chainColor(c);
  const lab=document.createElement('span');lab.textContent=`${c} (${n})`;
  row.appendChild(sw);row.appendChild(lab);
  row.style.cursor='pointer';row.onclick=()=>{selChain.value=c;applyFilter(false);};
  legend.appendChild(row);
});
function chainColor(c){const map={'金属冶金':'#607d8b','能源':'#fbc02d','食品':'#ef6c00','纺织':'#ad1457','化工':'#7e57c2','机械装备':'#1565c0','建筑建材':'#6d4c41','林业造纸':'#558b2f','电子电气':'#1e88e5','文化医药消费':'#d81b60','初级原料':'#8d6e63','其他':'#90a4ae'};return map[c]||'#90a4ae';}

applyT(); applyFilter(false);
</script>
''')
html.append('</body></html>')
out=r"D:\Godot\ProjectKeynes\Project.Keynes\docs\industrial_chain.html"
open(out,'w',encoding='utf-8').write('\n'.join(html))
print("WROTE",out,"nodes",len(MAT),"buildings",len(BUILD),"max_tier",max(tiers))
# chain distribution
from collections import Counter
cc=Counter(node_chain.values()); bc=Counter(build_chain.values())
print("chain(goods+res):",dict(cc))
print("chain(buildings):",dict(bc))
print("era(goods+res):",Counter(node_era.values()))
print("era(buildings):",Counter(build_era.values()))
