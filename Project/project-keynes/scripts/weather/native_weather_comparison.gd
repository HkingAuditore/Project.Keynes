extends RefCounted

## Reads native field results and compares native and script weather publication.


static func _pull_gdext_field_results_to_next(host, map: MapData, n_cells: int) -> void:
	var soa_vapor: PackedFloat32Array = map.weather_vapor_arr
	var soa_cloud: PackedFloat32Array = map.weather_cloud_arr
	var soa_cloud_water: PackedFloat32Array = map.weather_cloud_water_arr
	var soa_precip: PackedFloat32Array = map.weather_precip_arr
	var soa_inst: PackedFloat32Array = map.weather_instability_arr
	var soa_intens: PackedFloat32Array = map.weather_intensity_arr
	var soa_conv: PackedFloat32Array = map.weather_convergence_arr
	var soa_type: PackedByteArray = map.weather_type_arr
	for i in range(n_cells):
		host._field_solver._field_slice_next_vapor[i] = soa_vapor[i]
		host._field_solver._field_slice_next_cloud[i] = soa_cloud[i]
		if soa_cloud_water.size() == n_cells:
			host._field_solver._field_slice_next_cloud_water[i] = soa_cloud_water[i]
		host._field_solver._field_slice_next_precip[i] = soa_precip[i]
		host._field_solver._field_slice_next_instability[i] = soa_inst[i]
		host._field_solver._field_slice_next_intensity[i] = soa_intens[i]
		host._field_solver._field_slice_next_convergence[i] = soa_conv[i]
		host._field_solver._field_slice_next_type[i] = int(soa_type[i])

# ─── F.1 A/B 运行时验证 ───────────────────────────────────────────────────
# 触发：host.set_field_verify_mode(true) 之后每次 C++ 路径成功 commit 前进入。# 触发：set_field_verify_mode(true) 之后每次 C++ 路径成功 commit 前进入。
# 步骤：
#   1. 把 C++ 已写好的 8 个 SoA 字段快照成独立 PackedArray（CoW 复制；不影响
#      host._field_solver._field_slice_next_* 已经持有的同一 SoA 引用）。#      _field_solver._field_slice_next_* 已经持有的同一 SoA 引用）。
#   2. 把 SoA 反向回滚到本 tick 入口的 prev 状态（vapor/precip 用 prev_*；
#      其余字段在 commit 之前不被本 pass 内部读，所以无需精确还原）。
#   3. 把 GDScript 的 host._field_solver._field_slice_next_* 拷成另一组独立缓冲，再用 GDScript#   3. 把 GDScript 的 _field_solver._field_slice_next_* 拷成另一组独立缓冲，再用 GDScript
#      slice loop 重新写一遍——但这会污染 host._field_solver._field_slice_next_*，所以我们先用#      slice loop 重新写一遍——但这会污染 _field_solver._field_slice_next_*，所以我们先用
#      临时 var 备份再恢复。
#   4. 对照 8 个字段逐 cell 比 abs(cpp - gdscript)，首次超过 tol 时打日志并
#      记录 "_field_verify_first_divergence_logged = true"，避免 spam。
#
# 实现策略：直接调用 _solve_weather_field_internal_loop_for_verify(...) 把
# slice 主循环做成独立函数，避免在 verify 路径里复制 600 行算法。

