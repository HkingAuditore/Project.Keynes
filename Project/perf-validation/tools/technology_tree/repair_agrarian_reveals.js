const fs = require("fs");

const networkPath = "Project/project-keynes/data/technology/technology_network.json";
const text = fs.readFileSync(networkPath, "utf8");

const any = (...ids) => ({
  operator: 2,
  children: ids.map((id) => ({ kind: 1, id, value: 1 })),
});

// These nodes previously repeated a species/resource atom already implied by
// their hard-prerequisite history. The replacement evidence describes the
// production problem that makes the next technique worth investigating.
const replacements = {
  "tech.irrigation": any("landform.freshwater_access", "breakthrough.hydraulic_engineering"),
  "tech.pastoralism": any("resource.pasture", "landform.steppe_plain", "weather.drought"),
  "tech.horse_domestication": any("resource.pasture", "landform.steppe_plain"),
  "tech.maize_selection": any("breakthrough.maize_selection"),
  "tech.spice_cultivation": any("resource.plantation_land", "weather.prolonged_wet_season"),
  "tech.rubber_working": any("resource.plantation_land", "landform.forest"),
  "tech.weaving": any("resource.arable_land", "development.population.100_90d"),
  "tech.copper_metallurgy": any("breakthrough.metalworking"),
  "tech.bronze_casting": any("resource.tin_ore", "contact.tin"),
  "tech.dryland_water_retention": any("breakthrough.rainfed_adaptation", "landform.loess_plain"),
  "tech.irrigation_surveying": any("landform.delta", "development.settlement.tier_1_90d"),
  "tech.kiln_firing": any("resource.silica_sand", "breakthrough.kiln_temperature"),
  "tech.pottery": any("weather.freeze_thaw"),
  "tech.loom_weaving": any("development.population.100_90d", "resource.pasture"),
  "tech.household_landholding": any("resource.fertile_soil", "landform.river_valley"),
  "tech.communal_field_coordination": any("development.population.100_90d", "resource.arable_land"),
  "tech.maize_garden_horticulture": any("resource.arable_land", "weather.drought"),
  "tech.swidden_maize_cultivation": any("landform.forest"),
  "tech.rainfed_maize_cultivation": any("breakthrough.rainfed_adaptation"),
  "tech.flood_recession_maize": any("landform.floodplain", "weather.major_flood"),
  "tech.grain_threshing": any("bio.maize", "bio.rice"),
  "tech.rainfed_wheat_cultivation": any("resource.arable_land", "weather.drought"),
  "tech.flood_recession_wheat": any("landform.floodplain", "weather.major_flood"),
  "tech.dryland_wheat_cultivation": any("landform.loess_plain"),
  "tech.upland_rice_propagation": any("landform.high_plateau", "weather.drought"),
  "tech.wetland_rice_gardening": any("landform.delta", "weather.prolonged_wet_season"),
  "tech.rice_water_control": any("landform.river_valley", "weather.major_flood"),
  "tech.rice_paddy_cultivation": any("resource.paddy_land", "landform.delta"),
  "tech.ridge_tuber_cultivation": any("landform.high_plateau", "weather.frost"),
  "tech.frost_protected_storage": any("resource.arable_land"),
  "tech.highland_tuber_farming": any("landform.high_plateau", "breakthrough.terrace_maintenance"),
  "tech.flax_retting": any("landform.freshwater_access", "weather.prolonged_wet_season"),
  "tech.hand_spinning": any("bio.cotton", "resource.arable_land"),
  "tech.cotton_ginning": any("resource.arable_land", "development.population.100_90d"),
  "tech.cotton_gardening": any("resource.arable_land", "weather.heatwave"),
  "tech.spice_shade_gardening": any("resource.plantation_land", "landform.forest"),
  "tech.latex_smoke_coagulation": any("weather.prolonged_wet_season"),
  "tech.dairy_processing": any("resource.pasture", "landform.grassland"),
  "tech.hide_tanning": any("resource.wild_game", "resource.pasture"),
  "tech.wool_husbandry": any("resource.pasture", "landform.steppe_plain"),
  "tech.meat_processing": any("resource.wild_game", "bio.pig"),
  "tech.salt_preservation": any("resource.saltpeter", "weather.heatwave"),
  "tech.grain_baking": any("development.population.100_90d"),
  "tech.early_glassmaking": any("resource.limestone", "weather.freeze_thaw"),
};

function replaceBalanced(source, start) {
  const open = source.indexOf("{", start);
  if (open < 0) throw new Error("missing condition object");
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = open; i < source.length; i += 1) {
    const ch = source[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; continue; }
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return [source.slice(0, open), source.slice(open, i + 1), source.slice(i + 1)];
    }
  }
  throw new Error("unbalanced condition object");
}

let output = text;
let changed = 0;
for (const [id, condition] of Object.entries(replacements)) {
  const nodeStart = output.indexOf(`"id": "${id}"`);
  if (nodeStart < 0) throw new Error(`node not found: ${id}`);
  const revealStart = output.indexOf('"reveal_condition":', nodeStart);
  if (revealStart < 0) throw new Error(`reveal condition not found: ${id}`);
  const nextNode = output.indexOf('\n\t\t"id": "', nodeStart + 1);
  if (nextNode >= 0 && revealStart > nextNode) throw new Error(`wrong node scope: ${id}`);
  const [before, old, after] = replaceBalanced(output, revealStart);
  const indent = "\t\t\t";
  const replacement = JSON.stringify(condition, null, "\t").replace(/\n/g, "\n\t\t");
  output = before + replacement + after;
  changed += old === replacement ? 0 : 1;
}

fs.writeFileSync(networkPath, output, "utf8");
console.log(`[PASS] repaired ${changed} agrarian reveal conditions`);
