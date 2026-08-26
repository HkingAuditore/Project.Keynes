import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "../..");
const NETWORK_PATH = path.join(ROOT, "data/technology/technology_network.json");
const BUILDING_DIR = path.join(ROOT, "data/economy/buildings");
const GOOD_DIR = path.join(ROOT, "data/goods");
const RESOURCE_DIR = path.join(ROOT, "data/resources");
const SURVIVAL_PLAN_PATH = path.join(ROOT,
  "data/economy/consumption_plans/survival_household.tres");
const WRITE = process.argv.includes("--write");
const WRITE_NETWORK_ONLY = process.argv.includes("--write-network-only");
if (WRITE && WRITE_NETWORK_ONLY) {
  throw new Error("--write and --write-network-only are mutually exclusive");
}
const ERA_IDS = [
  "stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
  "steam", "electrical", "atomic", "information", "intelligent",
];
const ERA_PRODUCTIVITY_INDEX = [1.0, 1.5, 2.2, 3.2, 4.5, 6.0, 9.0, 13.0, 17.0, 21.0, 24.0];
// Full survival diets supported per food worker at maximum staffing, climate,
// resources and utilization.  These are authoring targets, not a runtime cap:
// production modifiers and future methods may exceed them.  The early ladder
// stays deliberately modest; steam power, fertilizer, precision agriculture
// and autonomous equipment create the historically large productivity steps.
const ERA_FOOD_LABOR_CAPACITY = [
  1.15, 1.35, 1.60, 2.00, 2.50, 3.20, 6.00, 18.00, 40.00, 90.00, 180.00,
];
const ERA_FOOD_PROCESSING_YIELD = [
  0.90, 0.92, 0.94, 0.96, 0.98, 1.00, 1.02, 1.04, 1.06, 1.08, 1.10,
];
const ERA_CONSTRUCTION_PAYBACK_DAYS = [45, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330];
const ENERGY_GOODS = new Set([
  "coal", "coke", "crude_oil", "natural_gas", "refined_fuel", "electricity",
  "nuclear_fuel",
]);
const CAPITAL_GOODS = new Set([
  "tools", "bronze_tools", "precision_tools", "steam_engines", "engines",
  "machine_parts", "industrial_machinery", "agricultural_machinery",
  "electric_motor", "electrical_equipment", "electronic_components", "computers",
  "scientific_instruments", "autonomous_systems", "reactor_components",
]);

function quotedStrings(value) {
  return [...value.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((match) =>
    JSON.parse(`"${match[1]}"`));
}

function packedInts(value) {
  const body = value.slice(value.indexOf("(") + 1, value.lastIndexOf(")")).trim();
  if (!body) return [];
  return body.split(",").map((part) => Number(part.trim()));
}

function parseTres(filePath) {
  const text = fs.readFileSync(filePath, "utf8");
  const props = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z0-9_]+) = (.*)$/);
    if (match) props[match[1]] = match[2];
  }
  const idMatch = (props.id ?? "").match(/&?"([^"]+)"/);
  return {
    path: filePath,
    text,
    eol: text.includes("\r\n") ? "\r\n" : "\n",
    props,
    id: idMatch?.[1] ?? "",
    name: quotedStrings(props.display_name ?? "")[0] ?? idMatch?.[1] ?? "",
    strings(name) { return quotedStrings(props[name] ?? ""); },
    ints(name) { return packedInts(props[name] ?? "PackedInt32Array()"); },
  };
}

function packedString(values) {
  return `PackedStringArray(${values.map((value) => JSON.stringify(value)).join(", ")})`;
}

function packedInt(values, type = "PackedInt32Array") {
  return `${type}(${values.join(", ")})`;
}

function setProperty(resource, name, value) {
  const lines = resource.text.split(/\r?\n/);
  const index = lines.findIndex((line) => line.startsWith(`${name} = `));
  if (index < 0) throw new Error(`missing property ${resource.id}.${name}`);
  lines[index] = `${name} = ${value}`;
  resource.text = lines.join(resource.eol);
  resource.props[name] = value;
}

function listTres(directory) {
  return fs.readdirSync(directory).filter((name) => name.endsWith(".tres"))
    .sort().map((name) => parseTres(path.join(directory, name)));
}

const network = JSON.parse(fs.readFileSync(NETWORK_PATH, "utf8"));
const buildings = listTres(BUILDING_DIR);
const goods = listTres(GOOD_DIR);
const resources = listTres(RESOURCE_DIR);
const survivalPlan = parseTres(SURVIVAL_PLAN_PATH);
const buildingById = new Map(buildings.map((row) => [row.id, row]));
const goodById = new Map(goods.map((row) => [row.id, row]));
const resourceById = new Map(resources.map((row) => [row.id, row]));

const SURVIVAL_FOOD_NEEDS = new Set(["staple_food", "protein", "produce"]);
const survivalNeedIds = survivalPlan.strings("need_ids");
const survivalNeedQuantities = survivalPlan.ints("base_qty_per_person");
const survivalNeedVariantOffsets = survivalPlan.ints("need_variant_offsets");
const survivalVariantComponentOffsets = survivalPlan.ints("variant_component_offsets");
const survivalComponentGoods = survivalPlan.strings("component_good_ids");
const DIRECT_SURVIVAL_FOOD_GOODS = new Set();
let survivalFoodUnitsPerPerson = 0;
for (let need = 0; need < survivalNeedIds.length; need += 1) {
  if (!SURVIVAL_FOOD_NEEDS.has(survivalNeedIds[need])) continue;
  survivalFoodUnitsPerPerson += Math.max(0, survivalNeedQuantities[need] ?? 0);
  for (let variant = survivalNeedVariantOffsets[need];
       variant < survivalNeedVariantOffsets[need + 1]; variant += 1) {
    for (let component = survivalVariantComponentOffsets[variant];
         component < survivalVariantComponentOffsets[variant + 1]; component += 1) {
      DIRECT_SURVIVAL_FOOD_GOODS.add(survivalComponentGoods[component]);
    }
  }
}
if (survivalFoodUnitsPerPerson <= 0 || DIRECT_SURVIVAL_FOOD_GOODS.size === 0) {
  throw new Error("survival food basket is empty");
}
// These are upstream one-for-one abstract food units. They are not household
// variants themselves, but leaving them on the money ladder recreates excess
// calories downstream through bakeries and slaughterhouses.
const RAW_SURVIVAL_FOOD_GOODS = new Set([
  "wheat_grain", "rice_grain", "corn_grain", "livestock_products",
]);
const FOOD_EQUIVALENT_GOODS = new Set([
  ...DIRECT_SURVIVAL_FOOD_GOODS, ...RAW_SURVIVAL_FOOD_GOODS,
]);

function directTechnology(resource) {
  const ids = resource.strings("technology_tags").filter((tag) => tag.startsWith("tech."));
  if (!ids.length) throw new Error(`${resource.id} has no direct technology`);
  // Method variants may intentionally share one BuildingProfile across two
  // era-specific application nodes.  The first tag remains the primary
  // owner for closure diagnostics; EconomyCatalog still compiles every tag.
  return ids[0];
}

function replaceTechnology(resource, technologyId) {
  const tags = resource.strings("technology_tags").filter((tag) => !tag.startsWith("tech."));
  tags.push(technologyId);
  setProperty(resource, "technology_tags", packedString(tags));
}

function replaceInput(resource, goodsIds, quantities, required, categories = []) {
  if (!categories.length) categories = goodsIds.map(() => "");
  setProperty(resource, "input_good_ids", packedString(goodsIds));
  setProperty(resource, "input_quantities_per_day", packedInt(quantities, "PackedInt64Array"));
  setProperty(resource, "input_required_q16", packedInt(required));
  setProperty(resource, "input_category_ids", packedString(categories));
  setProperty(resource, "input_candidate_offsets", packedInt(Array(goodsIds.length + 1).fill(0)));
  setProperty(resource, "input_candidate_good_ids", packedString([]));
  setProperty(resource, "input_candidate_efficiency_q16", packedInt([]));
}

function replaceConstruction(resource, goodIds, quantities) {
  setProperty(resource, "construction_good_ids", packedString(goodIds));
  setProperty(resource, "construction_quantities", packedInt(quantities, "PackedInt64Array"));
  if (Object.hasOwn(resource.props, "construction_candidate_offsets")) {
    setProperty(resource, "construction_candidate_offsets",
      packedInt(Array.from({length: goodIds.length + 1}, (_, index) => index)));
    setProperty(resource, "construction_candidate_good_ids", packedString(goodIds));
    setProperty(resource, "construction_candidate_efficiency_q16",
      packedInt(goodIds.map(() => 65536)));
  }
}

