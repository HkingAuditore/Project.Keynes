# -*- coding: utf-8 -*-
"""Extract Project.Keynes economy catalog (resources / goods / buildings) and
render a self-contained interactive industrial-chain structure diagram (HTML)."""
import re, json, os, glob

ROOT = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
RES_DIR = os.path.join(ROOT, "data", "resources")
GOOD_DIR = os.path.join(ROOT, "data", "goods")
BLD_DIR = os.path.join(ROOT, "data", "economy", "buildings")
OUT_HTML = r"D:\Godot\ProjectKeynes\Project.Keynes\docs\industrial_chain.html"
OUT_CSV = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\chain_edges.csv"
OUT_JSON = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\chain_data.json"

def parse_tres(path):
    with open(path, encoding="utf-8") as f:
        txt = f.read()
    d = {}
    def skey(key):
        m = re.search(r'^'+re.escape(key)+r'\s*=\s*&?"([^"]*)"', txt, re.M)
        return m.group(1) if m else ""
    def dkey(key):
        m = re.search(r'^'+re.escape(key)+r'\s*=\s*"([^"]*)"', txt, re.M)
        return m.group(1) if m else ""
    def parr(key):
        m = re.search(r'^'+re.escape(key)+r'\s*=\s*PackedStringArray\((.*?)\)', txt, re.M|re.S)
        if not m:
            return []
        inner = m.group(1).strip()
        if not inner:
            return []
        return re.findall(r'"([^"]*)"', inner)
    d["id"] = skey("id") or dkey("id")
    d["display_name"] = dkey("display_name") or d["id"]
    d["category_id"] = skey("category_id")
    d["building_kind"] = dkey("building_kind")
    d["behavior_id"] = dkey("behavior_id")
    d["resource_ids"] = parr("resource_ids")
    d["resource_interaction_modes"] = parr("resource_interaction_modes")
    d["resource_access_modes"] = parr("resource_access_modes")
    d["input_good_ids"] = parr("input_good_ids")
    d["output_good_ids"] = parr("output_good_ids")
    d["input_category_ids"] = parr("input_category_ids")
    d["technology_tags"] = parr("technology_tags")
    return d

resources = {}
for p in glob.glob(os.path.join(RES_DIR, "*.tres")):
    d = parse_tres(p)
    if d["id"]:
        resources[d["id"]] = d

goods = {}
for p in glob.glob(os.path.join(GOOD_DIR, "*.tres")):
    d = parse_tres(p)
    if d["id"]:
        goods[d["id"]] = d

buildings = {}
for p in glob.glob(os.path.join(BLD_DIR, "*.tres")):
    d = parse_tres(p)
    if d["id"]:
        buildings[d["id"]] = d

# ---- category palette ----
CAT_PALETTE = [
    "#e6194b","#3cb44b","#4363d8","#f58231","#911eb4","#46f0f0","#f032e6",
    "#bcf60c","#fabebe","#008080","#e6beff","#9a6324","#800000","#aaffc3",
    "#808000","#000075","#ffd8b1","#a9a9a9","#ff6347","#2e8b57",
]
cat_list = sorted({g["category_id"] for g in goods.values() if g["category_id"]})
cat_color = {c: CAT_PALETTE[i % len(CAT_PALETTE)] for i, c in enumerate(cat_list)}

# ---- build graph ----
# node ids: resource:<id>, good:<id>, building:<id>
nodes = {}
def add_node(nid, kind, label, category=""):
    nodes[nid] = {"id": nid, "kind": kind, "label": label, "category": category}

for rid, r in resources.items():
    add_node("resource:"+rid, "resource", r["display_name"])
for gid, g in goods.items():
    add_node("good:"+gid, "good", g["display_name"], g["category_id"])
for bid, b in buildings.items():
    add_node("building:"+bid, "building", b["display_name"], b["building_kind"])

