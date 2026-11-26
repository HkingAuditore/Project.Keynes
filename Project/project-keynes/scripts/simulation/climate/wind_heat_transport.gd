extends "res://scripts/simulation/generator_context.gd"
class_name DCWindHeatTransport

const GenerationLoadingSteps = preload("res://scripts/simulation/climate/generation_loading_steps.gd")

const AsyncClimateDiagnostics = preload("res://scripts/simulation/climate/async_climate_diagnostics.gd")

func _init(generator = null) -> void:
	_generator = generator


## Phase 3.3（master 手册 §6.4 - 被遗漏依赖项）：风温耦合 / 气团温度异常输运。
##
## **当前状态**：stub —— 函数体待从 map_generator.gd 整体搬迁。
##
## 拆出原因：风温耦合是"洋流热输运"的对称模块（air_mass_temp_anomaly 对应
## temperature_transport_anomaly），但实施过程中被遗漏在 map_generator.gd
## 主体里（line ~6610-6700，~90 行）。Phase 3.3 拆分时与 ocean/water_pass 和
## ocean/land_pass 同源处理，否则会出现：
##   simulation/ocean/*.gd 是 ocean 热输运
##   simulation/climate/wind_heat_transport.gd 是 wind/air 热输运
## 二者拆出后 climate pass_b 才能彻底脱离 map_generator.gd。
##
## The native wind passes are dispatched by MapGenerator and ClimateDailySystem.
## This placeholder remains until a dedicated stateless helper is needed.
##
## 当前文件保留为占位；具体 static func 在 PR-3.3.X 引入。

# 占位：实际 static func 等迁移过来

func set_daily_climate_refresh_stride(s: int) -> void:
	var stride: int = max(1, s)
	var cp = _generator._c()
	if cp == null:
		return
	cp.daily_climate_refresh_stride = stride
	if _generator._sus != null:
		_generator._sus.apply_job_schedule(_generator._refresh_climate_daily_job, cp, &"refresh_climate_daily", stride)

# ─── Emergent Climate Coupling：天气 → 慢层反馈 pass ─────────────────────
# 每日末尾一次性把当日天气累积效应以**极小权重**（≤ 慢层基线 0.5%/日）
# 累加到慢层的两个反馈缓冲字段：
#   cell.soil_moisture             ← 降水累积（RAIN / STORM / MONSOON × intensity）
#   cell.vegetation_growth_pressure ← 综合正向（RAIN）/ 负向（DROUGHT / HEATWAVE）
# 这些反馈缓冲由 refresh_seasonal 在季末消费并按 feedback_decay 衰减，从而让
# "长期天气"（如"连下三个月雨"）能缓慢影响 base_moisture / 演替评估，但
# 当天的雨绝不直接重写 base_*——物理上"天气快、地图慢"。
#
# 受 ClimateProfile.fast_slow_layering_enabled 控制（调用方已检查）。
# 全局 |Δ|/日 clamp：feedback_per_day_clamp（默认 0.005，即 0.5%）。

func _build_transpiration_donor_table() -> PackedFloat32Array:
	if _generator._gdext_transp_donor_table_cached.size() > 0:
		return _generator._gdext_transp_donor_table_cached
	var n_veg: int = VegetationType.VEG.size()
	var table: PackedFloat32Array = PackedFloat32Array()
	table.resize(n_veg)
	for v in range(n_veg):
		table[v] = VegetationType.transpiration(v)
	_generator._gdext_transp_donor_table_cached = table
	return _generator._gdext_transp_donor_table_cached



func _make_transpiration_native_unavailable(reason: String, t_wall_us: int, n_cells: int = 0) -> Dictionary:
	var elapsed_ms: float = (Time.get_ticks_usec() - t_wall_us) / 1000.0
	push_error("[transpiration] native failed: %s; previous moisture fields retained" % reason)
	var result: Dictionary = _generator._make_climate_pass_result("transp", false, elapsed_ms, 0, -1, -1,
			_generator._CLIMATE_PASS_STATUS_FAILED, 0, "native_unavailable", reason)
	result["path"] = "native_failed"
	result["cursor_remaining"] = n_cells
	result["next_stage"] = "compute"
	return result



