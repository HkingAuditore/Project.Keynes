extends "res://scripts/simulation/generator_context.gd"

const ManualDailyTick = preload("res://scripts/simulation/climate/native_daily_manual_tick.gd")

const DailyJobSteps = preload("res://scripts/simulation/climate/native_daily_job_steps.gd")

const DailyRegistration = preload("res://scripts/simulation/climate/native_daily_registration.gd")
## Native daily graph execution and SUS tick orchestration extracted from MapGenerator.
func _init(generator) -> void:
	_generator = generator


func _ensure_maritime_factor(map: MapData, decay_cells: float) -> PackedFloat32Array:
	var n: int = map.soa_size()
	if n <= 0:
		return PackedFloat32Array()
	var key: String = "%d:%.3f" % [n, decay_cells]
	if _generator._maritime_factor_cache_key == key and _generator._maritime_factor_cache.size() == n:
		return _generator._maritime_factor_cache
	var isw: PackedByteArray = map.is_water_arr
	var nb: PackedInt32Array = map.neighbor_indices_packed()
	if isw.size() != n or nb.size() < n * 6:
		return PackedFloat32Array()
	var dist: PackedInt32Array = PackedInt32Array()
	dist.resize(n)
	var queue: PackedInt32Array = PackedInt32Array()
	queue.resize(n)
	var qh: int = 0
	var qt: int = 0
	for i in range(n):
		if isw[i] != 0:
			dist[i] = 0
			queue[qt] = i
			qt += 1
		else:
			dist[i] = -1
	while qh < qt:
		var cur: int = queue[qh]
		qh += 1
		var nd: int = dist[cur] + 1
		var base: int = cur * 6
		for d in range(6):
			var ni: int = nb[base + d]
			if ni < 0 or ni >= n:
				continue
			if dist[ni] >= 0:
				continue
			dist[ni] = nd
			queue[qt] = ni
			qt += 1
	var inv_decay: float = 1.0 / maxf(decay_cells, 0.001)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		if isw[i] != 0 or dist[i] < 0:
			out[i] = 0.0  # 水面 / 无海可达内陆 → 不调温
		else:
			out[i] = exp(-float(dist[i]) * inv_decay)  # 沿海陆地(dist=1)≈最大，向内陆衰减
	_generator._maritime_factor_cache = out
	_generator._maritime_factor_cache_key = key
	return out


# _async_pass_a_kernel_pure 的硬校验 lane 列表（gdext/src/runtime_climate_passes.cpp
# 顶部的维度检查）。任一条 size != n_cells，共享内核直接 return false。
func publish_worker_climate_visuals(defer_upload: bool, commit: Dictionary = {}) -> Dictionary:
	if _generator._baker == null or _generator._sus_map == null or _generator._last_world == null:
		return {"lut_encode_path": "none", "reason": "missing_baker_map_or_world"}
	var frame: Dictionary
	if commit.has("map_lut_generation"):
		# The presentation budget admitted this update. Read the ecology for
		# the same publication that installed climate, vision and classes.
		frame = _generator._get_map_runtime_bridge().read_runtime_map_lut_frame(
			_generator._sus_map, int(commit.map_lut_day), int(commit.map_lut_generation))
		if frame.has("reason"):
			return {"lut_encode_path": "none", "map_lut_read_failed": true, "reason": frame.reason}
		commit["cell_lut_frame"] = frame
	var dirty: PackedInt32Array = commit.get("display_dirty_cells", PackedInt32Array())
	var result := DCCellLutBaker.refresh_cell_luts_daily(_generator._baker,
			_generator._sus_map, _generator._last_world, dirty,
			not commit.has("display_dirty_cells"), true, defer_upload, commit)
	if frame.has("copy_ns"):
		result["map_lut_copy"] = {"day": commit.map_lut_day, "ns": frame.copy_ns,
			"bytes": frame.transition_age.size() + frame.previous_vitality.size()}
	return result