edges = []  # {s, t, building, recipe}
# consumer/ producer maps for goods
good_producers = {}   # good_id -> [building ids]
good_consumers = {}   # good_id -> [building ids]
for bid, b in buildings.items():
    kind = b["building_kind"]
    outs = b["output_good_ids"]
    ins = b["input_good_ids"]
    res = b["resource_ids"]
    modes = b["resource_interaction_modes"]
    if kind == "collector":
        # resource -> building (extract/capacity), building -> good
        for i, r in enumerate(res):
            mode = modes[i] if i < len(modes) else "extract"
            edges.append({"s": "resource:"+r, "t": "building:"+bid,
                          "building": bid, "label": ("开采" if mode=="extract" else "占用")+r})
        for g in outs:
            edges.append({"s": "building:"+bid, "t": "good:"+g,
                          "building": bid, "label": "产出 "+g})
            good_producers.setdefault(g, []).append(bid)
    else:  # industrial
        for g in ins:
            edges.append({"s": "good:"+g, "t": "building:"+bid,
                          "building": bid, "label": "消耗 "+g})
            good_consumers.setdefault(g, []).append(bid)
        for g in outs:
            edges.append({"s": "building:"+bid, "t": "good:"+g,
                          "building": bid, "label": "产出 "+g})
            good_producers.setdefault(g, []).append(bid)

# resource -> good direct (for collectors, the building is the bridge); also map resource extract modes
# ---- tier assignment (longest path from a resource) ----
# good tier = longest chain length from any resource
good_tier = {gid: 0 for gid in goods}
# iterate fixed point
changed = True
it = 0
while changed and it < len(goods)+3:
    changed = False
    it += 1
    for bid, b in buildings.items():
        outs = b["output_good_ids"]
        if b["building_kind"] == "collector":
            cand = 1  # resource(0) -> collector -> good(1)
        else:
            ins = b["input_good_ids"]
            if not ins:
                cand = 1
            else:
                cand = max(good_tier.get(i, 0) for i in ins) + 1
        for g in outs:
            if cand > good_tier.get(g, 0):
                good_tier[g] = cand
                changed = True

# building tier = output good max tier - 0.5 (collectors -> 0.5)
def building_tier(b):
    outs = b["output_good_ids"]
    if b["building_kind"] == "collector":
        return 0.5
    if not outs:
        return 0.5
    return max(good_tier.get(g, 1) for g in outs) - 0.5

node_tier = {}
for rid in resources:
    node_tier["resource:"+rid] = 0.0
for gid in goods:
    node_tier["good:"+gid] = float(good_tier[gid])
for bid, b in buildings.items():
    node_tier["building:"+bid] = building_tier(b)

max_tier = max(node_tier.values())

# ---- layout ----
COLW = 250.0
ROWH = 30.0
NODE_W = 168.0
NODE_H = 22.0
MX, MY = 60.0, 50.0

# order within tier
def sort_key(nid):
    n = nodes[nid]
    if n["kind"] == "resource":
        return (0, n["label"])
    if n["kind"] == "good":
        return (cat_list.index(n["category"]) if n["category"] in cat_list else 999, n["label"])
    # building: sort by output category if industrial else by resource
    b = buildings[n["id"].split(":",1)[1]]
    if b["building_kind"] == "collector":
        cat = b["resource_ids"][0] if b["resource_ids"] else ""
        return (0, cat, n["label"])
    else:
        oc = ""
        if b["output_good_ids"]:
            og = goods.get(b["output_good_ids"][0])
            oc = og["category_id"] if og else ""
        return (cat_list.index(oc) if oc in cat_list else 999, n["label"])

tier_groups = {}
for nid, t in node_tier.items():
    tier_groups.setdefault(t, []).append(nid)
for t in tier_groups:
    tier_groups[t].sort(key=sort_key)

pos = {}
col_count = {}
for t, ids in tier_groups.items():
    for i, nid in enumerate(ids):
        x = MX + t * COLW
        y = MY + i * ROWH
        pos[nid] = {"x": x, "y": y}
        col_count[t] = i+1

max_rows = max(col_count.values()) if col_count else 1
W = MX*2 + (max_tier+1) * COLW
H = MY*2 + max_rows * ROWH

