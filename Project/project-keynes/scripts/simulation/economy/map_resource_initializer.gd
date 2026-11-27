extends "res://scripts/simulation/economy/map_resource_deposits.gd"

## Publish initial resources and schedule daily resource recovery.

const BioOccupancyGuaranteeScript = preload("res://scripts/geography/map_generation/bio_occupancy_guarantee.gd")


## `_log_bio_occupancy_seed()` 的诊断名字表。融合 pass 的 C++ 聚合段与 GDScript
## 兜底段共用这一份，保证两条路径打印逐字相同。

func _build_resource_signal_knobs(map_ref: MapData) -> Dictionary:
	var catalog: Dictionary = _generator.TechnologyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		push_error("[research-signals] resource catalog compile failed")
		return {}
	if map_ref == null or map_ref.cell_count() <= 0:
		return {}
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var dense := PackedInt32Array()
	for profile in ResourceProfileRegistry.ordered():
		var signal_index := ids.find("resource.%s" % String(profile.id))
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if signal_index < 0 or field.is_empty():
			push_error("[research-signals] resource signal binding missing: %s" % String(profile.id))
			return {}
		dense.append(signal_index)
	if map_ref.cell_research_signal_offsets.size() != map_ref.cell_count() + 1:
		push_error("[research-signals] static signal CSR missing")
		return {}
	return {
		"cell_signal_offsets": map_ref.cell_research_signal_offsets,
		"cell_signal_ids": map_ref.cell_research_signal_ids,
		"cell_signal_values": map_ref.cell_research_signal_values,
		"resource_signal_ids": dense,
	}


func _publish_bootstrapped_natural_resources_to_runtime(map_ref: MapData) -> void:
	if map_ref == null:
		return
	var habitat_component := &"cell.resource_habitat_mask"
	if _generator._data_core_world != null and _generator._data_core_world.has_method("component_id") \
			and _generator._data_core_world.has_method("write_u8_range"):
		var habitat_cid := int(_generator._data_core_world.component_id(habitat_component))
		if habitat_cid >= 0:
			_generator._data_core_world.write_u8_range(
				habitat_cid, 0, map_ref.resource_habitat_mask_arr)
	if _generator._data_core_world_ext != null :
		var habitat_cid_ext := int(_generator._data_core_world_ext.component_id(&"cell_resource_habitat_mask"))
		if habitat_cid_ext >= 0:
			_generator._data_core_world_ext.write_u8_range(
				habitat_cid_ext, 0, map_ref.resource_habitat_mask_arr)
	for profile in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field.is_empty():
			continue
		var values: PackedFloat32Array = map_ref.get(field)
		if _generator._data_core_world != null and _generator._data_core_world.has_method("component_id") \
				and _generator._data_core_world.has_method("write_f32_range"):
			var cid := int(_generator._data_core_world.component_id(profile.reserve_component))
			if cid >= 0:
				_generator._data_core_world.write_f32_range(cid, 0, values)
		if _generator._data_core_world_ext != null :
			# Native slots use schema cpp_name, not the dotted GDScript name.
			var cid_ext := int(_generator._data_core_world_ext.component_id(
				ResourceProfileRegistry.reserve_cpp_name(profile)))
			if cid_ext >= 0:
				_generator._data_core_world_ext.write_f32_range(cid_ext, 0, values)


# 每日资源 pass 入口（由 NaturalResourceDailySystem.tick 调）。
# 优先 C++ run_natural_resource_pass（slot 权威 + flush 回 MapData）；
# native 不可用 / 未发布时退回 GDScript fallback 同模板。

func _on_modifier_events_available(batch: Dictionary) -> void:
	# Modifier events are emitted after the native modifier commit and before
	# downstream economy/resource consumers in the same daily graph. Only the
	# Economy domain can affect natural-resource regen factors; climate/country/
	# gameplay events leave this cache valid.
	var domains: PackedInt32Array = batch.get("domains", PackedInt32Array())
	for domain in domains:
		if int(domain) == _generator.ModifierFacadeScript.Domain.ECONOMY:
			_generator._natural_resource_regen_factors_valid = false
			return



