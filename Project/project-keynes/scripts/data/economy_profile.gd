class_name EconomyProfile
extends Resource

## Numeric scales are save-format ABI and must match the native constants.
@export var money_scale: int = 10000
@export var goods_scale: int = 1000
@export var ratio_scale: int = 65536
@export var rate_scale: int = 4294967296

@export_range(1, 65536, 1) var cells_per_slice: int = 5000
@export var auto_slice_by_scale: bool = true
## 0 uses a deterministic 256-active-cell building range. Positive values override it.
@export_range(0, 65536, 1) var building_cells_per_slice: int = 0
## Dense settlements are additionally bounded by actual building groups.
@export_range(1, 65536, 1) var building_groups_per_slice: int = 512
## Stage-local batching overrides. Zero keeps deterministic auto batching:
## plan/post-buildings use twice the normal building range, investment uses 96
## rolling cells, and final employment reconciliation uses 128 affected cells.
@export_range(0, 65536, 1) var building_plan_cells_per_slice: int = 128
@export_range(0, 65536, 1) var household_post_building_cells_per_slice: int = 0
@export_range(0, 65536, 1) var investment_cells_per_slice: int = 0
@export_range(0, 65536, 1) var building_finalize_cells_per_slice: int = 0
## Global building output efficiency. It scales goods output only; construction,
## production inputs, natural-resource use, and wages keep their catalog values.
@export_range(65536, 262144, 1) var building_output_efficiency_q16: int = 131072
## Food-only multiplier applied to staple/protein/produce building outputs and
## their carrying-capacity yield.  It leaves non-food industries unchanged.
@export_range(65536, 262144, 1) var food_building_output_efficiency_q16: int = 81920
## Longest market interval (1–5). Native locks N for a full cycle from populated
## work plus previous-cycle machine timing. 5 is the late-game stagger cap, not
## a start-of-game fixed period. 0 is ignored and treated as 5; the retired
## 50/334 auto-fast-forward path is not restored.
@export_range(1, 5, 1) var market_cycle_days: int = 5
@export_range(1, 5, 1) var market_min_cycle_days: int = 1
@export_range(1, 5, 1) var market_max_cycle_days: int = 5
## Per-native-call cohort guard retained for custom tests. Production rolling
## settlement normally completes its entire due phase in one call.
@export_range(0, 1000000, 1000) var market_target_cohorts_per_slice: int = 0
@export_range(1, 1048576, 1) var commands_per_slice: int = 16384
@export_range(1, 32, 1) var max_rules_per_plan: int = 32
@export var worker_enabled: bool = true
@export_range(1, 100000, 1) var worker_market_threshold: int = 64
@export_range(0, 16, 1) var worker_tasks_hint: int = 0
## Upper bound for economy worker fan-out. Twelve tasks still leaves the
## render/main thread headroom on 16+ core desktop CPUs; worker partition is
## weight-balanced and deterministic, so raising the cap only changes wall
## time, never results (worker/scalar state-hash equality is preserved).
@export_range(1, 16, 1) var economy_worker_task_cap: int = 12
## At speed 20+ adjacent household/production ranges are paired before worker
## dispatch. Merge order remains the original ascending cell order.
@export var economy_high_speed_batching_enabled: bool = true
## Recompute the complete opening ledger periodically as an independent
## verifier. Other days reuse the last exact committed close and refresh the
## native country treasury contribution.
@export_range(1, 365, 1) var economy_full_audit_verify_interval_days: int = 25
## INCREMENTAL uses the validated mutation ledger and performs a complete
## verification every configured interval. Any mismatch blocks publication and
## disables the fast path for the session; FULL remains the emergency baseline.
@export_enum("FULL", "PROBE", "INCREMENTAL") var economy_closing_audit_mode: String = "INCREMENTAL"
## Accuracy policy is independent from rollout mode. ACTIVE applies certified
## approximate candidate sets; invalid certificates and cooldown epochs remain
## exact. OFF and PROBE stay available as exact rollback/baseline paths.
@export_enum("EXACT", "BALANCED", "FAST", "CUSTOM") var economy_accuracy_preset: String = "BALANCED"
@export_enum("OFF", "PROBE", "ACTIVE") var economy_approximation_runtime_mode: String = "ACTIVE"
@export_range(0, 65536, 1) var economy_custom_max_regret_q16: int = 1966
@export_range(0, 65536, 1) var economy_custom_household_tail_share_q16: int = 655
@export_range(1, 8, 1) var economy_custom_candidate_top_k: int = 4
@export_range(0, 65536, 1) var economy_custom_choice_temperature_q16: int = 983
@export_range(1, 65536, 1) var economy_custom_exact_probe_rate_q16: int = 655
@export_range(1, 3650, 1) var economy_custom_fallback_cooldown_epochs: int = 10
## PROBE compares the conservative active-good candidate set with the complete
## investment type scan without changing authoritative results.
@export_enum("OFF", "PROBE", "ACTIVE") var economy_investment_sparse_mode: String = "ACTIVE"
@export_range(65536, 16777216, 65536) var save_chunk_bytes: int = 4194304
## Economy event journal keeps compact summaries globally and exact delta legs
## only for explicitly traced cells. Handlers consume committed batches.
@export_enum("OFF", "SUMMARY", "SELECTIVE", "FULL_DEBUG") var economy_trace_mode: String = "SELECTIVE"
@export_range(1048576, 1073741824, 1048576) var economy_trace_memory_bytes: int = 33554432
@export_range(1, 3650, 1) var economy_trace_retention_epochs: int = 8
@export_range(65536, 268435456, 65536) var economy_trace_detail_epoch_bytes: int = 8388608
@export_range(1, 65536, 1) var economy_trace_poll_max_events: int = 4096
@export var merchant_profession_id: StringName = &"merchant"
## Reserved profession id used for unemployed population buckets. Native resolves
## this to a profession index so the employment pass can identify (and skip when
## laying off / target when idling) the unemployed signatures. Must match the
## reserved `unemployed` profession catalog entry and MUST NOT be a building role.
@export var unemployed_profession_id: StringName = &"unemployed"
@export var wealth_reference_per_capita: int = 100000
@export var living_cost_base_plan_id: StringName = &"survival_household"
## Survival satisfaction reaches full workforce capacity at this caloric/cold-exposure ratio.
@export_range(1, 65536, 1) var starvation_satisfaction_threshold_q16: int = 32768
## Subsistence producers plan and retain enough food for healthy satisfaction, independently
## from the lower threshold where starvation mortality begins.
@export_range(1, 65536, 1) var survival_production_target_q16: int = 65536
## Maximum per-person daily Q32 mortality when survival satisfaction is zero.
## Starvation mortality is deliberately driven by the subsistence dimension
## alone: dying of hunger is a physiological fact and must never follow from a
## heavy tax burden or a backward settlement.
@export_range(0, 4294967296, 1) var starvation_death_rate_q32: int = 21474836

