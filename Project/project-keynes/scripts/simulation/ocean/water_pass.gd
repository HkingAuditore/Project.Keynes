extends "res://scripts/simulation/generator_context.gd"
class_name DCOceanWaterPass

## Ocean water native dispatch and sliced execution. MapGenerator owns the
## cursor, caches, and diagnostics accessed through the weak reference.

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null or map == null:
		return
	_ocean_water_pass_legacy(map, season_phase)

func _ocean_water_pass_legacy(map: MapData, season_phase: float) -> void:
	if _generator._last_cfg == null:
		push_error("[ocean/water] native failed: missing map config; previous fields retained")
		return
	if not is_nan(_generator._ocean_water_done_phase) and absf(_generator._ocean_water_done_phase - season_phase) < 0.001:
		return
	var cp: ClimateProfile = _generator._c()
	if cp == null or map == null or not map.has_soa():
		push_error("[ocean/water] native failed: SoA map unavailable; previous fields retained")
		return
	_ocean_water_pass_soa(map, season_phase, cp)
	_generator._ocean_water_done_phase = season_phase


func _ocean_water_pass_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：同 _climate_pass_a_soa 的 TODO。
	# 仅保留 C++ dispatch；GDScript 计算回退已退休。
	var advect_steps: int = max(0, _generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS)
	var heat_mix: float = clampf(_generator._last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0)
	var tta: Dictionary = _generator._temperature_transport_anomaly_knobs(cp)
	var tta_source_cap: float = float(tta["tta_source_cap"])
	var tta_blend_rate: float = float(tta["tta_blend_rate"])
	var tta_zero_current_decay: float = float(tta["tta_zero_current_decay"])
	# DataCore（climate-datacore-migration A-4）：取数入口分支化（Ocean Water）
	var _dc_views: Dictionary = _generator._climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	var n: int = map.soa_size()
	var cells: Array[HexCell] = map.iter_cells()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	var temp_a: PackedFloat32Array = _dc_views["temp"] if _use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
	var elev_a: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
	var is_water_a: PackedByteArray = _dc_views["is_water"] if _use_dc else map.is_water_arr
	var pos_x_a: PackedFloat32Array = _dc_views["pos_x"] if _use_dc else map.cell_pos_x_arr
	var pos_y_a: PackedFloat32Array = _dc_views["pos_y"] if _use_dc else map.cell_pos_y_arr
	# seam-advection-fix：pos_x 是 size=1.0 单位空间的不环绕规范坐标，接缝邻居差分需折叠。
	# 与 C++ 内核（wrap_period_x knob / DCWorldExt 常驻值）取同一个周期。
	var wrap_px: float = HexUtils.wrap_period_cell_pos_x(int(map.width)) if map != null else 0.0
	var ocx_a: PackedFloat32Array = _dc_views["ocean_current_x"] if _use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = _dc_views["ocean_current_y"] if _use_dc else map.ocean_current_y_arr
	var lat_a: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
	# Phase 3a Step 2.1.a：ema_initialized SoA 别名
	var ema_init_a: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr

	# baseline + temp_before 快照。复用 PackedArray，避免每个 climate round 分配。
	# DOTS boundary：优先读 lat_norm SoA，避免逐 HexCell 调 _cube_row_norm。
	if _generator._gdext_ocean_baseline_work_buf.size() != n:
		_generator._gdext_ocean_baseline_work_buf.resize(n)
	if _generator._gdext_ocean_temp_before_work_buf.size() != n:
		_generator._gdext_ocean_temp_before_work_buf.resize(n)
	var baseline: PackedFloat32Array = _generator._gdext_ocean_baseline_work_buf
	var temp_before: PackedFloat32Array = _generator._gdext_ocean_temp_before_work_buf
	for i in range(n):
		if ema_init_a[i] != 0:
			baseline[i] = temp_baseline_a[i]
		else:
			var ny: float = lat_a[i] if lat_a.size() > i else _generator._cube_row_norm(cells[i], _generator._last_cfg)
			baseline[i] = _generator._compute_temperature(ny, elev_a[i])
		var t0: float = temp_a[i]
		temp_before[i] = _generator._valid_runtime_temp_or_baseline(t0, baseline[i])

	# ─── Phase F.2a：DCWorldExt C++ 快路径（charter §7 P1，3.4ms → < 0.5ms）──
	# baseline + temp_before 已经预算，不需要再翻译 _compute_temperature 到 C++。
	# 触发条件全 true 才进 C++。anomaly_out 是 [n] 浮点 scratch buffer，C++ 写
	# water cell 的 anomaly，land pass 后续覆盖 land cell。
	#
	# 与 F.5 同模板：精确诊断 print + sig probe + DEBUG print + fast-path
	if not _generator._gdext_ocean_water_first_attempt_logged:
		_generator._gdext_ocean_water_first_attempt_logged = true
		var cp_path_w: String = "<in-memory>"
		var flag_w: bool = true  # use_gdext_ocean_water flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path_w = cp.resource_path
		var ext_w_ok: bool = _generator._data_core_world_ext != null
		var has_w_ok: bool = ext_w_ok and _generator._data_core_world_ext.has_method("run_ocean_water_pass")
		var fast_w_ok: bool = nb_idx.size() >= n * 6
		var verdict_w: String = "OK → will try C++"
		if not (flag_w and ext_w_ok and has_w_ok and fast_w_ok):
			verdict_w = "FAIL → fall through to GDScript"
		print("[ocean_water/F.2a] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path_w)
		print("  cp.use_gdext_ocean_water = %s (flag removed; constant true)" % str(flag_w))
		print("  _data_core_world_ext != null = %s" % str(ext_w_ok))
		print("  ext.has_method('run_ocean_water_pass') = %s" % str(has_w_ok))
		print("  fast_indexed = %s (n=%d nb=%d)" % [str(fast_w_ok), n, nb_idx.size()])
		print("  advect_steps=%d heat_mix=%.4f" % [advect_steps, heat_mix])
		print("  verdict = %s" % verdict_w)

	if cp != null and _generator._data_core_world_ext != null \
			and _generator._data_core_world_ext.has_method("run_ocean_water_pass") and nb_idx.size() >= n * 6:
		if not _generator._gdext_ocean_water_signature_checked:
			_generator._gdext_ocean_water_signature_checked = true
			_generator._gdext_ocean_water_signature_ok = _generator._validate_gdext_method_signature("run_ocean_water_pass", 1)
			print("[ocean_water/F.2a] sig probe result = %s（仅作诊断）" % str(_generator._gdext_ocean_water_signature_ok))
		# C++ 会创建 fresh anomaly_out 并写回 knobs。这里传复用 buffer 只为满足
		# 旧签名，避免额外 cells → array 打包。
		if _generator._gdext_ocean_anomaly_work_buf.size() != n:
			_generator._gdext_ocean_anomaly_work_buf.resize(n)
		var anomaly_buf: PackedFloat32Array = _generator._gdext_ocean_anomaly_work_buf
		var prev_anomaly: PackedFloat32Array = _generator._prepare_temperature_transport_anomaly_state(map, n, cells)
		for ai in range(n):
			anomaly_buf[ai] = prev_anomaly[ai]
		var knobs_w: Dictionary = {
			"n_cells": n,
			"advect_steps": advect_steps,
			"heat_mix": heat_mix,
			"neighbor_indices": nb_idx,
			"baseline_arr": baseline,
			"temp_before_arr": temp_before,
			"anomaly_out": anomaly_buf,
			"ocean_current_x_arr": ocx_a,
			"ocean_current_y_arr": ocy_a,
			"cold_transport_form_threshold": float(cp.sea_ice_form_threshold) if cp.get("sea_ice_form_threshold") != null else 0.06,
			"cold_transport_melt_threshold": float(cp.sea_ice_melt_threshold) if cp.get("sea_ice_melt_threshold") != null else 0.11,
		}
		_generator._apply_temperature_transport_anomaly_knobs(knobs_w, tta)
		# storage A/B 同源契约（修复 B 2026-05-14）：climate_b 已 flush 到 map，
		# 但本 pass 还要读 map.is_water_arr / cell_lat_norm_arr 等静态/上一段写过的字段；
		# refresh 后保证 C++ slot 与 map 一致。详见 docs/architecture/migration.md。
		# refresh-consolidation-2026-06：climate_daily round 守门员。
		_generator._ensure_climate_daily_round_slots_fresh()
		# ─── sim-2ms-perf-push（plan/ocean-water-land-simd）派发 ─────────────
		# dots-flag-prune-pr1 round 2: use_gdext_ocean_water_simd / use_gdext_thread_fallback
		# flag 均已删除——恒走 C++ scalar 入口 run_ocean_water_pass，C++ 内部根据 CPU
		# 特性 / n_cells 自动选择 scalar / SIMD / threaded 三档执行路径。
		var _w_dispatch_path: String = "scalar"
		var rc_w: float = float(_generator._data_core_world_ext.run_ocean_water_pass(knobs_w))
		if rc_w < 0.0 and _generator._data_core_world_ext.has_method("run_ocean_water_pass_thread"):
			_w_dispatch_path = "thread_fallback"
			rc_w = float(_generator._data_core_world_ext.run_ocean_water_pass_thread(knobs_w, 4))
		if _generator._gdext_ocean_water_runs + _generator._gdext_ocean_water_fallbacks < 3:
			print("[ocean_water/F.2a] DEBUG call#%d: path=%s rc=%.4f n=%d advect=%d" % [
				_generator._gdext_ocean_water_runs + _generator._gdext_ocean_water_fallbacks + 1,
				_w_dispatch_path, rc_w, n, advect_steps,
			])
		if rc_w >= 0.0:
			# §11 CoW fix: C++ 创建了新的 anomaly 数组并写回了 knobs Dictionary。
			# 必须从 dict 重新读取，原始 anomaly_buf 因 CoW detach 仍是旧数据。
			anomaly_buf = knobs_w["anomaly_out"]
			# 不在 water pass 回写 HexCell.temperature_transport_anomaly：land pass
			# 会直接复用该 buffer，并在下一片统一回写。这样 ocean_water 不再承担
			# 2400 次 facade 属性写。
			# 顺便把 anomaly_buf 缓存给后续 land pass C++ 路径使用，避免再
			# 次 cells → PackedArray 拷贝（_apply_ocean_anomaly_to_cells 之后再清）
			_generator._gdext_ocean_anomaly_buf_cached = anomaly_buf
			# 把 baseline 也 stash 一份给 land pass 当 t_prev 兜底（修复正反馈 bug）
			_generator._gdext_ocean_baseline_arr_cached = baseline
			# ocean_current 同样 cache 给 land pass 复用。
			_generator._gdext_ocean_current_x_arr_cached = ocx_a
			_generator._gdext_ocean_current_y_arr_cached = ocy_a
			_generator._gdext_ocean_water_runs += 1
			_generator._gdext_ocean_water_total_ms += rc_w
			if _generator._gdext_ocean_water_runs == 1:
				print("[ocean_water/F.2a] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 3.4ms; charter §7 target < 0.5ms)" % rc_w)
			return
		_generator._gdext_ocean_water_fallbacks += 1
		# rc<0：C++ 已 push_warning；fall through 到下面 GDScript 完整路径


	push_error("[ocean/water] native failed: run_ocean_water_pass unavailable or returned failure; previous fields retained")
	return


func run_ocean_water_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	return _generator.run_climate_pass_slice(_generator._CLIMATE_PASS_OCEAN_WATER, map, season_phase)



func _run_ocean_water_pass_slice_impl(map: MapData, season_phase: float, token: int = 0) -> Dictionary:
	var cp: ClimateProfile = _generator._c()
	if _generator._climate_ocean_slice_state.is_empty() \
			or int(_generator._climate_ocean_slice_state.get("map_id", -1)) != map.get_instance_id():
		if not _generator._begin_ocean_heat_transport_sliced(map, season_phase, cp):
			return _generator._run_climate_pass_legacy_fallback(_generator._CLIMATE_PASS_OCEAN_WATER, map, season_phase, token, "native_unavailable")
	var n: int = int(_generator._climate_ocean_slice_state.get("n", 0))
	var start: int = int(_generator._climate_ocean_slice_state.get("water_cursor", 0))
	var end: int = mini(n, start + _generator._ocean_slice_budget_cells())
	var knobs: Dictionary = _generator._climate_ocean_slice_state["water_knobs"]
	knobs["start_idx"] = start
	knobs["end_idx"] = end
	var rc: float = float(_generator._data_core_world_ext.run_ocean_water_pass(knobs))
	if rc < 0.0:
		_generator._climate_ocean_slice_state.clear()
		_generator._climate_pass_states.erase(_generator._CLIMATE_PASS_OCEAN_WATER)
		return _generator._run_climate_pass_legacy_fallback(_generator._CLIMATE_PASS_OCEAN_WATER, map, season_phase, token, "native_failed")
	var anomaly: PackedFloat32Array = knobs["anomaly_out"]
	_generator._climate_ocean_slice_state["anomaly"] = anomaly
	_generator._climate_ocean_slice_state["water_cursor"] = end
	var land_knobs: Dictionary = _generator._climate_ocean_slice_state["land_knobs"]
	land_knobs["anomaly_inout"] = anomaly
	_generator._gdext_ocean_anomaly_buf_cached = anomaly
	_generator._gdext_ocean_baseline_arr_cached = _generator._climate_ocean_slice_state["baseline"]
	# Incremental publish (climate-pipeline-spike-reduction)：每片都把当前 anomaly
	# 推到 map / DCWorld dense buffer，避免 budget=2ms 节奏下 round 跨多帧时读方
	# (weather field_solver / map_generator feedback 路径) 长时间读到陈旧的洋流热
	# 输运。区间外格子保留上一片旧值（C++ run_ocean_water_pass §11 CoW duplicate
	# 保证），即「水格新值 + 陆格旧值」的混合态——比「完全冻结到几日前」好得多。
	map.temperature_transport_anomaly_arr = anomaly
	if _generator._data_core_world != null:
		var _cid_tta_inc_w: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_inc_w >= 0 and _generator._data_core_world.has_method("write_f32_dense"):
			_generator._data_core_world.write_f32_dense(_cid_tta_inc_w, anomaly)
	# A2 增量回写 HexCell.temperature_transport_anomaly：该字段尚未 facade 化
	# (HexCell 内是裸 var)，baker / info_panel / weather fallback 都通过
	# cell.temperature_transport_anomaly 这条 AoS 路径读，必须显式赋值。仅写当
	# 前 slice 区间，开销 ~slice_budget 个 cell 一次循环（≤0.05ms 量级），区间外
	# 保留上一片旧值，配合 land 阶段最终 done 全图回写，渲染层可逐片看到合并视图。
	var _cells_inc_w: Array = _generator._climate_ocean_slice_state.get("cells", [])
	if _cells_inc_w.size() == n:
		for _ci_w in range(start, end):
			var _c_w = _cells_inc_w[_ci_w]
			if _c_w != null:
				_c_w.temperature_transport_anomaly = anomaly[_ci_w]
	var done: bool = end >= n
	if _generator._climate_pass_states.has(_generator._CLIMATE_PASS_OCEAN_WATER):
		var state: Dictionary = _generator._climate_pass_states[_generator._CLIMATE_PASS_OCEAN_WATER]
		state["water_cursor"] = end
		state["cursor_start"] = start
		state["cursor_end"] = end
		state["processed_cells"] = end - start
		state["status"] = _generator._CLIMATE_PASS_STATUS_DONE if done else _generator._CLIMATE_PASS_STATUS_RUNNING
		_generator._climate_pass_states[_generator._CLIMATE_PASS_OCEAN_WATER] = state
	if done:
		_generator._climate_pass_states.erase(_generator._CLIMATE_PASS_OCEAN_WATER)
	return _generator._make_climate_pass_result(_generator._CLIMATE_PASS_OCEAN_WATER, done, rc, end - start, start, end, _generator._CLIMATE_PASS_STATUS_DONE if done else _generator._CLIMATE_PASS_STATUS_RUNNING, token, "ocean_water")
