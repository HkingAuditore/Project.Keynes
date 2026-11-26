extends RefCounted

## Coordinates the daily wind and physical circulation stages.


static func _run_daily_wind_prepass(owner: OceanCurrentsJob, ctx: SusTickContext) -> Dictionary:
	if ctx.tick_index == owner._last_daily_wind_tick:
		return owner._last_daily_wind_report.duplicate(true)
	var phase_now: float = owner._current_phase(ctx)
	var stage: String = owner._daily_wind_stage_for(ctx)
	var report: Dictionary = {
		"ran": false,
		"path": "daily_wind_skip",
		"elapsed_ms": 0.0,
		"fallback_reason": "",
	}
	if owner.baker == null or owner.world == null or owner.map == null or owner.cfg == null:
		report["fallback_reason"] = "missing_refs"
	elif not owner.baker._use_physical_circulation(owner.cfg):
		report["path"] = "daily_wind_disabled"
		report["fallback_reason"] = "physical_disabled"
	elif not owner.baker.has_method("run_daily_wind_field_update"):
		report["fallback_reason"] = "missing_baker_method"
	else:
		report = owner.baker.run_daily_wind_field_update(
				owner.map, owner.world, owner.cfg, owner.hex_size, phase_now, ctx.day_index, stage)
		if typeof(report) != TYPE_DICTIONARY:
			report = {
				"ran": false,
				"path": "daily_wind_bad_report",
				"elapsed_ms": 0.0,
				"fallback_reason": "non_dict_report",
			}
	report["tick_idx"] = ctx.tick_index
	report["day_index"] = ctx.day_index
	report["season_phase"] = phase_now
	report["due"] = true
	report["stage_requested"] = stage
	report["due_seq"] = owner._daily_wind_due_seq
	owner._last_daily_wind_tick = ctx.tick_index
	owner._daily_wind_due_seq += 1
	owner._last_daily_wind_report = report.duplicate(true)
	if PKLog.enabled and owner._daily_wind_rt_diag_count < owner._ocean_rt_log_budget():
		owner._daily_wind_rt_diag_count += 1
		print("[ocean_currents][daily_wind] #%d tick=%d stage=%s ran=%s path=%s elapsed=%.3f slp=%.3f wind=%.3f passA=%.3f passB=%.3f norm=%.3f marshall=%.3f dominant=%s/%.3f delta=%.6f reason=%s" % [
			owner._daily_wind_rt_diag_count,
			ctx.tick_index,
			stage,
			str(report.get("ran", false)),
			str(report.get("path", "")),
			float(report.get("elapsed_ms", 0.0)),
			float(report.get("slp_ms", -1.0)),
			float(report.get("wind_ms", -1.0)),
			float(report.get("slp_passA_ms", -1.0)),
			float(report.get("slp_passB_ms", -1.0)),
			float(report.get("slp_norm_ms", -1.0)),
			float(report.get("slp_marshall_ms", -1.0)),
			str(report.get("dominant_stage", "")),
			float(report.get("dominant_stage_ms", 0.0)),
			float(report.get("wind_delta_p95", 0.0)),
			str(report.get("fallback_reason", "")),
		])
	return report



static func _should_run_ocean_this_round(owner: OceanCurrentsJob, ctx: SusTickContext) -> bool:
	if owner.baker == null or not owner.baker._use_physical_circulation(owner.cfg):
		return true
	if owner._phase_int_seen == owner._NO_VISUAL_PHASE:
		return true
	return (ctx.tick_index % max(1, owner.ocean_period_ticks)) == 0