function appendOptionalInput(buildingId, goodId, quantity, category = "") {
  const building = buildingById.get(buildingId);
  if (!building) throw new Error(`unknown building ${buildingId}`);
  const ids = building.strings("input_good_ids");
  if (ids.includes(goodId)) {
    const slot = ids.indexOf(goodId);
    const configuredRequired = building.ints("input_required_q16");
    const required = ids.map((_, index) => configuredRequired[index] ?? 65536);
    const configuredCategories = building.strings("input_category_ids");
    const categories = ids.map((_, index) => configuredCategories[index] ?? "");
    required[slot] = 0;
    categories[slot] = category;
    setProperty(building, "input_required_q16", packedInt(required));
    setProperty(building, "input_category_ids", packedString(categories));
    return;
  }
  const quantities = building.ints("input_quantities_per_day");
  const configuredRequired = building.ints("input_required_q16");
  const required = ids.map((_, index) => configuredRequired[index] ?? 65536);
  const configuredCategories = building.strings("input_category_ids");
  const categories = ids.map((_, index) => configuredCategories[index] ?? "");
  const configuredOffsets = building.ints("input_candidate_offsets");
  const candidateOffsets = configuredOffsets.length === ids.length + 1 ?
    [...configuredOffsets] : Array(ids.length + 1).fill(0);
  const candidateGoods = building.strings("input_candidate_good_ids");
  const candidateEfficiencies = building.ints("input_candidate_efficiency_q16");
  ids.push(goodId);
  quantities.push(quantity);
  required.push(0);
  categories.push(category);
  candidateOffsets.push(candidateOffsets.at(-1) ?? 0);
  setProperty(building, "input_good_ids", packedString(ids));
  setProperty(building, "input_quantities_per_day", packedInt(quantities, "PackedInt64Array"));
  setProperty(building, "input_required_q16", packedInt(required));
  setProperty(building, "input_category_ids", packedString(categories));
  setProperty(building, "input_candidate_offsets", packedInt(candidateOffsets));
  setProperty(building, "input_candidate_good_ids", packedString(candidateGoods));
  setProperty(building, "input_candidate_efficiency_q16", packedInt(candidateEfficiencies));
}

function appendConstruction(buildingId, goodId, quantity) {
  const building = buildingById.get(buildingId);
  if (!building) throw new Error(`unknown building ${buildingId}`);
  const ids = building.strings("construction_good_ids");
  if (ids.includes(goodId)) return;
  const quantities = building.ints("construction_quantities");
  const hasCandidateColumns = Object.hasOwn(building.props, "construction_candidate_offsets");
  const configuredOffsets = hasCandidateColumns ?
    building.ints("construction_candidate_offsets") : [];
  const candidateOffsets = configuredOffsets.length === ids.length + 1 ?
    [...configuredOffsets] : Array(ids.length + 1).fill(0);
  const candidateGoods = hasCandidateColumns ?
    building.strings("construction_candidate_good_ids") : [];
  const candidateEfficiencies = hasCandidateColumns ?
    building.ints("construction_candidate_efficiency_q16") : [];
  ids.push(goodId);
  quantities.push(quantity);
  setProperty(building, "construction_good_ids", packedString(ids));
  setProperty(building, "construction_quantities", packedInt(quantities, "PackedInt64Array"));
  if (hasCandidateColumns) {
    candidateGoods.push(goodId);
    candidateEfficiencies.push(65536);
    candidateOffsets.push(candidateGoods.length);
    setProperty(building, "construction_candidate_offsets", packedInt(candidateOffsets));
    setProperty(building, "construction_candidate_good_ids", packedString(candidateGoods));
    setProperty(building, "construction_candidate_efficiency_q16", packedInt(candidateEfficiencies));
  }
}

// Base-method recipe corrections and immediate demand sinks.
replaceTechnology(buildingById.get("bast_wrap_shelter"), "tech.fiber_twisting");
replaceInput(buildingById.get("ore_bronzesmith_camp"),
  ["copper", "tin", "charcoal"], [700, 300, 200], [65536, 65536, 32768]);
replaceConstruction(buildingById.get("iron_ore_collector"), ["logs", "raw_stone"], [900, 700]);
replaceConstruction(buildingById.get("bloomery"), ["clay", "raw_stone"], [1200, 900]);
replaceConstruction(buildingById.get("iron_tool_workshop"), ["logs", "raw_stone"], [1800, 1200]);
replaceConstruction(buildingById.get("solar_salt_pan"), ["clay", "raw_stone"], [400, 250]);
replaceInput(buildingById.get("household_loom"), ["bast_fiber"], [1000], [65536],
  ["natural_spinnable_fiber"]);
replaceInput(buildingById.get("open_pottery_hearth"),
  ["clay", "charcoal"], [900, 300], [65536, 32768]);
replaceConstruction(buildingById.get("fertilizer_plant"),
  ["lumber", "bricks", "construction_components", "steel"], [16000, 12000, 12000, 8000]);
replaceInput(buildingById.get("fertilizer_plant"),
  ["phosphate_rock", "coal", "tools"], [1000, 600, 250], [65536, 32768, 32768],
  ["", "", "tools"]);
setProperty(buildingById.get("fertilizer_plant"), "output_quantities_per_day",
  packedInt([24000], "PackedInt64Array"));
replaceConstruction(buildingById.get("early_knowledge_institution"), ["logs"], [40]);

// First-generation power, electrical and research packages must use materials
// already producible in their own era. Later upgrades retain advanced recipes.
replaceConstruction(buildingById.get("atmospheric_engine_workshop"),
  ["lumber", "bricks", "raw_stone", "copper"], [12000, 12000, 8000, 4000]);
replaceInput(buildingById.get("atmospheric_engine_workshop"),
  ["coal", "tools", "copper"], [1600, 700, 400], [32768, 65536, 32768]);
replaceConstruction(buildingById.get("electricity_plant"),
  ["bricks", "steel", "glass", "copper"], [24000, 16000, 6000, 5000]);
replaceInput(buildingById.get("electricity_plant"),
  ["coal", "tools"], [1800, 400], [49152, 32768]);
replaceConstruction(buildingById.get("wire_plant"),
  ["bricks", "steel", "glass"], [18000, 12000, 5000]);
replaceInput(buildingById.get("wire_plant"),
  ["copper", "tools", "electricity"], [1400, 350, 700],
  [65536, 32768, 49152]);
replaceConstruction(buildingById.get("basic_electrical_equipment_works"),
  ["bricks", "steel", "glass", "copper"], [26000, 18000, 8000, 6000]);
replaceInput(buildingById.get("basic_electrical_equipment_works"),
  ["wire", "steel", "glass", "electricity", "tools"],
  [1100, 500, 250, 900, 350], [65536, 65536, 32768, 49152, 32768]);
replaceConstruction(buildingById.get("scientific_instrument_works"),
  ["lumber", "bricks", "glass", "copper"], [12000, 12000, 6000, 5000]);
replaceInput(buildingById.get("scientific_instrument_works"),
  ["glass", "copper", "tools", "technology_points"],
  [700, 700, 350, 200], [65536, 65536, 32768, 3277]);
replaceConstruction(buildingById.get("industrial_research_laboratory"),
  ["steel", "bricks", "glass", "copper"], [36000, 30000, 14000, 9000]);
replaceInput(buildingById.get("industrial_research_laboratory"),
  ["scientific_instruments", "electricity"], [3500, 4500], [49152, 49152]);
replaceConstruction(buildingById.get("guild_weaving_house"),
  ["lumber", "bricks", "raw_stone"], [9000, 7000, 4000]);
replaceInput(buildingById.get("guild_weaving_house"),
  ["flax_fiber", "tools"], [1400, 300], [65536, 32768]);
replaceConstruction(buildingById.get("cottage_weaving"),
  ["lumber", "bricks", "tools"], [1600, 1200, 300]);
replaceConstruction(buildingById.get("improved_domestic_loom"),
  ["lumber", "bricks", "steel", "tools"], [2400, 1800, 1200, 500]);

appendOptionalInput("marine_fish_collector", "natural_rubber", 40);
appendOptionalInput("method_marine_fish_collector_r2", "natural_rubber", 80);
appendOptionalInput("footwear_plant", "natural_rubber", 300);
appendOptionalInput("staple_kitchen", "salt", 60);
appendOptionalInput("slaughterhouse", "salt", 80);
appendOptionalInput("tannery", "salt", 80);
appendOptionalInput("bakery", "salt", 40);
appendOptionalInput("landed_estate", "fertilizer", 120);
appendOptionalInput("method_wheat_farm_r5", "fertilizer", 180);
appendOptionalInput("estate_paddy", "fertilizer", 180);
appendOptionalInput("bricks_plant", "lime", 100);
appendOptionalInput("insulated_cable_plant", "synthetic_rubber", 250);
appendOptionalInput("nuclear_power_plant", "stainless_steel", 300);
appendOptionalInput("steam_steel_works", "steam_engines", 240);
appendOptionalInput("electric_motor_plant", "electrical_equipment", 300);

appendConstruction("creamery", "lumber", 300);
appendConstruction("wetland_rice_garden", "reed_bundle", 180);

appendConstruction("method_steam_shipping", "oceanic_vessels", 500);
appendConstruction("method_automated_port", "oceanic_vessels", 1200);
appendConstruction("method_autonomous_shipping", "oceanic_vessels", 1800);
for (const id of [
  "railway_equipment_plant", "steel_plant", "early_oil_well",
  "method_lead_ore_collector_r9", "method_phosphate_rock_collector_r9",
  "method_bauxite_collector_r9",
]) appendConstruction(id, "railway_equipment", 800);

setProperty(buildingById.get("industrial_research_laboratory"), "upgrade_tier", "6");
setProperty(buildingById.get("learned_society"), "upgrade_tier", "7");
setProperty(buildingById.get("polytechnic_institute"), "upgrade_tier", "8");

