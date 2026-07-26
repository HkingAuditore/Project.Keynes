extends DCSystem
class_name EconomyDailySystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")

var facade = null
var world_clock: WorldClock = null
var _last_report: Dictionary = {}
var _fatal_reported: bool = false

func _init(p_facade, p_world_clock: WorldClock = null) -> void:
	id = &"economy_daily"
	priority = 260
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	use_job_deadline_critical = true
	starvation_threshold = 2
	slice_budget_ms = 0.8
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade
	world_clock = p_world_clock

func feature_flag() -> StringName:
	return &""

func declare_reads() -> Array[StringName]:
	var reads: Array[StringName] = [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_SNOW_COVER,
		DCComponentIds.CELL_WEATHER_INTENSITY,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_HAS_RIVER,
	]
	for profile in ResourceRegistryScript.ordered():
		reads.append(profile.reserve_component)
	return reads

func should_run(ctx: SusTickContext) -> bool:
	if facade == null or not facade.is_configured():
		return false
	var ext: Object = facade.world_ext()
	return ext != null and ext.has_method("economy_should_run") \
		and bool(ext.economy_should_run(ctx.day_index))


func is_deadline_critical(ctx: SusTickContext) -> bool:
	if facade == null or not facade.is_configured() or ctx == null:
		return false
	var report: Dictionary = facade.report()
	if bool(report.get("epoch_active", false)):
		return int(ctx.day_index) >= int(
			report.get("cycle_deadline_day", 9223372036854775807))
	# One phase is due every simulation day. Skipping the first eligible call
	# would make that phase older than the rolling four-day visibility bound.
	return int(ctx.day_index) > int(report.get("newest_state_day", -1))