static func _begin_physical_round(owner: OceanCurrentsJob, ctx: SusTickContext, daily_report: Dictionary) -> Dictionary:
	owner._visual_total_pixels = owner._total_pixels_for(owner.world)
	if owner._visual_total_pixels <= 0:
		return {
			"ok": false,
			"report": {
				"done": true,
				"work_done": 0,
				"elapsed_ms": 0.0,
				"stage_name": "ocean_no_pixels",
				"path": "no_pixels",
			},
		}
	owner._phys_phase_locked = owner._current_phase(ctx)
	owner._phase_locked = owner._phys_phase_locked
	owner._phys_round_active = true
	owner._phys_solve_done = not owner.baker._use_physical_circulation(owner.cfg)
	owner._phys_run_ocean_this_round = owner._should_run_ocean_this_round(ctx)
	owner._physical_round_id += 1
	if not owner._phys_solve_done:
		var primed_from_daily_wind: bool = false
		if owner._daily_wind_report_has_wind(daily_report) \
				and owner.baker.has_method("prime_physical_solve_from_current_wind"):
			primed_from_daily_wind = owner.baker.prime_physical_solve_from_current_wind(owner.map, owner._phys_phase_locked)
		if not primed_from_daily_wind and owner.baker.has_method("reset_physical_solve_state"):
			owner.baker.reset_physical_solve_state()
	var phase_int: int = int(floor(owner._phys_phase_locked))
	if owner.baker._use_physical_circulation(owner.cfg):
		owner._phys_need_visual = owner._phys_run_ocean_this_round \
				and (owner._phase_int_seen == owner._NO_VISUAL_PHASE or phase_int != owner._phase_int_seen)
		if owner._phys_run_ocean_this_round:
			owner._phase_int_seen = phase_int
	else:
		owner._phys_need_visual = true
		owner._phase_int_seen = phase_int
	# Mobile 60 FPS（Fix #1, 2026-06-15）：每次 phase_int 跨整数都 rebake ocean
	# 像素 atlas 是 frame=2412 起 non_sus_frame_avg 8→22ms 的直接原因
	#   （atlas 一旦可见，hex_terrain shader 多采样 dyn/eco/smo/ice 4 张 RGBA8
	#   512×304，移动端 fragment bandwidth 翻 3 倍）。
	# 移动端策略：只允许首次 bake 一次（让 shader 拿到非全黑的 ocean overlay
	#   纹理避免 NaN），后续物理 solve 继续运行（authority 保留在 cell_ocean_*）
	#   但视觉层不再 rebake → primitives 7096 → 1644，non_sus 22ms → 8ms。
	# 桌面端不动。
	if owner._phys_need_visual and OS.has_feature("mobile") and owner._phase_int_seen != owner._NO_VISUAL_PHASE \
			and owner._visual_round_id > 0:
		owner._phys_need_visual = false
	# [ocean-visual-skip 2026-06-16] ocean_current_visual 开关关 → 永不做逐像素视觉
	# 光栅 / commit（vector_atlas 是纯视觉 overlay）。need_visual=false 时本 round 求解
	# 完成即 round_done（见下方 stage 推进），跳过 stage 7 WIND_RASTER + pixel slices +
	# commit_ocean_buffers。per-cell SLP/风/洋流 solve（上方 stages + daily_wind prepass）
	# 照常跑并写 HexCell，气候/天气仿真完全不受影响。
	if owner._phys_need_visual and not DCFeatureFlags.ocean_current_visual_active():
		owner._phys_need_visual = false
	owner._sync_legacy_round_state()
	if PKLog.enabled and owner._ocean_rt_diag_count < owner._ocean_rt_log_budget():
		var tps: int = 0
		if owner._slow_slice_policy != null and owner._slow_slice_policy.has_method("ticks_per_slice"):
			tps = int(owner._slow_slice_policy.ticks_per_slice())
		print("[ocean_currents][RT] phys_round_start#%d tick=%d phase=%.4f physical=%s wind_period=%d ocean_period=%d slice_count=%d tps=%d max_slices=%d run_ocean=%s need_visual=%s phase_int=%d phase_seen=%d total_pixels=%d visual_active=%s" % [
			owner._physical_round_id, ctx.tick_index, owner._phys_phase_locked,
			str(owner.baker._use_physical_circulation(owner.cfg)), owner.wind_period_ticks, owner.ocean_period_ticks,
			owner.slice_count, tps, owner.max_slices_per_tick, str(owner._phys_run_ocean_this_round),
			str(owner._phys_need_visual), phase_int, owner._phase_int_seen, owner._visual_total_pixels,
			str(owner._visual_round_active),
		])
	owner._native_ocean_physical_begin(ctx)
	return {"ok": true}



static func _daily_wind_report_has_wind(owner: OceanCurrentsJob, daily_report: Dictionary) -> bool:
	return not daily_report.is_empty() \
			and bool(daily_report.get("ran", false)) \
			and bool(daily_report.get("wind_ran", false)) \
			and str(daily_report.get("fallback_reason", "")) == ""



static func _try_prime_physical_wind_from_daily(owner: OceanCurrentsJob, daily_report: Dictionary, phys_stage_before: int) -> Dictionary:
	var diag: Dictionary = {
		"phys_wind_dedupe_attempted": false,
		"phys_wind_dedupe_applied": false,
		"phys_wind_skipped_reason": "",
	}
	if phys_stage_before != 2:
		return diag
	if not owner._daily_wind_report_has_wind(daily_report):
		diag["phys_wind_skipped_reason"] = "daily_wind_not_available"
		return diag
	diag["phys_wind_dedupe_attempted"] = true
	if owner.baker == null or not owner.baker.has_method("prime_physical_solve_from_current_wind"):
		diag["phys_wind_skipped_reason"] = "missing_prime_method"
		return diag
	if not owner.baker.prime_physical_solve_from_current_wind(owner.map, owner._phys_phase_locked):
		diag["phys_wind_skipped_reason"] = "prime_failed"
		return diag
	diag["phys_wind_dedupe_applied"] = true
	diag["phys_wind_skipped_reason"] = "daily_wind_reused"
	return diag