## --- Composite satisfaction ---
## Fallback Q16 dimension weights for professions that do not author their own
## `satisfaction_dimension_weights_q16`. Native enum order: subsistence, basic,
## comfort, luxury, income growth, savings, tax burden, social development.
@export var satisfaction_default_dimension_weights_q16: PackedInt32Array = PackedInt32Array([
	65536, 45875, 26214, 13107, 19661, 19661, 16384, 13107,
])
## Subsistence gate slack. The composite may never exceed
## `subsistence + (1 - subsistence) * slack`, so a starving cohort cannot be
## rated satisfied because of its savings. 0 pins the composite to subsistence,
## 65536 disables the gate entirely. The default is deliberately tight: a fully
## fed cohort never feels the gate, while a fully starving one must stay under
## the birth reference so its births fall below natural deaths.
@export_range(0, 65536, 1) var satisfaction_subsistence_gate_slack_q16: int = 6554
## Per-capita income EMA ratio (short EMA over long baseline EMA) that scores
## zero and full marks on the income-growth dimension.
@export_range(0, 655360, 1) var satisfaction_income_growth_floor_q16: int = 58982
@export_range(1, 655360, 1) var satisfaction_income_growth_ceiling_q16: int = 78643
## Q16 alpha of the slow income baseline EMA per settlement day. The fast
## `income_ema` uses 1/8 per day, so 1/64 keeps the baseline roughly eight times
## slower and makes the ratio a genuine growth signal.
@export_range(1, 65536, 1) var satisfaction_income_baseline_alpha_q16: int = 1024
## Months of living cost a cohort must hold in funds to score full marks on the
## savings dimension (Q16 months).
@export_range(1, 6553600, 1) var satisfaction_savings_target_months_q16: int = 393216
## Net tax share of gross income that scores zero on the tax-burden dimension.
## Net subsidies (negative burden) saturate the dimension at full marks.
@export_range(1, 65536, 1) var satisfaction_tax_tolerance_q16: int = 22938
## Q16 weights of the three social-development inputs: settlement tier, national
## technology progress, and local built-industry variety. Normalized natively.
@export var satisfaction_development_weights_q16: PackedInt32Array = PackedInt32Array([
	26214, 26214, 13107,
])
## Local built-industry variety that saturates the third development input.
@export_range(1, 256, 1) var satisfaction_development_variety_target: int = 12
## Composite value treated as "fully satisfied" by the birth-rate reduction.
## The raw composite is rescaled by this reference before entering
## `birth_factor = 1 - satisfaction_birth_weight * (1 - birth_input)`, so an
## early-era cohort with no luxuries, savings, or development does not collapse
## its own birth rate.
@export_range(1, 65536, 1) var satisfaction_birth_reference_q16: int = 45875
## Composite thresholds (Q16, ascending) separating the five social-pressure
## levels. A cell publishes `EVENT_ECONOMY_SOCIAL_PRESSURE` only when its
## population-weighted level crosses one of these boundaries.
@export var satisfaction_pressure_thresholds_q16: PackedInt32Array = PackedInt32Array([
	13107, 26214, 39322, 52429,
])
@export_range(0, 65536, 1) var wage_ema_alpha_q16: int = 8192
## Daily fraction of a cohort that may reconsider employment (13107/65536 ≈ 20%).
## The native employment pass compounds this over the locked market period, so
## changing N does not create a one-period migration shock.
@export_range(0, 65536, 1) var employment_mobility_daily_q16: int = 13107
## Linear choice temperature used when splitting a cohort across acceptable
## vacancies. Higher values soften winner-takes-all hiring.
@export_range(1, 65536, 1) var employment_choice_temperature_q16: int = 6554
@export_range(0, 65536, 1) var wage_max_rise_q16_per_day: int = 1311
@export_range(0, 65536, 1) var wage_max_fall_q16_per_day: int = 1311
## Damping: the living-cost wage floor is capped at each building's per-employee
## expected revenue times this ratio (Q16, 65536 = 1.0). Keeps a rational employer
## from being forced to pay wages far above what its revenue can support. 0 disables.
@export_range(0, 655360, 1) var wage_income_cap_ratio_q16: int = 78643
@export_range(0, 65536, 1) var employee_profit_share_q16: int = 16384
@export_range(-65536, 0, 1) var building_severe_loss_threshold_q16: int = -16384
@export_range(1, 32, 1) var building_severe_loss_cycles: int = 3
@export_range(0, 65536, 1) var building_restart_margin_q16: int = 6554
## Merchants keep 12.5% of frozen opening cash while procurement is active.
@export_range(0, 65536, 1) var merchant_procurement_cash_reserve_q16: int = 8192
## Base inventory horizon before each good's configured target ratio is applied.
## 3932160 is 60 deterministic Q16 days: twelve production cycles and four
## default trade-response windows.
@export_range(0, 7864320, 1) var merchant_market_making_days_q16: int = 3932160
@export_enum("OFF", "PROBE", "ACTIVE") var merchant_credit_runtime_mode: String = "ACTIVE"
@export_range(0, 65536, 1) var merchant_credit_exposure_q16: int = 16384
@export_range(0, 65536, 1) var merchant_credit_premium_q16: int = 3277
@export_range(1, 64, 1) var merchant_credit_term_cycles: int = 6
## A suspended building must fail roughly one year of 5-day restart reviews
## before liquidation.
@export_range(1, 365, 1) var suspended_liquidation_failed_reviews: int = 73
## Frozen-cycle Market V2 has passed the mobile and 10M-cohort ACTIVE gates.
@export_enum("OFF", "PROBE", "ACTIVE") var market_runtime_mode: String = "ACTIVE"

