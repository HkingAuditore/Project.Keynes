'use strict';

const fs = require('node:fs');
const path = require('node:path');
const SC = require('./parser.js');

const repoRoot = path.resolve(__dirname, '..', '..');
const projectRoot = path.join(repoRoot, 'Project', 'project-keynes');
const data = { buildings: [], goods: [], resources: [], professions: [], plans: [], needs: [] };

function walk(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(fullPath);
    else if (entry.isFile() && entry.name.endsWith('.tres')) {
      const parsed = SC.classifyAndParse(entry.name, fs.readFileSync(fullPath, 'utf8'));
      if (parsed && parsed.error) throw new Error(`${fullPath}: ${parsed.error}`);
      if (parsed && parsed.record) data[`${parsed.type}s`].push(parsed.record);
    }
  }
}

function round(value, digits = 3) {
  return Number.isFinite(value) ? Number(value.toFixed(digits)) : String(value);
}

walk(path.join(projectRoot, 'data'));
const taxonomy = fs.readFileSync(
  path.join(projectRoot, 'scripts', 'economy', 'technology_taxonomy.gd'), 'utf8');
const model = SC.buildModel(Object.assign(data, { eras: SC.parseEraFile(taxonomy) }));

const scenarios = model.eras.map((era, eraOrder) => {
  const scenario = SC.computeBalanceScenario(model, {
    eraOrder,
    cumulative: true,
    latestUpgradeOnly: true,
    buildingCount: 1,
    utilization: 1,
    sellThrough: 0.8,
    professionScale: 1,
    includeHouseholds: true
  });
  const losses = scenario.buildings
    .filter((row) => !row.isMonetaryIssue && !row.sustainable)
    .sort((a, b) => a.breakEvenSellThrough - b.breakEvenSellThrough)
    .map((row) => ({
      id: row.building.id,
      name: row.building.display_name,
      sell_through_needed: round(row.breakEvenSellThrough),
      surplus_at_80_percent: round(row.surplus, 0)
    }));
  const oversupply = scenario.goods
    .filter((row) => row.demand > 0 && row.coverage > 2)
    .sort((a, b) => b.coverage - a.coverage)
    .slice(0, 20)
    .map((row) => ({
      id: row.good.id,
      name: row.good.display_name,
      coverage: round(row.coverage),
      supply: round(row.supply, 0),
      demand: round(row.demand, 0),
      business_demand: round(row.buildingDemand, 0),
      household_demand: round(row.householdDemand, 0)
    }));
  const noDemand = scenario.goods
    .filter((row) => row.supply > 0 && row.demand === 0 && Number(row.good.monetary_issue_value || 0) === 0)
    .sort((a, b) => b.supplyValue - a.supplyValue)
    .slice(0, 20)
    .map((row) => ({ id: row.good.id, name: row.good.display_name, supply: round(row.supply, 0) }));
  return {
    era: era.id,
    buildings: scenario.totals.buildingTypes,
    workforce: round(scenario.totals.workforce, 0),
    losses,
    oversupply,
    produced_without_reference_demand: noDemand
  };
});

const report = {
  assumptions: 'one latest building per family, 100% utilization, 80% sell-through, household population equals building jobs',
  scenarios
};
if (process.argv.includes('--summary')) {
  console.log(JSON.stringify({
    assumptions: report.assumptions,
    scenarios: scenarios.map((scenario) => ({
      era: scenario.era,
      buildings: scenario.buildings,
      workforce: scenario.workforce,
      loss_count: scenario.losses.length,
      losses: scenario.losses,
      top_oversupply: scenario.oversupply.slice(0, 5)
    }))
  }, null, 2));
} else {
  console.log(JSON.stringify(report, null, 2));
}