func _prime_natural_resource_regen_factors(n_cells: int) -> Dictionary:
	if n_cells <= 0 or _generator._data_core_world_ext == null :
		return {"ok": false, "reason": "regen_factor_api_unavailable"}
	_generator._ensure_natural_resource_knobs()
	var factor_started: int = Time.get_ticks_usec()
	var factor_result: Dictionary = _generator._data_core_world_ext.get_natural_resource_regen_factors(
		_generator._natural_resource_pass_knobs.get("resource_ids", PackedStringArray()), n_cells)
	_generator._natural_resource_regen_factor_prime_ms = (
		Time.get_ticks_usec() - factor_started) / 1000.0
	if bool(factor_result.get("ok", false)):
		_generator._natural_resource_pass_knobs["regen_factors"] = factor_result.get(
			"factors", PackedFloat32Array())
		_generator._natural_resource_pass_knobs["regen_modifier_snapshot_version"] = int(
			factor_result.get("snapshot_version", 0))
		_generator._natural_resource_pass_knobs["active_regen_factor_count"] = int(
			factor_result.get("active_factor_count", 0))
		_generator._natural_resource_regen_factors_valid = true
	return factor_result


func _bio_log_food_bits() -> PackedInt32Array:
	var catalog: Dictionary = _generator.ResearchSignalCatalogScript.compile_native_catalog()
	var bits := PackedInt32Array()
	for food_id in _generator.BIO_LOG_FOOD_IDS:
		bits.append(_generator.ResearchSignalCatalogScript.occupancy_bit_for_signal(
			catalog, StringName(food_id)))
	return bits


## carrier_unique_ids → reserve 字段名。查找规则与 `_bio_reserve_column()` 逐行一致：
## 取 ResourceProfileRegistry.ordered() 里第一个 id 匹配的资源的 reserve 字段；
## 匹配不到给 ""（对应老链路的空列）。
## 融合路径里 MapData 的 reserve 字段还没写入（矿藏与生态在同一次 native 调用里
## 才算），所以把字段名交给 C++，让它从矿藏输出按名对齐取列。

func _bio_carrier_reserve_fields(knobs: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for raw_id in knobs.get("carrier_unique_ids", []):
		out.append(_generator._bio_reserve_field_for(String(raw_id)))
	return out



func _bio_reserve_field_for(resource_id: String) -> String:
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) != resource_id:
			continue
		return ResourceProfileRegistry.reserve_map_field(profile)
	return ""


## 构造资源研究信号合并（mode=resources）的 knobs。储量列由融合 pass 直接取矿藏
## pass 的输出填进去；旧链路则由 `_append_natural_resource_research_signals()` 从
## MapData 的 reserve 字段取。两边数值同源。

