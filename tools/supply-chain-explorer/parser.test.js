'use strict';

const assert = require('node:assert/strict');
const SC = require('./parser.js');

function fixture() {
  return SC.buildModel({
    eras: [{ id: 'era0', display_name: '时代零', tags: ['tech0'] }],
    needs: [{ id: 'food', display_name: '食物', living_cost_weight_q16: 65536 }],
    goods: [
      { id: 'grain', display_name: '谷物', technology_tags: ['tech0'], default_price: 10000, merchant_buy_price_factor_q16: 65536, production_efficiency_q16: 65536, substitution_category_ids: ['feed'] },
      { id: 'meal', display_name: '餐食', technology_tags: ['tech0'], default_price: 20000, merchant_buy_price_factor_q16: 65536, production_efficiency_q16: 65536 },
      { id: 'efficient_feed', display_name: '高效饲料', technology_tags: ['tech0'], default_price: 12000, merchant_buy_price_factor_q16: 65536, production_efficiency_q16: 131072, substitution_category_ids: ['feed'] },
      { id: 'product', display_name: '成品', technology_tags: ['tech0'], default_price: 10000, merchant_buy_price_factor_q16: 65536, production_efficiency_q16: 65536 }
    ],
    professions: [
      { id: 'worker', display_name: '工人', technology_tags: ['tech0'], default_consumption_plan_id: 'worker_plan' }
    ],
    plans: [{
      id: 'worker_plan', display_name: '工人消费',
      need_ids: ['food'], priorities: [1], base_qty_per_person: [1000],
      wealth_elasticity_q16: [0], wealth_min_q16: [65536], wealth_max_q16: [65536],
      need_variant_offsets: [0, 2], variant_ids: ['grain_food', 'meal_food'],
      variant_preference_q16: [65536, 65536], variant_price_elasticity_q16: [65536, 65536],
      variant_component_offsets: [0, 1, 2], component_good_ids: ['grain', 'meal'],
      component_qty_per_need: [1000, 1000]
    }],
    buildings: [{
      id: 'factory', display_name: '工厂', technology_tags: ['tech0'],
      owner_profession_id: 'worker', owner_slots_per_building: 1,
      employee_profession_ids: ['worker'], employee_slots_per_building: [2],
      employee_reference_wages_per_day: [2000],
      input_good_ids: ['grain'], input_quantities_per_day: [1000],
      input_category_ids: ['feed'], input_min_quality_levels: [0],
      input_candidate_offsets: [0, 0], input_candidate_good_ids: [], input_candidate_efficiency_q16: [],
      output_good_ids: ['product'], output_quantities_per_day: [4000],
      target_operating_margin_q16: 6554
    }],
    resources: []
  });
}

const model = fixture();
const reference = SC.professionReferenceDemand(model, 'worker');
assert.equal(reference.hasPlan, true);
assert.equal(reference.goods.grain, 500);
assert.equal(reference.goods.meal, 500);
assert.equal(reference.totalCost, 15000);

const selected = SC.resolveReferenceInput(model, model.buildingById.factory.consumes[0]);
assert.equal(selected.good.id, 'efficient_feed');
assert.equal(selected.physicalQty, 500);
assert.equal(selected.cost, 6000);

const scenario = SC.computeBalanceScenario(model, {
  eraOrder: 0, buildingCount: 1, utilization: 1, sellThrough: 0.8,
  professionScale: 1, includeHouseholds: true
});
assert.equal(scenario.totals.buildingTypes, 1);
assert.equal(scenario.totals.workforce, 3);
assert.equal(scenario.buildings[0].acceptedOutputValue, 32000);
assert.equal(scenario.buildings[0].inputCost, 6000);
assert.equal(scenario.buildings[0].employeeWages, 4000);
assert.equal(scenario.buildings[0].ownerLivingCost, 15000);
assert.equal(scenario.buildings[0].surplus, 7000);

const byGood = Object.fromEntries(scenario.goods.map((row) => [row.good.id, row]));
assert.equal(byGood.product.supply, 3200);
assert.equal(byGood.efficient_feed.buildingDemand, 500);
assert.equal(byGood.grain.householdDemand, 1500);
assert.equal(byGood.meal.householdDemand, 1500);

console.log('supply-chain-explorer parser tests passed');
