extends RefCounted
class_name DCPhysicalSolveBaker

const PhysCircSolverScript = preload("res://scripts/rendering/physical_circulation_solver.gd")





static func _physical_solve_step_one(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float, solve_ocean: bool = true) -> bool:
	if world == null or map == null:
		return true
	# 同 phase 已求解过 → idempotent fast path（caller 不需要外层判断）。
	if not is_nan(baker._pending_phys_solved_phase) \
			and absf(baker._pending_phys_solved_phase - season_phase) < 0.001:
		if baker._phys_solve_rt_diag_count < 24:
			baker._phys_solve_rt_diag_count += 1
			print("[phys_solve][RT] cache_hit#%d phase=%.4f pending=%s stage=%d solve_ocean=%s" % [
				baker._phys_solve_rt_diag_count, season_phase,
				str(baker._pending_phys_solved_phase), baker._phys_stage, str(solve_ocean),
			])
		baker._phys_stage = baker._PHYS_STAGE_DONE
		return true
	if baker._phys_stage == baker._PHYS_STAGE_NONE:
		if baker._phys_solve_rt_diag_count < 24:
			baker._phys_solve_rt_diag_count += 1
			print("[phys_solve][RT] start#%d phase=%.4f pending=%s solve_ocean=%s ext=%s idx=%s soa=%s" % [
				baker._phys_solve_rt_diag_count, season_phase,
				str(baker._pending_phys_solved_phase), str(solve_ocean),
				str(baker._world_ext != null), str(map.has_indices()), str(map.has_soa()),
			])
		baker._phys_stage = baker._PHYS_STAGE_SLP
		baker._phys_psi_iters_done = 0
		baker._phys_wind_done_by_cpp = false
		baker._pending_psi_state = null
		# Item 2b: 新一轮求解起点清零切片游标（中途续帧不会经过此分支，游标得以保留）。
		baker._phys_slp_cursor = 0
		baker._phys_wind_cursor = 0
		baker._phys_upwelling_cursor = 0

	var profile: ClimateProfile = cfg.climate_profile if cfg != null else null
	var phys_cell_slice_enabled: bool = baker._physical_cell_slice_enabled(profile)
	var phys_cell_slice_divisor: int = baker._physical_cell_slice_divisor(profile)
	baker._phys_cell_slice_enabled = phys_cell_slice_enabled
	baker._phys_cell_slice_divisor = phys_cell_slice_divisor
	var terrain_aware: bool = profile.enable_terrain_aware_wind if profile != null else true
	var heat_transport: bool = profile.enable_ocean_heat_transport if profile != null else true
	var slp_wind_gdscript_required: bool = profile != null and (
			absf(profile.wind_thermal_slp_weight) > 0.0001
			or absf(profile.slp_ice_high_weight) > 0.0001
			or absf(profile.slp_snow_high_weight) > 0.0001
			or profile.wind_response_rate < 0.999)
	var ocean_gdscript_required: bool = profile != null and (
			profile.ocean_current_response_rate < 0.999
			or absf(profile.ocean_thermal_current_weight) > 0.0001
			or absf(profile.ocean_density_cold_weight) > 0.0001
			or absf(profile.ocean_density_ice_weight) > 0.0001)
	var bounds: Rect2 = world.world_bounds
	var days_per_year_phys: int = baker._calendar_days_per_year(profile)
	var sim_day_phys: int = baker._phys_resolve_abs_sim_day(season_phase, days_per_year_phys)
	var world_seed_phys: int = int(world.bake_seed) if world != null else (int(cfg.seed) if cfg != null else 0)
	baker._phys_last_season_phase = season_phase
	baker._phys_last_sim_day = sim_day_phys
	# 预建常量 knob base（按 map+profile+hex_size 失效），削减每 stage 每调用重建
	# Dictionary 的 GDScript wrapper 开销。详见 _phys_ensure_knob_cache。
	baker._phys_ensure_knob_cache(map, hex_size, bounds, profile, cfg)

	match baker._phys_stage:
		baker._PHYS_STAGE_SLP:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：记录 wrapper 整体耗时（包括 iter_cells +
			# Dict 构造 + C++ call + writeback fallback）。配合 ocean_currents/STAGE-DIAG
			# 在 SUS slice 层定位 stage 1 wall time。
			var _slp_stage_t0_us: int = Time.get_ticks_usec()
			# plan/dots-slp-psi-cpp — once-only path-decision (fronts 3 hits).
			# dots-flag-prune-pr1 round 2: use_gdext_slp_field flag 已删除——恒走 ext +
			# has_method(run_slp_field_pass) + map.has_indices() 探测分支。DIAG 块保留原状，
			# pflag_val 恒为 true 仅作为诊断记录。
			var _slp_done_by_cpp: bool = false
			var _slp_native_ms: float = -1.0
			# Item 2b: 切片状态（case 级，供写回 gate 与续帧 return 共用）。
			var _slp_slicing: bool = false
			var _slp_final: bool = true
			var _slp_end: int = 0
			if baker._slp_path_log_count < 3:
				baker._slp_path_log_count += 1
				var _s_prof_ok: bool = profile != null
				var _s_pflag_attr_ok: bool = true  # 已折叠：flag 字段已删，不再检查
				var _s_pflag_val_ok: bool = true  # 已折叠：恒 true
				var _s_pext_ok: bool = baker._world_ext != null
				var _s_pmethod_ok: bool = _s_pext_ok and baker._world_ext.has_method("run_slp_field_pass")
				var _s_idx_ok: bool = map != null and map.has_indices()
				var _s_gate_pass: bool = _s_pmethod_ok and _s_idx_ok
				print("[slp_field] path-decision call#%d: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s idx=%s -> cpp_gate=%s" % [
					baker._slp_path_log_count,
					str(_s_prof_ok), str(_s_pflag_attr_ok), str(_s_pflag_val_ok),
					str(_s_pext_ok), str(_s_pmethod_ok), str(_s_idx_ok), str(_s_gate_pass)
				])
			if baker._world_ext != null and baker._world_ext.has_method("run_slp_field_pass") \
					and map != null and map.has_indices():
				var cells_for_slp_cpp: Array = map.iter_cells()
				var n_slp: int = cells_for_slp_cpp.size()
				var nb_idx_for_slp: PackedInt32Array = map.neighbor_indices_packed()
				if n_slp > 0 and nb_idx_for_slp.size() >= n_slp * 6:
					var knobs_slp: Dictionary = baker._phys_knobs_base_slp.duplicate()
					knobs_slp["season_phase"] = season_phase
					knobs_slp["sim_day"] = sim_day_phys
					knobs_slp["world_seed"] = world_seed_phys
					knobs_slp["prev_slp_arr"] = map.slp_arr
					# Item 2b: cell-range 切片（默认关闭）。拆成 divisor 段，传 start_idx/end_idx。
					_slp_slicing = phys_cell_slice_enabled and phys_cell_slice_divisor > 1
					if _slp_slicing:
						var _slp_chunk: int = int(ceil(float(n_slp) / float(phys_cell_slice_divisor)))
						if _slp_chunk < 1:
							_slp_chunk = 1
						var _slp_start: int = baker._phys_slp_cursor
						var _slp_range_end: int = mini(_slp_start + _slp_chunk, n_slp)
						knobs_slp["start_idx"] = _slp_start
						knobs_slp["end_idx"] = _slp_range_end
						_slp_final = (_slp_range_end >= n_slp)
						_slp_end = _slp_range_end
					var ret_slp = baker._world_ext.run_slp_field_pass(knobs_slp)
					if ret_slp != null and typeof(ret_slp) == TYPE_DICTIONARY:
						var rc_slp: float = float(ret_slp.get("elapsed_ms", -1.0))
						var slp_out: PackedFloat32Array = ret_slp.get("slp_out", PackedFloat32Array())
						var slp_published_to_slot: bool = bool(ret_slp.get("published_to_slot", false))
						var slp_slice_start: int = int(ret_slp.get("slice_start", int(knobs_slp.get("start_idx", 0))))
						var slp_slice_end: int = int(ret_slp.get("slice_end", int(knobs_slp.get("end_idx", n_slp))))
						var slp_slice_final: bool = bool(ret_slp.get("slice_final", _slp_final))
						var slp_slot_id: int = int(ret_slp.get("slot_id", -1))
						var slp_slot_size: int = int(ret_slp.get("slot_size", 0))
						var slp_slot_publish_reason: String = str(ret_slp.get(
								"slot_publish_reason", "legacy_dll_unknown"))
						_slp_final = slp_slice_final
						baker._phys_last_slp_rc_ms = rc_slp
						baker._phys_last_slp_out_size = slp_out.size()
						baker._phys_last_slp_published_to_slot = slp_published_to_slot
						baker._phys_last_slp_commit_ok = rc_slp >= 0.0 and slp_out.size() == n_slp
						if baker._slp_commit_diag_count < 3:
							baker._slp_commit_diag_count += 1
							print("[slp_field] commit-diag call#%d: rc=%.3f slp_out=%d n_cells=%d map_slp=%d slice=%d:%d final=%s published=%s slot=%d/%d reason=%s" % [
								baker._slp_commit_diag_count, rc_slp, slp_out.size(), n_slp, map.slp_arr.size(),
								slp_slice_start, slp_slice_end, str(slp_slice_final),
								str(slp_published_to_slot), slp_slot_id, slp_slot_size,
								slp_slot_publish_reason,
							])
						# 运行期根因诊断（每 200 次调用 + 前 5 次打印一次），定位 SLP 冻结：
						# - commit_ok=true  → 已写回 map.slp_arr，理应随 season 变化
						# - rc<0            → C++ pass 内部走了 fallback(返回 dict 但无效)
						# - size_mismatch   → commit gate 因 slp_out.size()!=n_cells 拦截
						baker._slp_rt_diag_count += 1
						if baker._slp_rt_diag_count <= 5 or baker._slp_rt_diag_count % 200 == 0:
							var _commit_ok: bool = rc_slp >= 0.0 and slp_out.size() == n_slp
							var _reason: String = "rc<0(cpp_fallback)" if rc_slp < 0.0 else \
								("size_mismatch(gate_block)" if not _commit_ok else \
								("intermediate_slice" if not slp_slice_final else \
								("slot_published" if slp_published_to_slot else "snapshot_commit")))
							print("[slp_field][RT-DIAG] call#%d phase=%.4f rc=%.3f slp_out=%d n=%d slice=%d:%d final=%s published=%s slot=%d/%d slot_reason=%s -> %s" % [
								baker._slp_rt_diag_count, season_phase, rc_slp, slp_out.size(), n_slp,
								slp_slice_start, slp_slice_end, str(slp_slice_final),
								str(slp_published_to_slot), slp_slot_id, slp_slot_size,
								slp_slot_publish_reason, _reason,
							])
						if rc_slp >= 0.0 and slp_out.size() == n_slp:
							baker._slp_thermal_p95_last = float(ret_slp.get("slp_thermal_p95", 0.0))
							baker._slp_delta_p95_last = float(ret_slp.get("slp_delta_p95", 0.0))
							# Item 2b: 仅末片（或关闭切片时）写回 map.slp_arr；中间切片跳过
							# 避免把 partial slp_out（非切片区为上一 tick 残值）写进地图。
							if _slp_final:
								if not slp_published_to_slot:
									# C++ slot unavailable/stale-DLL compatibility: the result is
									# already a complete PackedFloat32Array. Replacing it once is
									# the same snapshot boundary as native flush; per-element writes
									# can trigger a CoW detach on every iteration and stall the frame.
									map.slp_arr = slp_out
									if baker._world_ext.has_method("refresh_slots_from_map_keys"):
										baker._world_ext.refresh_slots_from_map_keys(
											PackedStringArray(["cell_slp"]))
								_slp_done_by_cpp = true
								_slp_native_ms = rc_slp
								if not baker._slp_first_run_logged:
									baker._slp_first_run_logged = true
									print("[slp_field] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ~36ms; target < 3ms)" % rc_slp)
			# Item 2b: SLP 切片未到末片 → 推进游标、停留 SLP、续帧（本 tick SLP 仍未完成）。
			if _slp_slicing and not _slp_final and baker._phys_last_slp_commit_ok:
				baker._phys_slp_cursor = _slp_end
				return false
			if not _slp_done_by_cpp:
				baker._phys_last_slp_rc_ms = -1.0
				baker._phys_last_slp_out_size = -1
				baker._phys_last_slp_published_to_slot = false
				baker._phys_last_slp_commit_ok = false
				if baker._slp_path_log_count > 0 and baker._slp_path_log_count <= 3:
					print("[slp_field] FALLBACK to GDScript solve_slp_field (call#%d) — see preceding path-decision / commit-diag for reason" % baker._slp_path_log_count)
				# 运行期诊断：进入此分支即说明 C++ commit 未成功（没进 C++ 分支 /
				# 返回 null / gate 拦截）。打印 has_soa——若为 true，下面镜像写回被跳过，
				# GDScript 只写了 HexCell.slp(SoA)，若 SoA 与 map.slp_arr 不同步则冻结。
				baker._slp_rt_diag_count += 1
				if baker._slp_rt_diag_count <= 5 or baker._slp_rt_diag_count % 200 == 0:
					print("[slp_field][RT-DIAG] call#%d phase=%.4f -> GDSCRIPT_FALLBACK has_soa=%s (镜像写回 %s)" % [
						baker._slp_rt_diag_count, season_phase, str(map.has_soa()),
						"SKIP" if map.has_soa() else "DONE"
					])
				PhysCircSolverScript.solve_slp_field(map, hex_size, bounds, season_phase, 1, profile)
				# Fallback path 内部用 HexCell.slp setter（_facade_enabled=true 时已
				# 写 SoA），这里仅在 facade 关闭/非完整迁移的兼容窗口里做兜底镜像。
				# 用 has_soa() 守门避免无谓 2400× loop。
				if not map.has_soa():
					var cells_for_slp: Array = map.iter_cells() if map.has_indices() else map.all_cells()
					if map.slp_arr.size() == cells_for_slp.size():
						for _i_slp_commit in range(cells_for_slp.size()):
							var _c_slp_commit: HexCell = cells_for_slp[_i_slp_commit]
							map.slp_arr[_i_slp_commit] = _c_slp_commit.slp if _c_slp_commit != null else 0.0
			baker._slp_native_ms_last = _slp_native_ms
			baker._slp_path_str_last = "gdext" if _slp_done_by_cpp else "gdscript"
			var _slp_stage_total_ms: float = float(Time.get_ticks_usec() - _slp_stage_t0_us) / 1000.0
			# 前 3 次必打 + >= 5ms 异常打。配合 [ocean_currents/STAGE-DIAG] 做交叉验证。
			# 注意：call#1 内还有 path-decision / commit-diag / RT-DIAG / ACTIVE 共 4 个 print，
			#       Windows stdout flush 每行 ~12-15ms → call#1 wall 会被污染 ~50-60ms。
			#       真实 stage wall ≈ call#1_wall - 15ms × (该 call 同 stage 内已打印的 print 行数)。
			#       call#2+ 后 path-decision / commit-diag 命中前 3 次封顶，wall 才反映真实开销。
			if PKLog.enabled and (baker._slp_path_log_count <= 3 or _slp_stage_total_ms >= 5.0):
				print("[slp_field/STAGE-TOTAL] call#%d wall=%.2fms native=%.2fms path=%s commit_ok=%s (call#1 wall pollution: ~15ms/print × 4 prints; trust call#4+ or wall>=5ms warn)" % [
					baker._slp_path_log_count, _slp_stage_total_ms,
					float(_slp_native_ms),
					baker._slp_path_str_last,
					str(baker._phys_last_slp_commit_ok),
				])
			baker._phys_slp_cursor = 0
			baker._phys_stage = baker._PHYS_STAGE_WIND
		baker._PHYS_STAGE_WIND:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：见 _PHYS_STAGE_SLP。
			var _wind_stage_t0_us: int = Time.get_ticks_usec()
			# Block B（master 手册 §4 / dots-wind-validation.md）：wind solver C++ 化 hook。
			# dots-flag-prune-pr1 round 2: use_gdext_wind_field flag 已删除——恒走 ext +
			# has_method(run_wind_field_pass) 探测分支（C++ 返回 fallback 或 ext 未 bind 时
			# 透明 fallback 到 GDScript solve_wind_field）。DIAG 块保留原状。
			var _wind_done_by_cpp: bool = false
			# Item 2b: 切片状态（case 级）。
			var _wind_slicing: bool = false
			var _wind_final: bool = true
			baker._phys_last_wind_rc_ms = -1.0
			baker._phys_last_wind_wx_size = -1
			baker._phys_last_wind_wy_size = -1
			baker._phys_last_wind_speed_out_size = -1
			baker._phys_last_wind_map_speed_size = -1
			baker._phys_last_wind_commit_ok = false
			# DOTS-Final-Push 后续诊断 — once-only 路径决策（仿 upwelling stage 6）。
			# 与 _wind_b_first_run_logged 不同：那个只在 C++ 路径首次成功后打印；
			# 这里在 stage 2 第一次执行时无条件打印各子条件命中状态。
			if baker._wind_b_path_log_count < 3:
				baker._wind_b_path_log_count += 1
				var _w_prof_ok: bool = profile != null
				var _w_pflag_attr_ok: bool = true  # 已折叠：flag 字段已删
				var _w_pflag_val_ok: bool = true  # 已折叠：恒 true
				var _w_pext_ok: bool = baker._world_ext != null
				var _w_pmethod_ok: bool = _w_pext_ok and baker._world_ext.has_method("run_wind_field_pass")
				var _w_idx_ok: bool = map != null and map.has_indices()
				var _w_gate_pass: bool = _w_pmethod_ok and _w_idx_ok
				print("[wind_field/B] path-decision call#%d: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s idx=%s -> cpp_gate=%s" % [
					baker._wind_b_path_log_count,
					str(_w_prof_ok), str(_w_pflag_attr_ok), str(_w_pflag_val_ok),
					str(_w_pext_ok), str(_w_pmethod_ok), str(_w_idx_ok), str(_w_gate_pass)
				])
			if baker._world_ext != null and baker._world_ext.has_method("run_wind_field_pass"):
				var cells_for_wind: Array = map.iter_cells() if map.has_indices() else map.all_cells()
				var n_wind: int = cells_for_wind.size()
				var nb_idx_for_wind: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
				var fast_indexed_wind: bool = nb_idx_for_wind.size() >= n_wind * 6
				if fast_indexed_wind and n_wind > 0:
					var slp_arr: PackedFloat32Array = map.slp_arr if map.slp_arr.size() == n_wind else PackedFloat32Array()
					if slp_arr.is_empty():
						slp_arr.resize(n_wind)
						for _i_slp in range(n_wind):
							var _c_slp: HexCell = cells_for_wind[_i_slp]
							slp_arr[_i_slp] = _c_slp.slp if _c_slp != null else 0.0
					# water_terrain_ids：与 PhysicalCirculationSolver._is_water_terrain 1:1
					var knobs_wind: Dictionary = baker._phys_knobs_base_wind.duplicate()
					knobs_wind["season_phase"] = season_phase
					knobs_wind["sim_day"] = sim_day_phys
					knobs_wind["wind_elapsed_days"] = baker._phys_take_wind_elapsed_days(sim_day_phys)
					knobs_wind["world_seed"] = world_seed_phys
					knobs_wind["slp_arr"] = slp_arr
					# Item 2b: cell-range 切片
					_wind_slicing = phys_cell_slice_enabled and phys_cell_slice_divisor > 1
					if _wind_slicing:
						var _wind_chunk: int = int(ceil(float(n_wind) / float(phys_cell_slice_divisor)))
						if _wind_chunk < 1:
							_wind_chunk = 1
						var _wind_start: int = baker._phys_wind_cursor
						var _wind_end: int = mini(_wind_start + _wind_chunk, n_wind)
						knobs_wind["start_idx"] = _wind_start
						knobs_wind["end_idx"] = _wind_end
						_wind_final = (_wind_end >= n_wind)
					var _rc_wind = baker._world_ext.run_wind_field_pass(knobs_wind)
					baker._phys_last_wind_rc_ms = float(_rc_wind) if _rc_wind != null else -1.0
					if _rc_wind != null and float(_rc_wind) >= 0.0 and _wind_final:
						# C++ 已写入并 flush wind_x/y/speed；这里保留 size gate 与
						# 非 PSI fallback 的 HexCell 同步，避免成功路径重复写 PackedArray。
						var wx_arr: PackedFloat32Array = map.wind_x_arr
						var wy_arr: PackedFloat32Array = map.wind_y_arr
						var wspd_arr: PackedFloat32Array = knobs_wind.get("wind_speed_out", PackedFloat32Array())
						baker._phys_last_wind_wx_size = wx_arr.size()
						baker._phys_last_wind_wy_size = wy_arr.size()
						baker._phys_last_wind_speed_out_size = wspd_arr.size()
						baker._phys_last_wind_map_speed_size = map.wind_speed_arr.size()
						baker._phys_last_wind_commit_ok = wx_arr.size() == n_wind and wy_arr.size() == n_wind \
								and wspd_arr.size() == n_wind and map.wind_speed_arr.size() == n_wind
						# DOTS-Final-Push 后续诊断：commit size 检查是 silent
						# fallback 唯一缺口（rc>=0 但 size 不齐 → _phys_wind_done_by_cpp
						# 仍是 false，stage 6 走 GDScript upwelling 92ms）。一次性 print。
						if baker._wind_b_commit_diag_count < 3:
							baker._wind_b_commit_diag_count += 1
							print("[wind_field/B] commit-diag call#%d: rc=%.3f n_wind=%d wx=%d wy=%d wspd=%d map_wspd=%d" % [
								baker._wind_b_commit_diag_count, float(_rc_wind), n_wind, wx_arr.size(), wy_arr.size(), wspd_arr.size(), map.wind_speed_arr.size()
							])
						if baker._phys_last_wind_commit_ok:
							var psi_cpp_expected: bool = solve_ocean and heat_transport \
									and baker._world_ext != null and baker._world_ext.has_method("run_psi_solver_pass")
							# HexCell 写回仅在 facade 关闭（无 SoA）时需要。facade 恒启用时
							# run_wind_field_pass 已直写 cell.wind_x/wind_y/wind_speed SoA slot
							# （world_ext_physical.cpp:636-638/777-779），getter 也读 SoA，逐 cell
							# setter 写回纯冗余——每 cell 3 次跨语言 write_f32 × n_cells，是 wind-only
							# 物理轮（psi_cpp_expected=false）上 7-40ms 尖刺源。与 _PHYS_STAGE_SLP
							# fallback 的 `if not map.has_soa()` 守门同源。
							if not psi_cpp_expected and not map.has_soa():
								for _i_w in range(n_wind):
									var _c_w: HexCell = cells_for_wind[_i_w]
									if _c_w != null:
										_c_w.wind_vector = Vector2(wx_arr[_i_w], wy_arr[_i_w])
										_c_w.wind_speed = wspd_arr[_i_w]
							baker._wind_delta_p95_last = float(knobs_wind.get("wind_delta_p95", 0.0))
							baker._wind_dir_delta_p95_last = float(knobs_wind.get("wind_dir_delta_p95", 0.0))
							baker._wind_dir_flip_count_last = int(knobs_wind.get("wind_dir_flip_count", 0))
							_wind_done_by_cpp = true
							baker._phys_wind_done_by_cpp = true
							if not baker._wind_b_first_run_logged:
								baker._wind_b_first_run_logged = true
								print("[wind_field/B] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 35ms; charter §7 / dots-wind-validation.md target < 5ms)" % float(_rc_wind))
					elif _rc_wind != null and float(_rc_wind) >= 0.0 and _wind_slicing and not _wind_final:
						# Item 2b: 中间切片 —— C++ 已更新本段 wind_x/y/speed slots，无需 commit
						# 检查 / HexCell 写回，推进游标续帧（避免回退 GDScript 求解）。
						baker._phys_wind_cursor = int(knobs_wind.get("end_idx", n_wind))
						return false
			if not _wind_done_by_cpp:
				baker._phys_wind_done_by_cpp = false
				# DOTS-Final-Push 后续诊断：fallback 分支也打前 3 次，配合 path-decision /
				# commit-diag 形成完整诊断三角（gate 失败 / commit size mismatch / 默默 fallback）。
				if baker._wind_b_path_log_count > 0 and baker._wind_b_path_log_count <= 3:
					print("[wind_field/B] FALLBACK to GDScript solve_wind_field (call#%d) — see preceding path-decision / commit-diag for reason" % baker._wind_b_path_log_count)
				PhysCircSolverScript.solve_wind_field(map, hex_size, bounds, season_phase, terrain_aware, profile)
			var _wind_stage_total_ms: float = float(Time.get_ticks_usec() - _wind_stage_t0_us) / 1000.0
			if PKLog.enabled and (baker._wind_b_path_log_count <= 3 or _wind_stage_total_ms >= 5.0):
				print("[wind_field/STAGE-TOTAL] call#%d wall=%.2fms native=%.2fms path=%s commit_ok=%s" % [
					baker._wind_b_path_log_count, _wind_stage_total_ms,
					float(baker._phys_last_wind_rc_ms),
					"gdext" if _wind_done_by_cpp else "gdscript",
					str(baker._phys_last_wind_commit_ok),
				])
			if not solve_ocean:
				baker._pending_psi_state = null
				baker._phys_psi_iters_done = 0
				baker._pending_phys_solved_phase = season_phase
				baker._phys_stage = baker._PHYS_STAGE_DONE
				return true
			if heat_transport:
				baker._phys_stage = baker._PHYS_STAGE_PSI_INIT
			else:
				# 跳过 ψ 求解，直接走 fallback ocean current；下一片做 upwelling。
				baker._pending_psi_state = null
				PhysCircSolverScript.solve_ocean_current_fallback(map, hex_size, bounds, cfg, profile)
				baker._phys_stage = baker._PHYS_STAGE_UPWELLING
		baker._PHYS_STAGE_PSI_INIT:
			# plan/dots-slp-psi-cpp — once-only path-decision (fronts 3 hits).
			# dots-flag-prune-pr1 round 2: use_gdext_psi_solver flag 已删除——恒走 ext +
			# has_method(run_psi_solver_pass) + heat_transport + map.has_indices() 探测分支。
			var _psi_done_by_cpp: bool = false
			var _psi_native_ms: float = -1.0
			if baker._psi_path_log_count < 3:
				baker._psi_path_log_count += 1
				var _p_prof_ok: bool = profile != null
				var _p_pflag_attr_ok: bool = true  # 已折叠：flag 字段已删
				var _p_pflag_val_ok: bool = true  # 已折叠：恒 true
				var _p_pext_ok: bool = baker._world_ext != null
				var _p_pmethod_ok: bool = _p_pext_ok and baker._world_ext.has_method("run_psi_solver_pass")
				var _p_idx_ok: bool = map != null and map.has_indices()
				var _p_heat_ok: bool = heat_transport
				var _p_gate_pass: bool = _p_pmethod_ok and _p_idx_ok and _p_heat_ok
				print("[psi_solver] path-decision call#%d: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s idx=%s heat=%s -> cpp_gate=%s" % [
					baker._psi_path_log_count,
					str(_p_prof_ok), str(_p_pflag_attr_ok), str(_p_pflag_val_ok),
					str(_p_pext_ok), str(_p_pmethod_ok), str(_p_idx_ok),
					str(_p_heat_ok), str(_p_gate_pass)
				])
			if heat_transport \
					and baker._world_ext != null and baker._world_ext.has_method("run_psi_solver_pass") \
					and map != null and map.has_indices():
				# Fix #11 grounding (2026-06-15)：精确测量 PSI_INIT wrapper 时间分布。
				# log 实测 phys_slice elapsed=8-13ms，C++ kernel 仅 0.4ms。剩 7-12ms
				# 在哪？分 4 段测量：
				#   T1_prepack: iter_cells + neighbor_indices_packed + wind PackedArray ref/build
				#   T2_knobs:   构造 knobs Dictionary（25+ 字段）
				#   T3_call:    跨 GDExtension run_psi_solver_pass C++ kernel
				#   T4_writeback: 解 ret Dict + 2400 loop 写 wind_stress_curl_arr / ocean_psi_arr
				# 前 3 次完整 dump，之后只在异常 (>5ms) 时打印。
				var _psi_t_stage_us: int = Time.get_ticks_usec()
				var _psi_t1_us: int = Time.get_ticks_usec()
				var cells_for_psi: Array = map.iter_cells()
				var n_psi: int = cells_for_psi.size()
				var nb_idx_for_psi: PackedInt32Array = map.neighbor_indices_packed()
				# Pack current-frame wind state. C++ wind path already wrote map.wind_x/y
				# and map.wind_speed_arr, so reuse SoA directly and avoid 2400 facade reads.
				var wx_arr_psi: PackedFloat32Array = PackedFloat32Array()
				var wy_arr_psi: PackedFloat32Array = PackedFloat32Array()
				var wspd_arr_psi: PackedFloat32Array = PackedFloat32Array()
				if baker._phys_wind_done_by_cpp and map.wind_x_arr.size() == n_psi \
						and map.wind_y_arr.size() == n_psi and map.wind_speed_arr.size() == n_psi:
					wx_arr_psi = map.wind_x_arr
					wy_arr_psi = map.wind_y_arr
					wspd_arr_psi = map.wind_speed_arr
				else:
					wx_arr_psi.resize(n_psi)
					wy_arr_psi.resize(n_psi)
					wspd_arr_psi.resize(n_psi)
					for _i_w_pack in range(n_psi):
						var _c_wp: HexCell = cells_for_psi[_i_w_pack]
						if _c_wp == null:
							wx_arr_psi[_i_w_pack] = 0.0
							wy_arr_psi[_i_w_pack] = 0.0
							wspd_arr_psi[_i_w_pack] = 0.0
						else:
							wx_arr_psi[_i_w_pack] = _c_wp.wind_vector.x
							wy_arr_psi[_i_w_pack] = _c_wp.wind_vector.y
							wspd_arr_psi[_i_w_pack] = _c_wp.wind_speed
				if n_psi > 0 and nb_idx_for_psi.size() >= n_psi * 6:
					var _psi_t1_ms: float = float(Time.get_ticks_usec() - _psi_t1_us) / 1000.0
					var _psi_t2_us: int = Time.get_ticks_usec()
					var knobs_psi: Dictionary = baker._phys_knobs_base_psi.duplicate()
					knobs_psi["wind_x_arr"] = wx_arr_psi
					knobs_psi["wind_y_arr"] = wy_arr_psi
					knobs_psi["wind_speed_arr"] = wspd_arr_psi
					var _psi_t2_ms: float = float(Time.get_ticks_usec() - _psi_t2_us) / 1000.0
					var _psi_t3_us: int = Time.get_ticks_usec()
					var ret_psi = baker._world_ext.run_psi_solver_pass(knobs_psi)
					var _psi_t3_ms: float = float(Time.get_ticks_usec() - _psi_t3_us) / 1000.0
					# Fix #11 (2026-06-15)：published_to_slot=true 时 C++ 已写 slot + flush 到 map.*，
					# GDScript 跳过 4 次 PackedArray dict.get（每次会 deep copy 2400 floats）+ 2400-loop writeback。
					# 实测 fast path STAGE 从 15ms → 0.67ms（kernel 0.45ms + 边界 0.16ms + dict 0.06ms）。
					# fallback 路径（rc>=0 但 published_to_slot=false）走 4 array get + 2400-loop 兜底，
					# 兼容旧 DLL（不认识 curl/psi slot）的情况。
					var _psi_t4_us: int = Time.get_ticks_usec()
					if ret_psi != null and typeof(ret_psi) == TYPE_DICTIONARY:
						var rc_psi: float = float(ret_psi.get("elapsed_ms", -1.0))
						var psi_published_to_slot: bool = bool(ret_psi.get("published_to_slot", false))
						var curl_out: PackedFloat32Array
						var psi_out: PackedFloat32Array
						var ocx_out: PackedFloat32Array
						var ocy_out: PackedFloat32Array
						if not psi_published_to_slot:
							curl_out = ret_psi.get("wind_stress_curl_out", PackedFloat32Array())
							psi_out = ret_psi.get("ocean_psi_out", PackedFloat32Array())
							ocx_out = ret_psi.get("ocean_current_x_out", PackedFloat32Array())
							ocy_out = ret_psi.get("ocean_current_y_out", PackedFloat32Array())
						# commit-diag print 移到 STAGE 测量外（Windows ConHost stdout flush ~15ms/line 会污染 T4）
						var _do_commit_diag_print: bool = (baker._psi_commit_diag_count < 3)
						if _do_commit_diag_print:
							baker._psi_commit_diag_count += 1
						if rc_psi >= 0.0 and (psi_published_to_slot or (
								curl_out.size() == n_psi and psi_out.size() == n_psi
								and ocx_out.size() == n_psi and ocy_out.size() == n_psi)):
							baker._ocean_delta_p95_last = float(ret_psi.get("ocean_delta_p95", 0.0))
							baker._thermal_current_p95_last = float(ret_psi.get("thermal_current_p95", 0.0))
							baker._ocean_current_preclamp_p95_last = float(ret_psi.get("ocean_current_preclamp_p95", 0.0))
							baker._ocean_current_preclamp_max_last = float(ret_psi.get("ocean_current_preclamp_max", 0.0))
							baker._ocean_current_clamp_count_last = int(ret_psi.get("ocean_current_clamp_count", 0))
							baker._ocean_current_clamp_ratio_last = float(ret_psi.get("ocean_current_clamp_ratio", 0.0))
							baker._ocean_current_max_magnitude_last = float(ret_psi.get("ocean_current_max_magnitude", 0.0))
							# NS 化 Phase 4 诊断(旧 DLL 缺键落默认)
							baker._ocean_topo_steer_w_eff_last = float(ret_psi.get("ocean_topo_steer_w", 0.0))
							baker._ocean_depth_curl_damp_eff_last = float(ret_psi.get("ocean_depth_curl_damp", 0.0))
							baker._psi_iters_run_last = int(ret_psi.get("psi_iters_run", baker._PHYS_PSI_TOTAL_ITERS))
							baker._psi_residual_final_last = float(ret_psi.get("psi_residual_final", 0.0))
							baker._psi_early_exit_last = bool(ret_psi.get("psi_early_exit", false))
							baker._psi_mode_last = str(ret_psi.get("psi_mode", "off"))
							var _has_psi_debug_arr: bool = map.wind_stress_curl_arr.size() == n_psi \
									and map.ocean_psi_arr.size() == n_psi
							# Fix #11 (2026-06-15)：published_to_slot=true 时 C++ 已写 slot + flush 到 map.*，
							# GDScript 完全跳过 2400 loop writeback。fallback 路径走兜底循环（旧 DLL 不认识 slot）。
							if not psi_published_to_slot:
								for _i_pc in range(n_psi):
									map.ocean_current_x_arr[_i_pc] = ocx_out[_i_pc]
									map.ocean_current_y_arr[_i_pc] = ocy_out[_i_pc]
									if _has_psi_debug_arr:
										map.wind_stress_curl_arr[_i_pc] = curl_out[_i_pc]
										map.ocean_psi_arr[_i_pc] = psi_out[_i_pc]
							_psi_done_by_cpp = true
							_psi_native_ms = rc_psi
							var _psi_t4_ms: float = float(Time.get_ticks_usec() - _psi_t4_us) / 1000.0
							var _psi_stage_ms: float = float(Time.get_ticks_usec() - _psi_t_stage_us) / 1000.0
							# Fix #11 grounding：前 3 次完整打印，之后异常 (>5ms) 才打。
							# 注意：commit-diag 打印移到 STAGE 测量之后，避免 stdout flush ~15ms 污染 T4。
							# Fix #11 second pass (2026-06-16)：原 `_psi_path_log_count <= 3` 误用——
							# 该计数只在 line 5555 path-decision 块自增（封顶 3），不在 BREAKDOWN 块自增，
							# 所以 BREAKDOWN 永远命中 `<=3` 一直 print，mobile 上 61 次 / 2min 污染 logcat。
							# 改为独立 _psi_breakdown_log_count 计数 + 5ms warn 阈值（mobile 实测 STAGE
							# 0.6-1.2ms，不会触发 warn）。
							baker._psi_breakdown_log_count += 1
							if PKLog.enabled and (baker._psi_breakdown_log_count <= 3 or _psi_stage_ms > 5.0):
								print("[psi_solver/BREAKDOWN] call#%d STAGE=%.2fms T1_prepack=%.2fms T2_knobs=%.2fms T3_call=%.2fms (kernel=%.2fms gdext_overhead=%.2fms) T4_writeback=%.2fms (n_psi=%d published=%s has_debug=%s)" % [
									baker._psi_breakdown_log_count,
									_psi_stage_ms, _psi_t1_ms, _psi_t2_ms, _psi_t3_ms, rc_psi, maxf(0.0, _psi_t3_ms - rc_psi),
									_psi_t4_ms, n_psi, str(psi_published_to_slot), str(_has_psi_debug_arr)
								])
							if not baker._psi_first_run_logged:
								baker._psi_first_run_logged = true
								print("[psi_solver] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript stage3+4+5 baseline ~32+ms; target < 5ms)" % rc_psi)
							# 推迟到 STAGE 测量之外的 commit-diag print（避免 print stdout flush 污染 T4）
							if _do_commit_diag_print:
								print("[psi_solver] commit-diag call#%d: rc=%.3f n_water=%d n_cells=%d published=%s" % [
									baker._psi_commit_diag_count, rc_psi,
									int(ret_psi.get("n_water", -1)),
									n_psi, str(psi_published_to_slot)
								])
			baker._psi_native_ms_last = _psi_native_ms
			baker._psi_path_str_last = "gdext" if _psi_done_by_cpp else "gdscript"
			if _psi_done_by_cpp:
				# Skip stage 4 / 5: C++ pass did init+iters+finalize+commit.
				baker._pending_psi_state = null
				baker._phys_psi_iters_done = maxi(0, baker._psi_iters_run_last)
				baker._phys_stage = baker._PHYS_STAGE_UPWELLING
			else:
				if baker._psi_path_log_count > 0 and baker._psi_path_log_count <= 3:
					print("[psi_solver] FALLBACK to GDScript init/iters/finalize (call#%d) — see preceding path-decision / commit-diag for reason" % baker._psi_path_log_count)
				if baker._phys_wind_done_by_cpp and map.wind_x_arr.size() >= map.soa_size() \
						and map.wind_y_arr.size() >= map.soa_size() \
						and map.wind_speed_arr.size() >= map.soa_size():
					var cells_sync_wind: Array = map.iter_cells() if map.has_indices() else map.all_cells()
					for _i_sync_wind in range(map.soa_size()):
						var _c_sync_wind: HexCell = cells_sync_wind[_i_sync_wind]
						if _c_sync_wind != null:
							_c_sync_wind.wind_vector = Vector2(map.wind_x_arr[_i_sync_wind], map.wind_y_arr[_i_sync_wind])
							_c_sync_wind.wind_speed = map.wind_speed_arr[_i_sync_wind]
				baker._pending_psi_state = PhysCircSolverScript.init_psi_solver(map, hex_size, bounds)
				baker._phys_psi_iters_done = 0
				baker._phys_stage = baker._PHYS_STAGE_PSI_ITERS
		baker._PHYS_STAGE_PSI_ITERS:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：mobile 上 C++ 路径 PSI_INIT 跳过 ITERS/
			# FINALIZE，进这里就说明走了 fallback（GDScript SOR 40 iters），是高优先级排查目标。
			var _psi_iters_stage_t0_us: int = Time.get_ticks_usec()
			var iters_to_do: int = mini(
				baker._PHYS_PSI_ITERS_PER_STEP,
				baker._PHYS_PSI_TOTAL_ITERS - baker._phys_psi_iters_done
			)
			if iters_to_do > 0 and baker._pending_psi_state != null:
				PhysCircSolverScript.step_psi_solver(baker._pending_psi_state, iters_to_do)
				baker._phys_psi_iters_done += iters_to_do
			var _psi_iters_stage_total_ms: float = float(Time.get_ticks_usec() - _psi_iters_stage_t0_us) / 1000.0
			# 进入这里就是 fallback，每次都打（频次不会高 — 40/8 = 5 slice 才完成一轮）。
			print("[psi_iters/STAGE-TOTAL] wall=%.2fms iters_done=%d/%d iters_this_slice=%d (FALLBACK path — C++ run_psi_solver_pass not available)" % [
				_psi_iters_stage_total_ms, baker._phys_psi_iters_done, baker._PHYS_PSI_TOTAL_ITERS, iters_to_do,
			])
			if baker._phys_psi_iters_done >= baker._PHYS_PSI_TOTAL_ITERS:
				baker._phys_stage = baker._PHYS_STAGE_PSI_FINALIZE
		baker._PHYS_STAGE_PSI_FINALIZE:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：同 PSI_ITERS，进这里是 fallback。
			# psi_to_ocean_current 在 GDScript 跑 2400-loop 6 邻居梯度 + density gradient + lat_temp，
			# 是 ocean fallback 路径的最大单 stage 嫌疑（~20-40ms / slice）。
			var _psi_fin_stage_t0_us: int = Time.get_ticks_usec()
			if baker._pending_psi_state != null:
				PhysCircSolverScript.psi_to_ocean_current(baker._pending_psi_state, map, hex_size, bounds, cfg, profile)
				PhysCircSolverScript.commit_psi_to_cells(baker._pending_psi_state)
				if map.has_indices() and map.wind_stress_curl_arr.size() == map.soa_size() \
						and map.ocean_psi_arr.size() == map.soa_size():
					var cells_for_psi_debug: Array = map.iter_cells()
					for _i_psi_debug in range(cells_for_psi_debug.size()):
						var _c_psi_debug: HexCell = cells_for_psi_debug[_i_psi_debug]
						map.wind_stress_curl_arr[_i_psi_debug] = _c_psi_debug.wind_stress_curl if _c_psi_debug != null else 0.0
						map.ocean_psi_arr[_i_psi_debug] = _c_psi_debug.ocean_psi if _c_psi_debug != null else 0.0
			var _psi_fin_stage_total_ms: float = float(Time.get_ticks_usec() - _psi_fin_stage_t0_us) / 1000.0
			print("[psi_finalize/STAGE-TOTAL] wall=%.2fms (FALLBACK path — psi_to_ocean_current + commit_psi + 2400-loop curl/psi writeback in GDScript)" % _psi_fin_stage_total_ms)
			baker._phys_stage = baker._PHYS_STAGE_UPWELLING
		baker._PHYS_STAGE_UPWELLING:
			var _upwelling_done_by_cpp: bool = false
			# DOTS-Total-CPP 诊断：stage 6 整体 87ms 但 cpp 内部 0.045ms，瓶颈
			# 此前定位在 GDScript 准备步骤；现在 C++ 路径已经稳定（实测
			# STAGE-TOTAL ≈ 0.21ms），收尾把诊断收紧到只在第一次进入时打一组，
			# 之后静默。要复现详细日志只需把 budget 改大或重置 _upwelling_diag_count = 0。
			const _UPWELLING_DIAG_BUDGET: int = 1
			var _diag_active: bool = baker._upwelling_diag_count < _UPWELLING_DIAG_BUDGET
			var _t_stage_us: int = Time.get_ticks_usec()
			if _diag_active:
				baker._upwelling_diag_count += 1
				var prof_ok: bool = profile != null
				# dots-flag-prune-pr1 round 2: use_gdext_physical_circulation flag 已删除——
				# 探针保留以观察 ext / wind_cpp / idx 准备状态，pflag 列恒 true 标记。
				var pflag_attr_ok: bool = true  # 已折叠：flag 字段已删
				var pflag_val_ok: bool = true   # 已折叠：恒 true
				var pext_ok: bool = baker._world_ext != null
				var pmethod_ok: bool = pext_ok and baker._world_ext.has_method("run_physical_circulation_pass")
				var wind_cpp_ok: bool = baker._phys_wind_done_by_cpp
				var idx_ok: bool = map != null and map.has_indices()
				var gate_pass: bool = pmethod_ok and wind_cpp_ok and idx_ok
				print("[upwelling/DIAG#%d] gate: prof=%s pflag_attr=%s pflag_val=%s ext=%s method=%s wind_cpp=%s idx=%s -> cpp_gate=%s" % [
					baker._upwelling_diag_count, str(prof_ok), str(pflag_attr_ok), str(pflag_val_ok), str(pext_ok),
					str(pmethod_ok), str(wind_cpp_ok), str(idx_ok), str(gate_pass)
				])
			# dots-flag-prune-pr1 round 2: use_gdext_physical_circulation flag 已删除——
			# 恒走 ext + has_method(run_physical_circulation_pass) + wind_cpp + idx 探测。
			if baker._world_ext != null and baker._world_ext.has_method("run_physical_circulation_pass") \
					and baker._phys_wind_done_by_cpp \
					and map.has_indices():
				# T1: neighbor_indices_packed
				var _t1_us: int = Time.get_ticks_usec()
				var n_up: int = map.soa_size()
				var nb_idx_up: PackedInt32Array = map.neighbor_indices_packed()
				var _ms_t1: float = float(Time.get_ticks_usec() - _t1_us) / 1000.0
				if n_up > 0 and nb_idx_up.size() >= n_up * 6:
					# T2: 准备 knobs（PackedByteArray + Dictionary）
					var _t2_us: int = Time.get_ticks_usec()
					var knobs_up: Dictionary = baker._phys_knobs_base_up.duplicate()
					# Item 2b: cell-range 切片（upwelling 直写 slot，逐 cell 独立，无需 C++ 侧 gating）。
					if phys_cell_slice_enabled and phys_cell_slice_divisor > 1 and n_up > 0:
						var _up_chunk: int = int(ceil(float(n_up) / float(phys_cell_slice_divisor)))
						if _up_chunk < 1:
							_up_chunk = 1
						var _up_start: int = baker._phys_upwelling_cursor
						var _up_end: int = mini(_up_start + _up_chunk, n_up)
						knobs_up["start_idx"] = _up_start
						knobs_up["end_idx"] = _up_end
					var _ms_t2: float = float(Time.get_ticks_usec() - _t2_us) / 1000.0
					# T3: refresh_slots_from_map
					var _t3_us: int = Time.get_ticks_usec()
					if baker._world_ext.has_method("refresh_slots_from_map"):
						baker._world_ext.refresh_slots_from_map()
					var _ms_t3: float = float(Time.get_ticks_usec() - _t3_us) / 1000.0
					# T4: 真正调用 C++
					var _t4_us: int = Time.get_ticks_usec()
					var ret_up = baker._world_ext.run_physical_circulation_pass(knobs_up)
					var _ms_t4: float = float(Time.get_ticks_usec() - _t4_us) / 1000.0
					if _diag_active:
						var rt_ok: bool = (typeof(ret_up) == TYPE_DICTIONARY)
						var fb: bool = (not rt_ok) or bool(ret_up.get("fallback", true))
						var rsn: String = (ret_up.get("reason", "") if rt_ok else "non-dict")
						var em: float = (float(ret_up.get("elapsed_ms", -1.0)) if rt_ok else -1.0)
						print("[upwelling/DIAG#%d] cpp-call: ret_type=%s fallback=%s reason='%s' elapsed_native_ms=%.3f" % [
							baker._upwelling_diag_count, str(typeof(ret_up)), str(fb), rsn, em
						])
						print("[upwelling/DIAG#%d] BREAKDOWN: T1_nb_pack=%.2fms T2_knobs=%.2fms T3_refresh_slots=%.2fms T4_cpp_call=%.2fms (n=%d)" % [
							baker._upwelling_diag_count, _ms_t1, _ms_t2, _ms_t3, _ms_t4, n_up
						])
					if typeof(ret_up) == TYPE_DICTIONARY and not bool(ret_up.get("fallback", true)):
						_upwelling_done_by_cpp = true
						# Item 2b: UPWELLING 切片未到末片 → 推进游标、停留 UPWELLING、续帧。
						if phys_cell_slice_enabled and phys_cell_slice_divisor > 1 and n_up > 0:
							var _end2: int = int(knobs_up.get("end_idx", n_up))
							if _end2 < n_up:
								baker._phys_upwelling_cursor = _end2
								return false
							baker._phys_upwelling_cursor = 0
				else:
					if _diag_active:
						print("[upwelling/DIAG#%d] inner-skip: n_cells=%d nb_idx_size=%d (need >= %d)" % [
							baker._upwelling_diag_count, n_up, nb_idx_up.size(), n_up * 6
						])
			else:
				if _diag_active:
					print("[upwelling/DIAG#%d] outer-skip: gate_pass=false (see gate line above)" % baker._upwelling_diag_count)
			if not _upwelling_done_by_cpp:
				var _t_fb_us: int = Time.get_ticks_usec()
				PhysCircSolverScript.solve_upwelling(map, hex_size, bounds, cfg)
				if _diag_active:
					var _ms_fb: float = float(Time.get_ticks_usec() - _t_fb_us) / 1000.0
					print("[upwelling/DIAG#%d] GDSCRIPT-FALLBACK ran=%.2fms (THIS IS THE BOTTLENECK)" % [
						baker._upwelling_diag_count, _ms_fb
					])
			else:
				if _diag_active:
					print("[upwelling/DIAG#%d] CPP-PATH-OK (no GDScript fallback)" % baker._upwelling_diag_count)
			if _diag_active:
				var _ms_stage: float = float(Time.get_ticks_usec() - _t_stage_us) / 1000.0
				print("[upwelling/DIAG#%d] STAGE-TOTAL=%.2fms (matches slow_slice if > 25ms)" % [
					baker._upwelling_diag_count, _ms_stage
				])
			# Fix #11 (2026-06-15)：原 _UPWELLING_DIAG_BUDGET=1 封顶后整个 stage 静音，
			# 但 STAGE >= 5ms 的异常应该一直报。补一行 warn-only 路径，与 _diag_active 解耦。
			if not _diag_active:
				var _ms_stage_warn: float = float(Time.get_ticks_usec() - _t_stage_us) / 1000.0
				if PKLog.enabled and _ms_stage_warn >= 5.0:
					print("[upwelling/STAGE-TOTAL] warn wall=%.2fms cpp=%s (>= 5ms threshold; mobile ocean candidate hotspot)" % [
						_ms_stage_warn, str(_upwelling_done_by_cpp),
					])
			baker._phys_stage = baker._PHYS_STAGE_WIND_RASTER
		baker._PHYS_STAGE_WIND_RASTER:
			# Fix #11 (2026-06-15) STAGE-TOTAL 埋点：第一次进入 stage 时整段 wall time 已被
			# 内部 `t_wr_us > 8.0ms` 报警覆盖。这里给 GDScript slice 路径再加一行 wall warn，
			# mobile 上 Fix #1 已经禁用了 phys_need_visual 跨季 rebake，所以 stage 7 进入即
			# 异常（应该不再来这里）。这条诊断帮我们捕获回退。
			var _wr_stage_t0_us: int = Time.get_ticks_usec()
			# 第一次进入 WIND_RASTER 时跑 NaN 守门 + 分配 buffer，之后每次推进
			# 一片像素，全部写完才 _PHYS_STAGE_DONE。
			var W := world.derived_size.x
			var H := world.derived_size.y
			var pix_total: int = W * H
			if pix_total <= 0:
				baker._pending_phys_solved_phase = season_phase
				baker._phys_stage = baker._PHYS_STAGE_DONE
				return true
			if baker._phys_wind_raster_idx == 0:
				var t_wr_us: int = Time.get_ticks_usec()
				# NaN/Inf 守门：若任一 cell 物理量异常，退回 fallback 路径覆写。
				# DOTS-Total-CPP（A 方案 / phys nan_guard 孪生）：优先走 C++ SoA
				# 位运算扫描（2400 cell × 6 字段 << 0.1ms），替代 22ms GDScript 循环。
				# 失败（旧 DLL / SoA 缺失）→ 透明回落原路径。
				var n_bad: int = -1
				if baker._world_ext != null and baker._world_ext.has_method("phys_field_nan_guard"):
					n_bad = int(baker._world_ext.phys_field_nan_guard())
				if n_bad < 0:
					n_bad = 0
					for c: HexCell in map.all_cells():
						if c == null:
							continue
						if not is_finite(c.wind_vector.x) or not is_finite(c.wind_vector.y) \
								or not is_finite(c.wind_speed) \
								or not is_finite(c.ocean_current.x) or not is_finite(c.ocean_current.y) \
								or not is_finite(c.upwelling_strength):
							n_bad += 1
				if n_bad > 0:
					push_warning("PhysicalCirculation: detected %d cells with NaN/Inf, falling back to ny-only solver" % n_bad)
					PhysCircSolverScript.solve_ocean_current_fallback(map, hex_size, bounds, cfg, profile)
					PhysCircSolverScript.solve_upwelling(map, hex_size, bounds, cfg)
				var t_nan_ms: float = (Time.get_ticks_usec() - t_wr_us) / 1000.0
				var t_ensure0_us: int = Time.get_ticks_usec()
				baker._ensure_pending_wind_size(world)
				var t_ensure_ms: float = (Time.get_ticks_usec() - t_ensure0_us) / 1000.0
				# DOTS-Total-CPP（A 方案 / wind raster）：第一次进入 stage 时尝试 C++
				# 一次性 hex→pixel rasterize（620544 像素 ≤ 5ms），成功则直接收尾。
				# 失败 → 透明回落到下面的 GDScript 像素切片路径。
				# dots-flag-prune-pr1 (2026-05-22)：use_gdext_ocean_currents_pixel flag 已删，
				# wind raster fast path 现恒走 ext + has_method 探测。
				if profile != null \
						and baker._world_ext != null \
						and baker._world_ext.has_method("run_wind_field_rasterize"):
					var t_raster0_us: int = Time.get_ticks_usec()
					var _wr_res: Dictionary = baker.run_wind_field_rasterize_full(map, world, cfg)
					var t_raster_ms: float = (Time.get_ticks_usec() - t_raster0_us) / 1000.0
					if not bool(_wr_res.get("fallback", true)):
						baker._pending_phys_solved_phase = season_phase
						baker._phys_stage = baker._PHYS_STAGE_DONE
						baker._phys_wind_raster_idx = 0
						var t_total_ms: float = (Time.get_ticks_usec() - t_wr_us) / 1000.0
						if t_total_ms > 8.0:
							print("  [phys_wind_raster] total=%.1fms nan_guard=%.1f ensure_buf=%.1f cpp_raster=%.1f (cells=%d)" % [
								t_total_ms, t_nan_ms, t_ensure_ms, t_raster_ms, map.cell_count()
							])
						return true
			var s_idx: int = baker._phys_wind_raster_idx
			var e_idx: int = mini(pix_total, s_idx + baker._PHYS_WIND_RASTER_PIXELS_PER_STEP)
			baker._rasterize_wind_slice_from_hex(world, baker._pending_wind_buf, s_idx, e_idx)
			baker._phys_wind_raster_idx = e_idx
			var _wr_slice_total_ms: float = float(Time.get_ticks_usec() - _wr_stage_t0_us) / 1000.0
			if PKLog.enabled and _wr_slice_total_ms >= 5.0:
				print("[wind_raster/STAGE-TOTAL] warn slice wall=%.2fms (pix %d..%d / %d) [GDScript slice path; mobile Fix #1 expected to skip this stage entirely]" % [
					_wr_slice_total_ms, s_idx, e_idx, pix_total,
				])
			if baker._phys_wind_raster_idx >= pix_total:
				baker._pending_phys_solved_phase = season_phase
				baker._phys_stage = baker._PHYS_STAGE_DONE
				baker._phys_wind_raster_idx = 0
				return true
			# 还有像素要写 → 留在 WIND_RASTER stage，下次 step_one 续。
			return false
		baker._PHYS_STAGE_DONE:
			return true
		_:
			# 未知状态 → 强制收尾（避免死循环）。
			baker._pending_phys_solved_phase = season_phase
			baker._phys_stage = baker._PHYS_STAGE_DONE
			return true
	return baker._phys_stage == baker._PHYS_STAGE_DONE


