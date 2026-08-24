"use strict";

const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");

const ROOT = path.resolve(__dirname, "../../Project/project-keynes");
const NETWORK_PATH = path.join(ROOT, "data/technology/technology_network.json");
const BUILDINGS_DIR = path.join(ROOT, "data/economy/buildings");
const GOODS_DIR = path.join(ROOT, "data/goods");
const RESOURCES_DIR = path.join(ROOT, "data/resources");
const REPO_ROOT = path.resolve(ROOT, "../..");

// The checkout may contain a partially authored network with trailing commas.
// Remove only JSON trailing commas before parsing; all semantic edits below are
// explicit and deterministic.
function readNetwork() {
  const source = fs.readFileSync(NETWORK_PATH, "utf8");
  return JSON.parse(source.replace(/,\s*([}\]])/g, "$1"));
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function packedStrings(text, field) {
  const match = text.match(new RegExp(`^${field}\\s*=\\s*PackedStringArray\\((.*?)\\)$`, "ms"));
  return match ? [...match[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]) : [];
}

function scalar(text, field, fallback = "") {
  const match = text.match(new RegExp(`^${field}\\s*=\\s*&?"([^"]*)"`, "m"));
  return match ? match[1] : fallback;
}

function readHeadBuilding(fileName) {
  try {
    return childProcess.execFileSync("git", [
      "show", `HEAD:Project/project-keynes/data/economy/buildings/${fileName}`,
    ], { cwd: REPO_ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch (_) {
    return "";
  }
}

function readHeadGood(fileName) {
  try {
    return childProcess.execFileSync("git", [
      "show", `HEAD:Project/project-keynes/data/goods/${fileName}`,
    ], { cwd: REPO_ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch (_) {
    return "";
  }
}

function rewritePackedStrings(text, field, values) {
  const line = `${field} = PackedStringArray(${values.map((value) => `"${value}"`).join(", ")})`;
  const pattern = new RegExp(`^${field}\\s*=\\s*PackedStringArray\\(.*?\\)$`, "ms");
  if (!pattern.test(text)) throw new Error(`${field} missing from building resource`);
  return text.replace(pattern, line);
}

function packedIntegers(text, field) {
  const match = text.match(new RegExp(
    `^${field}\\s*=\\s*PackedInt(?:32|64)Array\\((.*?)\\)$`, "ms"));
  return match ? [...match[1].matchAll(/-?\d+/g)].map((value) => Number(value[0])) : [];
}

function rewritePackedIntegers(text, field, values) {
  const line = `${field} = PackedInt64Array(${values.join(", ")})`;
  const pattern = new RegExp(
    `^${field}\\s*=\\s*PackedInt(?:32|64)Array\\(.*?\\)$`, "ms");
  if (!pattern.test(text)) throw new Error(`${field} missing from resource`);
  return text.replace(pattern, line);
}

function bindingEffect(buildingId, displayName) {
  return {
    kind: "building",
    id: buildingId,
    binding_kind: 2,
    subject: `building.${buildingId}`,
    attribute: "construction_and_production_access",
    operation: "unlock",
    value: 1,
    implementation: "BuildingProfile.technology_tags",
    status: "catalog_rebind",
    display_name: displayName,
  };
}

function goodEffect(goodId, displayName) {
  return {
    kind: "good",
    id: goodId,
    binding_kind: 1,
    subject: `good.${goodId}`,
    attribute: "production_access",
    operation: "unlock",
    value: 1,
    implementation: "GoodProfile.technology_tags",
    status: "catalog_rebind",
    display_name: displayName,
  };
}

function addUnique(values, value) {
  if (!values.includes(value)) values.push(value);
}

function setHardPrerequisites(node, ids, rationalePrefix) {
  const unique = [];
  for (const id of ids) if (id && !unique.includes(id)) unique.push(id);
  node.hard_prerequisite_ids = unique;
  node.prerequisite_rationales = unique.map((id) =>
    `${rationalePrefix}：${id}。`);
}

function signalRoute(id, displayName, routeType, description, signalIds) {
  const children = signalIds.map((signalId) => ({
    kind: 1,
    id: signalId,
    value: 1,
  }));
  return {
    id,
    display_name: displayName,
    route_type: routeType,
    description,
    condition: children.length === 1
      ? { operator: 0, ...children[0] }
      : { operator: 2, children },
  };
}

function technologyRoute(id, displayName, routeType, description, technologyIds) {
  const children = technologyIds.map((technologyId) => ({
    kind: 0,
    id: technologyId,
    value: 1,
  }));
  return {
    id,
    display_name: displayName,
    route_type: routeType,
    description,
    condition: children.length === 1
      ? { operator: 0, ...children[0] }
      : { operator: 2, children },
  };
}

function removeBuildingBinding(node, buildingId) {
  node.expected_bindings = (node.expected_bindings || []).filter((binding) =>
    !(Number(binding.kind) === 2 && String(binding.id) === buildingId));
  node.content_effects = (node.content_effects || []).filter((effect) =>
    !(String(effect.kind) === "building" && String(effect.id) === buildingId));
}

function addBuildingBinding(node, buildingId, displayName) {
  node.expected_bindings = (node.expected_bindings || []).filter((binding) =>
    !(Number(binding.kind) === 2 && String(binding.id) === buildingId));
  node.expected_bindings.push({ kind: 2, id: buildingId });
  node.content_effects = (node.content_effects || []).filter((effect) =>
    !(String(effect.kind) === "building" && String(effect.id) === buildingId));
  node.content_effects.push(bindingEffect(buildingId, displayName));
  node.effect_summary = `解锁建筑：${displayName}`;
}

function removeGoodBinding(node, goodId) {
  node.expected_bindings = (node.expected_bindings || []).filter((binding) =>
    !(Number(binding.kind) === 1 && String(binding.id) === goodId));
  node.content_effects = (node.content_effects || []).filter((effect) =>
    !(String(effect.kind) === "good" && String(effect.id) === goodId));
}

function addGoodBinding(node, goodId, displayName) {
  removeGoodBinding(node, goodId);
  node.expected_bindings.push({ kind: 1, id: goodId });
  node.content_effects.push(goodEffect(goodId, displayName));
}

function cleanEffectSummary(node, buildingNames, goodNames) {
  const activeBuildingNames = new Set((node.content_effects || [])
    .filter((effect) => String(effect.kind) === "building")
    .map((effect) => String(effect.display_name || "").trim())
    .filter((name) => name.length > 0));
  const activeGoodNames = new Set((node.content_effects || [])
    .filter((effect) => String(effect.kind) === "good")
    .map((effect) => String(effect.display_name || "").trim())
    .filter((name) => name.length > 0));
  const chunks = String(node.effect_summary || "").split("；");
  const retainedChunks = chunks.filter((chunkValue) => {
    const chunk = String(chunkValue).trim();
    if (chunk.startsWith("作为必要支撑")) return false;
    if (chunk.startsWith("解锁建筑：") || chunk.startsWith("解锁建筑: ")) {
      const name = chunk.replace(/^解锁建筑[:：]\s*/, "");
      return activeBuildingNames.has(name);
    }
    if (chunk.startsWith("解锁物资：") || chunk.startsWith("解锁物资: ")) {
      const name = chunk.replace(/^解锁物资[:：]\s*/, "");
      return activeGoodNames.has(name);
    }
    return chunk.length > 0;
  });
  for (const name of activeGoodNames) {
    if (!retainedChunks.some((chunk) => chunk === `解锁物资：${name}` ||
        chunk === `解锁物资: ${name}`)) retainedChunks.push(`解锁物资：${name}`);
  }
  for (const name of activeBuildingNames) {
    if (!retainedChunks.some((chunk) => chunk === `解锁建筑：${name}` ||
        chunk === `解锁建筑: ${name}`)) retainedChunks.push(`解锁建筑：${name}`);
  }
  node.effect_summary = retainedChunks.join("；");
}

function normalizeNode(node) {
  node.hard_prerequisite_ids = node.hard_prerequisite_ids || [];
  node.prerequisite_rationales = node.prerequisite_rationales || [];
  node.research_routes = node.research_routes || [];
  node.secondary_route_tags = node.secondary_route_tags || ["route.institution.knowledge"];
  if (node.secondary_route_tags.length === 0) {
    node.secondary_route_tags = ["route.institution.knowledge"];
  }
  node.branch_successor_ids = node.branch_successor_ids || [];
  node.branch_successor_rationales = node.branch_successor_rationales || [];
  node.application_target_ids = node.application_target_ids || [];
  node.application_target_rationales = node.application_target_rationales || [];
  node.expected_bindings = node.expected_bindings || [];
  node.content_effects = node.content_effects || [];
}

function removeConditionTechnologyIds(condition, technologyIds) {
  if (!condition || typeof condition !== "object") return condition;
  if (Number(condition.kind) === 0 && technologyIds.has(String(condition.id || ""))) {
    return null;
  }
  const result = clone(condition);
  if (Array.isArray(result.children)) {
    result.children = result.children
      .map((child) => removeConditionTechnologyIds(child, technologyIds))
      .filter((child) => child !== null);
  }
  if (result.child) {
    result.child = removeConditionTechnologyIds(result.child, technologyIds);
  }
  return result;
}

function collectConditionSignalIds(condition, output = new Set()) {
  if (!condition || typeof condition !== "object") return output;
  if (Number(condition.kind) === 1 && condition.id) output.add(String(condition.id));
  for (const child of condition.children || []) collectConditionSignalIds(child, output);
  if (condition.child) collectConditionSignalIds(condition.child, output);
  return output;
}

function collectConditionTechnologyIds(condition, output = new Set()) {
  if (!condition || typeof condition !== "object") return output;
  if (Number(condition.kind) === 0 && condition.id) output.add(String(condition.id));
  for (const child of condition.children || []) collectConditionTechnologyIds(child, output);
  if (condition.child) collectConditionTechnologyIds(condition.child, output);
  return output;
}

function makeApplicationNode(source, building, applicationId, hardIds, eraId) {
  const node = clone(source);
  normalizeNode(node);
  node.id = applicationId;
  node.display_name = `应用：${building.displayName}`;
  node.era_id = eraId;
  node.layout_order = Number(source.layout_order || 0) + 0.01;
  node.network_role = "branch";
  node.anchor_kind = "application";
  node.node_role = "applied_method";
  node.is_milestone = false;
  node.is_era_key = false;
  node.is_starting = false;
  node.is_starter_eligible = false;
  node.starter_capability_tags = [];
  node.cost_points = Math.max(3000, Number(source.cost_points || 0));
  node.modifier_terms = [];
  node.research_routes = [];
  node.route_exemption_reason = "应用科技的全部知识汇合已经由可见硬前置表达。";
  node.reveal_condition = {};
  node.reveal_category = "application_intersection";
  node.reveal_summary = "完成全部工艺前置后揭示该应用科技";
  node.branch_successor_ids = [];
  node.branch_successor_rationales = [];
  node.application_target_ids = [];
  node.application_target_rationales = [];
  node.secondary_route_tags = source.secondary_route_tags?.length
    ? clone(source.secondary_route_tags)
    : ["route.institution.knowledge"];
  setHardPrerequisites(node, hardIds,
    "该应用建筑要求先完成直接知识与全部工艺前置");
  node.expected_bindings = [];
  node.content_effects = [];
  addBuildingBinding(node, building.id, building.displayName);
  node.opportunity_cost = "多条知识路线汇合为一个可见应用节点，避免建筑条件隐式叠加。";
  node.terminal_reason = "应用节点直接呈现该建筑的完整解锁条件。";
  return node;
}

function main() {
  const payload = readNetwork();
  const authoredNodes = payload.nodes.map(clone);
  const existingApplicationById = new Map(authoredNodes
    .filter((node) => String(node.id).startsWith("tech.application.") ||
      String(node.id) === "tech.copper_mining_application")
    .map((node) => [String(node.id), node]));
  const nodes = authoredNodes.filter((node) =>
    !String(node.id).startsWith("tech.application.") &&
    String(node.id) !== "tech.copper_mining_application" &&
    String(node.id) !== "tech.early_knowledge_institution");
  const nodeById = new Map(nodes.map((node) => [String(node.id), node]));
  const eraIndex = new Map(payload.eras.map((era, index) => [String(era.id), index]));
  const stoneWhitelist = new Set([
    "stone_age_hunting_camp", "gathering_ground", "early_merchant_post",
    "placer_gold_working", "deadwood_gathering_camp",
    "hide_scraping_shelter", "early_knowledge_institution", "communal_hearth",
    "flint_quarry", "knapping_workshop", "stone_collector",
    "freshwater_fishing_camp", "marine_fish_collector", "bast_fiber_camp",
    "bast_wrap_shelter",
  ]);

  // Every era receives a deliberately paced learning load. The sequence is
  // monotonic and nearly arithmetic while accounting for every active
  // building exactly once.
  const eraBuildingTargets = new Map([
    ["stone", 15], ["agrarian", 17], ["kingdom", 20], ["empire", 24],
    ["exploration", 28], ["enlightenment", 32], ["steam", 36],
    ["electrical", 40], ["atomic", 44], ["information", 46],
    ["intelligent", 49],
  ]);
  const preferredBuildingEra = new Map([
    ["method_marine_fish_collector_r2", "agrarian"],
    ["method_gathering_ground_r1", "agrarian"],
    ["horse_breeding_camp", "agrarian"],
    ["pastoral_camp", "agrarian"],
    ["open_pottery_hearth", "agrarian"],
    ["primitive_clay_pit", "agrarian"],
    ["early_clay_pit", "agrarian"],
    ["charcoal_pit", "agrarian"],
    ["copper_ore_collector", "agrarian"],
    ["natural_copper_workshop", "agrarian"],
    ["early_copper_smelter", "agrarian"],
    ["rainfed_wheat_plot", "agrarian"],
    ["rainfed_maize_field", "agrarian"],
    ["upland_rice_plot", "agrarian"],
    ["potato_collector", "agrarian"],
    ["subsistence_farm", "agrarian"],
    ["surface_silver_working", "agrarian"],
  ]);
  const minimumBuildingEra = new Map([
    ["guild_weaving_house", "kingdom"],
    ["method_wool_shed_r3", "kingdom"],
    ["lumber_plant", "kingdom"],
    ["method_lumber_plant_r2", "kingdom"],
    ["cotton_ginning_shelter", "kingdom"],
    ["cobbler_shop", "kingdom"],
    ["tannery", "kingdom"],
    ["felt_making_tent", "kingdom"],
    ["fur_sewing_shelter", "kingdom"],
    ["household_weaving_shelter", "kingdom"],
    ["lorekeeper_circle", "kingdom"],
    ["merchant_post", "kingdom"],
    ["method_flint_quarry_r1", "kingdom"],
    ["method_timber_collector_r2", "kingdom"],
    ["pastoral_council_tent", "kingdom"],
    ["reed_cutting_camp", "kingdom"],
    ["rubble_stone_working", "kingdom"],
    ["seasonal_observation_shelter", "kingdom"],
    ["shallow_silver_working", "kingdom"],
    ["tide_observation_hut", "kingdom"],
    ["timber_collector", "kingdom"],
    ["turf_cutting_ground", "kingdom"],
    ["cottage_weaving", "kingdom"],
    ["household_loom", "kingdom"],
    ["adobe_yard", "kingdom"],
    ["bricks_plant", "kingdom"],
    ["fired_brick_kiln", "kingdom"],
    ["flax_retting_pit", "kingdom"],
    ["pottery_kiln", "kingdom"],
    ["bronze_tool_workshop", "kingdom"],
    ["early_tin_mine", "kingdom"],
    ["early_tin_smelter", "kingdom"],
    ["ore_bronzesmith_camp", "kingdom"],
    ["bakery", "kingdom"],
    ["classical_glass_kiln", "empire"],
    ["classical_silica_pit", "empire"],
    ["scribal_school", "empire"],
    ["latex_smoking_shelter", "empire"],
  ]);
  const milestoneCandidateTargets = [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18];
  const milestoneRequiredTargets = [4, 4, 4, 4, 5, 5, 5, 6, 6, 7, 7];
  const applicationSupportBySector = {
    agriculture: [
      "tech.permanent_settlements", "tech.crop_rotation", "tech.intensive_crop_rotation",
      "tech.commercial_estates", "tech.agricultural_improvement", "tech.mechanized_agriculture",
      "tech.motorized_agriculture", "tech.industrial_agronomy", "tech.precision_agriculture",
      "tech.automated_agriculture",
    ],
    extractive: [
      "tech.ground_stone_tools", "tech.market_institutions", "tech.mine_timbering",
      "tech.deep_mining", "tech.geological_prospecting", "tech.industrial_coal_mining",
      "tech.petroleum_extraction", "tech.mechanized_mining", "tech.geographic_information_systems",
      "tech.autonomous_mining",
    ],
    manufacturing: [
      "tech.permanent_settlements", "tech.market_institutions", "tech.guild_organization",
      "tech.chartered_companies", "tech.mechanical_workshops", "tech.factory_system",
      "tech.mass_production", "tech.operations_research", "tech.digital_control",
      "tech.robotic_manufacturing",
    ],
    energy: [
      "tech.charcoal_burning", "tech.market_institutions", "tech.water_power",
      "tech.chartered_companies", "tech.hydraulic_engineering", "tech.steam_power",
      "tech.electric_grid", "tech.nuclear_energy", "tech.digital_control", "tech.smart_grid",
    ],
    knowledge: [
      "tech.record_keeping", "tech.writing", "tech.scholarly_academies",
      "tech.chartered_universities", "tech.experimental_science", "tech.industrial_research",
      "tech.national_laboratories", "tech.software_engineering", "tech.machine_learning",
    ],
  };
  const primitiveApplicationSupport = {
    agriculture: "tech.gathering",
    extractive: "tech.stone_knapping",
    manufacturing: "tech.composite_tools",
    energy: "tech.fire_control",
    knowledge: "tech.early_knowledge_institution",
  };

  const buildings = [];
  for (const fileName of fs.readdirSync(BUILDINGS_DIR).filter((name) => name.endsWith(".tres")).sort()) {
    const filePath = path.join(BUILDINGS_DIR, fileName);
    const text = fs.readFileSync(filePath, "utf8");
	const id = scalar(text, "id", path.parse(fileName).name);
    const rawDirect = packedStrings(text, "technology_tags").filter((tag) => tag.startsWith("tech."));
    let direct = rawDirect;
    let required = packedStrings(text, "required_technology_tags").filter((tag) => tag.startsWith("tech."));
    const headText = readHeadBuilding(fileName);
    const headDirect = packedStrings(headText, "technology_tags")
      .filter((tag) => tag.startsWith("tech."));
    const headRequired = packedStrings(headText, "required_technology_tags")
      .filter((tag) => tag.startsWith("tech."));
	if (direct.length === 1 && nodeById.has(direct[0])) {
	  required = [];
	} else if (direct.length === 1 && !nodeById.has(direct[0]) &&
		direct[0] === `tech.application.${id}` &&
		nodeById.has(`tech.method.${id}`)) {
	  direct = [`tech.method.${id}`];
	  required = [];
	} else if (headDirect.length === 1 && nodeById.has(headDirect[0])) {
	  direct = headDirect;
	  required = headRequired;
	} else if (direct.length === 1 && !nodeById.has(direct[0]) &&
		(existingApplicationById.has(direct[0]) ||
		  (direct[0] === `tech.method.${id}` &&
			existingApplicationById.has(`tech.application.${id}`)))) {
	  const applicationId = existingApplicationById.has(direct[0])
		? direct[0] : `tech.application.${id}`;
      const application = existingApplicationById.get(applicationId);
      const specialDirect = {
        "tech.copper_mining_application": "tech.natural_copper_identification",
        "tech.application.early_tin_mine": "tech.copper_metallurgy",
        "tech.application.early_copper_mine": "tech.mine_timbering",
        "tech.application.ore_bronzesmith_camp": "tech.copper_annealing",
        "tech.application.knapping_workshop": "tech.stone_knapping",
      };
      const restoredDirect = specialDirect[applicationId] ||
        headDirect.find((id) => nodeById.has(id)) ||
        (application.hard_prerequisite_ids || []).find((id) => nodeById.has(String(id))) ||
        "";
      if (!restoredDirect || !nodeById.has(restoredDirect)) {
        throw new Error(`${fileName}: cannot recover direct technology from ${applicationId}`);
      }
      direct = [restoredDirect];
	  const foundationIds = Array.isArray(application.application_foundation_ids)
		? application.application_foundation_ids.map(String)
		: (application.hard_prerequisite_ids || []).filter((id, index) => {
		  const rationale = String((application.prerequisite_rationales || [])[index] || "");
		  return !rationale.startsWith("建筑配方需要") && !rationale.startsWith("建筑");
		}).map(String);
	  let recoveredRequired = foundationIds.filter((id) => id !== restoredDirect);
	  const generatedSupportIds = new Set([
		...Object.values(applicationSupportBySector).flat(),
		...Object.values(primitiveApplicationSupport),
	  ]);
	  if (!Array.isArray(application.application_foundation_ids) &&
		  recoveredRequired.length === 1 && generatedSupportIds.has(recoveredRequired[0])) {
		recoveredRequired = [];
	  }
      required = applicationId === "tech.application.knapping_workshop" ? [] :
        (headRequired.length > 0 ? headRequired :
		  recoveredRequired);
    }
    if (direct.length !== 1) throw new Error(`${fileName}: expected exactly one direct technology`);
    buildings.push({
      fileName,
      filePath,
      text,
      id,
      displayName: scalar(text, "display_name", id),
      sector: scalar(text, "economic_sector_id", "manufacturing"),
      direct: direct[0],
      required,
      constructionGoods: packedStrings(text, "construction_good_ids"),
      constructionQuantities: packedIntegers(text, "construction_quantities"),
	  constructionCandidateOffsets: packedIntegers(text, "construction_candidate_offsets"),
	  constructionCandidateGoods: packedStrings(text, "construction_candidate_good_ids"),
      inputGoods: packedStrings(text, "input_good_ids"),
	  inputRequiredQ16: packedIntegers(text, "input_required_q16"),
	  inputCandidateOffsets: packedIntegers(text, "input_candidate_offsets"),
	  inputCandidateGoods: packedStrings(text, "input_candidate_good_ids"),
      outputGoods: packedStrings(text, "output_good_ids"),
      resourceIds: packedStrings(text, "resource_ids"),
    });
  }

  const goods = [];
  for (const fileName of fs.readdirSync(GOODS_DIR).filter((name) => name.endsWith(".tres")).sort()) {
    const filePath = path.join(GOODS_DIR, fileName);
    const text = fs.readFileSync(filePath, "utf8");
    const headText = readHeadGood(fileName);
    const currentTechnologyTags = packedStrings(text, "technology_tags")
      .filter((tag) => tag.startsWith("tech."));
    const headTechnologyTags = packedStrings(headText, "technology_tags")
      .filter((tag) => tag.startsWith("tech."));
    goods.push({
      fileName,
      filePath,
      text,
      id: scalar(text, "id", path.parse(fileName).name),
      displayName: scalar(text, "display_name", path.parse(fileName).name),
      technologyTags: headTechnologyTags.length > 0 ? headTechnologyTags : currentTechnologyTags,
    });
  }
	const resourceTechnologyTags = new Map();
	for (const fileName of fs.readdirSync(RESOURCES_DIR)
		.filter((name) => name.endsWith(".tres")).sort()) {
	  const text = fs.readFileSync(path.join(RESOURCES_DIR, fileName), "utf8");
	  const resourceId = scalar(text, "id", path.parse(fileName).name);
	  resourceTechnologyTags.set(resourceId,
		packedStrings(text, "discovery_technology_tags").filter((tag) => tag.startsWith("tech.")));
	}

  // Rebuild the visible binding index from the building profiles below. This
  // removes stale bindings left by older generated application nodes and
  // guarantees that a building cannot remain unlocked by its former source.
  for (const node of nodes) {
    for (const building of buildings) removeBuildingBinding(node, building.id);
    for (const good of goods) removeGoodBinding(node, good.id);
  }

  // Add one universal early knowledge institution before the remaining stone
  // branches. The five regional practice technologies stay as later branches.
  const oral = nodeById.get("tech.oral_memory_practice");
  if (!oral) throw new Error("missing tech.oral_memory_practice");
  const unified = clone(oral);
  unified.id = "tech.early_knowledge_institution";
  unified.display_name = "早期知识机构";
  unified.layout_order = 1.5;
  unified.network_role = "backbone";
  unified.anchor_kind = "backbone";
  unified.node_role = "institution";
  unified.branch_family_id = oral.branch_family_id || "branch.knowledge";
  unified.secondary_route_tags = ["route.institution.knowledge", "route.geography.coast"];
  unified.hard_prerequisite_ids = [];
  unified.prerequisite_rationales = [];
  unified.is_milestone = false;
  unified.is_era_key = false;
  unified.is_starting = false;
  unified.is_starter_eligible = false;
  unified.starter_capability_tags = [];
  unified.research_routes = [
    signalRoute("research_route.early_knowledge_institution.coast", "海岸观察", "geography",
      "观察潮汐、海岸线与潮间带资源后形成稳定的记录场所。", ["landform.coast", "landform.coastal_estuary"]),
    signalRoute("research_route.early_knowledge_institution.floodplain", "洪泛记录", "climate",
      "反复经历洪水或居住在洪泛平原后，需要保存季节与水位知识。", ["landform.floodplain", "weather.major_flood"]),
    signalRoute("research_route.early_knowledge_institution.pasture", "牧场与草原观察", "animal",
      "牧场或草原上的迁徙、放牧和水源经验促成稳定的知识传承。", ["resource.pasture", "landform.grassland", "landform.steppe_plain"]),
    signalRoute("research_route.early_knowledge_institution.forest", "森林物候观察", "ecology",
      "森林中的季节物候和可食资源需要被持续记录。", ["landform.forest", "landform.conifer_forest"]),
    signalRoute("research_route.early_knowledge_institution.survival", "一般生存观察", "institution",
      "对野味、肥沃土壤、木材或河湖的持续观察也能推动知识机构出现。", ["resource.wild_game", "resource.fertile_soil", "resource.timber", "landform.freshwater_access"]),
  ];
  unified.route_exemption_reason = "";
  unified.reveal_condition = {};
  unified.reveal_category = "environment_observation";
  unified.reveal_summary = "出生地的生存观察信号揭示统一的早期知识机构";
  setHardPrerequisites(unified, ["tech.gathering"],
    "稳定记录与传承生存观察，需要先形成基础采集共同体");
  unified.expected_bindings = [{ kind: 1, id: "technology_points" }, { kind: 2, id: "early_knowledge_institution" }];
  unified.content_effects = [
    {
      kind: "good", id: "technology_points", binding_kind: 1,
      subject: "good.technology_points", attribute: "production_access",
      operation: "unlock", value: 1, implementation: "GoodProfile.technology_tags",
      status: "catalog_rebind", display_name: "科技值",
    },
    bindingEffect("early_knowledge_institution", "早期知识机构"),
  ];
  unified.effect_summary = "解锁物资：科技值；解锁建筑：早期知识机构";
  unified.opportunity_cost = "统一知识机构占用早期建材与劳动力，但为后续区域知识分支提供入口。";
  unified.terminal_reason = "统一早期知识机构是五个区域知识分支的共同起点。";

  for (const regionalId of [
    "tech.oral_memory_practice", "tech.phenology_observation",
    "tech.flood_calendar_practice", "tech.pastoral_route_memory", "tech.tide_observation",
  ]) {
    const regional = nodeById.get(regionalId);
    if (!regional) throw new Error(`missing regional knowledge node ${regionalId}`);
    setHardPrerequisites(regional, ["tech.early_knowledge_institution"],
      "统一早期知识机构是区域知识实践的共同入口");
    regional.expected_bindings = [];
    regional.content_effects = [];
    regional.effect_summary = "区域知识分支：完成统一早期知识机构后，可继续深化本地观察传统";
  }
  for (const node of nodes) {
    if (String(node.era_id) !== "stone") continue;
    for (const route of node.research_routes || []) {
      if (!String(route.id || "").endsWith(".knowledge_institution")) continue;
      route.display_name = "统一知识机构传承";
      route.description = "完成早期知识机构后，由稳定的记录与传承制度支持该研究。";
      route.condition = { operator: 0, kind: 0, id: "tech.early_knowledge_institution", value: 1 };
    }
  }

  // Fishing boats is an agrarian application. Coastal and freshwater fishing
  // remain stone-age alternatives, but both require the institution first.
  const coastal = nodeById.get("tech.coastal_fishing");
  const freshwater = nodeById.get("tech.freshwater_fishing");
  const fishingBoats = nodeById.get("tech.fishing_boats");
  if (!coastal || !freshwater || !fishingBoats) throw new Error("missing fishing technology");
  for (const [node, rationale, routes] of [
    [coastal, "潮间带采集必须建立在统一知识机构的潮汐与沿岸记录能力之上。", [
      signalRoute("research_route.coastal_fishing.coast", "海岸证据", "geography",
        "观察海岸、河口或海洋鱼类资源。", ["landform.coast", "landform.coastal_estuary", "resource.marine_fish"]),
    ]],
    [freshwater, "淡水岸捕必须建立在统一知识机构的水文记录能力之上。", [
      signalRoute("research_route.freshwater_fishing.freshwater", "淡水证据", "geography",
        "观察河湖水系或淡水鱼群资源。", ["landform.freshwater_access", "resource.freshwater_fish"]),
    ]],
  ]) {
    setHardPrerequisites(node, ["tech.early_knowledge_institution"], rationale);
    node.research_routes = routes;
    node.route_exemption_reason = "";
  }
  fishingBoats.era_id = "agrarian";
  fishingBoats.research_routes = [
    technologyRoute("research_route.fishing_boats.coastal_fishing", "沿岸捕鱼经验", "geography",
      "完成潮间带采集后，可以把近岸捕捞经验转化为船体与航行工艺。", ["tech.coastal_fishing"]),
    technologyRoute("research_route.fishing_boats.freshwater_fishing", "淡水捕鱼经验", "ecology",
      "完成淡水岸捕后，可以把水上作业经验转化为渔舟。", ["tech.freshwater_fishing"]),
  ];
  fishingBoats.route_exemption_reason = "";

  // Material recognition cannot substitute for the craft being composed.
  // Composite tools are downstream of actual knapping, while controlled
  // burning is downstream of retaining and managing fire.
  setHardPrerequisites(nodeById.get("tech.stone_knapping"),
    ["tech.flint_identification"], "打制石器需要先辨识可剥片的燧石");
  setHardPrerequisites(nodeById.get("tech.ground_stone_tools"),
    ["tech.stone_knapping"], "磨制石器建立在打制石器的成形经验上");
  setHardPrerequisites(nodeById.get("tech.composite_tools"),
    ["tech.stone_knapping"], "复合工具必须先掌握可实际制造的打制石器");
  setHardPrerequisites(nodeById.get("tech.controlled_burning"),
    ["tech.fire_control"], "控制性用火必须先掌握火种控制");
  setHardPrerequisites(nodeById.get("tech.turf_cutting"),
    ["tech.stone_knapping"], "草皮切割需要可制造的石刃工具");
  setHardPrerequisites(nodeById.get("tech.brine_collection"),
    ["tech.gathering"], "卤水采集建立在基础采集组织之上");

  // Technologies that previously relied only on contextual research routes
  // still need an indispensable, visible knowledge foundation.  These are
  // semantic craft/institution dependencies, not era-capacity supports.
  const requiredKnowledgeFoundations = new Map([
    ["tech.fire_control", ["tech.deadwood_collection"]],
    ["tech.weights_and_measures", ["tech.writing"]],
    ["tech.urban_food_supply", ["tech.public_storehouses", "tech.estate_accounting"]],
    ["tech.deep_mining", ["tech.mine_timbering", "tech.mine_ventilation"]],
    ["tech.mass_production", ["tech.factory_system", "tech.interchangeable_parts"]],
    ["tech.corporate_management", ["tech.double_entry_bookkeeping", "tech.industrial_statistics"]],
    ["tech.industrial_quality_control", ["tech.industrial_statistics", "tech.industrial_research"]],
    ["tech.corporate_agribusiness", ["tech.global_logistics", "tech.corporate_management"]],
    ["tech.nuclear_fuel_cycle", ["tech.industrial_chemistry", "tech.national_laboratories", "tech.specialty_alloys"]],
    ["tech.automated_logistics", ["tech.global_logistics", "tech.software_engineering", "tech.semiconductor_manufacturing"]],
    ["tech.human_machine_collaboration", ["tech.platform_coordination", "tech.machine_learning"]],
    ["tech.robotic_manufacturing", ["tech.electronic_control", "tech.advanced_metallurgy", "tech.human_machine_collaboration"]],
    ["tech.autonomous_mining", ["tech.sensor_networks", "tech.robotic_manufacturing"]],
    ["tech.intelligent_breeding", ["tech.biotechnology", "tech.distributed_intelligence"]],
    ["tech.algorithmic_management", ["tech.operations_research", "tech.networked_computing", "tech.machine_learning"]],
    ["tech.adaptive_irrigation", ["tech.intelligent_breeding", "tech.autonomous_logistics", "tech.algorithmic_management"]],
  ]);
  for (const [technologyId, prerequisiteIds] of requiredKnowledgeFoundations) {
    const node = nodeById.get(technologyId);
    if (!node) throw new Error(`missing knowledge-foundation technology ${technologyId}`);
    setHardPrerequisites(node, prerequisiteIds,
      "该工艺或制度必须建立在所列基础知识已经实际掌握之上");
  }

  // Copper identification, working, annealing, tin identification and ore
  // roasting all move out of stone age. Their direct building bindings are
  // re-evaluated below, with explicit applications for mining and bronze work.
  for (const id of [
    "tech.natural_copper_identification", "tech.natural_copper_working",
    "tech.copper_annealing", "tech.tin_identification", "tech.copper_ore_roasting",
  ]) {
    const node = nodeById.get(id);
    if (!node) throw new Error(`missing copper technology ${id}`);
    node.era_id = "agrarian";
  }
  setHardPrerequisites(nodeById.get("tech.natural_copper_identification"), [], "自然铜辨识观察矿物证据");
  setHardPrerequisites(nodeById.get("tech.natural_copper_working"),
    ["tech.natural_copper_identification", "tech.stone_knapping"], "自然铜冷锤需要矿物辨识与石器锤击");
  setHardPrerequisites(nodeById.get("tech.copper_annealing"),
    ["tech.natural_copper_working"], "铜退火需要自然铜冷锤工艺");
  setHardPrerequisites(nodeById.get("tech.tin_identification"),
    ["tech.copper_annealing", "tech.stone_knapping"], "锡矿辨识需要退火经验与石器取样");
  setHardPrerequisites(nodeById.get("tech.copper_ore_roasting"),
    ["tech.copper_annealing", "tech.ground_stone_tools"], "铜矿焙烧需要退火经验与磨制工具");
  const copperMetallurgy = nodeById.get("tech.copper_metallurgy");
  setHardPrerequisites(copperMetallurgy,
    ["tech.natural_copper_working", "tech.copper_ore_roasting", "tech.charcoal_burning", "tech.pottery"],
    "木炭坩埚炼铜汇合自然铜、焙烧、木炭与陶器工艺");
  copperMetallurgy.expected_bindings = (copperMetallurgy.expected_bindings || []).filter((binding) =>
    !(Number(binding.kind) === 2 && String(binding.id) === "early_tin_mine"));
  copperMetallurgy.content_effects = (copperMetallurgy.content_effects || []).filter((effect) =>
    !(String(effect.kind) === "building" && String(effect.id) === "early_tin_mine"));
  copperMetallurgy.effect_summary = "解锁物资：铜；解锁建筑：土法炼铜炉；铜矿采掘产出 +12%";

  const removeIds = [
    "tech.early_knowledge_institution", "tech.fishing_boats",
    "tech.natural_copper_identification", "tech.natural_copper_working",
    "tech.copper_annealing", "tech.tin_identification", "tech.copper_ore_roasting",
  ];
  const moved = new Map(removeIds.map((id) => [id, nodeById.get(id)]));
  const retained = nodes.filter((node) => !removeIds.includes(String(node.id)));
  const milestoneIndex = retained.findIndex((node) => String(node.id) === "tech.settled_knowledge");
  if (milestoneIndex < 0) throw new Error("missing stone milestone");
  retained.splice(milestoneIndex + 1, 0,
    moved.get("tech.natural_copper_identification"),
    moved.get("tech.natural_copper_working"), moved.get("tech.copper_annealing"),
    moved.get("tech.tin_identification"), moved.get("tech.copper_ore_roasting"),
    moved.get("tech.fishing_boats"));
  const gatheringIndex = retained.findIndex((node) => String(node.id) === "tech.gathering");
  if (gatheringIndex < 0) throw new Error("missing gathering node");
  retained.splice(gatheringIndex + 1, 0, unified);

  const refreshedById = new Map(retained.map((node) => [String(node.id), node]));
	const dependencyGoodGroups = (building) => {
	  const groups = [];
	  for (let index = 0; index < building.constructionGoods.length; index += 1) {
		const begin = Number(building.constructionCandidateOffsets[index] || 0);
		const end = Number(building.constructionCandidateOffsets[index + 1] || 0);
		groups.push(end > begin
		  ? building.constructionCandidateGoods.slice(begin, end)
		  : [building.constructionGoods[index]]);
	  }
	  for (let index = 0; index < building.inputGoods.length; index += 1) {
		const requiredQ16 = building.inputRequiredQ16.length > 0
		  ? Number(building.inputRequiredQ16[index] || 0) : 65536;
		if (requiredQ16 <= 0) continue;
		const begin = Number(building.inputCandidateOffsets[index] || 0);
		const end = Number(building.inputCandidateOffsets[index + 1] || 0);
		groups.push(end > begin
		  ? building.inputCandidateGoods.slice(begin, end)
		  : [building.inputGoods[index]]);
	  }
	  return groups.filter((group) => group.length > 0);
	};
  const earliestBuildingEra = new Map();
  const plannedBuildingEra = new Map();
	const buildingScheduleOrder = new Map();
  const unassignedBuildings = new Set();
  for (const building of buildings) {
    const source = refreshedById.get(building.direct);
    if (!source) throw new Error(`${building.fileName}: direct technology missing ${building.direct}`);
    var earliestIndex = eraIndex.get(String(source.era_id));
    for (const requiredId of building.required) {
      const requiredNode = refreshedById.get(requiredId);
      if (requiredNode) earliestIndex = Math.max(earliestIndex,
        eraIndex.get(String(requiredNode.era_id)));
    }
	for (const resourceId of building.resourceIds) {
	  const candidates = (resourceTechnologyTags.get(resourceId) || [])
		.map((id) => refreshedById.get(id)).filter(Boolean);
	  if (candidates.length === 0) {
		throw new Error(`${building.id}: resource recognition technology missing for ${resourceId}`);
	  }
	  earliestIndex = Math.max(earliestIndex, Math.min(...candidates.map((node) =>
		eraIndex.get(String(node.era_id)))));
	}
    if (!stoneWhitelist.has(building.id)) earliestIndex = Math.max(earliestIndex, 1);
    if (minimumBuildingEra.has(building.id)) earliestIndex = Math.max(earliestIndex,
      eraIndex.get(minimumBuildingEra.get(building.id)));
    earliestBuildingEra.set(building.id, earliestIndex);
    if (stoneWhitelist.has(building.id)) {
      plannedBuildingEra.set(building.id, "stone");
    } else {
      unassignedBuildings.add(building.id);
    }
  }
  if ([...plannedBuildingEra.values()].filter((id) => id === "stone").length !==
      eraBuildingTargets.get("stone")) {
    throw new Error("stone building whitelist does not match its era target");
  }
  const buildingById = new Map(buildings.map((building) => [building.id, building]));
	for (const buildingId of stoneWhitelist) {
	  buildingScheduleOrder.set(buildingId, buildingScheduleOrder.size);
	}
  const availableProductionGoods = new Set();
	for (const buildingId of stoneWhitelist) {
	  const building = buildingById.get(buildingId);
	  if (!building) throw new Error(`stone whitelist building missing: ${buildingId}`);
	  for (const goodId of building.outputGoods) availableProductionGoods.add(goodId);
	}
	const dependenciesAvailable = (building) => dependencyGoodGroups(building)
	  .every((group) => group.some((goodId) => availableProductionGoods.has(goodId)));
  for (let targetEraIndex = 1; targetEraIndex < payload.eras.length; targetEraIndex += 1) {
    const targetEraId = String(payload.eras[targetEraIndex].id);
    const targetCount = eraBuildingTargets.get(targetEraId);
	for (let slot = 0; slot < targetCount; slot += 1) {
	  const candidates = [...unassignedBuildings]
		.filter((id) => earliestBuildingEra.get(id) <= targetEraIndex &&
		  dependenciesAvailable(buildingById.get(id)))
		.sort((a, b) => {
		  const aPreferred = preferredBuildingEra.get(a) === targetEraId ? 0 : 1;
		  const bPreferred = preferredBuildingEra.get(b) === targetEraId ? 0 : 1;
		  if (aPreferred !== bPreferred) return aPreferred - bPreferred;
		  const earliestDelta = earliestBuildingEra.get(a) - earliestBuildingEra.get(b);
		  if (earliestDelta !== 0) return earliestDelta;
		  const aBuilding = buildingById.get(a);
		  const bBuilding = buildingById.get(b);
		  const aSource = refreshedById.get(aBuilding.direct);
		  const bSource = refreshedById.get(bBuilding.direct);
		  const layoutDelta = Number(aSource.layout_order || 0) -
			Number(bSource.layout_order || 0);
		  if (layoutDelta !== 0) return layoutDelta;
		  const sourceDelta = String(aSource.id).localeCompare(String(bSource.id));
		  return sourceDelta !== 0 ? sourceDelta : a.localeCompare(b);
		});
	  if (candidates.length === 0) {
		const blocked = [...unassignedBuildings]
		  .filter((id) => earliestBuildingEra.get(id) <= targetEraIndex)
		  .slice(0, 12).map((id) => {
			const building = buildingById.get(id);
			const missing = dependencyGoodGroups(building)
			  .filter((group) => !group.some((goodId) => availableProductionGoods.has(goodId)));
			return `${id}:${JSON.stringify(missing)}`;
		  });
		throw new Error(`${targetEraId}: supply-closed building slot ${slot + 1}/${targetCount} unavailable; ${blocked.join(",")}`);
	  }
	  const buildingId = candidates[0];
	  plannedBuildingEra.set(buildingId, targetEraId);
	  buildingScheduleOrder.set(buildingId, buildingScheduleOrder.size);
	  unassignedBuildings.delete(buildingId);
	  for (const goodId of buildingById.get(buildingId).outputGoods) {
		availableProductionGoods.add(goodId);
	  }
	}
  }
  if (unassignedBuildings.size !== 0 || plannedBuildingEra.size !== buildings.length) {
    throw new Error(`building era allocation incomplete: ${[...unassignedBuildings].join(",")}`);
  }

  const directGroups = new Map();
  for (const building of buildings) {
    if (!directGroups.has(building.direct)) directGroups.set(building.direct, []);
    directGroups.get(building.direct).push(building);
  }
  const requiredSets = new Map();
  for (const [direct, group] of directGroups) {
    requiredSets.set(direct, new Set(group.map((building) => JSON.stringify([...building.required].sort()))));
  }
  const appNodes = [];
  const appAssignments = new Map();
  const specialApplicationIds = new Map([
    ["copper_ore_collector", "tech.copper_mining_application"],
    ["early_tin_mine", "tech.application.early_tin_mine"],
    ["early_copper_mine", "tech.application.early_copper_mine"],
    ["ore_bronzesmith_camp", "tech.application.ore_bronzesmith_camp"],
  ]);
  const keepDirect = new Set(["early_copper_smelter"]);

  for (const building of buildings) {
    const source = refreshedById.get(building.direct);
    if (!source) throw new Error(`${building.fileName}: direct technology missing ${building.direct}`);
	let sourceEraIndex = eraIndex.get(String(source.era_id));
    const targetEraId = plannedBuildingEra.get(building.id);
    const targetEraIndex = eraIndex.get(targetEraId);
	const isVisibleMethodTechnology = String(building.direct).startsWith("tech.method.");
	if ((keepDirect.has(building.id) || isVisibleMethodTechnology) &&
		targetEraIndex > sourceEraIndex) {
	  source.era_id = targetEraId;
	  sourceEraIndex = targetEraIndex;
	}
    const hasConflict = requiredSets.get(building.direct).size > 1;
    const mustMoveStoneBuilding = source.era_id === "stone" && !stoneWhitelist.has(building.id);
    const mustDelayBuilding = targetEraIndex > sourceEraIndex;
	const needsExplicitApplication = !keepDirect.has(building.id) &&
	  !isVisibleMethodTechnology &&
      !stoneWhitelist.has(building.id) && (
        building.id === "copper_ore_collector" ||
        building.id === "early_tin_mine" ||
        building.id === "early_copper_mine" ||
        building.id === "ore_bronzesmith_camp" ||
        hasConflict || mustMoveStoneBuilding || mustDelayBuilding);
    if (needsExplicitApplication) {
      const applicationId = specialApplicationIds.get(building.id) ||
        `tech.application.${building.id}`;
      const prerequisiteIds = [building.direct, ...building.required];
      const prerequisiteEra = Math.max(sourceEraIndex,
        ...building.required.map((id) => eraIndex.get(String(refreshedById.get(id)?.era_id || "stone"))));
      const eraId = payload.eras[Math.max(prerequisiteEra, targetEraIndex)].id;
      removeBuildingBinding(source, building.id);
      const application = makeApplicationNode(source, building, applicationId,
        prerequisiteIds, eraId);
      if (building.id === "copper_ore_collector") {
		setHardPrerequisites(application,
		  ["tech.natural_copper_identification", "tech.stone_knapping"],
		  "铜矿开采必须汇合自然铜辨识与可实际制造的打制石器");
        application.display_name = "铜矿开采";
        application.effect_summary = "解锁建筑：铜矿；要求自然铜辨识与打制石器";
        application.opportunity_cost = "自然铜辨识与打制石器汇合后，才能把矿物观察转化为铜矿开采。";
      } else if (building.id === "early_copper_mine") {
        setHardPrerequisites(application,
          ["tech.copper_metallurgy", "tech.mine_timbering"],
          "浅层铜矿需要铜冶金与矿井木支护");
      } else if (building.id === "early_tin_mine") {
        setHardPrerequisites(application,
          ["tech.copper_metallurgy", "tech.bronze_casting"],
          "浅层锡矿需要铜冶金与青铜铸造");
      } else if (building.id === "ore_bronzesmith_camp") {
        setHardPrerequisites(application,
          ["tech.copper_annealing", "tech.bronze_casting", "tech.tin_identification"],
          "露天青铜作坊需要退火、青铜铸造与锡矿辨识");
	  } else if (building.id === "iron_tool_workshop") {
		setHardPrerequisites(application, ["tech.iron_smelting"],
		  "铁制工具工坊必须先掌握铁冶炼，块炼铁与燃料供应由配方闭包补齐");
      }
	  application.application_foundation_ids = [
		...new Set(application.hard_prerequisite_ids.map(String)),
	  ];
      appNodes.push(application);
      appAssignments.set(building.id, applicationId);
    } else {
      // A direct technology may be reused only when every building on that
      // direct axis shares the same required set. This makes the hard gate
      // visible on the technology itself and never on the building profile.
      const group = directGroups.get(building.direct);
      const sameSet = !hasConflict;
      if (sameSet && building.required.length > 0) {
        for (const requiredId of building.required) {
          if (!source.hard_prerequisite_ids.includes(requiredId)) {
            source.hard_prerequisite_ids.push(requiredId);
            source.prerequisite_rationales.push(
              `该直接科技下的建筑共同要求前置：${requiredId}。`);
          }
        }
      }
      if (keepDirect.has(building.id)) {
        // The copper furnace is the sole direct metallurgy building. Its
        // requirements are authored explicitly on tech.copper_metallurgy.
        source.hard_prerequisite_ids = [
          "tech.natural_copper_working", "tech.copper_ore_roasting",
          "tech.charcoal_burning", "tech.pottery",
        ];
        source.prerequisite_rationales = source.hard_prerequisite_ids.map((id) =>
          `土法炼铜炉吸收原有工艺前置：${id}。`);
      }
    }
  }

  // Rebind every building profile to exactly one direct tech and clear the old
  // hidden multi-tech field.
  for (const building of buildings) {
    const targetTech = appAssignments.get(building.id) || building.direct;
    let sourceText = building.text;
    if (building.constructionGoods.some((goodId) => building.outputGoods.includes(goodId))) {
      const replacementGoods = building.constructionGoods.map((goodId) =>
        building.outputGoods.includes(goodId) ? "logs" : goodId);
      sourceText = rewritePackedStrings(sourceText, "construction_good_ids", replacementGoods);
      building.constructionGoods = replacementGoods;
    }
    let text = rewritePackedStrings(sourceText, "technology_tags", [
      ...packedStrings(building.text, "technology_tags").filter((tag) => !tag.startsWith("tech.")),
      targetTech,
    ]);
    text = rewritePackedStrings(text, "required_technology_tags", []);
    fs.writeFileSync(building.filePath, text, "utf8");
  }

  // Ensure the unified institution directly owns the newly authored building;
  // no regional knowledge node retains an institution binding.
  refreshedById.set(unified.id, unified);
  retained.push(...appNodes);
  const knownIds = new Set(retained.map((node) => String(node.id)));
  payload.visual_edges = (payload.visual_edges || []).filter((edge) =>
    knownIds.has(String(edge.from || "")) && knownIds.has(String(edge.to || "")) &&
    String(edge.kind || "") !== "hard");
  const visualKeys = new Set(payload.visual_edges.map((edge) =>
    `${edge.from}>${edge.to}>${edge.kind}`));
  const addHardVisualEdge = (from, to) => {
    const key = `${from}>${to}>hard`;
    if (visualKeys.has(key)) return;
    payload.visual_edges.push({ from, to, kind: "hard" });
    visualKeys.add(key);
  };
  for (const regionalId of [
    "tech.oral_memory_practice", "tech.phenology_observation",
    "tech.flood_calendar_practice", "tech.pastoral_route_memory", "tech.tide_observation",
  ]) addHardVisualEdge("tech.early_knowledge_institution", regionalId);
  for (const node of appNodes) {
    for (const prerequisite of node.hard_prerequisite_ids) addHardVisualEdge(prerequisite, node.id);
  }
  // Keep the application layer visually distinct from ordinary branch edges.
  for (const node of appNodes) {
    node.network_role = "branch";
  }
  const nodeByRetainedId = new Map(retained.map((node) => [String(node.id), node]));
	const collectHardAncestry = (technologyId, output = new Set()) => {
	  if (!nodeByRetainedId.has(technologyId) || output.has(technologyId)) return output;
	  output.add(technologyId);
	  for (const prerequisite of nodeByRetainedId.get(technologyId).hard_prerequisite_ids || []) {
		collectHardAncestry(String(prerequisite), output);
	  }
	  return output;
	};
	const targetTechnologyForBuilding = (building) =>
	  appAssignments.get(building.id) || building.direct;

	// Every unlock package, application or ordinary, must include executable
	// construction and input supply.  Producer technologies are selected from
	// the actual recipe and may never point to a later era or back to a
	// dependent package.
	const unresolvedDependencies = [];
	for (const building of buildings) {
	  const targetTechnologyId = targetTechnologyForBuilding(building);
	  const targetNode = nodeByRetainedId.get(targetTechnologyId);
	  if (!targetNode) throw new Error(`${building.id}: target technology missing`);
	  if (Boolean(targetNode.is_starter_eligible)) continue;
	  for (const dependencyGroup of dependencyGoodGroups(building)) {
		let ancestry = collectHardAncestry(targetTechnologyId, new Set());
		const producers = buildings.filter((producer) => producer.id !== building.id &&
		  producer.outputGoods.some((goodId) => dependencyGroup.includes(goodId)))
		  .map((producer) => {
			const technologyId = targetTechnologyForBuilding(producer);
			const node = nodeByRetainedId.get(technologyId);
			return { producer, technologyId, node };
		  });
		if (producers.some((candidate) => candidate.technologyId === targetTechnologyId ||
		  (ancestry.has(candidate.technologyId) &&
			Number(buildingScheduleOrder.get(candidate.producer.id)) <
			  Number(buildingScheduleOrder.get(building.id))))) {
		  continue;
		}
		const targetEraIndex = eraIndex.get(String(plannedBuildingEra.get(building.id)));
		const candidates = producers.filter((candidate) => candidate.node &&
		  eraIndex.get(String(plannedBuildingEra.get(candidate.producer.id))) <= targetEraIndex &&
		  Number(buildingScheduleOrder.get(candidate.producer.id)) <
			Number(buildingScheduleOrder.get(building.id)) &&
		  candidate.technologyId !== targetTechnologyId &&
		  !collectHardAncestry(candidate.technologyId, new Set()).has(targetTechnologyId))
		  .sort((a, b) => eraIndex.get(String(plannedBuildingEra.get(a.producer.id))) -
			eraIndex.get(String(plannedBuildingEra.get(b.producer.id))) ||
			Number(buildingScheduleOrder.get(a.producer.id)) -
			Number(buildingScheduleOrder.get(b.producer.id)) ||
			a.producer.id.localeCompare(b.producer.id));
		if (candidates.length === 0) {
		  unresolvedDependencies.push(`${targetTechnologyId}/${building.id}/${dependencyGroup.join("|")}`);
		  continue;
		}
		const selected = candidates[0];
		if (!targetNode.hard_prerequisite_ids.includes(selected.technologyId)) {
		  targetNode.hard_prerequisite_ids.push(selected.technologyId);
		  targetNode.prerequisite_rationales.push(
			`建筑${building.id}需要${dependencyGroup.join("或")}，其可运行生产方法由${selected.technologyId}提供。`);
		}
	  }
	  for (const resourceId of building.resourceIds) {
		let ancestry = collectHardAncestry(targetTechnologyId, new Set());
		const recognitionIds = resourceTechnologyTags.get(resourceId) || [];
		if (recognitionIds.some((id) => ancestry.has(id) || id === targetTechnologyId)) continue;
		const candidates = recognitionIds.map((technologyId) => ({
		  technologyId, node: nodeByRetainedId.get(technologyId),
		})).filter((candidate) => candidate.node &&
		  eraIndex.get(String(candidate.node.era_id)) <= eraIndex.get(String(targetNode.era_id)) &&
		  !collectHardAncestry(candidate.technologyId, new Set()).has(targetTechnologyId))
		  .sort((a, b) => eraIndex.get(String(a.node.era_id)) -
			eraIndex.get(String(b.node.era_id)) ||
			Number(a.node.layout_order || 0) - Number(b.node.layout_order || 0) ||
			a.technologyId.localeCompare(b.technologyId));
		if (candidates.length === 0) {
		  unresolvedDependencies.push(`${targetTechnologyId}/${building.id}/resource:${resourceId}`);
		  continue;
		}
		const selected = candidates[0];
		if (!targetNode.hard_prerequisite_ids.includes(selected.technologyId)) {
		  targetNode.hard_prerequisite_ids.push(selected.technologyId);
		  targetNode.prerequisite_rationales.push(
			`建筑${building.id}利用资源${resourceId}，必须先由${selected.technologyId}完成辨识。`);
		}
	  }
	}
	if (unresolvedDependencies.length > 0) {
	  throw new Error(`building supply dependencies unresolved: ${unresolvedDependencies.join(",")}`);
	}
	const unresolvedApplications = appNodes.filter((application) =>
	  new Set(application.hard_prerequisite_ids || []).size < 2);
	if (unresolvedApplications.length > 0) {
	  const convertedIds = new Map();
	  for (const node of unresolvedApplications) {
		const oldId = String(node.id);
		const building = buildings.find((candidate) =>
		  targetTechnologyForBuilding(candidate) === oldId);
		if (!building) throw new Error(`${oldId}: single-foundation building missing`);
		const methodId = `tech.method.${building.id}`;
		if (nodeByRetainedId.has(methodId)) throw new Error(`${methodId}: duplicate method technology`);
		convertedIds.set(oldId, methodId);
		node.id = methodId;
		node.display_name = `方法：${building.displayName}`;
		node.anchor_kind = "backbone";
		node.network_role = "branch";
		node.node_role = "applied_method";
		node.route_exemption_reason = "该基础方法的不可替代知识由唯一可见硬前置完整表达。";
		node.reveal_category = "method_progression";
		node.reveal_summary = "完成基础工艺后揭示这一具体生产方法";
		node.application_foundation_ids = [];
		appAssignments.set(building.id, methodId);
		nodeByRetainedId.delete(oldId);
		nodeByRetainedId.set(methodId, node);
		knownIds.delete(oldId);
		knownIds.add(methodId);
	  }
	  for (const node of retained) {
		node.hard_prerequisite_ids = (node.hard_prerequisite_ids || [])
		  .map((id) => convertedIds.get(String(id)) || String(id));
		node.branch_successor_ids = (node.branch_successor_ids || [])
		  .map((id) => convertedIds.get(String(id)) || String(id));
	  }
	  for (const edge of payload.visual_edges) {
		edge.from = convertedIds.get(String(edge.from || "")) || edge.from;
		edge.to = convertedIds.get(String(edge.to || "")) || edge.to;
	  }
	  visualKeys.clear();
	  for (const edge of payload.visual_edges) {
		visualKeys.add(`${edge.from}>${edge.to}>${edge.kind}`);
	  }
	  for (const building of buildings) {
		if (!appAssignments.has(building.id)) continue;
		const targetTechnologyId = appAssignments.get(building.id);
		if (!String(targetTechnologyId).startsWith("tech.method.")) continue;
		let text = fs.readFileSync(building.filePath, "utf8");
		text = rewritePackedStrings(text, "technology_tags", [
		  ...packedStrings(text, "technology_tags").filter((tag) => !tag.startsWith("tech.")),
		  targetTechnologyId,
		]);
		fs.writeFileSync(building.filePath, text, "utf8");
	  }
	}

  // A Good technology tag is a production permit. Rebind every authored tag
  // to a technology that directly unlocks a real producer; the underlying
  // scientific or craft principle remains visible as that producer's hard
  // foundation instead of exposing demand before supply exists.
  for (const node of retained) {
    for (const good of goods) removeGoodBinding(node, good.id);
  }
  for (const good of goods) {
    const producers = buildings.filter((building) => building.outputGoods.includes(good.id));
    if (producers.length === 0) throw new Error(`${good.id}: no production building`);
    const reboundTags = [];
    for (const authoredTag of good.technologyTags) {
      const authoredNode = nodeByRetainedId.get(authoredTag);
      if (!authoredNode) throw new Error(`${good.id}: unknown authored technology ${authoredTag}`);
      const authoredEra = eraIndex.get(String(authoredNode.era_id));
      const ranked = producers.map((building) => {
        const targetId = targetTechnologyForBuilding(building);
        const targetNode = nodeByRetainedId.get(targetId);
        const ancestry = collectHardAncestry(targetId, new Set());
        return {
          building,
          targetId,
          targetNode,
          supported: ancestry.has(authoredTag) ? 0 : 1,
          era: eraIndex.get(String(targetNode.era_id)),
        };
      }).filter((candidate) => candidate.era >= authoredEra)
        .sort((a, b) => a.supported - b.supported || a.era - b.era ||
          a.building.id.localeCompare(b.building.id));
      if (ranked.length === 0) {
        // A late technology that only improves or consumes an established
        // good is not a production permit and must not reveal that good.
        continue;
      }
      const selected = ranked[0];
      if (selected.targetId !== authoredTag && selected.supported !== 0 &&
          !selected.targetNode.hard_prerequisite_ids.includes(authoredTag)) {
        selected.targetNode.hard_prerequisite_ids.push(authoredTag);
        selected.targetNode.prerequisite_rationales.push(
          `生产${good.displayName}必须先掌握${authoredNode.display_name}。`);
      }
      addUnique(reboundTags, selected.targetId);
    }
    if (reboundTags.length === 0) throw new Error(`${good.id}: production technology missing`);
    let text = rewritePackedStrings(good.text, "technology_tags", [
      ...packedStrings(good.text, "technology_tags").filter((tag) => !tag.startsWith("tech.")),
      ...reboundTags,
    ]);
    fs.writeFileSync(good.filePath, text, "utf8");
    for (const technologyId of reboundTags) {
      addGoodBinding(nodeByRetainedId.get(technologyId), good.id, good.displayName);
    }
  }

  for (let eraPosition = 0; eraPosition < payload.eras.length; eraPosition += 1) {
    const era = payload.eras[eraPosition];
    const eraId = String(era.id);
    const targetCount = milestoneCandidateTargets[eraPosition];
    const validExisting = (era.milestone_candidate_ids || []).filter((id) => {
      const node = nodeByRetainedId.get(String(id));
      return node && String(node.era_id) === eraId && !String(id).startsWith("tech.application.") &&
        String(id) !== "tech.copper_mining_application" && String(id) !== String(era.milestone_id);
    });
    const candidates = [...new Set(validExisting)];
    for (const node of retained) {
      if (candidates.length >= targetCount) break;
      const id = String(node.id);
      if (String(node.era_id) !== eraId || id === String(era.milestone_id) ||
          id.startsWith("tech.application.") || id === "tech.copper_mining_application" ||
          candidates.includes(id)) continue;
      candidates.push(id);
    }
    if (candidates.length < targetCount) {
      throw new Error(`${eraId}: only ${candidates.length} milestone candidates for target ${targetCount}`);
    }
    era.milestone_candidate_ids = candidates.slice(0, targetCount);
    era.candidate_required = milestoneRequiredTargets[eraPosition];
  }
  payload.visual_edges = (payload.visual_edges || []).filter((edge) =>
    String(edge.kind || "") !== "milestone_candidate");
  for (const era of payload.eras) {
    for (const candidateId of era.milestone_candidate_ids) {
      payload.visual_edges.push({
        from: String(candidateId), to: String(era.milestone_id), kind: "milestone_candidate",
      });
    }
  }
  // Re-establish a deterministic topological order after moving complete
  // unlock packages. A backward-era prerequisite is an authoring error: the
  // successor package must move with its knowledge foundation.
  for (const building of buildings) {
    const targetTech = appAssignments.get(building.id) || building.direct;
    const targetNode = nodeByRetainedId.get(targetTech);
    if (!targetNode) throw new Error(`${building.fileName}: missing target node ${targetTech}`);
    if (!(targetNode.expected_bindings || []).some((binding) =>
        Number(binding.kind) === 2 && String(binding.id) === building.id)) {
      targetNode.expected_bindings.push({ kind: 2, id: building.id });
    }
    const existingEffect = (targetNode.content_effects || []).find((effect) =>
      String(effect.kind) === "building" && String(effect.id) === building.id);
    if (!existingEffect) {
      targetNode.content_effects.push(bindingEffect(building.id, building.displayName));
    } else {
      existingEffect.display_name = building.displayName;
      existingEffect.status = "catalog_rebind";
    }
  }
  const buildingNames = new Set(buildings.map((building) => building.displayName));
  const goodNames = new Set(goods.map((good) => good.displayName));
  for (const node of retained) cleanEffectSummary(node, buildingNames, goodNames);

  for (const [eraId, targetCount] of eraBuildingTargets) {
    const actualCount = retained.reduce((count, node) => count +
      (String(node.era_id) === eraId
        ? (node.expected_bindings || []).filter((binding) => Number(binding.kind) === 2).length
        : 0), 0);
    if (actualCount !== targetCount) {
	  const actualIds = retained.filter((node) => String(node.era_id) === eraId)
		.flatMap((node) => (node.expected_bindings || [])
		  .filter((binding) => Number(binding.kind) === 2).map((binding) => String(binding.id)));
	  const plannedIds = buildings.filter((building) => plannedBuildingEra.get(building.id) === eraId)
		.map((building) => building.id);
	  throw new Error(`${eraId} building unlock count ${actualCount} != ${targetCount}; extra=${
		actualIds.filter((id) => !plannedIds.includes(id))}; missing=${
		plannedIds.filter((id) => !actualIds.includes(id))}`);
    }
  }
  const stableNodeCompare = (a, b) => {
    const aNode = nodeByRetainedId.get(a);
    const bNode = nodeByRetainedId.get(b);
    const layoutDelta = Number(aNode.layout_order || 0) - Number(bNode.layout_order || 0);
    return layoutDelta !== 0 ? layoutDelta : String(a).localeCompare(String(b));
  };
  for (const node of retained) {
    const ids = [];
    const rationales = [];
    for (let index = 0; index < (node.hard_prerequisite_ids || []).length; index += 1) {
      const prerequisite = String(node.hard_prerequisite_ids[index]);
      if (!prerequisite) {
        throw new Error(`${node.id}: empty hard prerequisite at index ${index}`);
      }
      if (prerequisite === String(node.id)) {
        throw new Error(`${node.id}: technology cannot require itself`);
      }
      if (ids.includes(prerequisite)) continue;
      if (!nodeByRetainedId.has(prerequisite)) {
        throw new Error(`${node.id}: unknown hard prerequisite ${prerequisite}`);
      }
      const prerequisiteNode = nodeByRetainedId.get(prerequisite);
      if ((eraIndex.get(String(prerequisiteNode.era_id)) ?? 0) >
          (eraIndex.get(String(node.era_id)) ?? 0)) {
        throw new Error(
          `${node.id}: prerequisite ${prerequisite} belongs to later era ` +
          `${prerequisiteNode.era_id}; move the complete successor unlock package forward`);
      }
      ids.push(prerequisite);
      rationales.push(String((node.prerequisite_rationales || [])[index] ||
        `该科技需要先完成 ${prerequisite}。`));
    }
    node.hard_prerequisite_ids = ids;
    node.prerequisite_rationales = rationales;
    const hardPrerequisites = new Set(ids);
    for (const route of node.research_routes || []) {
      route.condition = removeConditionTechnologyIds(route.condition, hardPrerequisites);
    }
    node.research_routes = (node.research_routes || []).filter((route) =>
      route.condition && typeof route.condition === "object" &&
      (route.condition.kind !== undefined || route.condition.operator !== undefined));
    if (node.research_routes.length === 0 &&
        !String(node.route_exemption_reason || "").trim()) {
      node.route_exemption_reason = "不可替代知识已经由可见硬前置完整表达。";
    }
  }
  const collectHardAncestors = (technologyId, output) => {
    if (!nodeByRetainedId.has(technologyId) || output.has(technologyId)) return;
    output.add(technologyId);
    for (const prerequisite of nodeByRetainedId.get(technologyId).hard_prerequisite_ids || []) {
      collectHardAncestors(String(prerequisite), output);
    }
  };
  for (const node of retained) {
    const nodeEra = eraIndex.get(String(node.era_id)) || 0;
    const ancestors = new Set();
    for (const prerequisite of node.hard_prerequisite_ids || []) {
      collectHardAncestors(String(prerequisite), ancestors);
    }
    const impliedSignals = new Set();
    for (const ancestorId of ancestors) {
      collectConditionSignalIds(nodeByRetainedId.get(ancestorId).reveal_condition, impliedSignals);
    }
    if (nodeEra >= 2 && Number(node.reveal_condition?.kind) === 1 &&
        impliedSignals.has(String(node.reveal_condition.id || ""))) {
      node.reveal_condition = {};
      node.reveal_summary = "完成不可替代的核心知识前置后揭示";
    }
    node.research_routes = (node.research_routes || []).filter((route) => {
      const routeTechnologies = collectConditionTechnologyIds(route.condition);
      const routeSignals = collectConditionSignalIds(route.condition);
      const hasEvidence = routeTechnologies.size > 0 || routeSignals.size > 0;
      const fullyImplied = [...routeTechnologies].every((id) => ancestors.has(id)) &&
        [...routeSignals].every((id) => impliedSignals.has(id));
      return !hasEvidence || !fullyImplied;
    });
	if (node.research_routes.length === 0 &&
		!String(node.route_exemption_reason || "").trim()) {
	  node.route_exemption_reason = "不可替代知识已经由可见硬前置完整表达。";
	}
  }
  const validRouteIds = new Set(retained.flatMap((node) =>
    (node.research_routes || []).map((route) => String(route.id))));
  payload.visual_edges = payload.visual_edges.filter((edge) =>
    String(edge.kind || "") !== "alternative" ||
    validRouteIds.has(String(edge.route_id || "")));
  const topological = [];
  for (const era of payload.eras) {
    const eraId = String(era.id);
    const eraNodes = retained.filter((node) => String(node.era_id) === eraId);
    const remaining = new Set(eraNodes.map((node) => String(node.id)));
    while (remaining.size > 0) {
      const available = [...remaining].filter((id) => {
        const node = nodeByRetainedId.get(id);
        return (node.hard_prerequisite_ids || []).every((prerequisite) =>
          !remaining.has(String(prerequisite)));
      }).sort(stableNodeCompare);
      if (available.length === 0) {
        const blocked = [...remaining].sort(stableNodeCompare).map((id) => {
          const internalPrerequisites = (nodeByRetainedId.get(id).hard_prerequisite_ids || [])
            .map(String).filter((prerequisite) => remaining.has(prerequisite));
          return `${id}<-[${internalPrerequisites.join(",")}]`;
        });
        throw new Error(`hard prerequisite cycle in era ${eraId}: ${blocked.join("; ")}`);
      }
      for (const id of available) {
        if (id !== String(era.milestone_id)) {
          topological.push(nodeByRetainedId.get(id));
        }
        remaining.delete(id);
      }
    }
    const milestoneId = String(era.milestone_id);
    if (nodeByRetainedId.has(milestoneId)) {
      topological.push(nodeByRetainedId.get(milestoneId));
    }
  }
  payload.nodes = topological;
  for (const node of payload.nodes) {
    const alternativeGroups = String(node.id) === "tech.fishing_boats"
      ? [["tech.coastal_fishing", "tech.freshwater_fishing"]]
      : [];
    const requiredIds = [...new Set((node.hard_prerequisite_ids || []).map(String))];
    if (String(node.anchor_kind || "") === "application" && requiredIds.length < 2) {
      throw new Error(`${node.id}: application technology must have at least two knowledge foundations`);
    }
    let exemptionReason = "";
    if (requiredIds.length === 0 && alternativeGroups.length === 0) {
      if (Boolean(node.is_starter_eligible)) {
        exemptionReason = "开局生存能力不依赖更早的可研究工艺。";
      } else if (Boolean(node.is_milestone)) {
        exemptionReason = "时代里程碑由本时代候选完成数构成，不使用节点硬前置。";
      } else if (String(node.node_role || "") === "identification") {
        exemptionReason = "纯观察辨识由资源或环境证据揭示，不预设加工能力。";
      } else {
        throw new Error(`${node.id}: non-observation technology lacks a knowledge foundation`);
      }
    }
    node.knowledge_basis = {
      required_ids: requiredIds,
      alternative_groups: alternativeGroups,
      exemption_reason: exemptionReason,
    };
  }
  for (const node of payload.nodes) {
    for (const prerequisite of node.hard_prerequisite_ids || []) {
      addHardVisualEdge(String(prerequisite), String(node.id));
    }
  }

  // The authoring source is now valid JSON and self-describing; runtime code
  // should not depend on a fixed node count.
  payload.semantic_review = payload.semantic_review || {};
  payload.semantic_review.unlock_policy =
    "每项科技是不可拆分的知识-产能-时代解锁包；商品与基础生产方法同科技解锁，每个活动建筑恰好绑定一个可见 tech.*，多科技汇合使用显式 application 节点。";
  fs.writeFileSync(NETWORK_PATH, `${JSON.stringify(payload, null, "\t")}\n`, "utf8");
  console.log(`technology rebalance complete: ${payload.nodes.length} nodes, ${appNodes.length} application nodes`);
}

main();
