#!/usr/bin/env python3
"""One-shot migration from the generated lane grid to explicit technology schema v2.

The output is the sole authoring source.  This script deliberately does not run as
part of the game or normal authoring validation; it exists so the v1 -> v2 rewrite
is reproducible and reviewable.
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "data" / "technology" / "technology_network.json"

ERAS = [
    "stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
    "steam", "electrical", "atomic", "information", "intelligent",
]

CANDIDATES = {
    "stone": ["crop_domestication", "composite_tools", "natural_observation", "communal_specialization", "wild_maize_collection", "hand_pottery", "seasonal_calendar", "early_trade"],
    "agrarian": ["seed_selection", "plough_agriculture", "celestial_calendars", "permanent_settlements", "rice_paddy_cultivation", "bronze_casting", "irrigation_surveying", "record_keeping"],
    "kingdom": ["crop_rotation", "road_engineering", "writing", "state_bureaucracy", "tenant_paddy_management", "iron_smelting", "natural_philosophy", "market_institutions"],
    "empire": ["intensive_crop_rotation", "movable_type_printing", "scholastic_method", "guild_organization", "forest_management", "blast_furnace", "magnetic_navigation", "regional_granaries"],
    "exploration": ["agronomic_exchange", "mechanical_timekeeping", "cartography", "double_entry_bookkeeping", "crop_acclimatization", "oceanic_ship_design", "interregional_botany", "chartered_companies"],
    "enlightenment": ["agricultural_improvement", "standardization", "experimental_science", "cooperative_association", "crop_breeding", "atmospheric_engine", "scientific_classification", "property_cadastre"],
    "steam": ["mechanized_agriculture", "machine_tools", "thermodynamics", "factory_system", "fertilizer_processing", "steam_power", "industrial_chemistry", "labor_organization"],
    "electrical": ["motorized_agriculture", "electrification", "industrial_research", "public_education", "modern_husbandry", "electric_grid", "modern_medicine", "corporate_management"],
    "atomic": ["industrial_agronomy", "electronic_control", "national_laboratories", "state_enterprises", "corporate_agribusiness", "nuclear_energy", "deep_geophysics", "global_logistics"],
    "information": ["precision_agriculture", "digital_control", "digital_computing", "knowledge_economy", "precision_irrigation", "semiconductor_manufacturing", "satellite_observation", "platform_coordination"],
    "intelligent": ["automated_agriculture", "autonomous_systems", "machine_learning", "human_machine_cogovernance", "intelligent_breeding", "robotic_manufacturing", "climate_modeling", "algorithmic_governance"],
}

PUBLIC_PREREQUISITES = {
    "tech.crop_domestication": [],
    "tech.composite_tools": [],
    "tech.natural_observation": [],
    "tech.communal_specialization": ["tech.composite_tools"],
    "tech.seed_selection": ["tech.crop_domestication"],
    "tech.plough_agriculture": ["tech.composite_tools"],
    "tech.celestial_calendars": ["tech.natural_observation"],
    "tech.permanent_settlements": ["tech.communal_specialization"],
    "tech.crop_rotation": ["tech.seed_selection", "tech.plough_agriculture"],
    "tech.road_engineering": ["tech.permanent_settlements", "tech.plough_agriculture"],
    "tech.writing": ["tech.celestial_calendars", "tech.permanent_settlements"],
    "tech.state_bureaucracy": ["tech.writing", "tech.permanent_settlements"],
    "tech.intensive_crop_rotation": ["tech.crop_rotation"],
    "tech.movable_type_printing": ["tech.writing", "tech.composite_tools"],
    "tech.scholastic_method": ["tech.writing", "tech.state_bureaucracy"],
    "tech.guild_organization": ["tech.state_bureaucracy", "tech.road_engineering"],
    "tech.agronomic_exchange": ["tech.intensive_crop_rotation", "tech.guild_organization"],
    "tech.mechanical_timekeeping": ["tech.road_engineering", "tech.scholastic_method"],
    "tech.cartography": ["tech.writing", "tech.road_engineering", "tech.celestial_calendars"],
    "tech.double_entry_bookkeeping": ["tech.writing", "tech.guild_organization"],
    "tech.agricultural_improvement": ["tech.agronomic_exchange"],
    "tech.standardization": ["tech.cartography", "tech.mechanical_timekeeping"],
    "tech.experimental_science": ["tech.scholastic_method", "tech.mechanical_timekeeping"],
    "tech.cooperative_association": ["tech.double_entry_bookkeeping", "tech.guild_organization"],
    "tech.mechanized_agriculture": ["tech.agricultural_improvement", "tech.standardization"],
    "tech.machine_tools": ["tech.standardization", "tech.guild_organization"],
    "tech.thermodynamics": ["tech.experimental_science", "tech.mechanical_timekeeping"],
    "tech.factory_system": ["tech.standardization", "tech.cooperative_association"],
    "tech.motorized_agriculture": ["tech.mechanized_agriculture", "tech.thermodynamics"],
    "tech.electrification": ["tech.thermodynamics", "tech.machine_tools"],
    "tech.industrial_research": ["tech.experimental_science", "tech.factory_system"],
    "tech.public_education": ["tech.cooperative_association", "tech.factory_system"],
    "tech.industrial_agronomy": ["tech.motorized_agriculture", "tech.industrial_research"],
    "tech.electronic_control": ["tech.electrification", "tech.industrial_research"],
    "tech.national_laboratories": ["tech.industrial_research", "tech.public_education"],
    "tech.state_enterprises": ["tech.factory_system", "tech.cooperative_association"],
    "tech.precision_agriculture": ["tech.industrial_agronomy", "tech.electronic_control"],
    "tech.digital_control": ["tech.electronic_control"],
    "tech.digital_computing": ["tech.electronic_control", "tech.national_laboratories"],
    "tech.knowledge_economy": ["tech.public_education", "tech.national_laboratories"],
    "tech.automated_agriculture": ["tech.precision_agriculture", "tech.digital_control"],
    "tech.autonomous_systems": ["tech.digital_control", "tech.digital_computing"],
    "tech.machine_learning": ["tech.digital_computing", "tech.national_laboratories"],
    "tech.human_machine_cogovernance": ["tech.knowledge_economy", "tech.digital_control"],
}
CANDIDATES = {era: [f"tech.{value}" for value in values] for era, values in CANDIDATES.items()}

FAMILY_ROWS = [
    ("branch.maize_horticulture", "玉米与园圃农业"),
    ("branch.wheat_rainfed", "小麦、谷物与雨养农业"),
    ("branch.rice_irrigation", "水稻、水田与灌溉农业"),
    ("branch.tuber_highland", "块茎、梯田与高地农业"),
    ("branch.pastoral_livestock", "草原、马匹与畜牧业"),
    ("branch.tropical_commodities", "热带作物与商品农业"),
    ("branch.forest_biomass", "森林、木材、造纸与生物质"),
    ("branch.maritime_logistics", "渔业、航海、港口与海运物流"),
    ("branch.textile_fibers", "纤维、纺织、服装与合成纤维"),
    ("branch.construction_materials", "黏土、石材、玻璃、建筑与公共工程"),
    ("branch.nonferrous_metals", "铜、锡、有色金属与特种合金"),
    ("branch.heavy_industry", "铁、煤、矿井、蒸汽与重工业"),
    ("branch.industrial_chemistry", "盐、硫、肥料、炸药与工业化学"),
    ("branch.petroleum_materials", "石油、内燃机、石化与合成材料"),
    ("branch.water_wind", "水力、风力、水务与流域工程"),
    ("branch.electric_intelligent_energy", "电力、核能、电网与智能能源"),
    ("branch.land_institutions", "土地产权、租佃与乡村制度"),
    ("branch.commerce_finance", "商业、金融、会计与公司组织"),
    ("branch.labor_management", "劳工、管理与生产组织"),
    ("branch.measurement_instruments", "测量、标准化与精密仪器"),
    ("branch.natural_history", "自然史、生物学与育种科学"),
    ("branch.public_health", "医学、卫生与公共健康"),
    ("branch.geoscience_gis", "制图、地学、遥感与空间分析"),
    ("branch.computation_control", "计算、控制、网络与机器智能"),
]

FAMILY_PATTERNS = [
    ("branch.land_institutions", ("tenancy", "lease", "landholding", "sharecropping", "manorial", "serf_obligations", "estate_accounting", "property_cadastre", "communal_field")),
    ("branch.commerce_finance", ("trade", "market", "currency", "bookkeeping", "mercantile", "chartered_companies", "commercial_", "digital_marketplaces")),
    ("branch.labor_management", ("labor", "wage_", "guild_", "factory_system", "managerial", "worker_cooperatives", "corporate_management", "algorithmic_management", "industrial_organization")),
    ("branch.measurement_instruments", ("calendar", "weights_and_measures", "timekeeping", "precision_instruments", "standardization", "quality_control", "probability_statistics", "industrial_statistics")),
    ("branch.natural_history", ("natural_observation", "phenology", "botany", "classification", "breeding", "biotechnology", "bioinformatics", "computational_biology", "acclimatization")),
    ("branch.public_health", ("sanitation", "public_health", "modern_medicine", "refrigeration", "cold_chain")),
    ("branch.geoscience_gis", ("cartography", "geological", "geophysics", "spectral_survey", "satellite_observation", "remote_sensing", "geographic_information", "weather_prediction", "climate_modeling")),
    ("branch.computation_control", ("information_theory", "digital_", "software", "networked_computing", "semiconductor", "sensor_networks", "machine_learning", "neural_networks", "autonomous_systems", "robotic", "distributed_intelligence", "scientific_agents", "human_machine_", "algorithmic_governance", "platform_coordination")),
]

COMPLEX_PREREQUISITES = {
    "tech.property_cadastre": ["tech.cartography", "tech.long_term_leases", "tech.estate_accounting", "tech.weights_and_measures"],
    "tech.scientific_classification": ["tech.natural_philosophy"],
    "tech.atmospheric_engine": ["tech.mine_drainage", "tech.mechanical_workshops", "tech.blast_furnace"],
    "tech.geographic_information_systems": ["tech.cartography", "tech.digital_computing", "tech.probability_statistics"],
    "tech.nuclear_energy": ["tech.nuclear_fission", "tech.advanced_metallurgy", "tech.electric_grid", "tech.national_laboratories", "tech.precision_instruments", "tech.industrial_quality_control"],
    "tech.nuclear_fuel_cycle": ["tech.nuclear_energy", "tech.advanced_metallurgy", "tech.industrial_chemistry", "tech.national_laboratories"],
    "tech.semiconductor_manufacturing": ["tech.digital_computing", "tech.electromagnetic_induction", "tech.advanced_metallurgy", "tech.industrial_quality_control", "tech.electronic_control"],
    "tech.robotic_manufacturing": ["tech.machine_tools", "tech.electronic_control", "tech.digital_control", "tech.autonomous_systems", "tech.advanced_metallurgy"],
    "tech.smart_grid": ["tech.electric_grid", "tech.information_theory", "tech.digital_control", "tech.sensor_networks", "tech.platform_coordination"],
    "tech.computational_biology": ["tech.scientific_classification", "tech.biotechnology", "tech.bioinformatics", "tech.digital_computing", "tech.probability_statistics"],
    "tech.climate_modeling": ["tech.numerical_weather_prediction", "tech.satellite_observation", "tech.digital_computing", "tech.probability_statistics", "tech.crop_remote_sensing"],
    "tech.autonomous_mining": ["tech.mechanized_mining", "tech.mineral_spectral_survey", "tech.sensor_networks", "tech.autonomous_systems", "tech.advanced_metallurgy"],
    "tech.petrochemical_industry": ["tech.petroleum_extraction", "tech.petroleum_refining", "tech.industrial_chemistry", "tech.electrochemistry"],
    "tech.internal_combustion": ["tech.petroleum_refining", "tech.precision_engineering", "tech.thermodynamics", "tech.mechanical_workshops"],
    "tech.deep_geophysics": ["tech.geological_prospecting", "tech.electromagnetic_induction", "tech.probability_statistics", "tech.mine_drainage"],
    "tech.operations_research": ["tech.probability_statistics", "tech.industrial_statistics", "tech.industrial_organization"],
    "tech.public_health_systems": ["tech.public_health", "tech.modern_medicine", "tech.urban_sanitation", "tech.industrial_chemistry"],
}

RESEARCH_CONDITIONS = {
    "tech.scientific_classification": (3, 2, ["tech.experimental_science", "tech.interregional_botany", "tech.learned_societies"]),
    "tech.geographic_information_systems": (2, 1, ["tech.satellite_observation", "tech.hydrological_remote_sensing", "tech.mineral_spectral_survey"]),
    "tech.oceanic_navigation": (2, 1, ["tech.magnetic_navigation", "tech.celestial_navigation"]),
    "tech.crop_breeding": (3, 2, ["tech.soil_experimentation", "tech.interregional_botany", "tech.agricultural_improvement"]),
    "tech.modern_husbandry": (2, 1, ["tech.livestock_breeding", "tech.public_health"]),
    "tech.synthetic_fertilizer": (2, 1, ["tech.industrial_chemistry", "tech.electrochemistry"]),
    "tech.advanced_metallurgy": (3, 2, ["tech.coke_smelting", "tech.electromagnetic_induction", "tech.industrial_quality_control"]),
    "tech.global_logistics": (3, 2, ["tech.rail_logistics", "tech.telecommunications", "tech.oceanic_navigation"]),
}

APPLICATIONS = {
    "tech.wool_husbandry": ["tech.hand_spinning"],
    "tech.early_glassmaking": ["tech.precision_instruments"],
    "tech.steam_sealing": ["tech.atmospheric_engine"],
    "tech.crop_breeding": ["tech.industrial_agronomy"],
    "tech.global_logistics": ["tech.digital_marketplaces"],
    "tech.electromagnetic_induction": ["tech.electric_grid"],
    "tech.commodity_crop_management": ["tech.commercial_estates"],
    "tech.chartered_companies": ["tech.global_logistics"],
    "tech.irrigation_surveying": ["tech.rice_paddy_cultivation"],
    "tech.soil_experimentation": ["tech.crop_breeding"],
    "tech.grain_baking": ["tech.public_health"],
    "tech.precision_irrigation": ["tech.smart_grid"],
    "tech.fertilizer_processing": ["tech.industrial_chemistry"],
    "tech.latex_smoke_coagulation": ["tech.rubber_working"],
    "tech.petrochemical_industry": ["tech.petrochemical_cracking"],
    "tech.forest_management": ["tech.scientific_classification"],
    "tech.public_health_systems": ["tech.knowledge_economy"],
    "tech.industrial_organization": ["tech.operations_research"],
    "tech.scientific_classification": ["tech.crop_breeding", "tech.livestock_breeding"],
    "tech.cartography": ["tech.property_cadastre", "tech.geographic_information_systems"],
    "tech.probability_statistics": ["tech.operations_research", "tech.geographic_information_systems"],
    "tech.mine_drainage": ["tech.atmospheric_engine", "tech.deep_mining"],
    "tech.industrial_chemistry": ["tech.petrochemical_industry", "tech.modern_medicine"],
    "tech.digital_computing": ["tech.geographic_information_systems", "tech.machine_learning"],
    "tech.satellite_observation": ["tech.geographic_information_systems", "tech.climate_modeling"],
    "tech.standardization": ["tech.interchangeable_parts", "tech.industrial_quality_control"],
    "tech.electric_grid": ["tech.nuclear_energy", "tech.smart_grid"],
    "tech.interregional_botany": ["tech.scientific_classification", "tech.crop_breeding"],
}


def tech_atom(technology_id: str) -> dict:
    return {"kind": 0, "id": technology_id, "value": 1}


def family_for(node: dict) -> str:
    current = node.get("main_lane", node.get("branch_family_id", ""))
    if node.get("is_milestone"):
        return current or "backbone.institutions_exchange"
    token = node["id"].removeprefix("tech.")
    for family, patterns in FAMILY_PATTERNS:
        if any(pattern in token for pattern in patterns):
            return family
    return current


def remove_era_milestones(spec, milestone_ids: set[str]):
    if not isinstance(spec, dict) or not spec:
        return {}
    if "kind" in spec:
        if int(spec.get("kind", -1)) == 0 and str(spec.get("id", "")) in milestone_ids:
            return {}
        return spec
    children = [remove_era_milestones(child, milestone_ids) for child in spec.get("children", [])]
    children = [child for child in children if child]
    if not children:
        return {}
    if len(children) == 1:
        return children[0]
    out = dict(spec)
    out["children"] = children
    if int(out.get("operator", -1)) == 3:
        out["required_count"] = min(int(out.get("required_count", 1)), len(children))
    return out


def condition_signal_ids(spec) -> list[str]:
    if not isinstance(spec, dict):
        return []
    if "kind" in spec:
        return [str(spec.get("id", ""))] if int(spec.get("kind", -1)) in (1, 2) else []
    out: list[str] = []
    for child in spec.get("children", []):
        out.extend(condition_signal_ids(child))
    return out


def condition_technology_ids(spec) -> list[str]:
    if not isinstance(spec, dict):
        return []
    if "kind" in spec:
        return [str(spec.get("id", ""))] if int(spec.get("kind", -1)) == 0 else []
    out: list[str] = []
    for child in spec.get("children", []):
        out.extend(condition_technology_ids(child))
    return out


def reveal_metadata(node: dict) -> tuple[str, str]:
    if node.get("network_role") == "backbone" or node.get("is_milestone"):
        return "general_knowledge", "由公共知识主干或本时代共同发展揭示"
    if (node.get("era_id") in ("atomic", "information", "intelligent")
            and (len(node.get("hard_prerequisite_ids", [])) >= 3
                 or node.get("id") in {
                     "tech.geographic_information_systems", "tech.computational_biology",
                     "tech.climate_modeling", "tech.nuclear_energy",
                     "tech.autonomous_mining", "tech.smart_grid",
                 })):
        return "composite_science", "由现实应用问题与多领域知识共同揭示"
    signals = condition_signal_ids(node.get("reveal_condition", {}))
    if any(signal.startswith(("resource.", "landform.", "weather.", "bio.")) for signal in signals):
        return "environment_observation", "通过实际地理、资源、生物或气候观察揭示"
    if any(signal.startswith(("contact.", "breakthrough.")) for signal in signals):
        return "practice_diffusion", "通过实物接触、生产实践或技术突破揭示"
    if node.get("era_id") in ("atomic", "information", "intelligent"):
        return "composite_science", "由现实应用问题与多领域知识共同揭示"
    return "general_knowledge", "由已有知识与制度实践逐步揭示"


def prerequisite_rationales(node: dict, node_by_id: dict[str, dict]) -> list[str]:
    target = node.get("display_name", node["id"])
    out = []
    for prerequisite in node.get("hard_prerequisite_ids", []):
        source = node_by_id[prerequisite].get("display_name", prerequisite)
        out.append(f"{source}为{target}提供不可替代的理论、材料、工艺或组织基础")
    return out


def append_binding(node: dict, kind: int, content_id: str, display_name: str) -> None:
    bindings = node.setdefault("expected_bindings", [])
    if not any(int(row.get("kind", 0)) == kind and row.get("id") == content_id for row in bindings):
        bindings.append({"kind": kind, "id": content_id})
    effects = node.setdefault("content_effects", [])
    if any(int(row.get("binding_kind", 0)) == kind and row.get("id") == content_id for row in effects):
        return
    content_kind = "good" if kind == 1 else "building"
    effects.append({
        "kind": content_kind,
        "id": content_id,
        "binding_kind": kind,
        "subject": f"{content_kind}.{content_id}",
        "attribute": "production_access" if kind == 1 else "construction_and_production_access",
        "operation": "unlock",
        "value": 1,
        "implementation": "GoodProfile.technology_tags" if kind == 1 else "BuildingProfile.technology_tags",
        "status": "catalog_rebind",
        "display_name": display_name,
    })


def remove_binding(node: dict, content_id: str) -> None:
    node["expected_bindings"] = [
        row for row in node.get("expected_bindings", []) if row.get("id") != content_id
    ]
    node["content_effects"] = [
        row for row in node.get("content_effects", []) if row.get("id") != content_id
    ]


def migrate() -> None:
    payload = json.loads(NETWORK.read_text(encoding="utf-8"))
    if int(payload.get("schema_version", 0)) >= 2:
        raise RuntimeError(
            "legacy lane migration refuses schema v2 authoring; "
            "technology_network.json already contains explicit semantic relationships")
    nodes = payload["nodes"]
    node_by_id = {node["id"]: node for node in nodes}
    milestone_by_era = {era["id"]: era["milestone_id"] for era in payload["eras"]}
    milestone_ids = set(milestone_by_era.values())

    payload["schema_version"] = 2
    payload["branch_families"] = [
        {"id": family_id, "display_name": name, "sort_order": index}
        for index, (family_id, name) in enumerate(FAMILY_ROWS)
    ]
    payload.pop("specialist_lanes", None)

    previous_milestone = ""
    for era in payload["eras"]:
        era["entry_milestone_id"] = previous_milestone
        era["milestone_candidate_ids"] = CANDIDATES[era["id"]]
        era["candidate_required"] = 4
        previous_milestone = era["milestone_id"]

    for node in nodes:
        node["branch_family_id"] = family_for(node)
        node["network_role"] = "branch" if node["branch_family_id"].startswith("branch.") else "backbone"
        node.pop("main_lane", None)
        node["era_entry_milestone_id"] = next(
            era["entry_milestone_id"] for era in payload["eras"] if era["id"] == node["era_id"])
        node["hard_prerequisite_ids"] = [
            value for value in node.get("hard_prerequisite_ids", []) if value not in milestone_ids
        ]
        node["reveal_condition"] = remove_era_milestones(node.get("reveal_condition", {}), milestone_ids)
        if node.get("is_milestone"):
            node["reveal_condition"] = {}
        node.pop("is_milestone_candidate", None)
        node["anchor_kind"] = "milestone" if node.get("is_milestone") else (
            "era_candidate" if node["id"] in CANDIDATES[node["era_id"]] else
            ("backbone" if node.get("network_role") == "backbone" else "branch")
        )
        node["application_target_ids"] = list(APPLICATIONS.get(node["id"], []))
        node["research_condition"] = {}
        node["research_condition_summary"] = ""
        category, summary = reveal_metadata(node)
        node["reveal_category"] = category
        node["reveal_summary"] = summary
        node["branch_successor_ids"] = []
        node.pop("same_lane_successor_ids", None)
        # Content effects are the direct authored unlock surface. Recipe inputs,
        # outputs and generic owner/employee summaries are discoverable from the
        # bound content itself and must not be presented as extra technology
        # effects.
        direct_bindings = {
            (int(binding.get("kind", 0)), str(binding.get("id", "")))
            for binding in node.get("expected_bindings", [])
        }
        node["content_effects"] = [
            effect for effect in node.get("content_effects", [])
            if (int(effect.get("binding_kind", 0)), str(effect.get("id", "")))
            in direct_bindings
        ]

        # Remove the generic "unlock then immediately buff the same object" template.
        directly_unlocked_buildings = {
            binding["id"] for binding in node.get("expected_bindings", [])
            if int(binding.get("kind", 0)) == 2
        }
        node["modifier_terms"] = [
            term for term in node.get("modifier_terms", [])
            if str(term.get("subject_id", "")) not in directly_unlocked_buildings
        ]

    for technology_id, prerequisites in COMPLEX_PREREQUISITES.items():
        node_by_id[technology_id]["hard_prerequisite_ids"] = prerequisites

    for technology_id, prerequisites in PUBLIC_PREREQUISITES.items():
        node = node_by_id[technology_id]
        node["hard_prerequisite_ids"] = prerequisites
        node["reveal_condition"] = {}
        node["reveal_category"] = "general_knowledge"
        node["reveal_summary"] = "公共主干知识；不依赖稀有资源、特殊地貌或国家标签揭示"

    for technology_id, (operator, required, alternatives) in RESEARCH_CONDITIONS.items():
        node = node_by_id[technology_id]
        spec = {"operator": operator, "children": [tech_atom(value) for value in alternatives]}
        if operator == 3:
            spec["required_count"] = required
        node["research_condition"] = spec
        node["research_condition_summary"] = (
            f"完成以下路径中的任意一项：{', '.join(alternatives)}" if operator == 2 else
            f"完成以下证据中的至少{required}项：{', '.join(alternatives)}"
        )

    # Ocean-going knowledge is revealed only by coast/estuary experience,
    # sustained maritime operation, or physical contact with a foreign vessel.
    for technology_id in (
            "tech.magnetic_navigation", "tech.oceanic_navigation",
            "tech.oceanic_ship_design", "tech.coastal_shipyards",
            "tech.oceanic_provisioning"):
        node_by_id[technology_id]["reveal_condition"] = {
            "operator": 2,
            "children": [
                {"kind": 1, "id": "landform.coast", "value": 1},
                {"kind": 1, "id": "landform.coastal_estuary", "value": 1},
                {"kind": 1, "id": "contact.maritime_vessel", "value": 1},
                {"kind": 1, "id": "breakthrough.maritime_operations", "value": 1},
            ],
        }
        node_by_id[technology_id]["reveal_category"] = "practice_diffusion"
        node_by_id[technology_id]["reveal_summary"] = (
            "由海岸环境、外国舰船实物接触或实际航运运营揭示；普通外交和陆路贸易无效"
        )

    # Give every sustained branch family at least one real alternative route.
    # The chosen alternatives are two independently authored earlier nodes in
    # the same theme; they are removed from the target's hard-AND list so the
    # OR is not decorative.
    era_order = {era: index for index, era in enumerate(ERAS)}
    explicitly_conditioned = set(RESEARCH_CONDITIONS)
    for family_id, _display_name in FAMILY_ROWS:
        family_members = sorted(
            (node for node in nodes if node["branch_family_id"] == family_id and not node.get("is_milestone")),
            key=lambda row: (era_order[row["era_id"]], int(row.get("layout_order", 0))),
        )
        if any(node["id"] in explicitly_conditioned for node in family_members):
            continue
        target = None
        alternatives = []
        for index, candidate in enumerate(family_members):
            if candidate["id"] in PUBLIC_PREREQUISITES:
                continue
            earlier = family_members[:index]
            if len(earlier) >= 2 and era_order[candidate["era_id"]] > era_order[earlier[0]["era_id"]]:
                target = candidate
                alternatives = [earlier[-2]["id"], earlier[-1]["id"]]
                break
        if target is None:
            continue
        target["hard_prerequisite_ids"] = [
            value for value in target.get("hard_prerequisite_ids", []) if value not in alternatives
        ]
        target["research_condition"] = {"operator": 2, "children": [tech_atom(value) for value in alternatives]}
        target["research_condition_summary"] = f"沿{_display_name}的两种早期实践中任选一条：{', '.join(alternatives)}"

    # Explicit corrections requested by the design review.
    cadastre = node_by_id["tech.property_cadastre"]
    cadastre["branch_family_id"] = "branch.land_institutions"
    cadastre["modifier_terms"] = [{"stat": "country.construction.cost_factor", "operation": 0, "value": -0.06}]
    cadastre["expected_bindings"] = [{"kind": 2, "id": "cadastral_office"}]
    cadastre["application_target_ids"] = ["tech.commercial_estates"]
    cadastre["content_effects"] = [{
        "kind": "building", "id": "cadastral_office", "binding_kind": 2,
        "subject": "building.cadastral_office", "attribute": "construction_and_production_access",
        "operation": "unlock", "value": 1, "implementation": "BuildingProfile.technology_tags",
        "status": "new_content", "display_name": "地籍管理局",
    }]
    cadastre["effect_summary"] = "解锁建筑：地籍管理局；国家建设成本 -6%"

    classification = node_by_id["tech.scientific_classification"]
    classification["branch_family_id"] = "branch.natural_history"
    classification["modifier_terms"] = [{
        "stat": "country.output.building.learned_society_factor", "operation": 0, "value": 0.18,
        "subject_kind": "building", "subject_id": "learned_society", "subject_display_name": "博学学会",
    }]
    classification["expected_bindings"] = []
    classification["content_effects"] = []
    classification["effect_summary"] = "博学学会研究产出 +18%；支持育种、生物调查与现代畜牧"

    atmospheric = node_by_id["tech.atmospheric_engine"]
    atmospheric["branch_family_id"] = "branch.heavy_industry"
    atmospheric["modifier_terms"] = []
    atmospheric["application_target_ids"] = ["tech.steam_power", "tech.thermodynamics"]
    atmospheric["expected_bindings"] = []
    atmospheric["content_effects"] = []
    append_binding(atmospheric, 1, "steam_engines", "蒸汽机")
    append_binding(atmospheric, 2, "atmospheric_engine_workshop", "大气式蒸汽机工坊")
    atmospheric["effect_summary"] = "解锁物资：蒸汽机；解锁建筑：大气式蒸汽机工坊"

    gis = node_by_id["tech.geographic_information_systems"]
    gis["branch_family_id"] = "branch.geoscience_gis"
    gis["modifier_terms"] = []
    gis["application_target_ids"] = [
        "tech.hydrological_remote_sensing", "tech.precision_agriculture",
        "tech.mineral_spectral_survey",
    ]
    gis["expected_bindings"] = [{"kind": 2, "id": "geospatial_analysis_center"}]
    gis["content_effects"] = [{
        "kind": "building", "id": "geospatial_analysis_center", "binding_kind": 2,
        "subject": "building.geospatial_analysis_center", "attribute": "construction_and_production_access",
        "operation": "unlock", "value": 1, "implementation": "BuildingProfile.technology_tags",
        "status": "new_content", "display_name": "地理空间分析中心",
    }]
    gis["effect_summary"] = "解锁建筑：地理空间分析中心；支持流域治理、森林遥感与精准农业"

    petrochemicals = node_by_id["tech.petrochemical_industry"]
    petrochemicals["expected_bindings"] = []
    petrochemicals["content_effects"] = []
    append_binding(petrochemicals, 1, "petrochemicals", "石化产品")
    append_binding(petrochemicals, 2, "petrochemicals_plant", "石油化工厂")
    append_binding(petrochemicals, 2, "method_petrochemicals_plant_r10", "智能石油化工厂")
    append_binding(petrochemicals, 1, "detergent", "洗涤剂")
    append_binding(petrochemicals, 2, "detergent_plant", "洗涤剂厂")
    append_binding(petrochemicals, 2, "method_detergent_plant_r10", "智能化洗涤剂厂")
    petrochemicals["modifier_terms"] = []
    petrochemicals["effect_summary"] = (
        "解锁物资：石化产品、洗涤剂；解锁建筑：石油化工厂、洗涤剂厂及其智能化方法"
    )
    autonomous_mining = node_by_id["tech.autonomous_mining"]
    append_binding(autonomous_mining, 2, "method_rare_earth_collector_r10", "智能战略矿山")
    mineral_survey = node_by_id["tech.mineral_spectral_survey"]
    append_binding(mineral_survey, 2, "method_zinc_ore_collector_r9", "自动化锌矿")

    # Estate institutions govern ownership, accounting and labour organization;
    # crop agronomy remains a separate ALL-support axis. Keep every landlord
    # method on the appropriate estate route and never turn a land institution
    # into a corn-only output modifier.
    for technology_id, content_id in (
            ("tech.seed_selection", "method_flax_collector_r3"),
            ("tech.seed_selection", "method_wheat_farm_r5"),
            ("tech.intensive_crop_rotation", "method_wheat_farm_r3"),
            ("tech.rice_paddy_cultivation", "method_rice_collector_r3"),
            ("tech.crop_breeding", "method_flax_collector_r5"),
            ("tech.crop_breeding", "method_rice_collector_r5")):
        remove_binding(node_by_id[technology_id], content_id)
    for content_id, display_name in (
            ("method_wheat_farm_r3", "佃作小麦庄园"),
            ("method_wheat_farm_r5", "改良轮作小麦庄园")):
        append_binding(node_by_id["tech.estate_cereal_management"], 2, content_id, display_name)
    for content_id, display_name in (
            ("method_flax_collector_r3", "亚麻庄园"),
            ("method_flax_collector_r5", "改良亚麻庄园")):
        append_binding(node_by_id["tech.estate_plantation_management"], 2, content_id, display_name)
    append_binding(node_by_id["tech.tenant_paddy_management"], 2,
                   "method_rice_collector_r3", "佃作稻庄")
    append_binding(node_by_id["tech.estate_paddy_management"], 2,
                   "method_rice_collector_r5", "精耕稻庄")
    for technology_id in (
            "tech.estate_accounting", "tech.tenant_paddy_management",
            "tech.manorial_jurisdiction", "tech.serf_obligations",
            "tech.estate_cereal_management", "tech.estate_paddy_management",
            "tech.estate_plantation_management", "tech.long_term_leases"):
        node_by_id[technology_id]["modifier_terms"] = []
    node_by_id["tech.manorial_cereal_farming"]["modifier_terms"] = [
        {"stat": "country.output.building.tenant_rainfed_maize_field_factor",
         "operation": 0, "value": 0.18, "subject_kind": "building",
         "subject_id": "tenant_rainfed_maize_field",
         "subject_display_name": "佃作雨养玉米田"},
        {"stat": "country.output.building.tenant_rainfed_wheat_field_factor",
         "operation": 0, "value": 0.18, "subject_kind": "building",
         "subject_id": "tenant_rainfed_wheat_field",
         "subject_display_name": "佃作雨养小麦田"},
    ]
    for term in node_by_id["tech.plough_agriculture"].get("modifier_terms", []):
        if term.get("stat") == "country.output.family.metal_toolmaking_factor":
            term.update(
                stat="country.output.family.field_crop_farming_factor",
                subject_id="field_crop_farming", subject_display_name="大田作物农业")
    for term in node_by_id["tech.coastal_shipyards"].get("modifier_terms", []):
        if term.get("stat") == "country.output.family.construction_methods_factor":
            term.update(
                stat="country.output.family.maritime_operations_factor",
                subject_id="maritime_operations", subject_display_name="海运作业")

    # Move generated "first available factory" bindings to the engineering
    # capability that actually creates the method. Organization/science nodes
    # remain ALL-support requirements where they are genuinely relevant.
    for source_id, target_id, content_id, display_name in (
            ("tech.industrial_statistics", "tech.mass_production", "jewelry_plant", "珠宝厂"),
            ("tech.industrial_statistics", "tech.electric_motors", "method_oceanic_shipyard_r7", "电气化造船厂"),
            ("tech.interchangeable_parts", "tech.factory_system", "footwear_plant", "制鞋厂"),
            ("tech.interchangeable_parts", "tech.factory_system", "leather_plant", "制革厂"),
            ("tech.corporate_management", "tech.mass_production", "cloth_plant", "电力纺织厂"),
            ("tech.corporate_management", "tech.mass_production", "fine_clothing_plant", "高级成衣厂"),
            ("tech.open_science_networks", "tech.digital_control", "method_lead_plant_r9", "自动化炼铅厂"),
            ("tech.open_science_networks", "tech.digital_control", "method_zinc_plant_r9", "自动化炼锌厂"),
            ("tech.algorithmic_management", "tech.robotic_manufacturing", "method_synthetic_fiber_plant_r10", "智能化合成纤维厂"),
            ("tech.algorithmic_management", "tech.robotic_manufacturing", "method_synthetic_rubber_plant_r10", "智能化合成橡胶厂"),
            ("tech.autonomous_labor_coordination", "tech.robotic_manufacturing", "method_aluminum_plant_r10", "智能冶铝厂"),
            ("tech.autonomous_labor_coordination", "tech.robotic_manufacturing", "method_stainless_steel_plant_r10", "智能化不锈钢厂"),
            ("tech.autonomous_systems", "tech.robotic_manufacturing", "method_reactor_component_works_r10", "智能化核反应堆设备厂"),
            ("tech.learned_societies", "tech.geological_prospecting", "method_limestone_collector_r6", "工业石灰岩矿场"),
            ("tech.coal_geology", "tech.mechanized_mining", "method_saltpeter_collector_r8", "现代硝石矿"),
            ("tech.coal_geology", "tech.mechanized_mining", "method_sulfur_collector_r8", "现代硫矿"),
            ("tech.mechanical_threshing", "tech.mechanized_agriculture", "method_cotton_collector_r6", "机械化棉花农场"),
            ("tech.mechanical_threshing", "tech.mechanized_agriculture", "method_potato_collector_r6", "机械化马铃薯农场"),
            ("tech.industrial_agronomy", "tech.digital_control", "method_phosphate_rock_collector_r9", "自动化磷矿"),
            ("tech.electronic_control", "tech.electrochemistry", "batteries_plant", "电池厂"),
            ("tech.systems_engineering", "tech.robotic_manufacturing", "method_rare_earth_metals_plant_r10", "智能战略金属冶炼厂"),
            ("tech.sensor_networks", "tech.digital_control", "method_concrete_plant_r9", "自动化混凝土厂"),
            ("tech.biotechnology", "tech.precision_agriculture", "method_highland_precision_agriculture", "高地精准块茎农业"),
            ("tech.scientific_agents", "tech.autonomous_systems", "method_autonomous_forestry", "自主林业经营站")):
        remove_binding(node_by_id[source_id], content_id)
        append_binding(node_by_id[target_id], 2, content_id, display_name)

    # Rebuild branch continuity from explicit family membership. This is display
    # and audit metadata only; eligibility remains in hard/research conditions.
    family_nodes: dict[str, list[dict]] = defaultdict(list)
    for node in nodes:
        if not node.get("is_milestone"):
            family_nodes[node["branch_family_id"]].append(node)
    for family, members in family_nodes.items():
        members.sort(key=lambda row: (era_order[row["era_id"]], int(row.get("layout_order", 0))))
        for index, node in enumerate(members):
            node["branch_successor_ids"] = [members[index + 1]["id"]] if index + 1 < len(members) else []
            node["terminal_reason"] = "该主题家族在当前内容目录中的最终应用端点" if index + 1 == len(members) else ""

    for node in nodes:
        if (not node.get("branch_successor_ids")
                and not node.get("application_target_ids")
                and not str(node.get("terminal_reason", "")).strip()):
            node["terminal_reason"] = (
                "时代里程碑；其价值是开放下一时代的全局研究资格"
                if node.get("is_milestone") else
                "该主题路线在当前内容目录中的最终应用端点"
            )
        node["prerequisite_rationales"] = prerequisite_rationales(node, node_by_id)

    # Rebuild visual edges exclusively from explicit authoring fields.
    edges = []
    seen = set()
    def add_edge(source: str, target: str, kind: str) -> None:
        key = (source, target, kind)
        if source and target and source != target and key not in seen:
            seen.add(key)
            edges.append({"from": source, "to": target, "kind": kind})
    for node in nodes:
        for prerequisite in node.get("hard_prerequisite_ids", []):
            add_edge(prerequisite, node["id"], "hard")
        for alternative in condition_technology_ids(node.get("research_condition", {})):
            add_edge(alternative, node["id"], "alternative")
        for target in node.get("application_target_ids", []):
            add_edge(node["id"], target, "application")
    for era in payload["eras"]:
        for candidate in era["milestone_candidate_ids"]:
            add_edge(candidate, era["milestone_id"], "milestone_candidate")
    index_by_id = {node["id"]: index for index, node in enumerate(nodes)}
    edges.sort(key=lambda edge: (index_by_id[edge["from"]], index_by_id[edge["to"]], edge["kind"]))
    payload["visual_edges"] = edges

    NETWORK.write_text(json.dumps(payload, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")


if __name__ == "__main__":
    migrate()