# Phys Solve Sliced 入口 ① ：给一次性路径用的 wrapper。
#
# 一次性调用：把 SLP / wind / ψ / current / upwelling / wind raster 全部在
# 一次函数调用中跑完。bake_world 与 rebake_ocean_currents 走这条；它们都需要
# "调用返回时 hex 字段已就绪"的强语义。内部循环调 `_physical_solve_step_one`
# 直到 `_PHYS_STAGE_DONE`，避免与切片路径双份维护求解逻辑。
#
# 重复调用同一 phase 时直接 return（_pending_phys_solved_phase 命中）。下一轮
# 来临前 commit_ocean_buffers / discard_ocean_buffers 都会把
# _pending_phys_solved_phase + _phys_stage 重置，强制重算。

static func _physical_solve_for_phase(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	if world == null or map == null:
		return
	if not is_nan(baker._pending_phys_solved_phase) and absf(baker._pending_phys_solved_phase - season_phase) < 0.001:
		return
	var t0_total := Time.get_ticks_msec()
	# dots-total-cpp step3（2026-06-25）：一次性路径优先走 C++ orchestrator
	# run_physical_solve_pass（SLP→wind→PSI→upwelling 全在 C++ 进程内串完，中间量不跨语言）。
	# 仅本"原子完成"入口走它；运行期逐帧分摊路径（_physical_solve_step_one 被 job 驱动）不受影响。
	# 失败（ext/方法缺失、未 bind、任一 sub-pass fallback、!heat_transport、NaN）→ 回退原 loop。
	if baker._physical_solve_native_oneshot(map, world, hex_size, cfg, season_phase):
		baker._pending_phys_solved_phase = season_phase
		baker._phys_stage = baker._PHYS_STAGE_DONE
		var total_ms_oneshot := Time.get_ticks_msec() - t0_total
		if total_ms_oneshot > 25:
			push_warning("PhysicalCirculation solve@phase=%.2f total=%dms (C++ one-shot) — exceeds 25ms soft budget" % [season_phase, total_ms_oneshot])
		else:
			print("PhysicalCirculation solve@phase=%.2f total=%dms (C++ one-shot run_physical_solve_pass)" % [season_phase, total_ms_oneshot])
		return
	# 一次性路径必须从干净状态起步，避免和切片路径残留的 _phys_stage 冲突。
	baker.reset_physical_solve_state()
	var stage_ms: Dictionary = {}  # stage_idx -> ms（diagnostic）
	var stage_t0: int = Time.get_ticks_msec()
	var prev_stage: int = baker._phys_stage
	while not baker._physical_solve_step_one(map, world, hex_size, cfg, season_phase):
		# 在每个 stage 切换处采样一次，方便日志比对老的 slp/wind/psi/up 拆分。
		if baker._phys_stage != prev_stage:
			stage_ms[prev_stage] = Time.get_ticks_msec() - stage_t0
			stage_t0 = Time.get_ticks_msec()
			prev_stage = baker._phys_stage
	stage_ms[prev_stage] = Time.get_ticks_msec() - stage_t0

	var total_ms := Time.get_ticks_msec() - t0_total
	var msg := "PhysicalCirculation solve@phase=%.2f total=%dms (slp=%dms wind=%dms psi=%dms finalize=%dms upwelling=%dms wind_raster=%dms)" % [
		season_phase, total_ms,
		int(stage_ms.get(baker._PHYS_STAGE_SLP, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_WIND, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_PSI_INIT, 0)) + int(stage_ms.get(baker._PHYS_STAGE_PSI_ITERS, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_PSI_FINALIZE, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_UPWELLING, 0)),
		int(stage_ms.get(baker._PHYS_STAGE_WIND_RASTER, 0)),
	]
	if total_ms > 25:
		push_warning("%s — exceeds 25ms soft budget" % msg)
	else:
		print(msg)

# dots-total-cpp step3（2026-06-25）：生成期物理环流一次性 C++ orchestrator wrapper。
# 构造 combined knobs（SLP+wind+PSI+upwelling 四 stage 输入并集，chained 键 slp_arr/
# wind_*_arr/stage 由 C++ 内部注入），一次调 run_physical_solve_pass 跑完全部 kernel，
# 再用 phys_field_nan_guard 复刻 WIND_RASTER 的 NaN 守门。风场 RG8 光栅化仍由后续
# _bake_initial_vector_buffers 完成（本 wrapper 不碰 _pending_wind_buf）。
# 返回 true=全程 C++ 成功；false=ext/方法缺失、未 bind、任一 sub-pass fallback、
# !heat_transport（需 GDScript ocean fallback）、NaN → caller 回退原 step_one loop。

static func _physical_solve_native_oneshot(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> bool:
	if baker._world_ext == null or not baker._world_ext.has_method("run_physical_solve_pass"):
		return false
	if map == null or not map.has_indices():
		return false
	var profile: ClimateProfile = cfg.climate_profile if cfg != null else null
	# !heat_transport 配置走 GDScript ocean fallback（C++ 无等价）→ 不用一次性路径。
	var heat_transport: bool = profile.enable_ocean_heat_transport if profile != null else true
	if not heat_transport:
		return false
	var cells: Array = map.iter_cells()
	var n: int = cells.size()
	if n <= 0:
		return false
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if nb_idx.size() < n * 6:
		return false

	var bounds: Rect2 = world.world_bounds
	if bounds.size.y <= 0.001:
		return false
	var terrain_aware: bool = profile.enable_terrain_aware_wind if profile != null else true
	var days_per_year_phys: int = baker._calendar_days_per_year(profile)
	var sim_day_phys: int = baker._phys_resolve_abs_sim_day(season_phase, days_per_year_phys)
	var world_seed_phys: int = int(world.bake_seed)
	var cold_sink_temp: float = -0.05
	if cfg != null and "COLD_SINK_TEMP" in cfg:
		cold_sink_temp = float(cfg.COLD_SINK_TEMP)

	# water_terrain_ids（与 PhysicalCirculationSolver._is_water_terrain 1:1，4 stage 共用）
	var water_ids := PackedByteArray()
	water_ids.append(int(TerrainType.TERRAIN.OCEAN))
	water_ids.append(int(TerrainType.TERRAIN.COAST))
	water_ids.append(int(TerrainType.TERRAIN.REEF))
	water_ids.append(int(TerrainType.TERRAIN.KELP))

	# prev_slp_arr（SLP response_rate 混合用）；缺失时 C++ 自有兜底。
	var prev_slp: PackedFloat32Array = map.slp_arr if map.slp_arr.size() == n else PackedFloat32Array()

	# combined knobs = 四 stage 输入并集（chained 键 slp_arr / wind_*_arr / stage 不传，C++ 注入）。
	var knobs := {
		# 共用
		"n_cells": n,
		"hex_size": hex_size,
		"season_phase": season_phase,
		"world_bounds_pos_y": bounds.position.y,
		"world_bounds_size_y": bounds.size.y,
		"wrap_origin_x": 0.0,
		"wrap_period_x": HexUtils.wrap_period_cell_pos_x(map.width),
		"neighbor_indices": nb_idx,
		"water_terrain_ids": water_ids,
		"days_per_year": days_per_year_phys,
		"sim_day": sim_day_phys,
		"world_seed": world_seed_phys,
		"axial_tilt_deg": profile.axial_tilt_deg if profile != null else 23.5,
		# orchestrator 控制标志
		"heat_transport": heat_transport,
		"solve_ocean": true,
		"terrain_aware": (1 if terrain_aware else 0),
		# SLP
		"smooth_passes": 1,
		"prev_slp_arr": prev_slp,
		"slp_lat_amp": 0.16,
		"slp_land_amp": 0.55,
		"slp_water_damp": 0.20,
		"slp_interior_boost": 1.30,
		"slp_coast_damp": 0.60,
		"slp_target_p95": 0.18,
		"insolation_daylen_amp": profile.insolation_daylen_amp if profile != null else 0.35,
		# wind
		"land_lf_mountain": int(LandformType.LF.MOUNTAIN),
		"land_lf_peak": int(LandformType.LF.PEAK),
		"land_lf_hill": int(LandformType.LF.HILL),
		"wind_elapsed_days": baker._phys_take_wind_elapsed_days(sim_day_phys),
		# PSI
		"psi_total_iters": baker._PHYS_PSI_TOTAL_ITERS,
		"psi_warm_start": bool(profile.psi_warm_start) if profile != null and profile.get("psi_warm_start") != null else true,
		"psi_early_exit_mode": str(profile.psi_early_exit_mode) if profile != null and profile.get("psi_early_exit_mode") != null else "perf",
		"psi_sor_omega": 1.4,
		"psi_r_base": 0.18,
		"psi_beta_floor": 0.05,
		"psi_source_scale": float(profile.ocean_psi_source_scale) if profile != null and profile.get("ocean_psi_source_scale") != null else 0.06,
		"ocean_current_scale": float(profile.ocean_current_scale) if profile != null and profile.get("ocean_current_scale") != null else 0.13,
		"ocean_current_max_magnitude": float(profile.ocean_current_max_magnitude) if profile != null and profile.get("ocean_current_max_magnitude") != null else 0.65,
		"thermohaline_weight": 0.12,
		"upwelling_highlat_abs": 0.75,
		"cold_sink_temp": cold_sink_temp,
		# upwelling
		"stage": "upwelling",
	}
	if profile != null:
		# SLP profile knobs
		knobs["wind_thermal_slp_weight"] = profile.wind_thermal_slp_weight
		knobs["slp_ice_high_weight"] = profile.slp_ice_high_weight
		knobs["slp_snow_high_weight"] = profile.slp_snow_high_weight
		knobs["slp_response_rate"] = profile.slp_response_rate
		knobs["slp_synoptic_amp"] = profile.slp_synoptic_amp
		knobs["slp_moist_low_weight"] = profile.slp_moist_low_weight
		knobs["wind_synoptic_period_days"] = profile.wind_synoptic_period_days
		# wind profile knobs
		knobs["wind_response_rate"] = profile.wind_response_rate
		knobs["wind_max_turn_deg_per_day"] = profile.wind_max_turn_deg_per_day
		knobs["wind_min_flux_for_dir_update"] = profile.wind_min_flux_for_dir_update
		knobs["wind_synoptic_amp"] = profile.wind_synoptic_amp
		knobs["wind_belt_only_debug"] = profile.wind_belt_only_debug
		# PSI profile knobs
		knobs["ocean_current_response_rate"] = profile.ocean_current_response_rate
		knobs["ocean_thermal_current_weight"] = profile.ocean_thermal_current_weight
		knobs["ocean_density_cold_weight"] = profile.ocean_density_cold_weight
		knobs["ocean_density_ice_weight"] = profile.ocean_density_ice_weight

	# refresh slot 缓存，确保 kernel 读到最新 map 状态（镜像 upwelling stage 的 refresh_slots_from_map）。
	if baker._world_ext.has_method("refresh_slots_from_map"):
		baker._world_ext.refresh_slots_from_map()
	var rep: Dictionary = baker._world_ext.run_physical_solve_pass(knobs)
	if rep == null or typeof(rep) != TYPE_DICTIONARY or bool(rep.get("fallback", true)):
		if baker._phys_solve_rt_diag_count < 24:
			baker._phys_solve_rt_diag_count += 1
			print("[phys_solve][oneshot] fallback reason=%s → 回退 step_one loop" % (
				String(rep.get("reason", "?")) if rep != null and typeof(rep) == TYPE_DICTIONARY else "null"))
		return false

	# NaN/Inf 守门（复刻 WIND_RASTER stage）：异常时回退 loop（其内含 ny-only 覆写）。
	if baker._world_ext.has_method("phys_field_nan_guard"):
		var n_bad: int = int(baker._world_ext.phys_field_nan_guard())
		if n_bad > 0:
			push_warning("[phys_solve][oneshot] phys_field_nan_guard=%d → 回退 step_one loop（含 NaN 覆写）" % n_bad)
			return false

	print("[phys_solve][oneshot] OK slp=%.2fms wind=%.2fms psi=%.2fms(ran=%s) upwelling=%.2fms total=%.2fms" % [
		float(rep.get("slp_ms", -1.0)), float(rep.get("wind_ms", -1.0)),
		float(rep.get("psi_ms", -1.0)), str(bool(rep.get("psi_ran", false))),
		float(rep.get("upwelling_ms", -1.0)), float(rep.get("elapsed_ms", -1.0))])
	return true

# 确保 _pending_wind_buf 已按 W×H×2 字节就位（PackedByteArray 不在 size 一致时
# 强制重分配，避免 GC 压力）。WIND_RASTER 阶段的第一次 step 调一次。

static func _ensure_pending_wind_size(baker: MapBaker, world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var need: int = W * H * 2
	if baker._pending_wind_buf.size() != need:
		baker._pending_wind_buf = PackedByteArray()
		baker._pending_wind_buf.resize(need)

# 把 cell.wind_vector 量化进区间 [s, e)（按像素索引）。s 必须是非负，e ≤ W*H。
# 用 pixel_to_cell_lookup 直接查最近 hex，无 cube_round 成本。
# wind_vector 是单位方向；RG8 写入 dir * wind_speed_norm，让 shader length() 表示风速。
# L: 同 ocean_current_slice，同步写持久 _vector_atlas_data 的 BA 通道（[idx*4+2, idx*4+3]）。

static func _rasterize_wind_slice_from_hex(baker: MapBaker, world: WorldData, buf: PackedByteArray,
		s: int, e: int) -> void:
	if buf.is_empty() or s >= e:
		return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var lookup: Array = world.pixel_to_cell_lookup
	var has_lookup: bool = lookup.size() == W * H
	var atlas_valid: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == W * H * 4)
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		var wx: float = 1.0
		var wy: float = 0.0
		if cell != null:
			var wind_speed_norm: float = clampf(cell.wind_speed / 1.7, 0.0, 1.0)
			wx = cell.wind_vector.x * wind_speed_norm
			wy = cell.wind_vector.y * wind_speed_norm
		var bx: int = clampi(int(round((wx * 0.5 + 0.5) * 255.0)), 0, 255)
		var by: int = clampi(int(round((wy * 0.5 + 0.5) * 255.0)), 0, 255)
		buf[i * 2]     = bx
		buf[i * 2 + 1] = by
		if atlas_valid:
			baker._vector_atlas_data[i * 4 + 2] = bx
			baker._vector_atlas_data[i * 4 + 3] = by

# 一次性版本（bake_world / rebake_ocean_currents 用）：直接全图写入 _pending_wind_buf
# 并返回它。等价于多次调 _rasterize_wind_slice_from_hex 拼成全图。

static func _rasterize_wind_field_from_hex(baker: MapBaker, map: MapData, world: WorldData) -> PackedByteArray:
	baker._ensure_pending_wind_size(world)
	var W := world.derived_size.x
	var H := world.derived_size.y
	baker._rasterize_wind_slice_from_hex(world, baker._pending_wind_buf, 0, W * H)
	return baker._pending_wind_buf

# L: 从 world.ocean_current_buffer / wind_field_buffer 一次性拼出 RGBA8 交错缓冲。
# fallback 路径（缓存未就绪）的 commit 末尾调一次，让下一次 commit 走 fast path。
# 之后 pixel slices 在写 _pending_currents_buf / _pending_wind_buf 时同步维护此 buf。

static func _rebuild_vector_atlas_data_from_buffers(baker: MapBaker, world: WorldData) -> void:
	if world == null:
		return
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	var need: int = n * 4
	if baker._vector_atlas_data.size() != need:
		baker._vector_atlas_data = PackedByteArray()
		baker._vector_atlas_data.resize(need)
	baker._vector_atlas_data_size = Vector2i(W, H)
	var ocean_buf: PackedByteArray = world.ocean_current_buffer
	var wind_buf: PackedByteArray = world.wind_field_buffer
	var has_ocean: bool = ocean_buf.size() >= n * 2
	var has_wind: bool = wind_buf.size() >= n * 2
	for i in range(n):
		var di: int = i * 4
		var oi: int = i * 2
		baker._vector_atlas_data[di]     = ocean_buf[oi]     if has_ocean else 128
		baker._vector_atlas_data[di + 1] = ocean_buf[oi + 1] if has_ocean else 128
		baker._vector_atlas_data[di + 2] = wind_buf[oi]      if has_wind else 128
		baker._vector_atlas_data[di + 3] = wind_buf[oi + 1]  if has_wind else 128

# 把 cell.ocean_current 量化进 RG8 像素区间 [s, e)。陆地像素填中性 (128, 128) = 零向量。
# L: 同步把 RG 写到持久 _vector_atlas_data 的 [idx*4, idx*4+1] 通道（若 size 已就绪），
# 让 commit_ocean_buffers 直接 Image.create_from_data(_vector_atlas_data) + tex.update，
# 省掉 620k × 4 字节的全图交错循环（30-50ms → memcpy）。

static func _rasterize_ocean_current_slice_from_hex(baker: MapBaker, world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	var lookup: Array = world.pixel_to_cell_lookup
	var W := world.derived_size.x
	var H := world.derived_size.y
	var has_lookup: bool = lookup.size() == W * H
	var atlas_valid: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == W * H * 4)
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		var cur_x: float = 0.0
		var cur_y: float = 0.0
		if cell != null and baker._is_water(int(cell.terrain)):
			cur_x = cell.ocean_current.x
			cur_y = cell.ocean_current.y
		var bx: int = clampi(int(round((cur_x * 0.5 + 0.5) * 255.0)), 0, 255)
		var by: int = clampi(int(round((cur_y * 0.5 + 0.5) * 255.0)), 0, 255)
		dst[i * 2]     = bx
		dst[i * 2 + 1] = by
		if atlas_valid:
			baker._vector_atlas_data[i * 4]     = bx
			baker._vector_atlas_data[i * 4 + 1] = by

# 把 cell.upwelling_strength 量化进 R8 像素区间 [s, e)。陆地填 128（中性）。
# 编码：strength ∈ [-1, 1] → byte ∈ [0, 255]，128 = 0；255 = +1（满上升）；0 = -1（满下沉）。
# 与现有 _bake_ocean_upwelling 的编码契约一致（虽然旧路径只用 [128, 255] 半区上升 +
# [0, 128] 半区下沉，新路径继续遵守）。

static func _rasterize_upwelling_slice_from_hex(baker: MapBaker, world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	var lookup: Array = world.pixel_to_cell_lookup
	var W := world.derived_size.x
	var H := world.derived_size.y
	var has_lookup: bool = lookup.size() == W * H
	for i in range(s, e):
		var cell: HexCell = null
		if has_lookup:
			cell = lookup[i]
		if cell == null or not baker._is_water(int(cell.terrain)):
			dst[i] = 128
			continue
		var up: float = clampf(cell.upwelling_strength, -1.0, 1.0)
		dst[i] = clampi(int(round(128.0 + 127.0 * up)), 0, 255)


# ─── DOTS-Total-CPP（plan/dots-total-cpp 任务 4+5）────────────────────────
# Ocean rasterize 一次性 hex→pixel byte 直出 — 替代 _rasterize_ocean_current_slice_from_hex
# + _rasterize_upwelling_slice_from_hex 的 17 个 pixel slice。
	# Gate：caller 已确认 ext + has_method (use_gdext_ocean_currents_pixel removed in dots-flag-prune-pr1).

# 缓存 ocean rasterize 的 pixel→cell-index 表（与 sea_ice 缓存独立）。

static func _ensure_ocean_pixel_to_cell_index(baker: MapBaker, map: MapData, world: WorldData) -> void:
	var n: int = int(world.derived_size.x) * int(world.derived_size.y)
	if baker._ocean_pixel_cache_size == world.derived_size and baker._ocean_pixel_to_cell_idx.size() == n:
		return
	baker._ocean_pixel_to_cell_idx = PackedInt32Array()
	baker._ocean_pixel_to_cell_idx.resize(n)
	var lookup := world.pixel_to_cell_lookup
	for i in range(n):
		var cell = lookup[i] if i < lookup.size() else null
		baker._ocean_pixel_to_cell_idx[i] = map.index_of(cell) if cell != null else -1
	baker._ocean_pixel_cache_size = world.derived_size


# 一次性把 ocean_current + upwelling SoA 通过 C++ rasterize 量化进
# _pending_currents_buf / _pending_upwelling_buf / _vector_atlas_data。
#
# Sub-slice 支持（plan/ocean-raster-subslice 2026-05-22）：
#   p_start_idx / p_end_idx 缺省 -1 表示"全图一次性"（旧行为）。
#   传入 [s, e) 时仅 raster 该像素区间，配合 OceanCurrentsJob 的多 sub-tick 切片。
#   首片（s==0）做 _ensure_pending_* / refresh_slots_from_map（O(1) check + 一次性
#   slot sync）；后续 sub-slice 跳过这两步，靠 caller 维持 buffer 一致。
# 返回 Dictionary：{ "fallback": bool, "elapsed_ms": float, "pixels": int,
#                  "atlas_updated": bool, "start_idx": int, "end_idx": int }

static func run_ocean_field_rasterize_full(baker: MapBaker, map: MapData, world: WorldData, _cfg: MapConfig,
		p_start_idx: int = -1, p_end_idx: int = -1) -> Dictionary:
	var out := { "fallback": true, "elapsed_ms": -1.0, "pixels": 0, "atlas_updated": false }
	if world == null or map == null:
		out["reason"] = "missing world/map"
		return out
	if baker._world_ext == null:
		out["reason"] = "ext/method missing"
		return out
	# 必须先把 hex 求解推到 DONE — caller 已通过 _physical_solve_step_one 完成。
	# pending_currents / pending_upwelling 缓冲就绪
	baker._ensure_pending_currents_size(world)
	baker._ensure_pending_upwelling_size(world)
	baker._ensure_ocean_pixel_to_cell_index(map, world)

	var W := int(world.derived_size.x)
	var H := int(world.derived_size.y)
	var n_px: int = W * H

	# 解析 sub-slice 区间。负数 / 越界 → 全图。
	var s: int = p_start_idx
	var e: int = p_end_idx
	if s < 0:
		s = 0
	if e < 0 or e > n_px:
		e = n_px
	if s > e:
		s = e
	var is_first_subslice: bool = (s == 0)

	# 同步 DataCoreWorld slots（HexCell facade 已直写 SoA，但保险起见 refresh）
	# 仅首片做：sub-slice 中途 SoA 不应再变（_phase_locked 已固定，hex 求解已 DONE）
	if is_first_subslice:
		baker._world_ext.refresh_slots_from_map()

	# atlas_data fast path：若 _vector_atlas_data 已就位，让 C++ 同步写入
	var atlas_ok: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == n_px * 4)
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"w": W,
		"h": H,
		"pixel_to_cell_idx": baker._ocean_pixel_to_cell_idx,
		"dst_currents": baker._pending_currents_buf,
		"dst_upwelling": baker._pending_upwelling_buf,
		"update_atlas_data": atlas_ok,
		"start_idx": s,
		"end_idx": e,
	}
	if atlas_ok:
		knobs["atlas_data"] = baker._vector_atlas_data
	if not baker._runtime_physics_visual_view.is_empty():
		knobs["physics_read_view"] = baker._runtime_physics_visual_view
	var res: Dictionary = baker._world_ext.run_ocean_field_rasterize(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		out["reason"] = String(res.get("reason", "unknown"))
		return out
	# C++ 端通过 ptrw 已修改 PackedByteArray；Dictionary 共享 ref，赋值即同步。
	baker._pending_currents_buf = knobs["dst_currents"]
	baker._pending_upwelling_buf = knobs["dst_upwelling"]
	if atlas_ok:
		baker._vector_atlas_data = knobs["atlas_data"]
	out["fallback"] = false
	out["elapsed_ms"] = float(res.get("elapsed_ms", 0.0))
	out["pixels"] = int(res.get("pixels", 0))
	out["atlas_updated"] = bool(res.get("atlas_updated", false))
	out["start_idx"] = int(res.get("start_idx", s))
	out["end_idx"] = int(res.get("end_idx", e))
	return out


# ─── DOTS-Total-CPP（A 方案 / wind raster 孪生）─────────────────────────
# Wind rasterize 一次性 hex→pixel byte 直出 — 替代 _rasterize_wind_slice_from_hex
# 在 _PHYS_STAGE_WIND_RASTER 中跑 21 片 × ~87ms 的 GDScript 循环。
# 复用 _ocean_pixel_to_cell_idx 缓存（同一 pixel→cell 映射）。
#
	# Gate：caller 已确认 ext + has_method (use_gdext_ocean_currents_pixel removed in dots-flag-prune-pr1).
# 返回 Dictionary：{ "fallback": bool, "elapsed_ms": float, "pixels": int, "atlas_updated": bool }

static func run_wind_field_rasterize_full(baker: MapBaker, map: MapData, world: WorldData, _cfg: MapConfig) -> Dictionary:
	var out := { "fallback": true, "elapsed_ms": -1.0, "pixels": 0, "atlas_updated": false }
	if world == null or map == null:
		out["reason"] = "missing world/map"
		return out
	if baker._world_ext == null:
		out["reason"] = "ext/method missing"
		return out
	# pending_wind 缓冲就绪
	baker._ensure_pending_wind_size(world)
	# pixel→cell idx 表（与 ocean rasterize 共用同一张表）
	baker._ensure_ocean_pixel_to_cell_index(map, world)

	# 同步 DataCoreWorld slots（HexCell facade 已直写 SoA，但保险起见 refresh）
	baker._world_ext.refresh_slots_from_map()

	var W := int(world.derived_size.x)
	var H := int(world.derived_size.y)
	var n_px: int = W * H
	# atlas_data fast path：若 _vector_atlas_data 已就位，让 C++ 同步写 [+2]/[+3]
	var atlas_ok: bool = (baker._vector_atlas_data_size == Vector2i(W, H) \
			and baker._vector_atlas_data.size() == n_px * 4)
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"w": W,
		"h": H,
		"pixel_to_cell_idx": baker._ocean_pixel_to_cell_idx,
		"dst_wind": baker._pending_wind_buf,
		"update_atlas_data": atlas_ok,
	}
	if atlas_ok:
		knobs["atlas_data"] = baker._vector_atlas_data
	if not baker._runtime_physics_visual_view.is_empty():
		knobs["physics_read_view"] = baker._runtime_physics_visual_view
	var res: Dictionary = baker._world_ext.run_wind_field_rasterize(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		out["reason"] = String(res.get("reason", "unknown"))
		return out
	# C++ 端通过 ptrw 已修改 PackedByteArray；Dictionary 共享 ref，赋值即同步。
	baker._pending_wind_buf = knobs["dst_wind"]
	if atlas_ok:
		baker._vector_atlas_data = knobs["atlas_data"]
	out["fallback"] = false
	out["elapsed_ms"] = float(res.get("elapsed_ms", 0.0))
	out["pixels"] = int(res.get("pixels", 0))
	out["atlas_updated"] = bool(res.get("atlas_updated", false))
	return out
