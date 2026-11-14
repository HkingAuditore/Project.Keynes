extends "res://scripts/simulation/generator_context.gd"
class_name DCTranspirationPass

## Transpiration native dispatch. The generator retains all counters, slots,
## scratch arrays, and synchronization helpers.

func _init(generator) -> void:
	_generator = generator

func run(map: MapData) -> void:
	if _generator == null:
		return
	_apply_transpiration_pass(map)

func run_native(map: MapData) -> Dictionary:
	if _generator == null:
		return {}
	return run_transpiration_pass_native(map)

func run_transpiration_pass_native(map: MapData) -> Dictionary:
	var t_wall_us: int = Time.get_ticks_usec()
	var n_cells: int = map.cell_count() if map != null else 0
	if map == null:
		return _generator._make_transpiration_native_unavailable("missing_map", t_wall_us, n_cells)
	var cp_f5: ClimateProfile = _generator._c()
	if cp_f5 == null:
		return _generator._make_transpiration_native_unavailable("missing_climate_profile", t_wall_us, n_cells)
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = n_cells > 0 and neighbor_indices.size() >= n_cells * 6
	if not _generator._gdext_transp_first_attempt_logged:
		_generator._gdext_transp_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		if cp_f5.resource_path != "":
			cp_path = cp_f5.resource_path
		var ext_ok: bool = _generator._data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _generator._data_core_world_ext.has_method("run_transpiration_pass")
		var verdict: String = "OK -> will try C++"
		if not (ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL -> fall through to GDScript sliced path"
		print("[transp/F.5] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_transpiration = true (flag removed; constant true)")
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_transpiration_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells * 6, neighbor_indices.size()])
		print("  verdict = %s" % verdict)
	if _generator._data_core_world_ext == null or not _generator._data_core_world_ext.has_method("run_transpiration_pass"):
		return _generator._make_transpiration_native_unavailable("native_unavailable", t_wall_us, n_cells)
	if not fast_indexed:
		return _generator._make_transpiration_native_unavailable("missing_neighbor_indices", t_wall_us, n_cells)
	if not _generator._gdext_transp_signature_checked:
		_generator._gdext_transp_signature_checked = true
		_generator._gdext_transp_signature_ok = _generator._validate_gdext_method_signature("run_transpiration_pass", 1)
		print("[transp/F.5] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_generator._gdext_transp_signature_ok))
	var donor_table: PackedFloat32Array = _generator._build_transpiration_donor_table()
	var knobs: Dictionary = {
		"n_cells": n_cells,
		"outflow_rate": float(cp_f5.transpiration_outflow_rate),
		"self_rate": float(cp_f5.transpiration_self_rate),
		"neighbor_indices": neighbor_indices,
		"donor_table": donor_table,
	}
	var refresh_ms: float = 0.0
	# refresh-consolidation-2026-06：climate_daily round 守门员。仅当未在本 round
	# 内 refresh 过时才计时，避免 skip 路径误报 refresh_ms。
	if _generator._data_core_world_ext.has_method("refresh_slots_from_map") and not _generator._climate_daily_round_slots_fresh:
		var t_refresh_us: int = Time.get_ticks_usec()
		_generator._ensure_climate_daily_round_slots_fresh()
		refresh_ms = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
	else:
		_generator._ensure_climate_daily_round_slots_fresh()  # may skip
	var t_native_us: int = Time.get_ticks_usec()
	var rc: float = float(_generator._data_core_world_ext.run_transpiration_pass(knobs))
	var native_call_ms: float = (Time.get_ticks_usec() - t_native_us) / 1000.0
	if _generator._gdext_transp_runs + _generator._gdext_transp_fallbacks < 3:
		print("[transp/F.5] DEBUG call#%d: rc=%.4f donor_table.size()=%d n_cells=%d outflow=%.4f self=%.4f" % [
			_generator._gdext_transp_runs + _generator._gdext_transp_fallbacks + 1,
			rc, donor_table.size(), n_cells,
			float(cp_f5.transpiration_outflow_rate),
			float(cp_f5.transpiration_self_rate),
		])
	if rc < 0.0:
		_generator._gdext_transp_fallbacks += 1
		return _generator._make_transpiration_native_unavailable("native_failed", t_wall_us, n_cells)
	var dirty_indices: PackedInt32Array = knobs.get("dirty_indices", PackedInt32Array())
	var dirty_values: PackedFloat32Array = knobs.get("dirty_values", PackedFloat32Array())
	var sync_diag: Dictionary = _generator._sync_transpiration_native_outputs(map, dirty_indices, dirty_values)
	_generator._gdext_transp_runs += 1
	_generator._gdext_transp_total_ms += rc
	if _generator._gdext_transp_runs == 1:
		print("[transp/F.5] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript sliced hotspot now bypassed)" % rc)
	var elapsed_ms: float = (Time.get_ticks_usec() - t_wall_us) / 1000.0
	var result: Dictionary = _generator._make_climate_pass_result("transp", true, elapsed_ms, n_cells, 0, n_cells,
			_generator._CLIMATE_PASS_STATUS_DONE, 0, "native")
	var sync_total_ms: float = float(sync_diag.get("sync_total_ms", 0.0))
	var dominant_substage: String = "native"
	var dominant_ms: float = rc
	if refresh_ms > dominant_ms:
		dominant_ms = refresh_ms
		dominant_substage = "refresh"
	if sync_total_ms > dominant_ms:
		dominant_ms = sync_total_ms
		dominant_substage = "sync"
	result["path"] = "gdext"
	result["native_ms"] = rc
	result["native_call_ms"] = native_call_ms
	result["native_compute_ms"] = float(knobs.get("compute_ms", 0.0))
	result["native_apply_ms"] = float(knobs.get("apply_ms", 0.0))
	result["native_flush_ms"] = float(knobs.get("flush_ms", 0.0))
	result["refresh_ms"] = refresh_ms
	result["sync_ms"] = sync_total_ms
	result["sync_total_ms"] = sync_total_ms
	result["sync_write_ms"] = float(sync_diag.get("sync_write_ms", 0.0))
	result["sync_mark_ms"] = float(sync_diag.get("sync_mark_ms", 0.0))
	result["sync_path"] = str(sync_diag.get("sync_path", ""))
	result["substage"] = dominant_substage
	result["diagnostic_wall_ms"] = elapsed_ms
	result["dirty_count"] = int(knobs.get("dirty_count", dirty_indices.size()))
	result["cursor_remaining"] = 0
	result["next_stage"] = "done"
	return result



func _apply_transpiration_pass(map: MapData) -> void:
	# 阶段 1：算每 cell 的"输出额"（不立刻写）
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = neighbor_indices.size() >= n_cells * 6

	# ─── Phase F.5：DCWorldExt C++ 快路径（charter §7 P2，3.2ms → 0.3ms）─
	# 触发条件：
	#   1. ClimateProfile.use_gdext_transpiration == true
	#   2. _data_core_world_ext 已 bind（class_exists("DCWorldExt") && bind_map_data 成功）
	#   3. fast_indexed（neighbor_indices_packed 完整）
	#   4. C++ 端 run_transpiration_pass 返回 ≥ 0
	# 任意一条不满足 → 报告 native failure，不再进入 GDScript 计算循环。
	#
	# 与 F.1 同模板：单 shot 全图，写直接落 cell_moisture SoA。GDScript 一侧 cell.moisture
	# = soa[i] 已经在 fastpath HexCell typed fields 路径下生效（main.gd 启动日志
	# `[fastpath] HexCell typed fields active (SoA)`），所以 C++ 写 SoA 等价于 GDScript
	# 写 cell.moisture，不需要再做一次 cell.moisture = ... 兜底。
	var cp_f5: ClimateProfile = _generator._c()
	# F.5 无脑首次诊断：在做任何条件检查之前，把 5 个 precondition 的真实值 +
	# 当前 ClimateProfile 资源路径全部打印一次。这样"flag 表面 true 实际 false"
	# 类隐藏 bug（编辑了错的 .tres / 改了 inspector 但没保存 / @export 资源被
	# 别的实例覆盖）能一眼看穿，不需要在 if 嵌套深处反复加 print 排查。
	if not _generator._gdext_transp_first_attempt_logged:
		_generator._gdext_transp_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_transpiration flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp_f5 != null and cp_f5.resource_path != "":
			cp_path = cp_f5.resource_path
		var ext_ok: bool = _generator._data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _generator._data_core_world_ext.has_method("run_transpiration_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL → fall through to GDScript path"
		print("[transp/F.5] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_transpiration = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_transpiration_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells * 6, neighbor_indices.size()])
		print("  verdict = %s" % verdict)
	if cp_f5 != null and _generator._data_core_world_ext != null \
			and _generator._data_core_world_ext.has_method("run_transpiration_pass") and fast_indexed:
		# Stale .dll probe（一次/session）：先无脑跑一次（带详细诊断 print），
		# 但即使 probe 判 false 也不阻止下面的 C++ 调用——避免 strict equality
		# 在某些 godot-cpp 版本误判把好的 .dll 也拒了。stale .dll 的真正信号是
		# rc=0.0 + console "Invalid call ... Expected N argument(s)"。
		if not _generator._gdext_transp_signature_checked:
			_generator._gdext_transp_signature_checked = true
			_generator._gdext_transp_signature_ok = _generator._validate_gdext_method_signature("run_transpiration_pass", 1)
			print("[transp/F.5] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_generator._gdext_transp_signature_ok))
		var donor_table: PackedFloat32Array = _generator._build_transpiration_donor_table()
		var knobs: Dictionary = {
			"n_cells": n_cells,
			"outflow_rate": float(cp_f5.transpiration_outflow_rate),
			"self_rate": float(cp_f5.transpiration_self_rate),
			"neighbor_indices": neighbor_indices,
			"donor_table": donor_table,
		}
		# storage A/B 同源契约（修复 B 2026-05-14）：sea_ice 已 flush 到 map，
		# refresh 让本 pass 读 cell.moisture / cell.weather_precip 等取得最新值。
		# 详见 docs/architecture/migration.md。
		if _generator._data_core_world_ext.has_method("refresh_slots_from_map"):
			_generator._data_core_world_ext.refresh_slots_from_map()
		var rc: float = float(_generator._data_core_world_ext.run_transpiration_pass(knobs))
		# 强制无脑诊断：前 3 次调用无论 rc 多少都打一行（含 donor_table 长度），
		# 让 stale-dll / silent-fallback / 隐藏 -1.0 一类 bug 没法藏。
		if _generator._gdext_transp_runs + _generator._gdext_transp_fallbacks < 3:
			print("[transp/F.5] DEBUG call#%d: rc=%.4f donor_table.size()=%d n_cells=%d outflow=%.4f self=%.4f" % [
				_generator._gdext_transp_runs + _generator._gdext_transp_fallbacks + 1,
				rc, donor_table.size(), n_cells,
				float(cp_f5.transpiration_outflow_rate),
				float(cp_f5.transpiration_self_rate),
			])
		if rc >= 0.0:
			# C++ 完成全量写到 SoA cell_moisture。fastpath 模式下 cell.moisture
			# 是 SoA alias，无需再回写。
			_generator._gdext_transp_runs += 1
			_generator._gdext_transp_total_ms += rc
			if _generator._gdext_transp_runs == 1:
				print("[transp/F.5] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 3.2ms; charter §7 target < 0.3ms)" % rc)
			return
		_generator._gdext_transp_fallbacks += 1
		# rc<0：C++ 已 push_warning；继续 fall through 到 GDScript 双 phase 循环

	push_error("[transpiration] native failed: extension, method, or indexed neighbors unavailable; previous moisture fields retained")
	return
