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
@export var treasury_cash: int = 0
@export var merchant_profession_id: StringName = &"merchant"
@export var wealth_reference_per_capita: int = 100000
## Frozen-cycle Market V2 has passed the mobile and 10M-cohort ACTIVE gates.
@export_enum("OFF", "PROBE", "ACTIVE") var market_runtime_mode: String = "ACTIVE"

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
		"treasury_cash": treasury_cash,
		"merchant_profession_id": String(merchant_profession_id),
		"wealth_reference_per_capita": wealth_reference_per_capita,
		"market_runtime_mode": market_runtime_mode,
	}
