class_name EconomyProfile
extends Resource

## Numeric scales are save-format ABI and must match the native constants.
@export var money_scale: int = 10000
@export var goods_scale: int = 1000
@export var ratio_scale: int = 65536
@export var rate_scale: int = 4294967296

@export_range(1, 65536, 1) var cells_per_slice: int = 5000
@export var auto_slice_by_scale: bool = true
## Production defaults to a five-day settlement cycle. Set 0 for cohort-budget auto cadence.
@export_range(0, 3650, 1) var market_cycle_days: int = 5
@export_range(1, 3650, 1) var market_max_cycle_days: int = 365
## Dominant hot-loop budget. Auto cadence targets at most this many cohorts
## per simulation-day market slice, then settles all N-day totals together.
## 0 selects 4k/12k/30k automatically for small/medium/large worlds.
@export_range(0, 1000000, 1000) var market_target_cohorts_per_slice: int = 0
@export_range(1, 1048576, 1) var commands_per_slice: int = 16384
@export_range(1, 32, 1) var max_rules_per_plan: int = 32
@export var worker_enabled: bool = true
@export_range(1, 100000, 1) var worker_market_threshold: int = 64
@export_range(0, 16, 1) var worker_tasks_hint: int = 0
@export_range(65536, 16777216, 65536) var save_chunk_bytes: int = 4194304
## Economy event journal keeps compact summaries globally and exact delta legs
## only for explicitly traced cells. Handlers consume committed batches.
@export_enum("OFF", "SUMMARY", "SELECTIVE", "FULL_DEBUG") var economy_trace_mode: String = "SELECTIVE"
@export_range(1048576, 1073741824, 1048576) var economy_trace_memory_bytes: int = 33554432
@export_range(1, 3650, 1) var economy_trace_retention_epochs: int = 8
@export_range(65536, 268435456, 65536) var economy_trace_detail_epoch_bytes: int = 8388608
@export_range(1, 65536, 1) var economy_trace_poll_max_events: int = 4096
@export var merchant_profession_id: StringName = &"merchant"
@export var wealth_reference_per_capita: int = 100000
@export var living_cost_base_plan_id: StringName = &"subsistence_household"
@export_range(0, 65536, 1) var wage_ema_alpha_q16: int = 8192
@export_range(0, 65536, 1) var wage_max_rise_q16_per_day: int = 6554
@export_range(0, 65536, 1) var wage_max_fall_q16_per_day: int = 1311
@export_range(0, 65536, 1) var employee_profit_share_q16: int = 16384
## Frozen-cycle Market V2 has passed the mobile and 10M-cohort ACTIVE gates.
@export_enum("OFF", "PROBE", "ACTIVE") var market_runtime_mode: String = "ACTIVE"

## Domestic cross-cell trade rolls out independently from the local market.
@export_enum("OFF", "PROBE", "ACTIVE") var trade_runtime_mode: String = "PROBE"
@export_range(1, 2147483647, 1) var trade_capacity_per_merchant_q16: int = 4194304
@export_range(1, 1000000, 1) var trade_speed_cost_per_day: int = 4
@export_range(0, 65536, 1) var trade_min_margin_q16: int = 3277
@export_range(1, 8, 1) var trade_target_count: int = 4
@export_range(256, 1048576, 256) var trade_signal_pairs_per_slice: int = 16384
@export_range(1, 64, 1) var trade_route_searches_per_slice: int = 2
@export_range(64, 1000000, 64) var trade_max_route_expansions: int = 8192
@export_range(64, 4194304, 64) var trade_route_cache_entries: int = 16384
@export_range(64, 1048576, 64) var trade_max_signals: int = 32768
@export_range(16, 1048576, 16) var trade_max_candidates: int = 8192
@export_range(16, 1048576, 16) var trade_max_orders: int = 4096
@export_range(0, 65536, 1) var trade_flow_ema_alpha_q16: int = 8192
@export_range(1, 65536, 1) var trade_max_stock_share_q16: int = 16384

func to_native_profile() -> Dictionary:
	return {
		"money_scale": money_scale,
		"goods_scale": goods_scale,
		"ratio_scale": ratio_scale,
		"rate_scale": rate_scale,
		"cells_per_slice": cells_per_slice,
		"auto_slice_by_scale": auto_slice_by_scale,
		"market_cycle_days": market_cycle_days,
		"market_max_cycle_days": market_max_cycle_days,
		"market_target_cohorts_per_slice": market_target_cohorts_per_slice,
		"commands_per_slice": commands_per_slice,
		"max_rules_per_plan": max_rules_per_plan,
		"worker_enabled": worker_enabled,
		"worker_market_threshold": worker_market_threshold,
		"worker_tasks_hint": worker_tasks_hint,
		"economy_trace_mode": economy_trace_mode,
		"economy_trace_memory_bytes": economy_trace_memory_bytes,
		"economy_trace_retention_epochs": economy_trace_retention_epochs,
		"economy_trace_detail_epoch_bytes": economy_trace_detail_epoch_bytes,
		"economy_trace_poll_max_events": economy_trace_poll_max_events,
		"merchant_profession_id": String(merchant_profession_id),
		"wealth_reference_per_capita": wealth_reference_per_capita,
		"living_cost_base_plan_id": String(living_cost_base_plan_id),
		"wage_ema_alpha_q16": wage_ema_alpha_q16,
		"wage_max_rise_q16_per_day": wage_max_rise_q16_per_day,
		"wage_max_fall_q16_per_day": wage_max_fall_q16_per_day,
		"employee_profit_share_q16": employee_profit_share_q16,
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
	}
