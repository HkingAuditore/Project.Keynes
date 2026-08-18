#!/usr/bin/env python3
"""Surgically convert leftover zero-cost starter nodes to researchable nodes."""
from __future__ import annotations

import re
from pathlib import Path

NETWORK = Path(__file__).resolve().parents[1] / "Project" / "project-keynes" / "data" / "technology" / "technology_network.json"

LEFTOVER = [
    "tech.stone_knapping",
    "tech.fire_control",
    "tech.freshwater_fishing",
    "tech.coastal_fishing",
    "tech.earth_building",
    "tech.wild_tuber_collection",
    "tech.wild_flax_collection",
    "tech.deadwood_collection",
    "tech.reed_harvesting",
    "tech.turf_cutting",
    "tech.fur_sewing",
    "tech.felt_making",
    "tech.phenology_observation",
    "tech.flood_calendar_practice",
    "tech.pastoral_route_memory",
    "tech.tide_observation",
]

ORAL_REVEAL = '''			"reveal_condition": {
				"operator": 2.0,
				"children": [
					{
						"kind": 1.0,
						"id": "resource.fertile_soil",
						"value": 1.0
					},
					{
						"kind": 1.0,
						"id": "resource.wild_game",
						"value": 1.0
					}
				]
			},'''


def patch_node_fields(chunk: str) -> str:
    chunk = re.sub(r'"cost_points": 0\.0', '"cost_points": 3000.0', chunk, count=1)
    chunk = re.sub(r'"is_starting": true', '"is_starting": false', chunk, count=1)
    chunk = re.sub(
        r'"is_starter_eligible": true',
        '"is_starter_eligible": false',
        chunk,
        count=1,
    )
    return chunk


def main() -> None:
    text = NETWORK.read_text(encoding="utf-8")
    for tech_id in LEFTOVER:
        marker = f'"id": "{tech_id}"'
        start = text.find(marker)
        if start < 0:
            raise SystemExit(f"missing node {tech_id}")
        # Node objects are closed by the next sibling at the same indent.
        end = text.find('\n\t\t{\n\t\t\t"id": "tech.', start + len(marker))
        if end < 0:
            end = text.find("\n\t\t],", start)
        if end < 0:
            raise SystemExit(f"cannot bound node {tech_id}")
        chunk = text[start:end]
        patched = patch_node_fields(chunk)
        if patched == chunk:
            raise SystemExit(f"no starter fields patched for {tech_id}")
        if '"is_starter_eligible": true' in patched.split("starter_capability_tags")[0]:
            raise SystemExit(f"starter flag remains for {tech_id}")
        text = text[:start] + patched + text[end:]

    oral_marker = '"id": "tech.oral_memory_practice"'
    oral_start = text.find(oral_marker)
    if oral_start < 0:
        raise SystemExit("missing oral memory node")
    reveal_start = text.find('"reveal_condition":', oral_start)
    reveal_end = text.find('"is_milestone":', reveal_start)
    if reveal_start < 0 or reveal_end < 0:
        raise SystemExit("missing oral memory reveal_condition")
    text = text[:reveal_start] + ORAL_REVEAL.strip() + "\n" + text[reveal_end:]
    NETWORK.write_text(text, encoding="utf-8")
    print(f"patched {len(LEFTOVER)} leftover starter nodes and oral memory reveal")


if __name__ == "__main__":
    main()
