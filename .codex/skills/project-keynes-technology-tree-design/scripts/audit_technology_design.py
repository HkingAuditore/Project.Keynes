#!/usr/bin/env python3
"""Audit a Project.Keynes technology-network design JSON file."""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path
from typing import Any


ALLOWED_ROLES = {"backbone", "branch"}
ALLOWED_CONDITIONS = {
    "TECH_COMPLETED",
    "SIGNAL_PRESENT",
    "SIGNAL_COUNT",
    "ALL_OF",
    "ANY_OF",
    "AT_LEAST",
    "NOT",
}
ALLOWED_EDGE_KINDS = {"hard", "alternative", "application"}
AUTHORING_EDGE_KINDS = ALLOWED_EDGE_KINDS | {"milestone_candidate"}
AUTHORING_ERA_QUOTAS = [74, 58, 29, 27, 24, 25, 24, 23, 23, 22, 20]
AUTHORING_BROAD_PREFIXES = (
    "country.output.agriculture_factor",
    "country.output.extractive_factor",
    "country.output.manufacturing_factor",
    "country.output.energy_factor",
    "country.output.knowledge_factor",
    "country.research.",
    "country.trade.",
)
ALLOWED_UNLOCK_TYPES = {
    "building",
    "method",
    "good",
    "profession",
    "resource_access",
}
ALLOWED_STATUSES = {
    "existing_binding",
    "catalog_rebind",
    "new_content",
    "modifier_only",
    "blocked",
    "new_runtime",
}
REQUIRED_NODE_FIELDS = {"id", "name", "era", "domain", "role"}
REQUIRED_EFFECT_FIELDS = {
    "subject",
    "attribute",
    "operation",
    "value",
    "implementation",
    "status",
}


def _nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _condition_kinds(
    condition: Any,
    path: str,
    errors: list[str],
) -> set[str]:
    kinds: set[str] = set()
    if not isinstance(condition, dict):
        errors.append(f"{path}: condition must be an object")
        return kinds
    kind = condition.get("kind")
    if not _nonempty_string(kind):
        errors.append(f"{path}: condition.kind must be a non-empty string")
        return kinds
    if kind not in ALLOWED_CONDITIONS:
        errors.append(f"{path}: unsupported condition kind {kind!r}")
        return kinds
    kinds.add(kind)
    if kind in {"ALL_OF", "ANY_OF", "AT_LEAST", "NOT"}:
        children = condition.get("children")
        if not isinstance(children, list) or not children:
            errors.append(f"{path}: composite condition requires non-empty children")
            return kinds
        if kind == "AT_LEAST":
            required_count = condition.get("required_count")
            if not isinstance(required_count, int) or not 1 <= required_count <= len(children):
                errors.append(f"{path}: AT_LEAST required_count is invalid")
        if kind == "NOT" and len(children) != 1:
            errors.append(f"{path}: NOT requires exactly one child")
        for index, child in enumerate(children):
            kinds.update(_condition_kinds(child, f"{path}.children[{index}]", errors))
    elif not _nonempty_string(condition.get("id")):
        errors.append(f"{path}: leaf condition requires a non-empty id")
    return kinds


def _find_cycle(adjacency: dict[str, list[str]], node_ids: set[str]) -> list[str]:
    state: dict[str, int] = {}
    stack: list[str] = []

    def visit(node_id: str) -> list[str]:
        state[node_id] = 1
        stack.append(node_id)
        for successor in adjacency.get(node_id, []):
            if state.get(successor, 0) == 0:
                cycle = visit(successor)
                if cycle:
                    return cycle
            elif state.get(successor) == 1:
                start = stack.index(successor)
                return stack[start:] + [successor]
        stack.pop()
        state[node_id] = 2
        return []

    for node_id in sorted(node_ids):
        if state.get(node_id, 0) == 0:
            cycle = visit(node_id)
            if cycle:
                return cycle
    return []


def _reachable_later_branch(
    start_id: str,
    start_era: int,
    nodes_by_id: dict[str, dict[str, Any]],
    era_index: dict[str, int],
    adjacency: dict[str, list[str]],
    max_depth: int = 4,
) -> bool:
    queue = deque([(start_id, 0)])
    visited = {start_id}
    while queue:
        node_id, depth = queue.popleft()
        if depth >= max_depth:
            continue
        for successor in adjacency.get(node_id, []):
            if successor in visited:
                continue
            visited.add(successor)
            successor_node = nodes_by_id[successor]
            successor_era = era_index[successor_node["era"]]
            if successor_node["role"] == "branch" and successor_era > start_era:
                return True
            queue.append((successor, depth + 1))
    return False


