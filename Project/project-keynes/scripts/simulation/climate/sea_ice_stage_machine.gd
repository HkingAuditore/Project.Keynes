extends RefCounted

## Runs the sea-ice job's setup, sliced work, and climate-day accounting.


static func _sea_ice_slice_budget_cells(context) -> int:
	var cp = context._generator._c()
	var slice_ms: float = 0.75
	if cp != null and cp.get("sim_slice_budget_ms") != null:
		slice_ms = float(cp.sim_slice_budget_ms)
	return clampi(int(round(512.0 * clampf(slice_ms / 0.75, 0.5, 2.0))), 128, 1024)

static func _sea_ice_insolation_input(context, map: MapData, cells: Array, season_phase: float) -> PackedFloat32Array:
	var n_cells: int = cells.size()
	if map != null and map.insolation_now_arr.size() == n_cells:
		# Live slot first: the freeze gate and solar melt must see today's sun, and
		# Pass-A only mirrors insolation into MapData at the round boundary.
		return context._generator._get_native_daily_bundle_builder()._native_daily_live_f32("cell_insolation_now", map.insolation_now_arr, n_cells)
	if context._generator._gdext_sea_ice_insol_buf.size() != n_cells:
		context._generator._gdext_sea_ice_insol_buf.resize(n_cells)
	for i in range(n_cells):
		var c: HexCell = cells[i]
		context._generator._gdext_sea_ice_insol_buf[i] = context._generator._compute_insolation(context._generator._cube_row_norm(c, context._generator._last_cfg), season_phase) \
			if c != null and context._generator._last_cfg != null else 0.0
	return context._generator._gdext_sea_ice_insol_buf

static func _abort_sea_ice_state_machine(context, reason: String = "abort") -> void:
	if context._generator._sea_ice_state_machine.is_empty():
		return
	context._generator._sea_ice_state_machine["status"] = context._generator._CLIMATE_PASS_STATUS_ABORTED
	context._generator._sea_ice_state_machine["abort_reason"] = reason
	context._generator._sea_ice_state_machine["ended_msec"] = Time.get_ticks_msec()
	context._generator._sea_ice_state_machine = {}

