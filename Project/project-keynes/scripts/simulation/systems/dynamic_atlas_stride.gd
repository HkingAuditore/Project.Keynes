extends RefCounted

## Builds and advances each atlas update's texture stages.


static func _start_new_stride(owner: DynamicVisualAtlasUploadSystem) -> void:
	owner._phase = owner.PHASE_DYNAMIC
	owner._phase_cursor = 0
	owner._phase_cells = owner.map.all_cells()
	owner._phase_ctx = {}
	owner._phase_report = {}
	owner._total_ticks_used = 0
	owner._aggregated_report = {
		"dynamic_dirty_cells": 0,
		"dynamic_ms": 0.0,
		"ecology_dirty_cells": 0,
		"ecology_ms": 0.0,
		"smooth_dirty_cells": 0,
		"smooth_ms": 0.0,
		"ice_dirty_cells": 0,
		"ice_ms": 0.0,
		"dynamic_prepare_ms": 0.0,
		"dynamic_step_ms": 0.0,
		"dynamic_finalize_ms": 0.0,
		"dynamic_cells_considered": 0,
		"dynamic_pixels_written": 0,
		"dynamic_cpp_calls": 0,
		"dynamic_gd_calls": 0,
		"dynamic_empty_calls": 0,
		"ecology_prepare_ms": 0.0,
		"ecology_step_ms": 0.0,
		"ecology_finalize_ms": 0.0,
		"ecology_cells_considered": 0,
		"ecology_pixels_written": 0,
		"ecology_cpp_calls": 0,
		"ecology_gd_calls": 0,
		"ecology_empty_calls": 0,
		"smooth_prepare_ms": 0.0,
		"smooth_step_ms": 0.0,
		"smooth_finalize_ms": 0.0,
		"smooth_cells_considered": 0,
		"smooth_pixels_written": 0,
		"smooth_cpp_calls": 0,
		"smooth_gd_calls": 0,
		"smooth_empty_calls": 0,
		"ice_prepare_ms": 0.0,
		"ice_step_ms": 0.0,
		"ice_finalize_ms": 0.0,
		"ice_cells_considered": 0,
		"ice_pixels_written": 0,
		"ice_cpp_calls": 0,
		"ice_gd_calls": 0,
		"ice_empty_calls": 0,
		"dirty_reason": "",
		"dirty_source": "",
		"dirty_mask_available": false,
		"dirty_noop": false,
		"_cells_scanned_this_tick": 0,
	}
	# plan/dirty-push-atlas-encode 阶段 D：原子读 + 清零 mask，反查 cell 列表。
	# 单线程 SUS 调度保证 read_and_clear 的原子性（priority 100-200 的 sim 已写完，
	# 250 的 atlas upload 是唯一消费者）。
	owner._stride_dirty_indices = PackedInt32Array()
	owner._stride_dirty_cells = []
	owner._stride_dirty_path_used = false
	owner._stride_dirty_noop = false
	owner._stride_dirty_reason = ""
	if not owner._is_dirty_push_enabled():
		owner._stride_dirty_reason = "flag_disabled"
		owner._aggregated_report["dirty_reason"] = owner._stride_dirty_reason
		return
	var dirty_source = owner.dirty_world if owner.dirty_world != null else owner.world_data
	owner._aggregated_report["dirty_source"] = "dirty_world" if owner.dirty_world != null else "world_data"
	if dirty_source == null or not dirty_source.has_method("read_and_clear_dirty_mask"):
		owner._stride_dirty_reason = "read_and_clear_missing"
		owner._aggregated_report["dirty_reason"] = owner._stride_dirty_reason
		return
	if dirty_source.has_method("dirty_mask_size") and int(dirty_source.dirty_mask_size()) <= 0:
		owner._stride_dirty_reason = "dirty_mask_size_zero"
		owner._aggregated_report["dirty_reason"] = owner._stride_dirty_reason
		return
	owner._aggregated_report["dirty_mask_available"] = true
	var dirty: PackedInt32Array = dirty_source.read_and_clear_dirty_mask()
	owner._stride_dirty_path_used = true
	# [DIAG mask_dirty=2400 排查 · 2026-05-20] 仅前 8 次 stride + 之后每 30 stride 打一次
	if owner._dvas_diag_stride_count < 8 or (owner._dvas_diag_stride_count % 30) == 0:
		var _src_tag: String = "dirty_world" if owner.dirty_world != null else "world_data"
		var _mask_size_dump: int = -1
		if dirty_source.has_method("dirty_mask_size"):
			_mask_size_dump = int(dirty_source.dirty_mask_size())
		print("[DIAG atlas_upload] stride#%d source=%s mask_size=%d dirty_count=%d" % [
			owner._dvas_diag_stride_count, _src_tag, _mask_size_dump, dirty.size(),
		])
	if dirty.size() <= 0:
		owner._stride_dirty_noop = true
		owner._stride_dirty_reason = "no_dirty"
		owner._aggregated_report["dirty_reason"] = owner._stride_dirty_reason
		owner._aggregated_report["dirty_noop"] = true
		return
	owner._stride_dirty_indices = dirty
	owner._stride_dirty_reason = "dirty"
	owner._aggregated_report["dirty_reason"] = owner._stride_dirty_reason
	owner._aggregated_report["dirty_noop"] = false
	# 反查 HexCell：MapData.cell_by_index(idx) 是 O(1) 数组下标。
	owner._stride_dirty_cells.resize(dirty.size())
	var n: int = dirty.size()
	for i in range(n):
		var idx: int = dirty[i]
		var c: HexCell = owner.map.cell_at(idx)
		owner._stride_dirty_cells[i] = c   # 允许 null（mask 越界容错；下游会过滤）