def _authoring_condition_facts(
    spec: Any,
    path: str,
    errors: list[str],
) -> tuple[set[str], bool, bool]:
    technologies: set[str] = set()
    has_evidence = False
    has_alternative = False
    if not isinstance(spec, dict):
        errors.append(f"{path}: condition must be an object")
        return technologies, has_evidence, has_alternative
    if not spec:
        return technologies, has_evidence, has_alternative
    if "kind" in spec:
        kind = spec.get("kind")
        reference_id = spec.get("id")
        if kind not in {0, 1, 2}:
            errors.append(f"{path}: unsupported compiled predicate kind {kind!r}")
        if not _nonempty_string(reference_id):
            errors.append(f"{path}: compiled predicate requires a stable id")
        elif kind == 0:
            technologies.add(reference_id)
        else:
            has_evidence = True
        return technologies, has_evidence, has_alternative
    operator = spec.get("operator")
    children = spec.get("children")
    if operator not in {1, 2, 3, 5}:
        errors.append(f"{path}: unsupported compiled condition operator {operator!r}")
    if not isinstance(children, list) or not children:
        errors.append(f"{path}: composite condition requires children")
        return technologies, has_evidence, has_alternative
    if operator in {2, 3}:
        has_alternative = True
    if operator == 3:
        required_count = spec.get("required_count")
        if not isinstance(required_count, int) or not 1 <= required_count <= len(children):
            errors.append(f"{path}: AT_LEAST required_count is invalid")
    if operator == 5 and len(children) != 1:
        errors.append(f"{path}: NOT requires exactly one child")
    for index, child in enumerate(children):
        child_tech, child_evidence, child_alternative = _authoring_condition_facts(
            child, f"{path}.children[{index}]", errors
        )
        technologies.update(child_tech)
        has_evidence = has_evidence or child_evidence
        has_alternative = has_alternative or child_alternative
    return technologies, has_evidence, has_alternative


def _is_authoring_broad(stat: str) -> bool:
    return any(stat == prefix or stat.startswith(prefix) for prefix in AUTHORING_BROAD_PREFIXES)


