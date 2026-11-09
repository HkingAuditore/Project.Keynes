#!/usr/bin/env python3
"""Apply an explicit, reviewed content migration; audit the installed catalog.

This is an offline authoring tool. The game only reads technology_network.json
and its ordinary resource catalogs. No unlock/effect is inferred at runtime.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NETWORK = ROOT / "data/technology/technology_network.json"
REPORT = Path(__file__).with_name("technology_content_pacing_audit.md")
REVIEW_PLAN = Path(__file__).with_name("content_pacing_revision.json")


class Profile:
    def __init__(self, path):
        self.path = path
        self.text = path.read_text(encoding="utf-8")
        self.original = self.text
        self.fields = dict(re.findall(r"^(\w+) = (.*)$", self.text, re.M))
        self.id = self.strings("id")[0]
        self.name = (self.strings("display_name") or [self.id])[0]

    def strings(self, field):
        return [json.loads(m) for m in re.findall(r'"(?:[^"\\]|\\.)*"', self.fields.get(field, ""))]

    def ints(self, field):
        raw = self.fields.get(field, "")
        if "(" in raw:
            raw = raw[raw.index("(") + 1:raw.rindex(")")]
        return [int(v) for v in re.findall(r"-?\d+", raw)]

    def scalar(self, field, default=0):
        return int(self.fields.get(field, default))

    def tags(self, field="technology_tags"):
        return [t for t in self.strings(field) if t.startswith("tech.")]

    def set(self, field, value):
        line = f"{field} = {value}"
        if field in self.fields:
            self.text = re.sub(r"^" + field + r" = .*$", lambda _: line, self.text, flags=re.M)
        else:
            self.text = self.text.rstrip() + "\n" + line + "\n"
        self.fields[field] = value

    def set_strings(self, field, values):
        self.set(field, "PackedStringArray(" + ", ".join(json.dumps(v, ensure_ascii=False) for v in values) + ")")

    def save(self):
        if self.text != self.original:
            self.path.write_text(self.text, encoding="utf-8", newline="\n")


def profiles(relative):
    return {p.id: p for p in (Profile(f) for f in sorted((ROOT / relative).glob("*.tres")))}


def atoms(spec):
    if not isinstance(spec, dict):
        return []
    return ([spec["id"]] if spec.get("kind") == 0 else []) + [a for c in spec.get("children", []) for a in atoms(c)]


def without_core_atoms(spec, hard):
    if not spec:
        return None
    if spec.get("kind") == 0 and spec.get("id") in hard:
        return None
    if "children" not in spec:
        return spec
    result = copy.deepcopy(spec)
    children = [v for c in spec["children"] if (v := without_core_atoms(c, hard))]
    if not children:
        return None
    result["children"] = children
    if result.get("operator") == 2:
        result["required_count"] = min(int(result.get("required_count", 1)), len(children))
    return result


def strip_implied_prerequisites(spec, completed_ancestry):
    """Simplify a route after substituting its guaranteed hard ancestors."""
    if not spec:
        return True
    if spec.get("kind") == 0 and spec.get("id") in completed_ancestry:
        return True
    if "children" not in spec:
        return spec
    operator = int(spec.get("operator", 1))
    children = [strip_implied_prerequisites(child, completed_ancestry) for child in spec["children"]]
    if operator == 1:
        if any(child is None for child in children):
            return None
        remaining = [child for child in children if child is not True]
        if not remaining:
            return True
    elif operator == 2:
        if any(child is True for child in children):
            return True
        remaining = [child for child in children if child is not None]
        if not remaining:
            return None
    elif operator == 3:
        satisfied = sum(child is True for child in children)
        required = int(spec.get("required_count", 1)) - satisfied
        if required <= 0:
            return True
        remaining = [child for child in children if child is not None and child is not True]
        if required > len(remaining):
            return None
        spec = copy.deepcopy(spec)
        spec["required_count"] = required
    else:
        return {**spec, "children": children}
    if len(remaining) == 1:
        return remaining[0]
    result = copy.deepcopy(spec)
    result["children"] = remaining
    if operator == 2:
        result["required_count"] = min(int(result.get("required_count", 1)), len(remaining))
    return result


def ordered_nodes(network):
    nodes = {n["id"]: n for n in network["nodes"]}
    original = {n["id"]: i for i, n in enumerate(network["nodes"])}
    eras = {e["id"]: i for i, e in enumerate(network["eras"])}
    incoming = {id: set(n.get("hard_prerequisite_ids", [])) | set(atoms(n.get("reveal_condition", {}))) |
                {a for r in n.get("research_routes", []) for a in atoms(r.get("condition", {}))}
                for id, n in nodes.items()}
    result, done = [], set()
    while len(result) < len(nodes):
        ready = [id for id, deps in incoming.items() if id not in done and deps <= done]
        if not ready:
            raise ValueError("research dependency cycle: " + str({id: sorted(d - done) for id, d in incoming.items() if id not in done}))
        id = min(ready, key=lambda id: (eras[nodes[id]["era_id"]], original[id]))
        result.append(nodes[id])
        done.add(id)
    return result


def sync_bindings(network, buildings, goods, resources):
    """Mirror the real resources, including support gates, without inventing effects."""
    rows = {n["id"]: n for n in network["nodes"]}
    old_effects = {id: {(e.get("kind"), e.get("id")): e for e in n.get("content_effects", [])} for id, n in rows.items()}
    for n in rows.values():
        n["expected_bindings"] = []
        n["content_effects"] = [e for e in n.get("content_effects", []) if e.get("kind") not in ("building", "good", "resource")]
        n["support_buildings"] = []
    for kind, table, field, label, attribute, implementation in [
        (1, goods, "technology_tags", "good", "production_access", "GoodProfile.technology_tags"),
        (2, buildings, "technology_tags", "building", "construction_and_production_access", "BuildingProfile.technology_tags"),
        (3, resources, "discovery_technology_tags", "resource", "local_resource_access", "ResourceProfile.discovery_technology_tags"),
    ]:
        for p in table.values():
            for id in p.tags(field):
                n = rows[id]
                n["expected_bindings"].append({"kind": kind, "id": p.id})
                e = copy.deepcopy(old_effects[id].get((label, p.id), {}))
                e.update(kind=label, id=p.id, binding_kind=kind, subject=f"{label}.{p.id}", attribute=attribute,
                         operation="unlock", value=1, implementation=implementation, status="existing_binding", display_name=p.name)
                n["content_effects"].append(e)
    eras = {e["id"]: i for i, e in enumerate(network["eras"])}
    previous = {b: a for a in network.get("application_intersections", []) for b in a["building_ids"]}
    applications = []
    for b in buildings.values():
        for id in b.tags("required_technology_tags"):
            rows[id]["support_buildings"].append({"id": b.id, "name": b.name})
        gate = list(dict.fromkeys(b.tags() + b.tags("required_technology_tags")))
        if len(gate) < 2:
            continue
        old = previous.get(b.id, {})
        primary = rows[b.tags()[0]]
        latest = max(gate, key=lambda id: eras[rows[id]["era_id"]])
        applications.append({
            "id": old.get("id", "app." + b.id), "display_name": b.name,
            "description": f"{b.name}由{len(gate)}项已掌握知识自动形成，不消耗研究点。",
            "era_id": rows[latest]["era_id"], "domain_id": primary["domain_id"],
            "industry_chain_id": primary["branch_family_id"],
            "layout_order": float(primary.get("layout_order", 0)) + .01,
            "required_technology_ids": gate, "building_ids": [b.id],
        })
    network["application_intersections"] = sorted(applications, key=lambda a: (eras[a["era_id"]], a["layout_order"], a["id"]))


def migrate(network, plan, buildings, goods, resources):
    rows = {n["id"]: n for n in network["nodes"]}
    eras = {e["id"]: i for i, e in enumerate(network["eras"])}
    old_rationales = {id: dict(zip(n.get("hard_prerequisite_ids", []), n.get("prerequisite_rationales", []))) for id, n in rows.items()}
    for id, patch in plan.get("nodes", {}).items():
        rows[id].update(copy.deepcopy(patch["changes"]))
    for n in network["nodes"]:
        hard = set(n.get("hard_prerequisite_ids", []))
        for route in n.get("research_routes", []):
            route["condition"] = without_core_atoms(route.get("condition", {}), hard) or {}
        hard_ancestry = set(hard)
        frontier = list(hard)
        while frontier:
            prerequisite = frontier.pop()
            for ancestor in rows[prerequisite].get("hard_prerequisite_ids", []):
                if ancestor not in hard_ancestry:
                    hard_ancestry.add(ancestor)
                    frontier.append(ancestor)
        for route in n.get("research_routes", []):
            reduced = strip_implied_prerequisites(route.get("condition", {}), hard_ancestry)
            route["condition"] = reduced if isinstance(reduced, dict) else {}
        n["research_routes"] = [r for r in n.get("research_routes", []) if r["condition"]]
        if not n["research_routes"] and n.get("hard_prerequisite_ids"):
            n["route_exemption_reason"] = "候选替代条件均被不可替代前置知识蕴含；保留核心知识路径，省略冗余路线。"
        basis = n.get("knowledge_basis", {})
        # This is a knowledge index, not the executable route expression. The
        # catalog requires each indexed alternative once across all groups.
        alternative_seen = set(hard)
        groups = []
        for route in n.get("research_routes", []):
            group = []
            for technology in atoms(route["condition"]):
                if technology not in alternative_seen:
                    group.append(technology)
                    alternative_seen.add(technology)
            if group:
                groups.append(group)
        basis["alternative_groups"] = groups
        basis["required_ids"] = list(n.get("hard_prerequisite_ids", []))
        if basis["required_ids"] or basis["alternative_groups"]:
            basis["exemption_reason"] = ""
        if not basis.get("required_ids") and not basis.get("alternative_groups") and not basis.get("exemption_reason"):
            if hard:
                basis["required_ids"] = list(n["hard_prerequisite_ids"])
            elif n.get("node_role") == "identification":
                basis["exemption_reason"] = "对象辨识来自实际资源或生物目击，不以无关专业知识代替发现。"
        n["knowledge_basis"] = basis
    for era in network["eras"]:
        era.update(copy.deepcopy(plan.get("eras", {}).get(era["id"], {})))
    for id, patch in plan.get("buildings", {}).items():
        b = buildings[id]
        if "technology" in patch:
            b.set_strings("technology_tags", [t for t in b.strings("technology_tags") if not t.startswith("tech.")] + [patch["technology"]])
        if "required" in patch:
            b.set_strings("required_technology_tags", list(dict.fromkeys(t for t in patch["required"] if t not in b.tags())))
        for field, value in patch.get("fields", {}).items():
            b.set(field, value)
    for id, patch in plan.get("goods", {}).items():
        goods[id].set_strings("technology_tags", [t for t in goods[id].strings("technology_tags") if not t.startswith("tech.")] + patch["technologies"])
    # A good's production license follows its real producers; the first producer
    # no longer advertises a commodity before a corresponding method exists.
    producers = defaultdict(set)
    for b in buildings.values():
        for good in b.strings("output_good_ids"):
            producers[good].update(b.tags())
    order = {n["id"]: i for i, n in enumerate(network["nodes"])}
    for id, g in goods.items():
        if producers[id]:
            g.set_strings("technology_tags", [t for t in g.strings("technology_tags") if not t.startswith("tech.")] + sorted(producers[id], key=lambda t: order[t]))
    network["nodes"] = ordered_nodes(network)
    # Era metadata is descriptive; only milestones carry an era-entry gate in
    # the current runtime. This migration does not introduce universal era locks.
    for n in network["nodes"]:
        era = next(e for e in network["eras"] if e["id"] == n["era_id"])
        n["era_entry_milestone_id"] = era.get("entry_milestone_id", "")
    sync_bindings(network, buildings, goods, resources)
    for n in network["nodes"]:
        hard = n.get("hard_prerequisite_ids", [])
        reason = plan.get("nodes", {}).get(n["id"], {}).get("reason", "保留实际工艺的先验知识。")
        n["prerequisite_rationales"] = [old_rationales[n["id"]].get(t, f"{reason}；所需知识为「{rows[t]['display_name']}」。") for t in hard]
        unlocked = {(int(b["kind"]), b["id"]) for b in n["expected_bindings"]}
        kind_ids = {"good": 1, "building": 2, "resource": 3}
        has_building = any(k == 2 for k, _ in unlocked)
        n["modifier_terms"] = [term for term in n.get("modifier_terms", [])
                               if (kind_ids.get(term.get("subject_kind"), 0), term.get("subject_id")) not in unlocked
                               and not (has_building and n.get("network_role") == "branch" and term.get("stat") == "country.economy_output_factor")]
    # Previously available goods remain valid alternate producer licenses, but
    # their later methods should not repeatedly announce the same commodity.
    first_good_era = {g.id: min(eras[rows[t]["era_id"]] for t in g.tags()) for g in goods.values() if g.tags()}
    for n in network["nodes"]:
        for effect in n["content_effects"]:
            if effect.get("kind") == "good":
                effect["summary_visible"] = eras[n["era_id"]] == first_good_era.get(effect["id"])


def audit(network, buildings, goods, resources):
    rows = {n["id"]: n for n in network["nodes"]}
    eras = {e["id"]: i for i, e in enumerate(network["eras"])}
    errors = []
    actual_bindings = defaultdict(set)
    for kind, table, field in [(1, goods, "technology_tags"), (2, buildings, "technology_tags"), (3, resources, "discovery_technology_tags")]:
        for p in table.values():
            for id in p.tags(field):
                if id not in rows:
                    errors.append(f"unknown_technology {p.id}: {id}")
                actual_bindings[id].add((kind, p.id))
    for n in network["nodes"]:
        expected = {(int(b["kind"]), b["id"]) for b in n.get("expected_bindings", [])}
        if expected != actual_bindings[n["id"]]:
            errors.append(f"binding_drift {n['id']}: {sorted(expected ^ actual_bindings[n['id']])}")
        for id in n.get("hard_prerequisite_ids", []) + atoms(n.get("reveal_condition", {})) + [a for r in n.get("research_routes", []) for a in atoms(r.get("condition", {}))]:
            if id not in rows or eras[rows[id]["era_id"]] > eras[n["era_id"]]:
                errors.append(f"future_or_unknown_knowledge {n['id']}: {id}")
    ordered_nodes(network)
    app_by_building = {b: a for a in network.get("application_intersections", []) for b in a["building_ids"]}
    building_era = {}
    direct = defaultdict(list)
    for b in buildings.values():
        gate = set(b.tags() + b.tags("required_technology_tags"))
        if not gate:
            errors.append(f"no_building_gate {b.id}")
            continue
        era = max([min(eras[rows[t]["era_id"]] for t in b.tags())] + [eras[rows[t]["era_id"]] for t in b.tags("required_technology_tags")])
        building_era[b.id] = era
        for t in b.tags():
            direct[t].append(b)
        app = app_by_building.get(b.id)
        if len(gate) >= 2 and (not app or set(app["required_technology_ids"]) != gate or eras[app["era_id"]] != era):
            errors.append(f"application_drift {b.id}")
        if len(gate) == 1 and app:
            errors.append(f"single_gate_application {b.id}")
    # Supply timing is computed through actual mandatory-input and pooled-BOM
    # reachability. Geography, workforce, money and transport are intentionally
    # outside this theoretical catalog check; soft complements never block it.
    categories = defaultdict(set)
    for g in goods.values():
        for category in g.strings("substitution_category_ids") or g.strings("category_id"):
            categories[category].add(g.id)

    def candidates(b, slot, prefix):
        ids = b.strings(prefix + "_good_ids")
        offsets = b.ints(prefix + "_candidate_offsets")
        explicit = b.strings(prefix + "_candidate_good_ids")
        if len(offsets) == len(ids) + 1 and offsets[slot + 1] > offsets[slot]:
            return set(explicit[offsets[slot]:offsets[slot + 1]])
        cats, levels = b.strings(prefix + "_category_ids"), b.ints(prefix + "_min_quality_levels")
        if slot < len(cats) and cats[slot]:
            level = levels[slot] if slot < len(levels) else 0
            return {g for g in categories[cats[slot]] if goods[g].scalar("production_quality_level") >= level}
        return {ids[slot]}

    supply_era, usable_era = {}, {}
    for era in range(len(eras)):
        completed = {id for id, n in rows.items() if eras[n["era_id"]] <= era}
        stock = {g for g, e in supply_era.items() if e <= era}
        changed = True
        while changed:
            changed = False
            for b in buildings.values():
                if b.id in usable_era or building_era.get(b.id, 999) > era:
                    continue
                inputs = b.strings("input_good_ids")
                required = b.ints("input_required_q16")
                if any((required[i] if i < len(required) else 65536) >= 65536 and not candidates(b, i, "input") & stock for i in range(len(inputs))):
                    continue
                bill = b.strings("construction_good_ids")
                pool = set().union(*(candidates(b, i, "construction") for i in range(len(bill)))) if bill else set()
                if bill and not pool & stock and not any(rows[t].get("is_starter_eligible", False) for t in b.tags()):
                    continue
                outputs = b.strings("output_good_ids")
                if any(goods[g].tags() and not set(goods[g].tags()) & completed for g in outputs):
                    continue
                if any(resources[r].tags("discovery_technology_tags") and not set(resources[r].tags("discovery_technology_tags")) & completed for r in set(b.strings("resource_ids") + b.strings("resource_generation_ids"))):
                    continue
                usable_era[b.id] = era
                for g in outputs:
                    stock.add(g)
                    supply_era.setdefault(g, era)
                changed = True
    for g in goods.values():
        advertised = min((eras[rows[t]["era_id"]] for t in g.tags()), default=999)
        supplied = supply_era.get(g.id, 999)
        if advertised < supplied:
            errors.append(f"good_before_supply {g.id}: {advertised} -> {supplied}")
    for b in buildings.values():
        if usable_era.get(b.id, 999) > building_era.get(b.id, 999):
            errors.append(f"building_supply_delay {b.id}: {building_era.get(b.id)} -> {usable_era.get(b.id)}")
        for predecessor in b.strings("predecessor_building_ids"):
            if predecessor in building_era and building_era[predecessor] > building_era.get(b.id, 999):
                errors.append(f"progression_era_inversion {b.id}: {predecessor}")
    return errors, direct, building_era, supply_era


def report(network, buildings, goods, resources, baseline=None, plan=None):
    errors, direct, building_era, supply_era = audit(network, buildings, goods, resources)
    before = (plan or {}).get("before_research_counts") or Counter(n["era_id"] for n in (baseline or network)["nodes"])
    after = Counter(n["era_id"] for n in network["nodes"])
    lines = ["# 科技内容解锁曲线全量审查", "", "核查范围：实际研究目录、所有建筑/物资/资源档案与自动应用；不按旧报告推断。", "",
             f"- 研究科技：{len(network['nodes'])}；自动应用：{len(network.get('application_intersections', []))}；建筑：{len(buildings)}；物资：{len(goods)}；资源：{len(resources)}。",
             f"- 静态内容一致性与时代供应闭包：{'PASS' if not errors else 'FAIL'}（{len(errors)} 项）。",
             "- 闭包使用硬投入（required_q16=65536）、类别/显式替代、建材总OR池、产出许可、资源许可及开局预置豁免；软投入只降低产出，不算研究硬门。",
             "- 这是目录理论可达性：不证明具体地图、岗位、现金、运输和实际日期的产能。时代标签不会新增全局时代锁；运行时保持已有按知识与路线前进的机制。", "",
             "| 时代 | 调整前研究数 | 调整后研究数 | 辨识/零研究成本 | 首次可用建筑数 |", "|---|---:|---:|---:|---:|"]
    for i, e in enumerate(network["eras"]):
        ident = sum(n["era_id"] == e["id"] and (n.get("node_role") == "identification" or n.get("cost_points") == 0) for n in network["nodes"])
        lines.append(f"| {e['display_name']} | {before[e['id']]} | {after[e['id']]} | {ident} | {sum(v == i for v in building_era.values())} |")
    if errors:
        lines += ["", "## 未通过项", ""] + [f"- `{error}`" for error in errors]
    if plan:
        lines += ["", "## 逐项调整理由", ""]
        for kind in ("nodes", "buildings", "goods"):
            for id, p in plan.get(kind, {}).items():
                lines.append(f"- `{id}`：{p.get('reason', '')}")
    lines += ["", "## 全部研究科技核查", "", "完整进入条件、效果数值、取舍与后继见同目录生成的 technology_tree_report.md；此表逐项记录实际内容绑定。", "",
              "| 时代 | 科技 | 领域/角色 | 直接建筑 | 物资 | 资源 | 数值效果条数 | 支撑应用数 | 处理 |", "|---|---|---|---|---|---|---:|---:|---|"]
    names = {e["id"]: e["display_name"] for e in network["eras"]}
    for n in network["nodes"]:
        bindings = n.get("expected_bindings", [])
        by_kind = lambda k: "、".join(b["id"] for b in bindings if b["kind"] == k) or "—"
        reason = (plan or {}).get("nodes", {}).get(n["id"], {}).get("reason", "保留；核对绑定、研究引用与供应时代")
        lines.append(f"| {names[n['era_id']]} | {n['display_name']} `{n['id']}` | {n['domain_id']}/{n['network_role']} | {by_kind(2)} | {by_kind(1)} | {by_kind(3)} | {len(n.get('modifier_terms', []))} | {len(n.get('support_buildings', []))} | {reason} |")
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return errors


def refresh_manifest(network, buildings, goods, resources):
    """Use the same byte framing as migrate_technology_industry_v2.gd."""
    path = Path(__file__).with_name("technology_industry_v2_stable_id_manifest.json")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    ids = {"technology_ids": sorted(n["id"] for n in network["nodes"]),
           "application_ids": sorted(a["id"] for a in network["application_intersections"]),
           "building_ids": sorted(buildings), "good_ids": sorted(goods), "resource_ids": sorted(resources)}
    manifest.update(ids)
    keys = {"technologies": "technology_ids", "applications": "application_ids", "buildings": "building_ids", "goods": "good_ids", "resources": "resource_ids"}
    manifest["counts"] = {k: len(ids[v]) for k, v in keys.items()}
    manifest["id_sha256"] = {k: hashlib.sha256(("\n".join(ids[v]) + "\n").encode()).hexdigest() for k, v in keys.items()}
    hashes = {}
    for key, paths in {"technology": [NETWORK], "buildings": [b.path for b in buildings.values()],
                       "goods": [g.path for g in goods.values()], "resources": [r.path for r in resources.values()]}.items():
        digest = hashlib.sha256()
        for source in sorted(paths):
            digest.update(("res://" + source.relative_to(ROOT).as_posix()).encode())
            digest.update(b"\0")
            digest.update(source.read_bytes())
            digest.update(b"\0")
        hashes[key + "_sha256"] = digest.hexdigest()
    combined = "".join(f"{key}:{hashes[key + '_sha256']}\n" for key in ("technology", "buildings", "goods", "resources"))
    hashes["combined_sha256"] = hashlib.sha256(combined.encode()).hexdigest()
    manifest["content_sha256"] = hashes
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", type=Path, help="explicit reviewed patch; writes authoring data")
    parser.add_argument("--baseline", type=Path, help="optional original network for the review table")
    parser.add_argument("--review-plan", type=Path, default=REVIEW_PLAN, help="recorded rationale used by the report; does not apply changes")
    parser.add_argument("--refresh-manifest", action="store_true", help="refresh stable IDs and content fingerprints after Godot normalization")
    args = parser.parse_args()
    network = json.loads(NETWORK.read_text(encoding="utf-8"))
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else copy.deepcopy(network)
    buildings, goods, resources = profiles("data/economy/buildings"), profiles("data/goods"), profiles("data/resources")
    plan = json.loads(args.apply.read_text(encoding="utf-8")) if args.apply else None
    if plan:
        if args.baseline:
            network = copy.deepcopy(baseline)
        migrate(network, plan, buildings, goods, resources)
        for p in [*buildings.values(), *goods.values()]:
            p.save()
        NETWORK.write_text(json.dumps(network, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8", newline="\n")
        review = {"before_research_counts": plan.get("before_research_counts", {}),
                  "nodes": {id: {"reason": item.get("reason", "")} for id, item in plan.get("nodes", {}).items()},
                  "buildings": {id: {"reason": item.get("reason", "")} for id, item in plan.get("buildings", {}).items()},
                  "goods": {id: {"reason": item.get("reason", "")} for id, item in plan.get("goods", {}).items()}}
        REVIEW_PLAN.write_text(json.dumps(review, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8", newline="\n")
    review = plan or (json.loads(args.review_plan.read_text(encoding="utf-8")) if args.review_plan.exists() else None)
    errors = report(network, buildings, goods, resources, baseline, review)
    if args.refresh_manifest:
        if errors:
            raise ValueError("cannot refresh manifest while the content audit fails")
        refresh_manifest(network, buildings, goods, resources)
    print(f"content pacing: technologies={len(network['nodes'])} buildings={len(buildings)} goods={len(goods)} errors={len(errors)}")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