for (const building of buildings) {
  const inputCount = building.strings("input_good_ids").length;
  const qualities = building.ints("input_min_quality_levels");
  if (qualities.length > 0 && qualities.length !== inputCount) {
    setProperty(building, "input_min_quality_levels",
      packedInt(Array.from({length: inputCount}, (_, index) => qualities[index] ?? 0)));
  }
}

let nodeById = new Map(network.nodes.map((node) => [node.id, node]));
const originalIndex = new Map(network.nodes.map((node, index) => [node.id, index]));
const eraById = new Map(network.eras.map((era, index) => [era.id, index]));
const eraEntry = new Map(network.eras.map((era) => [era.id, era.entry_milestone_id]));
const protectedNodes = new Set();
const explicitlyAuthoredHardEdges = new Set();

function setHard(id, prerequisites, reason) {
  const node = nodeById.get(id);
  if (!node) throw new Error(`unknown node ${id}`);
  node.hard_prerequisite_ids = [...prerequisites];
  for (const prerequisite of prerequisites) {
    explicitlyAuthoredHardEdges.add(`${prerequisite}->${id}`);
  }
  node.prerequisite_rationales = prerequisites.map((prerequisite) =>
    `${nodeById.get(prerequisite)?.display_name ?? prerequisite}是${node.display_name}${reason}`);
  const basis = node.knowledge_basis ?? {required_ids: [], alternative_groups: [], exemption_reason: ""};
  basis.required_ids = [...new Set([...(basis.required_ids ?? []).filter((value) =>
    prerequisites.includes(value)), ...prerequisites])];
  basis.exemption_reason = prerequisites.length === 0 && node.node_role === "identification" ?
    "纯观察辨识由资源或接触证据揭示，不预设加工能力。" : "";
  node.knowledge_basis = basis;
}

function moveNode(id, eraId) {
  const node = nodeById.get(id);
  // Collapsed single-parent methods are intentionally absent on repeat runs.
  if (!node) return;
  node.era_id = eraId;
  node.era_entry_milestone_id = eraEntry.get(eraId) ?? "";
  protectedNodes.add(id);
}

// The complete historical base packages.  Later industrial upgrades keep their stable IDs.
setHard("tech.fiber_twisting", ["tech.natural_observation", "tech.wild_flax_collection"],
  "所需的可见纤维材料与基础观察知识。");
for (const [id, era] of [
  ["tech.application.early_tin_mine", "agrarian"],
  ["tech.application.early_tin_smelter", "agrarian"],
  ["tech.application.ore_bronzesmith_camp", "agrarian"],
  ["tech.application.bronze_tool_workshop", "kingdom"],
  ["tech.application.iron_ore_collector", "kingdom"],
  ["tech.application.bloomery", "kingdom"],
  ["tech.application.iron_tool_workshop", "kingdom"],
  ["tech.application.surface_coal_gathering", "kingdom"],
  ["tech.application.cotton_garden", "agrarian"],
  ["tech.application.flax_retting_pit", "kingdom"],
  ["tech.application.cotton_ginning_shelter", "agrarian"],
  ["tech.application.household_loom", "kingdom"],
  ["tech.application.rubber_tapping_camp", "agrarian"],
  ["tech.application.latex_smoking_shelter", "agrarian"],
  ["tech.application.brine_gathering_basin", "agrarian"],
  ["tech.application.solar_salt_pan", "kingdom"],
  ["tech.method.reed_cutting_camp", "agrarian"],
  ["tech.method.turf_cutting_ground", "agrarian"],
  ["tech.method.rubble_stone_working", "kingdom"],
  ["tech.wild_tuber_collection", "agrarian"],
  ["tech.application.fertilizer_plant", "electrical"],
  ["tech.application.zinc_plant", "atomic"],
]) moveNode(id, era);

function ensureModifier(id, term) {
  const node = nodeById.get(id);
  if (!(node.modifier_terms ?? []).some((row) => row.stat === term.stat)) {
    node.modifier_terms.push(term);
  }
}
for (const [id, value, rationale] of [
  ["tech.fur_sewing", 0.05, "毛皮缝合、包边与补强经验提高基础衣物产出。"],
  ["tech.felt_making", 0.04, "毡化压实与保温层经验提高基础衣物产出。"],
]) ensureModifier(id, {
  stat: "country.output.good.clothing_factor", operation: 0, value,
  subject_kind: "good", subject_id: "clothing", subject_display_name: "基础衣物",
  effect_class: "商品产出", effect_rationale: rationale,
  implementation_status: "runtime_consumed",
  runtime_consumer: "NativeEconomyRuntime::effective_building_output_quantity",
});
for (const [id, stat, subjectKind, displayName, rationale] of [
  ["tech.oral_memory_practice", "country.research.society_efficiency", "society",
    "社会领域研究效率", "口述复核与代际传承提高社会知识积累效率。"],
  ["tech.phenology_observation", "country.research.agriculture_efficiency", "agriculture",
    "农业领域研究效率", "连续物候记录提高农业知识积累效率。"],
  ["tech.pastoral_route_memory", "country.research.agriculture_efficiency", "agriculture",
    "农业领域研究效率", "牧道、季节与水草记忆提高农业知识积累效率。"],
  ["tech.tide_observation", "country.trade.speed_factor", "society",
    "全社会贸易运输速度", "潮汐时序经验改善沿岸运输周转。"],
]) ensureModifier(id, {
  stat, operation: 0, value: 0.03, subject_kind: subjectKind, subject_id: stat,
  subject_display_name: displayName, effect_class: stat.includes("research") ? "研究效率" : "全社会贸易能力",
  effect_rationale: rationale, implementation_status: "runtime_consumed",
  runtime_consumer: stat.includes("research") ? "NativeCountryRuntime::process_research_day" :
    "NativeEconomyRuntime::capture_country_epoch",
});

setHard("tech.application.early_tin_mine",
  ["tech.tin_identification", "tech.ground_stone_tools", "tech.natural_copper_working"],
  "所需的矿物辨识、采掘工具与金属经验。");
setHard("tech.application.early_tin_smelter",
  ["tech.kiln_firing", "tech.tin_identification",
    "tech.application.early_tin_mine"], "所需的矿石、炉温与合金知识。");
setHard("tech.application.ore_bronzesmith_camp",
  ["tech.copper_annealing", "tech.bronze_casting", "tech.application.early_tin_smelter",
    "tech.charcoal_burning"], "所需的精炼金属、配比铸造与燃料工艺。");
setHard("tech.application.iron_ore_collector",
  ["tech.surface_iron_collection", "tech.ground_stone_tools"], "所需的铁矿辨识与采掘工艺。");
setHard("tech.application.bloomery",
  ["tech.iron_smelting", "tech.surface_iron_collection", "tech.application.iron_ore_collector",
  ],
  "所需的铁矿、木炭与耐火土炉工艺。");
setHard("tech.application.iron_tool_workshop",
  ["tech.iron_smelting", "tech.application.bloomery"], "所需的块炼铁与锻造工艺。");
setHard("tech.application.solar_salt_pan",
  ["tech.salt_preservation", "tech.application.brine_gathering_basin"], "所需的卤水与盐渍知识。");
setHard("tech.application.fertilizer_plant",
  ["tech.synthetic_fertilizer", "tech.fertilizer_processing"],
  "所需的肥料化学与工业处理知识。");

setHard("tech.application.atmospheric_engine_workshop",
  ["tech.atmospheric_engine", "tech.application.surface_coal_gathering",
    "tech.application.iron_tool_workshop"], "所需的动力原理、燃料与金属工具知识。");
setHard("tech.application.electricity_plant",
  ["tech.electric_generation", "tech.atmospheric_engine",
    "tech.application.surface_coal_gathering"], "所需的发电原理、动力机械与燃料知识。");
setHard("tech.application.wire_plant",
  ["tech.electromagnetic_induction", "tech.application.electricity_plant",
    "tech.copper_metallurgy"], "所需的电磁、供电与铜加工知识。");
setHard("tech.application.basic_electrical_equipment_works",
  ["tech.electrification", "tech.electromagnetic_induction",
    "tech.application.wire_plant", "tech.application.electricity_plant"],
  "所需的电气原理、导线和稳定供电知识。");
setHard("tech.application.scientific_instrument_works",
  ["tech.industrial_research", "tech.scientific_classification"],
  "所需的实验组织与精密测量知识。");
setHard("tech.application.industrial_research_laboratory",
  ["tech.public_education", "tech.industrial_research",
    "tech.application.scientific_instrument_works",
    "tech.application.electricity_plant"], "所需的公共教育、实验仪器与供电知识。");
setHard("tech.application.guild_weaving_house",
  ["tech.loom_weaving", "tech.flax_retting", "tech.application.fired_brick_kiln"],
  "所需的织机、纤维处理与固定工场知识。");
setHard("tech.application.cottage_weaving",
  ["tech.hand_spinning", "tech.weaving", "tech.application.guild_weaving_house"],
  "所需的纺纱、织造与专业工场经验。");
setHard("tech.application.improved_domestic_loom",
  ["tech.mechanical_workshops", "tech.textile_machinery",
    "tech.application.steam_steel_works"], "所需的机械、纺织设备与钢制构件知识。");

// Industry-line closure: only process knowledge is a hard prerequisite.  Raw
// materials, construction goods, local extraction and optional tools remain
// market/runtime constraints and are reported below rather than becoming
// technology gates.
setHard("tech.natural_copper_working",
  ["tech.natural_copper_identification", "tech.stone_knapping", "tech.ground_stone_tools"],
  "所需的自然铜辨识与基础石器加工知识。");