def audit_authoring_network(data: dict[str, Any]) -> tuple[list[str], list[str], dict[str, Any]]:
    errors: list[str] = []
    warnings: list[str] = []
    metrics: dict[str, Any] = {}
    eras = data.get("eras")
    nodes = data.get("nodes")
    edges = data.get("visual_edges")
    backbones = data.get("backbones")
    branches = data.get("specialist_lanes")
    if not isinstance(eras, list) or len(eras) != 11:
        errors.append("authoring eras must contain exactly eleven objects")
        eras = []
    if not isinstance(nodes, list) or len(nodes) != 360:
        errors.append("authoring network must contain exactly 360 nodes")
        nodes = nodes if isinstance(nodes, list) else []
    if not isinstance(edges, list) or len(edges) > 1500:
        errors.append("authoring visual_edges must be an array with at most 1500 entries")
        edges = edges if isinstance(edges, list) else []
    if not isinstance(backbones, list) or len(backbones) != 4:
        errors.append("authoring network must define exactly four backbones")
        backbones = backbones if isinstance(backbones, list) else []
    if not isinstance(branches, list) or len(branches) != 16:
        errors.append("authoring network must define exactly sixteen specialist lanes")
        branches = branches if isinstance(branches, list) else []

    era_ids = [era.get("id") for era in eras if isinstance(era, dict)]
    if len(era_ids) != 11 or any(not _nonempty_string(era_id) for era_id in era_ids):
        errors.append("authoring era ids must be eleven non-empty strings")
    if len(set(era_ids)) != len(era_ids):
        errors.append("authoring era ids must be unique")
    era_index = {era_id: index for index, era_id in enumerate(era_ids)}
    milestone_by_era = {
        era.get("id"): era.get("milestone_id")
        for era in eras if isinstance(era, dict)
    }
    for era in eras:
        if isinstance(era, dict) and era.get("candidate_required") != 5:
            errors.append(f"era {era.get('id')!r}: candidate_required must equal 5")

    backbone_ids = {
        lane.get("id") for lane in backbones
        if isinstance(lane, dict) and _nonempty_string(lane.get("id"))
    }
    branch_ids = {
        lane.get("id") for lane in branches
        if isinstance(lane, dict) and _nonempty_string(lane.get("id"))
    }
    nodes_by_id: dict[str, dict[str, Any]] = {}
    era_nodes: dict[str, list[dict[str, Any]]] = defaultdict(list)
    route_anchor: dict[tuple[str, str], str] = {}
    backbone_anchor: dict[tuple[str, str], str] = {}
    condition_facts: dict[str, tuple[set[str], bool, bool]] = {}
    modifier_terms = 0
    broad_nodes = 0
    nonstarting_nodes = 0
    family_totals: defaultdict[str, float] = defaultdict(float)
    broad_totals: defaultdict[str, float] = defaultdict(float)
    hard_adjacency: dict[str, list[str]] = defaultdict(list)

    required_fields = {
        "id", "display_name", "era_id", "domain_id", "cost_points",
        "network_role", "anchor_kind", "main_lane", "hard_prerequisite_ids",
        "research_condition", "reveal_condition", "modifier_terms",
        "expected_bindings", "effect_summary", "opportunity_cost",
        "same_lane_successor_ids", "application_target_ids",
    }
    for index, node in enumerate(nodes):
        path = f"nodes[{index}]"
        if not isinstance(node, dict):
            errors.append(f"{path}: node must be an object")
            continue
        missing = required_fields - node.keys()
        if missing:
            errors.append(f"{path}: missing fields {', '.join(sorted(missing))}")
            continue
        node_id = node.get("id")
        if not _nonempty_string(node_id) or node_id in nodes_by_id:
            errors.append(f"{path}: invalid or duplicate id {node_id!r}")
            continue
        nodes_by_id[node_id] = node
        era_id = node.get("era_id")
        lane = node.get("main_lane")
        if era_id not in era_index:
            errors.append(f"{node_id}: unknown era {era_id!r}")
        else:
            era_nodes[era_id].append(node)
        if node.get("network_role") not in ALLOWED_ROLES:
            errors.append(f"{node_id}: invalid network_role")
        if lane not in backbone_ids | branch_ids:
            errors.append(f"{node_id}: unknown main_lane {lane!r}")
        if node.get("network_role") == "backbone" and lane not in backbone_ids:
            errors.append(f"{node_id}: backbone role uses a specialist lane")
        if node.get("network_role") == "branch" and lane not in branch_ids:
            errors.append(f"{node_id}: branch role uses a backbone lane")
        anchor_kind = node.get("anchor_kind")
        if anchor_kind == "route_anchor":
            key = (era_id, lane)
            if key in route_anchor:
                errors.append(f"{node_id}: duplicate route anchor for {key}")
            route_anchor[key] = node_id
            if not node.get("is_milestone_candidate"):
                errors.append(f"{node_id}: route anchor must be a milestone candidate")
        elif anchor_kind == "backbone_anchor":
            key = (era_id, lane)
            if key in backbone_anchor:
                errors.append(f"{node_id}: duplicate backbone anchor for {key}")
            backbone_anchor[key] = node_id
            if node.get("is_milestone_candidate"):
                errors.append(f"{node_id}: backbone anchor cannot be a milestone candidate")
        elif anchor_kind not in {"support", "milestone"}:
            errors.append(f"{node_id}: invalid anchor_kind {anchor_kind!r}")

        hard = node.get("hard_prerequisite_ids")
        if not isinstance(hard, list) or len(hard) > 2:
            errors.append(f"{node_id}: hard prerequisite count exceeds two")
            hard = hard if isinstance(hard, list) else []
        for prerequisite in hard:
            hard_adjacency[prerequisite].append(node_id)
        research_facts = _authoring_condition_facts(
            node.get("research_condition"), f"{path}.research_condition", errors
        )
        if any(research_facts[:2]):
            errors.append(
                f"{node_id}: research_condition must be empty; use hard prerequisites"
            )
        reveal_facts = _authoring_condition_facts(
            node.get("reveal_condition"), f"{path}.reveal_condition", errors
        )
        condition_facts[node_id] = reveal_facts

        terms = node.get("modifier_terms")
        if not isinstance(terms, list):
            errors.append(f"{node_id}: modifier_terms must be an array")
            terms = []
        modifier_terms += len(terms)
        if not node.get("is_starter_eligible"):
            nonstarting_nodes += 1
            if not 1 <= len(terms) <= 3:
                errors.append(f"{node_id}: nonstarting node requires one to three modifier terms")
            has_targeted = False
            has_broad = False
            for term in terms:
                if not isinstance(term, dict) or not _nonempty_string(term.get("stat")):
                    errors.append(f"{node_id}: malformed modifier term")
                    continue
                stat = term["stat"]
                value = term.get("value")
                if not isinstance(value, (int, float)):
                    errors.append(f"{node_id}: modifier term value must be numeric")
                    continue
                if stat.startswith("country.output.family."):
                    has_targeted = True
                    family_totals[stat] += float(value)
                if _is_authoring_broad(stat):
                    has_broad = True
                    broad_totals[stat] += float(value)
            if not has_targeted:
                errors.append(f"{node_id}: nonstarting node lacks a targeted family modifier")
            if has_broad:
                broad_nodes += 1
        if node.get("is_milestone") and node.get("expected_bindings"):
            errors.append(f"{node_id}: milestone directly binds economic content")
        if not _nonempty_string(node.get("effect_summary")):
            errors.append(f"{node_id}: missing effect summary")
        if not _nonempty_string(node.get("opportunity_cost")):
            errors.append(f"{node_id}: missing opportunity cost")

    if len(route_anchor) != 176:
        errors.append(f"route anchor count must equal 176, got {len(route_anchor)}")
    if len(backbone_anchor) != 44:
        errors.append(f"backbone anchor count must equal 44, got {len(backbone_anchor)}")
    for era_slot, era_id in enumerate(era_ids):
        expected = AUTHORING_ERA_QUOTAS[era_slot] + 1
        if len(era_nodes[era_id]) != expected:
            errors.append(f"era {era_id}: expected {expected} nodes, got {len(era_nodes[era_id])}")
        milestones = [node for node in era_nodes[era_id] if node.get("is_milestone")]
        if len(milestones) != 1 or milestones[0].get("id") != milestone_by_era.get(era_id):
            errors.append(f"era {era_id}: milestone identity/count mismatch")
        if len([node for node in era_nodes[era_id] if node.get("anchor_kind") == "route_anchor"]) != 16:
            errors.append(f"era {era_id}: requires sixteen route anchors")
        if len([node for node in era_nodes[era_id] if node.get("anchor_kind") == "backbone_anchor"]) != 4:
            errors.append(f"era {era_id}: requires four backbone anchors")
        if milestones:
            milestone_cost = float(milestones[0].get("cost_points", 0))
            for node in era_nodes[era_id]:
                cost = float(node.get("cost_points", 0))
                if cost > milestone_cost:
                    errors.append(f"{node.get('id')}: cost exceeds era milestone")
                if node.get("anchor_kind") == "route_anchor" and not milestone_cost * 0.60 <= cost <= milestone_cost * 0.75:
                    errors.append(f"{node.get('id')}: route-anchor cost outside 60-75%")
                if node.get("anchor_kind") == "backbone_anchor" and not milestone_cost * 0.55 <= cost <= milestone_cost * 0.70:
                    errors.append(f"{node.get('id')}: backbone-anchor cost outside 55-70%")

    hard_count = 0
    hard_cross_lane = 0
    edge_counts: Counter[str] = Counter()
    application_by_lane: Counter[str] = Counter()
    cross_application_by_lane: Counter[str] = Counter()
    feedback_by_lane: Counter[str] = Counter()
    for index, edge in enumerate(edges):
        path = f"visual_edges[{index}]"
        if not isinstance(edge, dict):
            errors.append(f"{path}: edge must be an object")
            continue
        source = edge.get("from")
        target = edge.get("to")
        kind = edge.get("kind")
        if source not in nodes_by_id or target not in nodes_by_id:
            errors.append(f"{path}: unknown endpoint")
            continue
        if kind not in AUTHORING_EDGE_KINDS:
            errors.append(f"{path}: unsupported edge kind {kind!r}")
            continue
        edge_counts[kind] += 1
        source_node = nodes_by_id[source]
        target_node = nodes_by_id[target]
        if kind == "hard":
            hard_count += 1
            if era_index[target_node["era_id"]] < era_index[source_node["era_id"]]:
                errors.append(f"{path}: hard edge points backward in era order")
            if source_node["main_lane"] != target_node["main_lane"] \
                    and not source_node.get("is_milestone"):
                hard_cross_lane += 1
        elif kind == "application" and source_node["main_lane"] in branch_ids:
            lane = source_node["main_lane"]
            target_lane = target_node["main_lane"]
            application_by_lane[lane] += 1
            if target_lane in branch_ids and target_lane != lane:
                cross_application_by_lane[lane] += 1
            if target_lane in backbone_ids:
                feedback_by_lane[lane] += 1
    if hard_count > 500:
        errors.append(f"hard edge count exceeds 500: {hard_count}")
    if hard_count and hard_cross_lane > (hard_count + 9) // 10:
        errors.append("cross-lane hard edges exceed 10%")
    if edge_counts["milestone_candidate"] != 176:
        errors.append("milestone-candidate visual edge count must equal 176")
    cycle = _find_cycle(hard_adjacency, set(nodes_by_id))
    if cycle:
        errors.append(f"hard prerequisite cycle: {' -> '.join(cycle)}")
    for lane in branch_ids:
        if application_by_lane[lane] < 6:
            errors.append(f"{lane}: fewer than six application edges")
        if cross_application_by_lane[lane] < 4:
            errors.append(f"{lane}: fewer than four cross-branch application edges")
        if feedback_by_lane[lane] < 2:
            errors.append(f"{lane}: fewer than two backbone feedback edges")

    evidence_anchors = 0
    for era_slot, era_id in enumerate(era_ids):
        for lane in branch_ids:
            anchor_id = route_anchor.get((era_id, lane))
            if not anchor_id:
                continue
            _technologies, has_evidence, _has_alternative = condition_facts[anchor_id]
            evidence_anchors += int(has_evidence)
            if era_slot:
                previous_era = era_ids[era_slot - 1]
                hard = set(nodes_by_id[anchor_id].get("hard_prerequisite_ids", []))
                if milestone_by_era[previous_era] not in hard:
                    errors.append(f"{anchor_id}: missing previous-era milestone prerequisite")
                previous_anchor = route_anchor.get((previous_era, lane))
                if previous_anchor not in hard:
                    errors.append(f"{anchor_id}: missing previous same-lane prerequisite")
            successors = nodes_by_id[anchor_id].get("same_lane_successor_ids", [])
            if era_slot < len(era_ids) - 1:
                expected_successor = route_anchor.get((era_ids[era_slot + 1], lane))
                if expected_successor not in successors:
                    errors.append(f"{anchor_id}: route continuity is broken")
            elif not _nonempty_string(nodes_by_id[anchor_id].get("terminal_reason")):
                errors.append(f"{anchor_id}: intelligent-era anchor lacks terminal payoff")
    if evidence_anchors != 176:
        errors.append(f"every route anchor must contain reveal evidence: {evidence_anchors}/176")
    if not 360 <= modifier_terms <= 480:
        errors.append(f"modifier term count outside 360-480: {modifier_terms}")
    if nonstarting_nodes and broad_nodes > int(nonstarting_nodes * 0.20):
        errors.append(f"broad-effect nodes exceed 20%: {broad_nodes}/{nonstarting_nodes}")
    for stat, value in family_totals.items():
        if value > 1.250001:
            errors.append(f"{stat}: family modifier stack exceeds +125%")
    for stat, value in broad_totals.items():
        if value > 0.500001:
            errors.append(f"{stat}: broad modifier stack exceeds +50%")

    metrics.update({
        "schema": "technology_network_authoring_v1",
        "eras": len(era_ids),
        "nodes": len(nodes_by_id),
        "edges": len(edges),
        "hard_edges": hard_count,
        "route_anchors": len(route_anchor),
        "backbone_anchors": len(backbone_anchor),
        "modifier_terms": modifier_terms,
        "broad_nodes": broad_nodes,
        "edge_kinds": dict(sorted(edge_counts.items())),
    })
    return errors, warnings, metrics