## Domestic cross-cell trade rolls out independently from the local market.
@export_enum("OFF", "PROBE", "ACTIVE") var trade_runtime_mode: String = "ACTIVE"
## Transient investment-only demand propagation. ACTIVE may open an existing
## investment demand gate, but never writes market demand, price, trade, or EMA
## state. OFF preserves the pre-v44 investment behavior.
@export_enum("OFF", "ACTIVE") var startup_demand_runtime_mode: String = "ACTIVE"
@export_range(1, 2147483647, 1) var trade_capacity_per_merchant_q16: int = 4194304
@export_range(1, 1000000, 1) var trade_speed_cost_per_day: int = 4
@export_range(0, 65536, 1) var trade_min_margin_q16: int = 3277
@export_range(1, 8, 1) var trade_target_count: int = 4
@export_range(256, 1048576, 256) var trade_signal_pairs_per_slice: int = 4096
@export_range(1, 256, 1) var trade_route_searches_per_slice: int = 32
@export_range(64, 1000000, 64) var trade_max_route_expansions: int = 8192
@export_range(64, 4194304, 64) var trade_route_cache_entries: int = 16384
@export_range(64, 1048576, 64) var trade_max_signals: int = 32768
@export_range(16, 1048576, 16) var trade_max_candidates: int = 8192
@export_range(16, 1048576, 16) var trade_max_orders: int = 4096
@export_range(0, 65536, 1) var trade_flow_ema_alpha_q16: int = 8192
@export_range(1, 65536, 1) var trade_max_stock_share_q16: int = 16384
@export_range(1, 365, 1) var trade_export_floor_days: int = 5
@export_range(0, 65536, 1) var trade_export_inventory_fraction_q16: int = 32768
@export_range(0, 65536, 1) var trade_import_fill_fraction_q16: int = 32768
@export_range(1, 365, 1) var trade_response_days: int = 15
@export_range(10, 30, 1) var investment_review_days: int = 30
## Plan P locks in 5–15; investment I locks in 10–30 and must be longer than P.
## These fields are range hints and v37 restore compatibility, not a shared S.
@export_range(5, 15, 1) var building_plan_days: int = 10
## One-day economy budget used only at cycle boundaries to convert measured
## milliseconds-per-knife into how many knives this machine can finish today.
@export_range(0.5, 32.0, 0.1) var economy_cadence_target_ms: float = 8.0
@export_range(1, 36500, 1) var investment_max_payback_days: int = 365
@export_range(1, 12, 1) var investment_operating_cycles: int = 2
@export_range(1, 65536, 1) var investment_gap_fill_share_q16: int = 16384
@export_range(1, 4, 1) var investment_portfolio_max_types: int = 4
@export_range(1, 65536, 1) var investment_max_type_owner_share_q16: int = 32768
## Per review, an established building type may grow by at most 10% of its
## installed count. A previously absent type uses the separate seed limit.
@export_range(1, 65536, 1) var investment_max_growth_share_q16: int = 16384
@export_range(1, 1024, 1) var investment_new_type_seed_buildings: int = 1
## Challenger unit cost must beat incumbents by at least this Q16 fraction
## (default 1/16) before a no-gap type can steal their daily offered supply.
@export_range(1, 65536, 1) var investment_displacement_min_advantage_q16: int = 4096
## A non-merchant cohort only changes profession into merchant when its
## projected disposable-income improvement reaches this Q16 threshold.
@export_range(1, 65536, 1) var investment_merchant_transition_min_improvement_q16: int = 32768
@export_range(1, 65536, 1) var recovery_liquidation_max_share_q16: int = 16384
@export_range(0, 65536, 1) var resource_min_reserve_q16: int = 22938
@export_range(0, 65536, 1) var resource_safe_harvest_q16: int = 32768
@export_range(1, 365000, 1) var resource_min_horizon_days: int = 3650
## Sector default construction-BOM amortization when a building leaves its
## maintenance recipe empty. Order: agriculture, extractive, manufacturing,
## energy, knowledge.
@export var building_maintenance_horizon_days_by_sector: PackedInt32Array = PackedInt32Array([
	5475, 2920, 3650, 2190, 7300,
])
## Applied only to derived (empty-recipe) daily quantities, not authored recipes.
@export_range(1, 262144, 1) var building_maintenance_cost_factor_q16: int = 65536
@export_range(0, 65536, 1) var bullion_monthly_issue_cap_q16: int = 655
@export_range(0, 65536, 1) var producer_support_monthly_cap_q16: int = 3277

