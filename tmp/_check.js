
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
