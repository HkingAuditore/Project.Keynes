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
@export_range(0, 65536, 1) var building_plan_cells_per_slice: int = 0
@export_range(0, 65536, 1) var household_post_building_cells_per_slice: int = 0
@export_range(0, 65536, 1) var investment_cells_per_slice: int = 0
@export_range(0, 65536, 1) var building_finalize_cells_per_slice: int = 0
## Global building output efficiency. It scales goods output only; construction,
## production inputs, natural-resource use, and wages keep their catalog values.
@export_range(65536, 262144, 1) var building_output_efficiency_q16: int = 131072
## ABI-compatible profile fields. Native v16 fixes all three to five days and
## distributes cells across five deterministic daily phases.
@export_range(5, 5, 1) var market_cycle_days: int = 5
@export_range(5, 5, 1) var market_min_cycle_days: int = 5
@export_range(5, 5, 1) var market_max_cycle_days: int = 5
## Per-native-call cohort guard retained for custom tests. Production rolling
## settlement normally completes its entire due phase in one call.
@export_range(0, 1000000, 1000) var market_target_cohorts_per_slice: int = 0
@export_range(1, 1048576, 1) var commands_per_slice: int = 16384
@export_range(1, 32, 1) var max_rules_per_plan: int = 32
@export var worker_enabled: bool = true
@export_range(1, 100000, 1) var worker_market_threshold: int = 64
@export_range(0, 16, 1) var worker_tasks_hint: int = 0
## Upper bound for economy worker fan-out. Six tasks leaves headroom for the
## render/main thread on 8+ core desktop CPUs.
@export_range(1, 16, 1) var economy_worker_task_cap: int = 6
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
@export_range(0, 4294967296, 1) var starvation_death_rate_q32: int = 21474836
@export_range(0, 65536, 1) var wage_ema_alpha_q16: int = 8192
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
@export_range(1, 32, 1) var building_restart_cycles: int = 2
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
@export_range(1, 32, 1) var recovery_success_cycles: int = 2
@export_range(1, 64, 1) var recovery_liquidation_failed_reviews: int = 6
## Frozen-cycle Market V2 has passed the mobile and 10M-cohort ACTIVE gates.
@export_enum("OFF", "PROBE", "ACTIVE") var market_runtime_mode: String = "ACTIVE"

## Domestic cross-cell trade rolls out independently from the local market.
@export_enum("OFF", "PROBE", "ACTIVE") var trade_runtime_mode: String = "ACTIVE"
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
@export_range(1, 3650, 1) var investment_review_days: int = 10
@export_range(0, 65536, 1) var investment_min_shortage_q16: int = 8192
@export_range(0, 65536, 1) var investment_min_utilization_q16: int = 42598
@export_range(1, 36500, 1) var investment_max_payback_days: int = 365
@export_range(1, 12, 1) var investment_operating_cycles: int = 2
@export_range(1, 65536, 1) var investment_gap_fill_share_q16: int = 16384
@export_range(1, 4, 1) var investment_portfolio_max_types: int = 4
@export_range(1, 65536, 1) var investment_max_type_owner_share_q16: int = 32768
## Per review, an established building type may grow by at most 10% of its
## installed count. A previously absent type uses the separate seed limit.
@export_range(1, 65536, 1) var investment_max_growth_share_q16: int = 6554
@export_range(1, 1024, 1) var investment_new_type_seed_buildings: int = 1
## A non-merchant cohort only changes profession into merchant when its
## projected disposable-income improvement reaches this Q16 threshold.
@export_range(1, 65536, 1) var investment_merchant_transition_min_improvement_q16: int = 32768
@export_range(1, 65536, 1) var recovery_liquidation_max_share_q16: int = 16384
@export_range(0, 65536, 1) var resource_min_reserve_q16: int = 22938
@export_range(0, 65536, 1) var resource_safe_harvest_q16: int = 32768
@export_range(1, 365000, 1) var resource_min_horizon_days: int = 3650
@export_range(0, 65536, 1) var bullion_monthly_issue_cap_q16: int = 655
@export_range(0, 65536, 1) var producer_support_monthly_cap_q16: int = 3277

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
		"market_cycle_days": market_cycle_days,
		"market_min_cycle_days": market_min_cycle_days,
		"market_max_cycle_days": market_max_cycle_days,
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
		"wage_ema_alpha_q16": wage_ema_alpha_q16,
		"wage_max_rise_q16_per_day": wage_max_rise_q16_per_day,
		"wage_max_fall_q16_per_day": wage_max_fall_q16_per_day,
		"wage_income_cap_ratio_q16": wage_income_cap_ratio_q16,
		"employee_profit_share_q16": employee_profit_share_q16,
		"building_severe_loss_threshold_q16": building_severe_loss_threshold_q16,
		"building_severe_loss_cycles": building_severe_loss_cycles,
		"building_restart_margin_q16": building_restart_margin_q16,
		"building_restart_cycles": building_restart_cycles,
		"merchant_procurement_cash_reserve_q16": merchant_procurement_cash_reserve_q16,
		"merchant_market_making_days_q16": merchant_market_making_days_q16,
		"merchant_credit_runtime_mode": merchant_credit_runtime_mode,
		"merchant_credit_exposure_q16": merchant_credit_exposure_q16,
		"merchant_credit_premium_q16": merchant_credit_premium_q16,
		"merchant_credit_term_cycles": merchant_credit_term_cycles,
		"recovery_success_cycles": recovery_success_cycles,
		"recovery_liquidation_failed_reviews": recovery_liquidation_failed_reviews,
		"market_runtime_mode": market_runtime_mode,
		"trade_runtime_mode": trade_runtime_mode,
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
		"investment_min_shortage_q16": investment_min_shortage_q16,
		"investment_min_utilization_q16": investment_min_utilization_q16,
		"investment_max_payback_days": investment_max_payback_days,
		"investment_operating_cycles": investment_operating_cycles,
		"investment_gap_fill_share_q16": investment_gap_fill_share_q16,
		"investment_portfolio_max_types": investment_portfolio_max_types,
		"investment_max_type_owner_share_q16": investment_max_type_owner_share_q16,
		"investment_max_growth_share_q16": investment_max_growth_share_q16,
		"investment_new_type_seed_buildings": investment_new_type_seed_buildings,
		"investment_merchant_transition_min_improvement_q16": investment_merchant_transition_min_improvement_q16,
		"recovery_liquidation_max_share_q16": recovery_liquidation_max_share_q16,
		"resource_min_reserve_q16": resource_min_reserve_q16,
		"resource_safe_harvest_q16": resource_safe_harvest_q16,
		"resource_min_horizon_days": resource_min_horizon_days,
		"bullion_monthly_issue_cap_q16": bullion_monthly_issue_cap_q16,
		"producer_support_monthly_cap_q16": producer_support_monthly_cap_q16,
	}