static func _verify_gdext_field_against_gdscript(host, map: MapData, world: WorldData, n_cells: int) -> void:
	# C++ 结果快照（dup() 保证 CoW，不和 SoA 引用别名）
	var cpp_vapor: PackedFloat32Array = host._field_solver._field_slice_next_vapor.duplicate()
	var cpp_cloud: PackedFloat32Array = host._field_solver._field_slice_next_cloud.duplicate()
	var cpp_cloud_water: PackedFloat32Array = host._field_solver._field_slice_next_cloud_water.duplicate()
	var cpp_precip: PackedFloat32Array = host._field_solver._field_slice_next_precip.duplicate()
	var cpp_inst: PackedFloat32Array = host._field_solver._field_slice_next_instability.duplicate()
	var cpp_intens: PackedFloat32Array = host._field_solver._field_slice_next_intensity.duplicate()
	var cpp_conv: PackedFloat32Array = host._field_solver._field_slice_next_convergence.duplicate()
	var cpp_type: PackedInt32Array = host._field_solver._field_slice_next_type.duplicate()

	# 用 GDScript path 重写 host._field_solver._field_slice_next_*。复用现有 slice 循环主体最干净# 用 GDScript path 重写 _field_solver._field_slice_next_*。复用现有 slice 循环主体最干净
	# 的办法是：临时关掉 host._use_gdext_weather_field、把 cursor reset 到 0、再调# 的办法是：临时关掉 _use_gdext_weather_field、把 cursor reset 到 0、再调
	# 一次 host.run_weather_field_solve_slice 走 GDScript 分支。# 一次 run_weather_field_solve_slice 走 GDScript 分支。
	var saved_cursor: int = host._field_solver._field_slice_cursor
	var saved_solve_ms: float = host._field_solver._field_slice_solve_ms
	var saved_last_ms: float = host._field_solver._field_slice_last_ms
	var saved_use_gdext: bool = host._use_gdext_weather_field
	host._use_gdext_weather_field = false
	host._field_solver._field_slice_cursor = 0
	host._field_solver.run_slice(2147483647)
	host._field_solver._field_slice_cursor = saved_cursor
	host._field_solver._field_slice_solve_ms = saved_solve_ms
	host._field_solver._field_slice_last_ms = saved_last_ms
	host._use_gdext_weather_field = saved_use_gdext

	# 此时 host._field_solver._field_slice_next_* = GDScript 版结果。逐 cell 比较。# 此时 _field_solver._field_slice_next_* = GDScript 版结果。逐 cell 比较。
	var max_dvap: float = 0.0
	var max_dcld: float = 0.0
	var max_dcw: float = 0.0
	var max_dpre: float = 0.0
	var max_dins: float = 0.0
	var max_dint: float = 0.0
	var max_dcnv: float = 0.0
	var type_mismatches: int = 0
	var first_div_idx: int = -1
	var first_div_field: String = ""
	var first_div_cpp: float = 0.0
	var first_div_gd: float = 0.0
	for i in range(n_cells):
		var dvap: float = absf(cpp_vapor[i] - host._field_solver._field_slice_next_vapor[i])
		var dcld: float = absf(cpp_cloud[i] - host._field_solver._field_slice_next_cloud[i])
		var dcw: float = absf(cpp_cloud_water[i] - host._field_solver._field_slice_next_cloud_water[i])
		var dpre: float = absf(cpp_precip[i] - host._field_solver._field_slice_next_precip[i])
		var dins: float = absf(cpp_inst[i] - host._field_solver._field_slice_next_instability[i])
		var dint: float = absf(cpp_intens[i] - host._field_solver._field_slice_next_intensity[i])
		var dcnv: float = absf(cpp_conv[i] - host._field_solver._field_slice_next_convergence[i])
		max_dvap = maxf(max_dvap, dvap)
		max_dcld = maxf(max_dcld, dcld)
		max_dcw = maxf(max_dcw, dcw)
		max_dpre = maxf(max_dpre, dpre)
		max_dins = maxf(max_dins, dins)
		max_dint = maxf(max_dint, dint)
		max_dcnv = maxf(max_dcnv, dcnv)
		if cpp_type[i] != host._field_solver._field_slice_next_type[i]:
			type_mismatches += 1
		if first_div_idx < 0:
			if dvap > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "vapor"; first_div_cpp = cpp_vapor[i]; first_div_gd = host._field_solver._field_slice_next_vapor[i]
			elif dcld > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "cloud"; first_div_cpp = cpp_cloud[i]; first_div_gd = host._field_solver._field_slice_next_cloud[i]
			elif dcw > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "cloud_water"; first_div_cpp = cpp_cloud_water[i]; first_div_gd = host._field_solver._field_slice_next_cloud_water[i]
			elif dpre > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "precip"; first_div_cpp = cpp_precip[i]; first_div_gd = host._field_solver._field_slice_next_precip[i]
			elif dins > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "instability"; first_div_cpp = cpp_inst[i]; first_div_gd = host._field_solver._field_slice_next_instability[i]
			elif dint > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "intensity"; first_div_cpp = cpp_intens[i]; first_div_gd = host._field_solver._field_slice_next_intensity[i]
			elif dcnv > host._field_verify_tol_f32:
				first_div_idx = i; first_div_field = "convergence"; first_div_cpp = cpp_conv[i]; first_div_gd = host._field_solver._field_slice_next_convergence[i]

	# 把 host._field_solver._field_slice_next_* 还原成 C++ 结果（commit 才能拿到 C++ 路径数据）。# 把 _field_solver._field_slice_next_* 还原成 C++ 结果（commit 才能拿到 C++ 路径数据）。
	host._field_solver._field_slice_next_vapor = cpp_vapor
	host._field_solver._field_slice_next_cloud = cpp_cloud
	host._field_solver._field_slice_next_cloud_water = cpp_cloud_water
	host._field_solver._field_slice_next_precip = cpp_precip
	host._field_solver._field_slice_next_instability = cpp_inst
	host._field_solver._field_slice_next_intensity = cpp_intens
	host._field_solver._field_slice_next_convergence = cpp_conv
	host._field_solver._field_slice_next_type = cpp_type

	if first_div_idx >= 0 and not host._field_verify_first_divergence_logged:
		host._field_verify_first_divergence_logged = true
		push_warning("[weather/F.1 verify] FAIL — first divergence cell=%d field=%s cpp=%.6f gdscript=%.6f delta=%.2e (tol=%.1e). max abs deltas: vapor=%.2e cloud=%.2e cloud_water=%.2e precip=%.2e inst=%.2e intens=%.2e conv=%.2e type_mismatch=%d/%d" % [
			first_div_idx, first_div_field, first_div_cpp, first_div_gd, absf(first_div_cpp - first_div_gd), host._field_verify_tol_f32,
			max_dvap, max_dcld, max_dcw, max_dpre, max_dins, max_dint, max_dcnv, type_mismatches, n_cells,
		])
	elif first_div_idx < 0:
		# 全 cell 通过——只在第一次通过时打一条 INFO，避免每 tick spam。
		if not host._field_verify_first_divergence_logged:
			host._field_verify_first_divergence_logged = true
			print("[weather/F.1 verify] PASS — all %d cells within tol (max abs deltas: vapor=%.2e cloud=%.2e cloud_water=%.2e precip=%.2e inst=%.2e intens=%.2e conv=%.2e type_mismatch=%d)" % [
				n_cells, max_dvap, max_dcld, max_dcw, max_dpre, max_dins, max_dint, max_dcnv, type_mismatches,
			])