setHard("tech.copper_ore_roasting",
  ["tech.copper_annealing", "tech.ground_stone_tools"],
  "所需的矿石焙烧与基础采掘知识。");
setHard("tech.copper_mining_application",
  ["tech.natural_copper_identification", "tech.stone_knapping", "tech.ground_stone_tools"],
  "所需的矿体辨识与基础挖掘知识。");
setHard("tech.copper_metallurgy",
  ["tech.copper_ore_roasting", "tech.charcoal_burning", "tech.pottery"],
  "所需的矿石冶炼、燃料与炉体知识。");
setHard("tech.bronze_casting",
  ["tech.copper_annealing", "tech.tin_identification", "tech.ground_stone_tools"],
  "所需的铜锡配比与铸造知识。");
setHard("tech.iron_ore_identification", [], "");
setHard("tech.surface_iron_collection", ["tech.iron_ore_identification"], "");
setHard("tech.iron_smelting", ["tech.surface_iron_collection"], "");
setHard("tech.application.brine_gathering_basin", ["tech.brine_collection", "tech.fire_control"],
  "所需的卤水采集与控火知识。");
setHard("tech.salt_preservation", ["tech.brine_collection"],
  "所需的盐渍保存知识。");
setHard("tech.application.salt_collector",
  ["tech.salt_preservation", "tech.ground_stone_tools"],
  "所需的盐源识别与采集知识。");
setHard("tech.cotton_gardening",
  ["tech.wild_cotton_collection", "tech.crop_domestication"],
  "所需的野生棉铃观察与作物驯化知识。");
setHard("tech.application.cotton_garden",
  ["tech.cotton_gardening", "tech.crop_domestication", "tech.rainfed_field_system"],
  "所需的棉花栽培与雨养田制知识。");
setHard("tech.application.cotton_ginning_shelter",
  ["tech.cotton_ginning", "tech.wild_cotton_collection"],
  "所需的棉花去籽与原料识别知识。");
setHard("tech.application.cotton_smallholding",
  ["tech.application.cotton_garden", "tech.cotton_ginning", "tech.customary_tenancy",
    "tech.rainfed_field_system"], "所需的棉花种植与租佃知识。");
setHard("tech.application.cotton_collector",
  ["tech.estate_plantation_management", "tech.cotton_gardening", "tech.indentured_contracts",
    "tech.commodity_crop_management", "tech.rainfed_field_system"],
  "所需的庄园、契约与商品作物管理知识。");
setHard("tech.application.rubber_tapping_camp",
  ["tech.wild_latex_tapping", "tech.rubber_identification"],
  "所需的乳胶采集与材料识别知识。");
setHard("tech.latex_smoke_coagulation",
  ["tech.rubber_working", "tech.wild_latex_tapping", "tech.fire_control"],
  "所需的乳胶处理与控火知识。");
setHard("tech.application.latex_smoking_shelter",
  ["tech.latex_smoke_coagulation", "tech.wild_latex_tapping", "tech.fire_control",
    "tech.application.rubber_tapping_camp"], "所需的乳胶烟熏凝固知识。");
setHard("tech.application.goldsmith_workshop",
  ["tech.ground_stone_tools", "tech.fire_control"],
  "所需的贵金属加工与控火知识。");
setHard("tech.application.gold_mine",
  ["tech.shaft_sinking", "tech.gold_panning"], "所需的竖井与淘金知识。");
setHard("tech.application.silver_mine",
  ["tech.shaft_sinking", "tech.surface_silver_collection"],
  "所需的竖井与地表银矿采集知识。");
setHard("tech.currency", ["tech.early_trade", "tech.weights_and_measures"],
  "所需的贸易与度量知识。");
setHard("tech.application.fired_brick_kiln",
  ["tech.kiln_firing", "tech.adobe_making", "tech.clay_preparation",
    "tech.charcoal_burning", "tech.ground_stone_tools"],
  "所需的窑烧、黏土与燃料知识。");
setHard("tech.application.classical_masonry_yard",
  ["tech.road_engineering", "tech.masonry", "tech.adobe_making", "tech.ground_stone_tools"],
  "所需的道路、砌筑与测量知识。");
setHard("tech.application.method_lumber_plant_r4",
  ["tech.forest_management", "tech.timber_sawing"],
  "所需的森林管理与锯木知识。");
setHard("tech.application.bark_paper_workshop",
  ["tech.bark_paper_making", "tech.writing", "tech.deadwood_collection"],
  "所需的树皮制纸与书写知识。");
setHard("tech.application.plant_fiber_paper_workshop",
  ["tech.plant_fiber_papermaking", "tech.writing", "tech.fiber_twisting",
    "tech.wild_flax_collection"], "所需的植物纤维制纸与书写知识。");
setHard("tech.application.parchment_workshop",
  ["tech.parchment_making", "tech.writing", "tech.hide_tanning"],
  "所需的皮纸与制革知识。");
setHard("tech.application.rag_paper_workshop",
  ["tech.rag_paper_making", "tech.application.flax_collector",
    "tech.application.flax_retting_pit"], "所需的碎布制纸知识。");
setHard("tech.application.paper_plant",
  ["tech.industrial_chemistry", "tech.mechanized_printing", "tech.factory_system"],
  "所需的现代造纸、印刷与工厂组织知识。");
setHard("tech.application.composting_yard",
  ["tech.crop_rotation", "tech.mechanical_workshops", "tech.pastoralism"],
  "所需的轮作、机械作业与牧业循环知识。");
setHard("tech.application.sulfur_collector", ["tech.gunpowder_formulation", "tech.ground_stone_tools"],
  "所需的硫磺识别与基础采掘知识。");
setHard("tech.application.early_oil_well",
  ["tech.petroleum_extraction", "tech.petroleum_drilling", "tech.steam_power"],
  "所需的钻井、石油开采与蒸汽动力知识。");
setHard("tech.application.oil_collector",
  ["tech.petroleum_drilling", "tech.machine_tools"],
  "所需的钻井与机械加工知识。");
setHard("tech.application.lubricants_plant",
  ["tech.industrial_ecology", "tech.digital_control", "tech.petroleum_refining"],
  "所需的石化精炼与过程控制知识。");

// The runtime signal catalog currently exposes resource provenance for these
// mineral routes, but no generic contact.<mineral> signals. Keep discovery
// valid against that authoritative vocabulary until contact signals are
// separately authored in the research catalog.
for (const [id, signal] of [
  ["tech.iron_ore_identification", "resource.iron_ore"],
  ["tech.application.sulfur_collector", "resource.sulfur"],
]) {
  const node = nodeById.get(id);
  if (node) node.reveal_condition = {kind: 1, id: signal, value: 1};
}
const goldsmithNode = nodeById.get("tech.application.goldsmith_workshop");
if (goldsmithNode) goldsmithNode.reveal_condition = {operator: 2, children: [
  {kind: 1, id: "resource.gold_ore", value: 1},
  {kind: 1, id: "resource.silver_ore", value: 1},
]};

// Single-parent method nodes only delayed a method already completely described
// by its source knowledge. Fold their buildings and all graph references into
// that source instead of inventing a second technology decision.
const COLLAPSED_METHODS = new Map([
  ["tech.method.wild_wheat_stand", "tech.wild_wheat_collection"],
  ["tech.method.reed_cutting_camp", "tech.reed_harvesting"],
  ["tech.method.turf_cutting_ground", "tech.turf_cutting"],
  ["tech.method.earth_digging_pit", "tech.earth_building"],
  ["tech.method.wild_maize_stand", "tech.wild_maize_collection"],
  ["tech.method.rainfed_wheat_plot", "tech.rainfed_wheat_cultivation"],
  ["tech.method.rubble_stone_working", "tech.ground_stone_tools"],
  ["tech.method.household_weaving_shelter", "tech.weaving"],
  ["tech.method.lumber_plant", "tech.timber_sawing"],
  ["tech.method.wild_rice_marsh", "tech.wild_rice_collection"],
]);
const canonicalTechnology = (id) => {
  let current = id;
  while (COLLAPSED_METHODS.has(current)) current = COLLAPSED_METHODS.get(current);
  return current;
};
function replaceTechnologyAtom(spec) {
  if (!spec || typeof spec !== "object") return spec;
  if (Number(spec.kind) === 0 && typeof spec.id === "string") {
    return {...spec, id: canonicalTechnology(spec.id)};
  }
  if (!Array.isArray(spec.children)) return spec;
  return {...spec, children: spec.children.map(replaceTechnologyAtom)};
}
for (const building of buildings) {
  const owner = directTechnology(building);
  if (COLLAPSED_METHODS.has(owner)) replaceTechnology(building, canonicalTechnology(owner));
}
for (const [obsolete, source] of COLLAPSED_METHODS) {
  const obsoleteNode = nodeById.get(obsolete);
  const sourceNode = nodeById.get(source);
  if (!obsoleteNode || !sourceNode) continue;
  sourceNode.modifier_terms = [...(sourceNode.modifier_terms ?? []),
    ...(obsoleteNode.modifier_terms ?? [])];
  sourceNode.expected_bindings = [...(sourceNode.expected_bindings ?? []),
    ...(obsoleteNode.expected_bindings ?? [])];
  sourceNode.content_effects = [...(sourceNode.content_effects ?? []),
    ...(obsoleteNode.content_effects ?? [])];
  sourceNode.branch_successor_ids = [...new Set([
    ...(sourceNode.branch_successor_ids ?? []),
    ...(obsoleteNode.branch_successor_ids ?? []),
  ].map(canonicalTechnology).filter((id) => id !== source))];
}
network.nodes = network.nodes.filter((node) => !COLLAPSED_METHODS.has(node.id));
nodeById = new Map(network.nodes.map((node) => [node.id, node]));
for (const node of network.nodes) {
  node.hard_prerequisite_ids = [...new Set((node.hard_prerequisite_ids ?? [])
    .map(canonicalTechnology).filter((id) => id !== node.id))];
  node.prerequisite_rationales = node.hard_prerequisite_ids.map((id) =>
    `${nodeById.get(id)?.display_name ?? id}是${node.display_name}不可替代的知识基础。`);
  node.branch_successor_ids = [...new Set((node.branch_successor_ids ?? [])
    .map(canonicalTechnology).filter((id) => id !== node.id))];
  node.reveal_condition = replaceTechnologyAtom(node.reveal_condition);
  node.research_routes = (node.research_routes ?? []).map((route) => ({
    ...route, condition: replaceTechnologyAtom(route.condition),
  }));
  const basis = node.knowledge_basis ?? {};
  basis.required_ids = [...new Set((basis.required_ids ?? [])
    .map(canonicalTechnology).filter((id) => id !== node.id))];
  basis.alternative_groups = (basis.alternative_groups ?? []).map((group) =>
    [...new Set(group.map(canonicalTechnology).filter((id) => id !== node.id))])
    .filter((group) => group.length);
  node.knowledge_basis = basis;
}
for (const era of network.eras) {
  era.milestone_candidate_ids = [...new Set((era.milestone_candidate_ids ?? [])
    .map(canonicalTechnology))];
}
const visualEdgeKeys = new Set();
network.visual_edges = (network.visual_edges ?? []).map((edge) => ({
  ...edge, from: canonicalTechnology(edge.from), to: canonicalTechnology(edge.to),
})).filter((edge) => {
  if (edge.from === edge.to) return false;
  const key = `${edge.kind}:${edge.from}:${edge.to}:${edge.route_id ?? ""}`;
  if (visualEdgeKeys.has(key)) return false;
  visualEdgeKeys.add(key);
  return true;
});