func _sync_transpiration_native_outputs(map: MapData, dirty_indices: PackedInt32Array, dirty_values: PackedFloat32Array) -> Dictionary:
	var t_sync_us: int = Time.get_ticks_usec()
	var out: Dictionary = {
		"sync_total_ms": 0.0,
		"sync_write_ms": 0.0,
		"sync_mark_ms": 0.0,
		"sync_path": "none",
		"dirty_count": dirty_indices.size(),
	}
	if _generator._data_core_world == null or map == null:
		out["sync_path"] = "missing_context"
		out["sync_total_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
		return out
	var n: int = map.cell_count()
	if n <= 0 or map.moisture_arr.size() < n:
		out["sync_path"] = "missing_soa"
		out["sync_total_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
		return out
	var cid_moist: int = _generator._data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
	if cid_moist >= 0 and dirty_indices.size() > 0 and dirty_values.size() >= dirty_indices.size() \
			and _generator._data_core_world.has_method("write_f32_indexed"):
		var t_write_us: int = Time.get_ticks_usec()
		_generator._data_core_world.write_f32_indexed(cid_moist, dirty_indices, dirty_values)
		out["sync_write_ms"] = (Time.get_ticks_usec() - t_write_us) / 1000.0
		if _generator._data_core_world.has_method("mark_dirty_indexed"):
			var t_mark_us: int = Time.get_ticks_usec()
			_generator._data_core_world.mark_dirty_indexed(dirty_indices)
			out["sync_mark_ms"] = (Time.get_ticks_usec() - t_mark_us) / 1000.0
		out["sync_path"] = "indexed"
	elif cid_moist >= 0 and _generator._data_core_world.has_method("write_f32_dense"):
		var t_dense_us: int = Time.get_ticks_usec()
		_generator._data_core_world.write_f32_dense(cid_moist, map.moisture_arr)
		out["sync_write_ms"] = (Time.get_ticks_usec() - t_dense_us) / 1000.0
		out["sync_path"] = "dense"
	else:
		out["sync_path"] = "missing_writer"
	out["sync_total_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
	return out



func _build_albedo_donor_table() -> PackedFloat32Array:
	if _generator._gdext_albedo_table_cached.size() > 0:
		return _generator._gdext_albedo_table_cached
	var n_veg: int = VegetationType.VEG.size()
	var table: PackedFloat32Array = PackedFloat32Array()
	table.resize(n_veg)
	for v in range(n_veg):
		table[v] = VegetationType.albedo(v)
	_generator._gdext_albedo_table_cached = table
	return _generator._gdext_albedo_table_cached


func _ensure_vegdyn_lut() -> void:
	if _generator._gdext_vegdyn_ideal_temp_cached.size() > 0:
		return
	var n_veg: int = VegetationType.VEG.size()
	var n_wt: int = WeatherType.WT.size()
	var ideal_t: PackedFloat32Array = PackedFloat32Array()
	var ideal_m: PackedFloat32Array = PackedFloat32Array()
	var tol_t: PackedFloat32Array = PackedFloat32Array()
	var tol_m: PackedFloat32Array = PackedFloat32Array()
	var nx_up: PackedByteArray = PackedByteArray()
	var nx_dn: PackedByteArray = PackedByteArray()
	ideal_t.resize(n_veg)
	ideal_m.resize(n_veg)
	tol_t.resize(n_veg)
	tol_m.resize(n_veg)
	nx_up.resize(n_veg)
	nx_dn.resize(n_veg)
	for v in range(n_veg):
		var p := VegetationProfileRegistry.get_profile(v)
		ideal_t[v] = float(p.ideal_temp)
		ideal_m[v] = float(p.ideal_moist)
		tol_t[v] = float(p.temp_tolerance)
		tol_m[v] = float(p.moist_tolerance)
		nx_up[v] = int(VegetationType.next_in_succession(v, 1))
		nx_dn[v] = int(VegetationType.next_in_succession(v, -1))
	_generator._gdext_vegdyn_ideal_temp_cached = ideal_t
	_generator._gdext_vegdyn_ideal_moist_cached = ideal_m
	_generator._gdext_vegdyn_temp_tol_cached = tol_t
	_generator._gdext_vegdyn_moist_tol_cached = tol_m
	_generator._gdext_vegdyn_next_up_cached = nx_up
	_generator._gdext_vegdyn_next_down_cached = nx_dn
	# weather_penalty 表（按 WT enum 顺序）：参考本文件 const WEATHER_VITALITY_PENALTY 字典，
	# 未声明的 WT 默认 0.0。
	var wpn: PackedFloat32Array = PackedFloat32Array()
	wpn.resize(n_wt)
	for wt_id in range(n_wt):
		wpn[wt_id] = float(_generator.WEATHER_VITALITY_PENALTY.get(wt_id, 0.0))
	_generator._gdext_vegdyn_weather_penalty_cached = wpn
	# resistance_table：VEG × WT 平铺，VegetationType.weather_resistance 提供单点查询
	var res: PackedFloat32Array = PackedFloat32Array()
	res.resize(n_veg * n_wt)
	for v in range(n_veg):
		var base: int = v * n_wt
		for wt_id in range(n_wt):
			res[base + wt_id] = float(VegetationType.weather_resistance(v, wt_id))
	_generator._gdext_vegdyn_resistance_cached = res



# 名义季节温度偏移：只用于旧 refresh_seasonal 行缓存兼容；运行时气候链条
# 始终由太阳几何 -> 日照偏差 -> 热惯性推进。
# ny ∈ [0, 1]：0 = 北极，0.5 = 赤道，1 = 南极。
# season_phase 用整数中点（0.5 / 1.5 / 2.5 / 3.5）做"季节中段"评估。

func _subsolar_lat_rad(season_phase: float) -> float:
	var cp = _generator._c()
	var tilt_deg: float = 23.5
	if cp != null and "axial_tilt_deg" in cp:
		tilt_deg = cp.axial_tilt_deg
	return _generator.DCClimateMath.subsolar_lat_rad(season_phase, tilt_deg)


func _compute_insolation(ny: float, season_phase: float) -> float:
	var cp = _generator._c()
	var amp: float = _generator._INSOLATION_DAYLEN_AMP
	var tilt_deg: float = 23.5
	if cp != null:
		if "insolation_daylen_amp" in cp:
			amp = cp.insolation_daylen_amp
		if "axial_tilt_deg" in cp:
			tilt_deg = cp.axial_tilt_deg
	return _generator.DCClimateMath.compute_daily_insolation(ny, season_phase, tilt_deg, amp)

# 按 ny 缓存的"一年平均 insolation"：16 点数值积分 + LUT 插值。
# 首次调用或 axial_tilt_deg 变化时重建 LUT；之后 O(1) 查表。

func _insolation_annual_mean(ny: float) -> float:
	var cp = _generator._c()
	var tilt_deg: float = 23.5
	if cp != null and "axial_tilt_deg" in cp:
		tilt_deg = cp.axial_tilt_deg
	# LUT 未建或 tilt 变化 → 重建
	if _generator._insol_mean_lut.size() != _generator._INSOL_MEAN_LUT_SIZE + 1 or not is_equal_approx(_generator._insol_mean_lut_tilt, tilt_deg):
		_generator._rebuild_insol_mean_lut()
	# 将 ny ∈ [0, 1] 映射到 LUT 桶索引（双线性插值）
	var x: float = clampf(ny, 0.0, 1.0) * float(_generator._INSOL_MEAN_LUT_SIZE)
	var i0: int = int(floor(x))
	var i1: int = mini(i0 + 1, _generator._INSOL_MEAN_LUT_SIZE)
	var t: float = x - float(i0)
	return lerp(_generator._insol_mean_lut[i0], _generator._insol_mean_lut[i1], t)


func _rebuild_insol_mean_lut() -> void:
	var cp = _generator._c()
	var tilt_deg: float = 23.5
	if cp != null and "axial_tilt_deg" in cp:
		tilt_deg = cp.axial_tilt_deg
	_generator._insol_mean_lut.resize(_generator._INSOL_MEAN_LUT_SIZE + 1)
	for i: int in range(_generator._INSOL_MEAN_LUT_SIZE + 1):
		var ny: float = float(i) / float(_generator._INSOL_MEAN_LUT_SIZE)
		var acc: float = 0.0
		for s: int in range(_generator._INSOL_ANNUAL_SAMPLES):
			var phase: float = 4.0 * float(s) / float(_generator._INSOL_ANNUAL_SAMPLES)
			acc += _generator._compute_insolation(ny, phase)
		_generator._insol_mean_lut[i] = acc / float(_generator._INSOL_ANNUAL_SAMPLES)
	_generator._insol_mean_lut_tilt = tilt_deg

# 日射季节偏差（legacy 气压求解 / UI 读法）：直接路由到 DCClimateMath 单一来源。
# 2026-06-16 物理化：删除"极地放大/衰减"band-aid，dev 还原为纯物理偏差。极地夏季
# 过热改由吸收短波因子（DCClimateMath.surface_absorbed_factor）在 pass_a season_offset 处理。

func _insolation_season_offset(ny: float, season_phase: float) -> float:
	var cp = _generator._c()
	var amp: float = 0.20
	var gain: float = 1.0
	if cp != null:
		if "season_temp_amp" in cp:
			amp = cp.season_temp_amp
		if "insolation_season_gain" in cp:
			gain = cp.insolation_season_gain
	var dev: float = _generator._insol_dev(ny, season_phase)
	# 冷侧软压缩（v2）：与 pass_a 同源，使 UI/legacy 读出的季节偏移在降温侧与实际一致。
	return _generator.DCClimateMath.compress_season_cooling(gain * dev * amp)

# ─── Emergent Climate Coupling：UI 用名义季节标签 ────────────────────────
# 仅供选中面板 / HUD 显示，不参与任何物理 pass。返回 {label, transition}：
#   label      ∈ {"Winter", "Spring", "Summer", "Autumn"}（北半球日历语义）
#   transition ∈ [0, 1]，当前 season 已走完的百分比（0 = 季首，1 = 季末）

func month_of_year(season_phase: float) -> Dictionary:
	const MONTH_LENGTHS: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	var days_per_year: int = _generator._calendar_days_per_year()
	var day_of_year: int = _generator._season_phase_to_day_of_year(season_phase, days_per_year)
	var display_days: int = 0
	for ml_display in MONTH_LENGTHS:
		display_days += int(ml_display)
	var calendar_day0: int = clampi(
			int(floor((float(day_of_year) / float(days_per_year)) * float(display_days))),
			0,
			display_days - 1)
	var month: int = 1
	var day_rem: int = calendar_day0
	for i in range(MONTH_LENGTHS.size()):
		var ml: int = int(MONTH_LENGTHS[i])
		if day_rem < ml:
			month = i + 1
			break
		day_rem -= ml
	return {
		"month": month,
		"day_of_month": day_rem + 1,
		"day_of_year": day_of_year + 1,
		"calendar_day_display": calendar_day0 + 1,
		"days_per_year": days_per_year,
	}

# True Insolation-Driven：UI 便利接口。给外部（main.gd 面板）用当前 _last_cfg
# 快速拿到某 cell 的归一化纬度 ny ∈ [0, 1]，0 = 北极 / 0.5 = 赤道 / 1 = 南极。
# 内部仍走 _cube_row_norm；_last_cfg 缺失时返回 0.5（赤道兜底）。

func observe_local_month(cell: HexCell, season_phase: float) -> Dictionary:
	var calendar: Dictionary = _generator.month_of_year(season_phase)
	# Fast-tick perf opt (C)：temp_dev_from_annual 已升级为强类型成员，直接读。
	var dev: float = cell.temp_dev_from_annual
	var cp = _generator._c()
	var amp: float = 0.20
	if cp != null and "season_temp_amp" in cp:
		amp = maxf(cp.season_temp_amp, 1e-4)
	var magnitude: float = clampf(absf(dev) / amp, 0.0, 1.0)
	var warmer: Variant = null
	if absf(dev) >= 0.02:
		warmer = dev > 0.0
	return {
		"calendar_month": int(calendar.month),
		"day_of_month": int(calendar.day_of_month),
		"dev": dev,
		"magnitude": magnitude,
		"warmer_than_annual": warmer,  # null = 无显著差异（赤道等）
	}

# --- Wind Temperature Coupling：风温耦合 pass（对称复刻洋流热输运） ─────────────────
# 在几何温度之上叠加一层：
#   Pass 1（气团→气团）：沿 -wind_vector 回溯最多 WIND_HEAT_ADVECT_STEPS 个邻居，
#                     混合上游 current_state.temperature 到本 cell，按 WIND_HEAT_MIX 权重。
#                     air_mass_temp_anomaly = temp_after_mix - temp_year_at_cell。
#   Pass 2（气团→地表）：对每个 cell，按 max(0, dot(邻居方向, 上游 cell wind_vector)) 加权
#                     收集相邻 cell 的 air_mass_temp_anomaly；按 AIR_MASS_HEAT_LEAK 注入 current_state.temperature。
#
# 复杂度：O(cells × (ADVECT_STEPS + 6))；默认常量 3 + 6 ≈ 9，轻量。
# 所有几何温度基线使用 _compute_temperature(ny, elevation) 保证与 refresh_climate_daily 一致。

func _build_native_wind_baseline(map: MapData) -> PackedFloat32Array:
	var n: int = map.soa_size()
	# 静态基线缓存：纬度/海拔在仿真期间不变，整条 _compute_temperature 循环只需
	# 每代算一次。命中时直接返回缓存引用（调用方仅作 C++ pass 的只读 baseline_arr，
	# 不会就地写）。失效由 generate() 触发（见 _invalidate_native_static_caches）。
	if _generator._native_wind_baseline_cache_map == map and _generator._native_wind_baseline_cache.size() == n and n > 0:
		return _generator._native_wind_baseline_cache
	var cells: Array[HexCell] = map.iter_cells()
	var elev_a: PackedFloat32Array = map.elevation_arr
	var lat_a: PackedFloat32Array = map.cell_lat_norm_arr
	var baseline: PackedFloat32Array = PackedFloat32Array()
	baseline.resize(n)
	for i in range(n):
		var ny: float = lat_a[i] if lat_a.size() > i else _generator._cube_row_norm(cells[i], _generator._last_cfg)
		var elev: float = elev_a[i] if elev_a.size() > i else cells[i].elevation
		baseline[i] = _generator._compute_temperature(ny, elev)
	_generator._native_wind_baseline_cache = baseline
	_generator._native_wind_baseline_cache_map = map
	return _generator._native_wind_baseline_cache



func _publish_wind_heat_native_outputs(map: MapData) -> void:
	if _generator._data_core_world == null:
		return
	var n: int = map.soa_size()
	if n <= 0:
		return
	var _cid_temp: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMP)
	var _cid_anom: int = _generator._data_core_world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
	if _cid_temp >= 0 and map.temp_arr.size() == n:
		_generator._data_core_world.write_f32_dense(_cid_temp, map.temp_arr)
	if _cid_anom >= 0 and map.air_mass_temp_anomaly_arr.size() == n:
		_generator._data_core_world.write_f32_dense(_cid_anom, map.air_mass_temp_anomaly_arr)
	# A 修复（climate-temp-pingpong-fix-2026-06）：3 条新写权字段定义后，wind_surface 末端
	# 也需要把 baseline / ocean_anom / local_anom 的 GDScript 镜像推回 C++ slot，保持
	# C++ 视角的 SoA 与 GDScript 视角一致。pass_a / ocean_* / pass_b 的 _flush_slot_to_map
	# 已经把 C++ slot 推到 map.* arr；这里走"补救式 push back"，与温度/air_anom 的旧逻辑
	# 等价（idempotent — 若 GDScript 没动 arr 这就是 no-op 拷贝）。
	var _cid_baseline: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMP_BASELINE)
	var _cid_oanom: int = _generator._data_core_world.component_id(DCComponentIds.CELL_OCEAN_THERMAL_ANOMALY)
	var _cid_lanom: int = _generator._data_core_world.component_id(DCComponentIds.CELL_LOCAL_THERMAL_ANOMALY)
	if _cid_baseline >= 0 and map.temp_baseline_arr.size() == n:
		_generator._data_core_world.write_f32_dense(_cid_baseline, map.temp_baseline_arr)
	if _cid_oanom >= 0 and map.ocean_thermal_anomaly_arr.size() == n:
		_generator._data_core_world.write_f32_dense(_cid_oanom, map.ocean_thermal_anomaly_arr)
	if _cid_lanom >= 0 and map.local_thermal_anomaly_arr.size() == n:
		_generator._data_core_world.write_f32_dense(_cid_lanom, map.local_thermal_anomaly_arr)



func run_wind_air_mass_pass_native(map: MapData, season_phase: float) -> Dictionary:
	if _generator._last_cfg == null or map == null:
		var result_missing: Dictionary = _generator._make_climate_pass_result("wind_air", true, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_DONE, 0, "oneshot_noop", "missing_context")
		result_missing["path"] = "noop"
		return result_missing
	if _generator._data_core_world_ext == null:
		push_error("[wind_air] native failed: native_unavailable; previous fields retained")
		var result_unavailable = _generator._make_climate_pass_result("wind_air", false, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_FAILED, 0, "oneshot_native", "native_unavailable")
		result_unavailable["path"] = "native_failed"
		return result_unavailable
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6 or map.temp_arr.size() < n:
		push_error("[wind_air] native failed: missing_soa; previous fields retained")
		var result_shape = _generator._make_climate_pass_result("wind_air", false, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_FAILED, 0, "oneshot_native", "missing_soa")
		result_shape["path"] = "native_failed"
		return result_shape
	var baseline: PackedFloat32Array = _generator._build_native_wind_baseline(map)
	var knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, _generator._last_cfg.WIND_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(_generator._last_cfg.WIND_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
	}
	if _generator._supports_wind_air_slot_temp():
		knobs["read_temp_from_slot"] = true
	else:
		if _generator._gdext_wind_temp_before_work_buf.size() != n:
			_generator._gdext_wind_temp_before_work_buf.resize(n)
		var temp_before: PackedFloat32Array = _generator._gdext_wind_temp_before_work_buf
		var temp_a: PackedFloat32Array = map.temp_arr
		for i in range(n):
			var t0: float = temp_a[i]
			temp_before[i] = _generator._valid_runtime_temp_or_baseline(t0, baseline[i])
		knobs["temp_before_arr"] = temp_before
	# refresh-consolidation-2026-06：climate_daily round 守门员。wind_air 通常无须
	# 真实 refresh —— 它读温度 temp_arr，前序 ocean_land flush 了 ocean_anom 但
	# climate_daily_system 会在跨 pass 边界 mark stale，这里 ensure 时会按需 refresh。
	_generator._ensure_climate_daily_round_slots_fresh()
	var rc: float = float(_generator._data_core_world_ext.run_wind_air_mass_pass(knobs))
	if rc < 0.0:
		push_error("[wind_air] native failed: native_failed; previous fields retained")
		var result_failed = _generator._make_climate_pass_result("wind_air", false, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_FAILED, 0, "oneshot_native", "native_failed")
		result_failed["path"] = "native_failed"
		return result_failed
	_generator._publish_wind_heat_native_outputs(map)
	var result: Dictionary = _generator._make_climate_pass_result("wind_air", true, rc, n, 0, n,
			_generator._CLIMATE_PASS_STATUS_DONE, 0, "oneshot_native")
	result["path"] = "gdext"
	return result



func run_wind_surface_pass_native(map: MapData, season_phase: float) -> Dictionary:
	if _generator._last_cfg == null or map == null:
		var result_missing: Dictionary = _generator._make_climate_pass_result("wind_surface", true, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_DONE, 0, "oneshot_noop", "missing_context")
		result_missing["path"] = "noop"
		return result_missing
	if _generator._data_core_world_ext == null:
		push_error("[wind_surface] native failed: native_unavailable; previous fields retained")
		var result_unavailable = _generator._make_climate_pass_result("wind_surface", false, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_FAILED, 0, "oneshot_native", "native_unavailable")
		result_unavailable["path"] = "native_failed"
		return result_unavailable
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6 or map.temp_arr.size() < n:
		push_error("[wind_surface] native failed: missing_soa; previous fields retained")
		var result_shape = _generator._make_climate_pass_result("wind_surface", false, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_FAILED, 0, "oneshot_native", "missing_soa")
		result_shape["path"] = "native_failed"
		return result_shape
	var baseline: PackedFloat32Array = _generator._build_native_wind_baseline(map)
	var knobs: Dictionary = {
		"n_cells": n,
		"air_leak": float(_generator._last_cfg.AIR_MASS_HEAT_LEAK),
		"neighbor_indices": nb_idx,
		"fallback_baseline_arr": baseline,
		"cold_transport_form_threshold": float(_generator._c().sea_ice_form_threshold) if _generator._c() != null else 0.06,
		"cold_transport_melt_threshold": float(_generator._c().sea_ice_melt_threshold) if _generator._c() != null else 0.11,
	}
	# refresh-consolidation-2026-06：climate_daily round 守门员。wind_surface 通常
	# 跟在 wind_air 之后，仅读 wind_air 写入的 C++ slot（不绕 MapData），故可 skip。
	_generator._ensure_climate_daily_round_slots_fresh()
	var rc: float = float(_generator._data_core_world_ext.run_wind_surface_pass(knobs))
	if rc < 0.0:
		push_error("[wind_surface] native failed: native_failed; previous fields retained")
		var result_failed = _generator._make_climate_pass_result("wind_surface", false, 0.0, 0, -1, -1,
				_generator._CLIMATE_PASS_STATUS_FAILED, 0, "oneshot_native", "native_failed")
		result_failed["path"] = "native_failed"
		return result_failed
	_generator._publish_wind_heat_native_outputs(map)
	var result: Dictionary = _generator._make_climate_pass_result("wind_surface", true, rc, n, 0, n,
			_generator._CLIMATE_PASS_STATUS_DONE, 0, "oneshot_native")
	result["path"] = "gdext"
	return result

# 风温耦合的"气团段"——
# 所有 cell 沿 -wind_vector 回溯 advect_steps 步、与上游 cell 温度做 lerp 混合，
# 只写回 cell.air_mass_temp_anomaly；temperature 由紧随其后的 surface pass 注入。
# [perf 2026-05-20] 不再循环 cell.X = setter（每帧 N 次 _dirty_mark_one 风暴），
# 改成累积到 PackedFloat32Array → 末尾 write_f32_dense 一次性 commit + 一次性 mark dirty range。

func _wind_air_mass_pass(map: MapData, season_phase: float, cooperative: bool = false) -> void:
	if _generator._last_cfg == null:
		return
	var advect_steps: int = max(0, _generator._last_cfg.WIND_HEAT_ADVECT_STEPS)
	var heat_mix: float = clampf(_generator._last_cfg.WIND_HEAT_MIX, 0.0, 1.0)

	# 基线温度缓存（per-cell 的 temp_year_at_cell，用于算 anomaly）
	var baseline: Dictionary = {}
	for cell: HexCell in map.all_cells():
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		var ny: float = _generator._cube_row_norm(cell, _generator._last_cfg)
		baseline[cell] = _generator._compute_temperature(ny, cell.elevation)

	# 先把所有 cell 的当前 temperature 拷贝出来（避免半途被覆盖）
	var temp_before: Dictionary = {}
	for cell: HexCell in map.all_cells():
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		temp_before[cell] = _generator._valid_runtime_temp_or_baseline(cell.temperature, float(baseline[cell]))

	# [perf] 累积输出，循环结束后批量 commit
	var n_cells_air: int = map.iter_cells().size() if map.has_indices() else map.all_cells().size()
	var anom_out_arr: PackedFloat32Array = PackedFloat32Array()
	anom_out_arr.resize(n_cells_air)
	# 默认值：anom=0，temperature 保持原值。
	var iter_cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	for ic in range(n_cells_air):
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		anom_out_arr[ic] = 0.0

	# climate-loop-closure 修复：直接读 SoA 风场（wind_x_arr/wind_y_arr，与 weather
	# field solver 同源）。此前读 cell.wind_vector facade（经 _world_ext.read_f32），
	# 在 native_environment_runtime 路径下返回 0 → 风温平流整段 no-op（air_mass≡0）。
	var wind_x_arr_air: PackedFloat32Array = map.wind_x_arr
	var wind_y_arr_air: PackedFloat32Array = map.wind_y_arr
	var has_wind_soa_air: bool = wind_x_arr_air.size() == n_cells_air and wind_y_arr_air.size() == n_cells_air
	for cell: HexCell in map.all_cells():
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		var ci_air: int = int(cell.index)
		var wind: Vector2
		if has_wind_soa_air and ci_air >= 0 and ci_air < n_cells_air:
			wind = Vector2(wind_x_arr_air[ci_air], wind_y_arr_air[ci_air])
		else:
			wind = cell.wind_vector
		if wind.length_squared() < 1e-6 or advect_steps == 0:
			# anom = 0（默认）；temp 保持原值（默认）
			continue

		# 沿 -wind 方向回溯 advect_steps 步，每步选最对齐的邻居
		var upstream: HexCell = cell
		var upstream_dir: Vector2 = -wind.normalized()

		for step in range(advect_steps):
			var best_nb: HexCell = null
			var best_dot: float = 0.1  # 需要最低对齐阈值，避免反向邻居被选
			var self_wp: Vector2 = HexUtils.cube_to_world(upstream.q, upstream.r, _generator._last_hex_size)

			for nb: HexCell in map.get_neighbors(upstream):
				if nb == null:
					continue
				var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _generator._last_hex_size)
				var d: Vector2 = (nb_wp - self_wp)
				if d.length_squared() < 1e-6:
					continue
				var dot_v: float = d.normalized().dot(upstream_dir)
				if dot_v > best_dot:
					best_dot = dot_v
					best_nb = nb

			if best_nb == null:
				break
			upstream = best_nb

		var temp_self: float = temp_before.get(cell, baseline[cell])
		var temp_up: float = temp_before.get(upstream, baseline.get(upstream, temp_self))
		var temp_mixed: float = lerpf(temp_self, temp_up, heat_mix)

		var idx_cell: int = int(cell.index)
		if idx_cell >= 0 and idx_cell < n_cells_air:
			anom_out_arr[idx_cell] = temp_mixed - float(baseline[cell])

	# climate-loop-closure 修复 v2：直接写 map SoA（property 原地索引，与 weather
	# distribute 的 snowpack 写法同源，recorder/下游已验证可见）。此前 write_f32_dense
	# 在本路径未反映到 map.air_mass_temp_anomaly_arr → air_mass 恒 0。
	var _anom_ok: bool = map.air_mass_temp_anomaly_arr.size() == n_cells_air
	for ic in range(n_cells_air):
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		if _anom_ok:
			map.air_mass_temp_anomaly_arr[ic] = anom_out_arr[ic]
		else:
			var cf: HexCell = iter_cells[ic]
			cf.air_mass_temp_anomaly = anom_out_arr[ic]
	# DCWorld view 兜底 push（facade 启用时 map.*_arr 即 view alias，幂等）。
	if _generator._data_core_world != null:
		var _cid_anom_a: int = _generator._data_core_world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
		if _cid_anom_a >= 0:
			_generator._data_core_world.write_f32_dense(_cid_anom_a, anom_out_arr)