static func _verify_gdext_distribute_against_gdscript(host, map: MapData, n_cells: int, cpp_rc: Dictionary) -> void:
	if not host._distribute_verify_enabled:
		return
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	# Step 1：把 C++ 已经 commit 的 5 个字段复制为 shadow（CoW dup 保证脱离 SoA 引用）。
	var shadow_temp: PackedFloat32Array = map.temp_arr.duplicate()
	var shadow_moist: PackedFloat32Array = map.moisture_arr.duplicate()
	var shadow_cover: PackedByteArray = map.cover_arr.duplicate()
	var shadow_acc: PackedInt32Array = PackedInt32Array()
	var shadow_pre: PackedInt32Array = PackedInt32Array()
	shadow_acc.resize(n_cells)
	shadow_pre.resize(n_cells)
	for i in range(n_cells):
		var c: HexCell = cells[i]
		shadow_acc[i] = c.accumulated_snow_days
		shadow_pre[i] = c.pre_snow_cover

	# Step 2：复位到本 tick 入口状态（cpp_rc 携带的 snapshot；调用方提供）。
	# snapshot 字段名约定：snap_temp / snap_moist / snap_cover / snap_acc / snap_pre。
	# 调用方在 fast-path 调度阶段已 dup 一份原始 SoA 传入。
	var snap_temp: PackedFloat32Array = cpp_rc.get("snap_temp", PackedFloat32Array())
	var snap_moist: PackedFloat32Array = cpp_rc.get("snap_moist", PackedFloat32Array())
	var snap_cover: PackedByteArray = cpp_rc.get("snap_cover", PackedByteArray())
	var snap_acc: PackedInt32Array = cpp_rc.get("snap_acc", PackedInt32Array())
	var snap_pre: PackedInt32Array = cpp_rc.get("snap_pre", PackedInt32Array())
	if snap_temp.size() != n_cells or snap_moist.size() != n_cells or \
			snap_cover.size() != n_cells or snap_acc.size() != n_cells or \
			snap_pre.size() != n_cells:
		push_warning("[weather/dist verify] snapshot 不全或大小不匹配，跳过本 tick verify")
		return
	# 把 SoA 还原。facade=true 时 cell.cover/temperature/moisture 通过 setter 透写
	# SoA；这里直接覆写 SoA arr 即可。
	map.temp_arr = snap_temp.duplicate()
	map.moisture_arr = snap_moist.duplicate()
	map.cover_arr = snap_cover.duplicate()
	for i in range(n_cells):
		var c2: HexCell = cells[i]
		c2.accumulated_snow_days = snap_acc[i]
		c2.pre_snow_cover = snap_pre[i]
		# current_state["cover"] 可能在 C++ commit 阶段被改过；同步回 snapshot。
		c2.current_state["cover"] = int(snap_cover[i])

	# Step 3：跑 GDScript 版 dist。它会读 cell.* 写 cell.* 同源覆盖。
	host._distribute_weather_field_to_cells(map)

	# Step 4：逐 cell 比对（temp/moist 用 tol_f32；cover/acc/pre 严格相等）。
	var max_dt: float = 0.0
	var max_dm: float = 0.0
	var first_div_idx: int = -1
	var first_div_field: String = ""
	for i in range(n_cells):
		var dt: float = absf(shadow_temp[i] - map.temp_arr[i])
		var dm: float = absf(shadow_moist[i] - map.moisture_arr[i])
		if dt > max_dt:
			max_dt = dt
		if dm > max_dm:
			max_dm = dm
		if first_div_idx < 0 and (dt > host._distribute_verify_tol_f32 or dm > host._distribute_verify_tol_f32):
			first_div_idx = i
			first_div_field = "temperature" if dt > dm else "moisture"
		if shadow_cover[i] != map.cover_arr[i] and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "cover"
		var c3: HexCell = cells[i]
		if shadow_acc[i] != c3.accumulated_snow_days and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "accumulated_snow_days"
		if shadow_pre[i] != c3.pre_snow_cover and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "pre_snow_cover"

	if first_div_idx >= 0 and not host._distribute_verify_first_divergence_logged:
		host._distribute_verify_first_divergence_logged = true
		var c4: HexCell = cells[first_div_idx]
		push_warning("[weather/dist verify] divergence at idx=%d field=%s cpp_temp=%.4f gd_temp=%.4f cpp_moist=%.4f gd_moist=%.4f cpp_cover=%d gd_cover=%d cpp_acc=%d gd_acc=%d (max_dt=%.4e max_dm=%.4e)" % [
			first_div_idx, first_div_field,
			shadow_temp[first_div_idx], map.temp_arr[first_div_idx],
			shadow_moist[first_div_idx], map.moisture_arr[first_div_idx],
			int(shadow_cover[first_div_idx]), int(map.cover_arr[first_div_idx]),
			shadow_acc[first_div_idx], c4.accumulated_snow_days,
			max_dt, max_dm
		])

	# Step 5：把 shadow（C++ 结果）写回 SoA/AoS，让 commit 走 C++ 路径。
	map.temp_arr = shadow_temp
	map.moisture_arr = shadow_moist
	map.cover_arr = shadow_cover
	for i in range(n_cells):
		var c5: HexCell = cells[i]
		c5.accumulated_snow_days = shadow_acc[i]
		c5.pre_snow_cover = shadow_pre[i]
		c5.current_state["cover"] = int(shadow_cover[i])