func _bootstrap_world_facades(map_ref, cfg) -> bool:
	if map_ref == null or _generator._data_core_world_ext == null:
		return false
	if _generator._boot_facade_disabled_for_ab():
		return false
	var n_cells: int = map_ref.cell_count()
	if n_cells <= 0:
		return false
	var deposit_knobs: Dictionary = _generator._get_map_resource_initializer()._build_resource_deposit_knobs(map_ref, cfg)
	if deposit_knobs.is_empty():
		return false
	var signal_knobs: Dictionary = _generator._get_map_resource_initializer()._build_resource_signal_knobs(map_ref)
	if signal_knobs.is_empty():
		return false
	var bio_knobs: Dictionary = _generator._bio_occupancy_base_knobs(map_ref)
	if not bool(bio_knobs.get("ok", false)):
		return false
	# 融合路径里 MapData 的 reserve 字段还没写入（矿藏与生态在同一次 native 调用
	# 里才算），因此把「carrier → reserve 字段名」交给 C++ 从矿藏输出对齐取列，
	# 并把此刻必然全 0 的 carrier_reserves 拆掉（省 20×n 次 Variant 拷贝）。
	bio_knobs.erase("carrier_reserves")
	bio_knobs["carrier_reserve_fields"] = _generator._bio_carrier_reserve_fields(bio_knobs)
	var started := Time.get_ticks_usec()
	var report: Dictionary = _generator._data_core_world_ext.run_boot_facade_pass({
		"cell_count": n_cells,
		"is_water": map_ref.is_water_arr,
		"landform": map_ref.landform_arr,
		"has_river": map_ref.has_river_arr,
		"river_flow": map_ref.river_flow_arr,
		"river_downstream": map_ref.river_downstream_arr,
		"neighbor_indices": map_ref.neighbor_indices_packed(),
		"habitat_mask_in": map_ref.resource_habitat_mask_arr,
		"run_deposits": true,
		"deposit": deposit_knobs,
		"deposit_knob_sig": _generator._knob_signature(deposit_knobs),
		"run_signals": true,
		"resource_signals": signal_knobs,
		"run_bio": true,
		"bio": bio_knobs,
		"bio_food_names": PackedStringArray(_generator.BIO_LOG_FOOD_NAMES),
		"bio_food_bits": _generator._bio_log_food_bits(),
		"bio_class_names": PackedStringArray(_generator.BIO_LOG_CLASS_NAMES),
	})
	if not bool(report.get("ok", false)) \
			or not bool(report.get("deposit_ok", false)) \
			or not bool(report.get("signal_ok", false)) \
			or not bool(report.get("bio_ok", false)):
		push_warning("[boot-facades] native pass declined (%s); diagnostics=%s; falling back per stage" % [
			String(report.get("reason",
				report.get("deposit_reason",
					report.get("signal_reason",
						report.get("bio_reason", "unknown"))))),
			str({"stages": report.get("stage_ms", {}),
				"bio_carriers": [report.get("bio_carrier_declared", -1),
					report.get("bio_carrier_used", -1)],
				"deposit_fields": (report.get("deposit_fields", PackedStringArray()) as PackedStringArray).size(),
				"reserves": (report.get("deposit_reserves", []) as Array).size()})])
		return false
	if not report.has_all(["deposit_quota_cells", "deposit_quota_unmet"]):
		push_warning("[boot-facades] native pass lacks landmass quotas; falling back per stage")
		return false
	var wall_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var fields: PackedStringArray = report.get("deposit_fields", PackedStringArray())
	var reserves: Array = report.get("deposit_reserves", [])
	if fields.is_empty() or fields.size() != reserves.size():
		push_warning("[boot-facades] deposit shape mismatch; falling back per stage")
		return false
	# ── 解包：整数组赋值 / set()，无 per-cell GDScript 循环 ─────────────────
	map_ref.resource_habitat_mask_arr = report.get("habitat_mask", PackedByteArray())
	for i in range(fields.size()):
		map_ref.set(fields[i], reserves[i])
	map_ref.cell_research_signal_offsets = report.get(
		"cell_signal_offsets", PackedInt32Array())
	map_ref.cell_research_signal_ids = report.get(
		"cell_signal_ids", PackedInt32Array())
	map_ref.cell_research_signal_values = report.get(
		"cell_signal_values", PackedInt32Array())
	map_ref.landmass_id_arr = report.get("landmass_ids", PackedInt32Array())
	map_ref.province_id_arr = report.get("province_ids", PackedInt32Array())
	map_ref.bio_occupancy_bits_arr = report.get("occupancy_bits", PackedInt32Array())
	_generator._publish_bio_occupancy_to_runtime(map_ref)
	print(("[boot-facades] path=gdext resources=%d cells=%d wall_ms=%.1f native_ms=%.1f"
		+ " quota_cells=%d quota_unmet=%d stages=%s") % [
		fields.size(), n_cells, wall_ms, float(report.get("elapsed_ms", 0.0)),
		int(report.get("deposit_quota_cells", 0)), int(report.get("deposit_quota_unmet", 0)),
		str(report.get("stage_ms", {}))])
	_generator._log_bio_occupancy_seed_native(report, bio_knobs)
	BioOccupancyGuaranteeScript.ensure_after_boot(_generator, map_ref, report)
	return true