# plan/dirty-push-atlas-encode 阶段 D 私有 helper：
# dots-flag-prune-pr1 round 2: dirty_push_enabled flag 已删除——恒走 mask 路径。
# climate_profile 与 dirty mask 逻辑无关，dirty_source 是否实现 read_and_clear_dirty_mask
# 由下游调用点探测。本 helper 仅作为后兼容保留，恒返 true。
static func _is_dirty_push_enabled(owner: DynamicVisualAtlasUploadSystem) -> bool:
	return true


# plan/dirty-push-atlas-encode 阶段 F 私有 helper：
# 是否启用 C++ atlas encode pass。要求：
#   1. world_data 有 _world_ext 引用且非 null（DCWorld bind 后注入）
#   2. ext 实现了对应 encode_* 方法（向前兼容旧版本 GDExtension dll）
# 任一不满足都返回 false → 自动 fallback 到 GDScript mask 路径。
#
# dots-flag-prune-pr1 round 2: cpp_atlas_encode_enabled flag 已删除——恒走 ext +
# has_method 探测分支（ext 未提供对应 encode_* method 时透明回退）。
static func _should_use_ext_encode(owner: DynamicVisualAtlasUploadSystem, method_name: StringName) -> bool:
	if owner.baker != null and owner.baker.has_method("_cpp_atlas_encode_active"):
		return bool(owner.baker.call("_cpp_atlas_encode_active", method_name))
	if owner.world_data == null:
		return false
	# DCWorld 在 bind_world 时把 ext 引用挂到 _world_ext / _ext 等字段；
	# 走 .get() 反射拿，避免对 DCWorld 内部实现强耦合。
	var ext = owner.world_data.get("_world_ext")
	if ext == null:
		ext = owner.world_data.get("_ext")
	if ext == null:
		return false
	return ext.has_method(method_name)



static func _chunk_size_limit_for_baker(owner: DynamicVisualAtlasUploadSystem, baker_key: String) -> int:
	var method_name: StringName
	match baker_key:
		"dynamic_cell_atlas":
			method_name = &"encode_dynamic_cell_atlas"
		"ecology_visual_atlas":
			method_name = &"encode_ecology_visual_atlas"
		"dyn_atlas_smooth":
			method_name = &"encode_dyn_smooth_atlas"
		"ice_state_atlas":
			method_name = &"encode_ice_state_atlas"
		_:
			return owner.TIME_CHECK_CELLS_PER_STEP
	if owner._should_use_ext_encode(method_name):
		return owner.CPP_TIME_CHECK_CELLS_PER_STEP
	return owner.TIME_CHECK_CELLS_PER_STEP


