extends RefCounted

## Applies native weather configuration and verifies the corresponding extension interfaces.

static func _sync_profile_weather_knobs(weather: WeatherSystem, cp: Resource) -> void:

	if weather._native_bridge == null:
		weather._native_bridge = weather.DCWeatherNativeBridge.new()
	weather._native_bridge._sync_profile_weather_knobs(weather, cp)


static func _push_resident_knobs_from_cp(weather: WeatherSystem, cp: Resource) -> void:
	if weather._knobs_handle == null or cp == null:
		return
	weather._sync_profile_weather_knobs(cp)

	# ─── field 段标量 ──
	if weather._knobs_handle.has_method("set_field_scalars"):
		weather._knobs_handle.set_field_scalars(
			weather._world_bounds.position.y,
			weather._world_bounds.size.y,
			not weather._field_verify_enabled,  # apply_convergence_boost = (not verify_mode)
			weather._hex_size,
			weather._field_advect_steps,
			weather._field_diffusion,
			weather._field_condensation_gain,
			weather._field_orographic_lift_gain,
			weather._field_convergence_gain,
			weather._field_ocean_evap_gain,
			weather._field_precip_decay,
			weather._season_phase,
		)
	var field_extra_scalars_available: bool = weather._knobs_handle.has_method("set_field_precip_stability_scalars")
	if field_extra_scalars_available:
		weather._knobs_handle.set_field_precip_stability_scalars(
			weather._field_precip_carryover_max,
			weather._field_vapor_precip_sink,
			weather._field_vapor_relax_rate,
			weather._field_orographic_lift_cap,
			weather._field_wet_terrain_precip_damping,
			weather._field_lake_precip_damping,
			weather._field_lake_evap_scale,
			weather._field_extreme_precip_soft_cap,
			weather._field_extreme_precip_softness,
		)

	# ─── distribute 段标量（snow/flood 阈值与 _build_weather_distribute_knobs 严格同源）──
	if weather._knobs_handle.has_method("set_distribute_scalars"):
		weather._knobs_handle.set_distribute_scalars(
			0.001,    # snow_min_intensity
			weather.SNOW_FREEZE_T,
			weather.SNOW_MELT_T,
			0.4,      # snow_intensity_for_snowing
			weather._snow_accum_days_req,
			0.55,     # flood_heavy_intensity
			0.55,     # flood_heavy_precip
			0.32,     # flood_lowland_intensity
			0.50,     # flood_lowland_elev
			0.60,     # flood_lowland_moisture
			int(WeatherType.WT.CLEAR),
			int(CoverType.CV.SNOW),
			int(CoverType.CV.NONE),
			int(CoverType.CV.FLOODING),
		)
	# distribute WT LUT（8-长度）—— 每次重建（cp.WeatherType 静态表理论上不会变，
	# 但 push 全路径覆盖一次更稳）
	if weather._knobs_handle.has_method("set_distribute_wt_tables"):
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
		weather._knobs_handle.set_distribute_wt_tables(temp_d, moist_d, cfs, cff)

	# ─── summary 段标量 ──
	if weather._knobs_handle.has_method("set_summary_scalars"):
		weather._knobs_handle.set_summary_scalars(
			weather._field_summary_limit,
			0.10,   # intensity_enter
			0.06,   # intensity_hold
			0.65,   # merge_ratio
			4,      # merge_max_rounds
			1.6,    # radius_base
			1.05,   # radius_scale
			false,  # drift_debug_log
			weather._day_counter,
		)


# ClimateProfile.changed 信号回调：段级 invalidate + 重新推送。
# cp 通过 .bind(cp) 透传到这里（Resource.changed 信号自身不带 sender 参数）。


static func _on_climate_profile_changed_for_knobs(weather: WeatherSystem, cp: Resource) -> void:
	if weather._knobs_handle == null:
		return
	if weather._knobs_handle.has_method("invalidate_all"):
		weather._knobs_handle.invalidate_all()
	weather._push_resident_knobs_from_cp(cp)