# ---- meta for hover ----
for nid, n in nodes.items():
    kind = n["kind"]
    meta = []
    if kind == "good":
        gid = nid.split(":",1)[1]
        prods = good_producers.get(gid, [])
        cons = good_consumers.get(gid, [])
        meta.append("类型: 物资 (类别 %s)" % (n["category"] or "-"))
        meta.append("由 %d 个建筑产出: %s" % (len(prods), ", ".join(buildings[p]["display_name"] for p in prods) or "无"))
        meta.append("被 %d 个建筑消耗: %s" % (len(cons), ", ".join(buildings[c]["display_name"] for c in cons) or "无(终端产品)"))
        meta.append("产业层级: %d" % good_tier.get(gid,0))
    elif kind == "resource":
        rid = nid.split(":",1)[1]
        r = resources[rid]
        meta.append("类型: 自然资源 (terrain deposit)")
        # find collectors
        cols = [bid for bid,b in buildings.items() if rid in b["resource_ids"]]
        meta.append("采集/占用建筑: %s" % (", ".join(buildings[c]["display_name"] for c in cols) or "无"))
    else:
        bid = nid.split(":",1)[1]
        b = buildings[bid]
        meta.append("类型: 建筑 (%s)" % ("采集设施" if b["building_kind"]=="collector" else "工业建筑"))
        if b["resource_ids"]:
            meta.append("自然资源: %s" % ", ".join("%s[%s]"%(rid, (b["resource_interaction_modes"][i] if i<len(b["resource_interaction_modes"]) else "") ) for i,rid in enumerate(b["resource_ids"])))
        if b["input_good_ids"]:
            meta.append("投入物资: %s" % ", ".join(b["input_good_ids"]))
        if b["output_good_ids"]:
            meta.append("产出物资: %s" % ", ".join(b["output_good_ids"]))
        if b["technology_tags"]:
            meta.append("科技标签: %s" % ", ".join(b["technology_tags"]))
    n["meta"] = meta

# color
for nid, n in nodes.items():
    if n["kind"] == "resource":
        n["color"] = "#2e7d32"
    elif n["kind"] == "building":
        n["color"] = "#8d6e63" if n["category"]=="collector" else "#546e7a"
    else:
        n["color"] = cat_color.get(n["category"], "#999999")

# edges json
edge_list = [{"s": e["s"], "t": e["t"], "label": e["label"]} for e in edges]

data = {
    "nodes": nodes,
    "edges": edge_list,
    "categories": cat_list,
    "cat_color": cat_color,
    "layout": {"pos": pos, "W": W, "H": H, "NODE_W": NODE_W, "NODE_H": NODE_H},
    "stats": {
        "resources": len(resources),
        "goods": len(goods),
        "buildings": len(buildings),
        "edges": len(edges),
        "categories": len(cat_list),
        "max_tier": int(max_tier),
    }
}

with open(OUT_JSON, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)

# edges csv
with open(OUT_CSV, "w", encoding="utf-8") as f:
    f.write("building_id,building_kind,building_name,resource_in,input_goods,output_goods\n")
    for bid, b in buildings.items():
        f.write("%s,%s,%s,%s,%s,%s\n" % (
            bid, b["building_kind"], b["display_name"],
            ";".join("%s[%s]"%(r,(b["resource_interaction_modes"][i] if i<len(b["resource_interaction_modes"]) else "")) for i,r in enumerate(b["resource_ids"])),
            ";".join(b["input_good_ids"]),
            ";".join(b["output_good_ids"]),
        ))

# ---- terminal / base goods ----
terminal = [gid for gid in goods if gid not in good_consumers]
base = [gid for gid in goods if good_tier.get(gid,0)==1]
print("RESOURCES:", len(resources))
print("GOODS:", len(goods))
print("BUILDINGS:", len(buildings))
print("EDGES:", len(edges))
print("CATEGORIES:", len(cat_list), cat_list)
print("MAX TIER:", int(max_tier))
print("TERMINAL GOODS (%d):" % len(terminal), terminal)
print("BASE GOODS (tier1, %d):" % len(base), base)
print("Tier distribution:", {t: len(v) for t,v in sorted(tier_groups.items())})

