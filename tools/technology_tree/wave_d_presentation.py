"""Wave D: de-duplicated effect summaries and a Python mirror of the schema-v4 normalizer.

* A good unlock is shown in the summary only when no hard ancestor already permits
  that good (``summary_visible: false`` otherwise).  The binding itself stays, so
  catalog content bindings and production permits are unchanged.
* ``effect_summary`` and ``visual_edges`` are rebuilt with the same rules as
  ``TechnologyNetworkValidator.effect_summary`` / ``build_visual_edges``.
* Reports formal technologies that lost every consumer.

Usage: python wave_d_presentation.py [--apply]
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from techtree_lib import (BUILDINGS_DIR, GOODS_DIR, NETWORK_PATH, PROJECT, RESOURCES_DIR, Model,
                          dump_json)

MODIFIER_SUBJECT_NAMES = {
    "country.climate.cold_stress_factor": "寒冷损失",
    "country.climate.drought_loss_factor": "旱灾损失",
    "country.climate.flood_loss_factor": "洪灾损失",
    "country.climate.heat_stress_factor": "热害损失",
    "country.construction.cost_factor": "国家建设成本",
    "country.output.agriculture_factor": "农业部门产出",
    "country.output.energy_factor": "能源部门产出",
    "country.output.extractive_factor": "采掘部门产出",
    "country.output.knowledge_factor": "知识部门产出",
    "country.output.manufacturing_factor": "制造部门产出",
    "country.research.agriculture_efficiency": "农业领域研究效率",
    "country.research.engineering_efficiency": "工程领域研究效率",
    "country.research.science_efficiency": "科学领域研究效率",
    "country.research.society_efficiency": "社会领域研究效率",
    "country.research.institution_output_factor": "科研机构产出",
    "country.trade.capacity_factor": "国内贸易容量",
    "country.trade.speed_factor": "贸易速度",
}
ALLOWED_EDGE_KINDS = ("hard", "alternative", "application", "branch", "milestone_candidate")


def modifier_subject(term: dict) -> str:
    stat = str(term.get("stat", ""))
    subject = str(term.get("subject_display_name", "")).strip() or MODIFIER_SUBJECT_NAMES.get(stat, stat)
    if stat.startswith("country.output.family."):
        return "「%s」生产家族建筑产出" % subject
    if stat.startswith("country.output.building."):
        return "建筑「%s」产出" % subject
    if stat.startswith("country.output.good."):
        return "商品「%s」产量" % subject
    if stat.startswith("country.output.terrain.") or stat.startswith("country.output.landform."):
        return "地理专长「%s」产出" % subject
    if stat.startswith("country.input.good."):
        return "商品「%s」生产投入" % subject
    if stat.startswith("country.consumption.good."):
        return "商品「%s」家庭消费" % subject
    return subject


def modifier_delta(term: dict) -> str:
    operation = int(term.get("operation", 0))
    value = float(term.get("value", 0.0))
    delta = value
    if operation == 1:
        delta = -value
    elif operation == 2:
        delta = value - 1.0
    elif operation == 3:
        delta = (1.0 / value - 1.0) if value != 0 else 0.0
    percent = delta * 100.0
    amount = ("%.1f" % abs(percent)).rstrip("0").rstrip(".")
    return "%s%s%%" % ("+" if percent >= 0.0 else "-", amount)


def effect_summary(node: dict) -> str:
    parts, seen = [], set()
    for effect in node.get("content_effects", []):
        if str(effect.get("operation", "")) != "unlock" or effect.get("summary_visible", True) is False:
            continue
        prefix = {"building": "解锁建筑", "good": "解锁物资", "resource": "可利用资源"}.get(
            str(effect.get("kind", "")))
        if prefix is None:
            continue
        text = "%s：%s" % (prefix, effect.get("display_name", effect.get("id", "")))
        if text not in seen:
            seen.add(text)
            parts.append(text)
    for term in node.get("modifier_terms", []):
        text = "%s %s" % (modifier_subject(term), modifier_delta(term))
        if text not in seen:
            seen.add(text)
            parts.append(text)
    names = []
    for support in node.get("support_buildings", []):
        name = str(support.get("name", support.get("id", "")))
        if name and name not in names:
            names.append(name)
    if names:
        parts.append("作为必要支撑：" + "、".join(names))
    if not parts:
        return "完成时代里程碑并开放下一时代" if node.get("is_milestone") else ""
    return "；".join(parts)


def collect_techs(cond, out: list) -> None:
    if not cond:
        return
    if "kind" in cond:
        if int(cond["kind"]) == 0 and cond["id"] not in out:
            out.append(cond["id"])
        return
    for child in cond.get("children", []):
        collect_techs(child, out)


def build_visual_edges(network: dict) -> list:
    nodes = network["nodes"]
    out, seen = [], set()

    def add(source, target, kind, route_id=""):
        if not source or not target or source == target or kind not in ALLOWED_EDGE_KINDS:
            return
        key = (kind, source, target, route_id)
        if key in seen:
            return
        seen.add(key)
        edge = {"from": source, "to": target, "kind": kind}
        if route_id:
            edge["route_id"] = route_id
        out.append(edge)

    for node in nodes:
        target = node["id"]
        for source in node.get("hard_prerequisite_ids", []):
            add(source, target, "hard")
        for route in node.get("research_routes", []):
            techs: list = []
            collect_techs(route.get("condition", {}), techs)
            for source in techs:
                add(source, target, "alternative", route.get("id", ""))
        for successor in node.get("branch_successor_ids", []):
            add(target, successor, "branch")
        for application in node.get("application_target_ids", []):
            add(target, application, "application")
    for era in network["eras"]:
        for candidate in era.get("milestone_candidate_ids", []):
            add(candidate, era.get("milestone_id", ""), "milestone_candidate")
    order = {n["id"]: i for i, n in enumerate(nodes)}
    out.sort(key=lambda e: "%08d|%08d|%s" % (order.get(e["from"], 1 << 29),
                                             order.get(e["to"], 1 << 29), e["kind"]))
    return out


MANIFEST_PATH = PROJECT / "tools" / "technology_tree" / "technology_industry_v2_stable_id_manifest.json"


def _sha256_files(pairs) -> str:
    """Mirrors migrate_technology_industry_v2.gd::_sha256_files (res:// path + NUL + bytes + NUL)."""
    context = hashlib.sha256()
    for res_path, disk_path in pairs:
        context.update(res_path.encode("utf-8") + b"\0")
        context.update(disk_path.read_bytes() + b"\0")
    return context.hexdigest()


def _id_hash(ids: list) -> str:
    return hashlib.sha256(("\n".join(ids) + "\n").encode("utf-8")).hexdigest()


def _dir_pairs(res_dir: str, disk_dir) -> list:
    names = sorted(p.name for p in disk_dir.glob("*.tres"))
    return [("%s/%s" % (res_dir, name), disk_dir / name) for name in names]


def build_manifest(model: Model) -> dict:
    technology_ids = sorted(n["id"] for n in model.nodes)
    application_ids = sorted(a["id"] for a in model.network["application_intersections"])
    building_ids = sorted(model.buildings)
    good_ids = sorted(model.goods)
    resource_ids = sorted(model.resources)
    hashes = {
        "technology_sha256": _sha256_files([("res://data/technology/technology_network.json",
                                             NETWORK_PATH)]),
        "buildings_sha256": _sha256_files(_dir_pairs("res://data/economy/buildings", BUILDINGS_DIR)),
        "goods_sha256": _sha256_files(_dir_pairs("res://data/goods", GOODS_DIR)),
        "resources_sha256": _sha256_files(_dir_pairs("res://data/resources", RESOURCES_DIR)),
    }
    combined = "technology:%s\nbuildings:%s\ngoods:%s\nresources:%s\n" % (
        hashes["technology_sha256"], hashes["buildings_sha256"], hashes["goods_sha256"],
        hashes["resources_sha256"])
    hashes["combined_sha256"] = hashlib.sha256(combined.encode("utf-8")).hexdigest()
    return {
        "schema_version": 1, "technology_industry_revision": 2,
        "technology_network_schema_version": int(model.network.get("schema_version", 0)),
        "technology_ids": technology_ids, "application_ids": application_ids,
        "building_ids": building_ids, "good_ids": good_ids, "resource_ids": resource_ids,
        "counts": {"technologies": len(technology_ids), "applications": len(application_ids),
                   "buildings": len(building_ids), "goods": len(good_ids),
                   "resources": len(resource_ids)},
        "id_sha256": {"technologies": _id_hash(technology_ids),
                      "applications": _id_hash(application_ids),
                      "buildings": _id_hash(building_ids), "goods": _id_hash(good_ids),
                      "resources": _id_hash(resource_ids)},
        "content_sha256": hashes,
    }


def main() -> None:
    if "--verify-hash" in sys.argv:
        path = Path(sys.argv[-1])
        print(_sha256_files([("res://data/technology/technology_network.json", path)]))
        return
    model = Model()
    permitted = {}
    for node in model.nodes:
        permitted[node["id"]] = {b["id"] for b in node.get("expected_bindings", [])
                                 if int(b.get("kind", 0)) == 1}
    hidden = 0
    for node in model.nodes:
        ancestors = set(model.closure(node["id"])) - {node["id"]}
        earlier = {n["id"] for n in model.nodes if model.era(n["id"]) < model.era(node["id"])}
        known = set()
        for ancestor in ancestors | earlier:
            known |= permitted.get(ancestor, set())
        for effect in node.get("content_effects", []):
            if effect.get("kind") != "good":
                continue
            if effect["id"] in known:
                effect["summary_visible"] = False
                hidden += 1
            else:
                effect.pop("summary_visible", None)
    # "Necessary support" lists only direct downstream facilities (within one era);
    # later facilities are presented by their own defining technology.
    for node in model.nodes:
        era = model.era(node["id"])
        node["support_buildings"] = [
            s for s in node.get("support_buildings", [])
            if s["id"] in model.buildings
            and model.building_era(s["id"]) <= era + 1]
    herb = model.node.get("tech.medicinal_herb_identification")
    if herb is not None:
        if herb.get("building_unlock_review", {}).get("policy") not in ("single", "paired", "support_only"):
            herb["building_unlock_review"] = {
                "policy": "support_only",
                "rationale": "辨识节点只让国家认出野生药草，采集与栽培由后续科技开放。"}
        if not str(herb.get("reveal_summary", "")).strip():
            herb["reveal_summary"] = "在领土或可见地块目击野生药草后揭示。"
        if not str(herb.get("reveal_category", "")).strip():
            herb["reveal_category"] = "environment_observation"
    for node in model.nodes:
        node["effect_summary"] = effect_summary(node)
    model.network["visual_edges"] = build_visual_edges(model.network)
    # consumer audit (mirrors technology_real_consumer_missing)
    successors = model.successors()
    missing = []
    for node in model.nodes:
        formal = not (node.get("is_milestone") or node.get("is_starting") or node.get("is_starter_eligible"))
        has_consumer = any(node.get(k) for k in ("expected_bindings", "content_effects", "support_buildings",
                                                  "branch_successor_ids", "application_target_ids",
                                                  "modifier_terms"))
        if formal and not has_consumer and not successors.get(node["id"]):
            missing.append(node["id"])
    print("good summary entries hidden:", hidden)
    print("visual edges:", len(model.network["visual_edges"]),
          {k: sum(1 for e in model.network["visual_edges"] if e["kind"] == k) for k in ALLOWED_EDGE_KINDS})
    print("formal technologies without consumer:", missing)
    if "--apply" in sys.argv:
        dump_json(NETWORK_PATH, model.network)
        manifest = build_manifest(model)
        dump_json(MANIFEST_PATH, manifest)
        print("written; manifest counts", manifest["counts"])


if __name__ == "__main__":
    main()