# 把 to_*_knobs_dict 缓存 Dict 与每帧动态字段（PackedArray ref / cache）合并。
# 用于 _build_weather_field_knobs / _build_weather_distribute_knobs /
# _build_weather_summary_knobs 三个 hot path 的 fast path。
#
# 实现要点：to_*_knobs_dict 返回的 Dict 是缓存 Dict 的 CoW 引用，duplicate(false)
# 浅拷贝出一份后 merge 动态字段（不污染缓存 Dict）。duplicate(false) 在 standard
# Godot Dictionary 是 O(N_keys)，N≤30 标量段约 0.01ms 量级，比标量段重建省一个量级。


static func _merge_resident_knobs_with_dynamic(weather: WeatherSystem, base_dict: Dictionary, dynamic_fields: Dictionary) -> Dictionary:
	if base_dict.is_empty():
		# KnobsHandle 拿不到缓存（首次或 invalidate 后），caller 应已 fallback 旧路径
		return dynamic_fields
	var out: Dictionary = base_dict.duplicate(false)
	for k in dynamic_fields:
		out[k] = dynamic_fields[k]
	if not weather._knobs_handle_first_use_logged:
		weather._knobs_handle_first_use_logged = true
		var fr: int = -1
		if weather._knobs_handle != null and weather._knobs_handle.has_method("get_field_rebuild_count"):
			fr = int(weather._knobs_handle.get_field_rebuild_count())
		print("[weather/knobs] resident KnobsHandle path ACTIVE — first to_*_knobs_dict hit (field_rebuild_count=%d expected ≤1; stable Hz target ≤1 Hz)" % fr)
	return out

# 调用 C++ pass。返回 Variant：
#   Array[WeatherFront]  → 成功（替换原 _build_field_summary_fronts 的输出）
#   null                 → 失败（GDScript fallback）
# 同时把 elapsed_ms / runs / fallbacks 累计到节流告警状态。