static func _begin_sea_ice_state_machine(context, map: MapData, season_phase: float, token: int) -> bool:
	if map == null or context._generator._last_cfg == null:
		return false
	var cp = context._generator._c()
	if cp == null:
		return false
	var cells_fast: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_fast: int = cells_fast.size()
	var nb_idx_fast: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = nb_idx_fast.size() >= n_cells_fast * 6
	if context._generator._data_core_world_ext == null \
			or not context._generator._data_core_world_ext.has_method("run_sea_ice_daily_pass") \
			or not fast_indexed:
		return false
	if not context._generator._gdext_sea_ice_signature_checked:
		context._generator._gdext_sea_ice_signature_checked = true
		context._generator._gdext_sea_ice_signature_ok = context._generator._validate_gdext_method_signature("run_sea_ice_daily_pass", 2)
		print("[sea_ice/F.4] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(context._generator._gdext_sea_ice_signature_ok))

	var k_freeze: float = float(cp.sea_ice_freeze_rate)
	var k_melt: float = float(cp.sea_ice_melt_rate)
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var contagion: float = float(cp.sea_ice_neighbor_contagion)
	var threshold: float = float(cp.sea_ice_terrain_threshold)
	var hysteresis: float = float(cp.sea_ice_terrain_hysteresis)
	var ice_delay: float = float(context._generator._last_cfg.OCEAN_CURRENT_ICE_DELAY)
	var climate_anomaly_now: float = 0.0
	if context._generator._world_clock_ref != null:
		var ca_v = context._generator._world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = 0.10 * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)

	# ─── sea_ice dt_days 补偿（状态机入口路径）────────────────────────────
	# C++ 接收 per-day k 与 dt_days，避免 sliced 调度间隔造成 dt^2 过冲。
	var dt_days: float = context._generator._consume_sea_ice_dt_days()
	var k_freeze_scaled: float = k_freeze * dt_days
	var k_melt_scaled: float = k_melt * dt_days

	var t_total_us: int = Time.get_ticks_usec()
	var t_pack_us: int = Time.get_ticks_usec()
	var base_terrain_input: PackedByteArray
	if map.base_terrain_arr.size() == n_cells_fast:
		base_terrain_input = map.base_terrain_arr
	else:
		if context._generator._gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
			context._generator._gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
		base_terrain_input = context._generator._gdext_sea_ice_base_terrain_buf
		for i_build in range(n_cells_fast):
			var c_build: HexCell = cells_fast[i_build]
			context._generator._gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
	var tta_input: PackedFloat32Array
	if context._generator._gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
		tta_input = context._generator._gdext_ocean_anomaly_buf_cached
	elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
		tta_input = map.temperature_transport_anomaly_arr
	else:
		if context._generator._gdext_sea_ice_tta_buf.size() != n_cells_fast:
			context._generator._gdext_sea_ice_tta_buf.resize(n_cells_fast)
		tta_input = context._generator._gdext_sea_ice_tta_buf
		for i_tta in range(n_cells_fast):
			tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
	var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
			if map.upwelling_strength_arr.size() == n_cells_fast \
			else context._generator._gdext_sea_ice_upw_buf
	if upw_input.size() != n_cells_fast:
		context._generator._gdext_sea_ice_upw_buf.resize(n_cells_fast)
		upw_input = context._generator._gdext_sea_ice_upw_buf
		for i_upw in range(n_cells_fast):
			upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
	var temp_input: PackedFloat32Array = map.temp_arr \
			if map.temp_arr.size() == n_cells_fast \
			else context._generator._gdext_sea_ice_temp_buf
	if temp_input.size() != n_cells_fast:
		context._generator._gdext_sea_ice_temp_buf.resize(n_cells_fast)
		temp_input = context._generator._gdext_sea_ice_temp_buf
		for i_temp in range(n_cells_fast):
			temp_input[i_temp] = cells_fast[i_temp].temperature
	var insol_input: PackedFloat32Array = context._generator._sea_ice_insolation_input(map, cells_fast, season_phase)
	var pack_ms: float = (Time.get_ticks_usec() - t_pack_us) / 1000.0
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	var knobs: Dictionary = {
		"n_cells": n_cells_fast,
		# C++ 端会用 dt_days 乘一次；这里传原始 per-day 速率，避免 dt^2 过冲。
		"k_freeze": k_freeze,
		"k_melt": k_melt,
		"dt_days": dt_days,
		"t_form": t_form,
		"t_melt": t_melt,
		"contagion": contagion,
		"threshold": threshold,
		"hysteresis": hysteresis,
		"ice_delay": ice_delay,
		"enable_ocean_heat_transport": bool(context._generator._last_cfg.enable_ocean_heat_transport),
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": water_ids,
		"neighbor_indices": nb_idx_fast,
		"base_terrain_arr": base_terrain_input,
		"temp_transport_anomaly": tta_input,
		"upwelling_strength": upw_input,
		"insolation_now_arr": insol_input,
		"solar_gate_enabled": context._generator._sea_ice_solar_gate_enabled(cp),
		"freeze_insol_low": float(cp.sea_ice_freeze_insol_low),
		"freeze_insol_high": float(cp.sea_ice_freeze_insol_high),
		"solar_melt_start": float(cp.sea_ice_solar_melt_start),
		"solar_melt_gain": float(cp.sea_ice_solar_melt_gain),
		"min_thick_ice_solar_exposure": float(cp.sea_ice_min_thick_ice_solar_exposure) if cp.get("sea_ice_min_thick_ice_solar_exposure") != null else 0.32,
		"daily_delta_cap": float(cp.sea_ice_daily_delta_cap) if cp.get("sea_ice_daily_delta_cap") != null else 0.070,
		"edge_mix_rate": float(cp.sea_ice_edge_mix_rate) if cp.get("sea_ice_edge_mix_rate") != null else 0.035,
		"cell_temperature_arr": temp_input,
	}
	var refresh_ms: float = 0.0
	if context._generator._data_core_world_ext.has_method("refresh_slots_from_map"):
		var t_refresh_us: int = Time.get_ticks_usec()
		context._generator._data_core_world_ext.refresh_slots_from_map()
		refresh_ms = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
	# [BUG-FIX 2026-05-23 海冰看似不动] 在 C++ pass 修改 SIF 之前，先 snapshot
	# pre-pass 状态。dense_sync_chunk 阶段会用它和 post-pass 比对，对真正变化
	# 的 cell 调 mark_dirty_indexed —— 否则 atlas pipeline 永远拿不到 SIF dirty。
	# 见 _run_sea_ice_state_machine_slice DENSE_SYNC_CHUNK 分支注释。
	var pre_sif_snapshot: PackedFloat32Array = PackedFloat32Array()
	if map.sea_ice_frac_arr.size() == n_cells_fast:
		pre_sif_snapshot = map.sea_ice_frac_arr.duplicate()
	var t_native_us: int = Time.get_ticks_usec()
	var rc: float = float(context._generator._data_core_world_ext.run_sea_ice_daily_pass(knobs, season_phase))
	var dispatch_path: String = "scalar"
	if rc < 0.0 and context._generator._data_core_world_ext.has_method("run_sea_ice_daily_pass_thread"):
		dispatch_path = "thread_fallback"
		rc = float(context._generator._data_core_world_ext.run_sea_ice_daily_pass_thread(knobs, season_phase, 4))
	var native_wall_ms: float = (Time.get_ticks_usec() - t_native_us) / 1000.0
	if rc < 0.0:
		context._generator._gdext_sea_ice_fallbacks += 1
		return false
	var facade_on: bool = false
	if n_cells_fast > 0 and cells_fast[0] != null:
		var c0_sync: HexCell = cells_fast[0] as HexCell
		facade_on = c0_sync != null and c0_sync.is_facade_enabled()
	context._generator._sea_ice_state_machine = {
		"token": token,
		"map_id": map.get_instance_id(),
		"season_phase": season_phase,
		"stage": context._generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK,
		"cells": cells_fast,
		"n": n_cells_fast,
		"facade_on": facade_on,
		"sync_cursor": 0,
		"flip_cursor": 0,
		"flip_to_ice_list": knobs.get("flip_to_ice_list", PackedInt32Array()),
		"flip_to_base_list": knobs.get("flip_to_base_list", PackedInt32Array()),
		"flip_to_base_terrain": knobs.get("flip_to_base_terrain", PackedByteArray()),
		"pack_ms": pack_ms,
		"refresh_ms": refresh_ms,
		"native_ms": rc,
		"native_wall_ms": native_wall_ms,
		"sync_ms": 0.0,
		"flip_ms": 0.0,
		"total_start_us": t_total_us,
		"water": int(knobs.get("stat_water_count", 0)),
		"flipped": int(knobs.get("stat_flipped_count", 0)),
		"dispatch_path": dispatch_path,
		# [BUG-FIX 2026-05-23 海冰看似不动] pre-pass SIF 快照：dense_sync_chunk 用
		# 来比对找真正变化 cell + 显式 mark_dirty_indexed。见同函数注释。
		"pre_sif_snapshot": pre_sif_snapshot,
		"dirty_marked_count": 0,
	}
	# [DIAG 2026-05-23] 海冰不动排障：状态机入口（实际运行主路径）。
	# 每个日历年长 + 前 5 次打印一次温度 / SIF 分布。
	# 关键问诊：t_eff 实际有没有 < t_form？SIF 是否在累积但卡在 threshold 下？
	if context._generator._gdext_sea_ice_runs < 5 or context._generator._is_annual_log_tick(context._generator._gdext_sea_ice_runs):
		var _diag_water: int = 0
		var _diag_below_form: int = 0
		var _diag_sif_pos: int = 0
		var _diag_sif_near_thr: int = 0
		var _diag_t_min: float = 9.99
		var _diag_t_max: float = -9.99
		var _diag_t_sum: float = 0.0
		var _diag_t_min_water: float = 9.99
		var _diag_sif_max: float = 0.0
		var _diag_sif_sum: float = 0.0
		var _diag_d_frac_max: float = 0.0    # 单 cell 单 pass 最大 d_frac 估算
		var _terrain_arr_diag: PackedByteArray = map.terrain_arr
		var _sif_arr_diag: PackedFloat32Array = map.sea_ice_frac_arr
		var _temp_n: int = temp_input.size()
		var _sif_n: int = _sif_arr_diag.size()
		var _terr_n: int = _terrain_arr_diag.size()
		for _i_diag in range(n_cells_fast):
			var _t_d: float = temp_input[_i_diag] if _i_diag < _temp_n else 0.0
			if _t_d < _diag_t_min: _diag_t_min = _t_d
			if _t_d > _diag_t_max: _diag_t_max = _t_d
			_diag_t_sum += _t_d
			var _terr_d: int = int(_terrain_arr_diag[_i_diag]) if _i_diag < _terr_n else -1
			var _is_w: bool = (_terr_d == int(TerrainType.TERRAIN.OCEAN) \
				or _terr_d == int(TerrainType.TERRAIN.COAST) \
				or _terr_d == int(TerrainType.TERRAIN.REEF) \
				or _terr_d == int(TerrainType.TERRAIN.KELP) \
				or _terr_d == int(TerrainType.TERRAIN.SEA_ICE))
			if _is_w:
				_diag_water += 1
				if _t_d < _diag_t_min_water: _diag_t_min_water = _t_d
				if _t_d < t_form:
					_diag_below_form += 1
					var _df: float = k_freeze_scaled * (t_form - _t_d)
					if _df > _diag_d_frac_max: _diag_d_frac_max = _df
				var _sf_d: float = _sif_arr_diag[_i_diag] if _i_diag < _sif_n else 0.0
				_diag_sif_sum += _sf_d
				if _sf_d > _diag_sif_max: _diag_sif_max = _sf_d
				if _sf_d > 0.01: _diag_sif_pos += 1
				if _sf_d >= threshold * 0.5 and _sf_d < threshold: _diag_sif_near_thr += 1
		var _avg_t: float = _diag_t_sum / max(1, n_cells_fast)
		var _avg_sif_w: float = _diag_sif_sum / max(1, _diag_water)
		# [DIAG 2026-05-23 四轮] 海冰看似不动排障：把 C++ 端写回的 flip 列表 + 计数也打出来。
		# 关键问诊：terrain 真的没翻吗？flip_to_ice_list 有没有元素？
		var _flip_to_ice_diag: PackedInt32Array = knobs.get("flip_to_ice_list", PackedInt32Array())
		var _flip_to_base_diag: PackedInt32Array = knobs.get("flip_to_base_list", PackedInt32Array())
		var _stat_water_diag: int = int(knobs.get("stat_water_count", 0))
		var _stat_flipped_diag: int = int(knobs.get("stat_flipped_count", 0))
		# 当前 terrain 已是 SEA_ICE 的 cell 数（用于交叉核对：若已翻 cell 多但 SIF avg_w 仍低 = 渲染层问题）
		var _existing_ice_terrain: int = 0
		for _i_terr in range(n_cells_fast):
			if _i_terr < _terr_n and int(_terrain_arr_diag[_i_terr]) == int(TerrainType.TERRAIN.SEA_ICE):
				_existing_ice_terrain += 1
		print("[sea_ice/DIAG-SM] run#%d phase=%.3f | thr_eff t_form=%.3f t_melt=%.3f flip_thr=%.3f | k_f=%.3f k_m=%.3f dt=%.2f | temp all min=%.3f max=%.3f avg=%.3f | water n=%d t_min_w=%.3f below_form=%d (%.1f%%) max_dfrac=%.4f | SIF pos=%d max=%.3f avg_w=%.4f near_thr=%d | FLIP to_ice=%d to_base=%d stat_water=%d stat_flipped=%d existing_ice_terr=%d | climate_anom=%.3f" % [
			context._generator._gdext_sea_ice_runs + 1, season_phase,
			t_form, t_melt, threshold,
			k_freeze_scaled, k_melt_scaled, dt_days,
			_diag_t_min, _diag_t_max, _avg_t,
			_diag_water, _diag_t_min_water,
			_diag_below_form, 100.0 * float(_diag_below_form) / max(1, _diag_water), _diag_d_frac_max,
			_diag_sif_pos, _diag_sif_max, _avg_sif_w, _diag_sif_near_thr,
			_flip_to_ice_diag.size(), _flip_to_base_diag.size(),
			_stat_water_diag, _stat_flipped_diag, _existing_ice_terrain,
			climate_anomaly_now,
		])
	context._generator._gdext_sea_ice_runs += 1
	context._generator._gdext_sea_ice_total_ms += rc
	return true