def audit_design(data: Any) -> tuple[list[str], list[str], dict[str, Any]]:
    errors: list[str] = []
    warnings: list[str] = []
    metrics: dict[str, Any] = {}

    if not isinstance(data, dict):
        return ["top level must be an object"], warnings, metrics

    if data.get("schema_version") == 1 and "visual_edges" in data:
        return audit_authoring_network(data)

    eras = data.get("eras")
    nodes = data.get("nodes")
    edges = data.get("edges")
    if not isinstance(eras, list) or len(eras) != 11 or not all(_nonempty_string(x) for x in eras):
        errors.append("eras must contain exactly eleven non-empty strings")
        eras = eras if isinstance(eras, list) else []
    if len(set(eras)) != len(eras):
        errors.append("eras must be unique and ordered")
    if not isinstance(nodes, list):
        errors.append("nodes must be an array")
        nodes = []
    if not isinstance(edges, list):
        errors.append("edges must be an array")
        edges = []

    era_index = {era: index for index, era in enumerate(eras)}
    nodes_by_id: dict[str, dict[str, Any]] = {}
    node_condition_kinds: dict[str, set[str]] = {}
    era_counts: Counter[str] = Counter()
    branch_family_nodes: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for index, node in enumerate(nodes):
        path = f"nodes[{index}]"
        if not isinstance(node, dict):
            errors.append(f"{path}: node must be an object")
            continue
        missing_fields = sorted(REQUIRED_NODE_FIELDS - node.keys())
        if missing_fields:
            errors.append(f"{path}: missing fields {', '.join(missing_fields)}")
            continue
        node_id = node.get("id")
        if not _nonempty_string(node_id):
            errors.append(f"{path}.id: must be a non-empty string")
            continue
        if node_id in nodes_by_id:
            errors.append(f"{path}.id: duplicate node id {node_id!r}")
            continue
        nodes_by_id[node_id] = node
        for field in ("name", "domain"):
            if not _nonempty_string(node.get(field)):
                errors.append(f"{path}.{field}: must be a non-empty string")
        if node.get("role") not in ALLOWED_ROLES:
            errors.append(f"{path}.role: must be backbone or branch")
        if node.get("era") not in era_index:
            errors.append(f"{path}.era: unknown era {node.get('era')!r}")
        else:
            era_counts[node["era"]] += 1

        conditions = node.get("conditions")
        kinds: set[str] = set()
        if not isinstance(conditions, list) or not conditions:
            errors.append(f"{path}.conditions: must be a non-empty array")
        else:
            for condition_index, condition in enumerate(conditions):
                kinds.update(_condition_kinds(
                    condition,
                    f"{path}.conditions[{condition_index}]",
                    errors,
                ))
        node_condition_kinds[node_id] = kinds

        unlocks = node.get("unlocks", [])
        effects = node.get("effects", [])
        if not isinstance(unlocks, list):
            errors.append(f"{path}.unlocks: must be an array")
            unlocks = []
        if not isinstance(effects, list):
            errors.append(f"{path}.effects: must be an array")
            effects = []
        if not unlocks and not effects:
            errors.append(f"{path}: requires at least one unlock or effect")

        for unlock_index, unlock in enumerate(unlocks):
            unlock_path = f"{path}.unlocks[{unlock_index}]"
            if not isinstance(unlock, dict):
                errors.append(f"{unlock_path}: must be an object")
                continue
            if unlock.get("type") not in ALLOWED_UNLOCK_TYPES:
                errors.append(f"{unlock_path}.type: unsupported unlock type")
            if not _nonempty_string(unlock.get("id")):
                errors.append(f"{unlock_path}.id: must be a non-empty string")
            if unlock.get("status") not in ALLOWED_STATUSES:
                errors.append(f"{unlock_path}.status: unsupported status")

        for effect_index, effect in enumerate(effects):
            effect_path = f"{path}.effects[{effect_index}]"
            if not isinstance(effect, dict):
                errors.append(f"{effect_path}: must be an object")
                continue
            missing_effect_fields = sorted(REQUIRED_EFFECT_FIELDS - effect.keys())
            if missing_effect_fields:
                errors.append(
                    f"{effect_path}: missing fields {', '.join(missing_effect_fields)}"
                )
                continue
            for field in ("subject", "attribute", "operation", "implementation"):
                if not _nonempty_string(effect.get(field)):
                    errors.append(f"{effect_path}.{field}: must be a non-empty string")
            value = effect.get("value")
            if not isinstance(value, (int, float, str)) or value == "":
                errors.append(f"{effect_path}.value: must be numeric or explicit text")
            if effect.get("status") not in ALLOWED_STATUSES:
                errors.append(f"{effect_path}.status: unsupported status")
            elif effect.get("status") in {"blocked", "new_runtime"}:
                warnings.append(
                    f"{node_id}: effect {effect.get('attribute')!r} is {effect.get('status')}"
                )

        if node.get("role") == "branch":
            family = node.get("branch_family")
            if not _nonempty_string(family):
                warnings.append(f"{node_id}: branch is missing branch_family")
            else:
                branch_family_nodes[family].append(node)
            non_tech_kinds = kinds - {"TECH_COMPLETED", "ALL_OF", "ANY_OF", "AT_LEAST", "NOT"}
            if not non_tech_kinds:
                warnings.append(f"{node_id}: branch entry condition uses technology only")
            if not node.get("tradeoffs"):
                warnings.append(f"{node_id}: branch has no explicit tradeoff")

    all_adjacency: dict[str, list[str]] = defaultdict(list)
    prerequisite_adjacency: dict[str, list[str]] = defaultdict(list)
    for index, edge in enumerate(edges):
        path = f"edges[{index}]"
        if not isinstance(edge, dict):
            errors.append(f"{path}: edge must be an object")
            continue
        source = edge.get("from")
        target = edge.get("to")
        kind = edge.get("kind")
        if source not in nodes_by_id:
            errors.append(f"{path}.from: unknown node {source!r}")
            continue
        if target not in nodes_by_id:
            errors.append(f"{path}.to: unknown node {target!r}")
            continue
        if source == target:
            errors.append(f"{path}: self-loop is not allowed")
            continue
        if kind not in ALLOWED_EDGE_KINDS:
            errors.append(f"{path}.kind: unsupported edge kind {kind!r}")
            continue
        all_adjacency[source].append(target)
        source_era = era_index.get(nodes_by_id[source].get("era"), -1)
        target_era = era_index.get(nodes_by_id[target].get("era"), -1)
        if kind in {"hard", "alternative"}:
            prerequisite_adjacency[source].append(target)
            if target_era < source_era:
                errors.append(f"{path}: research prerequisite points backward in era order")
        elif target_era < source_era and not _nonempty_string(edge.get("label")):
            warnings.append(f"{path}: backward application feedback needs a label")

    cycle = _find_cycle(prerequisite_adjacency, set(nodes_by_id))
    if cycle:
        errors.append(f"research prerequisite cycle: {' -> '.join(cycle)}")

    last_era_index = len(eras) - 1
    for node_id, node in nodes_by_id.items():
        if node.get("role") != "branch" or node.get("era") not in era_index:
            continue
        node_era = era_index[node["era"]]
        if node.get("terminal"):
            if not _nonempty_string(node.get("terminal_reason")):
                warnings.append(f"{node_id}: terminal branch should include terminal_reason")
            continue
        if node_era < last_era_index and not all_adjacency.get(node_id):
            errors.append(f"{node_id}: nonterminal branch has no successor")
        if node_era < last_era_index - 1 and not _reachable_later_branch(
            node_id,
            node_era,
            nodes_by_id,
            era_index,
            all_adjacency,
        ):
            warnings.append(f"{node_id}: branch does not reach a later branch within four hops")

    for family, family_nodes in sorted(branch_family_nodes.items()):
        family_eras = sorted({era_index[node["era"]] for node in family_nodes if node["era"] in era_index})
        if len(family_nodes) < 3:
            warnings.append(f"branch family {family!r}: fewer than three nodes")
        if family_eras and family_eras[-1] - family_eras[0] < 2:
            warnings.append(f"branch family {family!r}: spans fewer than three eras")

    for era in eras:
        if era_counts[era] == 0:
            errors.append(f"era {era!r}: contains no technology")
    if len(eras) == 11:
        early_average = sum(era_counts[era] for era in eras[:3]) / 3
        late_average = sum(era_counts[era] for era in eras[-3:]) / 3
        if early_average and late_average < early_average * 0.75:
            warnings.append(
                f"late eras are thin: average {late_average:.2f} versus early {early_average:.2f}"
            )

    branch_count = sum(1 for node in nodes_by_id.values() if node.get("role") == "branch")
    branch_ratio = branch_count / len(nodes_by_id) if nodes_by_id else 0.0
    if nodes_by_id and branch_ratio < 0.25:
        warnings.append(f"branch ratio is low: {branch_ratio:.1%}")
    if nodes_by_id and branch_ratio > 0.70:
        warnings.append(f"branch ratio is high: {branch_ratio:.1%}")

    metrics.update({
        "eras": len(eras),
        "nodes": len(nodes_by_id),
        "edges": len(edges),
        "branches": branch_count,
        "branch_ratio": round(branch_ratio, 4),
        "era_counts": {era: era_counts[era] for era in eras},
        "branch_families": len(branch_family_nodes),
    })
    return errors, warnings, metrics