# ─── Weather Hot-Path：summary fronts A/B verify（任务 8）─────────────────
# 调用前提：host.set_summary_verify_mode(true) 之后，C++ summary pass 已成功跑过# 调用前提：set_summary_verify_mode(true) 之后，C++ summary pass 已成功跑过
# 一次（fronts_cpp 已就位）；调用方把 fronts_cpp 与 cpp_state_snapshotted=true
# 作为入参传入。本函数：
#   1. 调 C++ restore_weather_summary_state() 把 prev_seeds/membership 还原到
#      C++ pass 入口状态（snapshot 已在 fast-path 调度时由 caller 完成）；
#   2. 跑 GDScript host._build_field_summary_fronts → 得 fronts_gd；#   2. 跑 GDScript _build_field_summary_fronts → 得 fronts_gd；
#   3. 同长度 + 字段容差比对（type 严格 / center 0.5px / intensity 1e-3 /
#      velocity 0.5px），首个发散 push_warning 一次（_summary_verify_first_
#      divergence_logged 节流）；
#   4. 调用方把 fronts_cpp 写回 host._active_fronts 完成 commit（本函数不动 commit）。#   4. 调用方把 fronts_cpp 写回 _active_fronts 完成 commit（本函数不动 commit）。
#
# 注意：GDScript 复跑 host._build_field_summary_fronts 会改 host._prev_summary_seeds /# 注意：GDScript 复跑 _build_field_summary_fronts 会改 _prev_summary_seeds /
# host._prev_summary_membership（GDScript 镜像）。这两个状态在 fast-path 模式下# _prev_summary_membership（GDScript 镜像）。这两个状态在 fast-path 模式下
# 不被使用，但 verify off 切回 GDScript 路径时会被复用 —— 不算污染（GDScript
# 路径下本来就由 host._build_field_summary_fronts 自维护）。# 路径下本来就由 _build_field_summary_fronts 自维护）。