# 风温耦合的"地表段"——
# 每个 cell 从相邻 cell 收集 air_mass_temp_anomaly，按"邻 cell 的 wind_vector 是否流向本 cell"加权注入。
# 必须在 _wind_air_mass_pass 之后调用——读取的是气团段写完的 anomaly。
# [perf 2026-05-20] 同 _wind_air_mass_pass：循环只累积到 array，末尾 dense 一次性 commit。


func _wind_surface_pass(map: MapData, season_phase: float, cooperative: bool = false) -> void:
	# Native path composes cell_temp from baseline and the published anomalies.
	if _generator._last_cfg == null:
		return
	var air_leak: float = _generator._last_cfg.AIR_MASS_HEAT_LEAK

	# baseline 在表面段也需要——用 cell.elevation + _cube_row_norm 重算
	var baseline: Dictionary = {}
	for cell: HexCell in map.all_cells():
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		var ny: float = _generator._cube_row_norm(cell, _generator._last_cfg)
		baseline[cell] = _generator._compute_temperature(ny, cell.elevation)

	# [perf] 累积 anom + temp 输出
	var iter_cells_s: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_s: int = iter_cells_s.size()
	var anom_out_s: PackedFloat32Array = PackedFloat32Array()
	var temp_out_s: PackedFloat32Array = PackedFloat32Array()
	anom_out_s.resize(n_cells_s)
	temp_out_s.resize(n_cells_s)
	# 默认值：anom=0；temp 优先保留 air_mass pass 写入 SoA 的最新值。
	for ic in range(n_cells_s):
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		var c0: HexCell = iter_cells_s[ic]
		anom_out_s[ic] = 0.0
		temp_out_s[ic] = c0.temperature

	# climate-loop-closure 修复：邻居风向同样直接读 SoA（理由见 _wind_air_mass_pass）。
	var wind_x_arr_s: PackedFloat32Array = map.wind_x_arr
	var wind_y_arr_s: PackedFloat32Array = map.wind_y_arr
	var has_wind_soa_s: bool = wind_x_arr_s.size() == n_cells_s and wind_y_arr_s.size() == n_cells_s
	var air_anom_arr_s: PackedFloat32Array = map.air_mass_temp_anomaly_arr
	var temp_arr_s: PackedFloat32Array = map.temp_arr
	var has_air_anom_soa_s: bool = air_anom_arr_s.size() == n_cells_s
	var has_temp_soa_s: bool = temp_arr_s.size() == n_cells_s
	for ic in range(n_cells_s):
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		if has_temp_soa_s:
			temp_out_s[ic] = temp_arr_s[ic]
	for cell: HexCell in map.all_cells():
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		var self_wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _generator._last_hex_size)
		var weighted_sum: float = 0.0
		var weight_total: float = 0.0

		for nb: HexCell in map.get_neighbors(cell):
			if nb == null:
				continue
			var nb_ci: int = int(nb.index)
			var wind_nb: Vector2
			if has_wind_soa_s and nb_ci >= 0 and nb_ci < n_cells_s:
				wind_nb = Vector2(wind_x_arr_s[nb_ci], wind_y_arr_s[nb_ci])
			else:
				wind_nb = nb.wind_vector
			if wind_nb.length_squared() < 1e-6:
				continue

			var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _generator._last_hex_size)
			# 邻居 → 本 cell 方向（迎流判断：若邻 cell 的风正是流向本 cell，权重最大）
			var dir_nb_to_self: Vector2 = (self_wp - nb_wp)
			if dir_nb_to_self.length_squared() < 1e-6:
				continue

			var w_nb: float = maxf(0.0, dir_nb_to_self.normalized().dot(wind_nb))
			if w_nb <= 0.0:
				continue

			var nb_anomaly: float = air_anom_arr_s[nb_ci] if has_air_anom_soa_s and nb_ci >= 0 and nb_ci < n_cells_s else nb.air_mass_temp_anomaly
			weighted_sum += nb_anomaly * w_nb
			weight_total += w_nb

		var anomaly_in: float = 0.0
		if weight_total > 0.0:
			anomaly_in = (weighted_sum / weight_total) * air_leak

		var idx_cell_s: int = int(cell.index)
		if idx_cell_s < 0 or idx_cell_s >= n_cells_s:
			continue
		anom_out_s[idx_cell_s] = anomaly_in
		if absf(anomaly_in) > 1e-5:
			var t_prev: float = _generator._valid_runtime_temp_or_baseline(temp_out_s[idx_cell_s], float(baseline[cell]))
			temp_out_s[idx_cell_s] = clampf(t_prev + anomaly_in, 0.0, 1.0)

	# climate-loop-closure 修复 v2：直接写 map SoA（property 原地索引，见 air pass 同注释）。
	var _temp_ok_s: bool = map.temp_arr.size() == n_cells_s
	var _anom_ok_s: bool = map.air_mass_temp_anomaly_arr.size() == n_cells_s
	for ic in range(n_cells_s):
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		if _temp_ok_s:
			map.temp_arr[ic] = temp_out_s[ic]
		if _anom_ok_s:
			map.air_mass_temp_anomaly_arr[ic] = anom_out_s[ic]
		if not (_temp_ok_s and _anom_ok_s):
			var cf: HexCell = iter_cells_s[ic]
			cf.temperature = temp_out_s[ic]
			cf.air_mass_temp_anomaly = anom_out_s[ic]
	if _generator._data_core_world != null:
		var _cid_temp_s: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMP)
		var _cid_anom_s: int = _generator._data_core_world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
		if _cid_temp_s >= 0:
			_generator._data_core_world.write_f32_dense(_cid_temp_s, temp_out_s)
		if _cid_anom_s >= 0:
			_generator._data_core_world.write_f32_dense(_cid_anom_s, anom_out_s)
	# 旧 B-full Step-2 镜像循环已并入上面的直写（map.air_mass_temp_anomaly_arr 即 SoA）；
	# 保留下方分支仅为兼容 has_soa 校验，但不再做 COW 易脱离的 local-var 镜像。
	if false and map.has_indices() and map.has_soa():
		var soa_air: PackedFloat32Array = map.air_mass_temp_anomaly_arr
		var n_air: int = map.iter_cells().size()
		for i_air in range(n_air):
			soa_air[i_air] = map.cell_at(i_air).air_mass_temp_anomaly


