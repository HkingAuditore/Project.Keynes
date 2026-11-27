extends RefCounted

## Packs summary inputs and decodes native weather fronts.


static func _build_weather_summary_knobs(host, map: MapData, world: WorldData) -> Dictionary:
	var n_cells: int = map.cell_count()
	var map_id: int = map.get_instance_id()
	if host._summary_cache_map_id != map_id or host._summary_cache_n != n_cells \
			or host._summary_q_cache.size() != n_cells or host._summary_r_cache.size() != n_cells:
		var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		host._summary_q_cache = PackedInt32Array()
		host._summary_r_cache = PackedInt32Array()
		host._summary_q_cache.resize(n_cells)
		host._summary_r_cache.resize(n_cells)
		for i in range(n_cells):
			var c: HexCell = cells[i]
			host._summary_q_cache[i] = c.q
			host._summary_r_cache[i] = c.r
		host._summary_cache_map_id = map_id
		host._summary_cache_n = n_cells
	# wind_x / wind_y 已是 SoA（map.wind_x_arr / wind_y_arr）；C++ 通过 _slots
	# 直接读，不必通过 knobs 传。
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	# ─── Phase A.3 fast path：从 KnobsHandle 拿 summary 段缓存 Dict ──
	if host._knobs_handle != null and host._knobs_handle.has_method("to_summary_knobs_dict"):
		# day_counter 每帧变化 → 走单字段细粒度入口（无变化时不拉 dirty）
		if host._knobs_handle.has_method("set_day_counter"):
			host._knobs_handle.set_day_counter(host._day_counter)
		var dynamic_fields_sum: Dictionary = {
			"n_cells": n_cells,
			"hex_size": host._hex_size,
			"cell_q_arr": host._summary_q_cache,
			"cell_r_arr": host._summary_r_cache,
			"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
			"weather_wrap_width_x": host._field_solver._world_wrap_width_x(map),
			"cyclone_wake_days": host._cyclone_wake_days,
			"cyclone_storm_type_id": int(WeatherType.WT.STORM),
			"water_terrain_ids": water_ids,
		}
		return host._merge_resident_knobs_with_dynamic(
			host._knobs_handle.to_summary_knobs_dict(), dynamic_fields_sum)
	return {
		"n_cells": n_cells,
		"hex_size": host._hex_size,
		"summary_limit": host._field_summary_limit,
		# 阈值（与 host._build_field_summary_fronts 内 const 严格同源）# 阈值（与 _build_field_summary_fronts 内 const 严格同源）
		"intensity_enter": 0.10,
		"intensity_hold": 0.06,
		# 合并相关
		"merge_ratio": 0.65,
		"merge_max_rounds": 4,
		# WeatherFront radius 公式： size*(1.6 + sqrt(area)*1.05)；
		# merge 距离阈值用的"等效半径"公式：size*sqrt(area)*1.05。
		"radius_base": 1.6,
		"radius_scale": 1.05,
		# WT 枚举常量（C++ 不直读 GDScript Resource，传过来用整型即可）
		"wt_clear": int(WeatherType.WT.CLEAR),
		"weather_wrap_width_x": host._field_solver._world_wrap_width_x(map),
		"cyclone_wake_days": host._cyclone_wake_days,
		"cyclone_storm_type_id": int(WeatherType.WT.STORM),
		"water_terrain_ids": water_ids,
		# Q/R 拓扑（C++ 端用于 cube_to_world / world_to_cube 反查）
		"cell_q_arr": host._summary_q_cache,
		"cell_r_arr": host._summary_r_cache,
		# 邻居索引（n_cells*6，-1 表无邻居；C++ 端 BFS / pick_inheritance_seed 必需）
		"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
		# Drift 调试日志（C++ 路径下默认关闭，verify mode 不影响日志）
		"drift_debug_log": false,
		"day_counter": host._day_counter,
	}

