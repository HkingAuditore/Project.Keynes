#!/usr/bin/env python3
"""Audit technology-line topology and progressive building unlocks.

The report is intentionally read-only with respect to authoring data.  The
authoritative sources remain technology_network.json and BuildingProfile
resources.  Use --strict while promoting a reviewed wave to the release gate.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "data" / "technology" / "technology_network.json"
BUILDINGS_DIR = ROOT / "data" / "economy" / "buildings"
REPORT = ROOT / "tools" / "technology_tree" / "technology_topology_audit.md"

TOPOLOGY_ROLES = {"origin", "continuation", "convergence", "branch", "terminal"}
BUILDING_POLICIES = {"single", "paired", "support_only"}


def packed_strings(text: str, field: str) -> list[str]:
    match = re.search(
        rf"^{re.escape(field)}\s*=\s*PackedStringArray\((.*?)\)$",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        return []
    return re.findall(r'"([^"]+)"', match.group(1))


def scalar(text: str, field: str, default: str = "") -> str:
    match = re.search(
        rf"^{re.escape(field)}\s*=\s*(?:&)?\"([^\"]*)\"$",
        text,
        re.MULTILINE,
    )
    return match.group(1) if match else default


def integer(text: str, field: str, default: int = 0) -> int:
    match = re.search(rf"^{re.escape(field)}\s*=\s*(-?\d+)$", text, re.MULTILINE)
    return int(match.group(1)) if match else default


def load_buildings() -> list[dict]:
    buildings: list[dict] = []
    for path in sorted(BUILDINGS_DIR.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        direct = [tag for tag in packed_strings(text, "technology_tags")
                  if tag.startswith("tech.")]
        required = [tag for tag in packed_strings(text, "required_technology_tags")
                    if tag.startswith("tech.")]
        buildings.append({
            "id": path.stem,
            "name": scalar(text, "display_name", path.stem),
            "direct": direct,
            "required": required,
            "family": scalar(text, "upgrade_family_id"),
            "tier": integer(text, "upgrade_tier"),
        })
    return buildings


def era_indices(payload: dict) -> dict[str, int]:
    return {str(row["id"]): index for index, row in enumerate(payload["eras"])}


def inferred_topology_role(node: dict, adjacency: dict[str, list[str]]) -> str:
    if bool(node.get("is_milestone", False)):
        return "terminal"
    if node.get("branch_successor_ids"):
        return "branch"
    if len(node.get("hard_prerequisite_ids", [])) >= 2:
        return "convergence"
    if not node.get("hard_prerequisite_ids", []):
        return "origin"
    if not adjacency.get(str(node["id"])) and str(node.get("terminal_reason", "")).strip():
        return "terminal"
    return "continuation"


def collect_direct_buildings(buildings: list[dict]) -> dict[str, list[dict]]:
    result: dict[str, list[dict]] = defaultdict(list)
    for building in buildings:
        for technology_id in building["direct"]:
            result[technology_id].append(building)
    return result


def validate_review_metadata(
    nodes: list[dict],
    node_by_id: dict[str, dict],
    direct_by_technology: dict[str, list[dict]],
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    family_ids = {str(node.get("branch_family_id", "")) for node in node_by_id.values()}
    for node in nodes:
        technology_id = str(node["id"])
        review = node.get("topology_review")
        if not isinstance(review, dict):
            warnings.append(f"missing topology_review: {technology_id}")
        else:
            role = str(review.get("role", ""))
            if role not in TOPOLOGY_ROLES:
                errors.append(f"invalid topology role: {technology_id} ({role})")
            if not str(review.get("rationale", "")).strip():
                errors.append(f"missing topology rationale: {technology_id}")
            expected = review.get("expected_hard_family_ids", [])
            if not isinstance(expected, list) or any(str(item) not in family_ids for item in expected):
                errors.append(f"invalid expected hard family list: {technology_id}")
            if role == "convergence" and not expected:
                errors.append(f"convergence has no expected hard families: {technology_id}")

        building_review = node.get("building_unlock_review")
        building_count = len(direct_by_technology.get(technology_id, []))
        if building_count and not isinstance(building_review, dict):
            warnings.append(f"missing building_unlock_review: {technology_id}")
        if isinstance(building_review, dict):
            policy = str(building_review.get("policy", ""))
            if policy not in BUILDING_POLICIES:
                errors.append(f"invalid building unlock policy: {technology_id} ({policy})")
            if not str(building_review.get("rationale", "")).strip():
                errors.append(f"missing building unlock rationale: {technology_id}")
            if policy == "single" and building_count > 1:
                errors.append(f"single policy has {building_count} direct buildings: {technology_id}")
            if policy == "paired" and building_count > 2:
                errors.append(f"paired policy has {building_count} direct buildings: {technology_id}")
            if policy == "support_only" and building_count:
                errors.append(f"support_only directly unlocks buildings: {technology_id}")
    return errors, warnings


def audit_upgrade_families(
    buildings: list[dict],
    technology_by_id: dict[str, dict],
    era_by_id: dict[str, int],
) -> tuple[list[str], list[str], list[dict]]:
    errors: list[str] = []
    warnings: list[str] = []
    families: dict[str, list[dict]] = defaultdict(list)
    for building in buildings:
        if building["family"]:
            families[building["family"]].append(building)

    rows: list[dict] = []
    for family_id, members in sorted(families.items()):
        members.sort(key=lambda item: (item["tier"], item["id"]))
        tiers = [int(item["tier"]) for item in members]
        if any(tier <= 0 for tier in tiers):
            errors.append(f"invalid non-positive upgrade tier: {family_id}")
        duplicate_tiers = sorted({tier for tier in tiers if tiers.count(tier) > 1})
        if duplicate_tiers:
            errors.append(f"duplicate upgrade tiers {duplicate_tiers}: {family_id}")
        if len(members) > 1:
            expected = set(range(1, max(tiers) + 1))
            missing = sorted(expected - set(tiers))
            if missing:
                warnings.append(f"upgrade tier gap {missing}: {family_id}")
        tier_eras: list[int] = []
        for member in members:
            tech_eras = [
                era_by_id[str(technology_by_id[tag]["era_id"])]
                for tag in member["direct"]
                if tag in technology_by_id
            ]
            if tech_eras:
                tier_eras.append(min(tech_eras))
        if tier_eras != sorted(tier_eras):
            warnings.append(f"building technology era regresses across tiers: {family_id}")
        rows.append({
            "id": family_id,
            "members": len(members),
            "tiers": ",".join(str(tier) for tier in sorted(set(tiers))),
            "min_era": min(tier_eras) if tier_eras else "-",
        })
    return errors, warnings, rows


def build_report(payload: dict, strict: bool = False) -> tuple[str, int]:
    nodes = list(payload.get("nodes", []))
    node_by_id = {str(node["id"]): node for node in nodes}
    era_by_id = era_indices(payload)
    buildings = load_buildings()
    direct_by_technology = collect_direct_buildings(buildings)

    adjacency: dict[str, list[str]] = defaultdict(list)
    hard_edges = 0
    one_hard = 0
    zero_hard = 0
    multi_hard = 0
    for node in nodes:
        technology_id = str(node["id"])
        hard = [str(item) for item in node.get("hard_prerequisite_ids", [])]
        hard_edges += len(hard)
        zero_hard += int(len(hard) == 0)
        one_hard += int(len(hard) == 1)
        multi_hard += int(len(hard) >= 2)
        for prerequisite in hard:
            adjacency[prerequisite].append(technology_id)

    metadata_errors, metadata_warnings = validate_review_metadata(
        nodes, node_by_id, direct_by_technology)
    family_errors, family_warnings, family_rows = audit_upgrade_families(
        buildings, node_by_id, era_by_id)
    errors = metadata_errors + family_errors
    warnings = metadata_warnings + family_warnings

    topology_rows: list[dict] = []
    for family in list(payload.get("backbones", [])) + list(payload.get("branch_families", [])):
        family_id = str(family["id"])
        members = [node for node in nodes if str(node.get("branch_family_id")) == family_id]
        era_values = sorted({era_by_id[str(node["era_id"])] for node in members})
        gaps = [era_values[index] - era_values[index - 1]
                for index in range(1, len(era_values))]
        hard_internal = 0
        hard_cross = 0
        routes = 0
        branches = 0
        applications = 0
        for node in members:
            routes += len(node.get("research_routes", []))
            branches += len(node.get("branch_successor_ids", []))
            applications += len(node.get("application_target_ids", []))
            for prerequisite in node.get("hard_prerequisite_ids", []):
                parent = node_by_id.get(str(prerequisite), {})
                if str(parent.get("branch_family_id")) == family_id:
                    hard_internal += 1
                else:
                    hard_cross += 1
        topology_rows.append({
            "id": family_id,
            "name": str(family.get("display_name", family_id)),
            "nodes": len(members),
            "eras": ",".join(str(node["id"]) for node in sorted(
                [payload["eras"][value] for value in era_values], key=lambda item: era_by_id[str(item["id"])])),
            "max_gap": max(gaps, default=0),
            "hard_internal": hard_internal,
            "hard_cross": hard_cross,
            "routes": routes,
            "branches": branches,
            "applications": applications,
        })

    direct_rows = sorted(
        ((technology_id, node_by_id.get(technology_id, {}).get("display_name", technology_id),
          len(buildings_for_technology))
         for technology_id, buildings_for_technology in direct_by_technology.items()),
        key=lambda item: (-item[2], item[0]),
    )
    over_limit = [row for row in direct_rows if row[2] > 2]
    if strict:
        errors.extend(warnings)
        warnings = []
        errors.extend(
            f"direct building unlock limit exceeded ({count}): {technology_id}"
            for technology_id, _name, count in over_limit
        )
        errors.extend(
            f"missing topology review in strict mode: {node['id']}"
            for node in nodes if not isinstance(node.get("topology_review"), dict)
        )
        errors.extend(
            f"missing building unlock review in strict mode: {technology_id}"
            for technology_id, _name, _count in direct_rows
            if not isinstance(node_by_id.get(technology_id, {}).get("building_unlock_review"), dict)
        )

    lines = [
        "# Technology Topology and Building Progression Audit",
        "",
        f"- Nodes: `{len(nodes)}`",
        f"- Hard prerequisite edges: `{hard_edges}`",
        f"- Zero hard prerequisites: `{zero_hard}`",
        f"- One hard prerequisite: `{one_hard}`",
        f"- Multiple hard prerequisites: `{multi_hard}`",
        f"- Buildings: `{len(buildings)}`",
        f"- Technologies with direct buildings: `{len(direct_rows)}`",
        f"- Direct building unlock entries: `{sum(row[2] for row in direct_rows)}`",
        f"- Technologies over the default direct-building limit (2): `{len(over_limit)}`",
        f"- Result: `{'FAIL' if errors else 'PASS'}`",
        "",
        "## Technology Families",
        "",
        "| Family | Nodes | Eras | Max era gap | Internal hard | Cross-family hard | Routes | Branches | Applications |",
        "|---|---:|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in topology_rows:
        lines.append(
            f"| {row['name']} (`{row['id']}`) | {row['nodes']} | {row['eras']} | "
            f"{row['max_gap']} | {row['hard_internal']} | {row['hard_cross']} | "
            f"{row['routes']} | {row['branches']} | {row['applications']} |"
        )
    lines.extend([
        "",
        "## Direct Building Unlocks",
        "",
        "| Technology | Direct buildings |",
        "|---|---:|",
    ])
    for technology_id, name, count in direct_rows:
        marker = " **OVER LIMIT**" if count > 2 else ""
        lines.append(f"| {name} (`{technology_id}`) | {count}{marker} |")
    lines.extend(["", "## Upgrade Families", "",
                  "| Upgrade family | Members | Tiers | Earliest technology era |",
                  "|---|---:|---|---:|"])
    for row in family_rows:
        lines.append(f"| `{row['id']}` | {row['members']} | {row['tiers']} | {row['min_era']} |")
    lines.extend(["", "## Errors", ""])
    lines.extend(f"- {error}" for error in errors) if errors else lines.append("- None.")
    lines.extend(["", "## Warnings", ""])
    lines.extend(f"- {warning}" for warning in warnings) if warnings else lines.append("- None.")
    return "\n".join(lines) + "\n", int(bool(errors))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    payload = json.loads(NETWORK.read_text(encoding="utf-8"))
    report, failed = build_report(payload, strict=args.strict)
    if args.check:
        if not REPORT.exists() or REPORT.read_text(encoding="utf-8") != report:
            print(f"[FAIL] stale or missing report: {REPORT}")
            return 1
    else:
        REPORT.write_text(report, encoding="utf-8")
    print(f"[{'FAIL' if failed else 'PASS'}] wrote {REPORT}")
    return failed


if __name__ == "__main__":
    sys.exit(main())