## Notable-family overlay. Anonymous households remain implicit; family cash is
## a conserved claim inside cohort funds and never a second wallet.
@export_enum("OFF", "PROBE", "ACTIVE") var family_runtime_mode: String = "ACTIVE"
@export_range(0, 7, 1) var family_min_settlement_tier: int = 2
@export_range(1, 3650, 1) var family_review_days: int = 30
## Ordinary family formation starts only in cells with at least 150 people.
@export_range(1, 1000000000, 1) var family_min_population_per_active: int = 150
## A city keeps only a few notable families. Changing this value invalidates
## PKEC restores (`save_family_policy_profile_mismatch`).
@export_range(1, 4096, 1) var family_max_per_cell: int = 8
@export_range(1, 65536, 1) var family_cells_per_slice: int = 128
@export_range(1, 32, 1) var family_decline_reviews: int = 3
## Local notable household size per owned owner post. A city keeps only a few
## families as an overlay on the anonymous majority. Each household may grow
## toward dozens or hundreds, but never by swallowing the whole town.
## Formation and FAMILY_COMMIT absorb remaining anonymous owner-signature
## people without minting population, leaving at least one anonymous person
## per cohort and at most half the cell in all families combined.
## Dispatch still leaves one person behind.
@export_range(1, 256, 1) var family_household_people_per_owner_slot: int = 256
@export_range(1, 100000, 1) var family_household_max_people: int = 1024

