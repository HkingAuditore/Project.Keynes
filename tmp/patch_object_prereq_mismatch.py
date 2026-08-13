#!/usr/bin/env python3
"""Retarget same-lane sequential hard prereqs onto the node's own object chain."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "Project/project-keynes/data/technology/technology_network.json"

HARD = {
    "tech.latex_smoke_coagulation": ["tech.rubber_working"],
    "tech.cotton_ginning": ["tech.settled_knowledge", "tech.wild_cotton_collection"],
    "tech.dairy_processing": ["tech.settled_knowledge", "tech.herd_management"],
    "tech.hide_tanning": ["tech.settled_knowledge", "tech.herd_management"],
    "tech.wool_husbandry": ["tech.settled_knowledge", "tech.herd_management"],
    "tech.meat_processing": ["tech.settled_knowledge", "tech.herd_management"],
    "tech.early_glassmaking": ["tech.kiln_firing"],
    "tech.flint_identification": [],
    "tech.gold_placer_identification": [],
    "tech.silver_vein_identification": [],
    "tech.clay_identification": [],
    "tech.ground_stone_tools": ["tech.stone_knapping"],
    "tech.ridge_tuber_cultivation": ["tech.settled_knowledge", "tech.tuber_storage"],
    "tech.coal_adit_mining": ["tech.surface_coal_collection"],
    "tech.tenant_cereal_farming": ["tech.seed_selection"],
}

REMOVE_HARD_EDGES = [
    ("tech.spice_shade_gardening", "tech.latex_smoke_coagulation"),
    ("tech.hand_spinning", "tech.cotton_ginning"),
    ("tech.horse_domestication", "tech.dairy_processing"),
    ("tech.dairy_processing", "tech.hide_tanning"),
    ("tech.hide_tanning", "tech.wool_husbandry"),
    ("tech.wool_husbandry", "tech.meat_processing"),
    ("tech.adobe_making", "tech.early_glassmaking"),
    ("tech.earth_building", "tech.flint_identification"),
    ("tech.freshwater_fishing", "tech.gold_placer_identification"),
    ("tech.seasonal_calendar", "tech.silver_vein_identification"),
    ("tech.stone_knapping", "tech.clay_identification"),
    ("tech.clay_identification", "tech.ground_stone_tools"),
    ("tech.terrace_farming", "tech.ridge_tuber_cultivation"),
    ("tech.blast_furnace", "tech.coal_adit_mining"),
    ("tech.fermentation", "tech.tenant_cereal_farming"),
]

ADD_HARD_EDGES = [
    ("tech.rubber_working", "tech.latex_smoke_coagulation"),
    ("tech.settled_knowledge", "tech.cotton_ginning"),
    ("tech.wild_cotton_collection", "tech.cotton_ginning"),
    ("tech.settled_knowledge", "tech.dairy_processing"),
    ("tech.herd_management", "tech.dairy_processing"),
    ("tech.settled_knowledge", "tech.hide_tanning"),
    ("tech.herd_management", "tech.hide_tanning"),
    ("tech.settled_knowledge", "tech.wool_husbandry"),
    ("tech.herd_management", "tech.wool_husbandry"),
    ("tech.settled_knowledge", "tech.meat_processing"),
    ("tech.herd_management", "tech.meat_processing"),
    ("tech.kiln_firing", "tech.early_glassmaking"),
    ("tech.stone_knapping", "tech.ground_stone_tools"),
    ("tech.settled_knowledge", "tech.ridge_tuber_cultivation"),
    ("tech.tuber_storage", "tech.ridge_tuber_cultivation"),
    ("tech.surface_coal_collection", "tech.coal_adit_mining"),
    ("tech.seed_selection", "tech.tenant_cereal_farming"),
]


def format_hard(prereqs: list[str]) -> str:
    if not prereqs:
        return "[]"
    inner = ",\n".join(f'\t\t\t\t"{item}"' for item in prereqs)
    return "[\n" + inner + "\n\t\t\t]"


def replace_hard(text: str, tech_id: str, prereqs: list[str]) -> str:
    id_token = f'"id": "{tech_id}"'
    start = text.find(id_token)
    if start < 0:
        raise SystemExit(f"missing node {tech_id}")
    hard_key = '"hard_prerequisite_ids":'
    hard_at = text.find(hard_key, start)
    next_id = text.find('\n\t\t{\n\t\t\t"id":', start + 1)
    if next_id < 0:
        next_id = len(text)
    if hard_at < 0 or hard_at > next_id:
        raise SystemExit(f"hard_prerequisite_ids missing for {tech_id}")
    bracket = text.find("[", hard_at)
    depth = 0
    end = bracket
    for i, ch in enumerate(text[bracket:], bracket):
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    return text[:bracket] + format_hard(prereqs) + text[end:]


def edge_block(frm: str, to: str, kind: str) -> str:
    return (
        "\t\t{\n"
        f'\t\t\t"from": "{frm}",\n'
        f'\t\t\t"to": "{to}",\n'
        f'\t\t\t"kind": "{kind}"\n'
        "\t\t}"
    )


def remove_edge(text: str, frm: str, to: str, kind: str) -> str:
    block = edge_block(frm, to, kind)
    if block + "," in text:
        return text.replace(block + ",\n", "", 1)
    if ",\n" + block in text:
        return text.replace(",\n" + block, "", 1)
    raise SystemExit(f"missing edge {frm} -> {to} {kind}")


def insert_hard_after_existing(text: str, frm: str, to: str) -> str:
    block = edge_block(frm, to, "hard")
    if block in text:
        return text
    token = f'\t\t\t"from": "{frm}",'
    last = text.rfind(token)
    if last < 0:
        raise SystemExit(f"no existing edge from {frm} to attach {to}")
    brace = text.find("{", text.rfind("\n", 0, last))
    depth = 0
    end = brace
    for i, ch in enumerate(text[brace:], brace):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    return text[:end] + ",\n" + block + text[end:]


def main() -> None:
    text = NETWORK.read_text(encoding="utf-8")
    for tech_id, prereqs in HARD.items():
        text = replace_hard(text, tech_id, prereqs)
    for frm, to in REMOVE_HARD_EDGES:
        text = remove_edge(text, frm, to, "hard")
    for frm, to in ADD_HARD_EDGES:
        text = insert_hard_after_existing(text, frm, to)
    NETWORK.write_text(text, encoding="utf-8")

    data = json.loads(NETWORK.read_text(encoding="utf-8"), strict=False)
    by = {n["id"]: n for n in data["nodes"]}
    for tech_id, prereqs in HARD.items():
        got = list(by[tech_id].get("hard_prerequisite_ids") or [])
        if got != prereqs:
            raise SystemExit(f"verify hard failed {tech_id}: {got} != {prereqs}")
    visual_hard = {
        (e["from"], e["to"])
        for e in data["visual_edges"]
        if e.get("kind") == "hard"
    }
    node_hard = set()
    for n in data["nodes"]:
        for hid in n.get("hard_prerequisite_ids") or []:
            node_hard.add((hid, n["id"]))
    if visual_hard != node_hard:
        print("visual - node", sorted(visual_hard - node_hard)[:20])
        print("node - visual", sorted(node_hard - visual_hard)[:20])
        raise SystemExit("hard edge mismatch")
    kinds = {}
    for e in data["visual_edges"]:
        kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    print(
        f"patched ok hard={len(node_hard)} visual={len(data['visual_edges'])} "
        f"kinds={kinds}"
    )


if __name__ == "__main__":
    main()