# 把 C++ 端返回的 fronts Dictionary 解包为 WeatherFront 实例。字段命名必须与
# C++ 端 build_front_dict 保持 1:1，任何缺字段就退化到 WeatherFront 默认值。

static func _unpack_summary_dict_to_front(host, d: Dictionary) -> WeatherFront:
	var f = WeatherFront.new()
	f.type = int(d.get("type", WeatherType.WT.CLEAR))
	f.center = d.get("center", Vector2.ZERO)
	f.intensity = clampf(float(d.get("intensity", 0.0)), 0.0, 1.0)
	f.radius = float(d.get("radius", 200.0))
	var ax: Vector2 = d.get("axis", Vector2.RIGHT)
	if ax.length_squared() <= 0.0001:
		ax = Vector2.RIGHT
	f.axis = ax.normalized()
	f.stable_axis = d.get("stable_axis", f.axis)
	f.velocity = d.get("velocity", Vector2.ZERO)
	f.major_scale = float(d.get("major_scale", 1.30))
	f.minor_scale = float(d.get("minor_scale", 0.85))
	f.age_days = int(d.get("age_days", 0))
	f.ttl_days = int(d.get("ttl_days", 12))
	f.decay_per_day = float(d.get("decay_per_day", 0.0))
	f.life_progress = clampf(float(d.get("life_progress", 0.15)), 0.0, 1.0)
	f.cloud_amount = clampf(float(d.get("cloud_amount", 0.0)), 0.0, 1.0)
	f.precip_amount = clampf(float(d.get("precip_amount", 0.0)), 0.0, 1.0)
	f.dissolve_amount = float(d.get("dissolve_amount", 0.0))
	f.edge_seed = float(d.get("edge_seed", 0.0))
	f.front_temperature_advection = float(d.get("front_temperature_advection", 0.0))
	f.front_diagnostic_kind = int(d.get("front_diagnostic_kind", WeatherFront.FRONT_DIAG_NONE))
	return f

# ─── Phase A.1（dots-total-cpp roadmap）：fronts zero-copy SoA 解包 ─────
# 从 C++ 端 run_weather_summary_fronts_pass 返回的 out["fronts_soa"]: Dict
# 中读取 23 个 PackedArray 列（命名严格沿用 fronts_schema.gd FRONTS_SCHEMA
# cpp_name），按 idx 1:1 构造 WeatherFront 实例数组。
#
# 与 host._unpack_summary_dict_to_front 等价但 marshalling 大幅减负：# 与 _unpack_summary_dict_to_front 等价但 marshalling 大幅减负：
#   - 旧路径：每 front N=12 个 → 跨语言 ~17*12 = 204 个 Variant entry
#   - SoA 路径：固定 ~24 个 PackedArray 引用（与 N 无关）
#
# 容错策略：任意必需列缺失或 size 不匹配 → 返回 null 触发 caller fallback
# 到旧 dict 路径（保证向前兼容 stale .dll）。