static func _run_sea_ice_state_machine_slice(context, map: MapData, season_phase: float, token: int) -> Dictionary:
	if context._generator._sea_ice_state_machine.is_empty() \
			or int(context._generator._sea_ice_state_machine.get("map_id", -1)) != map.get_instance_id() \
			or int(context._generator._sea_ice_state_machine.get("token", 0)) != token:
		if not context._generator._begin_sea_ice_state_machine(map, season_phase, token):
			var fb: Dictionary = context._generator._run_climate_pass_legacy_fallback(context._generator._CLIMATE_PASS_SEA_ICE, map, season_phase, token, "native_unavailable")
			context._generator._climate_pass_states.erase(context._generator._CLIMATE_PASS_SEA_ICE)
			return fb
		var native_result: Dictionary = context._generator._make_climate_pass_result(context._generator._CLIMATE_PASS_SEA_ICE, false, 0.0, 0, 0, 0, context._generator._CLIMATE_PASS_STATUS_RUNNING, token, context._generator._SEA_ICE_STAGE_NATIVE_COMPUTE)
		native_result["cursor_remaining"] = int(context._generator._sea_ice_state_machine.get("n", 0))
		native_result["budget_cells"] = context._generator._sea_ice_slice_budget_cells()
		return native_result
	var stage: String = str(context._generator._sea_ice_state_machine.get("stage", context._generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK))
	var n: int = int(context._generator._sea_ice_state_machine.get("n", 0))
	var budget: int = context._generator._sea_ice_slice_budget_cells()
	if stage == context._generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK:
		var sync_start: int = int(context._generator._sea_ice_state_machine.get("sync_cursor", 0))
		var sync_end: int = mini(n, sync_start + budget)
		var t_sync_us: int = Time.get_ticks_usec()
		if bool(context._generator._sea_ice_state_machine.get("facade_on", false)) and context._generator._data_core_world != null and map.sea_ice_frac_arr.size() >= n:
			var cid_si: int = context._generator._data_core_world.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)
			if cid_si >= 0 and context._generator._data_core_world.has_method("write_f32_indexed"):
				var idx: PackedInt32Array = PackedInt32Array()
				var vals: PackedFloat32Array = PackedFloat32Array()
				idx.resize(sync_end - sync_start)
				vals.resize(sync_end - sync_start)
				for k in range(sync_end - sync_start):
					var ci: int = sync_start + k
					idx[k] = ci
					vals[k] = map.sea_ice_frac_arr[ci]
				context._generator._data_core_world.write_f32_indexed(cid_si, idx, vals)
				# [B-Surgical 2026-05-23 海冰看似不动] 同步写 DCWorldExt 的 SIF slot。
				# 真因：C++ ice atlas raster（world_ext.cpp::encode_ice_state_atlas_*）
				# 从 DCWorldExt 自己的 cell_sea_ice_frac slot.arr_f32 读，不读
				# MapData.sea_ice_frac_arr，也不读 GDScript DCWorld。状态机只写
				# MapData + GDScript DCWorld，DCWorldExt slot 永远停留在初始 0 →
				# atlas pixel 全 0 → 视觉上海冰一直不动。
				# 修复：在已经备好 idx/vals 的同一处，向 DCWorldExt 镜像一次。
				# 双 world 架构由 GDScript DCWorld（ECS 容器）+ DCWorldExt（C++ 镜像
				# slot）组成，本来就是 superset/subset 关系；这里属于补足缺失的一条
				# 镜像链路（B-Surgical），不动其它系统的写入路径。
				# 见 docs/architecture/development-guide.md。
				if context._generator._data_core_world_ext != null \
						and context._generator._data_core_world_ext.has_method("write_f32_indexed") \
						and context._generator._data_core_world_ext.has_method("component_id"):
					# [B-Surgical 命名空间不一致] DCComponentIds 用点号风格
					# (`cell.sea_ice_frac`)，但 DCWorldExt 的 BIND_TABLE 用下划线
					# 风格 (`cell_sea_ice_frac`，见 component_bind_table.gen.h)。
					# C++ component_id 是按字面量 hash 查表，找不到点号版本。
					# 这里两种都试一遍，下划线版作为 ext 端的真名 fallback。
					var cid_si_ext: int = int(context._generator._data_core_world_ext.component_id(DCComponentIds.CELL_SEA_ICE_FRAC))
					if cid_si_ext < 0:
						cid_si_ext = int(context._generator._data_core_world_ext.component_id(&"cell_sea_ice_frac"))
					if cid_si_ext >= 0:
						context._generator._data_core_world_ext.write_f32_indexed(cid_si_ext, idx, vals)
				# [BUG-FIX 2026-05-23 海冰看似不动] C++ sea_ice pass 直接改 DCWorld
				# slot.arr_f32 + _flush_slot_to_map(set MapData)，slot 已是新值。
				# 上面 write_f32_indexed 的 value-diff 因此命中"未变" → 不 mark dirty
				# → atlas_pipeline read_and_clear_dirty_mask 拿不到 SIF 变化 cell
				# → ice_state_atlas 永远空 → 海冰看似不动。
				# 修复：用 _begin 时缓存的 pre-pass SIF 快照比对 + 显式 mark_dirty_indexed。
				# 海冰 pass 一天一次，开销可接受。
				if context._generator._data_core_world.has_method("mark_dirty_indexed"):
					var pre_arr: PackedFloat32Array = context._generator._sea_ice_state_machine.get("pre_sif_snapshot", PackedFloat32Array())
					if pre_arr.size() >= sync_end:
						var dirty_idx: PackedInt32Array = PackedInt32Array()
						dirty_idx.resize(sync_end - sync_start)
						var dw: int = 0
						# [DIAG 2026-05-23 海冰排障第二轮] 收集 SIF>0 的 dirty cell 计数
						# + 最大 SIF 值，用来核对 atlas COMMIT 收到的 nonzero=0 是否
						# 因为 dirty_idx 里的 cell SIF 实际上都是 0（量化后 byte=0）。
						var dw_pos: int = 0
						var dw_sif_max: float = 0.0
						for k2 in range(sync_end - sync_start):
							var ci2: int = sync_start + k2
							var v_now: float = map.sea_ice_frac_arr[ci2]
							if v_now != pre_arr[ci2]:
								dirty_idx[dw] = ci2
								dw += 1
								if v_now > 0.0:
									dw_pos += 1
									if v_now > dw_sif_max:
										dw_sif_max = v_now
						if dw > 0:
							dirty_idx.resize(dw)
							context._generator._data_core_world.mark_dirty_indexed(dirty_idx)
							context._generator._sea_ice_state_machine["dirty_marked_count"] = int(context._generator._sea_ice_state_machine.get("dirty_marked_count", 0)) + dw
							context._generator._sea_ice_state_machine["dirty_marked_sif_pos"] = int(context._generator._sea_ice_state_machine.get("dirty_marked_sif_pos", 0)) + dw_pos
							var prev_max: float = float(context._generator._sea_ice_state_machine.get("dirty_marked_sif_max", 0.0))
							if dw_sif_max > prev_max:
								context._generator._sea_ice_state_machine["dirty_marked_sif_max"] = dw_sif_max
			else:
				var cells_sync: Array = context._generator._sea_ice_state_machine.get("cells", [])
				for i_sync in range(sync_start, sync_end):
					(cells_sync[i_sync] as HexCell).sea_ice_fraction = map.sea_ice_frac_arr[i_sync]
		else:
			var cells_sync_fb: Array = context._generator._sea_ice_state_machine.get("cells", [])
			for i_sync_fb in range(sync_start, sync_end):
				(cells_sync_fb[i_sync_fb] as HexCell).sea_ice_fraction = map.sea_ice_frac_arr[i_sync_fb]
		context._generator._sea_ice_state_machine["sync_ms"] = float(context._generator._sea_ice_state_machine.get("sync_ms", 0.0)) + (Time.get_ticks_usec() - t_sync_us) / 1000.0
		context._generator._sea_ice_state_machine["sync_cursor"] = sync_end
		if sync_end >= n:
			context._generator._sea_ice_state_machine["stage"] = context._generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK
		var sync_result: Dictionary = context._generator._make_climate_pass_result(context._generator._CLIMATE_PASS_SEA_ICE, false, (Time.get_ticks_usec() - t_sync_us) / 1000.0,
				sync_end - sync_start, sync_start, sync_end, context._generator._CLIMATE_PASS_STATUS_RUNNING, token, context._generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK)
		sync_result["cursor_remaining"] = maxi(0, n - sync_end)
		sync_result["budget_cells"] = budget
		sync_result["next_stage"] = str(context._generator._sea_ice_state_machine.get("stage", context._generator._SEA_ICE_STAGE_DENSE_SYNC_CHUNK))
		return sync_result
	if stage == context._generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK:
		var flip_to_ice_list: PackedInt32Array = context._generator._sea_ice_state_machine.get("flip_to_ice_list", PackedInt32Array())
		var flip_to_base_list: PackedInt32Array = context._generator._sea_ice_state_machine.get("flip_to_base_list", PackedInt32Array())
		var flip_to_base_terrain: PackedByteArray = context._generator._sea_ice_state_machine.get("flip_to_base_terrain", PackedByteArray())
		var total_flips: int = flip_to_ice_list.size() + flip_to_base_list.size()
		var flip_start: int = int(context._generator._sea_ice_state_machine.get("flip_cursor", 0))
		var flip_end: int = mini(total_flips, flip_start + budget)
		var t_flip_us: int = Time.get_ticks_usec()
		var flip_batch: Dictionary = context._generator._build_sea_ice_flip_batch(flip_to_ice_list, flip_to_base_list, flip_to_base_terrain, flip_start, flip_end)
		var flip_diag: Dictionary = context._generator._apply_sea_ice_terrain_flips_indexed(
				map,
				flip_batch.get("indices", PackedInt32Array()),
				flip_batch.get("terrain", PackedByteArray()),
				true)
		if bool(flip_diag.get("applied", false)):
			context._generator._sea_ice_state_machine["terrain_flip_indexed_count"] = int(context._generator._sea_ice_state_machine.get("terrain_flip_indexed_count", 0)) + int(flip_diag.get("count", 0))
		else:
			context._generator._sea_ice_state_machine["terrain_flip_legacy_fallback"] = true
			context._generator._sea_ice_state_machine["terrain_flip_fallback_reason"] = str(flip_diag.get("fallback_reason", "unknown"))
			var sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
			for f in range(flip_start, flip_end):
				if f < flip_to_ice_list.size():
					var idx_i: int = flip_to_ice_list[f]
					if idx_i >= 0 and idx_i < n:
						var sm_cell_i: HexCell = map.cell_at(idx_i)
						if sm_cell_i != null:
							context._generator._set_cell_runtime_terrain(map, sm_cell_i, sea_ice_id, true, -1.0, sm_cell_i.snow_cover)
				else:
					var base_i: int = f - flip_to_ice_list.size()
					var idx_b: int = flip_to_base_list[base_i]
					if idx_b >= 0 and idx_b < n and base_i < flip_to_base_terrain.size():
						var target_terr: int = int(flip_to_base_terrain[base_i])
						var sm_cell_b: HexCell = map.cell_at(idx_b)
						if sm_cell_b != null:
							context._generator._set_cell_runtime_terrain(map, sm_cell_b, target_terr, true, -1.0, sm_cell_b.snow_cover)
		context._generator._sea_ice_state_machine["flip_ms"] = float(context._generator._sea_ice_state_machine.get("flip_ms", 0.0)) + (Time.get_ticks_usec() - t_flip_us) / 1000.0
		context._generator._sea_ice_state_machine["flip_cursor"] = flip_end
		if flip_end >= total_flips:
			context._generator._sea_ice_state_machine["stage"] = context._generator._SEA_ICE_STAGE_COMMIT
		var flip_result: Dictionary = context._generator._make_climate_pass_result(context._generator._CLIMATE_PASS_SEA_ICE, false, (Time.get_ticks_usec() - t_flip_us) / 1000.0,
				flip_end - flip_start, flip_start, flip_end, context._generator._CLIMATE_PASS_STATUS_RUNNING, token, context._generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK)
		flip_result["cursor_remaining"] = maxi(0, total_flips - flip_end)
		flip_result["budget_cells"] = budget
		flip_result["next_stage"] = str(context._generator._sea_ice_state_machine.get("stage", context._generator._SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK))
		flip_result["terrain_flip_path"] = "legacy_set_cell_runtime_terrain" if bool(context._generator._sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)) else "indexed"
		flip_result["terrain_flip_count"] = int(context._generator._sea_ice_state_machine.get("terrain_flip_indexed_count", 0))
		flip_result["fallback_reason"] = str(context._generator._sea_ice_state_machine.get("terrain_flip_fallback_reason", ""))
		return flip_result
	var t_commit_us: int = Time.get_ticks_usec()
	if bool(context._generator._sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)):
		context._generator._write_runtime_enum_axes_dense(map)
	var water_count: int = int(context._generator._sea_ice_state_machine.get("water", 0))
	var flipped_count: int = int(context._generator._sea_ice_state_machine.get("flipped", 0))
	# [BUG-FIX 2026-05-23 海冰看似不动] 诊断：本 pass 我们显式 mark_dirty 的 cell 数。
	# 期望：当 SIF 有变化时 dirty_marked > 0；若仍 ==0 而 SIF 在变，说明 fix 没生效。
	# 节流：前 5 次 + 每个日历年长（与 DIAG-SM 同步）。
	var _dirty_marked_count: int = int(context._generator._sea_ice_state_machine.get("dirty_marked_count", 0))
	if context._generator._gdext_sea_ice_runs <= 5 or context._generator._is_annual_log_tick(context._generator._gdext_sea_ice_runs):
		print("[sea_ice/DIRTY-MARK] run#%d marked_dirty_cells=%d (sif_pos=%d sif_max=%.4f) water=%d flipped=%d" % [
			context._generator._gdext_sea_ice_runs, _dirty_marked_count,
			int(context._generator._sea_ice_state_machine.get("dirty_marked_sif_pos", 0)),
			float(context._generator._sea_ice_state_machine.get("dirty_marked_sif_max", 0.0)),
			water_count, flipped_count
		])
	if water_count > 0:
		var ratio: float = float(flipped_count) / float(water_count)
		if ratio > 0.03:
			push_warning("[sea_ice_daily/F.4] %d/%d (%.1f%%) cells flipped on phase=%.3f — possible bulk-switch regression" % [
				flipped_count, water_count, ratio * 100.0, season_phase
			])
	context._generator._last_sea_ice_daily_breakdown = {
		"path": "gdext_state_machine",
		"stage": context._generator._SEA_ICE_STAGE_COMMIT,
		"pack_ms": float(context._generator._sea_ice_state_machine.get("pack_ms", 0.0)),
		"refresh_ms": float(context._generator._sea_ice_state_machine.get("refresh_ms", 0.0)),
		"native_ms": float(context._generator._sea_ice_state_machine.get("native_ms", 0.0)),
		"native_wall_ms": float(context._generator._sea_ice_state_machine.get("native_wall_ms", 0.0)),
		"sync_ms": float(context._generator._sea_ice_state_machine.get("sync_ms", 0.0)),
		"flip_ms": float(context._generator._sea_ice_state_machine.get("flip_ms", 0.0)),
		"terrain_flip_path": "legacy_set_cell_runtime_terrain" if bool(context._generator._sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)) else "indexed",
		"terrain_flip_count": int(context._generator._sea_ice_state_machine.get("terrain_flip_indexed_count", 0)),
		"terrain_flip_fallback_reason": str(context._generator._sea_ice_state_machine.get("terrain_flip_fallback_reason", "")),
		"commit_ms": (Time.get_ticks_usec() - t_commit_us) / 1000.0,
		"total_wall_ms": (Time.get_ticks_usec() - int(context._generator._sea_ice_state_machine.get("total_start_us", Time.get_ticks_usec()))) / 1000.0,
		"water": water_count,
		"flipped": flipped_count,
	}
	context._generator._dump_sea_ice_breakdown_if_slow()
	context._generator._gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
	context._generator._climate_pass_states.erase(context._generator._CLIMATE_PASS_SEA_ICE)
	context._generator._sea_ice_state_machine = {}
	return context._generator._make_climate_pass_result(context._generator._CLIMATE_PASS_SEA_ICE, true, (Time.get_ticks_usec() - t_commit_us) / 1000.0,
			0, -1, -1, context._generator._CLIMATE_PASS_STATUS_DONE, token, context._generator._SEA_ICE_STAGE_COMMIT)