# ============ HTML ============
html = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>Project.Keynes 产业链结构图</title>
<style>
* { box-sizing: border-box; }
html,body { margin:0; height:100%; font-family: "Segoe UI","Microsoft YaHei",system-ui,sans-serif; background:#0f1419; color:#e6e6e6; overflow:hidden; }
#app { display:flex; height:100vh; }
#side { width:300px; min-width:300px; background:#161c24; border-right:1px solid #2a3340; padding:14px; overflow-y:auto; }
#side h1 { font-size:16px; margin:0 0 6px; color:#ffd54f; }
#side .sub { font-size:12px; color:#9aa7b4; margin-bottom:12px; line-height:1.5; }
.stat { display:flex; justify-content:space-between; font-size:12px; padding:3px 0; border-bottom:1px dashed #232c38; }
.stat b { color:#7ee0c0; }
.legend { margin-top:14px; }
.legend .cat { display:flex; align-items:center; gap:6px; font-size:12px; padding:2px 4px; cursor:pointer; border-radius:4px; }
.legend .cat:hover { background:#222c38; }
.legend .sw { width:14px; height:14px; border-radius:3px; flex:0 0 auto; }
.legend .cnt { margin-left:auto; color:#7e8b99; }
.dim-legend { opacity:0.35; }
#search { width:100%; padding:6px 8px; margin-top:10px; background:#0f1419; border:1px solid #2a3340; color:#e6e6e6; border-radius:5px; font-size:13px; }
#info { margin-top:14px; font-size:12px; line-height:1.55; background:#0f1419; border:1px solid #2a3340; border-radius:6px; padding:10px; min-height:80px; }
#info .t { color:#ffd54f; font-weight:600; margin-bottom:4px; }
#info .m { color:#c4cdd6; white-space:pre-line; }
#canvasWrap { flex:1; position:relative; overflow:hidden; }
svg { width:100%; height:100%; display:block; cursor:grab; }
svg.grabbing { cursor:grabbing; }
.node rect { stroke-width:1.2; }
.node text { font-size:11px; fill:#0f1419; font-weight:600; pointer-events:none; }
.node.res text, .node.building text { fill:#fff; }
.edge { stroke:#3a4654; stroke-width:1; fill:none; opacity:0.55; }
.dim { opacity:0.08 !important; }
.hl { opacity:1 !important; }
.edge.hl { stroke:#ffd54f; stroke-width:2.2; opacity:0.95; }
.node.hl rect { stroke:#ffd54f; stroke-width:2.4; }
#hint { position:absolute; left:12px; bottom:10px; font-size:11px; color:#6b7886; background:rgba(15,20,25,.7); padding:4px 8px; border-radius:4px; }
#zoom { position:absolute; right:12px; top:12px; }
#zoom button { background:#222c38; color:#e6e6e6; border:1px solid #2a3340; border-radius:4px; width:30px; height:28px; cursor:pointer; font-size:15px; margin-left:4px; }
#zoom button:hover { background:#2e3a48; }
</style></head>
<body><div id="app">
<div id="side">
  <h1>产业链结构图</h1>
  <div class="sub">Project.Keynes 经济目录：自然资源 → 建筑加工 → 物资流转。拖拽平移，滚轮缩放，悬停节点高亮上下游产业链。</div>
  <div id="stats"></div>
  <input id="search" placeholder="搜索 资源/物资/建筑 名称…">
  <div class="legend" id="legend"></div>
  <div id="info"><div class="t">信息面板</div><div class="m">悬停任意节点查看其配方与上下游关系。</div></div>
</div>
<div id="canvasWrap">
  <div id="zoom"><button id="zin">+</button><button id="zout">−</button><button id="zfit">⤢</button></div>
  <svg id="svg"><g id="viewport">
    <g id="edges"></g>
    <g id="nodes"></g>
  </g></svg>
  <div id="hint">左键拖拽平移 · 滚轮缩放 · 悬停高亮产业链 · 图例/搜索过滤</div>
</div>
</div>
<script>
const DATA = __DATA__;
const NS = "http://www.w3.org/2000/svg";
const {nodes, edges, categories, cat_color, layout} = DATA;
const pos = layout.pos, NODE_W = layout.NODE_W, NODE_H = layout.NODE_H;
const svg = document.getElementById("svg");
const vp = document.getElementById("viewport");
const gEdges = document.getElementById("edges");
const gNodes = document.getElementById("nodes");

// adjacency
const succ = {}, pred = {};
for (const k in nodes){ succ[k]=[]; pred[k]=[]; }
for (const e of edges){ succ[e.s].push(e.t); pred[e.t].push(e.s); }

// build edges
for (const e of edges){
  const p1 = pos[e.s], p2 = pos[e.t];
  if(!p1||!p2) continue;
  const x1 = p1.x+NODE_W, y1 = p1.y+NODE_H/2;
  const x2 = p2.x, y2 = p2.y+NODE_H/2;
  const mx = (x1+x2)/2;
  const path = document.createElementNS(NS,"path");
  path.setAttribute("class","edge");
  path.setAttribute("d", `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`);
  path.dataset.s = e.s; path.dataset.t = e.t;
  gEdges.appendChild(path);
}
// build nodes
const nodeEls = {};
for (const k in nodes){
  const n = nodes[k], p = pos[k];
  const g = document.createElementNS(NS,"g");
  g.setAttribute("class","node "+n.kind);
  g.setAttribute("transform", `translate(${p.x},${p.y})`);
  g.dataset.id = k;
  const rect = document.createElementNS(NS,"rect");
  rect.setAttribute("width",NODE_W); rect.setAttribute("height",NODE_H);
  rect.setAttribute("rx",5);
  rect.setAttribute("fill", n.color);
  rect.setAttribute("stroke", "#0f1419");
  g.appendChild(rect);
  const tx = document.createElementNS(NS,"text");
  tx.setAttribute("x", 7); tx.setAttribute("y", NODE_H/2+4);
  tx.textContent = n.label.length>14 ? n.label.slice(0,13)+"…" : n.label;
  g.appendChild(tx);
  g.addEventListener("mouseenter", ()=>focusNode(k));
  g.addEventListener("mouseleave", clearFocus);
  gNodes.appendChild(g);
  nodeEls[k]=g;
}

// stats
const st = DATA.stats;
const statsEl = document.getElementById("stats");
const rows = [["自然资源",st.resources],["物资",st.goods],["建筑",st.buildings],["加工边",st.edges],["物资类别",st.categories],["最大产业层级",st.max_tier]];
statsEl.innerHTML = rows.map(r=>`<div class="stat"><span>${r[0]}</span><b>${r[1]}</b></div>`).join("");

// legend
const legend = document.getElementById("legend");
for (const c of categories){
  const div = document.createElement("div");
  div.className="cat"; div.dataset.cat=c;
  div.innerHTML = `<span class="sw" style="background:${cat_color[c]}"></span><span>${c}</span><span class="cnt">${DATA.nodes?Object.values(DATA.nodes).filter(n=>n.kind==='good'&&n.category===c).length:0}</span>`;
  div.onclick = ()=>toggleCat(c, div);
  legend.appendChild(div);
}
let activeCat = null;
function toggleCat(c, div){
  if(activeCat===c){ activeCat=null; div.classList.remove("dim-legend"); clearFocus(); return; }
  activeCat=c;
  document.querySelectorAll(".legend .cat").forEach(x=>x.classList.toggle("dim-legend", x.dataset.cat!==c));
  // highlight goods of this cat + connected buildings
  const keep = new Set();
  for(const k in nodes){ if(nodes[k].kind==='good'&&nodes[k].category===c) keep.add(k); }
  // add adjacent buildings
  for(const k of [...keep]){ for(const n of succ[k]) if(nodes[n].kind==='building') keep.add(n); for(const n of pred[k]) if(nodes[n].kind==='building') keep.add(n); }
  // add resources feeding those buildings
  for(const k of [...keep]){ if(nodes[k].kind==='building'){ for(const n of pred[k]) if(nodes[n].kind==='resource') keep.add(n);} }
  applyFilter(keep);
}

// search
const search = document.getElementById("search");
search.addEventListener("input", ()=>{
  const q = search.value.trim().toLowerCase();
  if(!q){ clearFocus(); return; }
  const keep = new Set();
  for(const k in nodes){ if(nodes[k].label.toLowerCase().includes(q) || k.toLowerCase().includes(q)) keep.add(k); }
  if(keep.size){ applyFilter(keep); } else { applyFilter(new Set()); }
});

function applyFilter(keep){
  for(const k in nodes){ nodeEls[k].classList.toggle("dim", !keep.has(k)); }
  document.querySelectorAll(".edge").forEach(p=>{
    const on = keep.has(p.dataset.s) && keep.has(p.dataset.t);
    p.classList.toggle("dim", !on); p.classList.toggle("hl", on);
  });
}

// focus (hover) highlight: full upstream + downstream chain
function focusNode(k){
  const down = new Set(), up = new Set();
  (function bfs(s,set,adj){ const q=[s]; while(q.length){ const c=q.pop(); for(const n of adj[c]){ if(!set.has(n)){ set.add(n); q.push(n);} } } })(k,down,succ);
  (function bfs(s,set,adj){ const q=[s]; while(q.length){ const c=q.pop(); for(const n of adj[c]){ if(!set.has(n)){ set.add(n); q.push(n);} } } })(k,up,pred);
  const hl = new Set([k, ...down, ...up]);
  for(const nk in nodes){ nodeEls[nk].classList.toggle("hl", hl.has(nk)); nodeEls[nk].classList.toggle("dim", !hl.has(nk)); }
  document.querySelectorAll(".edge").forEach(p=>{
    const on = hl.has(p.dataset.s) && hl.has(p.dataset.t);
    p.classList.toggle("hl", on); p.classList.toggle("dim", !on);
  });
  const n = nodes[k];
  document.getElementById("info").innerHTML = `<div class="t">${n.label}</div><div class="m">${n.meta.join("\\n")}</div>`;
}
function clearFocus(){
  if(activeCat){ // re-apply category filter
    toggleCatRenew(); return;
  }
  if(search.value.trim()){ return; }
  for(const nk in nodes){ nodeEls[nk].classList.remove("hl"); nodeEls[nk].classList.remove("dim"); }
  document.querySelectorAll(".edge").forEach(p=>{ p.classList.remove("hl"); p.classList.remove("dim"); });
  document.getElementById("info").innerHTML = `<div class="t">信息面板</div><div class="m">悬停任意节点查看其配方与上下游关系。</div>`;
}
function toggleCatRenew(){
  if(!activeCat) return;
  const keep = new Set();
  for(const k in nodes){ if(nodes[k].kind==='good'&&nodes[k].category===activeCat) keep.add(k); }
  for(const k of [...keep]){ for(const n of succ[k]) if(nodes[n].kind==='building') keep.add(n); for(const n of pred[k]) if(nodes[n].kind==='building') keep.add(n); }
  for(const k of [...keep]){ if(nodes[k].kind==='building'){ for(const n of pred[k]) if(nodes[n].kind==='resource') keep.add(n);} }
  applyFilter(keep);
}

// pan & zoom
let scale=1, tx=0, ty=0;
function applyView(){ vp.setAttribute("transform", `translate(${tx},${ty}) scale(${scale})`); }
function fit(){
  const wrap = document.getElementById("canvasWrap");
  const vw = wrap.clientWidth, vh = wrap.clientHeight;
  const cw = layout.W, ch = layout.H;
  scale = Math.min(vw/cw, vh/ch)*0.95;
  tx = (vw - cw*scale)/2; ty = (vh - ch*scale)/2;
  applyView();
}
let dragging=false, sx=0, sy=0, ox=0, oy=0;
svg.addEventListener("mousedown", e=>{ dragging=true; svg.classList.add("grabbing"); sx=e.clientX; sy=e.clientY; ox=tx; oy=ty; });
window.addEventListener("mousemove", e=>{ if(!dragging) return; tx=ox+(e.clientX-sx); ty=oy+(e.clientY-sy); applyView(); });
window.addEventListener("mouseup", ()=>{ dragging=false; svg.classList.remove("grabbing"); });
svg.addEventListener("wheel", e=>{ e.preventDefault(); const f = e.deltaY<0?1.12:0.89; const r=svg.getBoundingClientRect(); const mx=e.clientX-r.left, my=e.clientY-r.top; const nx=(mx-tx)/scale, ny=(my-ty)/scale; scale*=f; tx=mx-nx*scale; ty=my-ny*scale; applyView(); }, {passive:false});
document.getElementById("zin").onclick=()=>{ scale*=1.15; applyView(); };
document.getElementById("zout").onclick=()=>{ scale*=0.87; applyView(); };
document.getElementById("zfit").onclick=fit;
fit();
setTimeout(fit, 200);
</script></body></html>"""

html = html.replace("__DATA__", json.dumps(data, ensure_ascii=False))
with open(OUT_HTML, "w", encoding="utf-8") as f:
    f.write(html)
print("WROTE HTML:", OUT_HTML, "size", len(html))
print("WROTE CSV:", OUT_CSV)
print("WROTE JSON:", OUT_JSON)
