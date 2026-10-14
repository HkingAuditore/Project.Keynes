import json
import re
from pathlib import Path

ROOT = Path("Project/project-keynes/data")

# Target people fed per worker; current values from tools/food_yield_audit.gd.
BUILDING_TARGETS = {
    # agrarian entry farms -> ~6.5
    "maize_garden": (3.31, 6.5), "rainfed_wheat_plot": (3.31, 6.5),
    "wetland_rice_garden": (3.31, 6.5), "upland_rice_plot": (3.06, 6.5),
    "floodplain_maize_plot": (3.06, 6.5), "floodplain_wheat_plot": (3.06, 6.5),
    "highland_tuber_plot": (3.06, 6.5), "rice_collector": (3.63, 6.5),
    "wheat_farm": (3.92, 6.5), "swidden_maize_plot": (3.52, 6.5),
    "rainfed_maize_field": (3.52, 6.5), "dryland_wheat_field": (4.53, 6.5),
    "bunded_rice_field": (3.78, 6.5), "fertile_soil_collector": (2.90, 6.5),
    "method_gathering_ground_r1": (4.48, 6.5),
    "subsistence_farm": (2.75, 5.5),
    # kingdom tenant fields -> ~9.5
    "tenant_potato_field": (3.62, 9.5), "tenant_rainfed_maize_field": (3.62, 9.5),
    "tenant_rainfed_wheat_field": (3.62, 9.5), "tenant_paddy": (4.17, 9.5),
    "sharecrop_paddy": (3.92, 9.5), "method_rice_collector_r3": (7.25, 9.5),
    # empire estates
    "landed_estate": (13.59, 18.0), "estate_paddy": (13.59, 18.0),
    "method_wheat_farm_r3": (13.59, 18.0), "three_field_smallholding": (6.53, 12.0),
    "potato_estate": (6.80, 15.0),
    # enlightenment methods must stay above empire estates
    "method_potato_farm_r5": (14.68, 24.0), "method_wheat_farm_r5": (14.68, 24.0),
    "method_rice_collector_r5": (14.68, 24.0),
}


def set_array(path: Path, field: str, values: list) -> list:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(rf"^({field} = PackedInt64Array\()([^)]*)(\))$", re.M)
    match = pattern.search(text)
    assert match, (path, field)
    old = [int(v) for v in match.group(2).split(",") if v.strip()]
    new_line = match.group(1) + ", ".join(str(v) for v in values) + match.group(3)
    path.write_text(text[:match.start()] + new_line + text[match.end():], encoding="utf-8")
    return old


def read_array(path: Path, field: str) -> list:
    text = path.read_text(encoding="utf-8")
    match = re.search(rf"^{field} = PackedInt64Array\(([^)]*)\)$", text, re.M)
    assert match, (path, field)
    return [int(v) for v in match.group(1).split(",") if v.strip()]


for building_id, (current, target) in BUILDING_TARGETS.items():
    path = ROOT / "economy" / "buildings" / f"{building_id}.tres"
    factor = target / current
    old = read_array(path, "output_quantities_per_day")
    new = [int(round(v * factor)) for v in old]
    set_array(path, "output_quantities_per_day", new)
    print(f"{building_id}: {old} -> {new} (x{factor:.3f})")

hearth = ROOT / "economy" / "buildings" / "communal_hearth.tres"
set_array(hearth, "input_quantities_per_day", [702, 351, 1500, 100])
set_array(hearth, "output_quantities_per_day", [2000])
print("communal_hearth: logs 5240 -> 1500, prepared_staples 1375 -> 2000")

DEATH_TERMS = [
    ("fire_control", -0.08, "熟食降低肠道感染与寄生虫致死。"),
    ("food_storage", -0.08, "储存食物平滑季节性饥荒。"),
    ("medicinal_herb_identification", -0.08, "辨识草药缓解常见病痛。"),
    ("public_storehouses", -0.10, "公共仓储在歉收年提供口粮。"),
    ("permanent_settlements", -0.06, "定居减少迁徙途中的伤亡。"),
    ("urban_sanitation", -0.10, "城市排污减少水源性疾病。"),
    ("regional_granaries", -0.08, "区域粮仓调剂地方歉收。"),
    ("urban_waterworks", -0.10, "城市供水提供洁净饮水。"),
    ("public_health", -0.12, "公共卫生制度控制传染病。"),
    ("modern_medicine", -0.12, "现代医学显著降低疾病死亡。"),
    ("refrigeration", -0.04, "冷藏减少食物腐败致病。"),
    ("public_health_systems", -0.10, "全民卫生体系覆盖基本医疗。"),
]
network_path = ROOT / "technology" / "technology_network.json"
network = json.loads(network_path.read_text(encoding="utf-8"))
nodes = {node["id"]: node for node in network["nodes"]}
for tech_id, value, rationale in DEATH_TERMS:
    node = nodes["tech." + tech_id]
    if any(term["stat"] == "country.population.death_factor" for term in node["modifier_terms"]):
        continue
    node["modifier_terms"].append({
        "stat": "country.population.death_factor",
        "operation": 0.0,
        "value": value,
        "subject_kind": "society",
        "subject_id": "country.population.death_factor",
        "subject_display_name": "人口自然死亡率",
        "effect_class": "人口自然死亡率",
        "effect_rationale": rationale,
        "implementation_status": "runtime_consumed",
        "runtime_consumer": "NativeEconomyRuntime::process_market_cell",
    })
    line = "人口自然死亡率 %+d%%" % round(value * 100)
    summary = node.get("effect_summary", "")
    node["effect_summary"] = line + ("；" + summary if summary else "")
    print(f"{tech_id}: death {value:+.2f}")
network_path.write_text(json.dumps(network, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