# 推进当前 phase；返回 true 表示当前 phase 已完成（finalize 已调用），可切下一 phase。
# remaining_budget 是本 tick 还能扫多少 cell。
static func _advance_current_phase(owner: DynamicVisualAtlasUploadSystem, remaining_budget: int, deadline_us: int) -> bool:
	match owner._phase:
		owner.PHASE_DYNAMIC:
			return owner._step_phase_baker(remaining_budget, "dynamic_cell_atlas",
					"dynamic_dirty_cells", "dynamic_ms", "dynamic", deadline_us)
		owner.PHASE_ECOLOGY:
			return owner._step_phase_baker(remaining_budget, "ecology_visual_atlas",
					"ecology_dirty_cells", "ecology_ms", "ecology", deadline_us)
		owner.PHASE_SMOOTH:
			return owner._step_phase_baker(remaining_budget, "dyn_atlas_smooth",
					"smooth_dirty_cells", "smooth_ms", "smooth", deadline_us)
		owner.PHASE_ICE:
			return owner._step_phase_baker(remaining_budget, "ice_state_atlas",
					"ice_dirty_cells", "ice_ms", "ice", deadline_us)
		_:
			return true



static func _abort_smooth_prep(owner: DynamicVisualAtlasUploadSystem, reason: String) -> void:
	if owner._smooth_prep_state.is_empty():
		return
	owner._smooth_prep_abort_count += 1
	owner._aggregated_report["smooth_prep_abort_reason"] = reason
	owner._aggregated_report["smooth_prep_abort_count"] = owner._smooth_prep_abort_count
	owner._smooth_prep_generation += 1
	owner._smooth_prep_state = {}



static func _start_smooth_prep(owner: DynamicVisualAtlasUploadSystem, source: String, seed_cells: Array, decay_set: Dictionary = {}) -> void:
	var n: int = owner.map.cell_count() if owner.map != null else 0
	owner._smooth_prep_generation += 1
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(maxi(0, n))
	var seed_seen: PackedByteArray = PackedByteArray()
	seed_seen.resize(maxi(0, n))
	owner._smooth_prep_state = {
		"generation": owner._smooth_prep_generation,
		"stage": "merge_seed",
		"source": source,
		"input_cells": seed_cells if seed_cells != null else [],
		"input_cursor": 0,
		"decay_keys": decay_set.keys() if decay_set != null and not decay_set.is_empty() else [],
		"decay_cursor": 0,
		"seed_cells": [],
		"dilate_cursor": 0,
		"collect_cursor": 0,
		"seen": seen,
		"seed_seen": seed_seen,
		"candidates": PackedInt32Array(),
		"candidate_sorted": false,
		"out": [],
		"n": n,
		"prepared": false,
	}



static func _smooth_prep_push_candidate(owner: DynamicVisualAtlasUploadSystem, idx: int) -> void:
	var n: int = int(owner._smooth_prep_state.get("n", 0))
	if idx < 0 or idx >= n:
		return
	var seen: PackedByteArray = owner._smooth_prep_state.get("seen", PackedByteArray())
	if seen.size() < n or seen[idx] != 0:
		return
	seen[idx] = 1
	owner._smooth_prep_state["seen"] = seen
	var candidates: PackedInt32Array = owner._smooth_prep_state.get("candidates", PackedInt32Array())
	candidates.append(idx)
	owner._smooth_prep_state["candidates"] = candidates



