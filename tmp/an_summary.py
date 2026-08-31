import csv, statistics as st

BASE = 'economy_record_20260831_140522_v25_cell650_q45_r10'
f = open(BASE + '_summary.csv', encoding='utf-8-sig')
r = csv.reader(f); h = next(r)
rows = [row for row in r]
idx = {c: i for i, c in enumerate(h)}
N = len(rows)
def col(name):
    i = idx[name]
    out = []
    for row in rows:
        v = row[i]
        try: out.append(float(v))
        except: out.append(v if v != '' else None)
    return out

days = [int(x) for x in col('day_index')]
print('rows', N, 'days', days[0], days[-1], 'unique', len(set(days)))
d = sorted(set(days))
gaps = [(a, b) for a, b in zip(d, d[1:]) if b - a != 1]
print('day gaps', gaps[:10], 'count', len(gaps))

def num(name):
    return [float(x) if x not in (None, '') else 0.0 for x in col(name)]

def win(name, a=0, b=None):
    v = num(name)
    b = b if b is not None else len(v)
    s = v[a:b]
    return st.mean(s) if s else 0.0

KEY = [
 'cohort_count','market_count','good_count','building_type_count','building_group_count',
 'pending_construction_count','filled_owner_jobs','filled_employee_jobs','unemployed_population',
 'births','deaths','production_inputs_consumed','production_output_stock','production_output_discarded',
 'production_output_retained','production_output_supported','owner_output_consumed','producer_revenue',
 'producer_support_money_issued','bullion_money_issued','bullion_stock_consumed',
 'cycle_flow_produced','cycle_flow_consumed','cycle_flow_discarded',
 'building_wages_paid','building_wages_unpaid','building_resource_generated','building_resource_consumed',
 'loss_suspended_building_groups','merchant_procurement_budget','merchant_procurement_opportunity',
 'merchant_procurement_allocated','merchant_procurement_unspent_allocated','merchant_procurement_reserved',
 'merchant_procurement_spent','owner_working_capital_reserved','production_input_reserved',
 'production_input_reserve_shortfall','construction_material_reserved','maintenance_goods_consumed',
 'maintenance_unmet','population_error','money_error','goods_error','construction_goods_consumed',
 'building_investment_candidates','building_investments_started','building_investment_blocked_funds',
 'building_investment_blocked_materials','building_investment_blocked_sponsor_capital',
 'building_investment_blocked_resources','building_investment_probability_skips',
 'building_investment_capital_transferred','desired_business_demand','funded_business_demand',
 'unfunded_business_demand','building_owner_mobility','building_owner_job_reallocations',
 'building_employee_to_owner_reallocations','building_investment_jobs_started',
 'building_investment_employment_gap','building_investment_demand_limited',
 'building_investment_material_limited','building_investment_capital_limited',
 'building_investment_owner_population_limited','building_investment_displacement_starts',
 'trade_candidates_generated','trade_candidates_accepted','trade_rejected_profit','trade_rejected_no_spread',
 'trade_rejected_margin','trade_rejected_capacity','trade_rejected_stock','trade_rejected_cash',
 'trade_rejected_route','trade_orders_in_flight','trade_orders_dispatched','trade_orders_arrived',
 'trade_unclaimed_orders','trade_source_signals','trade_destination_signals','trade_ready_candidates',
 'trade_relief_candidates','trade_unresolved_no_attempt','trade_unresolved_no_spread',
 'trade_unresolved_margin','trade_unresolved_route','trade_unresolved_stock','trade_unresolved_capacity',
 'trade_unresolved_cash','trade_response_deadline_misses','trade_deficit_episodes_started',
 'trade_deficit_episodes_resolved','trade_true_source_stock_failures','trade_plan_reset_count',
 'merchant_cash','merchant_inventory_retail_value','merchant_inventory_liquidation_value',
 'merchant_economic_assets','merchant_operating_outflow','merchant_liquidity_coverage_q16',
 'merchant_effective_buy_factor_q16','merchant_credit_budget','merchant_credit_drawn',
 'merchant_credit_outstanding','merchant_credit_bad_debt','merchant_survival_procurement_required',
 'merchant_survival_procurement_allocated','merchant_input_procurement_required',
 'merchant_input_procurement_allocated','recovery_candidates','recovery_approved','recovery_restarted',
 'recovery_failed','recovery_liquidated_buildings','recovery_partially_liquidated_buildings',
 'recovery_fully_liquidated_groups','suspended_restart_candidates','suspended_restart_restarted',
 'suspended_liquidated_buildings','suspended_fully_liquidated_groups',
 'climate_profiled_building_groups','climate_limited_building_groups','average_climate_capacity_q16',
 'bullion_quota_initial','bullion_quota_remaining','gold_accepted','silver_accepted',
 'trade_active_keys_pruned','trade_candidates_stale_generation','trade_candidates_arbitrated_out',
]

W = 90  # window halves: first 90 days vs last 90 days
print('\n%-46s %14s %14s %14s %10s' % ('metric', 'mean_first90', 'mean_last90', 'total', 'ratio'))
for k in KEY:
    if k not in idx: 
        print('MISSING', k); continue
    v = num(k)
    tot = sum(v)
    a = st.mean(v[:W]) if len(v) >= W else 0
    b = st.mean(v[-W:]) if len(v) >= W else 0
    ratio = (b / a) if a else float('nan')
    print('%-46s %14.2f %14.2f %16.0f %10s' % (k, a, b, tot, ('%.2f' % ratio) if a else 'n/a'))