// Era placement follows the earliest complete knowledge/recipe package. These
// overrides reverse the old fixed-count capacity moves and lock the audited
// historical/industrial packages to their semantic era.
const SEMANTIC_ERA_OVERRIDES = {
  agrarian: [
    "tech.application.early_clay_pit", "tech.application.pastoral_camp",
    "tech.application.surface_silver_working", "tech.application.small_game_trapline",
    "tech.horse_domestication", "tech.application.maize_garden",
    "tech.application.swidden_maize_plot", "tech.application.floodplain_maize_plot",
    "tech.application.floodplain_wheat_plot", "tech.application.wetland_rice_garden",
    "tech.application.flax_collector", "tech.application.spice_shade_garden",
    "tech.application.creamery", "tech.application.highland_tuber_plot",
    "tech.application.adobe_yard",
  ],
  kingdom: [
    "tech.application.lorekeeper_circle", "tech.application.merchant_post",
    "tech.application.oral_memory_circle", "tech.application.flood_calendar_shrine",
    "tech.application.fertile_soil_collector", "tech.application.wheat_farm",
    "tech.application.rice_collector", "tech.application.slaughterhouse",
    "tech.application.tenant_rainfed_maize_field",
    "tech.application.tenant_rainfed_wheat_field", "tech.application.tenant_paddy",
    "tech.application.sharecrop_paddy",
  ],
  empire: [
    "tech.application.primitive_gold_sluice", "tech.application.shallow_silver_working",
    "tech.application.seasonal_observation_shelter", "tech.application.tide_observation_hut",
    "tech.application.pottery_kiln", "tech.application.bricks_plant",
    "tech.application.salt_collector", "tech.application.classical_scriptorium",
    "tech.application.guild_weaving_house",
  ],
  exploration: [
    "tech.application.method_marine_fish_collector_r2", "tech.application.cottage_weaving",
  ],
  enlightenment: [
    "tech.application.atmospheric_engine_workshop",
  ],
  steam: [
    "tech.application.improved_domestic_loom",
  ],
  electrical: [
    "tech.application.electricity_plant", "tech.application.wire_plant",
    "tech.application.basic_electrical_equipment_works",
    "tech.application.scientific_instrument_works",
    "tech.application.industrial_research_laboratory",
  ],
  atomic: ["tech.application.polytechnic_institute"],
  information: ["tech.application.nuclear_power_plant"],
  stone: ["tech.wild_tuber_collection", "tech.application.wild_tuber_patch"],
};
for (const [eraId, ids] of Object.entries(SEMANTIC_ERA_OVERRIDES)) {
  for (const id of ids) moveNode(id, eraId);
}

// Re-group moved foundation nodes before their same-era consumers.
function moveBefore(id, beforeId) {
  const from = network.nodes.findIndex((node) => node.id === id);
  const node = network.nodes.splice(from, 1)[0];
  const to = network.nodes.findIndex((row) => row.id === beforeId);
  network.nodes.splice(to, 0, node);
}
moveBefore("tech.wild_flax_collection", "tech.fiber_twisting");
moveBefore("tech.application.early_tin_smelter", "tech.application.ore_bronzesmith_camp");
nodeById = new Map(network.nodes.map((node) => [node.id, node]));

function buildingOwnerMap() {
  return new Map(buildings.map((building) => [building.id, directTechnology(building)]));
}

let buildingOwner = buildingOwnerMap();
function producerMap() {
  const out = new Map();
  for (const building of buildings) {
    for (const goodId of building.strings("output_good_ids")) {
      if (!out.has(goodId)) out.set(goodId, new Set());
      for (const owner of building.strings("technology_tags").filter((tag) => tag.startsWith("tech."))) {
        out.get(goodId).add(owner);
      }
    }
  }
  return out;
}

let producers = producerMap();
let order = new Map(network.nodes.map((node, index) => [node.id, index]));
for (const good of goods) {
  const nonTechnology = good.strings("technology_tags").filter((tag) => !tag.startsWith("tech."));
  const technology = [...(producers.get(good.id) ?? [])].sort((a, b) =>
    (order.get(a) ?? 1e9) - (order.get(b) ?? 1e9) || a.localeCompare(b));
  if (!technology.length) throw new Error(`good has no producer: ${good.id}`);
  setProperty(good, "technology_tags", packedString([...nonTechnology, ...technology]));
}

// Keep authoring bindings exactly equal to the explicit resource catalogs.
const buildingEffects = new Map();
for (const building of buildings) {
  for (const owner of building.strings("technology_tags").filter((tag) => tag.startsWith("tech."))) {
    if (!buildingEffects.has(owner)) buildingEffects.set(owner, []);
    buildingEffects.get(owner).push({id: building.id, name: building.name});
  }
}
const goodEffects = new Map();
for (const good of goods) {
  for (const technology of good.strings("technology_tags").filter((tag) => tag.startsWith("tech."))) {
    if (!goodEffects.has(technology)) goodEffects.set(technology, []);
    goodEffects.get(technology).push({id: good.id, name: good.name});
  }
}
for (const node of network.nodes) {
  const retainedBindings = (node.expected_bindings ?? []).filter((binding) =>
    Number(binding.kind) !== 1 && Number(binding.kind) !== 2);
  const retainedEffects = (node.content_effects ?? []).filter((effect) =>
    effect.kind !== "good" && effect.kind !== "building");
  for (const row of [...(goodEffects.get(node.id) ?? [])].sort((a, b) => a.id.localeCompare(b.id))) {
    retainedBindings.push({kind: 1, id: row.id});
    retainedEffects.push({kind: "good", id: row.id, binding_kind: 1,
      subject: `good.${row.id}`, attribute: "production_access", operation: "unlock", value: 1,
      implementation: "GoodProfile.technology_tags", status: "existing_binding", display_name: row.name});
  }
  for (const row of [...(buildingEffects.get(node.id) ?? [])].sort((a, b) => a.id.localeCompare(b.id))) {
    retainedBindings.push({kind: 2, id: row.id});
    retainedEffects.push({kind: "building", id: row.id, binding_kind: 2,
      subject: `building.${row.id}`, attribute: "construction_and_production_access",
      operation: "unlock", value: 1, implementation: "BuildingProfile.technology_tags",
      status: "existing_binding", display_name: row.name});
  }
  node.expected_bindings = retainedBindings;
  node.content_effects = retainedEffects;
}
const removedSameTargetModifiers = [];
for (const node of network.nodes) {
  const unlocked = new Set((node.expected_bindings ?? []).map((binding) =>
    `${Number(binding.kind)}:${binding.id}`));
  node.modifier_terms = (node.modifier_terms ?? []).filter((term) => {
    const kind = term.subject_kind === "good" ? 1 : term.subject_kind === "building" ? 2 :
      term.subject_kind === "resource" ? 3 : 0;
    if (!kind || !unlocked.has(`${kind}:${term.subject_id}`)) return true;
    removedSameTargetModifiers.push(`${node.id}:${term.subject_kind}.${term.subject_id}`);
    return false;
  });
}

