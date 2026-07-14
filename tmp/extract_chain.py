#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, re, json

BASE = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data"

def parse_value(v):
    v = v.strip()
    if v.startswith('PackedStringArray('):
        inner = v[len('PackedStringArray('):-1]
        return re.findall(r'"([^"]*)"', inner)
    if v.startswith('PackedInt64Array(') or v.startswith('PackedInt32Array('):
        inner = v[v.index('(')+1:-1]
        return [int(x) for x in inner.split(',') if x.strip() != '']
    if v.startswith('&"') or v.startswith('&'):
        return v.strip('&"').strip('"')
    if v.startswith('"'):
        return v.strip('"')
    if v == '' or v == '""':
        return []
    # number
    try:
        return float(v) if ('.' in v or 'e' in v.lower()) else int(v)
    except:
        return v

def parse_tres(path):
    """Return dict of key->value for simple `key = value` lines."""
    out = {}
    with open(path, encoding='utf-8') as f:
        lines = f.readlines()
    # handle multiline dicts by joining continuation lines (only for init_landform_weights etc.)
    buf = ''
    key = None
    i = 0
    while i < len(lines):
        line = lines[i].rstrip('\n')
        i += 1
        if line.strip() == '' or line.strip().startswith('['):
            continue
        if '=' in line and not buf:
            k, _, val = line.partition('=')
            key = k.strip()
            val = val.strip()
            if val.startswith('{'):
                collected = val
                if '}' in val:
                    out[key] = collected
                    key = None
                else:
                    buf = collected
                    while i < len(lines):
                        nxt = lines[i].rstrip('\n')
                        i += 1
                        buf += ' ' + nxt.strip()
                        if '}' in nxt: break
                    out[key] = buf
                    key = None
                    buf = ''
            else:
                out[key] = val
                key = None
    # Only keep fields we care about; convert
    res = {}
    for k, val in out.items():
        res[k] = parse_value(val)
    return res

# --- harvest goods ---
goods = {}
gdir = os.path.join(BASE, 'goods')
for fn in os.listdir(gdir):
    if fn.endswith('.tres'):
        d = parse_tres(os.path.join(gdir, fn))
        gid = d.get('id')
        if gid:
            goods[gid] = {
                'id': gid,
                'display': d.get('display_name', gid),
                'category': d.get('category_id', ''),
                'tech_tags': d.get('technology_tags', []) or [],
                'default_price': d.get('default_price', 0),
            }

# --- harvest resources ---
resources = {}
rdir = os.path.join(BASE, 'resources')
for fn in os.listdir(rdir):
    if fn.endswith('.tres'):
        d = parse_tres(os.path.join(rdir, fn))
        rid = d.get('id')
        if rid:
            resources[rid] = {
                'id': rid,
                'display': d.get('display_name', rid),
            }

# --- harvest buildings ---
buildings = []
bdir = os.path.join(BASE, 'economy', 'buildings')
for fn in os.listdir(bdir):
    if fn.endswith('.tres'):
        d = parse_tres(os.path.join(bdir, fn))
        bid = d.get('id')
        if not bid:
            continue
        inp = d.get('input_good_ids', []) or []
        inq = d.get('input_quantities_per_day', []) or []
        out = d.get('output_good_ids', []) or []
        outq = d.get('output_quantities_per_day', []) or []
        res = d.get('resource_ids', []) or []
        resq = d.get('resource_quantities_per_day', []) or []
        # resource_generation_ids (some buildings generate resources)
        resgen = d.get('resource_generation_ids', []) or []
        buildings.append({
            'id': bid,
            'display': d.get('display_name', bid),
            'kind': d.get('building_kind', ''),
            'tech_tags': d.get('technology_tags', []) or [],
            'inputs': [{'good': x, 'qty': (inq[i] if i < len(inq) else 0)} for i, x in enumerate(inp)],
            'outputs': [{'good': x, 'qty': (outq[i] if i < len(outq) else 0)} for i, x in enumerate(out)],
            'resources': [{'res': x, 'qty': (resq[i] if i < len(resq) else 0)} for i, x in enumerate(res)],
            'resource_gen': resgen,
        })

# --- build material flow graph ---
# material nodes: resources (tier 0) + goods (tier >=1)
materials = {}
for rid, r in resources.items():
    materials[('R', rid)] = {'id': rid, 'type': 'resource', 'display': r['display']}
for gid, g in goods.items():
    materials[('G', gid)] = {'id': gid, 'type': 'good', 'display': g['display'],
                             'category': g['category'], 'price': g['default_price'],
                             'tech_tags': g.get('tech_tags', [])}

# edges: material -> material, attributed to building
edges = []  # (from_key, to_key, building_id, building_display)
# resource -> good (collector)
for b in buildings:
    for rin in b['resources']:
        fk = ('R', rin['res'])
        for gout in b['outputs']:
            tk = ('G', gout['good'])
            if fk in materials and tk in materials:
                edges.append({'from': fk[0]+':'+fk[1], 'to': tk[0]+':'+tk[1],
                              'b': b['id'], 'bd': b['display']})
    for gin in b['inputs']:
        fk = ('G', gin['good'])
        for gout in b['outputs']:
            tk = ('G', gout['good'])
            if fk in materials and tk in materials:
                edges.append({'from': fk[0]+':'+fk[1], 'to': tk[0]+':'+tk[1],
                              'b': b['id'], 'bd': b['display'],
                              'qty_in': gin['qty'], 'qty_out': gout['qty']})

