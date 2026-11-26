extends RefCounted

const NativeField = preload("res://scripts/weather/native_weather_field_bridge.gd")
const NativeComparison = preload("res://scripts/weather/native_weather_comparison.gd")
const NativeSummary = preload("res://scripts/weather/native_weather_summary_bridge.gd")


func _sync_profile_weather_knobs(host, cp: Resource) -> void:
	NativeField._sync_profile_weather_knobs(host, cp)

func _transition_enabled(host) -> Dictionary:
	return NativeField._transition_enabled(host)

func _build_weather_field_knobs(host, map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> Dictionary:
	return NativeField._build_weather_field_knobs(host, map, world, n_cells, start_idx, end_idx)

func _try_run_weather_field_solve_gdext(host, map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> float:
	return NativeField._try_run_weather_field_solve_gdext(host, map, world, n_cells, start_idx, end_idx)

func _try_run_weather_field_commit_gdext(host, map: MapData, n_cells: int) -> Dictionary:
	return NativeField._try_run_weather_field_commit_gdext(host, map, n_cells)


func _validate_weather_distribute_signature(host, ext: RefCounted) -> bool:
	if ext == null:
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_distribute_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_distribute_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_debug dev_build=no -j8'." % args.size())
			return false
	return false


func _validate_weather_summary_signature(host, ext: RefCounted) -> bool:
	if ext == null:
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_summary_fronts_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_summary_fronts_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_debug dev_build=no -j8'." % args.size())
			return false
	return false


func _build_weather_distribute_knobs(host, map: MapData, n_cells: int) -> Dictionary:
	# 标量入参（snow / flood 阈值与 GDScript 版严格同源；任务 4 在 C++ 内消费）。
	# SoA view 由 C++ 端通过 ext._map_data + 已绑定 schema 直接拿，无需 GDScript
	# 显式传 PackedArray（与 F.1 一致）。
	#
	# 例外（无 SoA 镜像的 AoS 字段）：
	#   - accumulated_snow_days：HexCell.int 字段，没在 component_schema 里。
	#   - pre_snow_cover：HexCell.int 字段，同上。
	# 这两个字段每帧打包成 PackedInt32Array 传入；C++ 写完后通过 CoW alias 透回。
	#
	# WeatherType / LandformType 静态查询：profile lookup 是 Resource access，
	# C++ 拿不到。打包成 8-element PackedArray 按 WT 索引，C++ 内部 O(1) 查表。
	var map_id: int = map.get_instance_id()
	if host._dist_cache_map_id != map_id or host._dist_cache_n != n_cells \
			or host._dist_acc_snow_cache.size() != n_cells or host._dist_pre_cover_cache.size() != n_cells:
		var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		host._dist_acc_snow_cache = PackedInt32Array()
		host._dist_pre_cover_cache = PackedInt32Array()
		host._dist_acc_snow_cache.resize(n_cells)
		host._dist_pre_cover_cache.resize(n_cells)
		for i in range(n_cells):
			var c: HexCell = cells[i]
			host._dist_acc_snow_cache[i] = c.accumulated_snow_days
			host._dist_pre_cover_cache[i] = c.pre_snow_cover
		host._dist_cache_map_id = map_id
		host._dist_cache_n = n_cells
	# 8 个 WT 的 profile 静态值（temp_delta / moisture_delta / can_form_snow /
	# can_form_flood）按 WT 索引。WT 枚举值 0..7（CLEAR..MONSOON）。
	var temp_d: PackedFloat32Array = PackedFloat32Array()
	var moist_d: PackedFloat32Array = PackedFloat32Array()
	var cfs: PackedByteArray = PackedByteArray()
	var cff: PackedByteArray = PackedByteArray()
	temp_d.resize(8)
	moist_d.resize(8)
	cfs.resize(8)
	cff.resize(8)
	for w in range(8):
		temp_d[w] = WeatherType.temp_delta(w)
		moist_d[w] = WeatherType.moisture_delta(w)
		cfs[w] = 1 if WeatherType.can_form_snow(w) else 0
		cff[w] = 1 if WeatherType.can_form_flood(w) else 0
	# ─── Phase A.3 fast path：从 KnobsHandle 拿 distribute 段缓存 Dict ──
	if host._knobs_handle != null and host._knobs_handle.has_method("to_distribute_knobs_dict"):
		# 标量段与 LUT 由 host._push_resident_knobs_from_cp 在 changed signal 时已推送；# 标量段与 LUT 由 _push_resident_knobs_from_cp 在 changed signal 时已推送；
		# 这里仅 merge 动态字段（n_cells / SoA AoS cache）。
		var dynamic_fields_dist: Dictionary = {
			"n_cells": n_cells,
			"accumulated_snow_days": host._dist_acc_snow_cache,
			"pre_snow_cover": host._dist_pre_cover_cache,
			"snowpack_accum_gain": host._snowpack_accum_gain,
			"snowpack_melt_temp_gain": host._snowpack_melt_temp_gain,
			"snowpack_melt_sun_gain": host._snowpack_melt_sun_gain,
			"snowpack_cover_low": host._snowpack_cover_low,
			"snowpack_cover_full": host._snowpack_cover_full,
			"weather_temp_anomaly_cap": host._weather_temp_anomaly_cap,
			"weather_direct_moisture_enabled": host._weather_direct_moisture_enabled,
			"snowline_temp_threshold": host._snowline_temp_threshold,
			"snowline_band": host._snowline_band,
		}
		return host._merge_resident_knobs_with_dynamic(
			host._knobs_handle.to_distribute_knobs_dict(), dynamic_fields_dist)
	return {
		"n_cells": n_cells,
		# host._apply_snow_accumulation 用到的 cover/温度阈值（任务 4 中 C++ 复刻 GDScript# _apply_snow_accumulation 用到的 cover/温度阈值（任务 4 中 C++ 复刻 GDScript
		# 同名函数；任意改动需保持双侧同步）。
		# 2026-05-18 雪线修正：GDScript 在 host._apply_snow_accumulation 内做 elev 偏移；# 2026-05-18 雪线修正：GDScript 在 _apply_snow_accumulation 内做 elev 偏移；
		# C++ 端 run_weather_distribute_pass 已同步实现（gdext/src/world_ext.cpp，
		# host.SNOW_ELEV_NEUTRAL=0.30 / FREEZE_GAIN=0.20 / MELT_GAIN=0.30，常数硬编码不走 knobs）。# SNOW_ELEV_NEUTRAL=0.30 / FREEZE_GAIN=0.20 / MELT_GAIN=0.30，常数硬编码不走 knobs）。
		# 若日后调参，需双侧同步修改。
		"snow_min_intensity": 0.001,
		"snow_freeze_t": host.SNOW_FREEZE_T,
		"snow_melt_t": host.SNOW_MELT_T,
		"snow_intensity_for_snowing": 0.4,
		"snow_accum_days_req": host._snow_accum_days_req,
		"flood_heavy_intensity": 0.55,
		"flood_heavy_precip": 0.55,
		"flood_lowland_intensity": 0.32,
		"flood_lowland_elev": 0.50,
		"flood_lowland_moisture": 0.60,
		"snowpack_accum_gain": host._snowpack_accum_gain,
		"snowpack_melt_temp_gain": host._snowpack_melt_temp_gain,
		"snowpack_melt_sun_gain": host._snowpack_melt_sun_gain,
		"snowpack_cover_low": host._snowpack_cover_low,
		"snowpack_cover_full": host._snowpack_cover_full,
		"weather_temp_anomaly_cap": host._weather_temp_anomaly_cap,
		"weather_direct_moisture_enabled": host._weather_direct_moisture_enabled,
		"snowline_temp_threshold": host._snowline_temp_threshold,
		"snowline_band": host._snowline_band,
		# WT.CLEAR / SNOW / NONE / FLOODING 的 enum 值。GDScript 端用 Type.WT
		# / Type.CV，C++ 不能直接引用，所以把数值传进去。
		"wt_clear": int(WeatherType.WT.CLEAR),
		"cv_snow": int(CoverType.CV.SNOW),
		"cv_none": int(CoverType.CV.NONE),
		"cv_flooding": int(CoverType.CV.FLOODING),
		# AoS 字段 PackedArray（CoW shared via Dictionary 持有）。C++ 直接 ptrw 写回，
		# GDScript 在 try 函数末尾用同样的 Packed 引用 lookup 写回 AoS。
		"accumulated_snow_days": host._dist_acc_snow_cache,
		"pre_snow_cover": host._dist_pre_cover_cache,
		# WeatherType 静态查询表（PackedArray 按 WT 索引，C++ 内部 O(1)）。
		"temp_delta_arr": temp_d,
		"moisture_delta_arr": moist_d,
		"can_form_snow_arr": cfs,
		"can_form_flood_arr": cff,
	}

# ACTIVE climate authority：worker 侧 weather field stage 的 knobs 入口。
#
# 与 distribute 那个包装不同，field knobs 拿不到就建不出来：host._build_weather_field_knobs# 与 distribute 那个包装不同，field knobs 拿不到就建不出来：_build_weather_field_knobs
# 读的是 host._field_solver._field_slice_*，而那套 slice state 由 host.begin_weather_field_solve# 读的是 _field_solver._field_slice_*，而那套 slice state 由 begin_weather_field_solve
# 建立。所以这里必须真的 begin 一次，取完 knobs 立刻 clear —— 权威下生产的 weather
# 段是被抑制的，没有 host.apply_unified_fast_tick_result 会来收尾，留着就是一份每天新建# 段是被抑制的，没有 apply_unified_fast_tick_result 会来收尾，留着就是一份每天新建
# 却永不消费的悬挂 state。
#
# 返回的 PackedArray 是 CoW 值语义，clear 不会动它们，worker 拿到的那份仍然有效。

func _try_run_weather_distribute_gdext(host, map: MapData, n_cells: int) -> Dictionary:
	if host._data_core_world_ext == null:
		return { "elapsed_ms": -1.0, "cover_dirty": false }
	var knobs: Dictionary = host._build_weather_distribute_knobs(map, n_cells)
	var rc_dict: Dictionary = host._data_core_world_ext.run_weather_distribute_pass(knobs)
	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0:
		host._sync_weather_distribute_cache_to_cells(map, n_cells)
		if not host._gdext_dist_warned_fallback:
			host._gdext_dist_warned_fallback = true
			push_warning("[weather] gdext run_weather_distribute_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
		return rc_dict
	# C++ 已通过 PackedArray ptrw 把 acc_snow_days / pre_snow_cover 改写完成（CoW
	# alias 透传）。fast path 以 PackedArray 为连续状态源，不再每 tick 全量写回
	# HexCell；只有 cover 真正变化的 cell 需要同步 current_state。verify/fallback
	# 路径仍会全量同步，保证调试和降级语义一致。
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var acc_after: PackedInt32Array = knobs.get("accumulated_snow_days", PackedInt32Array())
	var pre_after: PackedInt32Array = knobs.get("pre_snow_cover", PackedInt32Array())
	var changed: PackedInt32Array = rc_dict.get("changed_cells", PackedInt32Array())
	if host._distribute_verify_enabled:
		host._sync_weather_distribute_cache_to_cells(map, n_cells)
	else:
		for ci in changed:
			if ci < 0 or ci >= cells.size():
				continue
			var cc: HexCell = cells[ci]
			if acc_after.size() == n_cells and pre_after.size() == n_cells:
				cc.accumulated_snow_days = acc_after[ci]
				cc.pre_snow_cover = pre_after[ci]
			# C++ 已经写好 cover_arr (SoA)；HexCell facade reader cell.cover 应当透读 SoA。
			# 但 current_state["cover"] 是 dict 字段，需手动同步。
			cc.current_state["cover"] = int(cc.cover)
	return rc_dict


func _build_weather_summary_knobs(host, map: MapData, world: WorldData) -> Dictionary:
	return NativeSummary._build_weather_summary_knobs(host, map, world)

func _unpack_summary_dict_to_front(host, d: Dictionary) -> WeatherFront:
	return NativeSummary._unpack_summary_dict_to_front(host, d)

func _unpack_summary_soa_to_fronts(host, soa: Dictionary) -> Variant:
	return NativeSummary._unpack_summary_soa_to_fronts(host, soa)

func _build_fronts_from_rc(host, rc_dict: Dictionary) -> Array[WeatherFront]:
	return NativeSummary._build_fronts_from_rc(host, rc_dict)

func _try_run_weather_summary_fronts_gdext(host, map: MapData, world: WorldData) -> Variant:
	return NativeSummary._try_run_weather_summary_fronts_gdext(host, map, world)


func try_run_refresh_daily_combined_gdext(host, map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float = -1.0,
		stage_b_knobs: Dictionary = {}) -> Dictionary:
	var ret: Dictionary = {
		"ok": false,
		"fronts": [] as Array[WeatherFront],
		"breakdown": {},
		"fail_stage": "precondition",
	}
	if host._data_core_world_ext == null:
		return ret
	if map == null or world == null:
		return ret
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return ret

	var t_us0: int = Time.get_ticks_usec()

	# Step 1：初始化 field slice state（替代 host.tick_one_day 入口的 day-bump +# Step 1：初始化 field slice state（替代 tick_one_day 入口的 day-bump +
	# wind_fn 设置；count_day=true，与 host.tick_one_day 语义一致）。# wind_fn 设置；count_day=true，与 tick_one_day 语义一致）。
	host._current_map_for_tick = map
	host.begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase, true)
	# fast-indexed 是 cpp 5 段的硬前置条件（field_solve / distribute /
	# summary / feedback 都要 neighbor_indices_packed 完整）。任意一段缺失
	# 立即放弃，让 caller 走 GDScript fallback 而不是付出半 cpp 半 GDScript 代价。
	if not host._field_solver._field_slice_fast_indexed:
		host._clear_weather_field_slice_state()
		ret["fail_stage"] = "fast_indexed_missing"
		return ret

	# Step 2：合并 4 组 knobs。各 builder 已存在且严格按 cpp 端 5 段所需 key
	# 集合产出。super-knobs 用 merge() 合到一个 Dictionary 单次跨界传递。
	# stage_b 的 knobs 由 generator 提供（builder 在 generator 那边，
	# weather_system 拿不到 cp/lut；caller 必须传入）。
	var super_knobs: Dictionary = host._build_weather_field_knobs(map, world, n_cells)
	var dist_knobs: Dictionary = host._build_weather_distribute_knobs(map, n_cells)
	for k in dist_knobs.keys():
		super_knobs[k] = dist_knobs[k]
	var summary_knobs: Dictionary = host._build_weather_summary_knobs(map, world)
	for k in summary_knobs.keys():
		super_knobs[k] = summary_knobs[k]
	# stage_b 的 5 段 knobs 由 caller（map_generator.refresh_weather_daily facade）
	# 通过 stage_b_knobs 参数注入——builder 在 generator 那边（依赖 cp/lut），
	# weather_system 拿不到。如果 caller 传空 dict（例如还在试运行阶段），那么
	# cpp 端会跳过 stage_b 段（stage_b_pass 内部检查 run_albedo/veg_dyn/feedback
	# 三个 flag 全 false 时直接 return rc=0），这是允许的过渡状态。
	# 注意：把 stage_b_knobs 的所有 key 平铺到 super_knobs 顶层，与 cpp 端
	# run_weather_refresh_daily_pass 解 stage_b 段时按 top-level key 取值的约定一致。
	if not stage_b_knobs.is_empty():
		for k in stage_b_knobs.keys():
			# 不允许 stage_b key 覆盖 weather field/distribute/summary 已写好的同名
			# key（例如 n_cells / neighbor_indices）——后者是真值，stage_b 端的
			# n_cells / neighbor_indices 与 weather 段必然一致，但为安全起见
			# 用 has() 做防御。
			if not super_knobs.has(k):
				super_knobs[k] = stage_b_knobs[k]

	# Step 3：单次 cpp call。
	var rc_dict: Dictionary = host._data_core_world_ext.run_weather_refresh_daily_pass(super_knobs)
	var rc_int: int = int(rc_dict.get("rc", -1))
	if rc_int != 0:
		# cpp 端任一段失败 → 清理 slice state，让 caller 走 GDScript fallback。
		host._clear_weather_field_slice_state()
		ret["fail_stage"] = String(rc_dict.get("fail_stage", "rc"))
		ret["breakdown"] = {
			"total_ms": float(rc_dict.get("total_ms", 0.0)),
		}
		if not host._gdext_combined_warned_fallback:
			host._gdext_combined_warned_fallback = true
			push_warning("[weather/combined] run_weather_refresh_daily_pass rc=%d fail_stage=%s; falling back to GDScript chain" % [rc_int, ret["fail_stage"]])
		return ret

	# Step 4：解包 fronts，写 host._active_fronts（替代 commit() summary 段 +# Step 4：解包 fronts，写 _active_fronts（替代 commit() summary 段 +
	# host.tick_one_day 末端 host._active_fronts 写入）。# tick_one_day 末端 _active_fronts 写入）。
	# Phase A.1: SoA 优先 + Dict fallback（与 host._try_run_weather_summary_fronts_gdext# Phase A.1: SoA 优先 + Dict fallback（与 _try_run_weather_summary_fronts_gdext
	# 共享 host._build_fronts_from_rc helper，single source of truth）。# 共享 _build_fronts_from_rc helper，single source of truth）。
	var fronts_out: Array[WeatherFront] = host._build_fronts_from_rc(rc_dict)
	host._active_fronts = fronts_out

	# Step 5：cover_dirty 同步（distribute 段输出）。
	host._cover_dirty = bool(rc_dict.get("cover_dirty", false)) or host._cover_dirty

	# Step 6：cyclone_wake 镜像（cpp 端维护 _cyclone_perturbations 内部
	# vector，GDScript 端 host.ocean_current_perturbation 用于航运 AI 直读）。# vector，GDScript 端 ocean_current_perturbation 用于航运 AI 直读）。
	var cyclone_mirror: Dictionary = host._data_core_world_ext.get_cyclone_perturbations_dict()
	# 替换式同步而非 merge：cpp 是 source of truth（已经做了衰减 + 注入）。
	host.ocean_current_perturbation = cyclone_mirror

	# Step 7：清理 slice state（cpp 已直写 SoA，_field_slice_* buffer 不再需要）。
	host._clear_weather_field_slice_state()
	host._current_map_for_tick = null

	# Step 8：拼装 host._last_breakdown（与 GDScript path 字段集合保持一致）。# Step 8：拼装 _last_breakdown（与 GDScript path 字段集合保持一致）。
	var combined_total_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	var br: Dictionary = {
		"advance_ms": float(rc_dict.get("advance_ms", 0.0)),
		"distribute_ms": float(rc_dict.get("distribute_ms", 0.0)),
		"summary_ms": float(rc_dict.get("summary_ms", 0.0)),
		"cyclone_ms": float(rc_dict.get("cyclone_ms", 0.0)),
		# Phase B.2 cyclone 细粒度遥测（C++ cyclone_wake_step by-ref 写回 6 字段
		# + caller 写回 cyclone_pool_size，map_generator._dump_weather_breakdown_if_slow
		# 触发时立即定位是衰减循环 vs 注入循环、是大量 evict vs 大量 replace）
		"cyclone_phase1_decay_ms": float(rc_dict.get("cyclone_phase1_decay_ms", 0.0)),
		"cyclone_phase2_inject_ms": float(rc_dict.get("cyclone_phase2_inject_ms", 0.0)),
		"cyclone_n_decayed": int(rc_dict.get("cyclone_n_decayed", 0)),
		"cyclone_n_evicted": int(rc_dict.get("cyclone_n_evicted", 0)),
		"cyclone_n_replaced": int(rc_dict.get("cyclone_n_replaced", 0)),
		"cyclone_n_injected": int(rc_dict.get("cyclone_n_injected", 0)),
		"cyclone_pool_size": int(rc_dict.get("cyclone_pool_size", 0)),
		"stage_b_ms": float(rc_dict.get("stage_b_ms", 0.0)),
		"albedo_ms": float(rc_dict.get("albedo_ms", 0.0)),
		"veg_dyn_ms": float(rc_dict.get("veg_dyn_ms", 0.0)),
		"feedback_ms": float(rc_dict.get("feedback_ms", 0.0)),
		"weather_tick_ms": float(rc_dict.get("weather_tick_ms", combined_total_ms)),
		"total_ms": combined_total_ms,
		"fronts": fronts_out.size(),
		"path": "gdext_combined",
	}
	br.merge(host._front_diagnostic_counts(fronts_out), true)
	# stage_b succession 写回（与 _build_native_daily_stage_b_knobs 等价）
	if rc_dict.has("succession_indices"):
		br["succession_indices"] = rc_dict["succession_indices"]
		br["succession_to_veg"] = rc_dict["succession_to_veg"]
		br["stat_succession_count"] = int(rc_dict.get("stat_succession_count", 0))
	br.merge(host._mark_weather_commit_tick(), true)
	host._last_breakdown = br

	# 节流告警（仅首次）：标记 gdext_combined ACTIVE。
	host._gdext_combined_runs += 1
	host._gdext_combined_total_ms += combined_total_ms
	if host._gdext_combined_runs == 1:
		print("[weather/combined] gdext path ACTIVE — first run elapsed=%.2fms (target ≤ 1.5ms; legacy stage_a+stage_b chain ≈ 1.0-1.2ms baseline + 3 marshal overhead)" % combined_total_ms)

	ret["ok"] = true
	ret["fronts"] = fronts_out
	ret["breakdown"] = br
	ret["fail_stage"] = ""
	return ret


# ─── Phase A.2 unified fast tick：weather_knobs 嵌入 native_daily_bundle ─────
# 当 native_daily_sim_mode=ACTIVE 时（unified_fast_tick 路径现恒走），由
# map_generator._build_native_daily_bundle 调用本 helper 构造平铺 weather super_knobs，
# 由 run_native_daily_tick 内部的 bundle["weather_knobs"] 分支自动转调
# run_weather_refresh_daily_pass，省去 weather_refresh_job 独立的一次跨界。
#
# 与 host.try_run_refresh_daily_combined_gdext step 1-2 同源逻辑（field_slice state# 与 try_run_refresh_daily_combined_gdext step 1-2 同源逻辑（field_slice state
# 初始化 + 3 组 weather knobs builder + 顶层平铺 stage_b knobs）。失败时返回
# 空 dict，caller 据此跳过 weather_knobs 嵌入退回 stage_b-only bundle。
#
# 副作用（成功路径）：
#   - 推进 host._day_counter（与 host.tick_one_day 语义一致，count_day=true）#   - 推进 _day_counter（与 tick_one_day 语义一致，count_day=true）
#   - 初始化 host._field_solver._field_slice_* state（_field_slice_fast_indexed 必须为 true）#   - 初始化 _field_solver._field_slice_* state（_field_slice_fast_indexed 必须为 true）
#   - 设置 host._current_map_for_tick = map#   - 设置 _current_map_for_tick = map
# 这些状态会在 host.apply_unified_fast_tick_result 内被 host._clear_weather_field_slice_state 清理。# 这些状态会在 apply_unified_fast_tick_result 内被 _clear_weather_field_slice_state 清理。

func build_unified_fast_tick_weather_knobs(host, map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float,
		stage_b_knobs: Dictionary) -> Dictionary:
	if host._data_core_world_ext == null:
		return {}
	if map == null or world == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}

	# Step 1：初始化 field slice state（与 host.try_run_refresh_daily_combined_gdext line 1361 同源）。# Step 1：初始化 field slice state（与 try_run_refresh_daily_combined_gdext line 1361 同源）。
	host._current_map_for_tick = map
	host.begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase, true)
	if not host._field_solver._field_slice_fast_indexed:
		# fast-indexed 是 cpp 5 段的硬前置；缺失 → 清理 + 让 caller fallback 不嵌入 weather_knobs。
		host._clear_weather_field_slice_state()
		host._current_map_for_tick = null
		return {}

	# Step 2：合并 4 组 knobs（与 line 1374-1395 同源）。
	var super_knobs: Dictionary = host._build_weather_field_knobs(map, world, n_cells)
	var dist_knobs: Dictionary = host._build_weather_distribute_knobs(map, n_cells)
	for k in dist_knobs.keys():
		super_knobs[k] = dist_knobs[k]
	var summary_knobs: Dictionary = host._build_weather_summary_knobs(map, world)
	for k in summary_knobs.keys():
		super_knobs[k] = summary_knobs[k]
	if not stage_b_knobs.is_empty():
		for k in stage_b_knobs.keys():
			if not super_knobs.has(k):
				super_knobs[k] = stage_b_knobs[k]
	# weather_lut_w/h：合并 native-daily 路径里 C++ 的 field commit pass
	# (run_weather_field_commit_pass) 用这两项把 weather LUT 字节按 lut_w*lut_h 编码。
	# 缺失时 C++ 退回 n_cells 个 slot，产出的字节数与发布纹理 (world.lut_dims) 不符，
	# 导致 publish_weather_lut_bytes_from_native 因 size 不匹配整段拒收 → 云/雨雪 LUT
	# 永远停在世界生成时的全晴初始 bake（全 0），天气视觉全部消失。
	# 与切片路径 host._try_run_weather_field_commit_gdext 同源补齐。# 与切片路径 _try_run_weather_field_commit_gdext 同源补齐。
	if world != null and world.lut_dims.x > 0 and world.lut_dims.y > 0:
		super_knobs["weather_lut_w"] = int(world.lut_dims.x)
		super_knobs["weather_lut_h"] = int(world.lut_dims.y)
	return super_knobs