function buildingCountByEra() {
  const counts = Array(ERA_IDS.length).fill(0);
  for (const [buildingId, owner] of buildingOwner) {
    if (!buildingById.has(buildingId)) continue;
    counts[eraById.get(nodeById.get(owner).era_id)] += 1;
  }
  return counts;
}

function hardSuccessors() {
  const out = new Map(network.nodes.map((node) => [node.id, []]));
  for (const node of network.nodes) {
    for (const prerequisite of node.hard_prerequisite_ids ?? []) out.get(prerequisite).push(node.id);
  }
  return out;
}

const finalCounts = buildingCountByEra();

const relaxedFutureInputs = [];
for (const building of buildings) {
  const inputIds = building.strings("input_good_ids");
  if (!inputIds.length) continue;
  const quantities = building.ints("input_quantities_per_day");
  const configuredRequired = building.ints("input_required_q16");
  const required = inputIds.map((_, index) => configuredRequired[index] ?? 65536);
  const configuredCategories = building.strings("input_category_ids");
  const categories = inputIds.map((_, index) => configuredCategories[index] ?? "");
  const ownerEra = eraById.get(nodeById.get(buildingOwner.get(building.id)).era_id);
  let changed = false;
  for (let slot = 0; slot < inputIds.length; slot += 1) {
    if (required[slot] <= 0) continue;
    const producerEras = [...(producers.get(inputIds[slot]) ?? [])].map((technology) =>
      eraById.get(nodeById.get(technology).era_id));
    if (producerEras.length && Math.min(...producerEras) > ownerEra) {
      required[slot] = 0;
      changed = true;
      relaxedFutureInputs.push(`${building.id}:${inputIds[slot]}`);
    }
  }
  if (changed) replaceInput(building, inputIds, quantities, required, categories);
}

// Add visible prerequisites for construction, mandatory inputs, and resource discovery.
const resourceTechnology = new Map(resources.map((resource) => [resource.id,
  resource.strings("discovery_technology_tags").filter((tag) => tag.startsWith("tech."))]));
const goodTags = new Map(goods.map((good) => [good.id,
  good.strings("technology_tags").filter((tag) => tag.startsWith("tech."))]));

function ancestors(id, memo = new Map(), visiting = new Set()) {
  if (memo.has(id)) return memo.get(id);
  if (visiting.has(id)) throw new Error(`hard prerequisite cycle at ${id}`);
  visiting.add(id);
  const result = new Set([id]);
  for (const prerequisite of nodeById.get(id).hard_prerequisite_ids ?? []) {
    for (const ancestor of ancestors(prerequisite, memo, visiting)) result.add(ancestor);
  }
  visiting.delete(id);
  memo.set(id, result);
  return result;
}

function routeTechnologyAtoms(node) {
  const out = new Set();
  function visit(spec) {
    if (!spec || typeof spec !== "object") return;
    if (Number(spec.kind) === 0 && typeof spec.id === "string" && spec.id.startsWith("tech.")) out.add(spec.id);
    for (const child of spec.children ?? []) visit(child);
  }
  for (const route of node.research_routes ?? []) visit(route.condition);
  return out;
}

function addDependency(id, alternatives, label) {
  const node = nodeById.get(id);
  let closure = ancestors(id, new Map());
  if (alternatives.some((candidate) => closure.has(candidate))) return;
  const routeAtoms = routeTechnologyAtoms(node);
  const targetEra = eraById.get(node.era_id);
  const candidates = [...new Set(alternatives)].filter((candidate) => {
    const producer = nodeById.get(candidate);
    return producer && candidate !== id && eraById.get(producer.era_id) <= targetEra &&
      !routeAtoms.has(candidate) && !ancestors(candidate, new Map()).has(id);
  }).sort((a, b) => eraById.get(nodeById.get(a).era_id) - eraById.get(nodeById.get(b).era_id) ||
    (originalIndex.get(a) ?? 1e9) - (originalIndex.get(b) ?? 1e9) || a.localeCompare(b));
  if (!candidates.length) throw new Error(`${id} lacks earlier dependency producer for ${label}: ${alternatives}`);
  const selected = candidates[0];
  node.hard_prerequisite_ids.push(selected);
  node.prerequisite_rationales.push(`${nodeById.get(selected).display_name}提供${node.display_name}所需的${label}。`);
  const basis = node.knowledge_basis;
  basis.required_ids = [...new Set([...(basis.required_ids ?? []), selected])];
}

function candidateGoods(building, slot) {
  const preferred = building.strings("input_good_ids")[slot];
  const category = building.strings("input_category_ids")[slot] ?? "";
  if (!category) return [preferred];
  const minimumQuality = building.ints("input_min_quality_levels")[slot] ?? 0;
  return goods.filter((good) =>
    (good.id === preferred || good.strings("category_id").includes(category) ||
      good.strings("substitution_category_ids").includes(category)) &&
    scalarInt(good, "production_quality_level", 0) >= minimumQuality)
    .map((good) => good.id);
}

function removeHardPrerequisite(node, prerequisite) {
  const retainedIndices = [];
  for (let index = 0; index < (node.hard_prerequisite_ids ?? []).length; index += 1) {
    if (node.hard_prerequisite_ids[index] !== prerequisite) retainedIndices.push(index);
  }
  if (retainedIndices.length === (node.hard_prerequisite_ids ?? []).length) return false;
  const oldPrerequisites = node.hard_prerequisite_ids ?? [];
  const oldRationales = node.prerequisite_rationales ?? [];
  node.hard_prerequisite_ids = retainedIndices.map((index) => oldPrerequisites[index]);
  node.prerequisite_rationales = retainedIndices.map((index) =>
    oldRationales[index] ?? `${nodeById.get(oldPrerequisites[index])?.display_name ??
      oldPrerequisites[index]}是${node.display_name}不可替代的知识基础。`);
  if (node.knowledge_basis) {
    node.knowledge_basis.required_ids = (node.knowledge_basis.required_ids ?? [])
      .filter((id) => id !== prerequisite);
  }
  return true;
}

// Older runs treated every positive input_required_q16 as a research gate.
// Remove only stale tool-producer edges left by soft tool slots. Explicitly
// authored knowledge foundations continue to gate the technology; construction
// goods and operating inputs are audited below but never synthesized here.
const removedSoftToolDependencies = [];
for (const building of buildings) {
  const owner = buildingOwner.get(building.id);
  const ownerNode = nodeById.get(owner);
  if (!ownerNode) continue;
  const inputIds = building.strings("input_good_ids");
  const categories = building.strings("input_category_ids");
  const configuredRequired = building.ints("input_required_q16");
  const softToolTechnologies = new Set();
  const retainedRecipeTechnologies = new Set();
  for (const goodId of building.strings("construction_good_ids")) {
    for (const technology of goodTags.get(goodId) ?? []) retainedRecipeTechnologies.add(technology);
  }
  for (let slot = 0; slot < inputIds.length; slot += 1) {
    const requiredQ16 = configuredRequired[slot] ?? 65536;
    const alternatives = candidateGoods(building, slot)
      .flatMap((goodId) => goodTags.get(goodId) ?? []);
    if (requiredQ16 >= 65536) {
      for (const technology of alternatives) retainedRecipeTechnologies.add(technology);
      continue;
    }
    if (inputIds[slot] === "tools" || (categories[slot] ?? "") === "tools") {
      for (const technology of alternatives) softToolTechnologies.add(technology);
    }
  }
  for (const prerequisite of [...(ownerNode.hard_prerequisite_ids ?? [])]) {
    if (!softToolTechnologies.has(prerequisite) ||
        retainedRecipeTechnologies.has(prerequisite) ||
        explicitlyAuthoredHardEdges.has(`${prerequisite}->${owner}`)) {
      continue;
    }
    if (removeHardPrerequisite(ownerNode, prerequisite)) {
      removedSoftToolDependencies.push(`${owner}:${prerequisite}`);
    }
  }
}

// These are supply methods, not universal knowledge gates. Remove legacy
// closure edges in one deterministic pass so existing authoring data is
// repaired even when the script is run on an older network snapshot.
const removedSupplierDependencies = [];
const bannedSupplierPrerequisites = [
  "tech.application.fired_brick_kiln",
  "tech.application.classical_masonry_yard",
  "tech.application.ore_bronzesmith_camp",
  "tech.application.iron_tool_workshop",
];
for (const node of network.nodes) {
  for (const prerequisite of bannedSupplierPrerequisites) {
    if (removeHardPrerequisite(node, prerequisite)) {
      removedSupplierDependencies.push(`${node.id}:${prerequisite}`);
    }
  }
}

// Keep the explicit knowledge contract closed under the authored hard graph.
// Older snapshots retained removed supplier IDs in knowledge_basis; filtering
// them here makes the persisted audit data agree with the actual graph.
for (const node of network.nodes) {
  const closure = ancestors(node.id, new Map());
  const basis = node.knowledge_basis ?? {};
  basis.required_ids = [...new Set([
    ...(basis.required_ids ?? []),
    ...(node.hard_prerequisite_ids ?? []),
  ].filter((id) => id !== node.id && closure.has(id)))];
  basis.alternative_groups = (basis.alternative_groups ?? []).map((group) =>
    [...new Set(group.filter((id) => id !== node.id))]).filter((group) => group.length);
  node.knowledge_basis = basis;
}

