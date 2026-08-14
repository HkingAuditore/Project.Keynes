#!/usr/bin/env python3
"""Build the crayon topology atlas from the authoritative technology network.

Reads data/technology/technology_network.json and writes a self-contained HTML
atlas. The atlas is an inspection drawing only: it does not participate in
catalog compilation, country research state, or the in-game TechnologyWorkspace.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_NETWORK = PROJECT / "data" / "technology" / "technology_network.json"
DEFAULT_TEMPLATE = PROJECT / "tools" / "technology_tree" / "technology_tree_topology_template.html"
DEFAULT_OUTPUT = PROJECT / "tools" / "technology_tree" / "technology_tree_topology.html"
PLACEHOLDER = "__TECHNOLOGY_TREE_DATA__"

LANE_GROUPS = [
    ("backbone", "公共主干", (
        "backbone.food_storage",
        "backbone.tools_machinery",
        "backbone.knowledge_computation",
        "backbone.institutions_exchange",
    )),
    ("agro", "农业与生物", (
        "branch.maize_horticulture",
        "branch.wheat_rainfed",
        "branch.rice_irrigation",
        "branch.tuber_highland",
        "branch.pastoral_livestock",
        "branch.tropical_commodities",
        "branch.forest_biomass",
        "branch.natural_history",
    )),
    ("materials", "材料与工业", (
        "branch.textile_fibers",
        "branch.construction_materials",
        "branch.nonferrous_metals",
        "branch.heavy_industry",
        "branch.industrial_chemistry",
        "branch.petroleum_materials",
    )),
    ("energy", "能源与运输", (
        "branch.maritime_logistics",
        "branch.water_wind",
        "branch.electric_intelligent_energy",
    )),
    ("institution", "制度与劳动", (
        "branch.land_institutions",
        "branch.commerce_finance",
        "branch.labor_management",
    )),
    ("knowledge", "知识与控制", (
        "branch.measurement_instruments",
        "branch.public_health",
        "branch.geoscience_gis",
        "branch.computation_control",
    )),
]


def _lane_meta() -> dict[str, tuple[str, str, str]]:
    out: dict[str, tuple[str, str, str]] = {}
    for group_id, group_name, lane_ids in LANE_GROUPS:
        for lane_id in lane_ids:
            kind = "backbone" if lane_id.startswith("backbone.") else "branch"
            out[lane_id] = (kind, group_id, group_name)
    return out


def _unlocks(row: dict) -> dict:
    buildings, goods, resources = [], [], []
    for effect in row.get("content_effects", []):
        record = {
            "id": str(effect.get("id", "")),
            "name": str(effect.get("display_name") or effect.get("id") or ""),
        }
        kind = str(effect.get("kind", ""))
        if kind == "building":
            buildings.append(record)
        elif kind == "good":
            goods.append(record)
        elif kind == "resource":
            resources.append(record)
    return {
        "buildings": buildings,
        "goods": goods,
        "resources": resources,
        "support_buildings": [
            {"id": str(item.get("id", "")), "name": str(item.get("name") or item.get("id") or "")}
            for item in row.get("support_buildings", [])
        ],
    }


def _route_lines(row: dict) -> list[dict]:
    lines = []
    for route in row.get("research_routes", []):
        name = str(route.get("display_name") or route.get("id") or "")
        description = str(route.get("description") or "")
        lines.append({"depth": 0, "text": name})
        if description:
            lines.append({"depth": 1, "text": description})
    return lines


def build_payload(network: dict) -> dict:
    lane_meta = _lane_meta()
    nodes_by_id = {row["id"]: row for row in network["nodes"]}
    lanes = []
    for _group_id, _group_name, lane_ids in LANE_GROUPS:
        for lane_id in lane_ids:
            kind, group_id, group_name = lane_meta[lane_id]
            source = next(
                (row for row in list(network.get("backbones", [])) + list(network.get("branch_families", []))
                 if row["id"] == lane_id),
                None,
            )
            lanes.append({
                "id": lane_id,
                "display_name": source["display_name"] if source else lane_id,
                "kind": kind,
                "group": group_id,
                "group_name": group_name,
            })

    edges = [
        {"from": edge["from"], "to": edge["to"], "kind": edge["kind"]}
        for edge in network.get("visual_edges", [])
        if edge.get("kind") in {"hard", "alternative", "application", "milestone_candidate"}
    ]
    hard_successors: dict[str, list[str]] = {row["id"]: [] for row in network["nodes"]}
    for edge in edges:
        if edge["kind"] != "hard":
            continue
        hard_successors.setdefault(edge["from"], []).append(edge["to"])

    compact_nodes = []
    unknown_lanes = []
    for row in network["nodes"]:
        lane_id = str(row.get("branch_family_id") or row.get("layout_lane") or "")
        if lane_id not in lane_meta:
            unknown_lanes.append(row["id"])
        reveal_summary = str(row.get("reveal_summary") or "")
        compact_nodes.append({
            "id": row["id"],
            "display_name": row["display_name"],
            "era_id": row["era_id"],
            "domain_id": row["domain_id"],
            "cost_points": int(row.get("cost_points") or 0),
            "prerequisite_ids": list(row.get("hard_prerequisite_ids") or []),
            "prerequisite_rationales": list(row.get("prerequisite_rationales") or []),
            "hard_successor_ids": hard_successors.get(row["id"], []),
            "hard_successor_rationales": [],
            "layout_lane": lane_id,
            "network_role": row.get("network_role", "branch"),
            "anchor_kind": row.get("anchor_kind", ""),
            "node_role": row.get("node_role", ""),
            "effect_profile": row.get("effect_profile", ""),
            "effect_summary": row.get("effect_summary", ""),
            "opportunity_cost": row.get("opportunity_cost", ""),
            "terminal_reason": row.get("terminal_reason", ""),
            "is_milestone": bool(row.get("is_milestone")),
            "is_era_key": bool(row.get("is_era_key")),
            "is_starting": bool(row.get("is_starting")),
            "is_starter_eligible": bool(row.get("is_starter_eligible")),
            "route_tags": list(row.get("secondary_route_tags") or []),
            "route_display_names": [],
            "reveal_condition_lines": (
                [{"depth": 0, "text": reveal_summary}] if reveal_summary else []
            ),
            "condition_lines": _route_lines(row),
            "modifier_terms": list(row.get("modifier_terms") or []),
            "content_effects": list(row.get("content_effects") or []),
            "unlocks": _unlocks(row),
            "application_target_ids": list(row.get("application_target_ids") or []),
            "application_target_rationales": list(row.get("application_target_rationales") or []),
            "branch_successor_ids": list(row.get("branch_successor_ids") or []),
            "branch_successor_rationales": list(row.get("branch_successor_rationales") or []),
            "milestone_candidate_ids": list(row.get("milestone_candidate_ids") or []),
            "milestone_required_count": int(row.get("milestone_required_count") or 0),
            "starter_capability_tags": list(row.get("starter_capability_tags") or []),
        })
    if unknown_lanes:
        raise SystemExit(f"nodes_missing_lane_group: {', '.join(unknown_lanes[:12])}")

    era_records = []
    for era in network["eras"]:
        members = [node for node in compact_nodes if node["era_id"] == era["id"]]
        costs = [node["cost_points"] for node in members] or [0]
        era_records.append({
            "id": era["id"],
            "display_name": era["display_name"],
            "milestone_id": era.get("milestone_id", ""),
            "node_count": len(members),
            "min_cost": min(costs),
            "max_cost": max(costs),
        })

    kinds = Counter(edge["kind"] for edge in edges)
    intra = 0
    cross = 0
    for edge in edges:
        if edge["kind"] != "hard":
            continue
        src = nodes_by_id[edge["from"]]
        dst = nodes_by_id[edge["to"]]
        src_lane = src.get("branch_family_id") or src.get("layout_lane")
        dst_lane = dst.get("branch_family_id") or dst.get("layout_lane")
        if src_lane == dst_lane:
            intra += 1
        else:
            cross += 1
    return {
        "source": "data/technology/technology_network.json",
        "schema_version": network.get("schema_version"),
        "eras": era_records,
        "domains": [
            {"id": row["id"], "display_name": row["display_name"], "accent": row.get("accent", "#d4a44a")}
            for row in network["domains"]
        ],
        "lanes": lanes,
        "nodes": compact_nodes,
        "edges": edges,
        "stats": {
            "nodes": len(compact_nodes),
            "eras": len(network["eras"]),
            "backbones": 4,
            "branches": 24,
            "hard": kinds["hard"],
            "alternative": kinds["alternative"],
            "application": kinds["application"],
            "milestone_candidate": kinds["milestone_candidate"],
            "intra_lane": intra,
            "cross_lane": cross,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", type=Path, default=DEFAULT_NETWORK)
    parser.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    network = json.loads(args.network.read_text(encoding="utf-8"))
    payload = build_payload(network)
    template = args.template.read_text(encoding="utf-8")
    if template.count(PLACEHOLDER) != 1:
        raise SystemExit(f"template_placeholder_invalid: {args.template}")
    html = template.replace(PLACEHOLDER, json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    args.output.write_text(html, encoding="utf-8")
    stats = payload["stats"]
    print(
        f"[PASS] technology topology atlas: {stats['nodes']} nodes / "
        f"{stats['hard']} hard edges -> {args.output}"
    )


if __name__ == "__main__":
    main()
