# -*- coding: utf-8 -*-
"""解锁对齐审计：校验「解锁即可建」原则。

模拟运行时建筑可建判定（economy_runtime_building_production.cpp::building_available）：
  1. technology_tags 任一完成（主解锁，仅 tech.* 前缀参与）
  2. required_technology_tags 全部完成
  3. 依赖组判定：每个投入槽/产出货物/绑定资源的技术标签组至少一项完成
     - 投入槽候选展开（economy_catalog.gd L1327-1363）：
       显式候选 > 类别替代（substitution_category_ids 中
       production_quality_level >= input_min_quality_levels 的成员）> 单一货物
     - 建造材料组不参与可建判定（kind 1）
  4. 绑定一致性：technology_network.json 的 expected_bindings 必须与
     .tres 实际数据零漂移（等价于 technology_content_binding_audit_test.gd
     的 _assert_authoring_bindings_exact）
  5. 工具门槛时代规则：tools 类别槽 min_level 不得超过建筑解锁时代对应等级
     （stone→1, agrarian→2, kingdom→3, empire/exploration→3, enlightenment+→4）

判定分级：
  error   = 跨时代错位（A/B/C/RES 类）、绑定漂移、未知科技引用、工具门槛超规则
  warning = 同时代链内顺序差、required 晚于主解锁（项目设计语言：
            direct=主题归属、required=能力门槛，见 expected_direct）

用法：
  python audit_unlock_alignment.py            # 输出报告
  python audit_unlock_alignment.py --check    # error 数 > 0 时退出码 1
报告写入本目录 unlock_alignment_audit.md。
"""
import re
import os
import sys
import json
import glob
import io

if sys.stdout.encoding and sys.stdout.encoding.lower() != 'utf-8':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(TOOLS_DIR, '..', '..', 'data')
TECH_JSON = os.path.join(DATA_DIR, 'technology', 'technology_network.json')
BUILDING_DIR = os.path.join(DATA_DIR, 'economy', 'buildings')
GOOD_DIR = os.path.join(DATA_DIR, 'goods')
RESOURCE_DIR = os.path.join(DATA_DIR, 'resources')
REPORT_PATH = os.path.join(TOOLS_DIR, 'unlock_alignment_audit.md')

TOOLS_ERA_RULE = {'stone': 1, 'agrarian': 2, 'kingdom': 3, 'empire': 3,
                  'exploration': 3, 'enlightenment': 4, 'steam': 4,
                  'electrical': 4, 'atomic': 4, 'information': 4, 'intelligent': 4}


def pstr(s):
    return re.findall(r'"([^"]*)"', s or '')


def pint(s):
    """PackedInt32Array/Int64Array 取括号内整数——注意类型名含 '32'/'64'，必须先截取括号内容。"""
    if s is None:
        return []
    m = re.search(r'\(([^)]*)\)', s)
    return [int(x) for x in re.findall(r'-?\d+', m.group(1) if m else s)]


def gf(text, name):
    m = re.search(r'^%s\s*=\s*(.*)$' % re.escape(name), text, re.M)
    return m.group(1).strip() if m else None


def load_tres(path, fields):
    text = open(path, encoding='utf-8').read()
    return {f: (pstr(gf(text, f)) if k == 's' else
                (pint(gf(text, f)) if k == 'i' else gf(text, f)))
            for f, k in fields}


def tolerant_json(path):
    """technology_network.json 允许尾逗号（Godot 解析容错）。"""
    raw = open(path, encoding='utf-8').read()
    return raw, json.loads(re.sub(r',(\s*[\]}])', r'\1', raw))