static func _advance_smooth_prep(owner: DynamicVisualAtlasUploadSystem, remaining_budget: int, deadline_us: int) -> bool:
	if owner._smooth_prep_state.is_empty():
		return true
	if int(owner._smooth_prep_state.get("generation", -1)) != owner._smooth_prep_generation:
		owner._abort_smooth_prep("stale_generation")
		return false
	var t_prep_us: int = Time.get_ticks_usec()
	var budget: int = maxi(1, mini(owner.SMOOTH_PREP_CELLS_PER_TICK, remaining_budget))
	var seed_cells: Array = owner._smooth_prep_state.get("seed_cells", [])
	var n: int = int(owner._smooth_prep_state.get("n", 0))
	var nb_indices: PackedInt32Array = owner.map.neighbor_indices_packed() if owner.map != null and owner.map.has_method("neighbor_indices_packed") else PackedInt32Array()
	var fast_indexed: bool = nb_indices.size() >= n * 6
	var worked: int = 0
	while worked < budget:
		if worked > 0 and Time.get_ticks_usec() >= deadline_us:
			break
		var stage: String = str(owner._smooth_prep_state.get("stage", "merge_seed"))
		if stage == "merge_seed":
			var input_cells: Array = owner._smooth_prep_state.get("input_cells", [])
			var decay_keys: Array = owner._smooth_prep_state.get("decay_keys", [])
			var input_cursor: int = int(owner._smooth_prep_state.get("input_cursor", 0))
			var decay_cursor: int = int(owner._smooth_prep_state.get("decay_cursor", 0))
			var merged_seed: Array = owner._smooth_prep_state.get("seed_cells", [])
			var c = null
			if input_cursor < input_cells.size():
				c = input_cells[input_cursor]
				owner._smooth_prep_state["input_cursor"] = input_cursor + 1
			elif decay_cursor < decay_keys.size():
				c = decay_keys[decay_cursor]
				owner._smooth_prep_state["decay_cursor"] = decay_cursor + 1
			else:
				owner._smooth_prep_state["seed_cells"] = merged_seed
				owner._smooth_prep_state["stage"] = "dilate_mark"
				seed_cells = merged_seed
				continue
			if c != null:
				var idx_seed: int = int(c.index)
				var seed_seen: PackedByteArray = owner._smooth_prep_state.get("seed_seen", PackedByteArray())
				if idx_seed >= 0 and idx_seed < n and seed_seen[idx_seed] == 0:
					seed_seen[idx_seed] = 1
					owner._smooth_prep_state["seed_seen"] = seed_seen
					merged_seed.append(c)
					owner._smooth_prep_state["seed_cells"] = merged_seed
			worked += 1
		elif stage == "dilate_mark":
			var dilate_cursor: int = int(owner._smooth_prep_state.get("dilate_cursor", 0))
			if dilate_cursor >= seed_cells.size():
				owner._smooth_prep_state["stage"] = "collect_sorted"
				continue
			var c2 = seed_cells[dilate_cursor]
			if c2 != null:
				var idx2: int = int(c2.index)
				if idx2 >= 0 and idx2 < n:
					owner._smooth_prep_push_candidate(idx2)
					if fast_indexed:
						var base: int = idx2 * 6
						for d in range(6):
							owner._smooth_prep_push_candidate(nb_indices[base + d])
					elif owner.map.has_method("get_neighbors"):
						for nb_cell in owner.map.get_neighbors(c2):
							if nb_cell != null:
								owner._smooth_prep_push_candidate(int(nb_cell.index))
			owner._smooth_prep_state["dilate_cursor"] = dilate_cursor + 1
			worked += 1
		elif stage == "collect_sorted":
			var candidates: PackedInt32Array = owner._smooth_prep_state.get("candidates", PackedInt32Array())
			if not bool(owner._smooth_prep_state.get("candidate_sorted", false)):
				candidates.sort()
				owner._smooth_prep_state["candidates"] = candidates
				owner._smooth_prep_state["candidate_sorted"] = true
			var collect_cursor: int = int(owner._smooth_prep_state.get("collect_cursor", 0))
			if collect_cursor >= candidates.size():
				owner._smooth_prep_state["stage"] = "done"
				owner._smooth_prep_state["prepared"] = true
				break
			var collect_end: int = mini(candidates.size(), collect_cursor + (budget - worked))
			var out: Array = owner._smooth_prep_state.get("out", [])
			for i in range(collect_cursor, collect_end):
				out.append(owner.map.cell_at(candidates[i]))
			owner._smooth_prep_state["out"] = out
			owner._smooth_prep_state["collect_cursor"] = collect_end
			worked += collect_end - collect_cursor
		else:
			break
	owner._aggregated_report["smooth_prepare_ms"] = float(owner._aggregated_report.get("smooth_prepare_ms", 0.0)) \
			+ float(Time.get_ticks_usec() - t_prep_us) / 1000.0
	owner._aggregated_report["smooth_prep_stage"] = str(owner._smooth_prep_state.get("stage", ""))
	owner._aggregated_report["smooth_prep_input_cursor"] = int(owner._smooth_prep_state.get("input_cursor", 0))
	owner._aggregated_report["smooth_prep_decay_cursor"] = int(owner._smooth_prep_state.get("decay_cursor", 0))
	owner._aggregated_report["smooth_prep_seed_count"] = int((owner._smooth_prep_state.get("seed_cells", []) as Array).size())
	owner._aggregated_report["smooth_prep_dilate_cursor"] = int(owner._smooth_prep_state.get("dilate_cursor", 0))
	owner._aggregated_report["smooth_prep_collect_cursor"] = int(owner._smooth_prep_state.get("collect_cursor", 0))
	owner._aggregated_report["smooth_prep_candidates"] = int((owner._smooth_prep_state.get("candidates", PackedInt32Array()) as PackedInt32Array).size())
	owner._aggregated_report["_cells_scanned_this_tick"] = int(owner._aggregated_report.get("_cells_scanned_this_tick", 0)) + worked
	return bool(owner._smooth_prep_state.get("prepared", false))