## Sparse important-person overlay nested inside family membership. Persons
## attribute realized cohort cash flow and demand; they never become a second
## population unit or an independent wallet.
@export_enum("OFF", "PROBE", "ACTIVE") var notable_person_runtime_mode: String = "ACTIVE"
@export_range(1, 32, 1) var notable_person_max_per_family: int = 4
@export_range(1, 4096, 1) var notable_person_max_per_cell: int = 128
@export_range(1, 1000000, 1) var notable_person_max_total: int = 65536
@export_range(1, 65536, 1) var notable_person_records_per_slice: int = 4096

## 格承载力三项混合 K：地理天花板、已解锁物资族盈余、阶层满意度。
@export var carrying_k_habitat_ref: int = 40
@export var carrying_k_floor: int = 8
@export_range(0, 262144, 1) var carrying_river_bonus_q16: int = 72090
@export_range(0, 65536, 1) var carrying_water_habitability_q16: int = 49152
@export_range(0, 65536, 1) var carrying_surplus_elasticity_q16: int = 32768
@export_range(0, 65536, 1) var carrying_sat_elasticity_q16: int = 22938
## Birth suppression begins at 90% of the stock-inclusive carrying capacity.
@export_range(1, 65536, 1) var carrying_soft_start_q16: int = 58982
## Food stock contributes a bounded number of days of equivalent carrying capacity.
## This prevents a temporary warehouse surplus from creating unlimited population growth.
@export_range(1, 3650, 1) var carrying_stock_buffer_days: int = 30
@export_range(0, 65536, 1) var carrying_surplus_floor_q16: int = 16384
@export_range(65536, 262144, 1) var carrying_surplus_cap_q16: int = 98304
@export_range(0, 65536, 1) var carrying_sat_floor_q16: int = 8192
@export_range(1, 65536, 1) var carrying_sat_cap_q16: int = 65536
@export_range(1, 262144, 1) var carrying_residual_floor_q16: int = 32768
@export_range(65536, 262144, 1) var carrying_residual_cap_q16: int = 131072
@export_range(1, 65536, 1) var carrying_support_ema_alpha_q16: int = 1024
@export_range(0, 65536, 1) var carrying_temp_opt_lo_q16: int = 19661
@export_range(0, 65536, 1) var carrying_temp_opt_hi_q16: int = 45875
@export_range(0, 65536, 1) var carrying_paw_opt_lo_q16: int = 16384
@export_range(0, 65536, 1) var carrying_paw_opt_hi_q16: int = 58982
@export var carrying_family_weight: PackedInt32Array = PackedInt32Array([
	10, 7, 5, 4, 4, 2, 4, 3, 3, 2, 1, 1, 1, 2, 3, 1, 1, 3, 2, 2, 1])