static func _verify_gdext_summary_against_gdscript(host, map: MapData, world: WorldData,
		fronts_cpp: Array[WeatherFront]) -> void:
	if not host._summary_verify_enabled:
		return
	if host._data_core_world_ext == null:
		return
	# Step 1：C++ 端把 prev_seeds/membership restore 到本 tick 入口状态。
	# 调用方应已在 fast-path 调度入口调用 snapshot_weather_summary_state()。
	host._data_core_world_ext.restore_weather_summary_state()
	# Step 2：GDScript 复跑（注意 GDScript prev_seeds/membership 也会被改，
	# 见函数说明）。
	var fronts_gd: Array[WeatherFront] = host._build_field_summary_fronts(map, world)
	# Step 3：逐 front 容差比对。
	var n_cpp: int = fronts_cpp.size()
	var n_gd: int = fronts_gd.size()
	if n_cpp != n_gd and not host._summary_verify_first_divergence_logged:
		host._summary_verify_first_divergence_logged = true
		push_warning("[weather/summary verify] front count mismatch: cpp=%d gd=%d" % [n_cpp, n_gd])
		return
	var n: int = mini(n_cpp, n_gd)
	for i in range(n):
		var fc: WeatherFront = fronts_cpp[i]
		var fg: WeatherFront = fronts_gd[i]
		if fc.type != fg.type and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] type mismatch cpp=%d gd=%d" % [i, fc.type, fg.type])
			return
		var dpos: float = fc.center.distance_to(fg.center)
		if dpos > host._summary_verify_tol_pos and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] center mismatch cpp=%s gd=%s |Δ|=%.2f (tol=%.2f)" % [
				i, str(fc.center.round()), str(fg.center.round()), dpos, host._summary_verify_tol_pos
			])
			return
		if absf(fc.intensity - fg.intensity) > host._summary_verify_tol_intensity and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] intensity mismatch cpp=%.4f gd=%.4f (tol=%.1e)" % [
				i, fc.intensity, fg.intensity, host._summary_verify_tol_intensity
			])
			return
		var dvel: float = fc.velocity.distance_to(fg.velocity)
		if dvel > host._summary_verify_tol_velocity and not host._summary_verify_first_divergence_logged:
			host._summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] velocity mismatch cpp=%s gd=%s |Δ|=%.2f (tol=%.2f)" % [
				i, str(fc.velocity.round()), str(fg.velocity.round()), dvel, host._summary_verify_tol_velocity
			])
			return

# ─── 任务 9：节流式回归告警 ───────────────────────────────────────────────
# field_solver 在 dist/summary commit 完成后分别调一次。维护最近 5 个 elapsed
# 样本；连续 5 个都 > budget × 2 时 push_warning 一次（warned 节流防止刷屏）。
# 一旦最近某次回到 budget 内，warned 重置回 false（性能恢复后可再警告）。