static func _validate_smooth_prep_equivalence_if_small(owner: DynamicVisualAtlasUploadSystem) -> void:
	if owner._smooth_prep_state.is_empty() or owner.map == null:
		return
	var input_cells: Array = owner._smooth_prep_state.get("input_cells", [])
	var decay_keys: Array = owner._smooth_prep_state.get("decay_keys", [])
	var total_input: int = input_cells.size() + decay_keys.size()
	if total_input > 256:
		return
	owner._smooth_prep_equiv_checks += 1
	var seed_expected: Array = owner.BakerDirtyHelpersScript.merge_with_eco_decay(input_cells, {})
	if not decay_keys.is_empty():
		var decay_set: Dictionary = {}
		for c in decay_keys:
			if c != null:
				decay_set[c] = true
		seed_expected = owner.BakerDirtyHelpersScript.merge_with_eco_decay(seed_expected, decay_set)
	var expected: Array = owner.BakerDirtyHelpersScript.dilate_dirty_one_hop(owner.map, seed_expected)
	var actual: Array = owner._smooth_prep_state.get("out", [])
	var equal: bool = expected.size() == actual.size()
	if equal:
		for i in range(expected.size()):
			var e = expected[i]
			var a = actual[i]
			var ei: int = int(e.index) if e != null else -1
			var ai: int = int(a.index) if a != null else -1
			if ei != ai:
				equal = false
				break
	if not equal:
		owner._smooth_prep_equiv_failures += 1
		push_warning("[dyn_atlas_smooth/prep] sliced dirty expansion mismatch expected=%d actual=%d" % [expected.size(), actual.size()])
	owner._aggregated_report["smooth_prep_equiv_checks"] = owner._smooth_prep_equiv_checks
	owner._aggregated_report["smooth_prep_equiv_failures"] = owner._smooth_prep_equiv_failures