// Construction goods, operating inputs, and local-resource discovery are
// economic availability constraints, not universal research prerequisites.
// Keep them visible for review without mutating the authoritative technology
// graph.  This prevents a producer's technology from becoming a cross-sector
// hard gate merely because another building can buy its output.
const constructionSupplyEdges = [];
const operatingInputEdges = [];
const resourceSupplyEdges = [];
for (const building of buildings) {
  const owner = buildingOwner.get(building.id);
  const ownerNode = nodeById.get(owner);
  if (!ownerNode) continue;
  for (const goodId of building.strings("construction_good_ids")) {
    const technologies = goodTags.get(goodId) ?? [];
    if (technologies.length) {
      constructionSupplyEdges.push({owner, building: building.id, good: goodId,
        technologies: [...technologies]});
    }
  }
  const inputIds = building.strings("input_good_ids");
  const configuredRequired = building.ints("input_required_q16");
  for (let slot = 0; slot < inputIds.length; slot += 1) {
    if ((configuredRequired[slot] ?? 65536) < 65536) continue;
    const alternatives = candidateGoods(building, slot)
      .flatMap((goodId) => goodTags.get(goodId) ?? []);
    if (alternatives.length) {
      operatingInputEdges.push({owner, building: building.id, slot,
        good: inputIds[slot], technologies: [...new Set(alternatives)]});
    }
  }
  for (const resourceId of [...building.strings("resource_ids"),
    ...building.strings("resource_generation_ids")]) {
    const technologies = resourceTechnology.get(resourceId) ?? [];
    if (technologies.length) {
      resourceSupplyEdges.push({owner, building: building.id, resource: resourceId,
        technologies: [...technologies]});
    }
  }
}

// Calibrate every producing building against one cross-sector era ladder. The
// values live in BuildingProfile; runtime production and investment consume the
// existing packed recipe columns without a balance-time modifier or script.
function scalarInt(resource, name, fallback = 0) {
  if (!resource) return fallback;
  const value = Number(resource.props[name] ?? fallback);
  return Number.isFinite(value) ? value : fallback;
}
function defaultPrice(goodId) {
  return Math.max(0, scalarInt(goodById.get(goodId), "default_price", 0));
}
function employeeSlots(building) {
  return building.ints("employee_slots_per_building").reduce((sum, value) => sum + value, 0);
}
function laborSlots(building) {
  return Math.max(1, scalarInt(building, "owner_slots_per_building", 1) +
    employeeSlots(building));
}
function recipeValue(ids, quantities) {
  return ids.reduce((sum, id, index) => sum +
    (id ? Math.max(0, quantities[index] ?? 0) * defaultPrice(id) : 0), 0);
}
function outputValue(building) {
  return recipeValue(building.strings("output_good_ids"),
    building.ints("output_quantities_per_day"));
}
function foodEquivalentValue(ids, quantities) {
  return ids.reduce((sum, id, index) => sum +
    (FOOD_EQUIVALENT_GOODS.has(id) ? Math.max(0, quantities[index] ?? 0) : 0), 0);
}
function foodEquivalentOutput(building) {
  return foodEquivalentValue(building.strings("output_good_ids"),
    building.ints("output_quantities_per_day"));
}
function median(values) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}
function technologyEra(building) {
  const owner = directTechnology(building);
  return eraById.get(nodeById.get(owner)?.era_id) ?? 0;
}
function familyKey(building) {
  const outputs = [...building.strings("output_good_ids")].sort();
  const explicit = quotedStrings(building.props.upgrade_family_id ?? "")[0] ?? "";
  // Research and precious-metal methods need a single authored curve even when
  // legacy profiles omitted or split upgrade_family_id.
  if (outputs.includes("technology_points") && explicit === "research_institution") {
    return "special:research";
  }
  if (outputs.includes("gold")) return "special:gold";
  if (outputs.includes("silver")) return "special:silver";
  if (explicit) return `family:${explicit}`;
  const sector = quotedStrings(building.props.economic_sector_id ?? "")[0] ?? "";
  return outputs.length ? `outputs:${sector}:${outputs.join("+")}` : `building:${building.id}`;
}
const producingBuildings = buildings.filter((building) =>
  building.strings("output_good_ids").length && outputValue(building) > 0);
// Fixed authored anchor: deriving this from already-calibrated output would make
// repeated --write runs compound same-era tier multipliers and drift the catalog.
const openingProductivity = 13_000_000;
const productivityGroups = new Map();
for (const building of producingBuildings) {
  const key = familyKey(building);
  if (!productivityGroups.has(key)) productivityGroups.set(key, []);
  productivityGroups.get(key).push({
    building,
    era: technologyEra(building),
    tier: scalarInt(building, "upgrade_tier", 0),
    labor: laborSlots(building),
    currentProductivity: outputValue(building) / laborSlots(building),
    targetProductivity: 0,
    currentFoodUnitsPerLabor: foodEquivalentOutput(building) / laborSlots(building),
    targetFoodUnitsPerLabor: 0,
  });
}
const productivityChanges = [];
for (const [key, rows] of productivityGroups) {
  rows.sort((a, b) => a.era - b.era || a.tier - b.tier ||
    a.building.id.localeCompare(b.building.id));
  const outputs = new Set(rows.flatMap((row) => row.building.strings("output_good_ids")));
  const research = outputs.has("technology_points");
  const precious = outputs.has("gold") || outputs.has("silver");
  const food = rows.every((row) => row.currentFoodUnitsPerLabor > 0);
  const first = rows[0];
  let previousTarget = 0;
  let previousEra = -1;
  let sameEraRank = 0;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index];
    sameEraRank = row.era === previousEra ? sameEraRank + 1 : 0;
    let target;
    if (food) {
      const sameEraMultiplier = Math.min(1.15, Math.pow(1.08, sameEraRank));
      row.targetFoodUnitsPerLabor = survivalFoodUnitsPerPerson *
        ERA_FOOD_LABOR_CAPACITY[row.era] * sameEraMultiplier;
      // Kept only for construction-value diagnostics below; output scaling for
      // food uses physical survival units rather than default-price value.
      target = row.currentProductivity;
    } else if (research) {
      const progress = rows.length <= 1 ? 0 : index / (rows.length - 1);
      target = first.currentProductivity * (1 + 15 * progress);
    } else if (precious) {
      const progress = rows.length <= 1 ? 0 : index / (rows.length - 1);
      target = first.currentProductivity * (1 + 11 * progress);
    } else {
      target = openingProductivity * ERA_PRODUCTIVITY_INDEX[row.era] *
        Math.pow(1.35, sameEraRank);
      if (previousTarget > 0) target = Math.max(target, previousTarget * 1.35);
    }
    row.targetProductivity = Math.max(1, target);
    previousTarget = row.targetProductivity;
    previousEra = row.era;
  }
  if (!food && !research && !precious && rows.length > 1 && first.era <= 1 &&
      rows.at(-1).era >= 9) {
    const last = rows.at(-1);
    last.targetProductivity = Math.max(first.targetProductivity * 15,
      Math.min(first.targetProductivity * 25, last.targetProductivity));
  }
  for (const row of rows) {
    const building = row.building;
    const oldOutputValue = outputValue(building);
    if (oldOutputValue <= 0) continue;
    const oldFoodOutput = foodEquivalentOutput(building);
    const desiredFoodOutput = food
      ? row.targetFoodUnitsPerLabor * row.labor : 0;
    const outputScale = food
      ? desiredFoodOutput / Math.max(1, oldFoodOutput)
      : row.targetProductivity * row.labor / oldOutputValue;
    const outputQuantities = building.ints("output_quantities_per_day");
    const scaledOutputs = outputQuantities.map((quantity) =>
      Math.max(1, Math.round(quantity * outputScale)));
    setProperty(building, "output_quantities_per_day",
      packedInt(scaledOutputs, "PackedInt64Array"));
    const desiredOutputValue = outputValue(building);

    if (outputScale > 1.001 || (food && outputScale < 0.999)) {
      const inputIds = building.strings("input_good_ids");
      const inputQuantities = building.ints("input_quantities_per_day");
      const materialIntensity = 1.0 - 0.4 * row.era / (ERA_IDS.length - 1);
      const scaledInputs = inputQuantities.map((quantity, index) => {
        const id = inputIds[index];
        const intensity = outputScale < 1.0 ? 1.0 : ENERGY_GOODS.has(id) ? 0.80 :
          CAPITAL_GOODS.has(id) ? 0.75 : materialIntensity;
        const absoluteFloor = row.era >= 6 && (ENERGY_GOODS.has(id) || CAPITAL_GOODS.has(id))
          ? 1.25 : 1.0;
        const factor = outputScale < 1.0 ? outputScale :
          Math.max(absoluteFloor, outputScale * intensity);
        return Math.max(1, Math.round(quantity * factor));
      });
      if (inputIds.length) setProperty(building, "input_quantities_per_day",
        packedInt(scaledInputs, "PackedInt64Array"));

      const resourceIds = building.strings("resource_ids");
      const resourceQuantities = building.ints("resource_quantities_per_day");
      const resourceModes = building.strings("resource_interaction_modes");
      const scaledResources = resourceQuantities.map((quantity, index) => {
        if (food && outputScale < 1.0 && resourceModes[index] === "capacity") {
          return quantity;
        }
        if (resourceModes[index] === "capacity") {
          return Math.max(1, Math.round(quantity * (1.0 - 0.3 * row.era /
            (ERA_IDS.length - 1))));
        }
        return Math.max(1, Math.round(quantity * outputScale * materialIntensity));
      });
      if (resourceIds.length) setProperty(building, "resource_quantities_per_day",
        packedInt(scaledResources, "PackedInt64Array"));
    }

    if (food) {
      const inputIds = building.strings("input_good_ids");
      const inputQuantities = building.ints("input_quantities_per_day");
      const configuredRequired = building.ints("input_required_q16");
      const foodInputSlots = inputIds.map((id, index) =>
        FOOD_EQUIVALENT_GOODS.has(id) && (configuredRequired[index] ?? 65536) > 0
          ? index : -1).filter((index) => index >= 0);
      const currentFoodInput = foodInputSlots.reduce((sum, index) =>
        sum + Math.max(0, inputQuantities[index] ?? 0), 0);
      if (currentFoodInput > 0) {
        const desiredFoodInput = desiredFoodOutput /
          ERA_FOOD_PROCESSING_YIELD[row.era];
        const foodInputScale = desiredFoodInput / currentFoodInput;
        for (const slot of foodInputSlots) {
          inputQuantities[slot] = Math.max(1,
            Math.round(inputQuantities[slot] * foodInputScale));
        }
        setProperty(building, "input_quantities_per_day",
          packedInt(inputQuantities, "PackedInt64Array"));
      }
    }

    const inputIds = building.strings("input_good_ids");
    const configuredRequired = building.ints("input_required_q16");
    const required = inputIds.map((id, index) => {
      const current = configuredRequired[index] ?? 65536;
      if (current === 0) return 0;
      if (!ENERGY_GOODS.has(id) && !CAPITAL_GOODS.has(id)) return 65536;
      if (row.era >= 10) return 57344;
      if (row.era >= 7) return 49152;
      if (row.era >= 6) return 32768;
      return current;
    });
    if (inputIds.length) setProperty(building, "input_required_q16", packedInt(required));

    const constructionIds = building.strings("construction_good_ids");
    const constructionQuantities = building.ints("construction_quantities");
    const currentConstructionValue = recipeValue(constructionIds, constructionQuantities);
    if (currentConstructionValue > 0) {
      const dailyInputValue = recipeValue(inputIds,
        building.ints("input_quantities_per_day"));
      const dailyValueAdded = Math.max(desiredOutputValue * 0.20,
        desiredOutputValue - dailyInputValue);
      const desiredConstructionValue = dailyValueAdded *
        ERA_CONSTRUCTION_PAYBACK_DAYS[row.era] * 0.55;
      const constructionScale = desiredConstructionValue / currentConstructionValue;
      const scaledConstruction = constructionQuantities.map((quantity) =>
        Math.max(1, Math.round(quantity * constructionScale)));
      replaceConstruction(building, constructionIds, scaledConstruction);
    }
    productivityChanges.push({key, id: building.id, era: ERA_IDS[row.era], food,
      before: row.currentProductivity, after: outputValue(building) / row.labor,
      foodBefore: row.currentFoodUnitsPerLabor,
      foodAfter: foodEquivalentOutput(building) / row.labor});
  }
}