@export var carrying_class_ids: PackedStringArray = PackedStringArray([
	"farmer", "worker", "general", "unemployed", "technology", "owner"])
@export var carrying_class_weight_q16: PackedInt32Array = PackedInt32Array([
	81920, 65536, 65536, 49152, 39322, 32768])
@export var carrying_landform_habitability_q16: PackedInt32Array = PackedInt32Array([
	3277, 6554, 26214, 36045, 65536, 58982, 45875, 22938, 6554, 72090,
	16384, 6554, 19661, 39322, 52429, 29491])
@export var carrying_vegetation_habitability_q16: PackedInt32Array = PackedInt32Array([
	32768, 6554, 16384, 13107, 29491, 36045, 29491, 65536, 58982, 65536,
	45875, 42598, 58982, 49152, 52429, 45875, 19661, 6554, 52429, 45875,
	49152, 52429, 39322, 32768, 45875, 52429, 36045, 29491])

func to_native_profile() -> Dictionary:
	return {
		"money_scale": money_scale,
		"goods_scale": goods_scale,
		"ratio_scale": ratio_scale,
		"rate_scale": rate_scale,
		"cells_per_slice": cells_per_slice,
		"auto_slice_by_scale": auto_slice_by_scale,
		"building_cells_per_slice": building_cells_per_slice,
		"building_groups_per_slice": building_groups_per_slice,
		"building_plan_cells_per_slice": building_plan_cells_per_slice,
		"household_post_building_cells_per_slice":
			household_post_building_cells_per_slice,
		"investment_cells_per_slice": investment_cells_per_slice,
		"building_finalize_cells_per_slice":
			building_finalize_cells_per_slice,
		"building_output_efficiency_q16": building_output_efficiency_q16,
		"food_building_output_efficiency_q16": food_building_output_efficiency_q16,
		"market_cycle_days": market_cycle_days,
		"market_min_cycle_days": market_min_cycle_days,
		"market_max_cycle_days": market_max_cycle_days,
		"economy_cadence_target_ms": economy_cadence_target_ms,
		"market_target_cohorts_per_slice": market_target_cohorts_per_slice,
		"commands_per_slice": commands_per_slice,
		"max_rules_per_plan": max_rules_per_plan,
		"worker_enabled": worker_enabled,
		"worker_market_threshold": worker_market_threshold,
		"worker_tasks_hint": worker_tasks_hint,
			"economy_worker_task_cap": economy_worker_task_cap,
			"economy_high_speed_batching_enabled": economy_high_speed_batching_enabled,
			"economy_full_audit_verify_interval_days": economy_full_audit_verify_interval_days,
			"economy_closing_audit_mode": economy_closing_audit_mode,
		"economy_accuracy_preset": economy_accuracy_preset,
		"economy_approximation_runtime_mode": economy_approximation_runtime_mode,
		"economy_custom_max_regret_q16": economy_custom_max_regret_q16,
		"economy_custom_household_tail_share_q16":
			economy_custom_household_tail_share_q16,
		"economy_custom_candidate_top_k": economy_custom_candidate_top_k,
		"economy_custom_choice_temperature_q16":
			economy_custom_choice_temperature_q16,
		"economy_custom_exact_probe_rate_q16": economy_custom_exact_probe_rate_q16,
		"economy_custom_fallback_cooldown_epochs":
			economy_custom_fallback_cooldown_epochs,
		"economy_investment_sparse_mode": economy_investment_sparse_mode,
		"economy_trace_mode": economy_trace_mode,
		"economy_trace_memory_bytes": economy_trace_memory_bytes,
		"economy_trace_retention_epochs": economy_trace_retention_epochs,
		"economy_trace_detail_epoch_bytes": economy_trace_detail_epoch_bytes,
		"economy_trace_poll_max_events": economy_trace_poll_max_events,
		"merchant_profession_id": String(merchant_profession_id),
		"unemployed_profession_id": String(unemployed_profession_id),
		"wealth_reference_per_capita": wealth_reference_per_capita,
		"living_cost_base_plan_id": String(living_cost_base_plan_id),
		"starvation_satisfaction_threshold_q16": starvation_satisfaction_threshold_q16,
		"survival_production_target_q16": survival_production_target_q16,
		"starvation_death_rate_q32": starvation_death_rate_q32,
		"satisfaction_default_dimension_weights_q16":
			satisfaction_default_dimension_weights_q16,
		"satisfaction_subsistence_gate_slack_q16":
			satisfaction_subsistence_gate_slack_q16,
		"satisfaction_income_growth_floor_q16": satisfaction_income_growth_floor_q16,
		"satisfaction_income_growth_ceiling_q16": satisfaction_income_growth_ceiling_q16,
		"satisfaction_income_baseline_alpha_q16": satisfaction_income_baseline_alpha_q16,
		"satisfaction_savings_target_months_q16": satisfaction_savings_target_months_q16,
		"satisfaction_tax_tolerance_q16": satisfaction_tax_tolerance_q16,
		"satisfaction_development_weights_q16": satisfaction_development_weights_q16,
		"satisfaction_development_variety_target":
			satisfaction_development_variety_target,
		"satisfaction_birth_reference_q16": satisfaction_birth_reference_q16,
		"satisfaction_pressure_thresholds_q16": satisfaction_pressure_thresholds_q16,
		"wage_ema_alpha_q16": wage_ema_alpha_q16,
		"employment_mobility_daily_q16": employment_mobility_daily_q16,
		"employment_choice_temperature_q16": employment_choice_temperature_q16,
		"wage_max_rise_q16_per_day": wage_max_rise_q16_per_day,
		"wage_max_fall_q16_per_day": wage_max_fall_q16_per_day,
		"wage_income_cap_ratio_q16": wage_income_cap_ratio_q16,
		"employee_profit_share_q16": employee_profit_share_q16,
		"building_severe_loss_threshold_q16": building_severe_loss_threshold_q16,
		"building_severe_loss_cycles": building_severe_loss_cycles,
		"building_restart_margin_q16": building_restart_margin_q16,
		"merchant_procurement_cash_reserve_q16": merchant_procurement_cash_reserve_q16,
		"merchant_market_making_days_q16": merchant_market_making_days_q16,
		"merchant_credit_runtime_mode": merchant_credit_runtime_mode,
		"merchant_credit_exposure_q16": merchant_credit_exposure_q16,
		"merchant_credit_premium_q16": merchant_credit_premium_q16,
		"merchant_credit_term_cycles": merchant_credit_term_cycles,
		"suspended_liquidation_failed_reviews": suspended_liquidation_failed_reviews,
		"market_runtime_mode": market_runtime_mode,
		"trade_runtime_mode": trade_runtime_mode,
		"startup_demand_runtime_mode": startup_demand_runtime_mode,
		"trade_capacity_per_merchant_q16": trade_capacity_per_merchant_q16,
		"trade_speed_cost_per_day": trade_speed_cost_per_day,
		"trade_min_margin_q16": trade_min_margin_q16,
		"trade_target_count": trade_target_count,
		"trade_signal_pairs_per_slice": trade_signal_pairs_per_slice,
		"trade_route_searches_per_slice": trade_route_searches_per_slice,
		"trade_max_route_expansions": trade_max_route_expansions,
		"trade_route_cache_entries": trade_route_cache_entries,
		"trade_max_signals": trade_max_signals,
		"trade_max_candidates": trade_max_candidates,
		"trade_max_orders": trade_max_orders,
		"trade_flow_ema_alpha_q16": trade_flow_ema_alpha_q16,
		"trade_max_stock_share_q16": trade_max_stock_share_q16,
		"trade_export_floor_days": trade_export_floor_days,
		"trade_export_inventory_fraction_q16": trade_export_inventory_fraction_q16,
		"trade_import_fill_fraction_q16": trade_import_fill_fraction_q16,
		"trade_response_days": trade_response_days,
		"investment_review_days": investment_review_days,
		"building_plan_days": building_plan_days,
		"investment_max_payback_days": investment_max_payback_days,
		"investment_operating_cycles": investment_operating_cycles,
		"investment_gap_fill_share_q16": investment_gap_fill_share_q16,
		"investment_portfolio_max_types": investment_portfolio_max_types,
		"investment_max_type_owner_share_q16": investment_max_type_owner_share_q16,
		"investment_max_growth_share_q16": investment_max_growth_share_q16,
		"investment_new_type_seed_buildings": investment_new_type_seed_buildings,
		"investment_displacement_min_advantage_q16": investment_displacement_min_advantage_q16,
		"investment_merchant_transition_min_improvement_q16": investment_merchant_transition_min_improvement_q16,
		"recovery_liquidation_max_share_q16": recovery_liquidation_max_share_q16,
		"resource_min_reserve_q16": resource_min_reserve_q16,
		"resource_safe_harvest_q16": resource_safe_harvest_q16,
		"resource_min_horizon_days": resource_min_horizon_days,
		"building_maintenance_horizon_days_by_sector":
			building_maintenance_horizon_days_by_sector,
		"building_maintenance_cost_factor_q16":
			building_maintenance_cost_factor_q16,
		"bullion_monthly_issue_cap_q16": bullion_monthly_issue_cap_q16,
		"producer_support_monthly_cap_q16": producer_support_monthly_cap_q16,
		"family_runtime_mode": family_runtime_mode,
		"family_min_settlement_tier": family_min_settlement_tier,
		"family_review_days": family_review_days,
		"family_min_population_per_active": family_min_population_per_active,
		"family_max_per_cell": family_max_per_cell,
		"family_cells_per_slice": family_cells_per_slice,
		"family_decline_reviews": family_decline_reviews,
		"family_household_people_per_owner_slot":
			family_household_people_per_owner_slot,
		"family_household_max_people": family_household_max_people,
		"notable_person_runtime_mode": notable_person_runtime_mode,
		"notable_person_max_per_family": notable_person_max_per_family,
		"notable_person_max_per_cell": notable_person_max_per_cell,
		"notable_person_max_total": notable_person_max_total,
		"notable_person_records_per_slice": notable_person_records_per_slice,
		"carrying_k_habitat_ref": carrying_k_habitat_ref,
		"carrying_k_floor": carrying_k_floor,
		"carrying_river_bonus_q16": carrying_river_bonus_q16,
		"carrying_water_habitability_q16": carrying_water_habitability_q16,
		"carrying_surplus_elasticity_q16": carrying_surplus_elasticity_q16,
		"carrying_sat_elasticity_q16": carrying_sat_elasticity_q16,
		"carrying_soft_start_q16": carrying_soft_start_q16,
		"carrying_stock_buffer_days": carrying_stock_buffer_days,
		"carrying_surplus_floor_q16": carrying_surplus_floor_q16,
		"carrying_surplus_cap_q16": carrying_surplus_cap_q16,
		"carrying_sat_floor_q16": carrying_sat_floor_q16,
		"carrying_sat_cap_q16": carrying_sat_cap_q16,
		"carrying_residual_floor_q16": carrying_residual_floor_q16,
		"carrying_residual_cap_q16": carrying_residual_cap_q16,
		"carrying_support_ema_alpha_q16": carrying_support_ema_alpha_q16,
		"carrying_temp_opt_lo_q16": carrying_temp_opt_lo_q16,
		"carrying_temp_opt_hi_q16": carrying_temp_opt_hi_q16,
		"carrying_paw_opt_lo_q16": carrying_paw_opt_lo_q16,
		"carrying_paw_opt_hi_q16": carrying_paw_opt_hi_q16,
		"carrying_family_weight": carrying_family_weight,
		"carrying_class_ids": carrying_class_ids,
		"carrying_class_weight_q16": carrying_class_weight_q16,
		"carrying_landform_habitability_q16": carrying_landform_habitability_q16,
		"carrying_vegetation_habitability_q16": carrying_vegetation_habitability_q16,
	}