func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if facade == null or not facade.is_configured():
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "stage_name": "economy_unavailable"}
	var native_ctx := {
		"day_index": int(ctx.day_index) if ctx != null else 0,
		"tick_index": int(ctx.tick_index) if ctx != null else 0,
		"speed_scale": float(ctx.speed_scale) if ctx != null else 1.0,
		"slice_budget_ms": slice_budget_ms,
	}
	var ext: Object = facade.world_ext()
	var compact_slice: bool = ctx != null and \
		ctx.source == &"country_economy_continuation" and \
		ext.has_method("run_economy_slice_compact")
	var result: Dictionary = ext.run_economy_slice_compact(native_ctx) if compact_slice \
		else ext.run_economy_slice(native_ctx)
	# Full slice reports are newly allocated native dictionaries and remain
	# immutable after this boundary. Continuations keep the last full diagnostic
	# snapshot so their compact report does not erase recorder/UI fields.
	if not compact_slice or bool(result.get("fatal", false)):
		_last_report = result
		_last_report["_tick_idx"] = int(ctx.tick_index) if ctx != null else -1
	if facade.has_method("dispatch_committed_events"):
		facade.dispatch_committed_events(result)
	var over_budget := bool(result.get("commit_over_budget", false))
	# A multi-day frozen cycle is expected to remain in-flight while the world
	# advances. Only stop the calendar at its settlement deadline (or on fatal),
	# then use real-frame continuation pulses to finish any missed slices.
	var commit_due := bool(result.get("commit_due", false))
	var boundary_continuation := bool(
		result.get("boundary_continuation_required", false))
	var day_barrier := bool(result.get("fatal", false)) or (
		not bool(result.get("done", true)) and (commit_due or boundary_continuation))
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"economy", over_budget)
		world_clock.request_simulation_backpressure(&"economy_day_barrier", day_barrier)
	if bool(result.get("fatal", false)) and not _fatal_reported:
		_fatal_reported = true
		push_error("[economy_daily] native economy paused: %s" % String(result.get("fatal_reason", "unknown")))
	var executed_stage := String(result.get(
		"executed_stage", result.get("stage", "economy_daily")))
	var executed_substage := String(result.get("executed_substage", ""))
	if executed_substage.is_empty() and executed_stage == "trade_planning":
		executed_substage = String(result.get("trade_plan_substage", ""))
	var stage_breakdown_ms: Dictionary = result.get("trade_plan_breakdown_ms", {})
	var stage_breakdown_work: Dictionary = result.get("trade_plan_breakdown_work", {})
	if executed_stage == "aggregate_publish":
		stage_breakdown_ms = result.get("publish_breakdown_ms", {})
		stage_breakdown_work = result.get("publish_breakdown_work", {})
	elif executed_stage == "building_commit":
		stage_breakdown_ms = result.get("building_commit_breakdown_ms", {})
		stage_breakdown_work = result.get("building_commit_breakdown_work", {})
	return {
		"done": bool(result.get("done", true)),
		"work_done": int(result.get("work_done", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
		"progress_ratio": float(result.get("progress_q16", 65535)) / 65536.0,
		"stage_name": executed_stage,
		"next_stage": String(result.get("next_stage", result.get("stage", ""))),
		"substage": executed_substage,
		"stage_breakdown_ms": stage_breakdown_ms,
		"stage_breakdown_work": stage_breakdown_work,
		"path": String(result.get("path", "ECONOMY_GRAPH")),
		"cursor_start": int(result.get("cursor_start", 0)),
		"cursor_end": int(result.get("cursor_end", 0)),
		"chunks_completed": int(result.get("chunks_completed", 0)),
		"phase_fusions": int(result.get("phase_fusions", 0)),
		"yield_reason": String(result.get("yield_reason", "")),
		"native_slice_budget_ms": float(result.get("slice_budget_ms", slice_budget_ms)),
		"budget_overrun_ms": float(result.get("budget_overrun_ms", 0.0)),
		"processed_cells": int(result.get("processed_cells", 0)),
		"processed_cohorts": int(result.get("processed_cohorts", 0)),
		"processed_rules": int(result.get("processed_rules", 0)),
		"settlement_phase": int(result.get("settlement_phase", -1)),
		"due_cells": int(result.get("due_cells", 0)),
		"processed_due_cells": int(result.get("processed_due_cells", 0)),
		"deferred_cells": int(result.get("deferred_cells", 0)),
		"settlement_watermark": int(result.get("settlement_watermark", -1)),
		"max_state_age_days": int(result.get("max_state_age_days", 0)),
		"commit_over_budget": over_budget,
		"commit_due": commit_due,
		"boundary_continuation_required": boundary_continuation,
		"market_cycle_days": int(result.get("market_cycle_days", 1)),
		"market_configured_cycle_days": int(
			result.get("market_configured_cycle_days", 0)),
		"estimated_market_slices_per_epoch": int(
			result.get("estimated_market_slices_per_epoch", 0)),
		"estimated_building_slices_per_epoch": int(
			result.get("estimated_building_slices_per_epoch", 0)),
		"estimated_total_slices_per_epoch": int(
			result.get("estimated_total_slices_per_epoch", 0)),
		"workload_deadline_feasible": bool(
			result.get("workload_deadline_feasible", true)),
		"workload_cycle_clamped": bool(result.get("workload_cycle_clamped", false)),
		"fatal": bool(result.get("fatal", false)),
	}

func last_report() -> Dictionary:
	return _last_report.duplicate(true)


func last_perf_report() -> Dictionary:
	if _last_report.is_empty():
		return {}
	var out: Dictionary = {"_tick_idx": int(_last_report.get("_tick_idx", -1))}
	for key in [
		"elapsed_ms", "executed_stage", "executed_substage", "next_stage",
		"work_done", "cursor_start", "cursor_end", "processed_cells",
		"processed_cohorts", "processed_building_groups", "worker_tasks",
		"building_production_worker_tasks", "market_worker_tasks_max",
			"market_worker_task_sum", "market_worker_dispatches",
			"high_speed_batching_enabled", "high_speed_batch_multiplier",
			"high_speed_market_dispatches_saved",
			"high_speed_production_dispatches_saved",
		"building_production_worker_tasks_max",
		"building_production_worker_task_sum",
		"building_production_worker_dispatches", "epoch_begin_ms",
		"epoch_preflight_ms", "prepare_ms", "audit_ms", "watermark_ms",
		"building_plan_ms", "building_plan_evaluate_ms",
		"building_plan_reserve_ms", "building_employment_ms",
		"building_production_ms", "building_production_worker_ms",
		"building_production_merge_ms", "building_investment_ms",
		"household_market_worker_ms", "household_market_merge_ms",
		"household_market_merge_aggregate_ms",
		"household_market_merge_trade_ms", "market_signal_insert_ms",
		"market_signal_flush_ms", "market_signal_insert_count",
		"market_signal_lookup_mode", "market_signal_lookup_entries",
		"pending_construction_index_entries",
		"market_result_allocation_growth_count",
		"market_result_allocation_growth_bytes",
		"production_result_allocation_growth_count",
		"production_result_allocation_growth_bytes", "publish_ms",
		"building_commit_breakdown_ms", "building_commit_breakdown_work",
			"memory_bytes", "population_error", "money_error", "goods_error",
			"closing_audit_mode", "closing_audit_runtime_disabled",
			"closing_audit_fast_paths", "closing_audit_full_verifications",
			"closing_audit_mismatches",
			"closing_audit_mismatch_ledger", "closing_audit_mismatch_lane",
			"closing_audit_population_touched_lanes",
			"closing_audit_market_touched_lanes",
			"closing_audit_population_full_scan_entries",
			"closing_audit_market_full_scan_entries",
			"investment_scheduled_review_cells", "investment_review_cells",
			"approximation_probe_violations",
			"approximation_probe_max_spend_error_q16",
			"approximation_probe_max_demand_error_q16",
			"approximation_cooldown_epochs_left",
			"investment_sparse_dense_fallbacks",
		"saturation_count", "continuation_slices", "due_cells",
		"processed_due_cells", "deferred_cells", "max_state_age_days",
		"last_completed_perf_valid", "last_completed_epoch_id",
		"last_completed_sample_day", "last_completed_continuation_slices",
		"last_completed_market_worker_tasks_max",
		"last_completed_market_worker_task_sum",
			"last_completed_market_worker_dispatches",
			"last_completed_high_speed_batch_multiplier",
			"last_completed_high_speed_market_dispatches_saved",
			"last_completed_high_speed_production_dispatches_saved",
		"last_completed_building_production_worker_tasks_max",
		"last_completed_building_production_worker_task_sum",
		"last_completed_building_production_worker_dispatches",
		"last_completed_building_plan_ms",
		"last_completed_building_plan_evaluate_ms",
		"last_completed_building_plan_reserve_ms",
		"last_completed_building_employment_ms",
		"last_completed_building_production_ms",
		"last_completed_building_production_worker_ms",
		"last_completed_building_production_merge_ms",
		"last_completed_household_market_worker_ms",
		"last_completed_household_market_merge_ms",
		"last_completed_household_market_merge_aggregate_ms",
		"last_completed_household_market_merge_trade_ms",
		"last_completed_building_investment_ms",
		"last_completed_aggregate_publish_ms",
			"last_completed_aggregate_audit_ms",
			"last_completed_closing_audit_fast_paths",
			"last_completed_closing_audit_full_verifications",
			"last_completed_closing_audit_mismatches",
			"last_completed_closing_audit_mismatch_ledger",
			"last_completed_closing_audit_mismatch_lane",
			"last_completed_closing_audit_population_touched_lanes",
			"last_completed_closing_audit_market_touched_lanes",
			"last_completed_closing_audit_population_full_scan_entries",
			"last_completed_closing_audit_market_full_scan_entries",
			"last_completed_investment_scheduled_review_cells",
			"last_completed_approximation_probe_violations",
			"last_completed_approximation_probe_max_spend_error_q16",
			"last_completed_approximation_probe_max_demand_error_q16",
			"last_completed_approximation_cooldown_epochs_left",
			"last_completed_investment_sparse_dense_fallbacks",
		"last_completed_market_result_allocation_growth_count",
		"last_completed_market_result_allocation_growth_bytes",
		"last_completed_production_result_allocation_growth_count",
		"last_completed_production_result_allocation_growth_bytes",
		"last_completed_building_structure_count_only_updates",
		"last_completed_building_structure_new_groups",
		"last_completed_building_structure_removed_groups",
		"last_completed_building_structure_topology_rebuilds",
		"last_completed_building_structure_role_span_reuses",
		"last_completed_building_structure_role_span_appends",
		"last_completed_building_structure_group_merge_ms",
		"last_completed_building_structure_market_cache_ms",
		"last_completed_building_structure_labor_cache_ms",
	]:
		if _last_report.has(key):
			out[key] = _last_report[key]
	return out

func reset_progress() -> void:
	super.reset_progress()
	_last_report.clear()
	_fatal_reported = false
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"economy", false)
		world_clock.request_simulation_backpressure(&"economy_day_barrier", false)
