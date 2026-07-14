#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
from collections import defaultdict

D = json.load(open(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\chain_data.json", encoding='utf-8'))
S=D['summary']; MAT=D['materials']; EDGES=D['edges']; BUILD=D['buildings']
max_tier=max(m['tier'] for m in MAT.values())
byId={k:v for k,v in MAT.items()}
bById={b['id']:b for b in BUILD}

def disp(k):
    return byId[k]['display'] if k in byId else k

# producers of a node
prod={}
cons={}
for e in EDGES:
    prod.setdefault(e['to'],[]).append(e)
    cons.setdefault(e['from'],[]).append(e)

out=[]
out.append('# Project.Keynes 产业链结构总览\n')
out.append('> 基于 `data/resources/`（自然资源）、`data/goods/`（物资）、`data/economy/buildings/`（建筑）三套目录自动抽取。\n')
out.append('## 一、规模与模型\n')
out.append(f"- 自然资源（Tier 0，地图生成沉积）：**{S['n_resources_used']}** 种")
out.append(f"- 物资（可贸易加工品）：**{S['n_goods_used']}** 种，分 **{len(S['category_counts'])}** 个类别")
out.append(f"- 建筑（转换节点）：**{S['n_buildings']}** 座")
out.append(f"- 生产链路（原料→产出有向边）：**{S['n_edges']}** 条 · 最大链深（Tier）：**{max_tier}**")
out.append(f"- 存在循环依赖的强连通分量：**{S['n_cyclic_scc']}** 组（工具/机械反馈回路，如 矿→钢→工具→矿）\n")
out.append('**三层模型**：`自然资源` →〔采集建筑〕→ `初级物资` →〔加工/制造建筑〕→ `精炼/终端物资`。')
out.append('建筑是唯一的“转换”节点：它消耗自然资源与上游物资，产出下游物资；部分建筑同时消耗工具/机械（运营投入），因此形成闭环供应链。\n')

# Part A: collector layer
out.append('## 二、采集层：自然资源 → 初级物资\n')
out.append('自然资源作为建筑输入有两种模式：')
out.append('1. **纯开采**（采集建筑 `resource_ids` 含矿/石/油，产出同名可贸易物资）：如 铁矿→铁矿、煤→煤、原油→原油。')
out.append('2. **土地容量依赖**（农场/纺织建筑以 `arable_land`、`fertile_soil`、`pasture`、`paddy_land`、`plantation_land` 等为运营用地资源，产出农作物/纤维）：这类资源不被“收集”为物资，而是作为生产前提。\n')
out.append('| 自然资源 | 采集/生产建筑 | 产出物资 | 模式 |')
out.append('|---|---|---|---|')
res_nodes=[k for k in MAT if MAT[k]['type']=='resource']
for k in sorted(res_nodes):
    rid=k.split(':',1)[1]
    # find buildings that have this resource in resource_ids and output a good
    bs=[b for b in BUILD if rid in [r['res'] for r in b['resources']] and b['outputs']]
    if not bs:
        # maybe direct R->G edge
        bs=[b for b in BUILD if rid in [r['res'] for r in b['resources']]]
    row=[disp(k)]
    mode='纯开采'
    if rid in ('arable_land','fertile_soil','pasture','paddy_land','plantation_land','marine_fish'):
        mode='土地容量依赖'
    if bs:
        row.append('、'.join(b['display'] for b in bs))
        outs=set()
        for b in bs:
            for o in b['outputs']: outs.add(o['good'])
        row.append('、'.join(disp('G:'+g) for g in outs))
    else:
        row.append('（无采集建筑）'); row.append('-')
    row.append(mode)
    out.append('| '+ ' | '.join(row) + ' |')
out.append('')

# Part B: tiers
out.append('## 三、加工链层级（Tier 0 → '+str(max_tier)+'）\n')
tiers=defaultdict(list)
for k,m in MAT.items():
    if m['type']=='good':
        tiers[m['tier']].append(k)
for t in sorted(tiers):
    nodes=sorted(tiers[t], key=lambda k: MAT[k].get('category',''))
    out.append(f'### Tier {t}（{len(nodes)} 种物资）\n')
    out.append('| 物资 | 类别 | 由以下建筑产出（消耗 → 产出） |')
    out.append('|---|---|---|')
    for k in nodes:
        prods=prod.get(k,[])
        cells=[]
        for e in prods:
            b=bById[e['b']]
            ins=[i['good'] for i in b['inputs']]+[r['res'] for r in b['resources']]
            q=f" ({e.get('qty_out','')})" if e.get('qty_out') else ''
            cells.append(f"**{b['display']}**：{('+'.join(ins)) or '—'} → {e['to'].split(':')[1]}{q}")
        if not cells:
            cells=['（无上游，孤立/初始）']
        out.append(f"| {MAT[k]['display']} | {MAT[k].get('category','')} | {'；'.join(cells)} |")
    out.append('')

# Part C: building index by category
out.append('## 四、建筑配方总表（按类别）\n')
cat_builds=defaultdict(list)
for b in BUILD:
    # primary category from outputs
    cat=''
    if b['outputs']:
        g='G:'+b['outputs'][0]['good']
        cat=MAT[g].get('category','') if g in MAT else ''
    cat_builds[cat if cat else '(其他)'].append(b)
for cat in sorted(cat_builds):
    out.append(f'### {cat}\n')
    out.append('| 建筑 | 类型 | 提取资源 | 消耗物资 | 产出物资 |')
    out.append('|---|---|---|---|---|')
    for b in sorted(cat_builds[cat], key=lambda x:x['display']):
        res='、'.join(f"{r['res']}×{r['qty']}" for r in b['resources']) or '—'
        inp='、'.join(f"{i['good']}×{i['qty']}" for i in b['inputs']) or '—'
        outp='、'.join(f"{o['good']}×{o['qty']}" for o in b['outputs']) or '—'
        out.append(f"| {b['display']} | {b['kind']} | {res} | {inp} | {outp} |")
    out.append('')

# Part D: sample end chains
out.append('## 五、代表性终端产品链（深度示例）\n')
def trace(target, depth=0, seen=None, path=None):
    if seen is None: seen=set()
    if path is None: path=[]
    if target in seen or depth>12: return
    seen.add(target)
    for e in prod.get(target,[]):
        b=bById[e['b']]
        ins=[i['good'] for i in b['inputs']]+[r['res'] for r in b['resources']]
        line='  '*depth + f"└ {b['display']}  [{'+'.join(ins)} → {target.split(':')[1]}]"
        path.append(line)
        for i in ins:
            tk='G:'+i if i in {g['good'] for bb in BUILD for g in bb['outputs']} or True else i
            # trace upstream goods
            if ('G:'+i) in prod:
                trace('G:'+i, depth+1, seen, path)
    return path

for target in ['G:steel','G:advanced_chips','G:construction_components','G:clothing','G:pharmaceuticals','G:oceanic_vessels']:
    if target in MAT:
        out.append(f'### {MAT[target]["display"]}（Tier {MAT[target]["tier"]}）\n')
        p=trace(target)
        # dedupe keep order
        uniq=[]; [uniq.append(x) for x in p if x not in uniq]
        out.extend(uniq[:40])
        out.append('')

out.append('\n---\n*自动生成 · 交互式版本见 `docs/industrial_chain.html`*')
text='\n'.join(out)
open(r"D:\Godot\ProjectKeynes\Project.Keynes\产业链结构总览.md",'w',encoding='utf-8').write(text)
print("WROTE 产业链结构总览.md  lines:", len(out))