static func _unpack_summary_soa_to_fronts(host, soa: Dictionary) -> Variant:
	var n: int = int(soa.get("n_fronts", -1))
	if n < 0:
		return null
	if n == 0:
		return [] as Array[WeatherFront]
	var center_x: PackedFloat32Array = soa.get("front_center_x", PackedFloat32Array())
	var center_y: PackedFloat32Array = soa.get("front_center_y", PackedFloat32Array())
	var radius_arr: PackedFloat32Array = soa.get("front_radius", PackedFloat32Array())
	var velocity_x: PackedFloat32Array = soa.get("front_velocity_x", PackedFloat32Array())
	var velocity_y: PackedFloat32Array = soa.get("front_velocity_y", PackedFloat32Array())
	var axis_x: PackedFloat32Array = soa.get("front_axis_x", PackedFloat32Array())
	var axis_y: PackedFloat32Array = soa.get("front_axis_y", PackedFloat32Array())
	var stable_axis_x: PackedFloat32Array = soa.get("front_stable_axis_x", PackedFloat32Array())
	var stable_axis_y: PackedFloat32Array = soa.get("front_stable_axis_y", PackedFloat32Array())
	var major_scale_arr: PackedFloat32Array = soa.get("front_major_scale", PackedFloat32Array())
	var minor_scale_arr: PackedFloat32Array = soa.get("front_minor_scale", PackedFloat32Array())
	var edge_seed_arr: PackedFloat32Array = soa.get("front_edge_seed", PackedFloat32Array())
	var intensity_arr: PackedFloat32Array = soa.get("front_intensity", PackedFloat32Array())
	var decay_arr: PackedFloat32Array = soa.get("front_decay_per_day", PackedFloat32Array())
	var life_arr: PackedFloat32Array = soa.get("front_life_progress", PackedFloat32Array())
	var cloud_arr: PackedFloat32Array = soa.get("front_cloud_amount", PackedFloat32Array())
	var precip_arr: PackedFloat32Array = soa.get("front_precip_amount", PackedFloat32Array())
	var dissolve_arr: PackedFloat32Array = soa.get("front_dissolve_amount", PackedFloat32Array())
	var type_arr: PackedInt32Array = soa.get("front_type", PackedInt32Array())
	var ttl_arr: PackedInt32Array = soa.get("front_ttl_days", PackedInt32Array())
	var age_arr: PackedInt32Array = soa.get("front_age_days", PackedInt32Array())
	var temp_adv_arr: PackedFloat32Array = soa.get("front_temperature_advection", PackedFloat32Array())
	var diag_kind_arr: PackedInt32Array = soa.get("front_diagnostic_kind", PackedInt32Array())
	# 必需列长度全检查（任一不匹配立即放弃，让 caller 走 dict fallback）
	if center_x.size() != n or center_y.size() != n: return null
	if radius_arr.size() != n: return null
	if velocity_x.size() != n or velocity_y.size() != n: return null
	if axis_x.size() != n or axis_y.size() != n: return null
	if stable_axis_x.size() != n or stable_axis_y.size() != n: return null
	if major_scale_arr.size() != n or minor_scale_arr.size() != n: return null
	if edge_seed_arr.size() != n: return null
	if intensity_arr.size() != n: return null
	if decay_arr.size() != n: return null
	if life_arr.size() != n: return null
	if cloud_arr.size() != n or precip_arr.size() != n: return null
	if dissolve_arr.size() != n: return null
	if type_arr.size() != n or ttl_arr.size() != n or age_arr.size() != n: return null

	var out: Array[WeatherFront] = [] as Array[WeatherFront]
	out.resize(n)
	for i in range(n):
		var f = WeatherFront.new()
		f.type = type_arr[i]
		f.center = Vector2(center_x[i], center_y[i])
		f.intensity = clampf(intensity_arr[i], 0.0, 1.0)
		f.radius = radius_arr[i]
		# axis 归一化与 dict 路径等价（C++ 端已经 normalize 但 GDScript fallback 也照同样语义守护）
		var ax = Vector2(axis_x[i], axis_y[i])
		if ax.length_squared() <= 0.0001:
			ax = Vector2.RIGHT
		f.axis = ax.normalized()
		var sax = Vector2(stable_axis_x[i], stable_axis_y[i])
		if sax.length_squared() <= 0.0001:
			sax = f.axis
		f.stable_axis = sax
		f.velocity = Vector2(velocity_x[i], velocity_y[i])
		f.major_scale = major_scale_arr[i]
		f.minor_scale = minor_scale_arr[i]
		f.age_days = age_arr[i]
		f.ttl_days = ttl_arr[i]
		f.decay_per_day = decay_arr[i]
		f.life_progress = clampf(life_arr[i], 0.0, 1.0)
		f.cloud_amount = clampf(cloud_arr[i], 0.0, 1.0)
		f.precip_amount = clampf(precip_arr[i], 0.0, 1.0)
		f.dissolve_amount = dissolve_arr[i]
		f.edge_seed = edge_seed_arr[i]
		if temp_adv_arr.size() == n:
			f.front_temperature_advection = temp_adv_arr[i]
		if diag_kind_arr.size() == n:
			f.front_diagnostic_kind = diag_kind_arr[i]
		out[i] = f
	return out



