#!/usr/bin/env python3
"""Generate the exhaustive, deterministic schema-v2 technology design audit."""

from __future__ import annotations

import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "data/technology/technology_network.json"
REPORT = ROOT / "tools/technology_tree/technology_network_v2_full_audit.md"

REQUIRED_NODE_FIELDS = (
    "id", "display_name", "era_id", "domain_id", "network_role", "node_role",
    "branch_family_id", "secondary_route_tags", "reveal_category",
    "reveal_condition", "reveal_summary", "hard_prerequisite_ids",
    "prerequisite_rationales", "research_condition", "research_condition_summary",
    "modifier_terms", "expected_bindings", "content_effects", "branch_successor_ids",
    "branch_successor_rationales", "application_target_ids",
    "application_target_rationales", "opportunity_cost", "terminal_reason",
)

ALLOWED_RESEARCH_CONDITION_IDS = {
    "tech.scientific_classification", "tech.crop_breeding", "tech.oceanic_navigation",
    "tech.synthetic_fertilizer", "tech.modern_husbandry", "tech.advanced_metallurgy",
    "tech.global_logistics", "tech.geographic_information_systems",
}

SCENARIOS = {
    "river_paddy": {"resource.paddy_land", "landform.floodplain", "landform.river_valley",
                    "landform.freshwater_access", "bio.rice", "weather.major_flood"},
    "dryland_grain": {"resource.arable_land", "resource.fertile_soil", "bio.wheat",
                      "weather.drought", "landform.arid_basin"},
    "highland_tuber": {"resource.arable_land", "bio.potato", "landform.mountain",
                       "landform.high_plateau", "weather.frost"},
    "pastoral_steppe": {"resource.pasture", "bio.horse", "bio.sheep", "bio.cattle"},
    "forest_biomass": {"resource.timber", "landform.forest", "bio.flax"},
    "coastal_maritime": {"landform.coast", "landform.coastal_estuary",
                         "resource.marine_fish", "weather.storm_surge"},
    "tropical_plantation": {"resource.plantation_land", "bio.spice", "bio.rubber",
                            "weather.monsoon"},
    "coal_heavy_industry": {"resource.iron_ore", "resource.coal", "resource.clay",
                            "breakthrough.metalworking"},
    "oil_petroleum": {"resource.oil", "resource.natural_gas", "resource.sulfur"},
    "water_wind_grid": {"landform.freshwater_access", "landform.stable_wind_corridor",
                        "weather.monsoon", "breakthrough.energy_control"},
}


def atom_ids(spec: dict, predicate_kind: int) -> set[str]:
    found: set[str] = set()
    if not spec:
        return found
    if "kind" in spec:
        if int(spec.get("kind", -1)) == predicate_kind:
            found.add(str(spec.get("id", "")))
        return found
    if int(spec.get("operator", -1)) == 0 and isinstance(spec.get("atom"), dict):
        return atom_ids(spec["atom"], predicate_kind)
    for child in spec.get("children", []):
        if isinstance(child, dict):
            found.update(atom_ids(child, predicate_kind))
    return found


def eval_reveal(spec: dict, signals: set[str], completed: set[str]) -> bool:
    if not spec:
        return True
    if "kind" in spec:
        kind, stable_id = int(spec.get("kind", -1)), str(spec.get("id", ""))
        return stable_id in (completed if kind == 0 else signals)
    operator = int(spec.get("operator", -1))
    children = [eval_reveal(child, signals, completed) for child in spec.get("children", [])]
    if operator == 0:
        return eval_reveal(spec.get("atom", {}), signals, completed)
    if operator == 1:
        return bool(children) and all(children)
    if operator == 2:
        return any(children)
    if operator == 3:
        return sum(children) >= int(spec.get("required_count", 1))
    if operator == 4:
        return len(children) == 1 and not children[0]
    return False


def compact_condition(spec: dict) -> str:
    if not spec:
        return "—"
    if "kind" in spec:
        return str(spec.get("id", ""))
    names = {0: "ATOM", 1: "ALL", 2: "ANY", 3: "AT_LEAST", 4: "NOT"}
    operator = int(spec.get("operator", -1))
    if operator == 0:
        return compact_condition(spec.get("atom", {}))
    children = ", ".join(compact_condition(child) for child in spec.get("children", []))
    label = names.get(operator, "?")
    if operator == 3:
        label += f" {int(spec.get('required_count', 1))}"
    return f"{label}({children})"


def cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ").strip() or "—"