static func configure_gdext_acceleration(weather: WeatherSystem, ext: RefCounted, enabled: bool, cp: Resource = null, dc_world = null) -> void:
	weather._data_core_world_ext = ext
	# PR-2.1.6：注入 GDScript DCWorld 用于 commit/spawn 写路径下移（master 手册 §3.9）。
	# 旧 caller（3 参数版）仍可用，dc_world 默认为 null → 仅维持现状双写不下移。
	weather._data_core_world = dc_world
	# has_method 仅检查方法名存在；旧 stub 签名是 (knobs, grid_w, grid_h, season_idx,
	# climate_anomaly, season_phase) 6 参数，新签名只剩 (knobs) 1 参数。stale .dll
	# 下 has_method=true 但 binding 拒调 → rc=null → float(null)=0.0 → 误判 success
	# → SoA 静默不写。下面用 get_method_list 验证实际参数数 = 1。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_weather_field/distribute/summary
	# 三个 cp 字段已删除——赋值现恒走 ext+has_method+sig 探测（仅保留
	# enabled 参数作为 caller 主动 kill-switch）。
	var sig_ok: bool = weather._validate_weather_field_signature(ext)
	var commit_sig_ok: bool = weather._validate_weather_field_commit_signature(ext)
	weather._use_gdext_weather_field = enabled and ext != null and ext.has_method("run_weather_field_solve_pass") and sig_ok
	weather._use_gdext_weather_field_commit = enabled and ext != null and ext.has_method("run_weather_field_commit_pass") and commit_sig_ok
	weather._gdext_field_warned_fallback = false
	weather._gdext_field_commit_warned_fallback = false
	# F.6 / fronts_soa / resident_knobs：cache cp reference 供 advect / soa / knobs 同步读。
	weather._cp_for_front_flag = cp
	weather._sync_profile_weather_knobs(cp)
	if weather._use_gdext_weather_field:
		print("[weather] gdext acceleration ON (class=DCWorldExt)")
	elif ext != null and enabled and not sig_ok:
		# sig probe 已经 push_warning 过具体的 args 数；这里再加一条总结
		push_warning("[weather] gdext acceleration DISABLED for this session: stale .dll signature mismatch (rebuild gdext to enable)")
	elif ext != null and enabled:
		push_warning("[weather] gdext acceleration requested but ext lacks run_weather_field_solve_pass; staying on GDScript path")
	if weather._use_gdext_weather_field_commit:
		print("[weather] gdext field commit ON")
	elif ext != null and enabled and ext.has_method("run_weather_field_commit_pass") and not commit_sig_ok:
		push_warning("[weather] gdext field commit DISABLED: stale .dll signature mismatch")

	# ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）───────────────────
	# dist + summary 两个 pass 的能力探测：方法存在 + 签名 arg-count = 1。任一失败镜像 flag
	# = false → 永远走 GDScript fallback。
	var dist_sig_ok: bool = weather._validate_weather_distribute_signature(ext)
	var summary_sig_ok: bool = weather._validate_weather_summary_signature(ext)
	weather._use_gdext_weather_distribute = enabled and ext != null \
			and ext.has_method("run_weather_distribute_pass") and dist_sig_ok
	weather._use_gdext_weather_summary = enabled and ext != null \
			and ext.has_method("run_weather_summary_fronts_pass") and summary_sig_ok
	weather._gdext_dist_warned_fallback = false
	weather._gdext_summary_warned_fallback = false
	# Flag 切换时清空 C++ 端持久化 summary 状态，避免新旧实现互相污染。
	if ext != null:
		ext.reset_weather_summary_state()

	if weather._use_gdext_weather_distribute:
		print("[weather] gdext distribute ON")
	elif ext != null and enabled and not dist_sig_ok:
		push_warning("[weather] gdext distribute DISABLED: stale .dll signature mismatch")
	if weather._use_gdext_weather_summary:
		print("[weather] gdext summary ON")
	elif ext != null and enabled and not summary_sig_ok:
		push_warning("[weather] gdext summary DISABLED: stale .dll signature mismatch")

	# dots-flag-prune-pr1 (2026-05-22)： use_hexcell_facade 已删除——facade 现恒启用（
	# DataCore world 已恒 bind，hot loop 跳过 16 行 AoS 双写，cell 字段读全部走 SoA）。
	if cp != null:
		weather._hexcell_facade_on = true
		if weather._hexcell_facade_on:
			print("[weather] hexcell facade ON (skip AoS double-write in hot loop)")
	# ─── Phase A.3：常驻 KnobsHandle 装配 ────────────────────────
	# dots-flag-prune-pr1 round 2: use_gdext_resident_knobs flag 已删除——恒走 ext +
	# ClassDB.class_exists('KnobsHandle') 探测分支。启用条件（任一失败永久 fallback 到
	# GDScript builder）：
	#   1. enabled 整体启用且 ext != null
	#   2. ClassDB 内有 "KnobsHandle" 类（rebuild 后 stale .dll 无此类则 instantiate 失败）
	weather._knobs_handle = null
	weather._knobs_handle_first_use_logged = false
	if enabled and ext != null:
		if ClassDB.class_exists("KnobsHandle"):
			weather._knobs_handle = ClassDB.instantiate("KnobsHandle")
			if weather._knobs_handle != null and weather._knobs_handle.has_method("invalidate_all"):
				# 首次装配 → all-dirty。caller 应立刻通过 _push_resident_knobs_from_cp(cp)
				# 把当前 ClimateProfile 全字段写入；后续 ClimateProfile.changed 信号触发同样路径。
				weather._knobs_handle.invalidate_all()
				weather._push_resident_knobs_from_cp(cp)
				# 连接 ClimateProfile.changed 信号（Resource 内置）→ 段级 invalidate
				if cp != null and cp.has_signal("changed") and not cp.changed.is_connected(weather._on_climate_profile_changed_for_knobs):
					cp.changed.connect(weather._on_climate_profile_changed_for_knobs.bind(cp))
				print("[weather] gdext resident knobs ON (class=KnobsHandle)")
			else:
				push_warning("[weather] KnobsHandle instantiate returned invalid object; resident knobs DISABLED")
				weather._knobs_handle = null
		else:
			push_warning("[weather] ClassDB lacks 'KnobsHandle' (stale .dll); resident knobs DISABLED. REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'")
# Stale .dll probe：验证 run_weather_field_solve_pass 实际签名。旧 stub 6 参，新
# 实装 1 参 (Dictionary knobs)。不匹配时 push_warning 一次 + 返回 false 让外层
# 永久走 GDScript fallback。


