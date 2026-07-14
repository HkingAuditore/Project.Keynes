#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json

DATA = json.load(open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\chain_data.json", encoding='utf-8'))

# ---- category palette ----
CAT_COLORS = {
    'primary':'#8d6e63','raw_materials':'#a1887f','metals':'#607d8b','forestry':'#558b2f',
    'food':'#ef6c00','textile':'#ad1457','textiles':'#c2185b','chemicals':'#7e57c2',
    'energy':'#fbc02d','machinery':'#1565c0','tools':'#00838f','construction':'#6d4c41',
    'electrical':'#3949ab','electronics':'#1e88e5','communication':'#039be5','instruments':'#00897b',
    'medical':'#26a69a','nuclear':'#5e35b1','paper':'#9e9d24','culture':'#8e24aa',
    'household_goods':'#d81b60','consumer':'#e53935','transport_equipment':'#43a047',
}
def cat_color(c):
    return CAT_COLORS.get(c, '#90a4ae')

S = DATA['summary']
MAT = DATA['materials']
EDGES = DATA['edges']
BUILD = DATA['buildings']

# ---- layout: tiers ----
tiers = {}
for k,m in MAT.items():
    tiers.setdefault(m['tier'], []).append(k)
# sort tiers ascending
max_tier = max(tiers) if tiers else 0

# order nodes within a tier by category then display for stable layout
def sort_key(k):
    m = MAT[k]
    return (m.get('category','') if m['type']=='good' else '__res', m['display'])
for t in tiers:
    tiers[t].sort(key=sort_key)

COL_W = 240
ROW_H = 30
PAD_TOP = 40
# assign positions
pos = {}
tier_height = {}
for t in range(0, max_tier+1):
    nodes = tiers.get(t, [])
    tier_height[t] = max(len(nodes)*ROW_H, ROW_H)
    x = 60 + t*COL_W
    for i,k in enumerate(nodes):
        y = PAD_TOP + i*ROW_H
        pos[k] = (x, y)

# building overlay positions
build_pos = {}
for b in BUILD:
    ins = [('G',i['good']) for i in b['inputs']] + [('R',r['res']) for r in b['resources']]
    outs = [('G',o['good']) for o in b['outputs']]
    def tk(prefix, name): return prefix+':'+name
    in_keys = [tk(p,n) for (p,n) in ins if tk(p,n) in pos]
    out_keys = [tk(p,n) for (p,n) in outs if tk(p,n) in pos]
    xs=[]; ys=[]
    for kk in in_keys+out_keys:
        xs.append(pos[kk][0]); ys.append(pos[kk][1])
    if xs:
        bx = (min(xs)+max(xs))/2
        by = sum(ys)/len(ys)
    else:
        bx = 60 + (max_tier+1)*COL_W; by = 0
    build_pos[b['id']] = (bx, by, in_keys, out_keys)

W = 60 + (max_tier+1)*COL_W + 120
H = PAD_TOP + max(tier_height.values()) + 60

# ---- build HTML ----
html = []
html.append('<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">')
html.append('<title>Project.Keynes 产业链结构图</title>')
html.append('<style>')
html.append('''
* { box-sizing: border-box; }
body { margin:0; font-family: "Segoe UI","Microsoft YaHei",sans-serif; background:#0f1419; color:#e6edf3; overflow:hidden; }
#app { display:flex; height:100vh; }
#sidebar { width:300px; min-width:300px; background:#161b22; border-right:1px solid #30363d; display:flex; flex-direction:column; }
#sidebar h1 { font-size:15px; margin:0; padding:14px 14px 8px; color:#58a6ff; }
#stats { font-size:11px; color:#8b949e; padding:0 14px 10px; line-height:1.6; border-bottom:1px solid #30363d; }
#controls { padding:10px 14px; border-bottom:1px solid #30363d; font-size:12px; }
#controls label { display:block; margin:6px 0 2px; color:#c9d1d9; }
#search { width:100%; padding:6px 8px; background:#0d1117; border:1px solid #30363d; color:#e6edf3; border-radius:4px; }
#legend { padding:8px 14px; overflow-y:auto; flex:1; }
.legrow { display:flex; align-items:center; gap:6px; padding:3px 0; font-size:12px; cursor:pointer; user-select:none; }
.legrow.off { opacity:0.35; }
.swatch { width:14px; height:14px; border-radius:3px; flex:none; }
#canvasWrap { flex:1; position:relative; overflow:hidden; background:#0d1117; }
svg { width:100%; height:100%; display:block; cursor:grab; }
svg.grabbing { cursor:grabbing; }
.node rect, .node text { cursor:pointer; }
.tooltip { position:fixed; pointer-events:none; background:#1c2128; border:1px solid #58a6ff; border-radius:6px; padding:8px 10px; font-size:12px; color:#e6edf3; max-width:320px; display:none; z-index:50; box-shadow:0 4px 16px rgba(0,0,0,.5); }
.tooltip b { color:#58a6ff; }
.edge { stroke:#3a4452; stroke-width:1; fill:none; }
.edge.hot { stroke:#58a6ff; stroke-width:2; }
.node.hot rect { stroke:#58a6ff; stroke-width:2.5; }
.dim { opacity:0.12 !important; }
.btnrow { display:flex; gap:6px; margin-top:8px; }
button { background:#21262d; color:#c9d1d9; border:1px solid #30363d; border-radius:5px; padding:5px 9px; font-size:12px; cursor:pointer; }
button:hover { background:#30363d; }
.ghost { color:#8b949e; font-size:11px; padding:2px 0; }
.resrect { fill:#3d2c1e; stroke:#b5793a; }
.bld { fill:#11324a; stroke:#58a6ff; }
#hint { position:absolute; left:12px; bottom:10px; font-size:11px; color:#586069; }
''')
html.append('</style></head><body>')
html.append('<div id="app">')
# sidebar
html.append('<div id="sidebar">')
html.append('<h1>Project.Keynes · 产业链结构图</h1>')
html.append('<div id="stats">')
html.append(f"自然资源 <b>{S['n_resources_used']}</b> · 物资 <b>{S['n_goods_used']}</b> · 建筑 <b>{S['n_buildings']}</b><br>")
html.append(f"生产链路 <b>{S['n_edges']}</b> · 层级深度 <b>{max_tier}</b> · 类别 <b>{len(S['category_counts'])}</b>")
html.append('</div>')
html.append('<div id="controls">')
html.append('<label>搜索节点 / 建筑（高亮其上下游）</label>')
html.append('<input id="search" placeholder="如 steel / 钢铁 / 建筑名">')
html.append('<div class="btnrow">')
html.append('<button id="btnBuild">显示建筑节点</button>')
html.append('<button id="btnZoomIn">放大</button><button id="btnZoomOut">缩小</button><button id="btnReset">复位</button>')
html.append('</div>')
html.append('<div class="ghost">拖拽平移 · 滚轮缩放 · 悬停看配方 · 点击高亮产业链</div>')
html.append('</div>')
html.append('<div id="legend"></div>')
html.append('</div>')  # sidebar
# canvas
html.append('<div id="canvasWrap"><svg id="svg"><g id="viewport"></g></svg>')
html.append('<div id="hint">Tier 0 = 自然资源 → Tier '+str(max_tier)+' = 终端产品</div>')
html.append('</div>')
html.append('</div>')  # app

# data for JS
jsdata = {
    'materials': MAT, 'edges': EDGES, 'buildings': BUILD,
    'pos': pos, 'build_pos': build_pos, 'cat_colors': CAT_COLORS,
    'max_tier': max_tier,
}
html.append('<script>const DATA = '+json.dumps(jsdata, ensure_ascii=False)+';</script>')
html.append('''
<script>
const SVGNS="http://www.w3.org/2000/svg";
const svg=document.getElementById('svg');
const vp=document.getElementById('viewport');
const NODE_W=150, NODE_H=22, BW=96, BH=18;

// build lookups
const mat=DATA.materials, edges=DATA.edges, builds=DATA.buildings;
const pos=DATA.pos, bpos=DATA.build_pos, colors=DATA.cat_colors;
const byId={}; mat && Object.keys(mat).forEach(k=>byId[k]=mat[k]);
const buildById={}; builds.forEach(b=>buildById[b.id]=b);

// ----- draw edges -----
const edgeLayer=document.createElementNS(SVGNS,'g');
const nodeLayer=document.createElementNS(SVGNS,'g');
const bldLayer=document.createElementNS(SVGNS,'g');
vp.appendChild(edgeLayer); vp.appendChild(nodeLayer); vp.appendChild(bldLayer);

function el(tag,attrs){const e=document.createElementNS(SVGNS,tag);for(const k in attrs)e.setAttribute(k,attrs[k]);return e;}

const edgeEls=[];
edges.forEach(e=>{
  const a=pos[e.from], b=pos[e.to];
  if(!a||!b) return;
  const x1=a[0]+NODE_W, y1=a[1]+NODE_H/2, x2=b[0], y2=b[1]+NODE_H/2;
  const mx=(x1+x2)/2;
  const p=el('path',{d:`M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`,class:'edge'});
  p._e=e;
  p.addEventListener('mouseover',ev=>showTip(ev,edgeTip(e)));
  p.addEventListener('mousemove',moveTip);
  p.addEventListener('mouseout',hideTip);
  edgeLayer.appendChild(p); edgeEls.push(p);
});

// ----- draw material nodes -----
const nodeEls={};
Object.keys(mat).forEach(k=>{
  const m=mat[k]; const [x,y]=pos[k];
  const g=el('g',{class:'node'}); g._k=k;
  const isRes=m.type==='resource';
  const rect=el('rect',{x:x,y:y,width:NODE_W,height:NODE_H,rx:5,
     class:isRes?'resrect':'', fill:isRes?'#3d2c1e':(colors[m.category]||'#90a4ae')});
  if(!isRes) rect.setAttribute('stroke','#0d1117');
  const t=el('text',{x:x+NODE_W/2,y:y+NODE_H/2+4,'text-anchor':'middle','font-size':11,fill:'#fff'});
  t.textContent=m.display;
  g.appendChild(rect); g.appendChild(t);
  g.addEventListener('mouseover',ev=>showTip(ev,nodeTip(k)));
  g.addEventListener('mousemove',moveTip);
  g.addEventListener('mouseout',hideTip);
  g.addEventListener('click',()=>focusChain(k));
  nodeLayer.appendChild(g); nodeEls[k]=g;
});

// ----- building nodes (hidden initially) -----
const bldEls={};
builds.forEach(b=>{
  const p=bpos[b.id]; if(!p) return;
  const [x,y]=p;
  const g=el('g',{class:'node bldnode',style:'display:none'});
  const rect=el('rect',{x:x-BW/2,y:y-BH/2,width:BW,height:BH,rx:4,class:'bld'});
  const t=el('text',{x:x,y:y+4,'text-anchor':'middle','font-size':9,fill:'#bfe0ff'});
  t.textContent=b.display.length>9?b.display.slice(0,8)+'…':b.display;
  g.appendChild(rect); g.appendChild(t);
  g.addEventListener('mouseover',ev=>showTip(ev,buildTip(b)));
  g.addEventListener('mousemove',moveTip);
  g.addEventListener('mouseout',hideTip);
  g.addEventListener('click',()=>focusBuild(b.id));
  bldLayer.appendChild(g); bldEls[b.id]=g;
});

// ----- pan / zoom -----
let tx=0,ty=0,scale=1;
function applyT(){vp.setAttribute('transform',`translate(${tx},${ty}) scale(${scale})`);}
svg.addEventListener('mousedown',e=>{if(e.target===svg||e.target===vp){drag=true;svg.classList.add('grabbing');sx=e.clientX-tx;sy=e.clientY-ty;}});
let drag=false,sx=0,sy=0;
window.addEventListener('mouseup',()=>{drag=false;svg.classList.remove('grabbing');});
window.addEventListener('mousemove',e=>{if(drag){tx=e.clientX-sx;ty=e.clientY-sy;applyT();}});
svg.addEventListener('wheel',e=>{e.preventDefault();const f=e.deltaY<0?1.1:0.9;
  const r=svg.getBoundingClientRect();const mx=e.clientX-r.left,my=e.clientY-r.top;
  tx=mx-(mx-tx)*f; ty=my-(my-ty)*f; scale*=f; applyT();},{passive:false});

document.getElementById('btnZoomIn').onclick=()=>{scale*=1.2;applyT();};
document.getElementById('btnZoomOut').onclick=()=>{scale*=0.83;applyT();};
document.getElementById('btnReset').onclick=()=>{tx=0;ty=0;scale=1;applyT();clearFocus();};
let bldOn=false;
document.getElementById('btnBuild').onclick=function(){bldOn=!bldOn;this.textContent=bldOn?'隐藏建筑节点':'显示建筑节点';
  Object.values(bldEls).forEach(g=>g.style.display=bldOn?'':'none');
  if(bldOn&&bpos) drawBldEdges();
};
let bldEdgeLayer=null;
function drawBldEdges(){
  if(bldEdgeLayer) return;
  bldEdgeLayer=el('g',{}); bldLayer.appendChild(bldEdgeLayer);
  builds.forEach(b=>{const p=bpos[b.id]; if(!p)return; const [x,y]=p;
    p[2].forEach(ik=>{const a=pos[ik];if(!a)return;const pa=el('path',{d:`M${a[0]+NODE_W},${a[1]+NODE_H/2} L${x-BW/2},${y}`,class:'edge'});bldEdgeLayer.appendChild(pa);});
    p[3].forEach(ok=>{const c=pos[ok];if(!c)return;const pa=el('path',{d:`M${x+BW/2},${y} L${c[0]},${c[1]+NODE_H/2}`,class:'edge'});bldEdgeLayer.appendChild(pa);});
  });
}

// ----- tooltips -----
const tip=document.createElement('div');tip.className='tooltip';document.body.appendChild(tip);
function showTip(ev,html){tip.innerHTML=html;tip.style.display='block';moveTip(ev);}
function moveTip(ev){tip.style.left=(ev.clientX+14)+'px';tip.style.top=(ev.clientY+14)+'px';}
function hideTip(){tip.style.display='none';}
function nodeTip(k){const m=mat[k];let s=`<b>${m.display}</b> <span style="color:#8b949e">(${k})</span><br>`;
  if(m.type==='resource'){s+='类型：自然资源（地图生成沉积）<br>';}
  else{s+=`类别：${m.category||'-'} · 基准价：${m.price||'-'}<br>`;}
  s+=`层级：Tier ${m.tier}<br><br><b>由以下建筑产出：</b><br>`;
  edges.filter(e=>e.to===k).forEach(e=>{s+=`· ${e.bd} <span style="color:#8b949e">(${e.b})</span><br>`;});
  if(m.type==='good'){s+='<br><b>作为原料供：</b><br>';edges.filter(e=>e.from===k).forEach(e=>{s+=`· ${e.bd} <span style="color:#8b949e">→ ${mat[e.to]?mat[e.to].display:e.to}</span><br>`;});}
  return s;}
function edgeTip(e){let s=`<b>${buildById[e.b]?buildById[e.b].display:e.b}</b><br>`;
  s+=`原料：${mat[e.from]?mat[e.from].display:e.from}`;
  if(e.qty_in)s+=` (×${e.qty_in})`;
  s+=`<br>产出：${mat[e.to]?mat[e.to].display:e.to}`;
  if(e.qty_out)s+=` (×${e.qty_out})`;
  return s;}
function buildTip(b){let s=`<b>${b.display}</b> <span style="color:#8b949e">(${b.id})</span><br>类型：${b.kind||'-'}<br>`;
  if(b.resources.length){s+='<br><b>提取资源：</b><br>'+b.resources.map(r=>`· ${r.res} ×${r.qty}`).join('<br>');}
  if(b.inputs.length){s+='<br><b>消耗物资：</b><br>'+b.inputs.map(i=>`· ${i.good} ×${i.qty}`).join('<br>');}
  if(b.outputs.length){s+='<br><b>产出物资：</b><br>'+b.outputs.map(o=>`· ${o.good} ×${o.qty}`).join('<br>');}
  return s;}

// ----- focus / highlight chain -----
function clearFocus(){document.querySelectorAll('.hot').forEach(e=>e.classList.remove('hot'));
  document.querySelectorAll('.dim').forEach(e=>e.classList.remove('dim'));}
function setDim(keep){Object.values(nodeEls).forEach(g=>{if(!keep.has(g._k))g.classList.add('dim');});
  edgeEls.forEach(p=>{if(!keep.has(p._e.from)&&!keep.has(p._e.to))p.classList.add('dim');});}
function focusChain(k){
  clearFocus();
  const up=new Set(),down=new Set();
  function walkUp(x){up.add(x);edges.filter(e=>e.to===x).forEach(e=>{if(!up.has(e.from))walkUp(e.from);});}
  function walkDown(x){down.add(x);edges.filter(e=>e.from===x).forEach(e=>{if(!down.has(e.to))walkDown(e.to);});}
  walkUp(k);walkDown(k);
  const keep=new Set([...up,...down]);
  keep.forEach(kk=>{if(nodeEls[kk])nodeEls[kk].classList.add('hot');});
  edgeEls.forEach(p=>{if(keep.has(p._e.from)&&keep.has(p._e.to))p.classList.add('hot');});
  setDim(keep);
}
function focusBuild(bid){
  clearFocus();const b=buildById[bid];if(!b)return;
  const keep=new Set();
  b.resources.forEach(r=>keep.add('R:'+r.res));
  b.inputs.forEach(i=>keep.add('G:'+i.good));
  b.outputs.forEach(o=>keep.add('G:'+o.good));
  keep.forEach(kk=>{if(nodeEls[kk])nodeEls[kk].classList.add('hot');});
  if(bldEls[bid])bldEls[bid].classList.add('hot');
  edgeEls.forEach(p=>{if(keep.has(p._e.from)&&keep.has(p._e.to))p.classList.add('hot');});
  setDim(keep);
}

// ----- search -----
document.getElementById('search').addEventListener('input',function(){
  const q=this.value.trim().toLowerCase();
  if(!q){clearFocus();return;}
  const matches=new Set();
  Object.keys(mat).forEach(k=>{const m=mat[k];
    if(m.display.toLowerCase().includes(q)||k.toLowerCase().includes(q))matches.add(k);});
  builds.forEach(b=>{if(b.display.toLowerCase().includes(q)||b.id.toLowerCase().includes(q)){
    b.resources.forEach(r=>matches.add('R:'+r.res));
    b.inputs.forEach(i=>matches.add('G:'+i.good));
    b.outputs.forEach(o=>matches.add('G:'+o.good));}});
  clearFocus();
  matches.forEach(kk=>{if(nodeEls[kk])nodeEls[kk].classList.add('hot');});
  setDim(matches);
});

// ----- legend (categories + resources) -----
const legend=document.getElementById('legend');
const cats={};Object.values(mat).forEach(m=>{if(m.type==='good')cats[m.category]=(cats[m.category]||0)+1;});
const title=document.createElement('div');title.style.cssText='font-size:12px;color:#8b949e;margin-bottom:4px;';title.textContent='物资类别（点击切换显隐）';
legend.appendChild(title);
const offCats=new Set();
Object.keys(cats).sort().forEach(c=>{
  const row=document.createElement('div');row.className='legrow';
  const sw=document.createElement('span');sw.className='swatch';sw.style.background=colors[c]||'#90a4ae';
  const lab=document.createElement('span');lab.textContent=`${c} (${cats[c]})`;
  row.appendChild(sw);row.appendChild(lab);
  row.onclick=()=>{if(offCats.has(c)){offCats.delete(c);row.classList.remove('off');}
    else{offCats.add(c);row.classList.add('off');}
    Object.keys(mat).forEach(k=>{if(mat[k].type==='good'&&mat[k].category===c&&nodeEls[k]){
      nodeEls[k].style.display=offCats.has(c)?'none':'';}});};
  legend.appendChild(row);
});
const rtitle=document.createElement('div');rtitle.style.cssText='font-size:12px;color:#b5793a;margin:10px 0 4px;';rtitle.textContent='自然资源（Tier 0）';
legend.appendChild(rtitle);
const rrow=document.createElement('div');rrow.className='legrow';
const rsw=document.createElement('span');rsw.className='swatch';rsw.style.background='#b5793a';
const rlab=document.createElement('span');rlab.textContent=`全部 ${Object.values(mat).filter(m=>m.type==='resource').length} 种`;
rrow.appendChild(rsw);rrow.appendChild(rlab);legend.appendChild(rrow);

applyT();
</script>
''')
html.append('</body></html>')

out = r"D:\Godot\ProjectKeynes\Project.Keynes\docs\industrial_chain.html"
with open(out,'w',encoding='utf-8') as f:
    f.write('\n'.join(html))
print("WROTE", out)
print("nodes:", len(MAT), "edges:", len(EDGES), "buildings:", len(BUILD), "max_tier:", max_tier)