## 矿藏 pass 输入数组的指纹：用于诊断融合 pass 的输入是否稳定。

func _knob_signature(knobs: Dictionary) -> int:
	var keys := [
		"temperature", "moisture", "elevation", "terrain", "vegetation", "landform", "is_water",
		"has_river", "is_lake", "has_volcano", "ocean_x", "ocean_y", "upwelling",
		"pos_x", "pos_y", "scalars", "field_names", "habitat_codes",
		"lf_keys", "lf_vals", "lf_offsets", "veg_keys", "veg_vals", "veg_offsets",
		"excluded_terrain", "excluded_vegetation",
	]
	var sig := 0
	for key in keys:
		sig = int((sig * 1000003 + hash(knobs.get(key))) & 0x3FFFFFFFFFFFFFFF)
	return sig



func run_natural_resource_pass_native(
		map_ref,
		dt_days: int = 1,
		cell_indices: PackedInt32Array = PackedInt32Array(),
		cell_dt_days: PackedInt32Array = PackedInt32Array(),
		schedule_day: int = -1, live_cells: PackedInt32Array = PackedInt32Array(),
		live_catchup: bool = false) -> Dictionary:
	var t_wall: int = Time.get_ticks_usec()
	if map_ref == null:
		return _generator._remember_natural_resource_report({"done": true, "path": "skip", "published_to_slot": false})
	var n_cells: int = map_ref.cell_count()
	if n_cells <= 0:
		return _generator._remember_natural_resource_report({"done": true, "path": "skip", "published_to_slot": false})
	var knob_update_started: int = Time.get_ticks_usec()
	_generator._ensure_natural_resource_knobs()
	var knob_update_ms: float = (Time.get_ticks_usec() - knob_update_started) / 1000.0
	if int(_generator._natural_resource_pass_knobs.get("resource_count", 0)) <= 0:
		return _generator._remember_natural_resource_report({"done": true, "path": "no_resources", "published_to_slot": false})
	var factor_lookup_ms: float = 0.0
	if not _generator._natural_resource_regen_factors_valid:
		var factor_started: int = Time.get_ticks_usec()
		_generator._prime_natural_resource_regen_factors(n_cells)
		factor_lookup_ms = (Time.get_ticks_usec() - factor_started) / 1000.0
		if not _generator._natural_resource_regen_factors_valid:
			# Preserve the legacy no-modifier behavior when the optional getter is
			# unavailable. An empty factor table means an exact multiplier of 1.0.
			_generator._natural_resource_pass_knobs.erase("regen_factors")
			_generator._natural_resource_pass_knobs["regen_modifier_snapshot_version"] = 0
			_generator._natural_resource_pass_knobs["active_regen_factor_count"] = 0
			_generator._natural_resource_regen_factors_valid = true

	var native_reason: String = "native_unavailable"
	if _generator._data_core_world_ext != null:
		native_reason = "native_failed"
		var refresh_ms: float = 0.0
		var refresh_started: int = 0
		refresh_started = Time.get_ticks_usec()
		_generator._data_core_world_ext.refresh_slots_from_map_keys(_generator._natural_resource_refresh_keys)
		refresh_ms = (Time.get_ticks_usec() - refresh_started) / 1000.0
		_generator._natural_resource_pass_knobs["n_cells"] = n_cells
		_generator._natural_resource_pass_knobs["dt_days"] = dt_days
		if schedule_day >= 0:
			_generator._natural_resource_pass_knobs["schedule_day"] = schedule_day
			_generator._natural_resource_pass_knobs["scheduled_live_cells"] = live_cells
			_generator._natural_resource_pass_knobs["live_catchup"] = live_catchup
		else:
			_generator._natural_resource_pass_knobs.erase("schedule_day")
			_generator._natural_resource_pass_knobs.erase("scheduled_live_cells")
			_generator._natural_resource_pass_knobs.erase("live_catchup")
		if cell_indices.is_empty():
			_generator._natural_resource_pass_knobs.erase("cell_indices")
			_generator._natural_resource_pass_knobs.erase("cell_dt_days")
		else:
			_generator._natural_resource_pass_knobs["cell_indices"] = cell_indices
			if cell_dt_days.size() == cell_indices.size():
				_generator._natural_resource_pass_knobs["cell_dt_days"] = cell_dt_days
			else:
				_generator._natural_resource_pass_knobs.erase("cell_dt_days")
		knob_update_ms = (Time.get_ticks_usec() - knob_update_started) / 1000.0
		var native_call_started: int = Time.get_ticks_usec()
		var res: Dictionary = _generator._data_core_world_ext.run_natural_resource_pass(_generator._natural_resource_pass_knobs)
		native_reason = String(res.get("reason", res.get("fallback_reason", "native_failed")))
		var native_call_ms: float = (Time.get_ticks_usec() - native_call_started) / 1000.0
		res["factor_lookup_ms"] = factor_lookup_ms
		res["slot_refresh_ms"] = refresh_ms
		res["knob_update_ms"] = knob_update_ms
		res["native_call_ms"] = native_call_ms
		if bool(res.get("published_to_slot", false)):
			res["wrapper_wall_ms"] = (Time.get_ticks_usec() - t_wall) / 1000.0
			res["wrapper_overhead_ms"] = max(0.0, float(res.get("wrapper_wall_ms", 0.0)) - float(res.get("native_ms", 0.0)))
			return _generator._remember_natural_resource_report(res)
	push_error("[natural_resource] native failed: %s; previous resource fields retained" % native_reason)
	return _generator._remember_natural_resource_report({
		"done": false,
		"path": "native_failed",
		"status": "failed",
		"reason": native_reason,
		"published_to_slot": false,
		"factor_lookup_ms": factor_lookup_ms,
		"knob_update_ms": knob_update_ms,
		"dt_days": dt_days,
		"indexed_cell_count": cell_indices.size() if not cell_indices.is_empty() else n_cells,
		"wrapper_wall_ms": (Time.get_ticks_usec() - t_wall) / 1000.0,
	})