# 与 host.try_run_refresh_daily_combined_gdext step 4-8 同源：从 native_daily 返回的# 与 try_run_refresh_daily_combined_gdext step 4-8 同源：从 native_daily 返回的
# breakdown 字典里取 weather 段子字典（C++ 端 run_native_daily_tick 把 weather
# 段产出 copy_dict_into 进顶层 breakdown），解 fronts、同步 host._active_fronts、# 段产出 copy_dict_into 进顶层 breakdown），解 fronts、同步 _active_fronts、
# cyclone mirror、cover_dirty，清理 slice state。
#
# 入参 weather_rc：bundle.weather_knobs 触发的 run_weather_refresh_daily_pass
# 返回 dict，由 native_daily breakdown 透传上来。
#
# 返回 fronts_out：与 host.try_run_refresh_daily_combined_gdext 一致的 Array[WeatherFront]，# 返回 fronts_out：与 try_run_refresh_daily_combined_gdext 一致的 Array[WeatherFront]，
# 由 caller（map_generator）写入 _last_active_fronts / _weather_round_fronts。

func apply_unified_fast_tick_result(host, weather_rc: Dictionary) -> Array[WeatherFront]:
	if host._data_core_world_ext == null:
		host._clear_weather_field_slice_state()
		host._current_map_for_tick = null
		return [] as Array[WeatherFront]
	var t_us0: int = Time.get_ticks_usec()

	# Step 4：解包 fronts，写 host._active_fronts。# Step 4：解包 fronts，写 _active_fronts。
	var fronts_out: Array[WeatherFront] = host._build_fronts_from_rc(weather_rc)
	host._active_fronts = fronts_out

	# Step 5：cover_dirty 同步。
	host._cover_dirty = bool(weather_rc.get("cover_dirty", false)) or host._cover_dirty

	# Step 6：cyclone_wake 镜像。
	var cyclone_mirror: Dictionary = host._data_core_world_ext.get_cyclone_perturbations_dict()
	host.ocean_current_perturbation = cyclone_mirror

	# Step 7：清理 slice state。
	host._clear_weather_field_slice_state()
	host._current_map_for_tick = null

	# Step 8：runs/total_ms 统计（与 combined path 共享计数器）。
	host._gdext_combined_runs += 1
	host._gdext_combined_total_ms += float(weather_rc.get("total_ms", 0.0))
	# Native daily breakdown may contain large PackedArrays and nested reports; keep the
	# weather-facing snapshot scalar-only except for the explicit fields consumers need.
	var br: Dictionary = {
		"advance_ms": float(weather_rc.get("advance_ms", weather_rc.get("weather_field_ms", 0.0))),
		"field_commit_total_ms": float(weather_rc.get("field_commit_total_ms", weather_rc.get("weather_commit_ms", 0.0))),
		"field_commit_loop_ms": float(weather_rc.get("field_commit_loop_ms", 0.0)),
		"distribute_ms": float(weather_rc.get("distribute_ms", weather_rc.get("weather_distribute_ms", 0.0))),
		"summary_ms": float(weather_rc.get("summary_ms", weather_rc.get("weather_summary_ms", 0.0))),
		"cyclone_ms": float(weather_rc.get("cyclone_ms", weather_rc.get("weather_cyclone_ms", 0.0))),
		"stage_b_ms": float(weather_rc.get("stage_b_ms", weather_rc.get("weather_stage_b_ms", 0.0))),
		"weather_field_ms": float(weather_rc.get("weather_field_ms", weather_rc.get("advance_ms", 0.0))),
		"weather_commit_ms": float(weather_rc.get("weather_commit_ms", weather_rc.get("field_commit_total_ms", 0.0))),
		"weather_distribute_ms": float(weather_rc.get("weather_distribute_ms", weather_rc.get("distribute_ms", 0.0))),
		"weather_summary_ms": float(weather_rc.get("weather_summary_ms", weather_rc.get("summary_ms", 0.0))),
		"weather_cyclone_ms": float(weather_rc.get("weather_cyclone_ms", weather_rc.get("cyclone_ms", 0.0))),
		"weather_stage_b_ms": float(weather_rc.get("weather_stage_b_ms", 0.0)),
		"albedo_ms": float(weather_rc.get("albedo_ms", 0.0)),
		"veg_dyn_ms": float(weather_rc.get("veg_dyn_ms", 0.0)),
		"feedback_ms": float(weather_rc.get("feedback_ms", 0.0)),
		"weather_tick_ms": float(weather_rc.get("weather_tick_ms", weather_rc.get("weather_ms", weather_rc.get("total_ms", 0.0)))),
		"total_ms": float(weather_rc.get("total_ms", weather_rc.get("weather_ms", 0.0))),
		"fronts": fronts_out.size(),
		"fronts_count": int(weather_rc.get("fronts_count", fronts_out.size())),
		"cover_dirty": bool(weather_rc.get("cover_dirty", false)),
		"active_weather_ratio": float(weather_rc.get("active_weather_ratio", 0.0)),
		"weather_dirty_count": int(weather_rc.get("weather_dirty_count", 0)),
		"weather_lut_changed": bool(weather_rc.get("weather_lut_changed", false)),
		"weather_lut_dirty_count": int(weather_rc.get("weather_lut_dirty_count", 0)),
		"weather_lut_full_rebuild": bool(weather_rc.get("weather_lut_full_rebuild", false)),
		"weather_convergence_dirty_count": int(weather_rc.get("weather_convergence_dirty_count", 0)),
		"path": "gdext_native_daily_apply",
	}
	if weather_rc.has("fronts_signature"):
		br["fronts_signature"] = str(weather_rc.get("fronts_signature", ""))
	if weather_rc.has("visual_dirty_intents"):
		br["visual_dirty_intents"] = weather_rc["visual_dirty_intents"]
	if weather_rc.has("succession_indices"):
		br["succession_indices"] = weather_rc["succession_indices"]
		br["succession_to_veg"] = weather_rc.get("succession_to_veg", PackedByteArray())
		br["stat_succession_count"] = int(weather_rc.get("stat_succession_count", 0))
	br.merge(host._front_diagnostic_counts(fronts_out), true)
	br.merge(host._mark_weather_commit_tick(), true)
	br["result_apply_ms"] = float(Time.get_ticks_usec() - t_us0) / 1000.0
	host._last_breakdown = br
	return fronts_out


