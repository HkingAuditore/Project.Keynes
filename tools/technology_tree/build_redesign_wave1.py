#!/usr/bin/env python3
"""Build the first reviewable redesign wave without changing the live catalog."""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Project/project-keynes/data/technology/technology_network.json"
BASELINE = ROOT / "tools/technology_tree/technology_tree_redesign_audit.json"
DEST = ROOT / "tools/technology_tree/technology_tree_redesign_wave1.json"
REPORT = ROOT / "docs/technology-tree-redesign-wave1.md"

CORE_BRANCHES = {
    "branch.rice_irrigation", "branch.heavy_industry", "branch.commerce_finance",
    "branch.computation_control", "branch.public_health", "branch.water_wind",
}

# These are design edges. They are intentionally not copied into the production
# hard-prerequisite graph until the content and closure tests have passed.
PROPOSALS = {
    "tech.wind_power": {
        "decision": "rebind_prerequisite",
        "proposed_hard_prerequisite_ids": ["tech.composite_tools"],
        "rationale": "风力机械需要传动和机械工具；地表煤使用与风力机理无关。",
        "status": "catalog_rebind",
    },
    "tech.urban_sanitation": {
        "decision": "rebind_prerequisite",
        "proposed_hard_prerequisite_ids": ["tech.permanent_settlements"],
        "rationale": "城市卫生的必要背景是定居与聚居，盐腌保存不是卫生设施的核心知识。",
        "status": "catalog_rebind",
    },
    "tech.coal_geology": {
        "decision": "rebind_prerequisite",
        "proposed_hard_prerequisite_ids": ["tech.coal_outcrop_identification"],
        "rationale": "煤层地质研究应建立在煤露头识别之上；特许公司属于可选组织路线。",
        "status": "catalog_rebind",
    },
    "tech.precision_irrigation": {
        "decision": "strengthen_branch_continuity",
        "proposed_hard_prerequisite_ids": ["tech.hydraulic_engineering", "tech.electronic_control"],
        "proposed_application_predecessor_ids": ["tech.rice_water_control"],
        "rationale": "保持水工与控制的硬基础，把水稻水位实践作为可见的应用血缘。",
        "status": "existing_binding",
    },
    "tech.adaptive_irrigation": {
        "decision": "strengthen_branch_continuity",
        "proposed_core_prerequisite_ids": ["tech.precision_irrigation", "tech.autonomous_systems"],
        "proposed_application_predecessor_ids": ["tech.precision_irrigation"],
        "rationale": "自适应灌溉的核心是精准水控与自主控制；育种、物流和管理作为相关应用路线，不再全部阻塞研究。",
        "status": "catalog_rebind",
    },
    "tech.digital_marketplaces": {
        "decision": "strengthen_branch_continuity",
        "proposed_application_predecessor_ids": ["tech.market_institutions", "tech.double_entry_bookkeeping"],
        "rationale": "数字市场不仅依赖联网，也继承交易制度与记账能力；后两者先作应用关系审查。",
        "status": "catalog_rebind",
    },
    "tech.public_health_systems": {
        "decision": "strengthen_branch_continuity",
        "proposed_application_predecessor_ids": ["tech.urban_sanitation", "tech.public_health"],
        "rationale": "建立从环境卫生到公共卫生制度的可读支线，不额外堆叠硬前置。",
        "status": "catalog_rebind",
    },
    "tech.networked_computing": {
        "decision": "review_overloaded_prerequisites",
        "proposed_core_prerequisite_ids": ["tech.software_engineering", "tech.telecommunications", "tech.information_theory"],
        "proposed_application_predecessor_ids": ["tech.semiconductor_manufacturing", "tech.advanced_metallurgy"],
        "rationale": "把计算/通信原理与具体材料供应链分层；完整硬前置缩减须先通过解锁闭包。",
        "status": "blocked",
    },
    "tech.machine_learning": {
        "decision": "review_overloaded_prerequisites",
        "proposed_core_prerequisite_ids": ["tech.systems_engineering", "tech.digital_computing"],
        "proposed_application_predecessor_ids": ["tech.semiconductor_manufacturing", "tech.precision_engineering"],
        "rationale": "算法能力与芯片、矿物、精密加工供应链分层；先审闭包与路线可达性。",
        "status": "blocked",
    },
}

