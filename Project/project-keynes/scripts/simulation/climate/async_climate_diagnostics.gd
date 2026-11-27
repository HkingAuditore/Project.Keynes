extends RefCounted

## Compares the asynchronous climate passes with their synchronous reference.


static func run_async_climate_round_bench(context, pass_name: String = "transp") -> Dictionary:
	var report: Dictionary = {
		"ok": false,
		"reason": "",
		"pass": pass_name,
	}
	if context._generator._data_core_world_ext == null:
		report["reason"] = "DCWorldExt unavailable"
		print("[async/bench] FAIL: ", report["reason"])
		return report
	var map: MapData = context._generator._sus_map
	if map == null:
		report["reason"] = "_sus_map is null; world not generated yet"
		print("[async/bench] FAIL: ", report["reason"])
		return report
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		report["reason"] = "map.cell_count() <= 0"
		print("[async/bench] FAIL: ", report["reason"])
		return report
	var cp_f5: ClimateProfile = context._generator._c()
	if cp_f5 == null:
		report["reason"] = "ClimateProfile null"
		print("[async/bench] FAIL: ", report["reason"])
		return report

	# Bench vs daily round 互斥：临时关 use_climate_round_async，避免 daily round 路径
	# 占用全局 worker，bench 拿到混入 daily-round 结果（pass_a worker_compute_us≈1700 而非 ≈1400 即
	# 是症状）。bench 完恢复原值。
	var _bench_was_async: bool = false
	if "use_climate_round_async" in cp_f5:
		_bench_was_async = bool(cp_f5.use_climate_round_async)
		cp_f5.use_climate_round_async = false
	# 等待当前在跑的 daily round worker 自然结束（最多 200ms）
	var _wait_deadline: int = Time.get_ticks_usec() + 200_000
	while Time.get_ticks_usec() < _wait_deadline:
		var stats: Dictionary = context._generator._data_core_world_ext.async_climate_round_stats()
		var pending: bool = bool(stats.get("request_pending", false))
		var ready: bool = bool(stats.get("result_ready", false))
		if not pending and not ready:
			break
		if ready:
			# 把上一次 daily round 残留结果 poll 掉，否则下一次 kick 永远拿到旧值
			context._generator._data_core_world_ext.async_climate_round_poll()
			break
		OS.delay_msec(1)

	# 静态 knobs 提前注入（neighbor_indices + donor_table 不变）
	context._generator._data_core_world_ext.async_climate_round_register()
	var donor_table: PackedFloat32Array = context._generator._build_transpiration_donor_table()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var static_knobs: Dictionary = {
		"n_cells": n_cells,
		"neighbor_indices": nb_idx,
		"donor_table": donor_table,
	}
	context._generator._data_core_world_ext.async_climate_round_set_static_knobs(static_knobs)

	# 按 pass 分支
	var bench_result: Dictionary = report
	match pass_name:
		"transp":
			bench_result = context._generator._bench_async_transp(map, n_cells, cp_f5, report)
		"pass_a":
			bench_result = context._generator._bench_async_pass_a(map, n_cells, cp_f5, report)
		_:
			report["reason"] = "unknown pass_name '%s' (expect 'transp' or 'pass_a')" % pass_name
			print("[async/bench] FAIL: ", report["reason"])
			bench_result = report
	# 恢复 use_climate_round_async flag（bench 入口已临时关掉）
	if "use_climate_round_async" in cp_f5:
		cp_f5.use_climate_round_async = _bench_was_async
	return bench_result

# 兼容旧名（KEY_B 热键调用）