# adjacency for tier computation
children = {}   # node -> set of downstream nodes
parents = {}    # node -> set of upstream nodes
allnodes = set(materials.keys())
for e in edges:
    f = (e['from'][0], e['from'][2:]) if e['from'][0]=='R' else (e['from'][0], e['from'][2:])
    # from/to are strings "R:iron_ore" / "G:steel"
    fk = tuple(e['from'].split(':',1))
    tk = tuple(e['to'].split(':',1))
    children.setdefault(fk, set()).add(tk)
    parents.setdefault(tk, set()).add(fk)

# tier: longest path from any resource, with robust cycle (SCC) handling.
# Build adjacency as node-key tuples.
adj = {k: set() for k in allnodes}
radj = {k: set() for k in allnodes}
for e in edges:
    fk = tuple(e['from'].split(':',1))
    tk = tuple(e['to'].split(':',1))
    if fk in allnodes and tk in allnodes:
        adj[fk].add(tk)
        radj[tk].add(fk)

# Tarjan SCC
index = {}
low = {}
onstack = {}
stack = []
sccs = []
idx = [0]
def strongconnect(v):
    index[v] = idx[0]; low[v] = idx[0]; idx[0]+=1
    stack.append(v); onstack[v]=True
    for w in adj[v]:
        if w not in index:
            strongconnect(w)
            low[v]=min(low[v],low[w])
        elif onstack.get(w):
            low[v]=min(low[v],index[w])
    if low[v]==index[v]:
        comp=[]
        while True:
            w=stack.pop(); onstack[w]=False; comp.append(w)
            if w==v: break
        sccs.append(comp)
for v in allnodes:
    if v not in index:
        strongconnect(v)

# map node -> scc id
scc_of = {}
for i,comp in enumerate(sccs):
    for n in comp:
        scc_of[n]=i

# condensed DAG edges
csucc = {i:set() for i in range(len(sccs))}
cprec = {i:set() for i in range(len(sccs))}
for v in allnodes:
    for w in adj[v]:
        if scc_of[v]!=scc_of[w]:
            csucc[scc_of[v]].add(scc_of[w])
            cprec[scc_of[w]].add(scc_of[v])

# topological order of condensed DAG (Kahn)
indeg = {i:len(cprec[i]) for i in range(len(sccs))}
from collections import deque
q = deque([i for i in range(len(sccs)) if indeg[i]==0])
topo=[]
while q:
    u=q.popleft(); topo.append(u)
    for w in csucc[u]:
        indeg[w]-=1
        if indeg[w]==0: q.append(w)
# (any remaining are in cycles; they are already in sccs, place them after by appending)
for i in range(len(sccs)):
    if i not in topo: topo.append(i)

# longest-path tier on condensed DAG
ctier={}
for u in topo:
    base = 0
    for p in cprec[u]:
        base=max(base, ctier.get(p,0))
    # resource-containing scc => tier at least 0; a pure-resource scc is tier 0
    if any(n[0]=='R' for n in sccs[u]):
        ctier[u]=0
    else:
        ctier[u]=base+1
# propagate to nodes
tier={}
for i,comp in enumerate(sccs):
    for n in comp:
        tier[n]=ctier[i]

cycles_found = [c for c in sccs if len(c)>1]

# stats
from collections import Counter
tier_counts = Counter(tier.values())
cat_counts = Counter(g.get('category','') for g in goods.values())
res_used = set()
good_in = set()
good_out = set()
for e in edges:
    fk = tuple(e['from'].split(':',1)); tk = tuple(e['to'].split(':',1))
    if fk[0]=='R': res_used.add(fk[1])
    if fk[0]=='G': good_in.add(fk[1])
    if tk[0]=='G': good_out.add(tk[1])

summary = {
    'n_resources_total': len(resources),
    'n_resources_used': len(res_used),
    'n_goods_total': len(goods),
    'n_goods_used': len(good_in | good_out),
    'n_goods_only_output': len(good_out - good_in),
    'n_goods_only_input': len(good_in - good_out),
    'n_goods_io': len(good_in & good_out),
    'n_buildings': len(buildings),
    'n_edges': len(edges),
    'tier_counts': dict(sorted(tier_counts.items())),
    'category_counts': dict(sorted(cat_counts.items())),
    'buildings_without_io': [b['id'] for b in buildings if not b['inputs'] and not b['outputs'] and not b['resources'] and not b['resource_gen']],
    'n_scc': len(sccs),
    'n_cyclic_scc': len(cycles_found),
    'cyclic_examples': [[n[0]+':'+n[1] for n in c] for c in cycles_found[:5]],
}

# enrich materials with tier
mat_out = {}
for k, m in materials.items():
    mm = dict(m)
    mm['tier'] = tier[k]
    mat_out[k[0]+':'+k[1]] = mm

# node degree
deg = {}
for e in edges:
    deg[e['from']] = deg.get(e['from'],0)+1
    deg[e['to']] = deg.get(e['to'],0)+1

data = {
    'summary': summary,
    'materials': mat_out,
    'edges': edges,
    'buildings': buildings,
    'categories': sorted(set(g.get('category','') for g in goods.values())),
}

outpath = r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\chain_data.json"
with open(outpath, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=1)

print("WROTE", outpath)
print("resources total/used:", summary['n_resources_total'], summary['n_resources_used'])
print("goods total/used:", summary['n_goods_total'], summary['n_goods_used'])
print("buildings:", summary['n_buildings'], "edges:", summary['n_edges'])
print("tiers:", summary['tier_counts'])
print("categories:", summary['category_counts'])
print("isolated buildings:", summary['buildings_without_io'][:20])