static func _build_fronts_from_rc(host, rc_dict: Dictionary) -> Array[WeatherFront]:
	# dots-flag-prune-pr1 round 2: use_gdext_fronts_soa flag 已删除——恒走 SoA 探测路径，
	# rc_dict.fronts_soa 存在时列扫描构造 WeatherFront，缺失时 fallback 到 Array[Dict]。
	if rc_dict.has("fronts_soa"):
		var soa: Dictionary = rc_dict["fronts_soa"]
		# Phase B Z-lock 实测遥测：editor-only 包夹 unpack 调用，100 样本 ring 满 print。
		var _telemetry_on: bool = OS.has_feature("editor")
		var _t0_us: int = Time.get_ticks_usec() if _telemetry_on else 0
		var soa_out: Variant = host._unpack_summary_soa_to_fronts(soa)
		if _telemetry_on:
			var _dt_us: int = Time.get_ticks_usec() - _t0_us
			if host._fronts_soa_unpack_us_ring.size() < host._FRONTS_SOA_TELEMETRY_WINDOW:
				host._fronts_soa_unpack_us_ring.resize(host._FRONTS_SOA_TELEMETRY_WINDOW)
			host._fronts_soa_unpack_us_ring[host._fronts_soa_unpack_window_idx] = _dt_us
			host._fronts_soa_unpack_window_idx = (host._fronts_soa_unpack_window_idx + 1) % host._FRONTS_SOA_TELEMETRY_WINDOW
			host._fronts_soa_unpack_window_count += 1
			if host._fronts_soa_unpack_window_count >= host._FRONTS_SOA_TELEMETRY_WINDOW:
				# 窗口满：计算 p50/p95/mean，print 后归零再采（持续观测，便于跨阶段对比）
				var _samples: PackedInt32Array = host._fronts_soa_unpack_us_ring.duplicate()
				_samples.sort()
				var _w: int = _samples.size()
				var _p50: int = _samples[_w / 2]
				var _p95: int = _samples[int(float(_w) * 0.95)]
				var _sum: int = 0
				for _v in _samples:
					_sum += int(_v)
				var _mean: float = float(_sum) / float(_w)
				print("[weather/summary] fronts_soa unpack telemetry — n=%d mean=%.1fμs p50=%dμs p95=%dμs (Z-lock threshold: p95<100μs)" % [_w, _mean, _p50, _p95])
				host._fronts_soa_unpack_window_count = 0
				host._fronts_soa_unpack_window_idx = 0
		if soa_out != null:
			if not host._fronts_soa_path_logged:
				host._fronts_soa_path_logged = true
				print("[weather/summary] fronts_soa path ACTIVE — first run n=%d (PackedArray columns, marshalling ~90%% slim vs Array[Dict])" % int(soa.get("n_fronts", 0)))
			return soa_out as Array[WeatherFront]
		else:
			if not host._fronts_soa_warned_fallback:
				host._fronts_soa_warned_fallback = true
				push_warning("[weather/summary] fronts_soa columns missing/invalid; falling back to Array[Dict] path (will retry next tick)")
	# Fallback: 走旧 Array[Dict] 路径
	var fronts_arr: Array = rc_dict.get("fronts", [])
	var out: Array[WeatherFront] = [] as Array[WeatherFront]
	for d in fronts_arr:
		out.append(host._unpack_summary_dict_to_front(d))
	return out