static func _validate_weather_field_signature(weather: WeatherSystem, ext: RefCounted) -> bool:
	if ext == null:
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_field_solve_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_field_solve_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'." % args.size())
			return false
	return false


static func _validate_weather_field_commit_signature(weather: WeatherSystem, ext: RefCounted) -> bool:
	if ext == null:
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_field_commit_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_field_commit_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'." % args.size())
			return false
	return false

# ─── Phase F.1：A/B 运行时验证（离线诊断专用）────────────────────────────
# enabled=true 后每 tick 都先用 C++ 跑 → 把 next_* + SoA 快照 → 复位 SoA →
# 用 GDScript 重跑 → 逐 cell 比较，首次 abs(delta) > tol 时打详细日志。
# 默认 tol=1.0e-4（charter §12.6.2 sqrt+lerp 链经验值）。
# 性能开销：≈ 2×（同一 tick 跑两次），仅适合 dev / repro 模式下用一两个 tick
# 抓 bug；正常游玩别开。


static func set_field_verify_mode(weather: WeatherSystem, enabled: bool, tol_f32: float = 1.0e-4) -> void:
	weather._field_verify_enabled = enabled
	weather._field_verify_tol_f32 = max(0.0, tol_f32)
	weather._field_verify_first_divergence_logged = false
	if enabled:
		print("[weather] field A/B verify ON (tol=%.1e); next tick will run both paths" % tol_f32)

# ─── Weather Hot-Path：dist A/B verify mode（任务 5）─────────────────────
# 流程：snapshot 5 个 SoA/AoS 字段 → C++ 跑（SoA 已写新值）→ 把 C++ 结果搬到
# shadow → 复位 SoA/AoS → 跑 GDScript → 逐 cell 比对 → commit 走 C++（把
# shadow 写回 SoA/AoS）。开启后整 pass 时间 ≈ 旧 × 2，仅 dev 模式短时使用。
# 切换 verify mode 时清空 dist 节流告警状态，避免历史 fallback 状态污染。


static func set_distribute_verify_mode(weather: WeatherSystem, enabled: bool, tol_f32: float = 1.0e-4) -> void:
	weather._distribute_verify_enabled = enabled
	weather._distribute_verify_tol_f32 = max(0.0, tol_f32)
	weather._distribute_verify_first_divergence_logged = false
	if enabled:
		print("[weather] distribute A/B verify ON (tol=%.1e); next tick will run both paths" % tol_f32)

# ─── Weather Hot-Path：summary A/B verify mode（任务 8 中实装比对主体；本处先
# 提供 setter 给 dev 工具调用，避免任务 6/7 引用未定义符号）。──────────────


static func set_summary_verify_mode(weather: WeatherSystem, enabled: bool,
		tol_pos: float = 0.5, tol_intensity: float = 1.0e-3,
		tol_velocity: float = 0.5) -> void:
	weather._summary_verify_enabled = enabled
	weather._summary_verify_tol_pos = max(0.0, tol_pos)
	weather._summary_verify_tol_intensity = max(0.0, tol_intensity)
	weather._summary_verify_tol_velocity = max(0.0, tol_velocity)
	weather._summary_verify_first_divergence_logged = false
	# 切换 verify 时清空 C++ 端持久化 summary 状态，避免新旧实现相互污染（与
	# flag 切换走同一通路）。
	if weather._data_core_world_ext != null:
		weather._data_core_world_ext.reset_weather_summary_state()
	if enabled:
		print("[weather] summary A/B verify ON (pos=%.2f intensity=%.1e velocity=%.2f)" % [
			tol_pos, tol_intensity, tol_velocity
		])

# 触发：set_distribute_verify_mode(true) 之后每次 C++ dist 成功 commit 前进入。
# 调用前置条件：C++ 已经把 dist 结果写入 SoA + acc/pre PackedArray。
# 主流程把这些 commit 后的值快照到 shadow，复位 SoA/AoS 到 snapshot 入口状态，
# 跑 GDScript 重新 dist，比较两侧最大 delta；最后把 shadow 重新塞回 SoA/AoS 让
# commit 走 C++ 路径。
