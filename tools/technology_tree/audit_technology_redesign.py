#!/usr/bin/env python3
"""Build a read-only audit package for the schema-v4 technology network.

The production network is deliberately never rewritten.  This tool copies the
authoring JSON into a review artifact, annotates each node with the kind of
redesign work it needs, and emits deterministic JSON/Markdown reports.
"""

from __future__ import annotations

import argparse
import copy
import json
from collections import Counter, defaultdict, deque
from pathlib import Path
from typing import Any


SUPPORTED_KINDS = {0: "TECH_COMPLETED", 1: "SIGNAL_PRESENT", 2: "SIGNAL_COUNT"}


def _atoms(condition: Any) -> tuple[set[str], set[str]]:
    techs: set[str] = set()
    signals: set[str] = set()
    if not isinstance(condition, dict) or not condition:
        return techs, signals
    if "kind" in condition:
        target = techs if int(condition.get("kind", -1)) == 0 else signals
        value = str(condition.get("id", "")).strip()
        if value:
            target.add(value)
        return techs, signals
    for child in condition.get("children", []):
        child_techs, child_signals = _atoms(child)
        techs.update(child_techs)
        signals.update(child_signals)
    return techs, signals


def _condition_summary(condition: Any) -> dict[str, Any]:
    techs, signals = _atoms(condition)
    kinds: set[str] = set()

    def visit(value: Any) -> None:
        if not isinstance(value, dict) or not value:
            return
        if "kind" in value:
            kinds.add(SUPPORTED_KINDS.get(int(value.get("kind", -1)), "UNKNOWN"))
            return
        operator = value.get("operator")
        kinds.add({1: "ALL_OF", 2: "ANY_OF", 3: "AT_LEAST", 5: "NOT"}.get(
            int(operator) if isinstance(operator, (int, float)) else -1, "UNKNOWN"))
        for child in value.get("children", []):
            visit(child)

    visit(condition)
    return {"technology_ids": sorted(techs), "signal_ids": sorted(signals),
            "kinds": sorted(kinds)}


def _closure_cycle(nodes_by_id: dict[str, dict[str, Any]]) -> list[str]:
    graph: dict[str, list[str]] = defaultdict(list)
    for node_id, node in nodes_by_id.items():
        for prerequisite in node.get("hard_prerequisite_ids", []):
            graph[str(prerequisite)].append(node_id)
    state: dict[str, int] = {}
    stack: list[str] = []

    def visit(node_id: str) -> list[str]:
        state[node_id] = 1
        stack.append(node_id)
        for successor in graph.get(node_id, []):
            if state.get(successor, 0) == 0:
                cycle = visit(successor)
                if cycle:
                    return cycle
            elif state.get(successor) == 1:
                return stack[stack.index(successor):] + [successor]
        stack.pop()
        state[node_id] = 2
        return []

    for node_id in sorted(nodes_by_id):
        if state.get(node_id, 0) == 0:
            cycle = visit(node_id)
            if cycle:
                return cycle
    return []


