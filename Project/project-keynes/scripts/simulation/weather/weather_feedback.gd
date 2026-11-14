extends "res://scripts/simulation/generator_context.gd"

func _apply_weather_to_map_feedback_pass(map: MapData, day_scale: float = 1.0, write_weather_veg_pressure: bool = true) -> void:
	if map == null:
		return
	var cp: ClimateProfile = _generator._c()
	if cp == null:
		return
	var soil_gain: float = float(cp.weather_to_soil_gain)
	var veg_gain: float = float(cp.weather_to_vegetation_gain)
	var scale: float = maxf(day_scale, 1.0)
	var per_day_clamp: float = float(cp.feedback_per_day_clamp) * scale
	var ocean_drift_gain: float = float(cp.ocean_moisture_drift_gain)
	# 让天气流动(2026-06-21)：weather → base_moisture 反馈增益(cp.get 兼容旧 profile 无此字段)。
	var base_m_gain: float = float(cp.weather_to_base_moisture_gain) if cp.get("weather_to_base_moisture_gain") != null else 0.0
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = neighbor_indices.size() >= n_cells * 6

	# ─── DOTS-Final-Push 任务 4：DCWorldExt C++ 快路径 ──────────────────
	# 触发条件：
	#   1. ClimateProfile.use_gdext_climate_feedback == true
	#   2. _data_core_world_ext 已 bind 且 has_method("run_climate_feedback_pass")
	#   3. fast_indexed（neighbor_indices_packed 完整 — ocean drift 段需要）
	#   4. C++ 端返回 ≥ 0
	# 任意一条不满足 → 报告 native failure，不再进入 GDScript 计算循环。
	#
	# soil_moisture / veg_growth_pressure / temperature_transport_anomaly 三个字段
	# 未 SoA 化，走 in/out PackedArray pack/unpack。base_moisture 已 SoA，C++ 直读直写。
	if not _generator._gdext_feedback_first_attempt_logged:
		_generator._gdext_feedback_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_climate_feedback flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path = cp.resource_path
		var ext_ok: bool = _generator._data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _generator._data_core_world_ext.has_method("run_climate_feedback_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL → fall through to GDScript path"
		print("[feedback/stage_b] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_climate_feedback = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_climate_feedback_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells * 6, neighbor_indices.size()])
		print("  verdict = %s" % verdict)
	if cp != null and _generator._data_core_world_ext != null \
			and _generator._data_core_world_ext.has_method("run_climate_feedback_pass") and fast_indexed:
		if not _generator._gdext_feedback_signature_checked:
			_generator._gdext_feedback_signature_checked = true
			_generator._gdext_feedback_signature_ok = _generator._validate_gdext_method_signature("run_climate_feedback_pass", 1)
			print("[feedback/stage_b] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_generator._gdext_feedback_signature_ok))
		# Pack in/out 数组：3 个 PackedFloat32Array（n_cells 长度）
		var soil_arr: PackedFloat32Array = PackedFloat32Array()
		var vg_arr: PackedFloat32Array = PackedFloat32Array()
		var tta_arr: PackedFloat32Array = PackedFloat32Array()
		soil_arr.resize(n_cells)
		vg_arr.resize(n_cells)
		tta_arr.resize(n_cells)
		for i in range(n_cells):
			var cell_pack: HexCell = cells[i]
			soil_arr[i] = cell_pack.soil_moisture
			vg_arr[i] = cell_pack.vegetation_growth_pressure
			tta_arr[i] = cell_pack.temperature_transport_anomaly
		var knobs: Dictionary = {
			"n_cells": n_cells,
			"soil_gain": soil_gain,
			"veg_gain": veg_gain,
			"write_weather_veg_pressure": write_weather_veg_pressure,
			"scale": scale,
			"per_day_clamp": per_day_clamp,
			"ocean_drift_gain": ocean_drift_gain,
			"weather_to_base_moisture_gain": base_m_gain,
			"wt_clear_id": int(WeatherType.WT.CLEAR),
			"wt_rain_id": int(WeatherType.WT.RAIN),
			"wt_storm_id": int(WeatherType.WT.STORM),
			"wt_monsoon_id": int(WeatherType.WT.MONSOON),
			"wt_blizzard_id": int(WeatherType.WT.BLIZZARD),
			"wt_drought_id": int(WeatherType.WT.DROUGHT),
			"wt_heatwave_id": int(WeatherType.WT.HEATWAVE),
			"neighbor_indices": neighbor_indices,
			"temp_transport_anomaly": tta_arr,
			"soil_moisture_arr": soil_arr,
			"veg_growth_pressure_arr": vg_arr,
		}
		# storage A/B 同源契约：refresh 让 SoA 取得最新值（接 weather_refresh 上一段）
		if _generator._data_core_world_ext.has_method("refresh_slots_from_map"):
			_generator._data_core_world_ext.refresh_slots_from_map()
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_climate_feedback_pass，C++ 内部根据 CPU 特性 / n_cells 自动
		# 选择 scalar / SIMD / threaded 三档执行路径。
		var rc: float = float(_generator._data_core_world_ext.run_climate_feedback_pass(knobs))
		if _generator._gdext_feedback_runs + _generator._gdext_feedback_fallbacks < 3:
			print("[feedback/stage_b] DEBUG call#%d: rc=%.4f n_cells=%d scale=%.2f" % [
				_generator._gdext_feedback_runs + _generator._gdext_feedback_fallbacks + 1,
				rc, n_cells, scale,
			])
		if rc >= 0.0:
			# 写回 in/out arrays（base_moisture 已通过 SoA flush 写回 cell.base_moisture）
			var soil_out: PackedFloat32Array = knobs.get("soil_moisture_arr", soil_arr)
			var vg_out: PackedFloat32Array = knobs.get("veg_growth_pressure_arr", vg_arr)
			for i in range(n_cells):
				var cell_unpack: HexCell = cells[i]
				cell_unpack.soil_moisture = soil_out[i]
				cell_unpack.vegetation_growth_pressure = vg_out[i]
			_generator._gdext_feedback_runs += 1
			_generator._gdext_feedback_total_ms += rc
			if _generator._gdext_feedback_runs == 1:
				print("[feedback/stage_b] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 6.1ms; target < 0.5ms)" % rc)
			return
		_generator._gdext_feedback_fallbacks += 1
		if _generator._gdext_feedback_fallbacks == 1:
			print("[stage_b] gdext path UNAVAILABLE: run_climate_feedback_pass — falling back to GDScript")

	for i in range(cells.size()):
		var cell: HexCell = cells[i]
		if _generator._is_water(cell.terrain):
			# 水体不参与土壤 / 植被反馈（海冰已有自己的半慢层）
			continue
		# ── 长期洋流 → base_moisture 漂移（寒流海岸沙漠通路，年尺度）──
		# 计算邻水平均 anomaly；以"日 |Δ| ≤ feedback_per_day_clamp"上限漂移
		# base_moisture，让稳态寒流海岸在 ~1 in-game year 内实测 base 下降 ~0.05–0.10，
		# 暖流海岸对称上升。彻底关闭时 ocean_moisture_drift_gain == 0。
		if ocean_drift_gain > 0.0:
			var sum_an: float = 0.0
			var n_water: int = 0
			if fast_indexed:
				var base: int = i * 6
				for d in range(6):
					var nb_idx: int = neighbor_indices[base + d]
					if nb_idx < 0:
						continue
					var nb: HexCell = cells[nb_idx]
					if _generator._is_water(nb.terrain):
						sum_an += nb.temperature_transport_anomaly
						n_water += 1
			else:
				for nb: HexCell in map.get_neighbors(cell):
					if nb != null and _generator._is_water(nb.terrain):
						sum_an += nb.temperature_transport_anomaly
						n_water += 1
			if n_water > 0:
				var avg_an: float = sum_an / float(n_water)
				if absf(avg_an) > 0.005:
					# coastal_ratio 0..1：内陆为 0，半岛 ≈ 1
					var coastal_ratio: float = clampf(float(n_water) / 6.0, 0.0, 1.0)
					var d_base: float = clampf(ocean_drift_gain * avg_an * coastal_ratio * scale,
						-per_day_clamp, per_day_clamp)
					cell.base_moisture = clampf(cell.base_moisture + d_base, 0.0, 1.0)
		var wt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var w_int: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		if w_int < 0.01:
			continue
		# 降水贡献（RAIN / STORM / MONSOON 正；DROUGHT / HEATWAVE 负）
		var precip_contrib: float = 0.0
		match wt:
			WeatherType.WT.RAIN:     precip_contrib = w_int
			WeatherType.WT.STORM:    precip_contrib = w_int * 0.8
			WeatherType.WT.MONSOON:  precip_contrib = w_int * 1.2
			WeatherType.WT.BLIZZARD: precip_contrib = w_int * 0.3  # 雪融化慢，贡献弱
			WeatherType.WT.DROUGHT:  precip_contrib = -w_int * 0.6
			WeatherType.WT.HEATWAVE: precip_contrib = -w_int * 0.4
			_: precip_contrib = 0.0
		# 累加到 soil_moisture（小权重）
		var d_soil: float = clampf(soil_gain * precip_contrib * scale, -per_day_clamp, per_day_clamp)
		cell.soil_moisture = clampf(cell.soil_moisture + d_soil, -0.5, 0.5)
		# 让天气流动(2026-06-21)：weather → base_moisture 直接反馈(镜像 C++ run_climate_feedback_pass)。
		if base_m_gain > 0.0:
			var d_bm: float = clampf(base_m_gain * precip_contrib * scale, -per_day_clamp, per_day_clamp)
			cell.base_moisture = clampf(cell.base_moisture + d_bm, 0.0, 1.0)
		if write_weather_veg_pressure:
			# 未跑 veg_dyn 的 tick 保留天气压力；跑过 veg_dyn 的 tick 让 VGP 保持 target - vitality。
			var d_veg: float = clampf(veg_gain * precip_contrib * scale, -per_day_clamp, per_day_clamp)
			cell.vegetation_growth_pressure = clampf(cell.vegetation_growth_pressure + d_veg, -0.5, 0.5)

# ─── Milestone 4：完整耦合反馈 ───────────────────────────────────────────
# 三个 pass + 一个演替触发，按"植被影响气候 → 气候反过来评估植被适应性 → 长期不适应触发演替"的因果序排列。
#
# 设计原则：
#   - 三个 pass 全部只动 cell.current_state 与 cell.vegetation_vitality / streak 计数器，
#     不写 base_moisture / base_temperature / base_vegetation。base_* 仅由 refresh_seasonal /
#     refresh_yearly 缓慢漂移；M4 反馈是"日尺度"的快变扰动。
#   - 蒸腾外溢只在陆地 cell 之间扩散（海面 / 冰川不参与）。
#   - 反照率只在陆地 cell 上调整温度（海洋温度由洋流体系决定，M4 不动）。
#   - 演替触发后立即写 cell.vegetation 并刷 base_vegetation，让玩家在 panel 看到"演替已发生"。

# Pass 1：蒸腾外溢。每个陆地 cell 把自己 transpiration × current_moisture 的一部分，
# 平均分给 6 个邻居 + 自己。所有写入做完后再统一应用，避免顺序耦合。
# const TRANSPIRATION_OUTFLOW_RATE (migrated to ClimateProfile.transpiration_outflow_rate)   # 每天最多 2.5% moisture 外溢给邻居
# const TRANSPIRATION_SELF_RATE (migrated to ClimateProfile.transpiration_self_rate)      # 每天最多 1.5% moisture 留给自己（蒸腾闭环）
# F.5 helper：按 VegetationType.VEG enum 顺序构建 transpiration donor table。
# 第一次调用时填好 cache，后续直接返回 cache（仍需 cache 副本 → C++ 端 zero-copy
# 入参；godot::PackedFloat32Array 经 Variant 边界后 refcount ≥ 2 但 ptr() 不会
# CoW，仅 ptrw() 才会）。VEG enum 长度通过 VegetationType.VEG.size() 取（GDScript
# enum 在 GDScript 4 中支持 .size() / .keys() 反射）。

