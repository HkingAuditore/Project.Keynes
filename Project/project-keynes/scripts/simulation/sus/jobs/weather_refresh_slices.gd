extends RefCounted

## Runs the weather job's sliced stages and publishes each completed report.


static func run_slice(owner: WeatherRefreshJob, ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if owner.generator == null or owner.map == null or owner.world == null:
		owner.ran_this_tick = false
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }
	# B8 唯一写者规则的第二道门：DCSystemScheduler 路径直接走 policy + run_slice，
	# 不会调用本 job 的 should_run。抑制必须放在真正干活的地方，否则天气链仍然在
	# worker writeback 之后把 MapData 天气场写回零。
	if owner.generator.has_method("climate_authority_suppressed") \
			and bool(owner.generator.climate_authority_suppressed()):
		owner.ran_this_tick = false
		return {
			"done": true,
			"work_done": 0,
			"elapsed_ms": 0.0,
			"stage_name": "weather_suppressed_by_climate_authority",
			"substage": "climate_worker_authoritative",
			"path": "suppressed",
		}

	# Prelude 计时：getter 调用、is_data_core_on 探测、can_slice_field has_method ×4。
	# 历史日志（2026-05-18）显示 unattributed=2.5~2.6ms，将该段独立 instrument
	# 以便后续诊断真凶（getter call 还是 has_method 链）。
	var t_prelude_us: int = Time.get_ticks_usec()
	var season_idx: int = 0
	if owner.season_index_getter.is_valid():
		season_idx = int(owner.season_index_getter.call())
	var season_phase: float = ctx.season_phase
	if owner.season_phase_getter.is_valid():
		season_phase = float(owner.season_phase_getter.call())
	var anomaly: float = 0.0
	if owner.climate_anomaly_getter.is_valid():
		anomaly = float(owner.climate_anomaly_getter.call())

	# C-02.3: 本次 run_slice 中是否启用 DataCore 镜像，仅查一次。
	# 避免两个 commit site 重复查 ClimateProfile 与 data_core_ready。
	var is_data_core_on: bool = owner._is_data_core_weather_enabled() and owner.data_core_ready()

	var can_slice_field: bool = owner.generator.has_method("weather_uses_field_solver") \
		and bool(owner.generator.weather_uses_field_solver()) \
		and owner.generator.has_method("begin_weather_refresh_stage_a") \
		and owner.generator.has_method("run_weather_refresh_stage_a_slice") \
		and owner.generator.has_method("commit_weather_refresh_stage_a")
	var prelude_ms: float = (Time.get_ticks_usec() - t_prelude_us) / 1000.0
	var timing: Dictionary = {
		"begin_stage_a_ms": 0.0,
		"run_stage_a_slice_ms": 0.0,
		"stage_a_direct_ms": 0.0,
		"commit_stage_a_ms": 0.0,
		"hydrology_discharge_ms": 0.0,
		"stage_b_outer_ms": 0.0,
		"sync_fronts_ms": 0.0,
		"soak_dump_ms": 0.0,
		"prelude_ms": prelude_ms,
	}
	var use_merged_native_weather: bool = owner._should_use_merged_native_weather(can_slice_field)
	owner._weather_rt_log(ctx, "entry", "can_slice=%s merged=%s dc=%s prelude=%.3f phase=%.3f" % [
		str(can_slice_field), str(use_merged_native_weather), str(is_data_core_on),
		prelude_ms, season_phase,
	])
	if use_merged_native_weather and not owner._merged_native_first_log_done:
		owner._merged_native_first_log_done = true
		print("[weather/native-daily] merged transaction ACTIVE — field/distribute/summary/stage_b run in one SUS slice; legacy sliced path remains fallback")

	# plan/weather-refresh-cpp-all PR-2：合并 facade 快路径。
	#
	# 当 _merged_native_gate_active=true 时，单 SUS slice 调 generator.refresh_weather_daily()
	# 把 5 段 cpp pass 一次跑完。返回的 fronts 与老链 stage_a + stage_b 完全语义一致；
	# 任何前置失败（flag off / ext null / cpp rc!=0）会在 generator.refresh_weather_daily
	# 内部透明 fallback 到 stage_a + stage_b 老链，所以本 job 这里只需关心"成功提交"
	# 后的状态同步：_last_fronts / _round_fronts / DataCore sync / soak dump / SUS timing publish。
	if use_merged_native_weather:
		owner.generator.merge_weather_job_breakdown({"weather_job_path": "merged"})
		var t_merged_us: int = Time.get_ticks_usec()
		var merged_fronts: Array[WeatherFront] = owner.generator.refresh_weather_daily(
			owner.map, owner.world, season_idx, anomaly, season_phase
		)
		# 用 stage_a_direct_ms 字段记录合并 path 的总耗时（"direct" 模式 = 单 slice
		# 完成全部，与 fallback 走 stage_a/stage_b 共用同一字段语义；perf overlay
		# 通过 _last_weather_breakdown.path == "gdext_combined" 区分两者）。
		timing["stage_a_direct_ms"] = (Time.get_ticks_usec() - t_merged_us) / 1000.0
		# Stage13b: ψ 推进已内联进 C++ solve pass(每轮 start_idx==0 全场一次)，不再走 GDScript 挂钩。
		owner._round_fronts = merged_fronts
		owner._round_active = false
		owner._round_stage = 0
		owner.ran_this_tick = true
		owner._fronts_changed_this_tick = owner._publish_fronts_if_changed(merged_fronts)

		if is_data_core_on and owner._fronts_changed_this_tick:
			var t_merged_sync_us: int = Time.get_ticks_usec()
			owner.sync_fronts_to_world(merged_fronts)
			timing["sync_fronts_ms"] = (Time.get_ticks_usec() - t_merged_sync_us) / 1000.0
		var t_merged_soak_us: int = Time.get_ticks_usec()
		owner._soak_dump_weather_phase(ctx, merged_fronts.size())
		timing["soak_dump_ms"] = (Time.get_ticks_usec() - t_merged_soak_us) / 1000.0

		var merged_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		owner._publish_job_timing(timing, merged_elapsed_ms, "weather_merged")
		var merged_report: Dictionary = {
			"done": true,
			"work_done": merged_fronts.size(),
			"elapsed_ms": merged_elapsed_ms,
			"progress_ratio": 1.0,
			"stage_name": "weather_merged",
			"substage": "fronts_%d" % merged_fronts.size(),
			"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
		}
		merged_report.merge(owner._last_fronts_diff_report, true)
		owner._publish_weather_lut_inline(ctx, merged_report, "merged")
		owner._weather_rt_log(ctx, "merged_done", "elapsed=%.3f changed_slots=%d" % [
			merged_elapsed_ms, int(owner._last_fronts_diff_report.get("changed_slots_count", 0)),
		])
		return merged_report

	if can_slice_field and not use_merged_native_weather:
		owner.generator.merge_weather_job_breakdown({"weather_job_path": "sliced"})
		var cell_budget: int = 500
		if owner.generator.has_method("weather_field_slice_cells"):
			cell_budget = int(owner.generator.weather_field_slice_cells())
		var round_cell_count: int = owner.map.cell_count() if owner.map != null and owner.map.has_method("cell_count") else 0
		var same_slice_full_round: bool = round_cell_count > 0 \
				and round_cell_count <= 6400 \
				and cell_budget >= round_cell_count
		if not owner._round_active:
			var t_begin_us: int = Time.get_ticks_usec()
			owner.generator.begin_weather_refresh_stage_a(owner.map, owner.world, season_idx, anomaly, season_phase)
			timing["begin_stage_a_ms"] = (Time.get_ticks_usec() - t_begin_us) / 1000.0
			owner._round_active = true
			owner._round_stage = 1
			owner._round_fronts = owner._last_fronts
			var begin_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
			owner._publish_job_timing(timing, begin_elapsed_ms, "weather_begin")
			owner._weather_rt_log(ctx, "begin", "elapsed=%.3f dc=%s" % [
				begin_elapsed_ms, str(is_data_core_on),
			])
			if not same_slice_full_round:
				return {
					"done": false,
					"work_done": 0,
					"elapsed_ms": begin_elapsed_ms,
					"progress_ratio": 0.10,
					"stage_name": "weather_begin",
					"substage": "init_round",
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
				}
		var slice_result: Dictionary = {}
		if owner._round_stage <= 1:
			var t_run_us: int = Time.get_ticks_usec()
			slice_result = owner.generator.run_weather_refresh_stage_a_slice(cell_budget)
			timing["run_stage_a_slice_ms"] = (Time.get_ticks_usec() - t_run_us) / 1000.0
			var slice_done: bool = bool(slice_result.get("done", true))
			var solve_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
			owner._publish_job_timing(timing, solve_elapsed_ms, "weather_solve")
			if not slice_done:
				owner._weather_rt_log(ctx, "solve", "elapsed=%.3f work=%d cursor=%d..%d progress=%.3f" % [
					solve_elapsed_ms,
					int(slice_result.get("work_done", 0)),
					int(slice_result.get("cursor_start", -1)),
					int(slice_result.get("cursor_end", -1)),
					float(slice_result.get("progress_ratio", 0.0)),
				])
				return {
					"done": false,
					"work_done": int(slice_result.get("work_done", 0)),
					"elapsed_ms": solve_elapsed_ms,
					"progress_ratio": maxf(0.10, float(slice_result.get("progress_ratio", 0.0))),
					"stage_name": "weather_solve",
					"substage": "cells_%d" % int(slice_result.get("work_done", 0)),
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
					"processed_cells": int(slice_result.get("processed_cells", slice_result.get("work_done", 0))),
					"cursor_start": int(slice_result.get("cursor_start", -1)),
					"cursor_end": int(slice_result.get("cursor_end", -1)),
				}
			owner._round_stage = 2
			owner._weather_rt_log(ctx, "solve_done", "elapsed=%.3f work=%d cursor=%d..%d" % [
				solve_elapsed_ms,
				int(slice_result.get("work_done", 0)),
				int(slice_result.get("cursor_start", -1)),
				int(slice_result.get("cursor_end", -1)),
			])
			if not same_slice_full_round:
				return {
					"done": false,
					"work_done": int(slice_result.get("work_done", 0)),
					"elapsed_ms": solve_elapsed_ms,
					"progress_ratio": 0.70,
					"stage_name": "weather_solve",
					"substage": "cells_done",
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
					"processed_cells": int(slice_result.get("processed_cells", slice_result.get("work_done", 0))),
					"cursor_start": int(slice_result.get("cursor_start", -1)),
					"cursor_end": int(slice_result.get("cursor_end", -1)),
				}
		if owner._round_stage == 2:
			var t_commit_us: int = Time.get_ticks_usec()
			var committed_fronts: Array[WeatherFront] = owner.generator.commit_weather_refresh_stage_a(owner.map, owner.world)
			timing["commit_stage_a_ms"] = (Time.get_ticks_usec() - t_commit_us) / 1000.0
			var summary_lut_report: Dictionary = owner.generator._last_weather_breakdown if owner.generator != null and owner.generator.get("_last_weather_breakdown") != null else {}
			owner._publish_weather_lut_inline(ctx, summary_lut_report, "summary")

			owner._round_fronts = committed_fronts
			# Stage13b: ψ 推进已内联进 C++ solve pass(每轮 start_idx==0 全场一次)，不再走 GDScript 挂钩。
			owner._round_stage = 3
			var commit_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
			owner._publish_job_timing(timing, commit_elapsed_ms, "weather_summary")
			owner._weather_rt_log(ctx, "summary", "elapsed=%.3f fronts=%d" % [
				commit_elapsed_ms, committed_fronts.size(),
			])
			if not same_slice_full_round:
				return {
					"done": false,
					"work_done": committed_fronts.size(),
					"elapsed_ms": commit_elapsed_ms,
					"progress_ratio": 0.85,
					"stage_name": "weather_summary",
					"substage": "fronts_%d" % committed_fronts.size(),
					"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
				}
		if owner._round_stage == 3:
			var hydrology_enabled: bool = owner.generator.has_method("runtime_hydrology_enabled") \
					and bool(owner.generator.runtime_hydrology_enabled())
			if hydrology_enabled:
				var t_hydro_us: int = Time.get_ticks_usec()
				var hydro_report: Dictionary = owner.generator.run_hydrology_discharge_pass_native(owner.map, owner.world)
				timing["hydrology_discharge_ms"] = (Time.get_ticks_usec() - t_hydro_us) / 1000.0
				owner._round_stage = 4
				var hydro_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
				owner._publish_job_timing(timing, hydro_elapsed_ms, "hydrology_discharge")
				hydro_report["done"] = false
				hydro_report["elapsed_ms"] = hydro_elapsed_ms
				hydro_report["progress_ratio"] = 0.92
				hydro_report["stage_name"] = "hydrology_discharge"
				hydro_report["substage"] = "route_full"
				owner._weather_rt_log(ctx, "hydrology", "elapsed=%.3f q95=%.4f qmax=%.4f budget=%.5f" % [
					hydro_elapsed_ms,
					float(hydro_report.get("river_discharge_p95", 0.0)),
					float(hydro_report.get("river_discharge_max", 0.0)),
					float(hydro_report.get("water_budget_error", 0.0)),
				])
				if not same_slice_full_round:
					return hydro_report
			owner._round_stage = 4
		var t_stage_b_us: int = Time.get_ticks_usec()
		owner.generator.refresh_daily_stage_b(owner.map, owner.world)
		timing["stage_b_outer_ms"] = (Time.get_ticks_usec() - t_stage_b_us) / 1000.0
		var sliced_fronts: Array[WeatherFront] = owner._round_fronts
		owner._round_active = false
		owner._round_stage = 0
		owner.ran_this_tick = true
		owner._fronts_changed_this_tick = owner._publish_fronts_if_changed(sliced_fronts)
		# DataCore step 2：正路径 commit 完成，镜像 front 到 World（开关 ON 才生效）。
		# C-02.3：复用 run_slice 入口缓存的 is_data_core_on。
		if is_data_core_on and owner._fronts_changed_this_tick:
			var t_sync_us: int = Time.get_ticks_usec()
			owner.sync_fronts_to_world(sliced_fronts)
			timing["sync_fronts_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
		var t_soak_us: int = Time.get_ticks_usec()
		owner._soak_dump_weather_phase(ctx, sliced_fronts.size())
		timing["soak_dump_ms"] = (Time.get_ticks_usec() - t_soak_us) / 1000.0
		var sliced_elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		owner._publish_job_timing(timing, sliced_elapsed_ms, "weather_commit")
		var sliced_report: Dictionary = {
			"done": true,
			"work_done": sliced_fronts.size(),
			"elapsed_ms": sliced_elapsed_ms,
			"progress_ratio": 1.0,
			"stage_name": "weather_commit",
			"substage": "fronts_%d" % sliced_fronts.size(),
			"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
		}
		sliced_report.merge(owner._last_fronts_diff_report, true)
		owner._weather_rt_log(ctx, "commit", "elapsed=%.3f changed_slots=%d" % [
			sliced_elapsed_ms, int(owner._last_fronts_diff_report.get("changed_slots_count", 0)),
		])
		return sliced_report

	var t_direct_a_us: int = Time.get_ticks_usec()
	owner.generator.merge_weather_job_breakdown({"weather_job_path": "direct"})
	var fronts: Array[WeatherFront] = owner.generator.refresh_daily_stage_a(owner.map, owner.world, season_idx, anomaly, season_phase)
	timing["stage_a_direct_ms"] = (Time.get_ticks_usec() - t_direct_a_us) / 1000.0
	if owner.generator.has_method("runtime_hydrology_enabled") and bool(owner.generator.runtime_hydrology_enabled()):
		var t_direct_hydro_us: int = Time.get_ticks_usec()
		owner.generator.run_hydrology_discharge_pass_native(owner.map, owner.world)
		timing["hydrology_discharge_ms"] = (Time.get_ticks_usec() - t_direct_hydro_us) / 1000.0
	var t_direct_b_us: int = Time.get_ticks_usec()
	owner.generator.refresh_daily_stage_b(owner.map, owner.world)
	timing["stage_b_outer_ms"] = (Time.get_ticks_usec() - t_direct_b_us) / 1000.0

	owner._round_fronts = fronts
	# 合并模式不再有"半成品 round"——_round_active 始终为 false。
	owner._round_active = false
	owner._round_stage = 0
	owner.ran_this_tick = true
	owner._fronts_changed_this_tick = owner._publish_fronts_if_changed(fronts)
	# DataCore step 2：同步镜像。C-02.3：复用 run_slice 入口缓存的 is_data_core_on。
	if is_data_core_on and owner._fronts_changed_this_tick:
		var t_direct_sync_us: int = Time.get_ticks_usec()
		owner.sync_fronts_to_world(fronts)
		timing["sync_fronts_ms"] = (Time.get_ticks_usec() - t_direct_sync_us) / 1000.0
	var t_direct_soak_us: int = Time.get_ticks_usec()
	owner._soak_dump_weather_phase(ctx, fronts.size())
	timing["soak_dump_ms"] = (Time.get_ticks_usec() - t_direct_soak_us) / 1000.0
	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	owner._publish_job_timing(timing, elapsed_ms, "weather_direct")
	var direct_report: Dictionary = {
		"done": true,
		"work_done": fronts.size(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"stage_name": "weather_direct",
		"substage": "fronts_%d" % fronts.size(),
		"path": "data_core_cells_only" if is_data_core_on else "dc_not_ready",
	}
	direct_report.merge(owner._last_fronts_diff_report, true)
	owner._publish_weather_lut_inline(ctx, direct_report, "direct")
	owner._weather_rt_log(ctx, "direct", "elapsed=%.3f changed_slots=%d" % [
		elapsed_ms, int(owner._last_fronts_diff_report.get("changed_slots_count", 0)),
	])
	return direct_report