# ─── [S2 fix 2026-05-23 三轮] sea_ice dt_days 补偿辅助函数 ────────────────────
# 抽自原 _apply_sea_ice_daily_pass 内联段。两条调用链共用：
#   - SUS sliced 路径：_begin_sea_ice_state_machine（实际运行时主路径）
#   - 非 sliced 整轮路径：_apply_sea_ice_daily_pass
# 同 tick 只命中其中一条，所以游标 _last_sea_ice_pass_day 不会双更新。
#
# 返回 dt_days ∈ (0, max_dt_days]（默认 30）。不要在传给 C++ 前预乘 k，避免 d_frac 变成 dt^2。
# 默认 clamp 上限 30：防 pause 复位 / 开局过冲；native daily sliced ACTIVE
# 可传 1.0，避免把整个 graph round 间隔折叠成一次批量融化。下限 ≥ 0 后
# 再 floor 到 1.0：阻断同 tick 重入。第一次调用保持默认 1.0。

static func _consume_sea_ice_dt_days(context, max_dt_days: float = 30.0) -> float:
	var dt_days: float = 1.0
	if context._generator._world_clock_ref != null:
		var now_day_v = context._generator._get_runtime_climate_capture().sample_day()
		if now_day_v != null:
			var now_day: float = float(now_day_v)
			if context._generator._last_sea_ice_pass_day >= 0.0:
				dt_days = clampf(now_day - context._generator._last_sea_ice_pass_day, 0.0, maxf(0.0, max_dt_days))
				if dt_days <= 0.0:
					dt_days = 1.0  # 同 tick 重入兜底
			# else: 第一次调用，保持 dt_days = 1.0 默认
			context._generator._last_sea_ice_pass_day = now_day
	# 诊断：每个日历年长或前 5 次打印一次 dt_days，验证补偿是否在工作。
	# Fix #11 second pass (2026-06-16) mobile：x20 速度下 1 仿真年 ~6 秒，mobile
	# 每秒触发 ~0.16 次 print。logcat overhead ~10ms/行 → 1.6ms/秒。改为 mobile 上
	# 前 5 次后只在 sea_ice 行为异常时打（dt_days > 10 或 < 0.5 = 速度档异常）。
	var _sea_ice_call_total: int = context._generator._gdext_sea_ice_runs + context._generator._gdext_sea_ice_fallbacks
	var _should_log_dt: bool = _sea_ice_call_total < 5
	if not _should_log_dt and not OS.has_feature("mobile"):
		_should_log_dt = context._generator._is_annual_log_tick(_sea_ice_call_total)
	if not _should_log_dt and OS.has_feature("mobile"):
		# mobile：超出 5 次后只在 dt_days 偏离常规时打（异常 dt 才有诊断价值）。
		_should_log_dt = dt_days > 10.0 or dt_days < 0.5
	if _should_log_dt and PKLog.enabled:
		print("[sea_ice/dt] call#%d dt_days=%.3f (last_pass_day=%.3f, k x%.2f)" % [
			context._generator._gdext_sea_ice_runs + context._generator._gdext_sea_ice_fallbacks + 1,
			dt_days,
			context._generator._last_sea_ice_pass_day,
			dt_days,
		])
	return dt_days