# C++ 完成后 SoA 已经写好，把 8 个数组的内容按 i 拷回 host._field_solver._field_slice_next_*# C++ 完成后 SoA 已经写好，把 8 个数组的内容按 i 拷回 _field_solver._field_slice_next_*
# 让 host.commit_weather_field_solve() 用同样的 GDScript 数据流 commit 回 cells +# 让 commit_weather_field_solve() 用同样的 GDScript 数据流 commit 回 cells +
# fronts 等下游 sub-system，无需感知 C++ 路径的存在。

func _pull_gdext_field_results_to_next(host, map: MapData, n_cells: int) -> void:
	NativeComparison._pull_gdext_field_results_to_next(host, map, n_cells)

func _verify_gdext_field_against_gdscript(host, map: MapData, world: WorldData, n_cells: int) -> void:
	NativeComparison._verify_gdext_field_against_gdscript(host, map, world, n_cells)

func _verify_gdext_distribute_against_gdscript(host, map: MapData, n_cells: int, cpp_rc: Dictionary) -> void:
	NativeComparison._verify_gdext_distribute_against_gdscript(host, map, n_cells, cpp_rc)

func _verify_gdext_summary_against_gdscript(host, map: MapData, world: WorldData,
		fronts_cpp: Array[WeatherFront]) -> void:
	NativeComparison._verify_gdext_summary_against_gdscript(host, map, world, fronts_cpp)