# Phase 1..4：通用 baker chunk 推进。
# baker_key 决定调用哪组 chunk_begin/step/finalize；
# agg_dirty_key / agg_ms_key 是 aggregated_report 里的累计字段名。
static func _step_phase_baker(owner: DynamicVisualAtlasUploadSystem, remaining_budget: int, baker_key: String,
		agg_dirty_key: String, agg_ms_key: String, phase_key: String,
		deadline_us: int) -> bool:
	var total_us: int = Time.get_ticks_usec()
	# [perf 2026-05-20] 方案 C：Callable 表命中直接调，未命中（理论上不会发生）走老路径。
	var _cb: Dictionary = owner._baker_callables.get(baker_key, {})
	var _cb_step: Callable = _cb.get("step", Callable())
	var _cb_finalize: Callable = _cb.get("finalize", Callable())
	if owner._phase_ctx.is_empty():
		var prepare_us: int = Time.get_ticks_usec()
		var begin_method: String = "%s_chunk_begin" % baker_key
		if not owner.baker.has_method(begin_method):
			return true
		var _cb_begin: Callable = _cb.get("begin", Callable())
		if _cb_begin.is_valid():
			owner._phase_ctx = _cb_begin.call(owner.map, owner.world_data)
		else:
			owner._phase_ctx = owner.baker.call(begin_method, owner.map, owner.world_data)
		if not bool(owner._phase_ctx.get("prepared", false)):
			owner._phase_ctx = {}
			return true
		var source: String = "all_cells"
		if baker_key == "ice_state_atlas":
			if owner._stride_dirty_path_used and owner._stride_dirty_noop:
				var ice_cache_valid: bool = bool(owner._phase_ctx.get("cache_valid", false))
				if ice_cache_valid:
					owner._phase_cells = []
					source = "no_dirty"
				elif owner.baker.has_method("ice_state_atlas_default_cell_source"):
					owner._phase_cells = owner.baker.ice_state_atlas_default_cell_source(owner.map, owner.world_data, owner._phase_ctx)
					source = "all_cells_cache_invalid"
				else:
					owner._phase_cells = owner.map.all_cells()
					source = "all_cells_cache_invalid"
			elif owner._stride_dirty_path_used and owner.baker.has_method("ice_state_atlas_default_cell_source"):
				var water_lists: Dictionary = owner.world_data.water_cell_pixel_lists if owner.world_data != null else {}
				if water_lists != null and not water_lists.is_empty() and not owner._stride_dirty_cells.is_empty():
					var intersection: Array = []
					intersection.resize(owner._stride_dirty_cells.size())
					var w: int = 0
					for c in owner._stride_dirty_cells:
						if c != null and water_lists.has(c):
							intersection[w] = c
							w += 1
					intersection.resize(w)
					owner._phase_cells = intersection
					source = "dirty_water_intersection"
				else:
					var ice_dirty_cache_valid: bool = bool(owner._phase_ctx.get("cache_valid", false))
					if ice_dirty_cache_valid:
						owner._phase_cells = []
						source = "dirty_no_water_intersection"
					else:
						owner._phase_cells = owner.baker.ice_state_atlas_default_cell_source(owner.map, owner.world_data, owner._phase_ctx)
						source = "all_cells_cache_invalid"
			elif owner.baker.has_method("ice_state_atlas_default_cell_source"):
				owner._phase_cells = owner.baker.ice_state_atlas_default_cell_source(owner.map, owner.world_data, owner._phase_ctx)
				source = "ice_default_source"
			else:
				owner._phase_cells = owner.map.all_cells()
		elif baker_key == "dynamic_cell_atlas" and owner._stride_dirty_path_used:
			if owner._stride_dirty_noop:
				var dynamic_cache_valid: bool = bool(owner._phase_ctx.get("cache_valid", false))
				if dynamic_cache_valid:
					owner._phase_cells = []
					source = "no_dirty"
				else:
					owner._phase_cells = owner.map.all_cells()
					source = "all_cells_cache_invalid"
			else:
				owner._phase_cells = owner._stride_dirty_cells
				source = "dirty_mask"
		elif baker_key == "ecology_visual_atlas" and owner._stride_dirty_path_used:
			var eco_cache_valid: bool = bool(owner._phase_ctx.get("cache_valid", false))
			if not eco_cache_valid:
				owner._phase_cells = owner.map.all_cells()
				source = "all_cells_cache_invalid"
			elif owner._stride_dirty_noop:
				if owner.baker._eco_active_decay_set.is_empty():
					owner._phase_cells = []
					source = "no_dirty"
				else:
					owner._phase_cells = owner.baker._eco_active_decay_set.keys()
					source = "decay_only"
			else:
				owner._phase_cells = owner.BakerDirtyHelpersScript.merge_with_eco_decay(
					owner._stride_dirty_cells, owner.baker._eco_active_decay_set)
				source = "dirty_plus_decay"
		elif baker_key == "dyn_atlas_smooth" and owner._stride_dirty_path_used:
			var smooth_cache_valid: bool = bool(owner._phase_ctx.get("cache_valid", false))
			if not smooth_cache_valid:
				owner._phase_cells = owner.map.all_cells()
				source = "all_cells_cache_invalid"
			elif owner._stride_dirty_noop:
				if owner.baker._eco_active_decay_set.is_empty():
					owner._phase_cells = []
					source = "no_dirty"
				else:
					source = "decay_one_hop_sliced"
					if owner._smooth_prep_state.is_empty():
						owner._start_smooth_prep(source, owner.baker._eco_active_decay_set.keys())
					if not owner._advance_smooth_prep(remaining_budget, deadline_us):
						owner._aggregated_report[phase_key + "_source"] = source
						return false
					owner._validate_smooth_prep_equivalence_if_small()
					owner._phase_cells = owner._smooth_prep_state.get("out", [])
					owner._smooth_prep_state = {}
			else:
				source = "dirty_decay_one_hop_sliced"
				if owner._smooth_prep_state.is_empty():
					owner._start_smooth_prep(source, owner._stride_dirty_cells, owner.baker._eco_active_decay_set)
				if not owner._advance_smooth_prep(remaining_budget, deadline_us):
					owner._aggregated_report[phase_key + "_source"] = source
					return false
				owner._validate_smooth_prep_equivalence_if_small()
				owner._phase_cells = owner._smooth_prep_state.get("out", [])
				owner._smooth_prep_state = {}
		else:
			owner._phase_cells = owner.map.all_cells()
		owner._phase_cursor = 0
		owner._phase_report = {
			"prepared": true,
			"dirty": false,
			"dirty_cells": 0,
			"pixels_written": 0,
			"elapsed_ms": 0.0,
			"path": "",
			"fallback_reason": "",
			"cpp_calls": 0,
			"gd_calls": 0,
			"empty_calls": 0,
		}
		owner._aggregated_report[phase_key + "_prepare_ms"] = \
				float(Time.get_ticks_usec() - prepare_us) / 1000.0
		owner._aggregated_report[phase_key + "_source"] = source
		owner._aggregated_report[phase_key + "_total_cells"] = owner._phase_cells.size()

	var total_cells: int = owner._phase_cells.size()
	var cells_scanned: int = 0
	while owner._phase_cursor < total_cells and cells_scanned < remaining_budget:
		if cells_scanned > 0 and Time.get_ticks_usec() >= deadline_us:
			break
		var chunk_size_limit: int = owner._chunk_size_limit_for_baker(baker_key)
		var chunk_budget: int = mini(chunk_size_limit, remaining_budget - cells_scanned)
		var end_cursor: int = mini(total_cells, owner._phase_cursor + chunk_budget)
		var slice_size: int = end_cursor - owner._phase_cursor
		if slice_size <= 0:
			break
		var step_us: int = Time.get_ticks_usec()
		# [perf 2026-05-20] 方案 C：Callable 直调；hot path 单次省 ~50-100μs。
		if _cb_step.is_valid():
			_cb_step.call(owner.map, owner.world_data, owner._phase_ctx, owner._phase_cells,
					owner._phase_report, owner._phase_cursor, end_cursor)
		else:
			var step_method: String = "%s_chunk_step" % baker_key
			owner.baker.call(step_method, owner.map, owner.world_data, owner._phase_ctx, owner._phase_cells,
					owner._phase_report, owner._phase_cursor, end_cursor)
		owner._phase_cursor = end_cursor
		owner._aggregated_report["_cells_scanned_this_tick"] = \
				int(owner._aggregated_report.get("_cells_scanned_this_tick", 0)) + slice_size
		owner._aggregated_report[phase_key + "_cells_considered"] = \
				int(owner._aggregated_report.get(phase_key + "_cells_considered", 0)) + slice_size
		owner._aggregated_report[phase_key + "_step_ms"] = \
				float(owner._aggregated_report.get(phase_key + "_step_ms", 0.0)) \
				+ float(Time.get_ticks_usec() - step_us) / 1000.0
		cells_scanned += slice_size

	var phase_complete: bool = owner._phase_cursor >= total_cells
	if phase_complete:
		var finalize_us: int = Time.get_ticks_usec()
		# [perf 2026-05-20] 方案 C：Callable 直调。
		if _cb_finalize.is_valid():
			_cb_finalize.call(owner.world_data, owner._phase_ctx, owner._phase_report)
		else:
			var finalize_method: String = "%s_chunk_finalize" % baker_key
			owner.baker.call(finalize_method, owner.world_data, owner._phase_ctx, owner._phase_report)
		owner._aggregated_report[phase_key + "_finalize_ms"] = \
				float(owner._aggregated_report.get(phase_key + "_finalize_ms", 0.0)) \
				+ float(Time.get_ticks_usec() - finalize_us) / 1000.0

	owner._phase_report.elapsed_ms = float(owner._phase_report.get("elapsed_ms", 0.0)) \
			+ float(Time.get_ticks_usec() - total_us) / 1000.0
	owner._aggregated_report[agg_dirty_key] = int(owner._phase_report.get("dirty_cells", 0))
	owner._aggregated_report[agg_ms_key] = float(owner._phase_report.get("elapsed_ms", 0.0))
	owner._aggregated_report[phase_key + "_pixels_written"] = int(owner._phase_report.get("pixels_written", 0))
	owner._aggregated_report[phase_key + "_path"] = str(owner._phase_report.get("path", ""))
	owner._aggregated_report[phase_key + "_fallback_reason"] = str(owner._phase_report.get("fallback_reason", ""))
	owner._aggregated_report[phase_key + "_cpp_calls"] = int(owner._phase_report.get("cpp_calls", 0))
	owner._aggregated_report[phase_key + "_gd_calls"] = int(owner._phase_report.get("gd_calls", 0))
	owner._aggregated_report[phase_key + "_empty_calls"] = int(owner._phase_report.get("empty_calls", 0))

	return phase_complete