// Visual hard edges are a view of the authoritative prerequisite arrays. Rebuild
// them after semantic collapse and recipe-closure edits so UI and tests cannot
// retain stale graph links.
const retainedVisualEdges = (network.visual_edges ?? []).filter((edge) => edge.kind !== "hard");
for (const node of network.nodes) {
  for (const prerequisite of node.hard_prerequisite_ids ?? []) {
    retainedVisualEdges.push({from: prerequisite, to: node.id, kind: "hard"});
  }
}
network.visual_edges = retainedVisualEdges;

// Stable era-first topological order; all public string IDs remain unchanged.
// A newly visible production prerequisite can invalidate a legacy alternative
// route that points back from its consumer.  Keep the hard economic closure and
// prune only the cyclic technology atom; practice/development evidence remains.
const indegree = new Map(network.nodes.map((node) => [node.id, 0]));
const successors = new Map(network.nodes.map((node) => [node.id, []]));
function addOrderingEdge(source, target) {
  if (!successors.get(source).includes(target)) {
    successors.get(source).push(target);
    indegree.set(target, indegree.get(target) + 1);
  }
}
for (const node of network.nodes) {
  for (const prerequisite of node.hard_prerequisite_ids ?? []) addOrderingEdge(prerequisite, node.id);
}
function orderingPathExists(source, target) {
  const pending = [source];
  const seen = new Set();
  while (pending.length) {
    const id = pending.pop();
    if (id === target) return true;
    if (seen.has(id)) continue;
    seen.add(id);
    pending.push(...successors.get(id));
  }
  return false;
}
function pruneTechnologyAtom(spec, technologyId) {
  if (!spec || typeof spec !== "object") return spec;
  if (Number(spec.kind) === 0 && spec.id === technologyId) return null;
  if (!Array.isArray(spec.children)) return spec;
  const children = spec.children.map((child) => pruneTechnologyAtom(child, technologyId))
    .filter((child) => child);
  if (!children.length) return null;
  const copy = {...spec, children};
  if (Number(copy.operator) === 2) copy.required_count = Math.min(Number(copy.required_count), children.length);
  return copy;
}
const removedCyclicRouteAtoms = [];
for (const node of network.nodes) {
  const retainedRoutes = [];
  for (const route of node.research_routes ?? []) {
    let condition = route.condition;
    for (const source of routeTechnologyAtoms({research_routes: [{condition}]})) {
      if (orderingPathExists(node.id, source)) {
        condition = pruneTechnologyAtom(condition, source);
        removedCyclicRouteAtoms.push(`${route.id}:${source}`);
        const groups = node.knowledge_basis?.alternative_groups ?? [];
        node.knowledge_basis.alternative_groups = groups.map((group) =>
          group.filter((id) => id !== source)).filter((group) => group.length);
      } else {
        addOrderingEdge(source, node.id);
      }
    }
    if (condition) retainedRoutes.push({...route, condition});
  }
  node.research_routes = retainedRoutes;
}
const ready = network.nodes.filter((node) => indegree.get(node.id) === 0);
const sorted = [];
function compareNodes(a, b) {
  return eraById.get(a.era_id) - eraById.get(b.era_id) ||
    (originalIndex.get(a.id) ?? 1e9) - (originalIndex.get(b.id) ?? 1e9) || a.id.localeCompare(b.id);
}
while (ready.length) {
  ready.sort(compareNodes);
  const node = ready.shift();
  sorted.push(node);
  for (const successor of successors.get(node.id)) {
    indegree.set(successor, indegree.get(successor) - 1);
    if (indegree.get(successor) === 0) ready.push(nodeById.get(successor));
  }
}
if (sorted.length !== network.nodes.length) {
  const color = new Map();
  const stack = [];
  let cycle = [];
  function visit(id) {
    color.set(id, 1);
    stack.push(id);
    for (const next of successors.get(id)) {
      if (color.get(next) === 1) {
        cycle = [...stack.slice(stack.indexOf(next)), next];
        return true;
      }
      if (!color.has(next) && visit(next)) return true;
    }
    stack.pop();
    color.set(id, 2);
    return false;
  }
  for (const node of network.nodes) {
    if (!color.has(node.id) && visit(node.id)) break;
  }
  throw new Error(`technology ordering cycle: ${cycle.join(" -> ")}`);
}
network.nodes = sorted;

console.log(`mode=${WRITE ? "write" : WRITE_NETWORK_ONLY ? "write-network-only" : "check"}`);
console.log(`building_counts=${finalCounts.join("/")}`);
console.log(`collapsed_delay_methods=${COLLAPSED_METHODS.size}`);
console.log(`opening_productivity=${Math.round(openingProductivity)}`);
console.log(`productivity_profiles=${productivityChanges.length}`);
console.log(`survival_food_units_per_person=${survivalFoodUnitsPerPerson}`);
console.log(`food_productivity_profiles=${productivityChanges.filter((row) => row.food).length}`);
console.log(`future_inputs_made_optional=${relaxedFutureInputs.length}`);
for (const input of relaxedFutureInputs) console.log(`  ${input}`);
console.log(`cyclic_route_atoms_removed=${removedCyclicRouteAtoms.length}`);
for (const atom of removedCyclicRouteAtoms) console.log(`  ${atom}`);
console.log(`same_target_modifiers_removed=${removedSameTargetModifiers.length}`);
for (const modifier of removedSameTargetModifiers) console.log(`  ${modifier}`);
console.log(`soft_tool_dependencies_removed=${removedSoftToolDependencies.length}`);
for (const dependency of removedSoftToolDependencies) console.log(`  ${dependency}`);
console.log(`supplier_dependencies_removed=${removedSupplierDependencies.length}`);
for (const dependency of removedSupplierDependencies) console.log(`  ${dependency}`);
console.log(`construction_supply_edges_audited=${constructionSupplyEdges.length}`);
console.log(`operating_input_edges_audited=${operatingInputEdges.length}`);
console.log(`resource_supply_edges_audited=${resourceSupplyEdges.length}`);

if (WRITE) {
  for (const resource of [...buildings, ...goods]) fs.writeFileSync(resource.path, resource.text, "utf8");
}
if (WRITE || WRITE_NETWORK_ONLY) {
  fs.writeFileSync(NETWORK_PATH, JSON.stringify(network, null, "\t") + "\n", "utf8");
}