# bake_world 阶段进度信号 forwarder：MapBaker.stage_progress → MapGenerator.bake_progress。
# 详细 stage 含义见 map_baker.gd 顶部 stage_progress 信号注释。


func run_async_climate_round_bench(pass_name: String = "transp") -> Dictionary:
	return AsyncClimateDiagnostics.run_async_climate_round_bench(self, pass_name)


func _bench_async_transp(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	return AsyncClimateDiagnostics._bench_async_transp(self, map, n_cells, cp_f5, report)


func _bench_async_pass_a(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	return AsyncClimateDiagnostics._bench_async_pass_a(self, map, n_cells, cp_f5, report)


func _busy_wait_poll(timeout_us: int) -> Dictionary:
	return AsyncClimateDiagnostics._busy_wait_poll(self, timeout_us)


func _diff_f32_arrays(a: PackedFloat32Array, b: PackedFloat32Array, n: int) -> Dictionary:
	return AsyncClimateDiagnostics._diff_f32_arrays(self, a, b, n)


func cancel_loading_work() -> void:
	GenerationLoadingSteps.cancel_loading_work(self)


func _loading_profile_step(label: String) -> void:
	GenerationLoadingSteps._loading_profile_step(self, label)


func _loading_tail_stage_for(label: String) -> String:
	return GenerationLoadingSteps._loading_tail_stage_for(self, label)


func _emit_loading_tail_progress(label: String) -> void:
	GenerationLoadingSteps._emit_loading_tail_progress(self, label)


func _generation_slice_due() -> bool:
	return GenerationLoadingSteps._generation_slice_due(self)


func _prepare_season_geometry_cooperative(map: MapData, n: int) -> void:
	await GenerationLoadingSteps._prepare_season_geometry_cooperative(self, map, n)