static func _bench_async_transp(context, map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	# 1) snapshot moisture
	var moisture_snap: PackedFloat32Array = map.moisture_arr.duplicate()

	# 2) sync 拿参考
	var sync_t0: int = Time.get_ticks_usec()
	var sync_res: Dictionary = context._generator.run_transpiration_pass_native(map)
	var sync_elapsed_us: int = Time.get_ticks_usec() - sync_t0
	var sync_path: String = str(sync_res.get("path", "?"))
	if sync_path != "gdext":
		report["reason"] = "sync path failed (path=%s)" % sync_path
		print("[async/bench transp] FAIL: ", report["reason"])
		map.moisture_arr = moisture_snap
		context._generator._data_core_world_ext.refresh_slots_from_map()
		return report
	var ref_moisture: PackedFloat32Array = map.moisture_arr.duplicate()

	# 把 moisture 还原，让 async 跑同一 input
	map.moisture_arr = moisture_snap
	context._generator._data_core_world_ext.refresh_slots_from_map()

	# 3) async kick（passes_mask=0x80 仅 transp）
	var input: Dictionary = {
		"n_cells": n_cells,
		"passes_mask": 0x80,
		"landform": map.landform_arr,
		"vegetation": map.vegetation_arr,
		"moisture": map.moisture_arr,
		"transp_outflow_rate": float(cp_f5.transpiration_outflow_rate),
		"transp_self_rate": float(cp_f5.transpiration_self_rate),
		"season_phase": 0.0,
	}
	var async_t0: int = Time.get_ticks_usec()
	if not bool(context._generator._data_core_world_ext.async_climate_round_kick(input)):
		report["reason"] = "kick returned false"
		print("[async/bench transp] FAIL: ", report["reason"])
		return report

	# 4) busy-wait
	var poll_result: Dictionary = context._generator._busy_wait_poll(200_000)
	var async_elapsed_us: int = Time.get_ticks_usec() - async_t0
	if poll_result.is_empty():
		report["reason"] = "worker did not complete within 200ms"
		print("[async/bench transp] FAIL: ", report["reason"])
		return report
	var async_moisture: PackedFloat32Array = map.moisture_arr.duplicate()

	# 5) compare
	var diff: Dictionary = context._generator._diff_f32_arrays(ref_moisture, async_moisture, n_cells)

	# 6) 恢复
	map.moisture_arr = moisture_snap
	context._generator._data_core_world_ext.refresh_slots_from_map()

	# 7) 报告
	report["ok"] = (diff["diff_count"] == 0)
	report["n_cells"] = n_cells
	report["sync_us"] = sync_elapsed_us
	report["async_total_us"] = async_elapsed_us
	report["worker_compute_us"] = int(poll_result.get("worker_compute_us", 0))
	report["transp_us"] = int(poll_result.get("transp_us", 0))
	report["diff_count"] = diff["diff_count"]
	report["max_abs_diff"] = diff["max_abs_diff"]
	report["first_diff_idx"] = diff["first_diff_idx"]
	print("[async/bench transp] === A-B verification ===")
	print("  n_cells=%d  sync_us=%d  async_total_us=%d" % [n_cells, sync_elapsed_us, async_elapsed_us])
	print("  worker_compute_us=%d  transp_us=%d" % [
		int(poll_result.get("worker_compute_us", 0)), int(poll_result.get("transp_us", 0))])
	print("  diff_count=%d  max_abs_diff=%.9f  first_diff_idx=%d" % [
		diff["diff_count"], diff["max_abs_diff"], diff["first_diff_idx"]])
	if report["ok"]:
		print("[async/bench transp] OK ✅ — moisture bit-equal sync")
	else:
		print("[async/bench transp] FAIL ❌")
	return report

# pass_a A-B：验证 16 字段输出 bit-equal sync

static func _bench_async_pass_a(context, map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	# 验证字段列表（与 worker poll 写回的 16 字段一致）。
	# (map_field, dtype) — 用于通用 snapshot/compare/restore
	# Stage 2 范围内只 diff F32 字段；ema_initialized 是 U8，逻辑相同（snapshot+restore）。
	var f32_fields: Array = [
		"moisture_arr", "snow_cover_arr", "temp_baseline_arr", "temp_season_offset_arr",
		"temp_30d_arr", "temp_365d_arr", "temp_anomaly_arr",
		"insolation_now_arr", "insolation_dev_arr", "day_length_arr", "heat_input_arr",
		"thermal_energy_arr", "snowpack_arr",
		"ocean_thermal_anomaly_arr", "local_thermal_anomaly_arr",
	]
	var u8_fields: Array = ["ema_initialized_arr"]

	# 1) snapshot 全部 16 字段
	var snap_f32: Dictionary = {}
	for f in f32_fields:
		snap_f32[f] = (map.get(f) as PackedFloat32Array).duplicate()
	var snap_u8: Dictionary = {}
	for f in u8_fields:
		snap_u8[f] = (map.get(f) as PackedByteArray).duplicate()

	# 2) sync 拿参考输出：直接调 _climate_pass_a（带 refresh + flush）
	var sync_t0: int = Time.get_ticks_usec()
	# season_phase 使用当前 round 锁定值；若 climate_daily round 没在跑，用 world_clock 当前值
	var sp: float = 0.0
	if context._generator._world_clock_ref != null and context._generator._world_clock_ref.has_method("season_phase"):
		sp = float(context._generator._world_clock_ref.season_phase())
	context._generator._climate_pass_a(map, sp)
	var sync_elapsed_us: int = Time.get_ticks_usec() - sync_t0
	# 拿 sync 后的 ref values
	var ref_f32: Dictionary = {}
	for f in f32_fields:
		ref_f32[f] = (map.get(f) as PackedFloat32Array).duplicate()
	var ref_u8: Dictionary = {}
	for f in u8_fields:
		ref_u8[f] = (map.get(f) as PackedByteArray).duplicate()

	# 3) 把所有字段恢复 snapshot
	for f in f32_fields:
		map.set(f, (snap_f32[f] as PackedFloat32Array).duplicate())
	for f in u8_fields:
		map.set(f, (snap_u8[f] as PackedByteArray).duplicate())
	context._generator._data_core_world_ext.refresh_slots_from_map()

	# 4) async kick（passes_mask=0x01 仅 pass_a）+ 完整 pass_a 输入
	var input: Dictionary = {
		"n_cells": n_cells,
		"passes_mask": 0x01,
		# U8 输入
		"is_water": map.is_water_arr,
		"terrain": map.terrain_arr,
		"cover": map.cover_arr,
		"ema_initialized": map.ema_initialized_arr,
		# F32 输入
		"elevation": map.elevation_arr,
		"base_moisture": map.base_moisture_arr,
		"lat_norm": map.cell_lat_norm_arr,
		"temp_baseline_year": map.temp_baseline_year_arr,
		"temp": map.temp_arr,
		"temp_30d": map.temp_30d_arr,
		"temp_365d": map.temp_365d_arr,
		"thermal_energy": map.thermal_energy_arr,
		"snowpack": map.snowpack_arr,
		# scalars - 与 _climate_pass_a 同源
		"season_phase": sp,
		"axial_tilt_deg": float(cp_f5.axial_tilt_deg) if "axial_tilt_deg" in cp_f5 else 23.5,
		"day_length_gain": float(cp_f5.insolation_daylen_amp) if "insolation_daylen_amp" in cp_f5 else 0.35,
		"solar_gain": float(cp_f5.solar_gain) if "solar_gain" in cp_f5 else 1.0,
		"insol_amp": float(cp_f5.season_temp_amp) if "season_temp_amp" in cp_f5 else 0.20,
		"insol_gain": float(cp_f5.insolation_season_gain) if "insolation_season_gain" in cp_f5 else 1.0,
		"moist_scale_now": 1.0,
		"days_per_year": context._generator._calendar_days_per_year(),
		"sea_level": float(context._generator._last_cfg.sea_level) if context._generator._last_cfg != null else 0.5,
		# pass_a 扩展 scalars — mirror sync `_climate_pass_a` 的 cp_struct。
		"thermal_inertia_land": float(cp_f5.thermal_inertia_land) if "thermal_inertia_land" in cp_f5 else 0.35,
		"thermal_inertia_water": float(cp_f5.thermal_inertia_water) if "thermal_inertia_water" in cp_f5 else 0.045,
		"thermal_inertia_snow": float(cp_f5.thermal_inertia_snow) if "thermal_inertia_snow" in cp_f5 else 0.09,
		"thermal_inertia_high_mountain": float(cp_f5.thermal_inertia_high_mountain) if "thermal_inertia_high_mountain" in cp_f5 else 0.16,
		"thermal_daily_delta_cap": float(cp_f5.thermal_daily_delta_cap) if "thermal_daily_delta_cap" in cp_f5 else 0.15,
		"temp_land_continentality": float(cp_f5.temp_land_continentality) if "temp_land_continentality" in cp_f5 else 1.0,
		"thermal_dt_days": context._generator._consume_climate_dt_days(),
		"snowpack_cover_low": float(cp_f5.snowpack_cover_low) if "snowpack_cover_low" in cp_f5 else 0.05,
		"snowpack_cover_full": float(cp_f5.snowpack_cover_full) if "snowpack_cover_full" in cp_f5 else 0.32,
		"insol_dev_min": float(cp_f5.insolation_dev_clamp_min) if "insolation_dev_clamp_min" in cp_f5 else -1.0,
		"insol_dev_max": float(cp_f5.insolation_dev_clamp_max) if "insolation_dev_clamp_max" in cp_f5 else 1.0,
	}
	var async_t0: int = Time.get_ticks_usec()
	if not bool(context._generator._data_core_world_ext.async_climate_round_kick(input)):
		report["reason"] = "kick returned false"
		print("[async/bench pass_a] FAIL: ", report["reason"])
		return report

	# 5) busy-wait
	var poll_result: Dictionary = context._generator._busy_wait_poll(200_000)
	var async_elapsed_us: int = Time.get_ticks_usec() - async_t0
	if poll_result.is_empty():
		report["reason"] = "worker did not complete within 200ms"
		print("[async/bench pass_a] FAIL: ", report["reason"])
		return report

	# 6) compare each F32 field
	var total_diff_count: int = 0
	var worst_field: String = ""
	var worst_max_diff: float = 0.0
	var field_diffs: Dictionary = {}
	for f in f32_fields:
		var ref_a: PackedFloat32Array = ref_f32[f]
		var async_a: PackedFloat32Array = map.get(f) as PackedFloat32Array
		var d: Dictionary = context._generator._diff_f32_arrays(ref_a, async_a, n_cells)
		field_diffs[f] = d
		total_diff_count += int(d["diff_count"])
		if float(d["max_abs_diff"]) > worst_max_diff:
			worst_max_diff = float(d["max_abs_diff"])
			worst_field = f

	# u8 field diff (ema_initialized)
	var u8_diff_count: int = 0
	for f in u8_fields:
		var ref_a: PackedByteArray = ref_u8[f]
		var async_a: PackedByteArray = map.get(f) as PackedByteArray
		for i in range(n_cells):
			var r: int = ref_a[i] if i < ref_a.size() else 0
			var a: int = async_a[i] if i < async_a.size() else 0
			if r != a:
				u8_diff_count += 1

	# 7) 恢复 sim 状态
	for f in f32_fields:
		map.set(f, (snap_f32[f] as PackedFloat32Array).duplicate())
	for f in u8_fields:
		map.set(f, (snap_u8[f] as PackedByteArray).duplicate())
	context._generator._data_core_world_ext.refresh_slots_from_map()

	# 8) 报告
	report["ok"] = (total_diff_count == 0 and u8_diff_count == 0)
	report["n_cells"] = n_cells
	report["sync_us"] = sync_elapsed_us
	report["async_total_us"] = async_elapsed_us
	report["worker_compute_us"] = int(poll_result.get("worker_compute_us", 0))
	report["pass_a_us"] = int(poll_result.get("pass_a_us", 0))
	report["total_diff_count_f32"] = total_diff_count
	report["total_diff_count_u8"] = u8_diff_count
	report["worst_field"] = worst_field
	report["worst_max_abs_diff"] = worst_max_diff
	report["field_diffs"] = field_diffs

	print("[async/bench pass_a] === A-B verification ===")
	print("  n_cells=%d  sync_us=%d  async_total_us=%d" % [n_cells, sync_elapsed_us, async_elapsed_us])
	print("  worker_compute_us=%d  pass_a_us=%d" % [
		int(poll_result.get("worker_compute_us", 0)), int(poll_result.get("pass_a_us", 0))])
	print("  total_diff_count_f32=%d  total_diff_count_u8=%d" % [total_diff_count, u8_diff_count])
	print("  worst_field=%s  worst_max_abs_diff=%.9f" % [worst_field, worst_max_diff])
	if total_diff_count > 0:
		# 打印每个有差异的字段细节
		for f in f32_fields:
			var d: Dictionary = field_diffs[f]
			if int(d["diff_count"]) > 0:
				print("    [%s] diff=%d max=%.9f first_idx=%d" % [
					f, int(d["diff_count"]), float(d["max_abs_diff"]), int(d["first_diff_idx"])])
	if report["ok"]:
		print("[async/bench pass_a] OK ✅ — 16 fields all bit-equal sync")
	else:
		print("[async/bench pass_a] FAIL ❌")
	return report

# busy-wait poll worker 结果，最多 timeout_us 微秒

static func _busy_wait_poll(context, timeout_us: int) -> Dictionary:
	var poll_result: Dictionary = {}
	var deadline_us: int = Time.get_ticks_usec() + timeout_us
	while Time.get_ticks_usec() < deadline_us:
		poll_result = context._generator._data_core_world_ext.async_climate_round_poll()
		if not poll_result.is_empty():
			break
		OS.delay_msec(1)
	return poll_result

# 比较两个 PackedFloat32Array，返回 {diff_count, max_abs_diff, first_diff_idx}

static func _diff_f32_arrays(context, a: PackedFloat32Array, b: PackedFloat32Array, n: int) -> Dictionary:
	var diff_count: int = 0
	var max_abs_diff: float = 0.0
	var first_diff_idx: int = -1
	for i in range(n):
		var av: float = a[i] if i < a.size() else 0.0
		var bv: float = b[i] if i < b.size() else 0.0
		var d: float = absf(av - bv)
		if d > max_abs_diff:
			max_abs_diff = d
		if d > 0.0:
			if first_diff_idx < 0:
				first_diff_idx = i
			diff_count += 1
	return {
		"diff_count": diff_count,
		"max_abs_diff": max_abs_diff,
		"first_diff_idx": first_diff_idx,
	}