func run_natural_resource_pass_scheduled(map_ref, day: int, live_cells: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return run_natural_resource_pass_native(map_ref, 1, PackedInt32Array(), PackedInt32Array(), maxi(0, day), live_cells)


func catchup_natural_resources_for_live_cells(day: int) -> Dictionary:
	return run_natural_resource_pass_native(_generator._sus_map, 1, PackedInt32Array(),
		PackedInt32Array(), maxi(0, day), _generator.economy_live_cells(), true)


func dump_climate_daily_round_slots_stats() -> Dictionary:
	var out: Dictionary = {
		"refresh_count": _generator._climate_daily_round_slots_refresh_count,
		"skip_count": _generator._climate_daily_round_slots_skip_count,
	}
	_generator._climate_daily_round_slots_refresh_count = 0
	_generator._climate_daily_round_slots_skip_count = 0
	return out


func _run_season_refresh_stage8_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp = _generator._c()
	# Native stage 8 is authoritative; cp only supplies the seasonal gate.
	if cp == null:
		_generator._season_log_path_once("stage8", "gdscript_fallback", "cp null")
		return false
	if _generator._last_cfg == null or map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage8", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	_generator._ensure_season_round_slots_fresh()
	var knobs: Dictionary = {
		"stage": 8,
		"n_cells": map.cell_count(),
		"sea_level": _generator._last_cfg.sea_level,
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_generator._season_log_path_once("stage8", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_generator._sync_stage8_facade_fields_from_soa(map)
	_generator._last_season_refresh_breakdown["stage_8_path"] = "gdext"
	_generator._last_season_refresh_breakdown["stage_8_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_generator._season_log_path_once("stage8", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# Native stage 11 feedback decay. Native failure is reported to the season
# coordinator and leaves the previous feedback fields untouched.
