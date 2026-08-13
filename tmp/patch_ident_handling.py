#!/usr/bin/env python3
"""Surgical JSON patches for identification-handling prerequisites."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "Project/project-keynes/data/technology/technology_network.json"

HARD = {
    "tech.tuber_storage": ["tech.potato_identification"],
    "tech.wild_spice_collection": ["tech.spice_identification"],
    "tech.wild_latex_tapping": ["tech.rubber_identification"],
    "tech.clay_preparation": ["tech.clay_identification"],
    "tech.hand_pottery": ["tech.clay_preparation"],
    "tech.copper_ore_roasting": ["tech.copper_annealing"],
    "tech.spice_identification": [],
    "tech.rubber_identification": [],
    "tech.flax_identification": [],
    "tech.flax_retting": ["tech.settled_knowledge", "tech.flax_identification"],
    "tech.iron_ore_identification": ["tech.agrarian_society"],
    "tech.coal_outcrop_identification": ["tech.agrarian_society"],
}

REMOVE_HARD_EDGES = [
    ("tech.flint_identification", "tech.clay_preparation"),
    ("tech.wild_cotton_collection", "tech.spice_identification"),
    ("tech.wild_spice_collection", "tech.rubber_identification"),
    ("tech.fiber_twisting", "tech.flax_identification"),
    ("tech.loom_weaving", "tech.flax_retting"),
    ("tech.iron_smelting", "tech.iron_ore_identification"),
    ("tech.surface_iron_collection", "tech.coal_outcrop_identification"),
]

ADD_HARD_EDGES = [
    ("tech.potato_identification", "tech.tuber_storage"),
    ("tech.spice_identification", "tech.wild_spice_collection"),
    ("tech.rubber_identification", "tech.wild_latex_tapping"),
    ("tech.clay_identification", "tech.clay_preparation"),
    ("tech.clay_preparation", "tech.hand_pottery"),
    ("tech.copper_annealing", "tech.copper_ore_roasting"),
    ("tech.settled_knowledge", "tech.flax_retting"),
    ("tech.flax_identification", "tech.flax_retting"),
    ("tech.agrarian_society", "tech.iron_ore_identification"),
    ("tech.agrarian_society", "tech.coal_outcrop_identification"),
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


def replace_reveal_operator(text: str, tech_id: str, operator: int) -> str:
    id_token = f'"id": "{tech_id}"'
    start = text.find(id_token)
    next_id = text.find('\n\t\t{\n\t\t\t"id":', start + 1)
    block = text[start:next_id]
    old = '"reveal_condition": {\n\t\t\t\t"operator": 2,'
    new = f'"reveal_condition": {{\n\t\t\t\t"operator": {operator},'
    if old not in block:
        raise SystemExit(f"reveal operator 2 not found for {tech_id}")
    block2 = block.replace(old, new, 1)
    return text[:start] + block2 + text[next_id:]


def remove_reveal_child(text: str, tech_id: str, signal_id: str) -> str:
    id_token = f'"id": "{tech_id}"'
    start = text.find(id_token)
    next_id = text.find('\n\t\t{\n\t\t\t"id":', start + 1)
    block = text[start:next_id]
    pattern = (
        r',\n\t\t\t\t\t\{\n\t\t\t\t\t\t"kind": 1,\n\t\t\t\t\t\t"id": "'
        + re.escape(signal_id)
        + r'",\n\t\t\t\t\t\t"value": 1\n\t\t\t\t\t\}'
    )
    block2, n = re.subn(pattern, "", block, count=1)
    if n != 1:
        # child may be first
        pattern_first = (
            r'\{\n\t\t\t\t\t\t"kind": 1,\n\t\t\t\t\t\t"id": "'
            + re.escape(signal_id)
            + r'",\n\t\t\t\t\t\t"value": 1\n\t\t\t\t\t\},\n'
        )
        block2, n = re.subn(pattern_first, "", block, count=1)
    if n != 1:
        raise SystemExit(f"failed to remove {signal_id} from {tech_id}")
    return text[:start] + block2 + text[next_id:]


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
    # insert after the last existing edge from the same source
    token = f'\t\t\t"from": "{frm}",'
    last = text.rfind(token)
    if last < 0:
        raise SystemExit(f"no existing edge from {frm} to attach {to}")
    # find end of that edge object
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
    insert = ",\n" + block
    return text[:end] + insert + text[end:]


def main() -> None:
    text = NETWORK.read_text(encoding="utf-8")
    for tech_id, prereqs in HARD.items():
        text = replace_hard(text, tech_id, prereqs)
    text = replace_reveal_operator(text, "tech.copper_ore_roasting", 1)
    text = remove_reveal_child(text, "tech.brine_collection", "resource.clay")
    text = remove_reveal_child(text, "tech.controlled_burning", "resource.clay")
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
    roast = by["tech.copper_ore_roasting"]["reveal_condition"]
    if int(roast["operator"]) != 1:
        raise SystemExit(f"roast operator {roast['operator']}")
    brine_ids = [c["id"] for c in by["tech.brine_collection"]["reveal_condition"]["children"]]
    if "resource.clay" in brine_ids or set(brine_ids) != {"resource.salt", "resource.sulfur"}:
        raise SystemExit(f"brine signals {brine_ids}")
    fire_ids = [c["id"] for c in by["tech.controlled_burning"]["reveal_condition"]["children"]]
    if "resource.clay" in fire_ids:
        raise SystemExit(f"controlled_burning still has clay {fire_ids}")

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
    print(f"patched ok hard={len(node_hard)} visual_edges={len(data['visual_edges'])}")


if __name__ == "__main__":
    main()