def _self_test_design() -> dict[str, Any]:
    eras = [f"era_{index}" for index in range(11)]
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    for index, era in enumerate(eras):
        node_id = f"tech.backbone_{index}"
        nodes.append({
            "id": node_id,
            "name": f"Backbone {index}",
            "era": era,
            "domain": "engineering",
            "role": "backbone",
            "conditions": [{"kind": "TECH_COMPLETED", "id": "tech.foundation"}],
            "effects": [{
                "subject": "country",
                "attribute": "country.research.engineering_efficiency",
                "operation": "add_percent",
                "value": 5,
                "implementation": "modifier",
                "status": "modifier_only",
            }],
            "unlocks": [],
        })
        if index:
            edges.append({
                "from": f"tech.backbone_{index - 1}",
                "to": node_id,
                "kind": "hard",
            })
    branch_eras = [1, 4, 7, 10]
    for index, era_index_value in enumerate(branch_eras):
        node_id = f"tech.branch_{index}"
        nodes.append({
            "id": node_id,
            "name": f"Branch {index}",
            "era": eras[era_index_value],
            "domain": "agriculture",
            "role": "branch",
            "branch_family": "test_branch",
            "conditions": [
                {"kind": "TECH_COMPLETED", "id": f"tech.backbone_{era_index_value}"},
                {"kind": "SIGNAL_PRESENT", "id": "landform.mountain"},
            ],
            "unlocks": [{
                "type": "building",
                "id": f"building.branch_{index}",
                "status": "new_content",
            }],
            "effects": [{
                "subject": f"building.branch_{index}",
                "attribute": "base_output",
                "operation": "add_percent",
                "value": 30,
                "implementation": "building_profile_recipe",
                "status": "new_content",
            }],
            "tradeoffs": ["mountain_only"],
            "terminal": index == len(branch_eras) - 1,
            "terminal_reason": "final-era payoff" if index == len(branch_eras) - 1 else "",
        })
        edges.append({
            "from": f"tech.backbone_{era_index_value}",
            "to": node_id,
            "kind": "alternative",
        })
        if index:
            edges.append({
                "from": f"tech.branch_{index - 1}",
                "to": node_id,
                "kind": "alternative",
            })
    return {"eras": eras, "nodes": nodes, "edges": edges}


def _print_report(errors: list[str], warnings: list[str], metrics: dict[str, Any]) -> None:
    print(json.dumps(metrics, ensure_ascii=False, indent=2))
    if errors:
        print("\nERRORS")
        for message in errors:
            print(f"- {message}")
    if warnings:
        print("\nWARNINGS")
        for message in warnings:
            print(f"- {message}")
    if not errors and not warnings:
        print("\nOK: no audit findings")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("design", nargs="?", help="Path to design JSON")
    parser.add_argument("--strict", action="store_true", help="Fail when warnings are present")
    parser.add_argument("--self-test", action="store_true", help="Run the embedded valid-design test")
    args = parser.parse_args()

    if args.self_test:
        data = _self_test_design()
    elif args.design:
        try:
            data = json.loads(Path(args.design).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"ERROR: unable to read design: {exc}", file=sys.stderr)
            return 2
    else:
        parser.error("provide a design path or --self-test")

    errors, warnings, metrics = audit_design(data)
    _print_report(errors, warnings, metrics)
    if errors or (args.strict and warnings):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