def audit(source: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    nodes = source.get("nodes", [])
    eras = source.get("eras", [])
    era_ids = [str(era.get("id", "")) for era in eras]
    era_index = {era_id: index for index, era_id in enumerate(era_ids)}
    nodes_by_id = {str(node.get("id")): node for node in nodes}

    era_counts: Counter[str] = Counter()
    domain_counts: Counter[str] = Counter()
    role_counts: Counter[str] = Counter()
    family_nodes: dict[str, list[dict[str, Any]]] = defaultdict(list)
    duplicate_bindings: dict[str, list[str]] = defaultdict(list)
    binding_inventory: dict[str, list[dict[str, str]]] = defaultdict(list)
    findings: list[dict[str, Any]] = []
    counters = Counter()

    for node in nodes:
        node_id = str(node.get("id", ""))
        era = str(node.get("era_id", ""))
        domain = str(node.get("domain_id", ""))
        role = str(node.get("network_role", ""))
        era_counts[era] += 1
        domain_counts[domain] += 1
        role_counts[role] += 1
        family = str(node.get("branch_family_id", ""))
        if family:
            family_nodes[family].append(node)
        for binding in node.get("expected_bindings", []):
            binding_id = str(binding.get("id", ""))
            if binding_id:
                duplicate_bindings[binding_id].append(node_id)
                binding_inventory[str(binding.get("kind", "unknown"))].append({
                    "id": binding_id,
                    "technology_id": node_id,
                })

        reveal = _condition_summary(node.get("reveal_condition", {}))
        route_signals: set[str] = set()
        for route in node.get("research_routes", []):
            route_signals.update(_atoms(route.get("condition", {}))[1])
        review: list[str] = []
        if role == "branch" and not node.get("branch_successor_ids") and not node.get("terminal_reason"):
            review.append("topology_review")
            counters["nonterminal_branch_without_successor"] += 1
        if not node.get("content_effects") and not node.get("modifier_terms"):
            review.append("content_review")
            counters["no_direct_effect_or_unlock"] += 1
        if era_index.get(era, 0) >= 2 and not node.get("research_routes"):
            review.append("route_review")
            counters["kingdom_plus_without_route"] += 1
        if set(reveal["signal_ids"]) & route_signals:
            review.append("reveal_route_overlap")
            counters["reveal_route_signal_overlap"] += 1
        if not review:
            review.append("retain_or_minor_rebind")
        findings.append({"id": node_id, "era_id": era, "domain_id": domain,
                         "branch_family_id": family, "review": review,
                         "condition_summary": reveal})

    family_metrics = {}
    for family, family_values in sorted(family_nodes.items()):
        family_eras = sorted({era_index.get(str(node.get("era_id", "")), -1)
                              for node in family_values})
        family_metrics[family] = {
            "nodes": len(family_values),
            "era_span": [family_eras[0], family_eras[-1]] if family_eras else [],
            "era_count": len(family_eras),
            "nodes_without_successor": sum(
                not node.get("branch_successor_ids") and not node.get("terminal_reason")
                for node in family_values),
        }

    duplicate_binding_findings = [
        {"binding_id": binding_id, "technology_ids": sorted(set(technology_ids))}
        for binding_id, technology_ids in sorted(duplicate_bindings.items())
        if len(set(technology_ids)) > 1
    ]
    cycle = _closure_cycle(nodes_by_id)
    counters["duplicate_binding_groups"] = len(duplicate_binding_findings)
    counters["hard_prerequisite_cycles"] = int(bool(cycle))

    review_artifact = copy.deepcopy(source)
    review_artifact["redesign_review"] = {
        "format": "project_keynes_technology_redesign_v1",
        "source_schema_version": source.get("schema_version"),
        "production_source": "Project/project-keynes/data/technology/technology_network.json",
        "stable_id_policy": "preserve_when_possible",
        "runtime_policy": "no_new_technology_runtime",
        "supported_condition_kinds": ["TECH_COMPLETED", "SIGNAL_PRESENT",
            "SIGNAL_COUNT", "ALL_OF", "ANY_OF", "AT_LEAST", "NOT"],
        "review_status": "baseline_audit",
    }
    findings_by_id = {item["id"]: item for item in findings}
    for node in review_artifact.get("nodes", []):
        node["redesign_review"] = findings_by_id.get(str(node.get("id")), {})

    report = {
        "format": "project_keynes_technology_redesign_audit_v1",
        "source_schema_version": source.get("schema_version"),
        "source_path": "Project/project-keynes/data/technology/technology_network.json",
        "nodes": len(nodes),
        "application_intersections": len(source.get("application_intersections", [])),
        "eras": len(eras),
        "era_counts": dict(era_counts),
        "domain_counts": dict(domain_counts),
        "role_counts": dict(role_counts),
        "branch_families": family_metrics,
        "counters": dict(counters),
        "hard_prerequisite_cycle": cycle,
        "duplicate_binding_groups": duplicate_binding_findings,
        "content_binding_inventory": {
            kind: sorted(values, key=lambda item: (item["id"], item["technology_id"]))
            for kind, values in sorted(binding_inventory.items())
        },
        "node_reviews": findings,
        "implementation_waves": [
            {"wave": 1, "name": "backbones_and_milestones",
             "focus": "主干、时代里程碑、硬前置和首批研究入口"},
            {"wave": 2, "name": "core_industry_branches",
             "focus": "农业、畜牧、材料、水利、贸易和测量"},
            {"wave": 3, "name": "modern_capabilities",
             "focus": "能源、控制、信息、生物和智能时代"},
            {"wave": 4, "name": "long_tail_and_presentation",
             "focus": "低影响长尾、重复内容、中文展示和来源追溯"},
        ],
    }
    return review_artifact, report


def write_markdown(report: dict[str, Any], path: Path) -> None:
    counters = report["counters"]
    lines = [
        "# Project Keynes 科技树重构基线审计",
        "",
        "本报告由 `audit_technology_redesign.py` 从 schema v4 权威源生成。它不修改生产科技网络。",
        "",
        "## 总览",
        "",
        f"- 节点：{report['nodes']}；应用交汇：{report['application_intersections']}；时代：{report['eras']}",
        f"- 时代分布：{json.dumps(report['era_counts'], ensure_ascii=False)}",
        f"- 领域分布：{json.dumps(report['domain_counts'], ensure_ascii=False)}",
        f"- 角色分布：{json.dumps(report['role_counts'], ensure_ascii=False)}",
        "",
        "## 需要重构的基线问题",
        "",
        f"- 非终端支线无后继：{counters.get('nonterminal_branch_without_successor', 0)}",
        f"- 无直接效果或解锁摘要：{counters.get('no_direct_effect_or_unlock', 0)}",
        f"- Kingdom 及以后没有 research route：{counters.get('kingdom_plus_without_route', 0)}",
        f"- reveal 与 route 信号重叠：{counters.get('reveal_route_signal_overlap', 0)}",
        f"- 重复绑定组：{counters.get('duplicate_binding_groups', 0)}",
        f"- 硬前置循环：{counters.get('hard_prerequisite_cycles', 0)}",
        "",
        "## 分支族群",
        "",
        "| branch family | 节点 | 时代跨度 | 时代数 | 无后继节点 |",
        "|---|---:|---:|---:|---:|",
    ]
    for family, values in report["branch_families"].items():
        span = values["era_span"]
        span_text = f"{span[0]}–{span[1]}" if span else "-"
        lines.append(f"| `{family}` | {values['nodes']} | {span_text} | {values['era_count']} | {values['nodes_without_successor']} |")
    lines += [
        "",
        "## 实施顺序",
        "",
    ]
    for wave in report["implementation_waves"]:
        lines.append(f"{wave['wave']}. **{wave['name']}**：{wave['focus']}")
    lines += [
        "",
        "## 分类规则",
        "",
        "- `topology_review`：支线没有后继且没有明确终端理由。",
        "- `content_review`：没有内容效果或 Modifier 记录，需要绑定真实对象或明确标记为发现型节点。",
        "- `route_review`：Kingdom 以后没有 research route，需要补充独立证据入口或写明豁免理由。",
        "- `reveal_route_overlap`：同一信号同时承担发现和路线条件，需要拆分。",
        "- `retain_or_minor_rebind`：当前基线没有触发上述审计项，仍需在内容波次中复核名称与效果关联。",
        "",
        "## 兼容边界",
        "",
        "- 本报告不改变 stable ID、catalog hash、存档 schema 或运行时 authority。",
        "- 生产修改必须继续通过 TechnologyCatalog、Country、Economy、Effect、Modifier 和 UI 现有验证链。",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="Project/project-keynes/data/technology/technology_network.json")
    parser.add_argument("--design", default="tools/technology_tree/technology_tree_redesign_v1.json")
    parser.add_argument("--report", default="tools/technology_tree/technology_tree_redesign_audit.json")
    parser.add_argument("--markdown", default="docs/technology-tree-redesign-audit.md")
    args = parser.parse_args()

    source_path = Path(args.source)
    source = json.loads(source_path.read_text(encoding="utf-8"))
    design, report = audit(source)
    for target, payload in ((Path(args.design), design), (Path(args.report), report)):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    markdown_path = Path(args.markdown)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(report, markdown_path)
    print(json.dumps({"design": args.design, "report": args.report, "markdown": args.markdown,
                      "counters": report["counters"]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
