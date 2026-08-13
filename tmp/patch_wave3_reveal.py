#!/usr/bin/env python3
"""Patch wave-3 cloned era-dump reveal conditions from EXPLICIT_EVIDENCE_BY_TECH."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes")
AUTHORING = ROOT / "Project/project-keynes/tools/build_technology_network_authoring.gd"
PATH = ROOT / "Project/project-keynes/data/technology/technology_network.json"

WAVE3_START = "tech.guild_organization"
WAVE3_END = "tech.industrial_research"


def load_wave3_evidence() -> dict[str, list[str]]:
    text = AUTHORING.read_text(encoding="utf-8")
    start = text.find('"%s":' % WAVE3_START)
    end = text.find('"%s":' % WAVE3_END)
    if start < 0 or end < 0:
        raise SystemExit("wave3 markers missing in authoring script")
    end = text.find("\n", end)
    block = text[start:end]
    evidence: dict[str, list[str]] = {}
    for match in re.finditer(r'"([^"]+)": \[([^\]]*)\]', block):
        tech_id = match.group(1)
        signals = re.findall(r'"([^"]+)"', match.group(2))
        evidence[tech_id] = signals
    if WAVE3_START not in evidence or WAVE3_END not in evidence:
        raise SystemExit("failed to parse wave3 evidence")
    return evidence


def any_of(signals: list[str]) -> dict:
    return {
        "operator": 2,
        "children": [{"kind": 1, "id": sid, "value": 1} for sid in signals],
    }


def dump_block(spec: dict, indent: str) -> str:
    dumped = json.dumps(spec, ensure_ascii=False, indent="\t")
    lines = dumped.split("\n")
    return lines[0] + "\n" + "\n".join(indent + line for line in lines[1:])


def replace_object_after(text: str, key_idx: int) -> tuple[int, int]:
    brace = text.find("{", key_idx)
    depth = 0
    for i in range(brace, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return brace, i + 1
    raise RuntimeError("unbalanced braces")


def main() -> None:
    evidence = load_wave3_evidence()
    text = PATH.read_text(encoding="utf-8")
    for tech_id, signals in evidence.items():
        needle = f'"id": "{tech_id}"'
        idx = text.find(needle)
        if idx < 0:
            raise SystemExit(f"missing {tech_id}")
        key = '"reveal_condition":'
        ridx = text.find(key, idx)
        next_id = text.find('\n\t\t{\n\t\t\t"id":', idx + len(needle))
        if next_id != -1 and ridx > next_id:
            raise SystemExit(f"reveal_condition not in {tech_id}")
        brace, end = replace_object_after(text, ridx)
        old = json.loads(text[brace:end])
        if int(old.get("operator", -1)) == 1:
            new_children = []
            replaced = False
            for child in old.get("children", []):
                if int(child.get("kind", -1)) == 0:
                    new_children.append(child)
                else:
                    new_children.append(any_of(signals))
                    replaced = True
            if not replaced:
                new_children.append(any_of(signals))
            new_spec = {"operator": 1, "children": new_children}
        else:
            new_spec = any_of(signals)
        line_start = text.rfind("\n", 0, ridx) + 1
        indent = text[line_start:ridx]
        text = text[:brace] + dump_block(new_spec, indent) + text[end:]
        print(f"patched {tech_id} -> {signals}")
    PATH.write_text(text, encoding="utf-8", newline="\n")
    print("ok", PATH, "count", len(evidence))


if __name__ == "__main__":
    main()