# Stride 完成 tick 的最终 report 组装。
static func _finalize_stride(owner: DynamicVisualAtlasUploadSystem, elapsed_ms: float) -> Dictionary:
	owner.mark_atlas_upload_success()
	owner._dvas_diag_stride_count += 1
	owner._dvas_diag_ticks_accum += owner._total_ticks_used
	# [diag 2026-05-20 phase-breakdown] 累加本 stride 的 phase ms 切片到窗口累加器。
	for key in owner._dvas_diag_phase_ms_accum.keys():
		owner._dvas_diag_phase_ms_accum[key] = float(owner._dvas_diag_phase_ms_accum[key]) \
				+ float(owner._aggregated_report.get(key, 0.0))
	if owner._dvas_diag_stride_count >= owner._dvas_diag_avg_window:
		var avg_ticks: float = float(owner._dvas_diag_ticks_accum) / float(owner._dvas_diag_stride_count)
		var n: float = float(owner._dvas_diag_stride_count)
		# 顶层数字（保持原有格式以免破坏旧 dashboard / grep）
		print_rich("[color=#888]dynamic_visual_atlas_upload diag: avg_ticks_per_stride=%.2f, max_tick_ms=%.2f (over %d strides)[/color]"
				% [avg_ticks, owner._dvas_diag_max_tick_ms, owner._dvas_diag_stride_count])
		# Phase 分解：每行一个 phase，prep/step/fin 三个分量（窗口均值, ms/stride）
		var dyn_p: float = float(owner._dvas_diag_phase_ms_accum["dynamic_prepare_ms"]) / n
		var dyn_s: float = float(owner._dvas_diag_phase_ms_accum["dynamic_step_ms"]) / n
		var dyn_f: float = float(owner._dvas_diag_phase_ms_accum["dynamic_finalize_ms"]) / n
		var eco_p: float = float(owner._dvas_diag_phase_ms_accum["ecology_prepare_ms"]) / n
		var eco_s: float = float(owner._dvas_diag_phase_ms_accum["ecology_step_ms"]) / n
		var eco_f: float = float(owner._dvas_diag_phase_ms_accum["ecology_finalize_ms"]) / n
		var smo_p: float = float(owner._dvas_diag_phase_ms_accum["smooth_prepare_ms"]) / n
		var smo_s: float = float(owner._dvas_diag_phase_ms_accum["smooth_step_ms"]) / n
		var smo_f: float = float(owner._dvas_diag_phase_ms_accum["smooth_finalize_ms"]) / n
		var ice_p: float = float(owner._dvas_diag_phase_ms_accum["ice_prepare_ms"]) / n
		var ice_s: float = float(owner._dvas_diag_phase_ms_accum["ice_step_ms"]) / n
		var ice_f: float = float(owner._dvas_diag_phase_ms_accum["ice_finalize_ms"]) / n
		var total: float = dyn_p + dyn_s + dyn_f + eco_p + eco_s + eco_f \
				+ smo_p + smo_s + smo_f + ice_p + ice_s + ice_f
		print_rich("[color=#888]  phase breakdown (avg ms/stride, prep+step+fin):"
				+ " dyn=%.2f+%.2f+%.2f eco=%.2f+%.2f+%.2f smo=%.2f+%.2f+%.2f ice=%.2f+%.2f+%.2f sum=%.2f[/color]"
				% [dyn_p, dyn_s, dyn_f, eco_p, eco_s, eco_f, smo_p, smo_s, smo_f, ice_p, ice_s, ice_f, total])
		owner._dvas_diag_stride_count = 0
		owner._dvas_diag_ticks_accum = 0
		owner._dvas_diag_max_tick_ms = 0.0
		for key2 in owner._dvas_diag_phase_ms_accum.keys():
			owner._dvas_diag_phase_ms_accum[key2] = 0.0

	var report: Dictionary = owner._build_report(true, elapsed_ms)
	owner._last_breakdown = report.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	owner._last_breakdown["_tick_idx"] = owner.current_fast_tick_idx
	return report