CHAINS = [
    ["tech.gathering", "tech.food_storage", "tech.public_storehouses", "tech.urban_food_supply", "tech.regional_granaries"],
    ["tech.composite_tools", "tech.plough_agriculture", "tech.machine_tools", "tech.electronic_control", "tech.digital_control", "tech.autonomous_systems"],
    ["tech.natural_observation", "tech.writing", "tech.experimental_science", "tech.industrial_research", "tech.national_laboratories"],
    ["tech.early_trade", "tech.market_institutions", "tech.mercantile_networks", "tech.digital_marketplaces"],
    ["tech.rice_identification", "tech.rice_paddy_cultivation", "tech.rice_water_control", "tech.precision_irrigation", "tech.adaptive_irrigation"],
    ["tech.coal_outcrop_identification", "tech.coal_mining", "tech.deep_mining", "tech.industrial_coal_mining", "tech.mechanized_mining", "tech.autonomous_mining"],
    ["tech.urban_sanitation", "tech.public_health", "tech.modern_medicine", "tech.public_health_systems"],
    ["tech.radio", "tech.telecommunications", "tech.networked_computing", "tech.distributed_intelligence"],
]


def build() -> tuple[dict, str]:
    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    nodes = {node["id"]: node for node in source["nodes"]}
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    baseline_reviews = {entry["id"]: entry["review"]
                        for entry in baseline.get("node_reviews", [])}
    era_ids = [era["id"] for era in source["eras"]]
    era_index = {era_id: index for index, era_id in enumerate(era_ids)}
    selected = {
        node_id for node_id, node in nodes.items()
        if node.get("network_role") == "backbone" or node.get("is_milestone")
        or node.get("branch_family_id") in CORE_BRANCHES
    }
    selected.update(PROPOSALS)
    for chain in CHAINS:
        selected.update(chain)
    missing = selected - nodes.keys()
    if missing:
        raise ValueError(f"unknown technology IDs: {sorted(missing)}")
    for node_id, proposal in PROPOSALS.items():
        target_era = era_index[nodes[node_id]["era_id"]]
        for field in ("proposed_hard_prerequisite_ids", "proposed_core_prerequisite_ids",
                      "proposed_application_predecessor_ids"):
            for predecessor in proposal.get(field, []):
                if predecessor not in nodes:
                    raise ValueError(f"{node_id}: unknown {field} reference {predecessor}")
                if era_index[nodes[predecessor]["era_id"]] > target_era:
                    raise ValueError(f"{node_id}: later-era {field} reference {predecessor}")

    chain_successors: dict[str, list[str]] = defaultdict(list)
    for chain in CHAINS:
        for predecessor, successor in zip(chain, chain[1:]):
            if era_index[nodes[successor]["era_id"]] < era_index[nodes[predecessor]["era_id"]]:
                raise ValueError(f"backward era chain: {predecessor} -> {successor}")
            chain_successors[predecessor].append(successor)

    # A proposed hard edge must not create a cycle in the complete production
    # graph, including nodes outside the first design wave.
    hard = {node_id: list(PROPOSALS.get(node_id, {}).get(
        "proposed_core_prerequisite_ids",
        PROPOSALS.get(node_id, {}).get("proposed_hard_prerequisite_ids",
        node.get("hard_prerequisite_ids", []))))
        for node_id, node in nodes.items()}
    state: dict[str, int] = {}

    def visit(node_id: str) -> None:
        if state.get(node_id) == 1:
            raise ValueError(f"proposed hard prerequisite cycle at {node_id}")
        if state.get(node_id) == 2:
            return
        state[node_id] = 1
        for predecessor in hard[node_id]:
            visit(predecessor)
        state[node_id] = 2

    for node_id in nodes:
        visit(node_id)

    records = []
    for node in source["nodes"]:
        node_id = node["id"]
        if node_id not in selected:
            continue
        proposal = PROPOSALS.get(node_id, {})
        review_flags = baseline_reviews.get(node_id, [])
        inferred_decision = (
            "repair_content_binding" if "content_review" in review_flags else
            "repair_branch_continuity" if "topology_review" in review_flags else
            "repair_research_route" if "route_review" in review_flags else
            "retain_then_review_binding")
        records.append({
            "id": node_id,
            "display_name": node.get("display_name", ""),
            "era_id": node["era_id"],
            "domain_id": node["domain_id"],
            "network_role": node["network_role"],
            "branch_family_id": node.get("branch_family_id", ""),
            "is_milestone": bool(node.get("is_milestone")),
            "current_hard_prerequisite_ids": node.get("hard_prerequisite_ids", []),
            "proposed_hard_prerequisite_ids": proposal.get(
                "proposed_core_prerequisite_ids",
                proposal.get("proposed_hard_prerequisite_ids", node.get("hard_prerequisite_ids", []))),
            "current_reveal_condition": node.get("reveal_condition", {}),
            "current_research_routes": node.get("research_routes", []),
            "current_content_effects": node.get("content_effects", []),
            "current_modifier_terms": node.get("modifier_terms", []),
            "current_expected_bindings": node.get("expected_bindings", []),
            "current_branch_successor_ids": node.get("branch_successor_ids", []),
            "proposed_relation_successor_ids": chain_successors.get(node_id, []),
            "proposed_application_predecessor_ids": proposal.get(
                "proposed_application_predecessor_ids", []),
            "proposed_core_prerequisite_ids": proposal.get("proposed_core_prerequisite_ids", []),
            "review_flags": review_flags,
            "decision": proposal.get("decision", inferred_decision),
            "rationale": proposal.get("rationale", "保持 stable ID，按主干/支线阶段审查内容与入口。"),
            "implementation_status": proposal.get("status", "existing_binding"),
        })

    # Sparse causal edges plus explicit related/application edges.  This keeps
    # the graph readable without turning every useful relationship into a gate.
    node_by_id = {record["id"]: record for record in records}
    edge_rows: list[dict[str, str]] = []
    seen_edges: set[tuple[str, str, str]] = set()

    def add_edge(source: str, target: str, kind: str, label: str, rationale: str) -> None:
        if source not in node_by_id or target not in node_by_id or source == target:
            return
        key = (source, target, kind)
        if key in seen_edges:
            return
        seen_edges.add(key)
        edge_rows.append({"from": source, "to": target, "kind": kind,
                          "label": label, "rationale": rationale})

    for record in records:
        node = nodes[record["id"]]
        for predecessor in record["proposed_hard_prerequisite_ids"]:
            add_edge(predecessor, record["id"], "hard", "core prerequisite",
                     "不可替代的核心知识")
        for successor in chain_successors.get(record["id"], []):
            add_edge(record["id"], successor, "related", "capability continuation",
                     "能力链后继；不自动成为硬前置")
        for successor in node.get("branch_successor_ids", []):
            add_edge(record["id"], str(successor), "related", "branch successor",
                     "现有支线后继；先作为可见关联边")
        for predecessor in record["proposed_application_predecessor_ids"]:
            add_edge(predecessor, record["id"], "application", "application intersection",
                     "应用交汇或产业关联；不阻塞研究完成")

    centrality = defaultdict(int)
    for edge in edge_rows:
        centrality[edge["from"]] += 1
        centrality[edge["to"]] += 1
    for record in records:
        node = nodes[record["id"]]
        if node.get("is_milestone"):
            tier = 1
        elif node.get("network_role") == "backbone" and centrality[record["id"]] >= 3:
            tier = 1
        elif centrality[record["id"]] >= 3:
            tier = 2
        elif record["decision"] in {"repair_content_binding", "repair_research_route"}:
            tier = 4
        else:
            tier = 3
        record["importance_tier"] = tier

    milestone_gates = []
    for index, era in enumerate(source["eras"]):
        milestone_id = era["milestone_id"]
        milestone_gates.append({
            "era_id": era["id"],
            "milestone_id": milestone_id,
            "previous_era_milestone_id": source["eras"][index - 1]["milestone_id"] if index else "",
            "candidate_required": era["candidate_required"],
            "candidate_ids": era.get("milestone_candidate_ids", []),
            "policy": "保留现有候选门槛；前一时代里程碑只作为下个里程碑门槛，不注入普通科技硬前置。",
        })
    design = {
        "format": "project_keynes_technology_redesign_wave1_v1",
        "reference_model": {
            "project": "secwind7/polytech-tree",
            "data_files": ["data/techs.json", "data/eras.json", "data/categories.json", "data/core-ids.json"],
            "adopted_topology": ["hard_prerequisite", "alternative_evidence", "related_application_feedback", "importance_tier"],
            "license_boundary": "reference topology only; no source data copied",
        },
        "source_schema_version": source["schema_version"],
        "source_path": str(SOURCE.relative_to(ROOT)).replace("\\", "/"),
        "production_network_changed": False,
        "stable_id_policy": "preserve",
        "eras": era_ids,
        "backbone_ids": [item["id"] for item in source["backbones"]],
        "core_branch_ids": sorted(CORE_BRANCHES),
        "milestone_gates": milestone_gates,
        "relation_chains": CHAINS,
        "topology_edges": edge_rows,
        "nodes": records,
        "implementation_gates": [
            "verify proposed hard prerequisite acyclicity and topological order",
            "verify every building/good/resource unlock closure before catalog rebind",
            "verify research signal reachability and route independence",
            "verify catalog identity/save rejection behavior after production changes",
        ],
    }
    explicit = [record for record in records if record["id"] in PROPOSALS]
    decision_counts = defaultdict(int)
    for record in records:
        decision_counts[record["decision"]] += 1
    lines = [
        "# 科技树 Wave 1 设计差异",
        "",
        "本稿只记录提案，不修改生产 `technology_network.json`。当前硬前置与效果均从权威源复制。",
        "",
        f"- 覆盖节点：{len(records)}（4 条主干、11 个时代里程碑与 6 条核心支线及其连接节点）。",
        f"- 明确变更提案：{len(explicit)}；关系链：{len(CHAINS)}。",
        f"- 拓扑边：{len(design['topology_edges'])}；硬前置 {sum(edge['kind'] == 'hard' for edge in design['topology_edges'])}，相关/应用边 {sum(edge['kind'] != 'hard' for edge in design['topology_edges'])}。",
        f"- 重要度层级：{json.dumps(dict(sorted(Counter(node['importance_tier'] for node in records).items())), ensure_ascii=False)}",
        f"- 节点处理分类：{json.dumps(dict(sorted(decision_counts.items())), ensure_ascii=False)}",
        "- 所有 ID 保留；里程碑候选数量与门槛保持现状。",
        "",
        "## 优先差异",
        "",
        "| 科技 | 当前硬前置 | 拟议核心前置 | 决策 |",
        "|---|---|---|---|",
    ]
    for record in explicit:
        current = ", ".join(record["current_hard_prerequisite_ids"]) or "无"
        proposed = ", ".join(record["proposed_hard_prerequisite_ids"]) or "无"
        lines.append(f"| `{record['id']}` | {current} | {proposed} | {record['decision']} |")
    lines += ["", "## 关系链", ""]
    for chain in CHAINS:
        lines.append("- " + " → ".join(f"`{node_id}`" for node_id in chain))
    lines += ["", "## 生产实施门槛", ""]
    for gate in design["implementation_gates"]:
        lines.append(f"- {gate}")
    lines += [
        "", "`blocked` 提案仅表示还需先核对内容闭包，不是已经进入生产的硬前置变更。",
        "关系链是解释性设计边；是否升级为硬前置由不可替代知识和闭包测试决定。",
    ]
    return design, "\n".join(lines) + "\n"


def write_csv(design: dict) -> None:
    import csv

    node_path = ROOT / "tools/technology_tree/technology_tree_redesign_wave1_nodes.csv"
    edge_path = ROOT / "tools/technology_tree/technology_tree_redesign_wave1_edges.csv"
    with node_path.open("w", encoding="utf-8-sig", newline="") as handle:
        fields = ["id", "display_name", "era_id", "domain_id", "network_role",
                  "branch_family_id", "importance_tier", "decision", "implementation_status"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for node in design["nodes"]:
            writer.writerow({field: node.get(field, "") for field in fields})
    with edge_path.open("w", encoding="utf-8-sig", newline="") as handle:
        fields = ["from", "to", "kind", "label", "rationale"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(design["topology_edges"])


def main() -> int:
    design, report = build()
    DEST.write_text(json.dumps(design, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    REPORT.write_text(report, encoding="utf-8")
    write_csv(design)
    print(f"Wave 1: {len(design['nodes'])} nodes, {len(design['relation_chains'])} chains, "
          f"{len(design['milestone_gates'])} milestones")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