# ─── Phase A.3（dots-total-cpp roadmap）：KnobsHandle dirty-write helper ─
# 把 ClimateProfile + weather_system 自身 _field_* 持久旋钮一次性推送到
# KnobsHandle 的所有段。caller：host.configure_gdext_acceleration 首次装配 + 后续# KnobsHandle 的所有段。caller：configure_gdext_acceleration 首次装配 + 后续
# ClimateProfile.changed 信号触发（信号 cb 会再调一次本函数）。
#
# 注意：动态 PackedArray ref（_field_slice_* / host._summary_q_cache / map.* SoA /# 注意：动态 PackedArray ref（_field_slice_* / _summary_q_cache / map.* SoA /
# neighbor_indices）不在这里推送 —— 它们每帧由 caller 在 _build_*_knobs
# 外层 merge 进 to_*_knobs_dict() 输出（保留每帧 ref 替换语义）。

static func _try_run_weather_summary_fronts_gdext(host, map: MapData, world: WorldData) -> Variant:
	if host._data_core_world_ext == null:
		return null
	var knobs: Dictionary = host._build_weather_summary_knobs(map, world)
	var rc_dict: Dictionary = host._data_core_world_ext.run_weather_summary_fronts_pass(knobs)
	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0:
		host._gdext_summary_fallbacks += 1
		if not host._gdext_summary_warned_fallback:
			host._gdext_summary_warned_fallback = true
			push_warning("[weather/summary] gdext run_weather_summary_fronts_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
		return null
	host._gdext_summary_runs += 1
	host._gdext_summary_total_ms += rc
	if host._gdext_summary_runs == 1:
		print("[weather/summary] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 17.8ms; charter target < 3.0ms)" % rc)
	# Phase A.1: SoA 优先 + Dict fallback（旧 Array[Dict] 路径仍兼容 stale .dll）
	return host._build_fronts_from_rc(rc_dict)

# ─── plan/weather-refresh-cpp-all PR-2 facade ─────────────────────────────
# 单 cpp call 跑完 weather refresh daily 全套（field_solve + distribute +
# summary_fronts + cyclone_wake + stage_b 五段），消除 GDScript ↔ C++ 之间
# 5 次 marshal。返回值：
#   { ok: bool, fronts: Array[WeatherFront], breakdown: Dictionary, fail_stage: String }
# ok=false 时 caller 必须走 GDScript fallback（refresh_daily_stage_a +
# refresh_daily_stage_b）。fail_stage 用于诊断（"precondition" / "field_solve" /
# "distribute" / "summary" / "stage_b" / "rc"）。
#
# 前置条件：
#   - host._data_core_world_ext 已绑定且 has_method("run_weather_refresh_daily_pass")#   - _data_core_world_ext 已绑定且 has_method("run_weather_refresh_daily_pass")
#   - 由 map_generator.refresh_weather_daily() 间接保证
#
# 副作用（成功路径）：
#   - 推进 host._day_counter / host._field_solve_tick（等价于 host.tick_one_day 的 day-bump）#   - 推进 _day_counter / _field_solve_tick（等价于 tick_one_day 的 day-bump）
#   - 写入 SoA 8 字段（cpp 端 field_solve 直写）
#   - 写入 host._active_fronts = fronts_cpp（替代 commit() 末段）#   - 写入 _active_fronts = fronts_cpp（替代 commit() 末段）
#   - 同步 host.ocean_current_perturbation（cpp 端 cyclone_wake 维护）#   - 同步 ocean_current_perturbation（cpp 端 cyclone_wake 维护）
#   - 写入 host._last_breakdown（advance/distribute/summary/cyclone/stage_b 子段 ms）#   - 写入 _last_breakdown（advance/distribute/summary/cyclone/stage_b 子段 ms）
#   - distribute 写回的 acc_snow / pre_snow_cover 由 caller 在拿到 fronts 后
#     按需同步（与 host._try_run_weather_distribute_gdext 行为一致）；本函数不#     按需同步（与 _try_run_weather_distribute_gdext 行为一致）；本函数不
#     做 cell-level 反向写入，避免重复 hot loop。