def main():
    check_only = '--check' in sys.argv
    errors = []
    warnings = []

    raw, data = tolerant_json(TECH_JSON)
    eras = [e['id'] for e in data['eras']]
    era_idx = {e: i for i, e in enumerate(eras)}
    tech = {n['id']: n for n in data['nodes']}

    memo = {}

    def finish(t):
        """(时代序号, 前置链累积研究点) —— 近似研究完成点。"""
        if t in memo:
            return memo[t]
        n = tech[t]
        era = era_idx[n['era_id']]
        cum = int(n.get('cost_points', 0) or 0)
        if n.get('hard_prerequisite_ids'):
            keys = [finish(p) for p in n['hard_prerequisite_ids']]
            era = max([era] + [k[0] for k in keys])
            cum += max(k[1] for k in keys)
        memo[t] = (era, cum)
        return memo[t]

    # ---- 货物 / 资源 ----
    goods = {}
    for p in glob.glob(os.path.join(GOOD_DIR, '*.tres')):
        d = load_tres(p, [('id', 'r'), ('display_name', 'r'), ('substitution_category_ids', 's'),
                          ('production_quality_level', 'i'), ('technology_tags', 's')])
        gid = (d['id'] or '').replace('&"', '').replace('"', '')
        if gid:
            goods[gid] = {
                'name': (d['display_name'] or '').strip('"'),
                'q': d['production_quality_level'][0] if d['production_quality_level'] else 0,
                'tags': [t for t in d['technology_tags'] if t.startswith('tech.')],
                'cats': d['substitution_category_ids'],
            }
    cat_members = {}
    for gid, g in goods.items():
        for c in g['cats']:
            cat_members.setdefault(c, []).append(gid)
    resources = {}
    for p in glob.glob(os.path.join(RESOURCE_DIR, '*.tres')):
        d = load_tres(p, [('id', 'r'), ('display_name', 'r'), ('discovery_technology_tags', 's')])
        rid = (d['id'] or '').replace('&"', '').replace('"', '')
        if rid:
            resources[rid] = {'name': (d['display_name'] or '').strip('"'),
                              'tags': [t for t in d['discovery_technology_tags'] if t.startswith('tech.')]}

    def group_key(tags):
        if not tags:
            return None
        if any(t not in tech for t in tags):
            return 'UNKNOWN'
        return min(finish(t) for t in tags)

    # ---- 建筑 ----
    bf = [('id', 'r'), ('display_name', 'r'), ('technology_tags', 's'),
          ('required_technology_tags', 's'), ('input_good_ids', 's'),
          ('input_category_ids', 's'), ('input_min_quality_levels', 'i'),
          ('input_candidate_offsets', 'i'), ('input_candidate_good_ids', 's'),
          ('output_good_ids', 's'), ('resource_ids', 's')]
    buildings = []
    for p in sorted(glob.glob(os.path.join(BUILDING_DIR, '*.tres'))):
        d = load_tres(p, bf)
        bid = (d['id'] or '').replace('&"', '').replace('"', '')
        if not bid:
            continue
        direct = [t for t in d['technology_tags'] if t.startswith('tech.')]
        if not direct:
            continue
        buildings.append((bid, d, direct))

    for bid, d, direct in buildings:
        name = d['display_name'].strip('"')
        unknown = [t for t in direct + [x for x in d['required_technology_tags'] if x.startswith('tech.')]
                   if t not in tech]
        if unknown:
            errors.append('%s(%s) 引用未知科技: %s' % (bid, name, unknown))
            continue
        req = [t for t in d['required_technology_tags'] if t.startswith('tech.')]
        unlock = max([min(finish(t) for t in direct)] +
                     [finish(t) for t in req]) if req else min(finish(t) for t in direct)
        unlock_era = eras[unlock[0]]

        # 工具门槛时代规则
        for i, gid in enumerate(d['input_good_ids']):
            cat = d['input_category_ids'][i] if i < len(d['input_category_ids']) else ''
            lvl = d['input_min_quality_levels'][i] if i < len(d['input_min_quality_levels']) else 0
            if cat != 'tools':
                continue
            allow = TOOLS_ERA_RULE.get(unlock_era, 4)
            if lvl > allow:
                errors.append('%s(%s) 解锁[%s] 但 tools 槽门槛 q%d 超过时代规则 q%d'
                              % (bid, name, unlock_era, lvl, allow))

        # 依赖组
        ico = d['input_candidate_offsets']
        has_exp = len(ico) > 1 or bool(d['input_candidate_good_ids'])
        for i, gid in enumerate(d['input_good_ids']):
            b = ico[i] if has_exp and i < len(ico) else 0
            e = ico[i + 1] if has_exp and i + 1 < len(ico) else 0
            if e > b:
                cand = [d['input_candidate_good_ids'][k] for k in range(b, e) if k < len(d['input_candidate_good_ids'])]
            elif i < len(d['input_category_ids']) and d['input_category_ids'][i]:
                lvl = d['input_min_quality_levels'][i] if i < len(d['input_min_quality_levels']) else 0
                cand = [g for g in cat_members.get(d['input_category_ids'][i], []) if goods[g]['q'] >= lvl]
            else:
                cand = [gid]
            tags = sorted(set(t for c in cand for t in goods.get(c, {}).get('tags', [])))
            k = group_key(tags)
            if k == 'UNKNOWN':
                errors.append('%s(%s) 投入槽 %s 候选引用未知科技' % (bid, name, gid))
            elif k and k > unlock:
                gap = k[0] - unlock[0]
                item = '%s(%s) 解锁[%s] 投入门: %s 候选[%s] 需[%s]' % (
                    bid, name, unlock_era, gid, ','.join(cand) or '无', eras[k[0]])
                (errors if gap > 0 else warnings).append(item)
        for gid in d['output_good_ids']:
            k = group_key(goods.get(gid, {}).get('tags', []))
            if k == 'UNKNOWN':
                errors.append('%s(%s) 产出 %s 引用未知科技' % (bid, name, gid))
            elif k and k > unlock:
                gap = k[0] - unlock[0]
                item = '%s(%s) 解锁[%s] 产出门: %s 需[%s]' % (bid, name, unlock_era, gid, eras[k[0]])
                (errors if gap > 0 else warnings).append(item)
        for rid in d['resource_ids']:
            k = group_key(resources.get(rid, {}).get('tags', []))
            if k == 'UNKNOWN':
                errors.append('%s(%s) 资源 %s 引用未知科技' % (bid, name, rid))
            elif k and k > unlock:
                gap = k[0] - unlock[0]
                item = '%s(%s) 解锁[%s] 资源门: %s 需[%s]' % (bid, name, unlock_era, rid, eras[k[0]])
                (errors if gap > 0 else warnings).append(item)
        # required 晚于主解锁 → 设计语言（direct=主题归属），跨 ≥2 时代才算 error
        for t in req:
            if finish(t)[0] - min(finish(x)[0] for x in direct) >= 2:
                warnings.append('%s(%s) 主解锁[%s] required=%s[%s] 相差 >= 2 时代（主题归属模式，建议核对）'
                                % (bid, name, eras[min(finish(x)[0] for x in direct)], t, tech[t]['era_id']))

    # ---- 绑定漂移 ----
    actual = {}
    for bid, d, direct in buildings:
        for tag in direct:
            actual.setdefault(tag, set()).add((2, bid))
    for gid, g in goods.items():
        for tag in g['tags']:
            actual.setdefault(tag, set()).add((1, gid))
    for rid, r in resources.items():
        for tag in r['tags']:
            actual.setdefault(tag, set()).add((3, rid))
    for n in data['nodes']:
        exp = set((int(b['kind']), b['id']) for b in n.get('expected_bindings', []))
        act = actual.get(n['id'], set())
        if exp != act:
            errors.append('绑定漂移 %s: 授权=%s 实际=%s' % (n['id'], sorted(exp), sorted(act)))

    # ---- rationale 长度契约 ----
    for n in data['nodes']:
        if len(n.get('hard_prerequisite_ids', [])) != len(n.get('prerequisite_rationales', [])):
            errors.append('rationale 失配 %s: %d 前置 vs %d 理由'
                          % (n['id'], len(n.get('hard_prerequisite_ids', [])),
                             len(n.get('prerequisite_rationales', []))))

    lines = ['# 解锁对齐审计（解锁即可建）', '',
             'error %d | warning %d | 建筑 %d | 货物 %d | 科技 %d'
             % (len(errors), len(warnings), len(buildings), len(goods), len(tech)), '',
             '## errors']
    lines += ['- ' + e for e in errors] or ['- 无']
    lines += ['', '## warnings']
    lines += ['- ' + w for w in warnings] or ['- 无']
    text = '\n'.join(lines) + '\n'
    open(REPORT_PATH, 'w', encoding='utf-8').write(text)
    print(text)
    print('报告: %s' % REPORT_PATH)
    if check_only and errors:
        sys.exit(1)


if __name__ == '__main__':
    main()