func _temperature_transport_anomaly_knobs(cp_now) -> Dictionary:
	var source_cap: float = 0.22
	var blend_rate: float = 0.70
	var decay_rate: float = 0.04
	var zero_current_decay: float = 0.06
	if cp_now != null:
		if cp_now.get("temperature_transport_anomaly_source_cap") != null:
			source_cap = float(cp_now.temperature_transport_anomaly_source_cap)
		if cp_now.get("temperature_transport_anomaly_blend_rate") != null:
			blend_rate = float(cp_now.temperature_transport_anomaly_blend_rate)
		if cp_now.get("temperature_transport_anomaly_decay_rate") != null:
			decay_rate = float(cp_now.temperature_transport_anomaly_decay_rate)
		if cp_now.get("temperature_transport_anomaly_zero_current_decay") != null:
			zero_current_decay = float(cp_now.temperature_transport_anomaly_zero_current_decay)
	return {
		"tta_source_cap": clampf(source_cap, 0.0, 0.5),
		"tta_blend_rate": clampf(blend_rate, 0.0, 1.0),
		"tta_decay_rate": clampf(decay_rate, 0.0, 1.0),
		"tta_zero_current_decay": clampf(zero_current_decay, 0.0, 1.0),
	}



func _prepare_temperature_transport_anomaly_state(map: MapData, n: int, cells: Array = [], prefer_cached: bool = false) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(maxi(n, 0))
	if n <= 0:
		return out
	if prefer_cached and _generator._gdext_ocean_anomaly_buf_cached.size() == n:
		var cached: PackedFloat32Array = _generator._gdext_ocean_anomaly_buf_cached
		for ci in range(n):
			out[ci] = float(cached[ci])
		return out
	if map != null and map.temperature_transport_anomaly_arr.size() == n:
		var arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
		for ai in range(n):
			out[ai] = float(arr[ai])
		return out
	if not prefer_cached and _generator._gdext_ocean_anomaly_buf_cached.size() == n:
		var cached_after_map: PackedFloat32Array = _generator._gdext_ocean_anomaly_buf_cached
		for cmi in range(n):
			out[cmi] = float(cached_after_map[cmi])
		return out
	if cells.size() == n:
		for i in range(n):
			var cell = cells[i]
			if cell != null:
				out[i] = float((cell as HexCell).temperature_transport_anomaly)
	return out



func _run_native_daily_shadow_probe(ctx: SusTickContext, map: MapData, world: WorldData) -> void:
	var cp = _generator._c()
	if not _generator._native_mode_is_shadow(cp, "native_daily_sim_mode"):
		return
	if _generator._data_core_world_ext == null:
		_generator._native_daily_last_result = { "rc": -1, "mode": "shadow_probe", "fail_stage": "gdext_unavailable" }
		return
	# SHADOW probe 同样是 readiness 探测，强制纳入 weather/stage_b 探完整图。
	var bundle: Dictionary = _generator._get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, map, world, false, 30.0, true)
	var pass_keys: Array[String] = _generator._get_native_daily_bundle_builder()._native_daily_bundle_pass_keys(bundle)
	if pass_keys.is_empty():
		_generator._native_daily_last_result = { "rc": -1, "mode": "shadow_probe", "fail_stage": "empty_bundle" }
		return
	var tick_knobs: Dictionary = _generator._get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
	tick_knobs["probe"] = true
	tick_knobs["native_daily_bundle"] = bundle
	tick_knobs["required_pass_keys"] = _generator._get_native_daily_bundle_builder()._native_daily_required_pass_keys_array(cp)
	var res: Dictionary = _generator._data_core_world_ext.run_native_daily_tick(tick_knobs)
	res["mode"] = "shadow_probe"
	res["bundle_pass_keys"] = pass_keys
	_generator._native_daily_last_result = res.duplicate(true)
	if not _generator._native_daily_shadow_probe_logged:
		_generator._native_daily_shadow_probe_logged = true
		var pass_key_text: String = ", ".join(PackedStringArray(pass_keys))
		print("[native_daily] SHADOW probe rc=%s passes=%s (legacy SUS remains authoritative)"
			% [str(res.get("rc", -1)), pass_key_text])