def main() -> int:
    data = json.loads(NETWORK.read_text(encoding="utf-8"))
    nodes = data["nodes"]
    node_by_id = {node["id"]: node for node in nodes}
    errors: list[str] = []
    hard_successors: dict[str, list[str]] = defaultdict(list)
    hard_prerequisites: dict[str, list[str]] = {
        node["id"]: list(node.get("hard_prerequisite_ids", [])) for node in nodes
    }
    for node in nodes:
        for prerequisite in node.get("hard_prerequisite_ids", []):
            hard_successors[prerequisite].append(node["id"])
    for node in nodes:
        missing = [field for field in REQUIRED_NODE_FIELDS if field not in node]
        if missing:
            errors.append(f"{node.get('id', '?')}: missing {', '.join(missing)}")
        hard = node.get("hard_prerequisite_ids", [])
        reasons = node.get("prerequisite_rationales", [])
        if len(hard) != len(reasons) or any(not str(reason).strip() for reason in reasons):
            errors.append(f"{node['id']}: prerequisite rationale mismatch")
        if any("不可替代的理论、材料、工艺或组织基础" in str(reason) for reason in reasons):
            errors.append(f"{node['id']}: legacy generic prerequisite rationale")
        branch = node.get("branch_successor_ids", [])
        branch_reasons = node.get("branch_successor_rationales", [])
        applications = node.get("application_target_ids", [])
        application_reasons = node.get("application_target_rationales", [])
        if len(branch) != len(branch_reasons) or any(not str(reason).strip() for reason in branch_reasons):
            errors.append(f"{node['id']}: branch successor rationale mismatch")
        if len(applications) != len(application_reasons) or any(not str(reason).strip() for reason in application_reasons):
            errors.append(f"{node['id']}: application rationale mismatch")
        for target in branch:
            if target in node_by_id and node_by_id[target]["branch_family_id"] != node["branch_family_id"]:
                errors.append(f"{node['id']}: cross-family branch successor {target}")
        alternatives = atom_ids(node.get("research_condition", {}), 0)
        if alternatives.intersection(hard):
            errors.append(f"{node['id']}: alternative duplicates hard prerequisite")
        if node.get("research_condition") and node["id"] not in ALLOWED_RESEARCH_CONDITION_IDS:
            errors.append(f"{node['id']}: research condition is not in the semantic whitelist")
        for reference in hard + node.get("branch_successor_ids", []) + node.get("application_target_ids", []):
            if reference not in node_by_id:
                errors.append(f"{node['id']}: dangling reference {reference}")
        if not hard_successors[node["id"]] and not node.get("branch_successor_ids") and not node.get("application_target_ids") \
                and not str(node.get("terminal_reason", "")).strip():
            errors.append(f"{node['id']}: no successor, application, or terminal reason")

    ancestor_cache: dict[str, set[str]] = {}

    def hard_ancestors(technology_id: str) -> set[str]:
        if technology_id in ancestor_cache:
            return ancestor_cache[technology_id]
        ancestors: set[str] = set()
        for prerequisite in hard_prerequisites.get(technology_id, []):
            ancestors.add(prerequisite)
            ancestors.update(hard_ancestors(prerequisite))
        ancestor_cache[technology_id] = ancestors
        return ancestors

    retained_transitive_edges: list[tuple[str, str, list[str], str]] = []
    for node in nodes:
        direct = node.get("hard_prerequisite_ids", [])
        rationales = node.get("prerequisite_rationales", [])
        for index, prerequisite in enumerate(direct):
            via = sorted(other for other in direct
                         if other != prerequisite and prerequisite in hard_ancestors(other))
            if via:
                retained_transitive_edges.append((
                    node["id"], prerequisite, via,
                    str(rationales[index]) if index < len(rationales) else ""))

    family_counts = Counter(node["branch_family_id"] for node in nodes if not node.get("is_milestone"))
    reveal_counts = Counter(node["reveal_category"] for node in nodes)
    hard_hist = Counter(len(node["hard_prerequisite_ids"]) for node in nodes)
    condition_count = sum(bool(node["research_condition"]) for node in nodes)
    modifier_empty = sum(not node["modifier_terms"] and not node.get("is_starter_eligible") for node in nodes)
    binding_counts = Counter(binding.get("kind", 0) for node in nodes for binding in node["expected_bindings"])
    canonical = json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    canonical_hash = hashlib.sha256(canonical).hexdigest()

    lines = [
        "# Technology Network v2 Full Audit", "",
        f"- Canonical SHA-256: `{canonical_hash}`",
        f"- Nodes: {len(nodes)} (legacy stable IDs retained: {min(361, len(nodes))})",
        f"- Eras / domains / branch families: {len(data['eras'])} / {len(data['domains'])} / {len(data['branch_families'])}",
        f"- Hard edges: {sum(len(node['hard_prerequisite_ids']) for node in nodes)}; maximum direct indegree: {max(hard_hist)}; no configured cap",
        f"- Nodes with alternative research conditions: {condition_count}",
        f"- Retained transitive direct edges requiring independent rationale: {len(retained_transitive_edges)}",
        f"- Unlock-only/no-Modifier research nodes: {modifier_empty}",
        f"- Expected content bindings by kind: {dict(sorted(binding_counts.items()))}",
        f"- Validation errors: {len(errors)}", "",
        "## Era gates and milestones", "",
        "| Era | Entry milestone | Milestone | Candidates | Required |", "|---|---|---|---:|---:|",
    ]
    for era in data["eras"]:
        lines.append(f"| {cell(era['id'])} | {cell(era['entry_milestone_id'])} | {cell(era['milestone_id'])} | {len(era['milestone_candidate_ids'])} | {era['candidate_required']} |")

    lines += ["", "## Topology and reveal coverage", "",
              f"- Hard indegree histogram: `{dict(sorted(hard_hist.items()))}`",
              f"- Reveal categories: `{dict(sorted(reveal_counts.items()))}`", "",
              "| Family | Nodes | Has alternative entry | Cross-family applications |", "|---|---:|---:|---:|"]
    for family in data["branch_families"]:
        family_id = family["id"]
        members = [node for node in nodes if node["branch_family_id"] == family_id]
        has_alt = any(node["research_condition"] for node in members)
        cross_apps = sum(
            node_by_id[target]["branch_family_id"] != family_id
            for node in members for target in node["application_target_ids"]
        )
        lines.append(f"| {cell(family['display_name'])} (`{family_id}`) | {len(members)} | {'yes' if has_alt else 'no'} | {cross_apps} |")

    lines += ["", "## Geographic opening visibility", "",
              "Counts evaluate reveal conditions only; hard prerequisites and era gates remain separate.", "",
              "| Opening profile | Revealed nodes | Revealed branch families | Maritime nodes |", "|---|---:|---:|---:|"]
    general_completed = {node["id"] for node in nodes if node.get("is_starter_eligible") and not node.get("reveal_condition")}
    for name, signals in SCENARIOS.items():
        visible = [node for node in nodes if eval_reveal(node["reveal_condition"], signals, general_completed)]
        visible_families = {node["branch_family_id"] for node in visible}
        maritime = sum(node["branch_family_id"] == "branch.maritime_logistics" for node in visible)
        lines.append(f"| `{name}` | {len(visible)} | {len(visible_families)} | {maritime} |")

    lines += ["", "## Validation findings", ""]
    lines += ([f"- {cell(error)}" for error in errors] if errors else ["- None."])
    lines += ["", "## Retained transitive direct-edge review", "",
              "These edges are structurally reachable through another direct prerequisite, but remain direct only where their rationale records an independent contribution.", "",
              "| Target | Direct prerequisite | Also reachable through | Independent direct rationale |",
              "|---|---|---|---|"]
    for target, prerequisite, via, rationale in retained_transitive_edges:
        lines.append("| " + " | ".join(map(cell, [target, prerequisite, ", ".join(via), rationale])) + " |")
    lines += ["", "## Complete node review table", "",
              "| ID | Name | Era / domain | Family / role | Reveal | Hard prerequisites and rationale | Alternative research condition | Direct bindings | Modifiers | Successors / applications / terminal | Opportunity cost |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
    for node in nodes:
        hard = "; ".join(
            f"{tech}: {reason}" for tech, reason in zip(
                node["hard_prerequisite_ids"], node["prerequisite_rationales"])
        ) or "—"
        bindings = "; ".join(f"{binding.get('kind')}:{binding.get('id')}" for binding in node["expected_bindings"]) or "—"
        modifiers = "; ".join(f"{term.get('stat')}={term.get('value')}" for term in node["modifier_terms"]) or "—"
        downstream = []
        if node["branch_successor_ids"]:
            downstream.append("next=" + "; ".join(
                f"{target}: {reason}" for target, reason in zip(
                    node["branch_successor_ids"], node["branch_successor_rationales"])))
        if node["application_target_ids"]:
            downstream.append("app=" + "; ".join(
                f"{target}: {reason}" for target, reason in zip(
                    node["application_target_ids"], node["application_target_rationales"])))
        if node["terminal_reason"]:
            downstream.append("terminal=" + node["terminal_reason"])
        reveal = f"{node['reveal_category']}: {node['reveal_summary']} [{compact_condition(node['reveal_condition'])}]"
        research = node["research_condition_summary"] or compact_condition(node["research_condition"])
        lines.append("| " + " | ".join(map(cell, [
            f"`{node['id']}`", node["display_name"], f"{node['era_id']} / {node['domain_id']}",
            f"{node['branch_family_id']} / {node['network_role']} / {node['node_role']}",
            reveal, hard, research, bindings, modifiers, "; ".join(downstream), node["opportunity_cost"],
        ])) + " |")

    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[PASS] wrote {REPORT} ({len(nodes)} nodes, sha256={canonical_hash})")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