static func _run_physical_slice(owner: OceanCurrentsJob, ctx: SusTickContext, t_start_us: int, daily_report: Dictionary = {}) -> Dictionary:
	if not owner._phys_round_active:
		return {}
	if not owner._phys_solve_done:
		var phys_stage_before: int = owner._baker_phys_stage_id()
		var stage_t0_us: int = Time.get_ticks_usec()
		var dedupe_diag: Dictionary = owner._try_prime_physical_wind_from_daily(daily_report, phys_stage_before)
		if bool(dedupe_diag.get("phys_wind_dedupe_applied", false)):
			# Reuse the wind field produced by the same-tick daily prepass, then yield.
			# The next ocean slice starts at PSI_INIT, so its timing is not misattributed to phys_wind.
			owner._phys_solve_done = false
		else:
			owner._phys_solve_done = owner.baker._physical_solve_step_one(
					owner.map, owner.world, owner.hex_size, owner.cfg, owner._phys_phase_locked, owner._phys_run_ocean_this_round)
		if not owner._phys_solve_done and not owner._phys_need_visual \
				and owner.baker.has_method("_use_physical_circulation") \
				and "_phys_stage" in owner.baker \
				and "_PHYS_STAGE_WIND_RASTER" in owner.baker \
				and "_PHYS_STAGE_DONE" in owner.baker \
				and int(owner.baker._phys_stage) == int(owner.baker._PHYS_STAGE_WIND_RASTER):
			owner.baker._phys_stage = owner.baker._PHYS_STAGE_DONE
			if "_pending_phys_solved_phase" in owner.baker:
				owner.baker._pending_phys_solved_phase = owner._phys_phase_locked
			owner._phys_solve_done = true
		var elapsed_solve_ms: float = (Time.get_ticks_usec() - stage_t0_us) / 1000.0
		var elapsed_total_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		var phys_report: Dictionary = owner._current_phys_stage_report(phys_stage_before, elapsed_solve_ms)
		phys_report["stage_local_ms"] = elapsed_solve_ms
		phys_report["job_elapsed_ms"] = elapsed_total_ms
		phys_report["phys_stage_before"] = phys_stage_before
		phys_report["phys_stage_after"] = owner._baker_phys_stage_id()
		phys_report["daily_wind_ran"] = bool(daily_report.get("ran", false))
		phys_report["daily_wind_wind_ran"] = bool(daily_report.get("wind_ran", false))
		phys_report["daily_wind_stage_requested"] = str(daily_report.get("stage_requested", ""))
		for k in dedupe_diag.keys():
			phys_report[k] = dedupe_diag[k]
		# Fix #11 (2026-06-15) stage-level diag：前 3 次每 stage 必打，之后只在 >= 5ms 时打。
		# stage_id 取自 phys_report.stage（_phys_stage_name 已映射好）。每个 stage 独立 budget，
		# 不与 _ocean_rt_diag_count 24 上限互相吃。配合 mobile 60FPS bench 用：哪个 stage 在
		# 8 tick 桶里出现峰值，下一次 bench log 会清楚标出来。
		var _stage_id_for_diag: int = int(phys_report.get("stage", -1))
		if _stage_id_for_diag > 0:
			var _stage_diag_seen: int = int(owner._phys_stage_diag_count.get(_stage_id_for_diag, 0))
			var _should_stage_diag: bool = (_stage_diag_seen < owner._PHYS_STAGE_DIAG_INITIAL_PRINTS) \
					or (elapsed_solve_ms >= owner._PHYS_STAGE_DIAG_WARN_MS)
			if _should_stage_diag and PKLog.enabled:
				owner._phys_stage_diag_count[_stage_id_for_diag] = _stage_diag_seen + 1
				var _stage_kind: String = "warn" if elapsed_solve_ms >= owner._PHYS_STAGE_DIAG_WARN_MS else "init"
				print("[ocean_currents/STAGE-DIAG] %s tick=%d round=%d stage=%d/%s path=%s next=%s elapsed_ms=%.2f slp_native=%.2f psi_native=%.2f wind_dp95=%.6f ocean_dp95=%.6f slp_dp95=%.6f phys_done=%s need_visual=%s" % [
					_stage_kind, ctx.tick_index, owner._physical_round_id,
					_stage_id_for_diag, str(phys_report.get("stage_name", "?")),
					str(phys_report.get("path", "?")), str(phys_report.get("next_stage_name", "?")),
					elapsed_solve_ms,
					float(phys_report.get("stage_slp_native_ms", -1.0)),
					float(phys_report.get("stage_psi_native_ms", -1.0)),
					float(phys_report.get("wind_delta_p95", 0.0)),
					float(phys_report.get("ocean_delta_p95", 0.0)),
					float(phys_report.get("slp_delta_p95", 0.0)),
					str(owner._phys_solve_done), str(owner._phys_need_visual),
				])
		if PKLog.enabled and owner._ocean_rt_diag_count < owner._ocean_rt_log_budget():
			owner._ocean_rt_diag_count += 1
			print("[ocean_currents][RT] phys_slice#%d tick=%d round=%d stage=%s->%s done=%s run_ocean=%s need_visual=%s elapsed=%.3f ocean_delta_p95=%.6f wind_delta_p95=%.6f slp_delta_p95=%.6f psi_path=%s" % [
				owner._ocean_rt_diag_count, ctx.tick_index, owner._physical_round_id,
				str(phys_report.get("stage_name", "?")), str(phys_report.get("next_stage_name", "?")),
				str(owner._phys_solve_done), str(owner._phys_run_ocean_this_round), str(owner._phys_need_visual),
				elapsed_solve_ms, float(phys_report.get("ocean_delta_p95", 0.0)),
				float(phys_report.get("wind_delta_p95", 0.0)), float(phys_report.get("slp_delta_p95", 0.0)),
				str(phys_report.get("stage_psi_path", "?")),
			])
		if elapsed_solve_ms > 8.0:
			print("  [ocean_currents] slow phys slice=%.1fms (just-finished stage=%d/%s, next=%d/%s, path=%s, round_done=%s)" % [
				elapsed_solve_ms,
				int(phys_report.get("stage", -1)),
				str(phys_report.get("stage_name", "?")),
				int(phys_report.get("next_stage", -1)),
				str(phys_report.get("next_stage_name", "?")),
				str(phys_report.get("path", "")),
				str(owner._phys_solve_done),
			])
		if not owner._phys_solve_done:
			phys_report["done"] = false
			phys_report["work_done"] = 0
			phys_report["elapsed_ms"] = elapsed_solve_ms
			phys_report["progress_ratio"] = 0.0
			phys_report["ocean_solve_enabled"] = owner._phys_run_ocean_this_round
			return owner._record_phys_diag(ctx, phys_report, false)
		phys_report["done"] = true
		phys_report["work_done"] = 0
		phys_report["elapsed_ms"] = elapsed_solve_ms
		phys_report["progress_ratio"] = 1.0
		phys_report["ocean_solve_enabled"] = owner._phys_run_ocean_this_round
		phys_report["physical_round_complete"] = true
		if owner._phys_need_visual:
			owner._enqueue_visual_round(ctx, owner._phys_phase_locked)
			phys_report["visual_enqueued"] = owner._visual_round_active
		else:
			phys_report["pixel_skipped"] = true
			if owner.on_commit.is_valid():
				owner.on_commit.call()
		owner._finish_physical_round(ctx)
		return owner._record_phys_diag(ctx, phys_report, true)

	if owner._phys_need_visual:
		owner._enqueue_visual_round(ctx, owner._phys_phase_locked)
		var queued_report: Dictionary = {
			"done": true,
			"work_done": 0,
			"elapsed_ms": (Time.get_ticks_usec() - t_start_us) / 1000.0,
			"progress_ratio": 1.0,
			"stage_name": "ocean_visual_enqueued",
			"substage": "physical_complete",
			"path": "scheduler",
			"visual_enqueued": true,
			"physical_round_complete": true,
		}
		owner._finish_physical_round(ctx)
		return owner._record_phys_diag(ctx, queued_report, true)

	var skip_report: Dictionary = {
		"done": true,
		"work_done": 0,
		"elapsed_ms": (Time.get_ticks_usec() - t_start_us) / 1000.0,
		"progress_ratio": 1.0,
		"stage_name": "phys_done",
		"substage": "no_visual",
		"path": "physical_circulation",
		"pixel_skipped": true,
		"ocean_solve_enabled": owner._phys_run_ocean_this_round,
	}
	if owner.on_commit.is_valid():
		owner.on_commit.call()
	owner._finish_physical_round(ctx)
	return owner._record_phys_diag(ctx, skip_report, true)
