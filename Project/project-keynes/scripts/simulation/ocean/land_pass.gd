extends "res://scripts/simulation/generator_context.gd"
class_name DCOceanLandPass

## Ocean land native dispatch and sliced execution. Water/land ordering and
## every mutable buffer remain owned by MapGenerator.

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null or map == null:
		return
	_ocean_land_pass_legacy(map, season_phase)

func _ocean_land_pass_legacy(map: MapData, season_phase: float) -> void:
	if _generator._last_cfg == null:
		push_error("[ocean/land] native failed: missing map config; previous fields retained")
		return
	var cp: ClimateProfile = _generator._c()
	if cp == null or map == null or not map.has_soa():
		push_error("[ocean/land] native failed: SoA map unavailable; previous fields retained")
		return
	_ocean_land_pass_soa(map, season_phase, cp)


func _ocean_land_pass_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：同 _climate_pass_a_soa 的 TODO。
	# 仅保留 C++ dispatch；GDScript 计算回退已退休。
	var coast_leak: float = _generator._last_cfg.COASTAL_HEAT_LEAK
	var winter_boost: float = 1.0
	var effective_leak: float = coast_leak * winter_boost
	var tta: Dictionary = _generator._temperature_transport_anomaly_knobs(cp)
	var tta_source_cap: float = float(tta["tta_source_cap"])
	var tta_blend_rate: float = float(tta["tta_blend_rate"])
	var tta_decay_rate: float = float(tta["tta_decay_rate"])

	# DataCore（climate-datacore-migration A-4）：取数入口分支化（Ocean Land）
	var _dc_views: Dictionary = _generator._climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	var n: int = map.soa_size()
	var cells: Array[HexCell] = map.iter_cells()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()

	# ─── Phase F.2b：DCWorldExt C++ 快路径（charter §7 P1，3.4ms → < 0.5ms）──
	# 与 water pass 同模板。anomaly_inout 是 [n] 浮点 in/out buffer：water pass
	# 已写好 water cell 的 anomaly（如果 water pass 也走 C++，直接复用 cached
	# buffer 省一次 cells→array 拷贝）；land pass 写每个 land cell 的 anomaly。
	if not _generator._gdext_ocean_land_first_attempt_logged:
		_generator._gdext_ocean_land_first_attempt_logged = true
		var cp_path_l: String = "<in-memory>"
		var flag_l: bool = true  # use_gdext_ocean_land flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path_l = cp.resource_path
		var ext_l_ok: bool = _generator._data_core_world_ext != null
		var has_l_ok: bool = ext_l_ok and _generator._data_core_world_ext.has_method("run_ocean_land_pass")
		var fast_l_ok: bool = nb_idx.size() >= n * 6
		var verdict_l: String = "OK → will try C++"
		if not (flag_l and ext_l_ok and has_l_ok and fast_l_ok):
			verdict_l = "FAIL → fall through to GDScript"
		print("[ocean_land/F.2b] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path_l)
		print("  cp.use_gdext_ocean_land = %s (flag removed; constant true)" % str(flag_l))
		print("  _data_core_world_ext != null = %s" % str(ext_l_ok))
		print("  ext.has_method('run_ocean_land_pass') = %s" % str(has_l_ok))
		print("  fast_indexed = %s (n=%d nb=%d)" % [str(fast_l_ok), n, nb_idx.size()])
		print("  effective_leak=%.4f (coast_leak=%.4f winter_boost=%.4f)" % [effective_leak, coast_leak, winter_boost])
		print("  verdict = %s" % verdict_l)

	if cp != null and _generator._data_core_world_ext != null \
			and _generator._data_core_world_ext.has_method("run_ocean_land_pass") and nb_idx.size() >= n * 6:
		if not _generator._gdext_ocean_land_signature_checked:
			_generator._gdext_ocean_land_signature_checked = true
			_generator._gdext_ocean_land_signature_ok = _generator._validate_gdext_method_signature("run_ocean_land_pass", 1)
			print("[ocean_land/F.2b] sig probe result = %s（仅作诊断）" % str(_generator._gdext_ocean_land_signature_ok))
		# 准备 anomaly_inout：优先复用 water pass 已 cache 的 buffer；否则从
		# cells 拷出（water pass 走 GDScript 时也兼容）。
		var anomaly_io: PackedFloat32Array
		if _generator._gdext_ocean_anomaly_buf_cached.size() == n:
			anomaly_io = _generator._gdext_ocean_anomaly_buf_cached
		else:
			anomaly_io = PackedFloat32Array()
			anomaly_io.resize(n)
			for ai in range(n):
				anomaly_io[ai] = float(cells[ai].temperature_transport_anomaly)
		# 准备 fallback_baseline_arr：优先复用 water pass cache；否则现场重算
		# （ema_init 分支 + _compute_temperature 兜底，与 GDScript 原版对齐）
		var fallback_baseline_arr: PackedFloat32Array
		if _generator._gdext_ocean_baseline_arr_cached.size() == n:
			fallback_baseline_arr = _generator._gdext_ocean_baseline_arr_cached
		else:
			fallback_baseline_arr = PackedFloat32Array()
			fallback_baseline_arr.resize(n)
			var temp_baseline_a_l: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
			var elev_a_l: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
			var lat_a_l: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
			var ema_init_a_l: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr
			for bi in range(n):
				if ema_init_a_l[bi] != 0:
					fallback_baseline_arr[bi] = temp_baseline_a_l[bi]
				else:
					var ny_b: float = lat_a_l[bi] if lat_a_l.size() > bi else _generator._cube_row_norm(cells[bi], _generator._last_cfg)
					fallback_baseline_arr[bi] = _generator._compute_temperature(ny_b, elev_a_l[bi])
		# 准备 ocean_current x/y：优先复用 water pass cache；否则从 cells 提取
		var ocx_arr_l: PackedFloat32Array
		var ocy_arr_l: PackedFloat32Array
		if _generator._gdext_ocean_current_x_arr_cached.size() == n and _generator._gdext_ocean_current_y_arr_cached.size() == n:
			ocx_arr_l = _generator._gdext_ocean_current_x_arr_cached
			ocy_arr_l = _generator._gdext_ocean_current_y_arr_cached
		else:
			ocx_arr_l = PackedFloat32Array()
			ocy_arr_l = PackedFloat32Array()
			ocx_arr_l.resize(n)
			ocy_arr_l.resize(n)
			for ci2 in range(n):
				var cci: HexCell = cells[ci2]
				ocx_arr_l[ci2] = cci.ocean_current.x
				ocy_arr_l[ci2] = cci.ocean_current.y
		var knobs_l: Dictionary = {
			"n_cells": n,
			"effective_leak": effective_leak,
			"neighbor_indices": nb_idx,
			"anomaly_inout": anomaly_io,
			"fallback_baseline_arr": fallback_baseline_arr,
			"ocean_current_x_arr": ocx_arr_l,
			"ocean_current_y_arr": ocy_arr_l,
		}
		_generator._apply_temperature_transport_anomaly_knobs(knobs_l, _generator._temperature_transport_anomaly_knobs(cp))
		# storage A/B 同源契约（修复 B 2026-05-14）：ocean_water 已 flush 到 map，
		# refresh 让本 pass C++ slot 看到最新海洋温度修正。详见 docs/architecture/migration.md。
		# refresh-consolidation-2026-06：climate_daily round 守门员；ocean_water→ocean_land
		# 的跨 pass mark stale 由 climate_daily_system._run_pass 负责。
		_generator._ensure_climate_daily_round_slots_fresh()
		# ─── sim-2ms-perf-push（plan/ocean-water-land-simd）派发 ─────────────
		# dots-flag-prune-pr1 round 2: use_gdext_ocean_land_simd / use_gdext_thread_fallback
		# flag 均已删除——恒走 C++ scalar 入口 run_ocean_land_pass，C++ 内部根据 CPU
		# 特性 / n_cells 自动选择 scalar / SIMD / threaded 三档执行路径。
		var _l_dispatch_path: String = "scalar"
		var rc_l: float = float(_generator._data_core_world_ext.run_ocean_land_pass(knobs_l))
		if rc_l < 0.0 and _generator._data_core_world_ext.has_method("run_ocean_land_pass_thread"):
			_l_dispatch_path = "thread_fallback"
			rc_l = float(_generator._data_core_world_ext.run_ocean_land_pass_thread(knobs_l, 4))
		if _generator._gdext_ocean_land_runs + _generator._gdext_ocean_land_fallbacks < 3:
			print("[ocean_land/F.2b] DEBUG call#%d: path=%s rc=%.4f n=%d effective_leak=%.4f" % [
				_generator._gdext_ocean_land_runs + _generator._gdext_ocean_land_fallbacks + 1,
				_l_dispatch_path, rc_l, n, effective_leak,
			])
		if rc_l >= 0.0:
			# §11 CoW fix: C++ 创建了新的 anomaly 数组并写回了 knobs Dictionary。
			# 必须从 dict 重新读取。
			anomaly_io = knobs_l["anomaly_inout"]
			# Bugfix 2026-05-17（overlay 洋流热输运全白）：
			# water pass 走 C++ 路径时刻意省略了 HexCell.temperature_transport_anomaly
			# 的回写（注释说 "land pass 会直接复用该 buffer，并在下一片统一回写"），
			# 但原回写循环只覆盖 land cell（is_water_l[ci]==0），导致水域 cell
			# 的 anomaly 永远停留在 HexCell 默认值 0.0。DataOverlayBaker 读
			# cell.temperature_transport_anomaly 后归一化为 value=0.5，shader 用
			# ramp_diverging 渲染为中性灰（≈白），表现为"洋流热输运 overlay 全白"。
			# anomaly_io 在进入 land pass 时复用 water pass cache（含水域 anomaly）
			# 且 land pass C++ 只写 land cell；这里把水陆两部分一起 flush 回 HexCell，
			# 与 GDScript 完整路径保持一致（line 5089 / 5177）。
			map.temperature_transport_anomaly_arr = anomaly_io
			if _generator._data_core_world != null:
				var _cid_tta_dense: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
				if _cid_tta_dense >= 0 and _generator._data_core_world.has_method("write_f32_dense"):
					_generator._data_core_world.write_f32_dense(_cid_tta_dense, anomaly_io)
			var _tta_facade_on: bool = n > 0 and cells[0] != null and (cells[0] as HexCell).is_facade_enabled()
			if not _tta_facade_on:
				for ci in range(n):
					cells[ci].temperature_transport_anomaly = anomaly_io[ci]
			# anomaly 继续保留给同轮 sea_ice，避免 sea_ice 再从 HexCell 打包 TTA。
			_generator._gdext_ocean_anomaly_buf_cached = anomaly_io
			_generator._gdext_ocean_baseline_arr_cached = PackedFloat32Array()
			_generator._gdext_ocean_current_x_arr_cached = PackedFloat32Array()
			_generator._gdext_ocean_current_y_arr_cached = PackedFloat32Array()
			_generator._gdext_ocean_land_runs += 1
			_generator._gdext_ocean_land_total_ms += rc_l
			if _generator._gdext_ocean_land_runs == 1:
				print("[ocean_land/F.2b] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 3.4ms; charter §7 target < 0.5ms)" % rc_l)
			return
		_generator._gdext_ocean_land_fallbacks += 1
		# rc<0：fall through 到 GDScript 完整路径
	push_error("[ocean/land] native failed: run_ocean_land_pass unavailable or returned failure; previous fields retained")
	return


func run_ocean_land_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	return _generator.run_climate_pass_slice(_generator._CLIMATE_PASS_OCEAN_LAND, map, season_phase)



func _run_ocean_land_pass_slice_impl(map: MapData, season_phase: float, token: int = 0) -> Dictionary:
	var cp: ClimateProfile = _generator._c()
	if _generator._climate_ocean_slice_state.is_empty() \
			or int(_generator._climate_ocean_slice_state.get("map_id", -1)) != map.get_instance_id():
		if not _generator._begin_ocean_heat_transport_sliced(map, season_phase, cp):
			return _generator._run_climate_pass_legacy_fallback(_generator._CLIMATE_PASS_OCEAN_LAND, map, season_phase, token, "native_unavailable")
	var n: int = int(_generator._climate_ocean_slice_state.get("n", 0))
	var start: int = int(_generator._climate_ocean_slice_state.get("land_cursor", 0))
	var end: int = mini(n, start + _generator._ocean_slice_budget_cells())
	var knobs: Dictionary = _generator._climate_ocean_slice_state["land_knobs"]
	knobs["start_idx"] = start
	knobs["end_idx"] = end
	var rc: float = float(_generator._data_core_world_ext.run_ocean_land_pass(knobs))
	if rc < 0.0:
		_generator._climate_ocean_slice_state.clear()
		_generator._climate_pass_states.erase(_generator._CLIMATE_PASS_OCEAN_LAND)
		return _generator._run_climate_pass_legacy_fallback(_generator._CLIMATE_PASS_OCEAN_LAND, map, season_phase, token, "native_failed")
	var anomaly: PackedFloat32Array = knobs["anomaly_inout"]
	_generator._climate_ocean_slice_state["anomaly"] = anomaly
	_generator._climate_ocean_slice_state["land_cursor"] = end
	var done: bool = end >= n
	if _generator._climate_pass_states.has(_generator._CLIMATE_PASS_OCEAN_LAND):
		var state: Dictionary = _generator._climate_pass_states[_generator._CLIMATE_PASS_OCEAN_LAND]
		state["land_cursor"] = end
		state["cursor_start"] = start
		state["cursor_end"] = end
		state["processed_cells"] = end - start
		state["status"] = _generator._CLIMATE_PASS_STATUS_DONE if done else _generator._CLIMATE_PASS_STATUS_RUNNING
		_generator._climate_pass_states[_generator._CLIMATE_PASS_OCEAN_LAND] = state
	# Incremental publish (climate-pipeline-spike-reduction)：每片都把当前 anomaly
	# 推到 map / DCWorld dense buffer。read 方 (weather/field_solver/feedback) 始
	# 终能拿到「已计算部分新值 + 未计算部分上一片旧值」的合并视图，避免在 ocean_land
	# 整轮跨多帧时洋流热输运彻底冻结。逐 cell HexCell 回写代价较大，仅在 done 时
	# 执行（且只对 facade-off 路径，新代码默认 facade-on）。
	map.temperature_transport_anomaly_arr = anomaly
	if _generator._data_core_world != null:
		var _cid_tta_dense: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_dense >= 0 and _generator._data_core_world.has_method("write_f32_dense"):
			_generator._data_core_world.write_f32_dense(_cid_tta_dense, anomaly)
	_generator._gdext_ocean_anomaly_buf_cached = anomaly
	# A2 增量回写 HexCell.temperature_transport_anomaly：land 阶段对 [start, end)
	# 内的陆格 anomaly 做了更新（水格保留 water 阶段值），区间外保留上一片旧值。
	# 与 water 阶段对称，让 baker / info_panel 在 budget=2ms 节奏下也能逐片看到
	# 渐进合并视图，避免「洋流热输运一直白」的现象。done 分支额外做的全图回写
	# 保留作为兜底（应对极端 reset 后某片尚未触达的格子）。
	var _cells_inc_l: Array = _generator._climate_ocean_slice_state.get("cells", [])
	if _cells_inc_l.size() == n:
		for _ci_l in range(start, end):
			var _c_l = _cells_inc_l[_ci_l]
			if _c_l != null:
				_c_l.temperature_transport_anomaly = anomaly[_ci_l]
	if done:
		var cells: Array = _generator._climate_ocean_slice_state.get("cells", [])
		# 兜底全图回写：确保任何因为 reset / cells 数组变更等原因未被增量段覆盖到的
		# 格子在 round 末尾拿到最新 anomaly。即使 facade 化后 (cell.temperature_
		# transport_anomaly 走 SoA) 这次冗余写也无害——facade getter/setter 不存在
		# 时这段就是唯一的最终回写。
		if n > 0 and cells.size() == n:
			for ci in range(n):
				var _cf = cells[ci]
				if _cf != null:
					_cf.temperature_transport_anomaly = anomaly[ci]
		_generator._gdext_ocean_baseline_arr_cached = PackedFloat32Array()
		_generator._gdext_ocean_current_x_arr_cached = PackedFloat32Array()
		_generator._gdext_ocean_current_y_arr_cached = PackedFloat32Array()
		_generator._climate_ocean_slice_state.clear()
		_generator._climate_pass_states.erase(_generator._CLIMATE_PASS_OCEAN_LAND)
	return _generator._make_climate_pass_result(_generator._CLIMATE_PASS_OCEAN_LAND, done, rc, end - start, start, end, _generator._CLIMATE_PASS_STATUS_DONE if done else _generator._CLIMATE_PASS_STATUS_RUNNING, token, "ocean_land")

# ─── Milestone 3：天气子系统每日推进 ────────────────────────────────────
# 由 main.gd 的 _on_day_changed 触发。流程：
#   1) WeatherSystem.tick_one_day：advect 现有 front + spawn 新 front + 写 cell.current_state.weather/intensity
#   2) 同时把 weather 的 moisture/temp 扰动叠加到 current_state.moisture/temperature（不改 base_*）
#   3) 必要时改写 cell.cover（BLIZZARD → SNOW、STORM/MONSOON 低地 → FLOODING）
#   4) 不重烘焙任何 tex（视觉层 weather overlay 走 shader uniform 数组路径，零 tex 上传）
# 返回当前活跃 front 列表，main 拿去喂 renderer。
