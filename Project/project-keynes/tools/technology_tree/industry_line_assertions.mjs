import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "../..");
const NETWORK = JSON.parse(fs.readFileSync(path.join(ROOT, "data/technology/technology_network.json"), "utf8"));
const nodes = new Map(NETWORK.nodes.map((node) => [node.id, node]));
const buildingDir = path.join(ROOT, "data/economy/buildings");
const goodDir = path.join(ROOT, "data/goods");

function text(file) { return fs.readFileSync(path.join(ROOT, file), "utf8"); }
function field(file, name) {
  const match = text(file).match(new RegExp(`^${name} = (.*)$`, "m"));
  return match?.[1] ?? "";
}
function strings(file, name) {
  return [...field(file, name).matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((match) =>
    JSON.parse(`"${match[1]}"`));
}
function ints(file, name) {
  const raw = field(file, name);
  const body = raw.slice(raw.indexOf("(") + 1, raw.lastIndexOf(")")).trim();
  return body ? body.split(",").map((value) => Number(value.trim())) : [];
}
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function node(id) {
  const value = nodes.get(id);
  assert(value, `missing technology: ${id}`);
  return value;
}
function building(id) { return path.join("data/economy/buildings", `${id}.tres`); }
function good(id) { return path.join("data/goods", `${id}.tres`); }
function hasPrereq(id, prerequisite) {
  return node(id).hard_prerequisite_ids.includes(prerequisite);
}

const banned = new Set([
  "tech.application.fired_brick_kiln",
  "tech.application.classical_masonry_yard",
  "tech.application.ore_bronzesmith_camp",
  "tech.application.iron_tool_workshop",
]);
for (const row of NETWORK.nodes) {
  for (const prerequisite of row.hard_prerequisite_ids ?? []) {
    assert(!banned.has(prerequisite), `${row.id} retains banned supplier edge ${prerequisite}`);
  }
}

assert(!node("tech.copper_ore_roasting").modifier_terms.some((term) =>
  term.stat === "country.resource.copper_ore.use_factor"),
  "copper roasting still owns a global copper resource modifier");
assert(node("tech.copper_metallurgy").era_id === "kingdom", "copper metallurgy is not kingdom-era");
assert(node("tech.copper_mining_application").era_id === "kingdom", "copper mining is not kingdom-era");
assert(hasPrereq("tech.copper_metallurgy", "tech.copper_ore_roasting"), "copper metallurgy lost roasting knowledge");
assert(hasPrereq("tech.application.early_tin_smelter", "tech.application.early_tin_mine"), "tin smelter is not tied to tin ore knowledge");
assert(!hasPrereq("tech.application.early_tin_smelter", "tech.bronze_casting"), "tin smelter is still bronze-gated");

for (const id of ["copper_ore_collector", "iron_ore_collector"]) {
  const file = building(id);
  assert(strings(file, "input_category_ids")[0] === "tools", `${id} does not use tools category`);
  assert(ints(file, "input_required_q16")[0] === 32768, `${id} tool input is not soft`);
  assert(!strings(file, "input_good_ids").includes("bronze_tools"), `${id} still requires bronze_tools`);
}
assert(fs.existsSync(path.join(ROOT, "data/goods/copper_tools.tres")), "copper_tools good missing");
assert(fs.existsSync(path.join(ROOT, "data/economy/buildings/copper_tool_workshop.tres")), "copper tool workshop missing");
assert(strings(building("copper_tool_workshop"), "technology_tags").includes("tech.copper_annealing"),
  "copper tool workshop lost copper annealing binding");

assert(fs.existsSync(path.join(ROOT, "data/economy/buildings/brine_boiling_hearth.tres")), "brine boiling hearth missing");
assert(node("tech.application.cotton_ginning_shelter").era_id === "agrarian", "cotton gin shelter not moved to agrarian era");
assert(node("tech.application.latex_smoking_shelter").era_id === "agrarian", "latex smoke shelter not moved to agrarian era");
assert(strings(good("latex"), "substitution_category_ids").includes("raw_latex_feedstock"), "latex remains elastomer substitute");
assert(!strings(building("automobiles_plant"), "input_good_ids").includes("latex"), "automobiles still consume latex");
assert(!strings(building("method_automobiles_plant_r10"), "input_good_ids").includes("latex"), "modern automobiles still consume latex");
assert(ints(building("marine_fish_collector"), "input_required_q16").some((value) => value === 32768),
  "marine fish collector lacks soft natural rubber input");

assert(node("tech.application.goldsmith_workshop").era_id === "kingdom", "goldsmith workshop not kingdom-era");
assert(strings(building("goldsmith_workshop"), "input_candidate_good_ids").includes("gold"), "goldsmith lacks gold candidate");
assert(strings(building("goldsmith_workshop"), "input_candidate_good_ids").includes("silver"), "goldsmith lacks silver candidate");
assert(strings(good("salt"), "technology_tags").includes("tech.salt_preservation"), "salt lacks preservation binding");

console.log("industry line static assertions passed");