func _configure_native_world_context(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	DailyRegistration._configure_native_world_context(self, map, world, cfg, hex_size)


func _try_register_native_daily_sim_job(map: MapData, world: WorldData) -> bool:
	return DailyRegistration._try_register_native_daily_sim_job(self, map, world)


func _configure_native_daily_transaction_budget(job, cp) -> void:
	DailyRegistration._configure_native_daily_transaction_budget(self, job, cp)


func _try_register_native_environment_runtime_system(map: MapData, cp) -> bool:
	return DailyRegistration._try_register_native_environment_runtime_system(self, map, cp)


func _register_visual_upload_jobs(map: MapData, world: WorldData, hex_size: float, cp) -> void:
	DailyRegistration._register_visual_upload_jobs(self, map, world, hex_size, cp)


func _native_daily_contract_stride_days() -> int:
	var cp = _generator._c()
	if cp != null and cp.get("native_daily_sim_stride") != null:
		return clampi(int(cp.native_daily_sim_stride), 1, 30)
	return 1



func _native_daily_contract_budget_days() -> int:
	var cp = _generator._c()
	if cp != null and cp.get("native_daily_commit_lag_budget_days") != null:
		return clampi(int(cp.native_daily_commit_lag_budget_days), 1, 30)
	return _generator._native_daily_contract_stride_days()



func _native_daily_effective_node_range_config(cp, ctx: SusTickContext, map_ref: MapData) -> Dictionary:
	var base_cells: int = 768
	if cp != null and cp.get("native_daily_node_range_cells") != null:
		base_cells = maxi(1, int(cp.native_daily_node_range_cells))
	var n_cells: int = map_ref.soa_size() if map_ref != null else 0
	var range_nodes: PackedStringArray = PackedStringArray()
	if cp != null and cp.get("native_daily_node_range_nodes") != null:
		range_nodes = cp.native_daily_node_range_nodes
	var range_node_count: int = maxi(1, range_nodes.size())
	var budget_days: int = _generator._native_daily_contract_budget_days()
	var age_days: int = _generator._native_daily_contract_age_days_for(ctx)
	var effective_cells: int = base_cells
	var catchup_active: bool = false
	var catchup_reason: String = "none"
	var estimated_slices: int = _generator._NATIVE_DAILY_CONTRACT_FIXED_SLICE_ESTIMATE
	if n_cells > 0:
		estimated_slices += int(ceil(float(n_cells) / float(base_cells))) * range_node_count
	if n_cells > 0 and estimated_slices > budget_days:
		var range_slice_budget: int = maxi(range_node_count, budget_days - _generator._NATIVE_DAILY_CONTRACT_FIXED_SLICE_ESTIMATE)
		var chunks_per_node: int = maxi(1, int(floor(float(range_slice_budget) / float(range_node_count))))
		effective_cells = maxi(base_cells, int(ceil(float(n_cells) / float(chunks_per_node))))
		catchup_active = effective_cells > base_cells
		catchup_reason = "fit_contract_budget" if catchup_active else "base_fits_contract"
	elif n_cells > 0 and age_days >= budget_days - 1:
		effective_cells = maxi(base_cells, mini(n_cells, base_cells * 2))
		catchup_active = effective_cells > base_cells
		catchup_reason = "near_contract_deadline" if catchup_active else "base_at_deadline"
	return {
		"base_cells": base_cells,
		"effective_cells": effective_cells,
		"catchup_active": catchup_active,
		"catchup_reason": catchup_reason,
		"estimated_slices": estimated_slices,
		"budget_days": budget_days,
		"age_days": age_days,
		"range_node_count": range_node_count,
	}



func _native_daily_begin_contract_round(ctx: SusTickContext) -> void:
	_generator._native_daily_contract_round_seq += 1
	_generator._native_daily_contract_sample_day = ctx.day_index if ctx != null else -1
	_generator._native_daily_contract_sample_tick = ctx.tick_index if ctx != null else -1
	_generator._native_daily_contract_warned_over_budget = false



func _native_daily_stamp_contract(res: Dictionary, breakdown: Dictionary,
		ctx: SusTickContext, committed: bool, state: String) -> void:
	if _generator._native_daily_contract_sample_day < 0 and ctx != null:
		_generator._native_daily_begin_contract_round(ctx)
	var current_day: int = ctx.day_index if ctx != null else _generator._native_daily_contract_sample_day
	var current_tick: int = ctx.tick_index if ctx != null else _generator._native_daily_contract_sample_tick
	var sample_day: int = _generator._native_daily_contract_sample_day
	var sample_tick: int = _generator._native_daily_contract_sample_tick
	var age_days: int = maxi(0, current_day - sample_day) if sample_day >= 0 and current_day >= 0 else 0
	var age_ticks: int = maxi(0, current_tick - sample_tick) if sample_tick >= 0 and current_tick >= 0 else age_days
	var budget_days: int = _generator._native_daily_contract_budget_days()
	var over_budget: bool = age_days > budget_days
	var commit_day: int = current_day if committed else -1
	var commit_tick: int = current_tick if committed else -1
	var fields := {
		"native_daily_contract_version": 1,
		"native_daily_contract_state": state,
		"native_daily_round_seq": _generator._native_daily_contract_round_seq,
		"native_daily_stride_days": _generator._native_daily_contract_stride_days(),
		"native_daily_commit_lag_budget_days": budget_days,
		"native_daily_sample_day": sample_day,
		"native_daily_sample_tick": sample_tick,
		"native_daily_current_day": current_day,
		"native_daily_current_tick": current_tick,
		"native_daily_commit_day": commit_day,
		"native_daily_commit_tick": commit_tick,
		"native_daily_age_days": age_days,
		"native_daily_age_ticks": age_ticks,
		"native_daily_commit_over_budget": over_budget,
		"native_daily_finalizer_pending": _generator._native_daily_finalizer_pending,
	}
	for key in fields.keys():
		res[key] = fields[key]
		breakdown[key] = fields[key]
	if over_budget and not _generator._native_daily_contract_warned_over_budget:
		_generator._native_daily_contract_warned_over_budget = true
		push_warning("[native_daily/contract] round=%d sample_day=%d current_day=%d age=%d budget=%d state=%s exceeded freshness contract"
				% [_generator._native_daily_contract_round_seq, sample_day, current_day, age_days, budget_days, state])



func run_native_daily_slice_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	return DailyJobSteps.run_native_daily_slice_from_job(self, ctx, _map, _world)


func run_native_daily_tick_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	return DailyJobSteps.run_native_daily_tick_from_job(self, ctx, _map, _world)


func sus_tick_daily(world_clock_node, day_index_override: int = -1,
		season_phase_override: float = NAN) -> Dictionary:
	return ManualDailyTick.sus_tick_daily(self, world_clock_node, day_index_override, season_phase_override)


func sus_reset_all() -> void:
	ManualDailyTick.sus_reset_all(self)


func set_current_fast_tick_idx(idx: int) -> void:
	ManualDailyTick.set_current_fast_tick_idx(self, idx)


func sus_ocean_currents_breakdown() -> Dictionary:
	var out: Dictionary = {}
	if _generator._ocean_currents_job != null and _generator._ocean_currents_job.has_method("last_physical_diag"):
		out = _generator._ocean_currents_job.last_physical_diag()
	if _generator._baker != null and _generator._baker.has_method("get_physical_circulation_diag"):
		var baker_diag: Dictionary = _generator._baker.get_physical_circulation_diag()
		for k in baker_diag.keys():
			out[k] = baker_diag[k]
	out["_tick_idx"] = _generator._current_fast_tick_idx
	return out



func _weather_front_count_from_value(v) -> int:
	match typeof(v):
		TYPE_INT:
			return int(v)
		TYPE_FLOAT:
			return int(v)
		TYPE_ARRAY:
			return (v as Array).size()
		TYPE_PACKED_FLOAT32_ARRAY:
			return (v as PackedFloat32Array).size()
		TYPE_PACKED_INT32_ARRAY:
			return (v as PackedInt32Array).size()
		TYPE_PACKED_STRING_ARRAY:
			return (v as PackedStringArray).size()
		TYPE_DICTIONARY:
			var d: Dictionary = v
			return _generator._weather_front_count_from_value(d.get("fronts_count", d.get("n_fronts", 0)))
		_:
			return 0



func _normalized_weather_breakdown(src: Dictionary) -> Dictionary:
	var out: Dictionary = src.duplicate(true)
	var front_count: int = _generator._weather_front_count_from_value(
		out.get("fronts_count", out.get("fronts", 0))
	)
	if out.has("fronts") and typeof(out.get("fronts")) != TYPE_INT:
		out["fronts_raw"] = out.get("fronts")
	out["fronts"] = front_count
	out["fronts_count"] = front_count
	return out



func consume_pending_enum_atlas_axis() -> String:
	if _generator._enum_atlas_biome_dirty:
		_generator._enum_atlas_biome_dirty = false
		_generator._enum_atlas_cover_dirty = false
		_generator._enum_atlas_vegetation_dirty = false
		return "biome"
	if _generator._enum_atlas_cover_dirty:
		_generator._enum_atlas_cover_dirty = false
		return "cover"
	if _generator._enum_atlas_vegetation_dirty:
		_generator._enum_atlas_vegetation_dirty = false
		return "vegetation"
	return ""



func queue_detail_scatter_refresh(indices: PackedInt32Array) -> void:
	if indices.is_empty():
		return
	var seen := {}
	for idx in _generator._pending_detail_scatter_refresh_indices:
		seen[int(idx)] = true
	for idx in indices:
		var ci := int(idx)
		if ci < 0 or seen.has(ci):
			continue
		seen[ci] = true
		_generator._pending_detail_scatter_refresh_indices.append(ci)



func has_pending_detail_scatter_refresh() -> bool:
	if not _generator._pending_detail_scatter_refresh_indices.is_empty() \
			or not _generator._pending_detail_scatter_change_sets.is_empty():
		return true
	if _generator._gameplay_event_bus != null and _generator._gameplay_event_bus.is_available():
		var probe: Dictionary = _generator._gameplay_event_bus.poll_events(
			&"detail_renderer",
			1,
			GameplayEventBus.EVENT_VEGETATION_SUCCESSION,
			false
		)
		return int(probe.get("count", 0)) > 0
	return false



func consume_pending_detail_scatter_refresh_indices() -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := {}
	if _generator._gameplay_event_bus != null and _generator._gameplay_event_bus.is_available():
		var event_cells: PackedInt32Array = _generator._gameplay_event_bus.poll_succession_cells(&"detail_renderer", 512, true)
		for idx in event_cells:
			var ci_event := int(idx)
			if ci_event < 0 or seen.has(ci_event):
				continue
			seen[ci_event] = true
			out.append(ci_event)
	for idx in _generator._pending_detail_scatter_refresh_indices:
		var ci := int(idx)
		if ci < 0 or seen.has(ci):
			continue
		seen[ci] = true
		out.append(ci)
	_generator._pending_detail_scatter_refresh_indices = PackedInt32Array()
	_generator._pending_detail_scatter_change_sets.clear()
	return out



func consume_pending_detail_scatter_changes():
	_generator._detail_scatter_change_generation += 1
	var merged := {}
	# 无 old/new 状态的旧事件保持兼容；精确 tick diff 在后面覆盖同格 unknown。
	if _generator._gameplay_event_bus != null and _generator._gameplay_event_bus.is_available():
		var event_cells: PackedInt32Array = _generator._gameplay_event_bus.poll_succession_cells(&"detail_renderer", 512, true)
		for raw_idx in event_cells:
			var ci := int(raw_idx)
			if ci >= 0:
				merged[ci] = {"axis": _generator.DetailScatterChangeSetScript.AXIS_UNKNOWN}
	for raw_idx in _generator._pending_detail_scatter_refresh_indices:
		var ci := int(raw_idx)
		if ci >= 0 and not merged.has(ci):
			merged[ci] = {"axis": _generator.DetailScatterChangeSetScript.AXIS_UNKNOWN}
	for raw_set in _generator._pending_detail_scatter_change_sets:
		if raw_set == null or not raw_set.has_method("is_well_formed") \
				or not bool(raw_set.is_well_formed()):
			continue
		for i in range(raw_set.cell_indices.size()):
			var ci := int(raw_set.cell_indices[i])
			if ci < 0:
				continue
			merged[ci] = {
				"axis": int(raw_set.axis_masks[i]),
				"ov": int(raw_set.old_vegetation[i]), "nv": int(raw_set.new_vegetation[i]),
				"ol": int(raw_set.old_landform[i]), "nl": int(raw_set.new_landform[i]),
				"oc": int(raw_set.old_cover[i]), "nc": int(raw_set.new_cover[i]),
			}
	_generator._pending_detail_scatter_refresh_indices = PackedInt32Array()
	_generator._pending_detail_scatter_change_sets.clear()
	var out = _generator.DetailScatterChangeSetScript.new()
	out.generation = _generator._detail_scatter_change_generation
	var keys: Array = merged.keys()
	keys.sort()
	for raw_idx in keys:
		var ci := int(raw_idx)
		var row: Dictionary = merged[raw_idx]
		out.append_change(
			ci,
			int(row.get("axis", _generator.DetailScatterChangeSetScript.AXIS_UNKNOWN)),
			int(row.get("ov", 0)), int(row.get("nv", 0)),
			int(row.get("ol", 0)), int(row.get("nl", 0)),
			int(row.get("oc", 0)), int(row.get("nc", 0))
		)
	return out



func record_enum_atlas_upload(axis: String, elapsed_ms: float) -> void:
	_generator._last_enum_atlas_upload_breakdown = {
		"axis": axis,
		"elapsed_ms": elapsed_ms,
		"biome_pending": _generator._enum_atlas_biome_dirty,
		"cover_pending": _generator._enum_atlas_cover_dirty,
		"vegetation_pending": _generator._enum_atlas_vegetation_dirty,
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": _generator._current_fast_tick_idx,
	}



func record_enum_atlas_upload_report(report: Dictionary) -> void:
	_generator._last_enum_atlas_upload_breakdown = report.duplicate(true)
	_generator._last_enum_atlas_upload_breakdown["biome_pending"] = _generator._enum_atlas_biome_dirty
	_generator._last_enum_atlas_upload_breakdown["cover_pending"] = _generator._enum_atlas_cover_dirty
	_generator._last_enum_atlas_upload_breakdown["vegetation_pending"] = _generator._enum_atlas_vegetation_dirty
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_generator._last_enum_atlas_upload_breakdown["_tick_idx"] = _generator._current_fast_tick_idx



func sus_dynamic_visual_atlas_breakdown() -> Dictionary:
	if _generator._dynamic_visual_atlas_upload_job != null \
			and _generator._dynamic_visual_atlas_upload_job.has_method("last_breakdown"):
		return _generator._dynamic_visual_atlas_upload_job.last_breakdown()
	return {}



func _climate_authority_grant_pending(thread_report: Dictionary) -> bool:
	# 内联日（web）没有 worker：grant 只能由内联日自己产生，在这里等它等于等自己。
	# 这个 60s 自旋整段落在 inline_day 的计时区间里，浏览器上表现为"首日卡 24 秒 ~
	# 彻底挂死"，而所有 native stage_ms 都只有 ~1ms。
	if bool(thread_report.get("native_daily_inline", false)):
		return false
	if int(thread_report.get("simulation_environment_generation", 0)) <= 0 \
			or bool(thread_report.get("climate_worker_authoritative", false)):
		return false
	if String(thread_report.get("requested_simulation_thread_mode", "")) != "ACTIVE" \
			or String(thread_report.get("state", "")) == "FAULTED":
		return false
	if (int(thread_report.get("requested_authority_mask", 0)) \
			& _generator.RUNTIME_CLIMATE_DOMAIN_BIT) == 0:
		return false
	return int(thread_report.get("simulation_committed_day", -1)) \
		< int(thread_report.get("simulation_environment_day", -1))


## Waits until the worker has committed the last captured day; if the grant did
## not land with it, it is not coming on a fixed day and waiting longer only stalls.

func _wait_climate_authority_grant() -> Dictionary:
	var ext = _generator._data_core_world_ext
	var started_ms := Time.get_ticks_msec()
	var report: Dictionary = _generator.get_runtime_thread_report()
	while _generator._climate_authority_grant_pending(report):
		if Time.get_ticks_msec() - started_ms > _generator.CLIMATE_AUTHORITY_GRANT_TIMEOUT_MS:
			push_warning("[climate-authority] grant wait timed out at day %d"
				% int(report.get("simulation_environment_day", -1)))
			break
		if ext != null:
			ext.wait_climate_consumed(_generator._runtime_input_generation, 10)
		OS.delay_usec(200)
		report = _generator.get_runtime_thread_report()
	return report



func _prime_scatter_sync_snapshot(map: MapData) -> void:
	if map == null or not map.has_soa():
		_generator._scatter_sync_snap_landform = PackedByteArray()
		_generator._scatter_sync_snap_vegetation = PackedByteArray()
		_generator._scatter_sync_snap_cover = PackedByteArray()
		return
	_generator._scatter_sync_snap_landform = map.landform_arr.duplicate()
	_generator._scatter_sync_snap_vegetation = map.vegetation_arr.duplicate()
	_generator._scatter_sync_snap_cover = map.cover_arr.duplicate()



func sync_detail_scatter_after_tick(map: MapData) -> void:
	if map == null or not map.has_soa():
		return
	var n: int = map.cell_count()
	var landform_a: PackedByteArray = map.landform_arr
	var vegetation_a: PackedByteArray = map.vegetation_arr
	var cover_a: PackedByteArray = map.cover_arr
	if _generator._scatter_sync_snap_vegetation.size() != n \
			or _generator._scatter_sync_snap_landform.size() != n \
			or _generator._scatter_sync_snap_cover.size() != n \
			or vegetation_a.size() != n or landform_a.size() != n \
			or cover_a.size() != n:
		_generator._prime_scatter_sync_snapshot(map)
		return
	# 快路径：PackedByteArray == 是原生 memcmp。权威脏源已有 pending 时只对齐快照，
	# 避免季节日再扫 2400 格并与 bus/changeset 双排队。
	var l_same: bool = _generator._scatter_sync_snap_landform == landform_a
	var c_same: bool = _generator._scatter_sync_snap_cover == cover_a
	var v_same: bool = _generator._scatter_sync_snap_vegetation == vegetation_a
	if l_same and c_same and v_same:
		return
	if _generator.has_pending_detail_scatter_refresh() and not _generator.detail_scatter_tick_sync_debug:
		_generator._prime_scatter_sync_snapshot(map)
		_generator._last_detail_scatter_sync["cells"] = 0
		_generator._last_detail_scatter_sync["vegetation_cells"] = 0
		_generator._last_detail_scatter_sync["skipped_pending"] = true
		return
	var changes = _generator.DetailScatterChangeSetScript.new()
	_generator._detail_scatter_change_generation += 1
	changes.generation = _generator._detail_scatter_change_generation
	var veg_changed := 0
	for i in range(n):
		var axis_mask := 0
		if not v_same and _generator._scatter_sync_snap_vegetation[i] != vegetation_a[i]:
			axis_mask |= _generator.DetailScatterChangeSetScript.AXIS_VEGETATION
			veg_changed += 1
		if not l_same and _generator._scatter_sync_snap_landform[i] != landform_a[i]:
			axis_mask |= _generator.DetailScatterChangeSetScript.AXIS_LANDFORM
		if not c_same and _generator._scatter_sync_snap_cover[i] != cover_a[i]:
			axis_mask |= _generator.DetailScatterChangeSetScript.AXIS_COVER
		if axis_mask != 0:
			changes.append_change(
				i, axis_mask,
				int(_generator._scatter_sync_snap_vegetation[i]), int(vegetation_a[i]),
				int(_generator._scatter_sync_snap_landform[i]), int(landform_a[i]),
				int(_generator._scatter_sync_snap_cover[i]), int(cover_a[i])
			)
	if changes.is_empty():
		_generator._prime_scatter_sync_snapshot(map)
		return
	_generator._prime_scatter_sync_snapshot(map)
	_generator._last_detail_scatter_sync["cells"] = changes.size()
	_generator._last_detail_scatter_sync["vegetation_cells"] = veg_changed
	_generator._last_detail_scatter_sync["skipped_pending"] = false
	_generator.queue_detail_scatter_changes(changes)
	if _generator.detail_scatter_tick_sync_debug:
		print("[detail_scatter] tick-sync queued=%d (vegetation=%d)" % [changes.size(), veg_changed])


# per-stage path once-log。每个 stage_key（如 "stage1"）在同一会话内最多打印一次路径来源。
# stage_key:  stage 标识，例如 "stage1" / "stage_swamp" / "stage0"
# path:       "gdext"（成功）/ "failed"（native 失败）
# detail:     reason / native_ms / 哪个 gate 拦下

func _season_log_path_once(stage_key: String, path: String, detail: String) -> void:
	# 同一 stage 同一 path 同一 detail 才算 dedup；path 切换（fallback→gdext）要重打。
	var k: String = "%s|%s|%s" % [stage_key, path, detail]
	if _generator._season_stage_path_logged.has(k):
		return
	_generator._season_stage_path_logged[k] = true
	print("[season_refresh] %s path=%s %s" % [stage_key, path, detail])


# X2-精简版（2026-05-21）：round 内 SoA-slots 同步守门员。
# 调用模式：每个 stage helper 进入时调本函数（替换原 if has_method+refresh_slots_from_map）。
# 行为：
#   - 若 _season_round_slots_fresh == true（同 round 已 refresh 过，且中间无 fallback 改 cell）
#     → 跳过 refresh_slots_from_map，省 ~14μs Variant get-loop。
#   - 若 false（首次或 round 边界）
#     → 调一次 refresh_slots_from_map，置 true。
# 注意：本 helper 仅用于 season_refresh round 内的 11 处 stage helper（含 micro-pass）。
# climate_pass_a / daily ECS 路径不在 round 内，**不要**改用本 helper。

func _ensure_season_round_slots_fresh() -> void:
	if _generator._data_core_world_ext == null:
		return
	if _generator._season_round_slots_fresh:
		_generator._season_round_slots_skip_count += 1
		return
	# Do not overwrite native-only Economy/resource slots or pay their copy
	# cost at a seasonal boundary.  Every B+ stage reads one of the keys above;
	# its outputs stay in the native slots and publish at their existing stage
	# boundary.
	if _generator._data_core_world_ext.has_method("refresh_slots_from_map_keys"):
		_generator._data_core_world_ext.refresh_slots_from_map_keys(_generator._season_round_refresh_keys)
	else:
		_generator._data_core_world_ext.refresh_slots_from_map()
	_generator._season_round_slots_fresh = true
	_generator._season_round_slots_refresh_count += 1


# refresh-consolidation-2026-06：climate daily round 内 SoA-slots 同步守门员。
# 见 _climate_daily_round_slots_fresh 注释。每个 climate sub-pass 入口调本函数
# 替换原 refresh_slots_from_map()。守门员逻辑与 season 版完全对称。

func _ensure_climate_daily_round_slots_fresh() -> void:
	if _generator._data_core_world_ext == null:
		return
	if _generator._climate_daily_round_slots_fresh:
		_generator._climate_daily_round_slots_skip_count += 1
		return
	_generator._data_core_world_ext.refresh_slots_from_map()
	_generator._climate_daily_round_slots_fresh = true
	_generator._climate_daily_round_slots_refresh_count += 1


# 跨 pass 边界 / fallback 写 cell / round 末尾时调用，让下一次
# _ensure_climate_daily_round_slots_fresh() 重新跑 refresh_slots_from_map()。

func _ensure_natural_resource_knobs() -> void:
	if _generator._natural_resource_pass_knobs.is_empty():
		_generator._natural_resource_pass_knobs = ResourceProfileRegistry.build_pass_knobs()
		_generator._natural_resource_refresh_keys = PackedStringArray([
			"cell_temp",
			"cell_temp_30d",
			"cell_moisture",
			"cell_plant_available_water",
			"cell_is_water",
			"cell_resource_habitat_mask",
		])
		var extra_slots: PackedStringArray = _generator._natural_resource_pass_knobs.get("extra_change_slots", PackedStringArray())
		for slot in extra_slots:
			if slot != "":
				_generator._natural_resource_refresh_keys.append(slot)
