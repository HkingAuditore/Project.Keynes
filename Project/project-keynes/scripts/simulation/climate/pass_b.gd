extends "res://scripts/simulation/generator_context.gd"
class_name DCClimatePassB

## Climate Pass-B native dispatch and its retired fallback entry points.
## Mutable counters, caches, and slots remain owned by MapGenerator.

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null or map == null:
		return
	_climate_pass_b_legacy(map, season_phase)

func _climate_pass_b_legacy(map: MapData, season_phase: float) -> void:
	var cp: ClimateProfile = _generator._c()
	if cp == null or _generator._last_cfg == null:
		push_error("[climate/pass_b] native failed: missing climate context")
		return
	if map == null or not map.has_soa():
		push_error("[climate/pass_b] native failed: SoA map unavailable; previous fields retained")
		return
	_climate_pass_b_soa(map, season_phase, cp)


func _climate_pass_b_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：同 _climate_pass_a_soa 的 TODO。
	# 仅保留 C++ dispatch；GDScript 计算回退已退休。
	# 局部气候耦合 SoA 版本：在 SoA 上做 albedo / coastal / landform 温度修正 +
	# evap / rain_shadow 湿度修正。复用 legacy 同段算法常量。
	var winter_boost: float = 1.0
	var coast_leak: float = float(_generator._last_cfg.COASTAL_HEAT_LEAK)
	var snow_cool: float = float(cp.snow_albedo_cooling)
	var veg_cool: float = float(cp.vegetation_cooling)
	var diurnal_amp: float = float(cp.landform_diurnal_amp)
	var evap_gain: float = float(cp.evaporation_gain)
	var rs_threshold: float = float(cp.rain_shadow_threshold)
	var rs_factor: float = float(cp.rain_shadow_factor)
	var rs_lookback: int = max(0, int(cp.rain_shadow_lookback))
	var t_freeze: float = float(cp.sea_ice_form_threshold)
	var coupling_gain: float = float(cp.ocean_moisture_coupling_gain)
	# climate-loop-closure Phase 4.1：海冰反照率→温度反馈系数（profile 缺字段默认 0.01）。
	var sea_ice_cool: float = float(cp.sea_ice_albedo_cooling) if cp.get("sea_ice_albedo_cooling") != null else 0.01

	# ─── Phase F.3：DCWorldExt C++ 快路径（charter §7 P1，5.2ms → < 0.5ms）──
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_climate_pass_b flag 已删，现走
	# ext + has_method 探测。触发条件：
	#   1. cp != null
	#   2. _data_core_world_ext 已 bind && has_method("run_climate_pass_b")
	#   3. fast_indexed（neighbor_indices_packed 完整 = n_cells*6）
	#   4. **删除了 `not use_sparse_climate` 检查**——C++ 永远跑 full pass；
	#      如果 sparse runtime 真触发 (path=sparse)，C++ 仍会跑全图，结果与
	#      “GDScript 跑 full” bit-equal（稳态下等价），仅损失 sparse 跳格优化。
	#   5. C++ 端 run_climate_pass_b 返回 ≥ 0
	var nb_idx_for_f3: PackedInt32Array = map.neighbor_indices_packed()
	var n_for_f3: int = map.soa_size()
	var fast_indexed_b: bool = nb_idx_for_f3.size() >= n_for_f3 * 6

	# F.3 无脑诊断：在做任何条件检查之前，把 6 个 precondition 真实值 + 当前
	# ClimateProfile 资源路径 print 一次。F.5 验收时踩过的"flag 表面 true 但
	# fast-path 静默不进"问题在这里被一眼看穿。
	if not _generator._gdext_climate_b_first_attempt_logged:
		_generator._gdext_climate_b_first_attempt_logged = true
		var cp_b_path: String = "<in-memory ClimateProfile>"
		var flag_b_val: bool = true  # use_gdext_climate_pass_b flag removed (dots-flag-prune-pr1, 2026-05-22)
		var sparse_b_val: bool = false
		if cp != null:
			if cp.resource_path != "":
				cp_b_path = cp.resource_path
			sparse_b_val = bool(cp.use_sparse_climate)
		var ext_b_ok: bool = _generator._data_core_world_ext != null
		var has_method_b_ok: bool = ext_b_ok and _generator._data_core_world_ext.has_method("run_climate_pass_b")
		var verdict_b: String = "OK → will try C++"
		if not (flag_b_val and ext_b_ok and has_method_b_ok and fast_indexed_b):
			verdict_b = "FAIL → fall through to GDScript path"
		print("[climate_b/F.3] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_b_path)
		print("  cp.use_gdext_climate_pass_b = %s (flag removed; constant true)" % str(flag_b_val))
		print("  cp.use_sparse_climate = %s（C++ 会跑 full path 等价结果，不阻止）" % str(sparse_b_val))
		print("  _data_core_world_ext != null = %s" % str(ext_b_ok))
		print("  ext.has_method('run_climate_pass_b') = %s" % str(has_method_b_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got nb_size=%d)" % [str(fast_indexed_b), n_for_f3 * 6, nb_idx_for_f3.size()])
		print("  rs_lookback = %d, t_freeze = %.4f, coupling_gain = %.4f" % [rs_lookback, t_freeze, coupling_gain])
		print("  verdict = %s" % verdict_b)

	if cp != null and _generator._data_core_world_ext != null \
			and _generator._data_core_world_ext.has_method("run_climate_pass_b") and fast_indexed_b:
		# Stale .dll sig probe（仅作诊断，不阻止下方 C++ 调用——和 F.5 同模板）
		if not _generator._gdext_climate_b_signature_checked:
			_generator._gdext_climate_b_signature_checked = true
			_generator._gdext_climate_b_signature_ok = _generator._validate_gdext_method_signature("run_climate_pass_b", 1)
			print("[climate_b/F.3] sig probe result = %s（仅作诊断）" % str(_generator._gdext_climate_b_signature_ok))
		var tta_arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
		if tta_arr.size() != n_for_f3:
			var cells_for_f3: Array = map.iter_cells()
			tta_arr = PackedFloat32Array()
			tta_arr.resize(n_for_f3)
			for ti in range(n_for_f3):
				var cti: HexCell = cells_for_f3[ti]
				tta_arr[ti] = float(cti.temperature_transport_anomaly)
		var foliage_table: PackedFloat32Array = _generator._build_climate_b_foliage_table()
		var knobs_b: Dictionary = {
			"n_cells": n_for_f3,
			"winter_boost": winter_boost,
			"snow_cool": snow_cool,
			"veg_cool": veg_cool,
			"diurnal_amp": diurnal_amp,
			"evap_gain": evap_gain,
			"rs_threshold": rs_threshold,
			"rs_factor": rs_factor,
			"rs_lookback": rs_lookback,
			"t_freeze": t_freeze,
			"coupling_gain": coupling_gain,
			"coast_leak": coast_leak,
			"season_phase": season_phase,
			"go_sparse": false,
			"neighbor_indices": nb_idx_for_f3,
			"temp_transport_anomaly": tta_arr,
			"foliage_table": foliage_table,
			# climate-loop-closure Phase 4.1：海冰反照率→温度反馈（C++ tail loop 消费）。
			"sea_ice_albedo_cooling": sea_ice_cool,
			"sea_ice_frac": map.sea_ice_frac_arr,
		}
		# storage A/B 同源契约（修复 B 2026-05-14）：pass_a 刚写过 map.temp_arr，C++
		# slot 仍指向旧 buffer；先 refresh 同步。详见 docs/architecture/migration.md。
		# refresh-consolidation-2026-06：climate_daily round 守门员，跨 pass 边界由
		# climate_daily_system 在 _run_pass 切换 pass_id 时 mark stale。
		_generator._ensure_climate_daily_round_slots_fresh()
		# ─── sim-2ms-perf-push（plan/climate-pass-b-simd）派发 ───────────────
		# dots-flag-prune-pr1 round 2: use_gdext_pass_b_simd / use_gdext_thread_fallback
		# flag 均已删除——恒走 C++ scalar 入口 run_climate_pass_b，C++ 内部根据 CPU 特性 /
		# n_cells 自动选择 scalar / SIMD / threaded 三档执行路径。
		var _b_dispatch_path: String = "scalar"
		var rc_b: float = -1.0
		if _generator._data_core_world_ext.has_method("run_climate_pass_b_simd"):
			_b_dispatch_path = "simd"
			rc_b = float(_generator._data_core_world_ext.run_climate_pass_b_simd(knobs_b))
		else:
			rc_b = float(_generator._data_core_world_ext.run_climate_pass_b(knobs_b))
		if rc_b < 0.0 and _b_dispatch_path == "simd":
			_b_dispatch_path = "scalar_fallback"
			rc_b = float(_generator._data_core_world_ext.run_climate_pass_b(knobs_b))
		# 强制无脑诊断：前 3 次调用打 rc 值 + 派发路径
		if _generator._gdext_climate_b_runs + _generator._gdext_climate_b_fallbacks < 3:
			print("[climate_b/F.3] DEBUG call#%d: path=%s rc=%.4f n_cells=%d rs_lookback=%d" % [
				_generator._gdext_climate_b_runs + _generator._gdext_climate_b_fallbacks + 1,
				_b_dispatch_path, rc_b, n_for_f3, rs_lookback,
			])
		if rc_b >= 0.0:
			# C++ 写完 cell_temp / cell_moisture SoA。fastpath HexCell 模式下 cell.temperature
			# / cell.moisture 是 SoA alias，下游 pass 直接看到 C++ 写入；不需要回写。
			# 注意：C++ 没写 cell.temperature_breakdown UI dict；该字段只在 inspector
			# 选中时有用，允许 GDScript fallback 路径按需补回。
			_generator._gdext_climate_b_runs += 1
			_generator._gdext_climate_b_total_ms += rc_b
			if _generator._gdext_climate_b_runs == 1:
				print("[climate_b/F.3] gdext path ACTIVE (dispatch=%s) — first run elapsed=%.2fms (legacy GDScript baseline ≈ 5.2ms; charter §7 target < 0.5ms)" % [_b_dispatch_path, rc_b])
			return
		_generator._gdext_climate_b_fallbacks += 1
		# rc<0：C++ 已 push_warning；继续 fall through 到下面的 GDScript 完整路径


	push_error("[climate/pass_b] native failed: run_climate_pass_b unavailable or returned failure; previous fields retained")
	return


func _apply_local_climate_coupling_pass(map: MapData, season_phase: float, winter_boost: float) -> void:
	push_error("[climate/pass_b] native failed: GDScript local coupling fallback retired; previous fields retained")

func publish_weather_lut_after_weather_commit(map: MapData, world: WorldData, native_lut: PackedByteArray = PackedByteArray(), force_changed: bool = false) -> Dictionary:
	if _generator._baker == null or map == null or world == null:
		return {"path": "weather_lut_inline", "fallback": true, "reason": "missing_inputs"}
	var report: Dictionary
	if not native_lut.is_empty() and _generator._baker.has_method("publish_weather_lut_bytes_from_native"):
		report = _generator._baker.publish_weather_lut_bytes_from_native(native_lut, world, force_changed)
	else:
		report = _generator._baker.refresh_weather_lut_from_weather(map, world)
	report["path"] = "weather_lut_inline"
	return report


# plan/weather-refresh-cpp-all PR-2：weather refresh daily 合并 facade。
#
# 单次 cpp call 把 field_solve + distribute + summary_fronts + cyclone_wake + stage_b
# 5 段 pass 跑完，跳过 GDScript ↔ C++ 3 次 marshal + 多次 Dictionary 装包。当 cp.use_gdext_weather_refresh_daily=true
# 且 ext 已 bound + has_method 时由 SUS WeatherRefreshJob 优先选用本入口；任何前置不
# 满足或 cpp rc!=0 时**透明回退**到 refresh_daily_stage_a + refresh_daily_stage_b 老链，
# 对 caller 完全无感。
#
# 与 stage_a/stage_b 的语义对应：
#   - stage_a (tick_one_day) ⇒ cpp 段 1-4：field_solve / distribute / summary / cyclone_wake
#   - stage_b ⇒ cpp 段 5：albedo / veg_dyn / feedback
#
# 通报字段 1:1 沿用 stage_b 末尾的 _last_weather_breakdown 协议（path 字段标 "gdext_combined"
# 让 perf overlay 能区分慢速 GDScript 链与 fast cpp 链）；同时 stage_b 的 enum_atlas
# dirty mark 必须由本 facade 主动调用，因为合并 path 完全跳过了 stage_b GDScript 入口。

func refresh_weather_daily(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	# Step 1：前置 gate。任何一项失败立即 fallback 到老链，让 caller 透明感知。
	if _generator._weather_system == null or map == null or world == null:
		return _generator.refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
	var cp_now = _generator._c()
	# dots-flag-prune-pr1 round 2: use_gdext_weather_refresh_daily flag 已删除——
	# 恒走 ext + has_method(run_weather_refresh_daily_pass) + weather_system has_method
	# 探测分支（任一缺失透明 fallback 到老链 stage_a + stage_b）。
	if _generator._data_core_world_ext == null :
		var fb: Array[WeatherFront] = _generator.refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
		_generator.refresh_daily_stage_b(map, world)
		return fb
	if not _generator._weather_system.has_method("try_run_refresh_daily_combined_gdext"):
		var fc: Array[WeatherFront] = _generator.refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
		_generator.refresh_daily_stage_b(map, world)
		return fc

	# Step 2：sliced stage 不应混用合并模式（_round_active 状态由 sliced 路径维护，
	# 由 weather_refresh_job 的 _should_use_merged_native_weather 互斥保证）。这里再
	# 做 defensive：合并 path 必须自己刷新 _round_t0 计时基准，与 stage_b 的 total_ms 算法对齐。
	_generator._last_world = world
	_generator._weather_round_t0_us = Time.get_ticks_usec()

	# Step 3：把 stage_b call_index 推进，保持 stride 计数与 stage_b 老链 1:1 对齐。
	# （即便后续 ok=false 走 fallback 老链，老 stage_b 也会再 ++ 一次 — 这是 stride 二次
	# 推进的旧问题，但它本就只在合并失败的"半冷启动"几 tick 出现，不影响周期 stride 节奏。
	# 为最大兼容，这里仍按 stage_b 同步 ++，若 fallback 触发则在 fallback 分支里手动回滚。）
	var prev_call_index: int = _generator._weather_stage_b_call_index
	_generator._weather_stage_b_call_index += 1
	var stage_b_knobs: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_stage_b_knobs(
		map,
		cp_now,
		maxi(0, _generator._weather_stage_b_call_index)
	)

	# Step 4：单次 cpp call。weather_system.try_run_refresh_daily_combined_gdext
	# 内部 begin_field_solve → super_knobs merge → run_weather_refresh_daily_pass →
	# unpack fronts + cyclone mirror，stage_b knobs 由本 facade 注入。
	var res: Dictionary = _generator._weather_system.try_run_refresh_daily_combined_gdext(
		map, world, season_idx, climate_anomaly, season_phase, stage_b_knobs
	)
	var ok: bool = bool(res.get("ok", false))
	if not ok:
		# Fallback 路径：先回滚 stage_b call_index（让老 stage_b 自己重新 ++），
		# 然后透明走 stage_a + stage_b 老链。fail_stage 会在 weather_system
		# 内部首次失败时打 push_warning（节流单次），无需在此重复。
		_generator._weather_stage_b_call_index = prev_call_index
		var fronts_fb: Array[WeatherFront] = _generator.refresh_daily_stage_a(
			map, world, season_idx, climate_anomaly, season_phase
		)
		_generator.refresh_daily_stage_b(map, world)
		return fronts_fb

	# Step 5：成功路径。同步生成器侧通报状态。
	var fronts_out: Array[WeatherFront] = res.get("fronts", [] as Array[WeatherFront])
	_generator._last_active_fronts = fronts_out
	_generator._weather_round_fronts = fronts_out
	# breakdown：weather_system 已经按 path="gdext_combined" + 各段 ms 装好；外部 perf
	# overlay / SUS publish 直接读 _last_weather_breakdown 即可。
	var br: Dictionary = res.get("breakdown", {})
	_generator._diagnostics_bus.replace_weather_breakdown(br, _generator._current_fast_tick_idx)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_generator._dump_weather_breakdown_if_slow()
	# weather_round_tick_ms 用于 sliced 路径与本路径共享 perf 字段：取 advance+distribute+summary 段
	# 之和（与 stage_a 老链的 weather_tick_ms 对应概念，cyclone/stage_b 之外的"主 tick"耗时）。
	_generator._weather_round_tick_ms = float(br.get("advance_ms", 0.0)) \
			+ float(br.get("distribute_ms", 0.0)) \
			+ float(br.get("summary_ms", 0.0))

	# Step 6：合并 path 完全绕过了 stage_b GDScript 入口，所以 enum_atlas dirty mark 必须由
	# 本 facade 主动触发——否则 baker 收不到 cover/vegetation 改动信号导致视觉残影。
	#   - cover_dirty: weather distribute 段（BLIZZARD→SNOW 等）由 cpp 在 run_distribute 内
	#     直接写 cell.cover；mark cover dirty 让 baker 重烘。
	#   - vegetation_dirty: cpp veg_dyn 段返回 succession_indices / succession_to_veg；非空
	#     即视为 vegetation 有改动。
	var merged_succession_indices: PackedInt32Array = br.get(
		"succession_indices", PackedInt32Array())
	var merged_succession_to_vegetation: PackedByteArray = br.get(
		"succession_to_veg", PackedByteArray())
	var merged_succession_applied: int = _generator._get_native_daily_publish()._apply_vegetation_succession_candidates(
		map, merged_succession_indices, merged_succession_to_vegetation, cp_now)
	br["succession_applied_count"] = merged_succession_applied
	_generator._diagnostics_bus.merge_weather_breakdown({"succession_applied_count": merged_succession_applied})
	if _generator._baker != null:
		if _generator._weather_system.has_method("has_cover_dirty") and bool(_generator._weather_system.has_cover_dirty()):
			_generator._mark_enum_atlas_dirty(true, false)
		var veg_dirty: bool = merged_succession_applied > 0
		if veg_dirty:
			_generator._mark_enum_atlas_dirty(false, true)

	return fronts_out



func weather_native_daily_readiness_report() -> Dictionary:
	var n_cells: int = _generator._sus_map.cell_count() if _generator._sus_map != null else 0
	var report: Dictionary = {
		"ready": false,
		"reason": "",
		"n_cells": n_cells,
		"has_ext": _generator._data_core_world_ext != null,
		"has_weather_system": _generator._weather_system != null,
		"has_combined_method": false,
		"has_commit_method": false,
		"has_knobs_builder": false,
		"has_result_apply": false,
		"has_weather_lut_publish": has_method("publish_weather_lut_after_weather_commit"),
		"field_commit_path": str(_generator._diagnostics_bus.get_weather_breakdown().get("field_commit_path", "")),
		"field_commit_publish_verified": bool(_generator._diagnostics_bus.get_weather_breakdown().get("field_commit_publish_verified", false)),
		"field_commit_publish_repaired": bool(_generator._diagnostics_bus.get_weather_breakdown().get("field_commit_publish_repaired", false)),
		"field_commit_init_count": int(_generator._diagnostics_bus.get_weather_breakdown().get("field_commit_init_count", 0)),
		"field_commit_publish_reason": str(_generator._diagnostics_bus.get_weather_breakdown().get("field_commit_publish_reason", "")),
	}
	if _generator._data_core_world_ext != null:
		report["has_combined_method"] = true
		report["has_commit_method"] = true
	if _generator._weather_system != null:
		report["has_knobs_builder"] = _generator._weather_system.has_method("build_unified_fast_tick_weather_knobs")
		report["has_result_apply"] = _generator._weather_system.has_method("apply_unified_fast_tick_result")
	if n_cells <= 0:
		report["reason"] = "no_cells"
		return report
	if not bool(report["has_ext"]):
		report["reason"] = "missing_world_ext"
		return report
	if not bool(report["has_weather_system"]):
		report["reason"] = "missing_weather_system"
		return report
	if not bool(report["has_combined_method"]):
		report["reason"] = "missing_run_weather_refresh_daily_pass"
		return report
	if not bool(report["has_commit_method"]):
		report["reason"] = "missing_run_weather_field_commit_pass"
		return report
	if not bool(report["has_knobs_builder"]):
		report["reason"] = "missing_unified_knobs_builder"
		return report
	if not bool(report["has_result_apply"]):
		report["reason"] = "missing_unified_result_apply"
		return report
	if not bool(report["has_weather_lut_publish"]):
		report["reason"] = "missing_weather_lut_publish"
		return report
	var commit_path: String = str(report["field_commit_path"])
	if commit_path == "":
		report["reason"] = "no_verified_staged_commit_yet"
		return report
	if not bool(report["field_commit_publish_verified"]):
		report["reason"] = "field_commit_not_publish_verified"
		return report
	if bool(report["field_commit_publish_repaired"]):
		report["reason"] = "field_commit_required_gdscript_repair"
		return report
	if int(report["field_commit_init_count"]) < n_cells:
		report["reason"] = "field_init_incomplete_%d_of_%d" % [
			int(report["field_commit_init_count"]),
			n_cells,
		]
		return report
	report["ready"] = true
	report["reason"] = "verified_visible_publish"
	return report



func refresh_daily_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	if _generator._weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	_generator._last_world = world
	# 重置当轮分段计时；stage_b 完成后再写 total_ms / 各 ms。
	_generator._weather_round_t0_us = Time.get_ticks_usec()
	var t_us0: int = Time.get_ticks_usec()
	var fronts = _generator._weather_system.tick_one_day(map, world, season_idx, climate_anomaly, season_phase)
	_generator._weather_round_tick_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
	_generator._last_active_fronts = fronts
	_generator._weather_round_fronts = fronts
	return fronts



func weather_field_slice_cells() -> int:
	var cp_now = _generator._c()
	if cp_now == null:
		return 2400
	var n_cells: int = _generator._sus_map.cell_count() if _generator._sus_map != null else 0
	if n_cells > 0 and n_cells <= 6400 \
			and _generator._data_core_world_ext != null \
			and _generator._weather_system != null \
			and _generator._weather_system.has_method("uses_weather_field") \
			and bool(_generator._weather_system.uses_weather_field()):
		return n_cells
	return clampi(int(cp_now.weather_field_slice_cells), 100, 6400)



func begin_weather_refresh_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> void:
	if _generator._weather_system == null or map == null or world == null:
		return
	_generator._last_world = world
	_generator._weather_round_t0_us = Time.get_ticks_usec()
	if _generator._weather_system.has_method("begin_weather_field_solve"):
		_generator._weather_system.begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase)



func run_weather_refresh_stage_a_slice(cell_budget: int) -> Dictionary:
	if _generator._weather_system == null or not _generator._weather_system.has_method("run_weather_field_solve_slice"):
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	var result: Dictionary = _generator._weather_system.run_weather_field_solve_slice(maxi(1, cell_budget))
	var elapsed_ms: float = float(result.get("elapsed_ms", 0.0))
	var processed_cells: int = int(result.get("processed_cells", result.get("work_done", 0)))
	var cursor_start: int = int(result.get("cursor_start", -1))
	var cursor_end: int = int(result.get("cursor_end", -1))
	var sub: Dictionary = _generator._weather_system.last_breakdown() if _generator._weather_system.has_method("last_breakdown") else {}
	var weather_breakdown: Dictionary = {
		"weather_tick_ms": elapsed_ms,
		"advance_ms": elapsed_ms,
		"spawn_ms": 0.0,
		"distribute_ms": 0.0,
		"cyclone_ms": 0.0,
		"weather_field_bake_ms": 0.0,
		"transp_ms": 0.0,
		"albedo_ms": 0.0,
		"veg_dyn_ms": 0.0,
		"cover_rebake_ms": 0.0,
		"veg_rebake_ms": 0.0,
		"feedback_ms": 0.0,
		"total_ms": (Time.get_ticks_usec() - _generator._weather_round_t0_us) / 1000.0,
		"fronts": _generator._weather_round_fronts.size(),
		"processed_cells": processed_cells,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"weather_dirty_count": int(result.get("weather_dirty_count", 0)),
		"water_budget_error": float(result.get("water_budget_error", 0.0)),
		"active_weather_ratio": float(result.get("active_weather_ratio", 0.0)),
		"field_solve_tick": int(sub.get("field_solve_tick", -1)),
		"weather_commit_tick_delta": int(sub.get("weather_commit_tick_delta", 0)),
		"weather_last_commit_tick": int(sub.get("weather_last_commit_tick", -1)),
		"weather_cold_front_count": int(sub.get("weather_cold_front_count", 0)),
		"weather_warm_front_count": int(sub.get("weather_warm_front_count", 0)),
		"field_convergence_refresh_stride": int(sub.get("field_convergence_refresh_stride", 0)),
		"refresh_convergence": bool(sub.get("refresh_convergence", false)),
		"native_convergence_boost": bool(sub.get("native_convergence_boost", false)),
		"weather_convergence_dirty_count": int(sub.get("weather_convergence_dirty_count", 0)),
		"weather_convergence_delta_p95": float(sub.get("weather_convergence_delta_p95", 0.0)),
		"convergence_published": bool(sub.get("convergence_published", false)),
		"partial": not bool(result.get("done", true)),
		"progress_ratio": float(result.get("progress_ratio", 0.0)),
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": _generator._current_fast_tick_idx,
	}
	_generator._diagnostics_bus.replace_weather_breakdown(weather_breakdown, _generator._current_fast_tick_idx)
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_generator._dump_weather_breakdown_if_slow()
	return result



func commit_weather_refresh_stage_a(map: MapData, world: WorldData) -> Array[WeatherFront]:
	if _generator._weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	if _generator._weather_system.has_method("commit_weather_field_solve"):
		fronts = _generator._weather_system.commit_weather_field_solve()
	var sub: Dictionary = _generator._weather_system.last_breakdown() if _generator._weather_system.has_method("last_breakdown") else {}
	_generator._weather_round_tick_ms = float(sub.get("weather_tick_ms", sub.get("field_solve_ms", 0.0)))
	if not sub.is_empty():
		var merged: Dictionary = _generator._diagnostics_bus.get_weather_breakdown()
		merged.merge(sub, true)
		merged["weather_tick_ms"] = _generator._weather_round_tick_ms
		merged["weather_field_bake_ms"] = float(merged.get("weather_field_bake_ms", 0.0))
		merged["transp_ms"] = float(merged.get("transp_ms", 0.0))
		merged["albedo_ms"] = float(merged.get("albedo_ms", 0.0))
		merged["veg_dyn_ms"] = float(merged.get("veg_dyn_ms", 0.0))
		merged["cover_rebake_ms"] = float(merged.get("cover_rebake_ms", 0.0))
		merged["veg_rebake_ms"] = float(merged.get("veg_rebake_ms", 0.0))
		merged["feedback_ms"] = float(merged.get("feedback_ms", 0.0))
		merged["total_ms"] = (Time.get_ticks_usec() - _generator._weather_round_t0_us) / 1000.0
		merged["fronts"] = fronts.size()
		merged["_tick_idx"] = _generator._current_fast_tick_idx
		_generator._diagnostics_bus.replace_weather_breakdown(merged, _generator._current_fast_tick_idx)
	_generator._last_active_fronts = fronts
	_generator._weather_round_fronts = fronts
	return fronts



func run_hydrology_discharge_pass_native(map: MapData, world: WorldData) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var cp_now = _generator._c()
	if cp_now == null or not bool(cp_now.runtime_hydrology_enabled):
		return {
			"done": true,
			"elapsed_ms": 0.0,
			"work_done": 0,
			"progress_ratio": 1.0,
			"stage_name": "hydrology_discharge",
			"substage": "disabled",
			"path": "disabled",
			"published_to_slot": false,
			"fallback_reason": "runtime_hydrology_disabled",
		}
	# legacy weather chain 也要吃 runtime_hydrology_stride，和 native graph 的
	# 节拍保持一致。两条路径互斥，所以共用同一个计数器。
	var stride: int = 1
	if cp_now.get("runtime_hydrology_stride") != null:
		stride = maxi(1, int(cp_now.runtime_hydrology_stride))
	if stride > 1:
		_generator._native_daily_hydrology_call_index += 1
		if (_generator._native_daily_hydrology_call_index % stride) != 0:
			return {
				"done": true,
				"elapsed_ms": (Time.get_ticks_usec() - t0) / 1000.0,
				"work_done": 0,
				"progress_ratio": 1.0,
				"stage_name": "hydrology_discharge",
				"substage": "stride_skip",
				"path": "stride_skip",
				"published_to_slot": false,
				"fallback_reason": "runtime_hydrology_stride_skip",
			}
	if map == null or world == null:
		return {
			"done": true,
			"elapsed_ms": 0.0,
			"work_done": 0,
			"progress_ratio": 1.0,
			"stage_name": "hydrology_discharge",
			"substage": "missing_context",
			"path": "fallback",
			"published_to_slot": false,
			"fallback_reason": "missing_map_or_world",
		}
	if _generator._data_core_world_ext == null:
		return {
			"done": true,
			"elapsed_ms": 0.0,
			"work_done": 0,
			"progress_ratio": 1.0,
			"stage_name": "hydrology_discharge",
			"substage": "missing_native",
			"path": "fallback",
			"published_to_slot": false,
			"fallback_reason": "missing_run_runtime_hydrology_pass",
		}
	var t_refresh_us: int = Time.get_ticks_usec()
	_generator._data_core_world_ext.refresh_slots_from_map()
	var refresh_ms: float = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"dt_days": clampf(_generator._consume_weather_dt_days(), 1.0, 30.0),
		"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
		"hydro_precip_scale": float(cp_now.hydro_precip_scale),
		"hydro_snowmelt_scale": float(cp_now.hydro_snowmelt_scale),
		"hydro_soil_capacity": float(cp_now.hydro_soil_capacity),
		"hydro_infiltration_rate": float(cp_now.hydro_infiltration_rate),
		"hydro_quickflow_fraction": float(cp_now.hydro_quickflow_fraction),
		"hydro_baseflow_recession": float(cp_now.hydro_baseflow_recession),
		"hydro_channel_release_rate": float(cp_now.hydro_channel_release_rate),
		"hydro_lake_release_rate": float(cp_now.hydro_lake_release_rate),
		"hydro_discharge_ema": float(cp_now.hydro_discharge_ema),
		"hydro_bank_moisture_gain": float(cp_now.hydro_bank_moisture_gain),
		"hydro_river_moisture_floor": float(cp_now.hydro_river_moisture_floor),
		"hydro_riparian_moisture_floor": float(cp_now.hydro_riparian_moisture_floor),
		"hydro_river_evap_gain": float(cp_now.hydro_river_evap_gain),
		"hydro_moisture_response_rate": float(cp_now.hydro_moisture_response_rate),
		"hydro_flood_threshold": float(cp_now.hydro_flood_threshold),
		"hydro_flood_decay": float(cp_now.hydro_flood_decay),
		"snowpack_melt_temp_gain": float(cp_now.snowpack_melt_temp_gain),
		"snowpack_melt_sun_gain": float(cp_now.snowpack_melt_sun_gain),
		"plant_water_balance_weight": float(cp_now.plant_water_balance_weight),
		"plant_soil_buffer_weight": float(cp_now.plant_soil_buffer_weight),
		"plant_drought_penalty": float(cp_now.plant_drought_penalty),
	}
	var res: Dictionary = _generator._data_core_world_ext.run_runtime_hydrology_pass(knobs)
	var elapsed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	res["done"] = true
	res["elapsed_ms"] = elapsed_ms
	res["work_done"] = int(res.get("processed_cells", res.get("n_cells", 0)))
	res["progress_ratio"] = 1.0
	res["stage_name"] = "hydrology_discharge"
	res["substage"] = "route_full"
	res["refresh_ms"] = refresh_ms
	res["path"] = str(res.get("path", "gdext"))
	_generator._diagnostics_bus.merge_weather_breakdown({
		"hydrology_discharge_ms": elapsed_ms,
		"hydrology_native_ms": float(res.get("native_ms", 0.0)),
		"hydrology_compute_ms": float(res.get("compute_ms", 0.0)),
		"hydrology_flush_ms": float(res.get("flush_ms", 0.0)),
		"hydrology_refresh_ms": refresh_ms,
		"hydrology_water_budget_error": float(res.get("water_budget_error", 0.0)),
		"hydrology_river_discharge_p95": float(res.get("river_discharge_p95", 0.0)),
		"hydrology_river_discharge_max": float(res.get("river_discharge_max", 0.0)),
		"hydrology_riparian_neighbor_touches": int(res.get("riparian_neighbor_touches", 0)),
		"hydrology_moisture_response_alpha": float(res.get("moisture_response_alpha", 0.0)),
		"hydrology_river_moisture_max_delta": float(res.get("river_moisture_max_delta", 0.0)),
		"hydrology_riparian_moisture_max_delta": float(res.get("riparian_moisture_max_delta", 0.0)),
		"hydrology_flood_count": int(res.get("flood_count", res.get("flood_candidate_count", 0))),
	})
	return res


# Stage B：tick_one_day 之后的全部"派生 / 反馈"工作。
# field_bake（F 之后 ~5ms 增量） + transpiration（多数情况下被 enable_local_climate_coupling 跳过）
# + albedo + vegetation_dynamics + cover/veg dirty marks + weather→map feedback。
# 由 SUS WeatherRefreshJob 在 round 终点的 tick 跑（典型下一 tick）。

func refresh_daily_stage_b(map: MapData, world: WorldData) -> void:
	if _generator._weather_system == null or map == null or world == null:
		return
	var cp_now = _generator._c()
	_generator._weather_stage_b_call_index += 1
	var albedo_stride: int = maxi(1, int(cp_now.weather_albedo_stride)) if cp_now != null else 10
	var veg_dyn_stride: int = maxi(1, int(cp_now.weather_vegetation_dynamics_stride)) if cp_now != null else 10
	var feedback_stride: int = maxi(1, int(cp_now.weather_feedback_stride)) if cp_now != null else 10
	var run_albedo: bool = (_generator._weather_stage_b_call_index % albedo_stride) == 0
	var run_veg_dyn: bool = (_generator._weather_stage_b_call_index % veg_dyn_stride) == 0
	var run_feedback: bool = (_generator._weather_stage_b_call_index % feedback_stride) == 0
	var weather_field_bake_ms: float = 0.0
	var t_us0: int = Time.get_ticks_usec()
	# Weather field data now lives on HexCell.weather_* and is consumed by CPU-side
	# systems directly. Do not flatten it into a per-pixel texture each weather tick.
	if world.weather_field_tex != null or not world.weather_field_buffer.is_empty():
		world.weather_field_tex = null
		world.weather_field_buffer = PackedByteArray()

	# Emergent Climate Coupling：当 enable_local_climate_coupling 开启时，
	# transpiration 已在 refresh_climate_daily 末尾、weather tick 之前执行过，此处跳过。
	var skip_transpiration: bool = cp_now != null and bool(cp_now.enable_local_climate_coupling)
	var transp_ms: float = 0.0
	if not skip_transpiration:
		t_us0 = Time.get_ticks_usec()
		_generator._ensure_daily_pass_modules()
		_generator._transpiration_pass_module.run(map)
		transp_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

	# ─── 方案 B：stage_b 三段合并快路径（plan/stage-b-combine）────────────────
	# native stage_b pass 把 albedo、vegetation dynamics 和 feedback 一次性处理。
	# 失败时保留已有字段并报告失败，不再在脚本侧重算整图。
	# 关键收益：消除 GDScript 端 3 次 pack（vit/lo/hi、soil/vg/tta、albedo+8 LUT）
	# + 3 次 refresh_slots_from_map + 3 次 unpack 循环。各段算法 1:1 同 cpp 旧路径。
	var stage_b_combined_done: bool = false
	var albedo_ms: float = 0.0
	var veg_dyn_ms: float = 0.0
	var feedback_ms: float = 0.0
	var vegetation_dirty := false
	var fast_slow_layering_on: bool = cp_now != null and bool(cp_now.fast_slow_layering_enabled)
	var combined_run_albedo: bool = run_albedo
	var combined_run_veg_dyn: bool = run_veg_dyn
	var combined_run_feedback: bool = run_feedback and fast_slow_layering_on
	# dots-flag-prune-pr1 round 2: use_gdext_stage_b_combined flag 已删除——恒走 ext +
	# has_method(run_stage_b_pass) 探测分支。DIAG 块保留原状，stage_b_flag_on 恒 true
	# 仅作为诊断记录。
	var stage_b_flag_on: bool = true  # 已折叠：flag 字段已删
	var stage_b_ext_ok: bool = _generator._data_core_world_ext != null
	if not _generator._gdext_stage_b_first_attempt_logged:
		_generator._gdext_stage_b_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		if cp_now != null and cp_now.resource_path != "":
			cp_path = cp_now.resource_path
		var verdict: String = "OK → will try native combined pass"
		if not (stage_b_flag_on and stage_b_ext_ok):
			verdict = "FAIL → native stage will report failure"
		print("[stage_b/combined] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_stage_b_combined = %s" % str(stage_b_flag_on))
		print("  _data_core_world_ext != null = %s" % str(_generator._data_core_world_ext != null))
		print("  ext.has_method('run_stage_b_pass') = %s" % str(stage_b_ext_ok))
		print("  verdict = %s" % verdict)

	if stage_b_flag_on and stage_b_ext_ok \
			and (combined_run_albedo or combined_run_veg_dyn or combined_run_feedback):
		var t_combined_us0: int = Time.get_ticks_usec()
		# 细粒度子段计时（仅前 3 次 DEBUG 用）
		var _dbg_combined_first3: bool = (_generator._gdext_stage_b_runs + _generator._gdext_stage_b_fallbacks) < 3
		var t_iter_us: int = 0
		var t_pack_albedo_us: int = 0
		var t_pack_vegdyn_us: int = 0
		var t_pack_feedback_us: int = 0
		var t_refresh_us: int = 0
		var t_call_us: int = 0
		var t_unpack_us: int = 0
		var _dbg_t0: int = t_combined_us0
		var cells_c: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		var n_cells_c: int = cells_c.size()
		if _dbg_combined_first3:
			t_iter_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		var knobs_c: Dictionary = {
			"n_cells": n_cells_c,
			"run_albedo": combined_run_albedo,
			"run_veg_dyn": combined_run_veg_dyn,
			"run_feedback": combined_run_feedback,
			# B3b 数据所有权下沉：6 字段已下沉到 SoA schema，cpp 端直读
			# _slots[].arr_*，消除 GDScript 端 pack/unpack hot loop。
			# 末尾 cpp 自动 flush 6 个新 slot 回 MapData，GDScript 端再做一次
			# 轻量"slot → HexCell 回灌"以兼容下游冷路径（overlay/info_panel/main）。
			"use_soa": true,
		}

		# ① ALBEDO 段入参
		if combined_run_albedo:
			knobs_c["reference_albedo"]   = float(cp_now.reference_albedo)
			knobs_c["albedo_temp_gain"]   = float(cp_now.albedo_temp_gain)
			knobs_c["snow_cover_albedo"]  = 0.75
			knobs_c["cover_snow_id"]      = int(CoverType.CV.SNOW)
			knobs_c["cover_glacier_id"]   = int(CoverType.CV.GLACIER)
			knobs_c["albedo_table"]       = _generator._build_albedo_donor_table()
		if _dbg_combined_first3:
			t_pack_albedo_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		# ② VEG_DYN 段入参（B3b 后 vit/streak 已下沉到 SoA，无需 pack PackedArray）
		if combined_run_veg_dyn:
			_generator._ensure_vegdyn_lut()
			var veg_dyn_scale_raw: float = float(veg_dyn_stride)
			var veg_dyn_scale_eff: float = maxf(veg_dyn_scale_raw, 1.0)
			var streak_days_c: int = maxi(1, int(round(veg_dyn_scale_eff)))
			knobs_c["day_scale"]               = veg_dyn_scale_raw
			knobs_c["streak_days"]             = streak_days_c
			knobs_c["vitality_change_rate"]    = float(cp_now.vitality_change_rate)
			knobs_c["compat_harshness"]        = float(cp_now.compat_harshness)
			knobs_c["weather_penalty_scale"]   = float(cp_now.vegetation_weather_penalty_scale)
			knobs_c["plant_water_balance_weight"] = float(cp_now.plant_water_balance_weight)
			knobs_c["plant_soil_buffer_weight"] = float(cp_now.plant_soil_buffer_weight)
			knobs_c["plant_drought_penalty"] = float(cp_now.plant_drought_penalty)
			knobs_c["succession_min_compat_gain"] = float(cp_now.succession_min_compat_gain)
			knobs_c["low_threshold"]           = float(cp_now.vitality_low_threshold)
			knobs_c["high_threshold"]          = float(cp_now.vitality_high_threshold)
			knobs_c["succession_degrade_days"] = int(cp_now.succession_degrade_days)
			knobs_c["succession_upgrade_days"] = int(cp_now.succession_upgrade_days)
			knobs_c["vegetation_degrade_reset_target"] = float(cp_now.vegetation_degrade_reset_target) if cp_now.get("vegetation_degrade_reset_target") != null else 0.75
			knobs_c["vegetation_low_vitality_damping_threshold"] = float(cp_now.vegetation_low_vitality_damping_threshold) if cp_now.get("vegetation_low_vitality_damping_threshold") != null else 0.40
			knobs_c["vegetation_succession_cooldown_days"] = int(cp_now.vegetation_succession_cooldown_days) if cp_now.get("vegetation_succession_cooldown_days") != null else 30
			knobs_c["vegetation_stress_enabled"] = bool(cp_now.vegetation_stress_enabled) if cp_now.get("vegetation_stress_enabled") != null else false
			knobs_c["vegetation_stress_memory_days"] = float(cp_now.vegetation_stress_memory_days) if cp_now.get("vegetation_stress_memory_days") != null else 30.0
			knobs_c["n_wt"]                    = int(WeatherType.WT.size())
			knobs_c["wt_clear_id"]             = int(WeatherType.WT.CLEAR)
			knobs_c["wt_blizzard_id"]          = int(WeatherType.WT.BLIZZARD)
			knobs_c["wt_drought_id"]           = int(WeatherType.WT.DROUGHT)
			knobs_c["wt_heatwave_id"]          = int(WeatherType.WT.HEATWAVE)
			knobs_c["veg_none_id"]             = int(VegetationType.VEG.NONE)
			knobs_c["ideal_temp_table"]        = _generator._gdext_vegdyn_ideal_temp_cached
			knobs_c["ideal_moist_table"]       = _generator._gdext_vegdyn_ideal_moist_cached
			knobs_c["temp_tol_table"]          = _generator._gdext_vegdyn_temp_tol_cached
			knobs_c["moist_tol_table"]         = _generator._gdext_vegdyn_moist_tol_cached
			knobs_c["weather_penalty_table"]   = _generator._gdext_vegdyn_weather_penalty_cached
			knobs_c["resistance_table"]        = _generator._gdext_vegdyn_resistance_cached
			knobs_c["next_up_table"]           = _generator._gdext_vegdyn_next_up_cached
			knobs_c["next_down_table"]         = _generator._gdext_vegdyn_next_down_cached
			# 注：use_soa=true 时 cpp 直读 _slots[sid_vit/sid_low_streak/sid_high_streak]
			# vitality_arr / low_streak_arr / high_streak_arr 已不再传入
		if _dbg_combined_first3:
			t_pack_vegdyn_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		# ③ FEEDBACK 段入参（B3b 后 soil/vg/tta 已下沉到 SoA，无需 pack PackedArray）
		if combined_run_feedback:
			var feedback_scale_eff: float = maxf(float(feedback_stride), 1.0)
			var per_day_clamp_c: float = float(cp_now.feedback_per_day_clamp) * feedback_scale_eff
			var neighbor_indices_c: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
			# fast_indexed precondition：合并入口的 feedback 段必须 fully indexed；
				# 不满足时只停用 feedback 段；已有 feedback 字段保持不变。
			if neighbor_indices_c.size() < n_cells_c * 6:
				push_error("[stage_b/feedback] native failed: neighbor_indices_packed incomplete; previous fields retained")
				combined_run_feedback = false
				knobs_c["run_feedback"] = false
			else:
				knobs_c["soil_gain"]               = float(cp_now.weather_to_soil_gain)
				knobs_c["veg_gain"]                = float(cp_now.weather_to_vegetation_gain)
				knobs_c["write_weather_veg_pressure"] = not combined_run_veg_dyn
				knobs_c["scale"]                   = feedback_scale_eff
				knobs_c["per_day_clamp"]           = per_day_clamp_c
				knobs_c["ocean_drift_gain"]        = float(cp_now.ocean_moisture_drift_gain)
				knobs_c["wt_rain_id"]              = int(WeatherType.WT.RAIN)
				knobs_c["wt_storm_id"]             = int(WeatherType.WT.STORM)
				knobs_c["wt_monsoon_id"]           = int(WeatherType.WT.MONSOON)
				knobs_c["wt_blizzard_id"]          = int(WeatherType.WT.BLIZZARD)
				knobs_c["wt_drought_id"]           = int(WeatherType.WT.DROUGHT)
				knobs_c["wt_heatwave_id"]          = int(WeatherType.WT.HEATWAVE)
				knobs_c["neighbor_indices"]        = neighbor_indices_c
				# 注：use_soa=true 时 cpp 直读 _slots[sid_tta/sid_soil/sid_vgp]
				# temp_transport_anomaly / soil_moisture_arr / veg_growth_pressure_arr 已不再传入
		if _dbg_combined_first3:
			t_pack_feedback_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		# 单次 refresh_slots_from_map（替代旧三段各自一次共三次）
		_generator._data_core_world_ext.refresh_slots_from_map()
		if _dbg_combined_first3:
			t_refresh_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		var rc_c: float = float(_generator._data_core_world_ext.run_stage_b_pass(knobs_c))
		if _dbg_combined_first3:
			t_call_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		if rc_c >= 0.0:
			# 段计时（C++ 写回）
			albedo_ms = float(knobs_c.get("albedo_ms", 0.0))
			veg_dyn_ms = float(knobs_c.get("veg_dyn_ms", 0.0))
			feedback_ms = float(knobs_c.get("feedback_ms", 0.0))

			# VEG_DYN 写回：cpp 已直写 SoA _slots[sid_vit/sid_low_streak/sid_high_streak]，
			# slot 与 map.vegetation_vitality_arr / vitality_low_streak_arr / vitality_high_streak_arr
			# 共享同一份 PackedArray 引用（zero-copy）。HexCell 端 5 字段已 facade 化
			# （hex_cell.gd L455-505），cell.vegetation_vitality / _vitality_low_streak / _vitality_high_streak
			# 的 getter 直接走 world.read_f32/i32 → 拿到的就是 cpp 刚写完的最新值。
			# 因此 unpack 回灌循环（n_cells × 3 PackedArray.get + cell setter）可整段删除，
			# 这是 wall ≤ 1ms 收益的核心来源。
			if combined_run_veg_dyn:
				var succ_indices_c: PackedInt32Array = knobs_c.get("succession_indices", PackedInt32Array())
				var succ_to_veg_c: PackedByteArray = knobs_c.get("succession_to_veg", PackedByteArray())
				vegetation_dirty = _generator._get_native_daily_publish()._apply_vegetation_succession_candidates(
					map, succ_indices_c, succ_to_veg_c, cp_now) > 0

			# FEEDBACK 写回：cpp 已直写 SoA _slots[sid_soil/sid_vgp]，与 map.soil_moisture_arr /
			# vegetation_growth_pressure_arr 共享 PackedArray 引用。HexCell 端 soil_moisture /
			# vegetation_growth_pressure 已 facade 化（hex_cell.gd L668-697），getter 自动从
			# SoA 拿最新值，无需 unpack 回灌循环。

			stage_b_combined_done = true
			_generator._gdext_stage_b_runs += 1
			_generator._gdext_stage_b_total_ms += rc_c
			if _generator._gdext_stage_b_runs == 1:
				print("[stage_b/combined] native path ACTIVE — first run elapsed=%.2fms" % rc_c)
				print("  per-stage: albedo=%.2fms veg_dyn=%.2fms feedback=%.2fms" % [albedo_ms, veg_dyn_ms, feedback_ms])
			# ─── DIAGNOSTIC: vegetation_vitality 数据通路一次性体检 ─────────────
			# 跑 N 次后采样一次（让 vitality 有机会漂移），打印 4 个数据源的全图分布。
			# 目的：定位"全图 70%"是 cpp 没漂、facade 没启用、还是渲染读错源。
			# 顺便每 5 次报一次心跳，确认 pass 在持续运行。
			if (_generator._gdext_stage_b_runs % 5) == 0 and _generator._gdext_stage_b_runs <= 20:
				print("[veg_vit/HEARTBEAT] stage_b combined runs=%d" % _generator._gdext_stage_b_runs)
			if _generator._gdext_stage_b_runs == 5:
				var _diag_n: int = cells_c.size()
				var _diag_cid: int = -1
				# 关键：参数 world 是 WorldData（无 component_id），必须用 _data_core_world（DCWorld）
				var _dcw = _generator._data_core_world
				if _dcw != null and _dcw.has_method("component_id"):
					_diag_cid = int(_dcw.component_id(&"cell.vegetation_vitality"))
				var _v_min_get: float =  1e9
				var _v_max_get: float = -1e9
				var _v_sum_get: float = 0.0
				var _v_min_soa: float =  1e9
				var _v_max_soa: float = -1e9
				var _v_sum_soa: float = 0.0
				var _v_min_arr: float =  1e9
				var _v_max_arr: float = -1e9
				var _v_sum_arr: float = 0.0
				var _land_cnt: int = 0
				var _facade_on_cnt: int = 0
				var _arr_size: int = map.vegetation_vitality_arr.size() if map != null else 0
				for _di in range(_diag_n):
					var _dc: HexCell = cells_c[_di]
					if _dc == null or bool(_dc.passable_sea):
						continue
					_land_cnt += 1
					if _dc.is_facade_enabled():
						_facade_on_cnt += 1
					var _vg: float = float(_dc.vegetation_vitality)  # getter
					if _vg < _v_min_get: _v_min_get = _vg
					if _vg > _v_max_get: _v_max_get = _vg
					_v_sum_get += _vg
					if _diag_cid >= 0:
						var _vs: float = float(_dcw.read_f32(_diag_cid, _di))
						if _vs < _v_min_soa: _v_min_soa = _vs
						if _vs > _v_max_soa: _v_max_soa = _vs
						_v_sum_soa += _vs
					if _di < _arr_size:
						var _va: float = float(map.vegetation_vitality_arr[_di])
						if _va < _v_min_arr: _v_min_arr = _va
						if _va > _v_max_arr: _v_max_arr = _va
						_v_sum_arr += _va
				print("[veg_vit/DIAG] tick #5  land_cells=%d  facade_on=%d/%d  cid=%d  arr_size=%d" % [_land_cnt, _facade_on_cnt, _land_cnt, _diag_cid, _arr_size])
				if _land_cnt > 0:
					print("  getter (cell.vegetation_vitality):  min=%.4f  max=%.4f  avg=%.4f" % [_v_min_get, _v_max_get, _v_sum_get / float(_land_cnt)])
					if _diag_cid >= 0:
						print("  SoA    (world.read_f32):             min=%.4f  max=%.4f  avg=%.4f" % [_v_min_soa, _v_max_soa, _v_sum_soa / float(_land_cnt)])
					if _arr_size > 0:
						print("  array  (map.vegetation_vitality_arr): min=%.4f  max=%.4f  avg=%.4f" % [_v_min_arr, _v_max_arr, _v_sum_arr / float(_land_cnt)])
		else:
			_generator._gdext_stage_b_fallbacks += 1
			if _generator._gdext_stage_b_fallbacks == 1:
				print("[stage_b/combined] native path unavailable: run_stage_b_pass")
		# combined elapsed wall-clock（含 pack/unpack/marshal）—— 仅 DEBUG 前 3 次
		if _generator._gdext_stage_b_runs + _generator._gdext_stage_b_fallbacks <= 3:
			# unpack 段：从 t_call_us 测完到现在
			t_unpack_us = Time.get_ticks_usec() - _dbg_t0
			var combined_wall_ms: float = (Time.get_ticks_usec() - t_combined_us0) / 1000.0
			print("[stage_b/combined] DEBUG call#%d: rc=%.4f wall=%.2fms run_a=%s run_v=%s run_f=%s" % [
				_generator._gdext_stage_b_runs + _generator._gdext_stage_b_fallbacks,
				rc_c, combined_wall_ms,
				str(combined_run_albedo), str(combined_run_veg_dyn), str(combined_run_feedback),
			])
			print("  breakdown(ms): iter=%.2f pack_albedo=%.2f pack_vegdyn=%.2f pack_feedback=%.2f refresh=%.2f call=%.2f unpack=%.2f" % [
				t_iter_us / 1000.0,
				t_pack_albedo_us / 1000.0,
				t_pack_vegdyn_us / 1000.0,
				t_pack_feedback_us / 1000.0,
				t_refresh_us / 1000.0,
				t_call_us / 1000.0,
				t_unpack_us / 1000.0,
			])

	if not stage_b_combined_done and not stage_b_ext_ok \
			and (combined_run_albedo or combined_run_veg_dyn or combined_run_feedback):
		_generator._gdext_stage_b_fallbacks += 1
		push_error("[stage_b] native failed; previous albedo, vegetation and feedback fields retained")
	var cover_rebake_ms: float = 0.0
	var veg_rebake_ms: float = 0.0
	if _generator._baker != null:
		if _generator._weather_system.has_cover_dirty():
			_generator._mark_enum_atlas_dirty(true, false)
		if vegetation_dirty:
			_generator._mark_enum_atlas_dirty(false, true)
	var total_ms: float = (Time.get_ticks_usec() - _generator._weather_round_t0_us) / 1000.0
	var sub: Dictionary = {}
	if _generator._weather_system.has_method("last_breakdown"):
		sub = _generator._weather_system.last_breakdown()
	var weather_breakdown: Dictionary = {
		"weather_tick_ms": _generator._weather_round_tick_ms,
		"advance_ms": float(sub.get("advance_ms", 0.0)),
		"spawn_ms": float(sub.get("spawn_ms", 0.0)),
		"distribute_ms": float(sub.get("distribute_ms", 0.0)),
		"cyclone_ms": float(sub.get("cyclone_ms", 0.0)),
		"field_solve_ms": float(sub.get("field_solve_ms", 0.0)),
		"field_solve_total_ms": float(sub.get("field_solve_total_ms", 0.0)),
		"field_summary_ms": float(sub.get("field_summary_ms", sub.get("spawn_ms", 0.0))),
		"field_commit_total_ms": float(sub.get("field_commit_total_ms", 0.0)),
		"field_commit_setup_ms": float(sub.get("field_commit_setup_ms", 0.0)),
		"field_commit_loop_ms": float(sub.get("field_commit_loop_ms", 0.0)),
		"field_commit_path": str(sub.get("field_commit_path", "")),
		"field_commit_publish_verified": bool(sub.get("field_commit_publish_verified", false)),
		"field_commit_publish_repaired": bool(sub.get("field_commit_publish_repaired", false)),
		"field_commit_init_count": int(sub.get("field_commit_init_count", 0)),
		"field_commit_publish_reason": str(sub.get("field_commit_publish_reason", "")),
		"field_commit_dc_ms": float(sub.get("field_commit_dc_ms", 0.0)),
		"field_commit_convergence_ms": float(sub.get("field_commit_convergence_ms", 0.0)),
		"field_solve_tick": int(sub.get("field_solve_tick", -1)),
		"weather_commit_tick_delta": int(sub.get("weather_commit_tick_delta", 0)),
		"weather_last_commit_tick": int(sub.get("weather_last_commit_tick", -1)),
		"weather_cold_front_count": int(sub.get("weather_cold_front_count", 0)),
		"weather_warm_front_count": int(sub.get("weather_warm_front_count", 0)),
		"field_convergence_refresh_stride": int(sub.get("field_convergence_refresh_stride", 0)),
		"refresh_convergence": bool(sub.get("refresh_convergence", false)),
		"native_convergence_boost": bool(sub.get("native_convergence_boost", false)),
		"weather_convergence_dirty_count": int(sub.get("weather_convergence_dirty_count", 0)),
		"weather_convergence_delta_p95": float(sub.get("weather_convergence_delta_p95", 0.0)),
		"convergence_published": bool(sub.get("convergence_published", false)),
		"weather_dirty_count": int(sub.get("weather_dirty_count", 0)),
		"water_budget_error": float(sub.get("water_budget_error", 0.0)),
		"active_weather_ratio": float(sub.get("active_weather_ratio", 0.0)),
		"weather_field_bake_ms": weather_field_bake_ms,
		"transp_ms": transp_ms,
		"albedo_ms": albedo_ms,
		"veg_dyn_ms": veg_dyn_ms,
		"cover_rebake_ms": cover_rebake_ms,
		"veg_rebake_ms": veg_rebake_ms,
		"feedback_ms": feedback_ms,
		"total_ms": total_ms,
		"fronts": _generator._weather_round_fronts.size(),
		"albedo_ran": run_albedo,
		"veg_dyn_ran": run_veg_dyn,
		"feedback_ran": run_feedback,
		# ── stage_b 调度诊断（供 tile_data_recorder 写 CSV，定位 veg_dyn 为何不动）──
		"stage_b_call_index": maxi(0, _generator._weather_stage_b_call_index),
		"stage_b_combined_done": stage_b_combined_done,
		"stage_b_ext_ok": stage_b_ext_ok,
		"stage_b_total_runs": _generator._gdext_stage_b_runs,
		"stage_b_total_fallbacks": _generator._gdext_stage_b_fallbacks,
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": _generator._current_fast_tick_idx,
	}
	_generator._diagnostics_bus.replace_weather_breakdown(weather_breakdown, _generator._current_fast_tick_idx)
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_generator._dump_weather_breakdown_if_slow()

# 给 UI / renderer 直接拿到当前天气快照（不触发 tick）

func set_weather_refresh_stride(s: int) -> void:
	var stride: int = clampi(s, 1, 8)
	var cp = _generator._c()
	if cp == null:
		# 尚无 climate profile（通常是 _ready 完成前的极早调用）——缓存到待应用标志上不太值得，
		# 外部 main.gd 会在后续 speed_changed 回调里再调一次，直接忽略即可。
		return
	cp.weather_refresh_stride = stride
	if _generator._sus != null:
		_generator._sus.apply_job_schedule(_generator._weather_refresh_system, cp, &"weather_refresh", stride)
		_generator._sus.apply_job_schedule(_generator._weather_refresh_job, cp, &"weather_refresh", stride)
	if stride != _generator._weather_stride_logged:
		_generator._weather_stride_logged = stride
		print("[fastpath] weather_refresh_stride = %d" % stride)


# 任务 8：daily_climate_refresh_stride 亦迁到 SUS；提供 setter 改写
# ClimateProfile + Job policy 两者，保持语义一致。默认 main.gd 不随 speed_changed
# 修改该 stride（历史上也未随速度变化），保持原有 default = 1 行为。
