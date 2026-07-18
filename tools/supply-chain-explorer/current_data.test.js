'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const SC = require('./parser.js');

const repoRoot = path.resolve(__dirname, '..', '..');
const projectRoot = path.join(repoRoot, 'Project', 'project-keynes');
const data = { buildings: [], goods: [], resources: [], professions: [], plans: [], needs: [], economies: [] };

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile() && entry.name.endsWith('.tres')) {
      const parsed = SC.classifyAndParse(entry.name, fs.readFileSync(full, 'utf8'));
      if (parsed && parsed.error) throw new Error(`${full}: ${parsed.error}`);
      if (parsed && parsed.record) data[SC.collectionKey(parsed.type)].push(parsed.record);
    }
  }
}

walk(path.join(projectRoot, 'data'));
const taxonomy = fs.readFileSync(path.join(projectRoot, 'scripts', 'economy', 'technology_taxonomy.gd'), 'utf8');
const model = SC.buildModel(Object.assign(data, { eras: SC.parseEraFile(taxonomy) }));
const compiled = SC.compileAnalyticalModel(model);
const scenario = SC.computeBalanceScenario(model, {
  eraOrder: model.eras.length - 1,
  cumulative: true,
  latestUpgradeOnly: true,
  buildingCount: 1,
  utilization: 1,
  sellThrough: 0.8,
  professionScale: 1,
  includeHouseholds: true
});

assert.ok(model.buildings.length >= 250, `expected current building catalog, got ${model.buildings.length}`);
assert.ok(model.professions.length >= 30, `expected current profession catalog, got ${model.professions.length}`);
assert.ok(model.plans.length >= 8, `expected current consumption plans, got ${model.plans.length}`);
assert.ok(scenario.buildings.length > 0);
assert.ok(scenario.professions.length > 0);
assert.ok(scenario.goods.length > 0);
assert.ok(scenario.buildings.every((row) => Number.isFinite(row.inputCost) && Number.isFinite(row.surplus)));
assert.ok(scenario.professions.every((row) => Number.isFinite(row.perPersonCost)));
assert.ok(scenario.goods.every((row) => Number.isFinite(row.supply) && Number.isFinite(row.demand)));
assert.equal(compiled.schema, 'project-keynes-economy-balance-model');
assert.equal(compiled.resources.find((row) => row.id === 'wild_game').ecology_growth_rate, 0.001495);

for (let eraOrder = 0; eraOrder < model.eras.length; eraOrder++) {
  const eraScenario = SC.computeBalanceScenario(model, {
    eraOrder,
    cumulative: true,
    latestUpgradeOnly: true,
    buildingCount: 1,
    utilization: 1,
    sellThrough: 0.8,
    professionScale: 1,
    includeHouseholds: true
  });
  assert.equal(eraScenario.totals.lossBuildingTypes, 0,
    `${model.eras[eraOrder].id} has ordinary buildings below living-cost break-even`);
}

const hunting = model.buildingById.stone_age_hunting_camp;
const huntingOutputs = Object.fromEntries(hunting.produces.map((row) => [row.good, row.qty]));
assert.ok(huntingOutputs.raw_hide <= huntingOutputs.game_meat / 50,
  'hunting hide byproduct should not dominate the food output');
assert.ok(huntingOutputs.fur <= huntingOutputs.game_meat / 100,
  'hunting fur byproduct should remain scarce');

console.log(JSON.stringify({
  buildings: model.buildings.length,
  professions: model.professions.length,
  plans: model.plans.length,
  scenario_buildings: scenario.buildings.length,
  workforce: scenario.totals.workforce,
  loss_building_types: scenario.totals.lossBuildingTypes,
  shortage_goods: scenario.totals.shortageGoods
}));
