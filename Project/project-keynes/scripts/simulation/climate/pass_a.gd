extends "res://scripts/simulation/generator_context.gd"
class_name DCClimatePassA

## Climate Pass-A native dispatch. The generator owns all runtime state; this
## collaborator only assembles the existing call and reports its result.

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null or map == null:
		return
	_climate_pass_a_legacy(map, season_phase)

func _climate_pass_a_legacy(map: MapData, season_phase: float) -> void:
	var cp: ClimateProfile = _generator._c()
	if cp == null or _generator._last_cfg == null:
		push_error("[climate/pass_a] native failed: missing climate context")
		return
	var days_per_year: int = _generator._calendar_days_per_year()
	var annual_ema_alpha: float = 1.0 / float(days_per_year)
	# [dt-aware EMA 2026-06-28] 镜像 world_ext_climate.cpp：temp_30d/365d EMA alpha 按经过游戏天数等效缩放，
	# 避免加速档下 EMA 窗口膨胀致 temp_anomaly 坍缩（DROUGHT/HEATWAVE 不可达）。α_eff=1-(1-base)^dt；dt<=1=base。
	var _climate_dt_days_ema: float = _generator._consume_climate_dt_days()
	var ema_alpha_30: float = (1.0 / 30.0) if _climate_dt_days_ema <= 1.0 else (1.0 - pow(1.0 - 1.0 / 30.0, _climate_dt_days_ema))
	var ema_alpha_365: float = annual_ema_alpha if _climate_dt_days_ema <= 1.0 else (1.0 - pow(1.0 - annual_ema_alpha, _climate_dt_days_ema))

	# [DIAG mask_dirty=2400 排查 · 2026-05-20] 入口 flag dump（仅前 3 个 round，
	# 之后按 WorldClock 年长节流）。诊断完成后整段删除。
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_climate_pass_a / use_data_core_climate
	# flag 已删除——这里保留原原生 DIAG 输出格式不变，但打印常量 true。
	if _generator._diagnostics_bus.get_climate_call_count() <= 3 or _generator._is_annual_log_tick(_generator._diagnostics_bus.get_climate_call_count()):
		print("[DIAG pass_a_entry] day=%d phase=%.3f gdext_pass_a=%s use_data_core_climate=%s use_soa_pipeline=%s use_sparse_climate=%s ext_bound=%s" % [
			_generator._diagnostics_bus.get_climate_call_count(), season_phase,
			"true",
			"true",
			str(bool(cp.use_soa_pipeline)),
			str(bool(cp.use_sparse_climate)),
			str(_generator._data_core_world_ext != null),
		])

	# dots-roadmap-to-gdextension 务实 A — climate Pass-A C++ 加速路由。
	# 三态路径优先级：
	# native dispatch；C++ 失败时保留上一份字段并报告失败。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_climate_pass_a / use_data_core_climate
	# 两个闸门 flag 已删除——现恒走原生单边分支（方法由握手保证）。
	if _generator._data_core_world_ext != null and map != null:
		# §11.2: Pass-A is the first C++ pass in the pipeline. Refresh all
		# slots from MapData so C++ reads GDScript-side changes since last flush.
		# refresh-consolidation-2026-06：改走 round 守门员，整个 climate daily round
		# 内多次调用收编为最多 ~3 次实际 refresh。详见 _ensure_climate_daily_round_slots_fresh。
		_generator._ensure_climate_daily_round_slots_fresh()
		# Step 3b-1: 真实 cp_struct packing。
		# 这些字段必须与 world_ext.cpp::run_climate_pass_a 第 3 节读取顺序一一对应。
		# 任何字段缺失 / 类型不符都会让 C++ 端 return -1.0；strict-native 下保留上一帧结果。
		# truth source for 各 cp.xxx 字段：scripts/geography/climate_profile.gd。
		# 日照/昼长/热输入由 C++ pass 逐格写入 SoA，不再从 GDScript 打包日照 LUT。
		var cp_struct: Dictionary = {
			"use_insol":        true,
			"use_sparse":       bool(cp.use_sparse_climate),
			"insol_amp":        float(cp.season_temp_amp) if "season_temp_amp" in cp else 0.20,
			"insol_gain":       float(cp.insolation_season_gain) if "insolation_season_gain" in cp else 1.0,
			"moist_scale_now":  1.0,
			"runtime_moisture_base_relax_rate": float(cp.runtime_moisture_base_relax_rate) if "runtime_moisture_base_relax_rate" in cp else 0.24,
			"runtime_moisture_weather_vapor_weight": float(cp.runtime_moisture_weather_vapor_weight) if "runtime_moisture_weather_vapor_weight" in cp else 0.12,
		"runtime_moisture_precip_weight": float(cp.runtime_moisture_precip_weight) if "runtime_moisture_precip_weight" in cp else 0.78,
		"runtime_moisture_soil_weight": float(cp.runtime_moisture_soil_weight) if "runtime_moisture_soil_weight" in cp else 1.82,
		"runtime_moisture_soil_dry_weight": float(cp.runtime_moisture_soil_dry_weight) if "runtime_moisture_soil_dry_weight" in cp else 2.21,
		"runtime_moisture_water_balance_weight": float(cp.runtime_moisture_water_balance_weight) if "runtime_moisture_water_balance_weight" in cp else 1.04,
		"runtime_moisture_water_balance_dry_weight": float(cp.runtime_moisture_water_balance_dry_weight) if "runtime_moisture_water_balance_dry_weight" in cp else 1.30,
			"season_phase":     float(season_phase),
			"days_per_year":    _generator._calendar_days_per_year(),
			"axial_tilt_deg":   float(cp.axial_tilt_deg) if "axial_tilt_deg" in cp else 23.5,
			"day_length_gain":  float(cp.insolation_daylen_amp) if "insolation_daylen_amp" in cp else 0.35,
			"solar_gain":       float(cp.solar_gain) if "solar_gain" in cp else 1.0,
			"insol_dev_min":    float(cp.insolation_dev_clamp_min) if "insolation_dev_clamp_min" in cp else -1.0,
			"insol_dev_max":    float(cp.insolation_dev_clamp_max) if "insolation_dev_clamp_max" in cp else 1.0,
			"thermal_inertia_land": float(cp.thermal_inertia_land) if "thermal_inertia_land" in cp else 0.35,
			"thermal_inertia_water": float(cp.thermal_inertia_water) if "thermal_inertia_water" in cp else 0.045,
			"thermal_inertia_snow": float(cp.thermal_inertia_snow) if "thermal_inertia_snow" in cp else 0.09,
			"thermal_inertia_high_mountain": float(cp.thermal_inertia_high_mountain) if "thermal_inertia_high_mountain" in cp else 0.16,
			"thermal_daily_delta_cap": float(cp.thermal_daily_delta_cap) if "thermal_daily_delta_cap" in cp else 0.15,
			"temp_land_continentality": float(cp.temp_land_continentality) if "temp_land_continentality" in cp else 1.0,
			"thermal_dt_days": _generator._consume_climate_dt_days(),
			"snowpack_cover_low": float(cp.snowpack_cover_low) if "snowpack_cover_low" in cp else 0.05,
			"snowpack_cover_full": float(cp.snowpack_cover_full) if "snowpack_cover_full" in cp else 0.32,
			"sea_level":        float(_generator._last_cfg.sea_level),
		}
		var rc: float = -1.0
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_climate_pass_a，C++ 内部根据 CPU 特性 / n_cells 自动选择
		# scalar / SIMD / threaded 三档执行路径。
		rc = float(_generator._data_core_world_ext.run_climate_pass_a(cp_struct, float(season_phase), float(season_phase)))
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] C++ Pass-A 路径 rc + DCWorld dirty
		# 即时观测：rc>=0 表示 C++ 接管并已 return；此处 peek 一次 dirty count 看 C++
		# 端是否在 set() 推回 MapData 时也副作用 mark 到 DCWorld（理论上不会）。
		if _generator._diagnostics_bus.get_climate_call_count() <= 3 or _generator._is_annual_log_tick(_generator._diagnostics_bus.get_climate_call_count()):
			var _dirty_after_cpp: int = -1
			if _generator._data_core_world != null and _generator._data_core_world.has_method("peek_dirty_count"):
				_dirty_after_cpp = int(_generator._data_core_world.peek_dirty_count())
			print("[DIAG pass_a_cpp] day=%d rc=%.4f cpp_taken_over=%s dirty_count_after_cpp=%d" % [
				_generator._diagnostics_bus.get_climate_call_count(), rc, str(rc >= 0.0), _dirty_after_cpp
			])
		if rc >= 0.0:
			# C++ 路径已接管整段 Pass-A 并已通过 set() 把结果推回 MapData。
			# 与 SoA 路径一样，这里直接返回；其余 sub-pass（B/ocean/sea_ice/transp）
			# 继续读 map.*_arr 强类型字段，与 GDScript 路径无差异。
			# 但 C++ 直接写 MapData 会绕过 GDScript SoA value-diff 路径；
			# dynamic visual atlas 依赖 DCWorld dirty mask，因此这里显式发布一次
			# 全气候 dirty，避免温度/雪/海冰 GPU Atlas 滞后到下一次全量 sweep。
			var native_dirty_cells: int = 0
			if map != null and map.has_method("cell_count"):
				native_dirty_cells = int(map.cell_count())
			elif map != null and map.has_method("all_cells"):
				native_dirty_cells = int(map.all_cells().size())
			_generator._pa_last_total_cells = native_dirty_cells
			_generator._pa_last_pushed_cells = native_dirty_cells
			if map != null and map.has_method("mark_all_climate_dirty"):
				map.mark_all_climate_dirty()
			if _generator._data_core_world != null and _generator._data_core_world.has_method("mark_dirty_all"):
				_generator._data_core_world.mark_dirty_all()
			return
		push_error("[climate/pass_a] native failed: native pass returned failure; previous fields retained")
		return

	push_error("[climate/pass_a] native failed: extension or native method unavailable; previous fields retained")
	return


func _climate_pass_a_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	push_error("[climate/pass_a] native failed: GDScript SoA fallback retired; previous fields retained")
