extends "res://scripts/simulation/generator_context.gd"
class_name DCSeaIceDailyPass

## Sea-ice native dispatch. MapGenerator remains the owner of timing, terrain
## flips, state-machine cursors, and all diagnostic buffers.

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null:
		return
	_apply_sea_ice_daily_pass(map, season_phase)

func _apply_sea_ice_daily_pass(map: MapData, season_phase: float) -> void:
	if map == null or _generator._last_cfg == null:
		return
	var cp: ClimateProfile = _generator._c()
	if cp == null:
		return

	var t_total_us: int = Time.get_ticks_usec()
	var t0: int = Time.get_ticks_msec()
	var k_freeze: float = float(cp.sea_ice_freeze_rate)
	var k_melt: float = float(cp.sea_ice_melt_rate)
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var contagion: float = float(cp.sea_ice_neighbor_contagion)
	var threshold: float = float(cp.sea_ice_terrain_threshold)
	var hysteresis: float = float(cp.sea_ice_terrain_hysteresis)
	var ice_delay: float = float(_generator._last_cfg.OCEAN_CURRENT_ICE_DELAY)

	# ─── map-visual-overhaul-v1：climate_anomaly 联动（极区可见缩水） ──────────
	# climate_anomaly > 0 → 长期升温 → 海冰冻结/融化阈值同步下调 → 极地白圈缩水。
	# 等价于"温度抬升 anomaly_strength * climate_anomaly"，但走阈值下调更安全
	# （不污染 SoA temp_arr / cell.temperature），且对 GDExt C++ 路径透明
	# （C++ 端接收的 t_form/t_melt 已带偏移）。系数 0.10 实测：
	#   climate_anomaly = +0.20 → 阈值下调 0.02 → 极地白圈缩约 1-2 hex 圈
	#   climate_anomaly = -0.20 → 阈值上调 0.02 → 中纬冬季冰扩约 1 hex 圈
	# 区间内对玩家明显可见但不至于剧烈跳变。
	var sea_ice_climate_anomaly_strength: float = 0.10
	var climate_anomaly_now: float = 0.0
	if _generator._world_clock_ref != null:
		var ca_v = _generator._world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = sea_ice_climate_anomaly_strength * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)

	# ─── [S2 fix 2026-05-23] dt_days 补偿 ──────────────────────────────
	# 详见 _consume_sea_ice_dt_days()。本函数是 daily_climate_refresh 非 sliced
	# 整轮路径 / fallback 路径；状态机 sliced 路径在 _begin_sea_ice_state_machine
	# 同样调用 _consume_sea_ice_dt_days，两路径互斥（同 tick 只命中一条）。
	var dt_days: float = _generator._consume_sea_ice_dt_days()

	# ─── Phase F.4：DCWorldExt C++ 快路径（charter §7 P2，5.1ms → 0.5ms）─
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_sea_ice flag 已删，现走 ext +
	# has_method 探测。触发条件：
	#   1. _data_core_world_ext 已 bind
	#   2. fast_indexed（neighbor_indices_packed 完整 + has_indices）
	#   3. C++ 端 has run_sea_ice_daily_pass 且返回 ≥ 0
	# 任意一条不满足 → 报告 native failure，不再进入 GDScript 计算循环。
	#
	# 设计：terrain 翻转**不**在 C++ 端写——C++ 只算 fraction 增量 + 收集 flip
	# 候选列表，由 GDScript 端遍历列表调 cell.apply_terrain 维护 multi-axis 同步
	# （passable_land / passable_sea / landform 等派生字段）。这是 charter §2.5
	# STRUCT-001 反模式规避：C++ 不直接改 multi-axis enum。
	var cells_fast: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_fast: int = cells_fast.size()
	var nb_idx_fast: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = nb_idx_fast.size() >= n_cells_fast * 6

	if not _generator._gdext_sea_ice_first_attempt_logged:
		_generator._gdext_sea_ice_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_sea_ice flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path = cp.resource_path
		var ext_ok: bool = _generator._data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _generator._data_core_world_ext.has_method("run_sea_ice_daily_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL → fall through to GDScript path"
		print("[sea_ice/F.4] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_sea_ice = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_sea_ice_daily_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells_fast * 6, nb_idx_fast.size()])
		print("  verdict = %s" % verdict)

	if _generator._data_core_world_ext != null \
			and _generator._data_core_world_ext.has_method("run_sea_ice_daily_pass") and fast_indexed:
		# Stale .dll probe（一次/session）
		if not _generator._gdext_sea_ice_signature_checked:
			_generator._gdext_sea_ice_signature_checked = true
			_generator._gdext_sea_ice_signature_ok = _generator._validate_gdext_method_signature("run_sea_ice_daily_pass", 2)
			print("[sea_ice/F.4] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_generator._gdext_sea_ice_signature_ok))

		# Build per-tick PackedArray 输入：尽量走 SoA/cache，避免从 HexCell facade
		# 逐格打包。sea_ice C++ native 只有几十微秒，热成本主要在这里。
		#
		# 性能修复（2026-05-18）：实测 pack=0.9ms vs native=0.025ms（36×）。
		# 原因是 base_terrain_arr / TTA 都在 SoA（map_data.gd:102, 142），但旧代码
		# 仍逐 cell 打包。现按 temp_input 同款策略：先看 SoA 是否已就绪，再用
		# fallback 私有 buffer。base_terrain 运行时不会变（sea_ice 翻转只动 terrain
		# 不动 base_terrain），可以直接引用；TTA 优先用 ocean pass 同 round 留下的
		# cached buffer（更新鲜），其次回 SoA，最后才逐 cell 打包。
		var t_pack_us: int = Time.get_ticks_usec()
		# base_terrain：SoA 是权威源（见 map_data.gd:397，pull_packed_arrays_from_cells
		# 在生成期 / 加载存档时写一次；运行时 sea_ice 翻 terrain 不动 base_terrain）。
		var base_terrain_input: PackedByteArray
		if map.base_terrain_arr.size() == n_cells_fast:
			base_terrain_input = map.base_terrain_arr
		else:
			if _generator._gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
				_generator._gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
			base_terrain_input = _generator._gdext_sea_ice_base_terrain_buf
			for i_build in range(n_cells_fast):
				var c_build: HexCell = cells_fast[i_build]
				_generator._gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
		# TTA：优先 ocean pass cached（同 round 最新），其次 SoA，最后 fallback。
		var tta_input: PackedFloat32Array
		if _generator._gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
			tta_input = _generator._gdext_ocean_anomaly_buf_cached
		elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
			tta_input = map.temperature_transport_anomaly_arr
		else:
			if _generator._gdext_sea_ice_tta_buf.size() != n_cells_fast:
				_generator._gdext_sea_ice_tta_buf.resize(n_cells_fast)
			tta_input = _generator._gdext_sea_ice_tta_buf
			for i_tta in range(n_cells_fast):
				tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
		var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
				if map.upwelling_strength_arr.size() == n_cells_fast \
				else _generator._gdext_sea_ice_upw_buf
		if upw_input.size() != n_cells_fast:
			_generator._gdext_sea_ice_upw_buf.resize(n_cells_fast)
			upw_input = _generator._gdext_sea_ice_upw_buf
			for i_upw in range(n_cells_fast):
				upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
		var temp_input: PackedFloat32Array = map.temp_arr \
				if map.temp_arr.size() == n_cells_fast \
				else _generator._gdext_sea_ice_temp_buf
		if temp_input.size() != n_cells_fast:
			_generator._gdext_sea_ice_temp_buf.resize(n_cells_fast)
			temp_input = _generator._gdext_sea_ice_temp_buf
			for i_temp in range(n_cells_fast):
				temp_input[i_temp] = cells_fast[i_temp].temperature
		var insol_input: PackedFloat32Array = _generator._sea_ice_insolation_input(map, cells_fast, season_phase)
		var pack_ms: float = (Time.get_ticks_usec() - t_pack_us) / 1000.0

		# water_terrain_ids 与 _is_water 1:1 对齐（line 3090+）：
		# OCEAN / COAST / LAKE / REEF / KELP / SEA_ICE 共 6 种。
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
			"enable_ocean_heat_transport": bool(_generator._last_cfg.enable_ocean_heat_transport),
			"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
			"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
			"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
			"water_terrain_ids": water_ids,
			"neighbor_indices": nb_idx_fast,
			"base_terrain_arr": base_terrain_input,
			"temp_transport_anomaly": tta_input,
			"upwelling_strength": upw_input,
			"insolation_now_arr": insol_input,
			"solar_gate_enabled": _generator._sea_ice_solar_gate_enabled(cp),
			"freeze_insol_low": float(cp.sea_ice_freeze_insol_low),
			"freeze_insol_high": float(cp.sea_ice_freeze_insol_high),
			"solar_melt_start": float(cp.sea_ice_solar_melt_start),
			"solar_melt_gain": float(cp.sea_ice_solar_melt_gain),
			"min_thick_ice_solar_exposure": float(cp.sea_ice_min_thick_ice_solar_exposure) if cp.get("sea_ice_min_thick_ice_solar_exposure") != null else 0.32,
			"daily_delta_cap": float(cp.sea_ice_daily_delta_cap) if cp.get("sea_ice_daily_delta_cap") != null else 0.070,
			"edge_mix_rate": float(cp.sea_ice_edge_mix_rate) if cp.get("sea_ice_edge_mix_rate") != null else 0.035,
			"cell_temperature_arr": temp_input,
		}
		# storage A/B 同源契约（修复 B 2026-05-14；详见 docs/architecture/migration.md）：
		# GDScript pass_a 写 map.temp_arr / 上一段 sub-pass 写 map.*_arr 后，C++ slot
		# 仍指向 CoW 解耦前的旧 buffer。先 refresh 让 C++ 读到 GDScript 端最新状态。
		# 开销 ~14μs / 35 component（map_data->get + Variant 类型分发），可接受；
		# 后续 Phase 2.1 GDScript 改走 world.write_f32_indexed 后可移除。
		# refresh-consolidation-2026-06：走 climate daily round 守门员。
		# 同 round 内若 pass_a/B/ocean 已 refresh 过则跳过；refresh_ms 仅记录真实
		# refresh 那次的耗时，否则保持 0。
		var refresh_ms: float = 0.0
		if _generator._data_core_world_ext.has_method("refresh_slots_from_map") and not _generator._climate_daily_round_slots_fresh:
			var t_refresh_us: int = Time.get_ticks_usec()
			_generator._ensure_climate_daily_round_slots_fresh()
			refresh_ms = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
		else:
			_generator._ensure_climate_daily_round_slots_fresh()  # may skip
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_sea_ice_daily_pass，C++ 内部根据 CPU 特性 / n_cells 自动选择
		# scalar / SIMD / threaded 三档执行路径。
		var _sea_ice_dispatch_path: String = "scalar"
		var t_native_us: int = Time.get_ticks_usec()
		var rc: float = float(_generator._data_core_world_ext.run_sea_ice_daily_pass(knobs, season_phase))
		if rc < 0.0 and _generator._data_core_world_ext.has_method("run_sea_ice_daily_pass_thread"):
			_sea_ice_dispatch_path = "thread_fallback"
			rc = float(_generator._data_core_world_ext.run_sea_ice_daily_pass_thread(knobs, season_phase, 4))
		var native_wall_ms: float = (Time.get_ticks_usec() - t_native_us) / 1000.0
		# Plan-C full-map diagnostics were removed from this hot path. Slow-path
		# breakdown logging below is retained and uses already-collected timings.
		if _generator._gdext_sea_ice_runs + _generator._gdext_sea_ice_fallbacks < 3:
			print("[sea_ice/F.4] DEBUG call#%d: path=%s rc=%.4f n_cells=%d enable_oht=%s" % [
				_generator._gdext_sea_ice_runs + _generator._gdext_sea_ice_fallbacks + 1,
				_sea_ice_dispatch_path, rc, n_cells_fast, str(_generator._last_cfg.enable_ocean_heat_transport),
			])
		if rc >= 0.0:
			# C++ 已写 DCWorldExt cell_sea_ice_frac slot 并 flush 回 MapData。
			# 这里还需要同步 GDScript DCWorld 的 dirty mask，供 dynamic atlas 消费。
			# 旧实现逐 cell 走 HexCell setter，会触发 2400 次 write_f32/dirty mark；
			# 改为 dense 批量写，复用 value-diff，仅真实变化的 cell 标 dirty。
			var t_sync_us: int = Time.get_ticks_usec()
			var facade_on: bool = false
			if n_cells_fast > 0 and cells_fast[0] != null:
				var c0_sync: HexCell = cells_fast[0] as HexCell
				facade_on = c0_sync != null and c0_sync.is_facade_enabled()
			var sync_done_dense: bool = false
			if facade_on and _generator._data_core_world != null \
					and _generator._data_core_world.has_method("write_f32_dense") \
					and map.sea_ice_frac_arr.size() >= n_cells_fast:
				var _cid_si_dense: int = _generator._data_core_world.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)
				if _cid_si_dense >= 0:
					_generator._data_core_world.write_f32_dense(_cid_si_dense, map.sea_ice_frac_arr)
					sync_done_dense = true
			if not sync_done_dense:
				for i_sync in range(n_cells_fast):
					var c_sync: HexCell = cells_fast[i_sync]
					c_sync.sea_ice_fraction = map.sea_ice_frac_arr[i_sync]
			var sync_ms: float = (Time.get_ticks_usec() - t_sync_us) / 1000.0

			# 应用 flip 列表
			# 2026-05-19 plan-c 修复：apply_terrain 只写 GDScript HexCell.terrain（裸 var），
			# 不会同步到 map.terrain_arr。下次 sea_ice pass 调用 refresh_slots_from_map 时，
			# C++ s_terrain.arr_u8 会从 map.terrain_arr 拿到 bake 时的旧 OCEAN，导致：
			#   1) was_ice 永远 false → flip_to_base_list 永远空 → 冰永远翻不回 OCEAN
			#   2) 已 flip 的 cell 被 C++ 重判为 "non-ice 且 sif>=thr" → 重复加入 flip_to_ice
			# 修复：apply 同步写 map.terrain_arr，让 C++ 下一帧看到最新 terrain。
			# 开销：flip_list 通常 <300，O(n) 写入 ~几 μs，可忽略。
			var t_flip_us: int = Time.get_ticks_usec()
			var flip_to_ice_list: PackedInt32Array = knobs.get("flip_to_ice_list", PackedInt32Array())
			var flip_to_base_list: PackedInt32Array = knobs.get("flip_to_base_list", PackedInt32Array())
			var flip_to_base_terrain: PackedByteArray = knobs.get("flip_to_base_terrain", PackedByteArray())
			var flip_batch: Dictionary = _generator._build_sea_ice_flip_batch(flip_to_ice_list, flip_to_base_list, flip_to_base_terrain)
			var flip_diag: Dictionary = _generator._apply_sea_ice_terrain_flips_indexed(
					map,
					flip_batch.get("indices", PackedInt32Array()),
					flip_batch.get("terrain", PackedByteArray()),
					true)
			if not bool(flip_diag.get("applied", false)):
				var _sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
				for i_flip in range(flip_to_ice_list.size()):
					var idx_i: int = flip_to_ice_list[i_flip]
					if idx_i >= 0 and idx_i < n_cells_fast:
						var fast_cell_i: HexCell = map.cell_at(idx_i)
						if fast_cell_i != null:
							_generator._set_cell_runtime_terrain(map, fast_cell_i, _sea_ice_id, true, -1.0, fast_cell_i.snow_cover)
				for i_back in range(flip_to_base_list.size()):
					var idx_b: int = flip_to_base_list[i_back]
					if idx_b >= 0 and idx_b < n_cells_fast and i_back < flip_to_base_terrain.size():
						var target_terr: int = int(flip_to_base_terrain[i_back])
						var fast_cell_b: HexCell = map.cell_at(idx_b)
						if fast_cell_b != null:
							_generator._set_cell_runtime_terrain(map, fast_cell_b, target_terr, true, -1.0, fast_cell_b.snow_cover)
				_generator._write_runtime_enum_axes_dense(map)
			var flip_ms: float = (Time.get_ticks_usec() - t_flip_us) / 1000.0

			var water_count_cpp: int = int(knobs.get("stat_water_count", 0))
			var flipped_count_cpp: int = int(knobs.get("stat_flipped_count", 0))

			# QA 异常守卫（与 GDScript 路径一致）
			if water_count_cpp > 0:
				var ratio: float = float(flipped_count_cpp) / float(water_count_cpp)
				if ratio > 0.03:
					push_warning("[sea_ice_daily/F.4] %d/%d (%.1f%%) cells flipped on phase=%.3f — possible bulk-switch regression" % [
						flipped_count_cpp, water_count_cpp, ratio * 100.0, season_phase
					])

			_generator._gdext_sea_ice_runs += 1
			_generator._gdext_sea_ice_total_ms += rc
			if _generator._gdext_sea_ice_runs == 1:
				print("[sea_ice/F.4] gdext path ACTIVE (dispatch=%s) — first run elapsed=%.2fms (legacy GDScript baseline ≈ 5.1ms; charter §7 target < 0.5ms)" % [_sea_ice_dispatch_path, rc])

			# 节流打点（每个日历年长）
			if _generator._is_annual_log_tick(_generator._diagnostics_bus.get_climate_call_count()):
				print("_apply_sea_ice_daily_pass[F.4]: %.2fms (water=%d, flipped=%d, phase=%.3f)" % [
					rc, water_count_cpp, flipped_count_cpp, season_phase
				])
				# [DIAG 2026-05-23] 海冰不动排障：统计水体 cell 的温度分布与 SIF 分布。
				# 关键问题：t_eff 是否真的有 < t_form？SIF 是否在涨但没到 threshold？
				# 用 temp_input（与 C++ 端读的同一份）+ map.sea_ice_frac_arr（C++ 已 flush）。
				var _diag_t_form: float = t_form          # 已带 climate_anomaly 偏移
				var _diag_t_melt: float = t_melt
				var _diag_thr: float = threshold
				var _diag_n: int = n_cells_fast
				var _diag_water: int = 0
				var _diag_below_form: int = 0     # t_eff < t_form
				var _diag_sif_pos: int = 0        # SIF > 0.01
				var _diag_sif_near_thr: int = 0   # SIF ∈ [thr*0.5, thr)
				var _diag_t_min: float = 9.99
				var _diag_t_max: float = -9.99
				var _diag_t_sum: float = 0.0
				var _diag_t_min_water: float = 9.99    # 仅水体
				var _diag_sif_max: float = 0.0
				var _diag_sif_sum: float = 0.0
				var _terrain_arr_diag: PackedByteArray = map.terrain_arr
				var _sif_arr_diag: PackedFloat32Array = map.sea_ice_frac_arr
				var _temp_n: int = temp_input.size()
				var _sif_n: int = _sif_arr_diag.size()
				for _i_diag in range(_diag_n):
					var _t_d: float = temp_input[_i_diag] if _i_diag < _temp_n else 0.0
					if _t_d < _diag_t_min: _diag_t_min = _t_d
					if _t_d > _diag_t_max: _diag_t_max = _t_d
					_diag_t_sum += _t_d
					var _terr_d: int = int(_terrain_arr_diag[_i_diag]) if _i_diag < _terrain_arr_diag.size() else -1
					var _is_w: bool = (_terr_d == int(TerrainType.TERRAIN.OCEAN) \
						or _terr_d == int(TerrainType.TERRAIN.COAST) \
						or _terr_d == int(TerrainType.TERRAIN.REEF) \
						or _terr_d == int(TerrainType.TERRAIN.KELP) \
						or _terr_d == int(TerrainType.TERRAIN.SEA_ICE))
					if _is_w:
						_diag_water += 1
						if _t_d < _diag_t_min_water: _diag_t_min_water = _t_d
						if _t_d < _diag_t_form: _diag_below_form += 1
						var _sf_d: float = _sif_arr_diag[_i_diag] if _i_diag < _sif_n else 0.0
						_diag_sif_sum += _sf_d
						if _sf_d > _diag_sif_max: _diag_sif_max = _sf_d
						if _sf_d > 0.01: _diag_sif_pos += 1
						if _sf_d >= _diag_thr * 0.5 and _sf_d < _diag_thr: _diag_sif_near_thr += 1
				var _avg_t: float = _diag_t_sum / max(1, _diag_n)
				var _avg_sif_w: float = _diag_sif_sum / max(1, _diag_water)
				print("[sea_ice/DIAG] thr_eff t_form=%.3f t_melt=%.3f flip_thr=%.3f | temp all min=%.3f max=%.3f avg=%.3f | water n=%d t_min_w=%.3f below_form=%d (%.1f%%) | SIF pos=%d max=%.3f avg_w=%.4f near_thr=%d | climate_anom=%.3f" % [
					_diag_t_form, _diag_t_melt, _diag_thr,
					_diag_t_min, _diag_t_max, _avg_t,
					_diag_water, _diag_t_min_water,
					_diag_below_form, 100.0 * float(_diag_below_form) / max(1, _diag_water),
					_diag_sif_pos, _diag_sif_max, _avg_sif_w, _diag_sif_near_thr,
					climate_anomaly_now,
				])
			_generator._last_sea_ice_daily_breakdown = {
				"path": "gdext",
				"pack_ms": pack_ms,
				"refresh_ms": refresh_ms,
				"native_ms": rc,
				"native_wall_ms": native_wall_ms,
				"sync_ms": sync_ms,
				"flip_ms": flip_ms,
				"terrain_flip_path": "indexed" if bool(flip_diag.get("applied", false)) else "legacy_set_cell_runtime_terrain",
				"terrain_flip_count": int(flip_diag.get("count", 0)),
				"terrain_flip_fallback_reason": str(flip_diag.get("fallback_reason", "")),
				"total_wall_ms": (Time.get_ticks_usec() - t_total_us) / 1000.0,
				"water": water_count_cpp,
				"flipped": flipped_count_cpp,
			}
			# 方案 ① Step 1：≥ 5ms 强制打印（节流），确诊 7ms 走的是哪条路径
			_generator._dump_sea_ice_breakdown_if_slow()
			_generator._gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
			return
	_generator._gdext_sea_ice_fallbacks += 1
	push_error("[sea_ice_daily] native failed: run_sea_ice_daily_pass returned failure; previous fields retained")
	return

	push_error("[sea_ice_daily] native failed: extension, method, or indexed neighbors unavailable; previous sea-ice fields retained")
	return
