extends RefCounted


static func _bio_occupancy_base_knobs(owner: Variant, map_ref: MapData) -> Dictionary:
	var build_started_usec := Time.get_ticks_usec()
	if map_ref == null:
		return {"ok": false, "reason": "map_missing"}
	var n := map_ref.cell_count()
	var map_id := int(map_ref.get_instance_id())
	var cache_hit = owner._generator._bio_occupancy_knob_cache_version == owner._generator._BIO_OCCUPANCY_KNOB_CACHE_VERSION \
			and owner._generator._bio_occupancy_knob_cache_map_id == map_id \
			and owner._generator._bio_occupancy_knob_cache_n == n \
			and not owner._generator._bio_occupancy_knob_cache.is_empty()
	if not cache_hit:
		var catalog: Dictionary = owner._generator.ResearchSignalCatalogScript.compile_native_catalog()
		if not bool(catalog.get("ok", false)):
			return {"ok": false, "reason": String(catalog.get("reason", "catalog"))}
		var carrier_ids: PackedStringArray = catalog.get(
			"research_bio_carrier_ids", PackedStringArray())
		var carrier_alts: PackedStringArray = catalog.get(
			"research_bio_carrier_alt_ids", PackedStringArray())
		var unique_ids: Array[String] = []
		var index_of := {}
		for raw_id in carrier_ids:
			var id := String(raw_id)
			if id.is_empty() or index_of.has(id):
				continue
			index_of[id] = unique_ids.size()
			unique_ids.append(id)
		for raw_id in carrier_alts:
			var id := String(raw_id)
			if id.is_empty() or index_of.has(id):
				continue
			index_of[id] = unique_ids.size()
			unique_ids.append(id)
		var primary := PackedInt32Array()
		var alt := PackedInt32Array()
		var carrier_slot_names := PackedStringArray()
		for raw_id in unique_ids:
			var slot_name := ""
			for profile in ResourceProfileRegistry.ordered():
				if String(profile.id) == String(raw_id):
					slot_name = ResourceProfileRegistry.reserve_cpp_name(profile)
					break
			carrier_slot_names.append(slot_name)
		primary.resize(carrier_ids.size())
		alt.resize(carrier_alts.size())
		for i in range(carrier_ids.size()):
			var id := String(carrier_ids[i])
			primary[i] = int(index_of.get(id, -1)) if not id.is_empty() else -1
		for i in range(carrier_alts.size()):
			var id := String(carrier_alts[i])
			alt[i] = int(index_of.get(id, -1)) if not id.is_empty() else -1
		owner._generator._bio_occupancy_knob_cache = {
			"ok": true,
			"cell_count": n,
			"width": map_ref.width,
			"height": map_ref.height,
			"seed": owner._generator._last_seed,
			"neighbor_indices": map_ref.neighbor_indices_packed(),
			"species_signal_ids": catalog.get("research_bio_signal_ids", PackedInt32Array()),
			"species_occupancy_bits": catalog.get("research_bio_occupancy_bits", PackedInt32Array()),
			"species_carrier_index": primary,
			"species_carrier_alt_index": alt,
			"species_temp_lo": catalog.get("research_bio_temp_lo", PackedFloat32Array()),
			"species_temp_hi": catalog.get("research_bio_temp_hi", PackedFloat32Array()),
			"species_moist_lo": catalog.get("research_bio_moist_lo", PackedFloat32Array()),
			"species_moist_hi": catalog.get("research_bio_moist_hi", PackedFloat32Array()),
			"species_elev_lo": catalog.get("research_bio_elev_lo", PackedFloat32Array()),
			"species_elev_hi": catalog.get("research_bio_elev_hi", PackedFloat32Array()),
			"species_veg_mask0": catalog.get("research_bio_veg_mask0", PackedInt32Array()),
			"species_veg_mask1": catalog.get("research_bio_veg_mask1", PackedInt32Array()),
			"species_flags": catalog.get("research_bio_flags", PackedInt32Array()),
			"species_max_cost": catalog.get("research_bio_max_cost", PackedInt32Array()),
			"species_fill_keep": catalog.get("research_bio_fill_keep", PackedFloat32Array()),
			"species_origin_policy": catalog.get("research_bio_origin_policy", PackedInt32Array()),
			"species_guild": catalog.get("research_bio_guild", PackedInt32Array()),
			"species_habitat_class": catalog.get("research_bio_habitat_class", PackedInt32Array()),
			"carrier_ids": carrier_ids,
			"carrier_alts": carrier_alts,
			"carrier_unique_ids": unique_ids,
			"carrier_slot_names": carrier_slot_names,
		}
		owner._generator._bio_occupancy_knob_cache_map_id = map_id
		owner._generator._bio_occupancy_knob_cache_n = n
		owner._generator._bio_occupancy_knob_cache_version = owner._generator._BIO_OCCUPANCY_KNOB_CACHE_VERSION
		# 保底残存格可能落在目录气候带外：把地图本地气候边界写回，persist 才不会次日剔除。
		owner.BioOccupancyGuaranteeScript.realize_bounds(owner._generator._bio_occupancy_knob_cache, map_ref)
	var static_knobs: Dictionary = owner._generator._bio_occupancy_knob_cache
	if owner._generator._bio_occupancy_native_configured_map_id != map_id \
			and owner._generator._data_core_world_ext != null :
		var configured: Dictionary = owner._generator._data_core_world_ext.configure_bio_occupancy(static_knobs)
		if bool(configured.get("ok", false)):
			owner._generator._bio_occupancy_native_configured_map_id = map_id
	var empty := PackedFloat32Array()
	empty.resize(n)
	var columns: Array = []
	var unique_ids: Array = static_knobs.get("carrier_unique_ids", [])
	for raw_id in unique_ids:
		columns.append(owner._generator._bio_reserve_column(map_ref, String(raw_id), n, empty))
	var temperature: PackedFloat32Array = map_ref.temp_30d_arr
	if temperature.size() != n:
		temperature = map_ref.temp_arr
	var out: Dictionary = static_knobs.duplicate(false)
	out.merge({
		"cell_count": n,
		"is_water": map_ref.is_water_arr,
		"vegetation": map_ref.vegetation_arr,
		"landform": map_ref.landform_arr,
		"has_river": map_ref.has_river_arr,
		"temperature": temperature,
		"moisture": map_ref.moisture_arr,
		"elevation": map_ref.elevation_arr,
		"carrier_reserves": columns,
		"_knob_cache_hit": cache_hit,
		"_knob_cache_build_ms": (Time.get_ticks_usec() - build_started_usec) / 1000.0,
	})
	return out


static func _bio_occupancy_daily_knobs(owner: Variant, map_ref: MapData) -> Dictionary:
	if map_ref == null:
		return {"ok": false, "reason": "map_missing"}
	var map_id := int(map_ref.get_instance_id())
	if owner._generator._bio_occupancy_native_configured_map_id != map_id:
		var configured_knobs = owner._generator._bio_occupancy_base_knobs(map_ref)
		if not bool(configured_knobs.get("ok", false)):
			return configured_knobs
		if owner._generator._bio_occupancy_native_configured_map_id != map_id:
			# Native slots may be unavailable in a focused test harness. Preserve
			# the PackedArray A/B path instead of changing gameplay semantics.
			return configured_knobs
	return {
		"ok": true,
		"cell_count": map_ref.cell_count(),
		"seed": owner._generator._last_seed,
		"use_configured_slots": true,
		"_knob_cache_hit": true,
		"_knob_cache_build_ms": 0.0,
	}


static func _bio_reserve_column(owner: Variant, map_ref: MapData, resource_id: String, n: int,
		empty: PackedFloat32Array) -> PackedFloat32Array:
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field.is_empty():
			break
		var values: PackedFloat32Array = map_ref.get(field)
		if values.size() == n:
			return values
		break
	return empty


static func _publish_bio_occupancy_to_runtime(owner: Variant, map_ref: MapData) -> void:
	if map_ref == null:
		return
	var pairs := [
		[&"cell.bio_occupancy_bits", map_ref.bio_occupancy_bits_arr],
		[&"cell.landmass_id", map_ref.landmass_id_arr],
		[&"cell.province_id", map_ref.province_id_arr],
	]
	for pair in pairs:
		var component: StringName = pair[0]
		var values: PackedInt32Array = pair[1]
		if owner._generator._data_core_world != null and owner._generator._data_core_world.has_method("component_id") \
				and owner._generator._data_core_world.has_method("write_i32_range"):
			var cid := int(owner._generator._data_core_world.component_id(component))
			if cid >= 0:
				owner._generator._data_core_world.write_i32_range(cid, 0, values)
	if owner._generator._data_core_world_ext != null:
		owner._generator._data_core_world_ext.refresh_slots_from_map_keys(PackedStringArray([
			"cell_bio_occupancy_bits", "cell_landmass_id", "cell_province_id"]))
	map_ref.publish_resource_visual_inputs(MapData.RESOURCE_VISUAL_BANDS)


static func _seed_bio_occupancy(owner: Variant, map_ref: MapData) -> void:
	if map_ref == null or owner._generator._data_core_world_ext == null:
		push_error("[bio-occupancy] native province/seed pass unavailable")
		return
	var knobs = owner._generator._bio_occupancy_base_knobs(map_ref)
	if not bool(knobs.get("ok", false)):
		push_error("[bio-occupancy] species knobs failed: %s" % String(knobs.get("reason", "unknown")))
		return
	var province_res: Dictionary = {}
	var seed_res: Dictionary = {}
	seed_res = owner._generator._data_core_world_ext.run_bio_bootstrap_pass(knobs)
	if not bool(seed_res.get("ok", false)):
		push_error("[bio-occupancy] bootstrap pass failed: %s" % String(
			seed_res.get("reason", "unknown")))
		return
	province_res = seed_res
	var n := map_ref.cell_count()
	var landmass: PackedInt32Array = province_res.get("landmass_ids", PackedInt32Array())
	var provinces: PackedInt32Array = province_res.get("province_ids", PackedInt32Array())
	if landmass.size() != n or provinces.size() != n:
		push_error("[bio-occupancy] province output shape invalid")
		return
	map_ref.landmass_id_arr = landmass
	map_ref.province_id_arr = provinces
	knobs["province_ids"] = provinces
	knobs["landmass_ids"] = landmass
	if seed_res.is_empty():
		seed_res = owner._generator._data_core_world_ext.run_bio_seed_pass(knobs)
		if not bool(seed_res.get("ok", false)):
			push_error("[bio-occupancy] seed pass failed: %s" % String(
				seed_res.get("reason", "unknown")))
			return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	if occupancy.size() != n:
		push_error("[bio-occupancy] occupancy output shape invalid")
		return
	map_ref.bio_occupancy_bits_arr = occupancy
	owner._generator._publish_bio_occupancy_to_runtime(map_ref)
	owner._generator._log_bio_occupancy_seed(knobs, seed_res, int(province_res.get("landmass_count", 0)),
		int(province_res.get("province_count", 0)))
	owner.BioOccupancyGuaranteeScript.ensure_after_boot(owner._generator, map_ref, seed_res)


static func _log_bio_occupancy_seed_summary(owner: Variant, knobs: Dictionary, seed_res: Dictionary,
		landmass_count: int, province_count: int) -> void:
	var catalog: Dictionary = owner._generator.ResearchSignalCatalogScript.compile_native_catalog()
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var signal_ids: PackedInt32Array = knobs.get("species_signal_ids", PackedInt32Array())
	var envelope: PackedInt32Array = seed_res.get("envelope_cell_counts", PackedInt32Array())
	var origin_envelope: PackedInt32Array = seed_res.get("origin_envelope_cell_counts", PackedInt32Array())
	var occupied: PackedInt32Array = seed_res.get("occupied_cell_counts", PackedInt32Array())
	var origins: PackedInt32Array = seed_res.get("origin_landmass_ids", PackedInt32Array())
	var seeded: PackedInt32Array = seed_res.get("seeded_landmass_counts", PackedInt32Array())
	var hearths: PackedInt32Array = seed_res.get("hearth_cell_counts", PackedInt32Array())
	print("[bio-occupancy] seed landmasses=%d provinces=%d species=%d secondary_hearths=%d" % [
		landmass_count, province_count, signal_ids.size(),
		int(seed_res.get("secondary_hearth_count", 0))])
	for i in range(signal_ids.size()):
		var sid := int(signal_ids[i])
		var signal_name := String(ids[sid]) if sid >= 0 and sid < ids.size() else "?"
		var env_n := int(envelope[i]) if i < envelope.size() else 0
		var origin_n := int(origin_envelope[i]) if i < origin_envelope.size() else 0
		var occ_n := int(occupied[i]) if i < occupied.size() else 0
		var origin_id := int(origins[i]) if i < origins.size() else 0
		var seeded_n := int(seeded[i]) if i < seeded.size() else 0
		var hearth_n := int(hearths[i]) if i < hearths.size() else occ_n
		var fill_ratio := (float(occ_n) / float(origin_n)) if origin_n > 0 else 0.0
		print("[bio-occupancy]   %s envelope=%d hearth=%d seeded_landmasses=%d primary_landmass=%d primary_envelope=%d occupied=%d occupied/envelope=%.2f" % [
			signal_name, env_n, hearth_n, seeded_n, origin_id, origin_n, occ_n, fill_ratio])


static func _log_bio_occupancy_seed(owner: Variant, knobs: Dictionary, seed_res: Dictionary, landmass_count: int,
		province_count: int) -> void:
	owner.BioOccupancyGuaranteeScript.log_seed(knobs, seed_res, landmass_count, province_count,
		owner._generator)


static func _log_bio_occupancy_seed_native(owner: Variant, report: Dictionary, knobs: Dictionary) -> void:
	owner._generator._log_bio_occupancy_seed_summary(knobs, report,
		int(report.get("bio_log_landmass_count", 0)),
		int(report.get("bio_log_province_count", 0)))
	var landmass_ids: PackedInt32Array = report.get(
		"bio_log_landmass_ids", PackedInt32Array())
	var classes: PackedStringArray = report.get(
		"bio_log_classes", PackedStringArray())
	var foods: PackedStringArray = report.get(
		"bio_log_foods", PackedStringArray())
	if classes.size() != landmass_ids.size() or foods.size() != landmass_ids.size():
		return
	for i in range(landmass_ids.size()):
		print("[bio-occupancy]   landmass %d classes=%s foods=%s" % [
			int(landmass_ids[i]), String(classes[i]), String(foods[i])])


static func _bio_landmass_summary_gdscript(owner: Variant, occupancy: PackedInt32Array,
		landmass: PackedInt32Array, knobs: Dictionary,
		out_landmass: PackedInt32Array, out_classes: PackedStringArray,
		out_foods: PackedStringArray) -> void:
	owner.BioSummary.summarize(owner._generator, occupancy, landmass, knobs,
		out_landmass, out_classes, out_foods)


static func run_bio_occupancy_pass_native(owner: Variant, map_ref, run_diffusion: bool = false,
		day_index: int = 0, slice_enabled: bool = false,
		bio_slice_cells: int = 2048) -> Dictionary:
	if map_ref == null or owner._generator._data_core_world_ext == null :
		return {"ok": false, "path": "skip", "reason": "native_unavailable"}
	var knobs = owner._generator._bio_occupancy_daily_knobs(map_ref)
	if not bool(knobs.get("ok", false)):
		return knobs
	if not bool(knobs.get("use_configured_slots", false)):
		knobs["province_ids"] = map_ref.province_id_arr
		knobs["occupancy_bits"] = map_ref.bio_occupancy_bits_arr
	knobs["run_diffusion"] = run_diffusion
	knobs["day_index"] = day_index
	knobs["slice_enabled"] = slice_enabled
	var observation_handle: int = owner._generator._resolve_bio_observation_country_handle()
	if observation_handle != 0:
		knobs["observation_country_handle"] = observation_handle
		knobs["observation_effective_day"] = day_index + 1
	# Keep phase boundaries (persistence/diffusion/merge/publish) preemptible
	# while using a fixed deterministic range per call. The round is frozen by
	# WorldClock until the final publish, so no partial occupancy is visible.
	if slice_enabled:
		knobs["bio_slice_cells"] = clampi(bio_slice_cells, 2048, 32768)
	# The first sliced call captures the full input snapshot.  Subsequent fixed
	# cursor calls reuse native staging and must not refresh/copy MapData again.
	if not owner._generator._bio_occupancy_slice_inflight:
		var refresh_keys := PackedStringArray([
			"cell_bio_occupancy_bits",
			"cell_province_id",
			"cell_temp_30d",
			"cell_moisture",
			"cell_landform",
			"cell_vegetation",
		])
		for slot_name in owner._generator._bio_occupancy_knob_cache.get(
				"carrier_slot_names", PackedStringArray()):
			if not refresh_keys.has(slot_name):
				refresh_keys.append(slot_name)
		owner._generator._data_core_world_ext.refresh_slots_from_map_keys(refresh_keys)
	var res: Dictionary = owner._generator._data_core_world_ext.run_bio_occupancy_slice(knobs) \
			if slice_enabled else owner._generator._data_core_world_ext.run_bio_occupancy_pass(knobs)
	res["bio_knob_cache_hit"] = bool(knobs.get("_knob_cache_hit", false))
	res["bio_knob_cache_build_ms"] = float(knobs.get("_knob_cache_build_ms", 0.0))
	if not bool(res.get("ok", false)) and slice_enabled:
		# A failed slice never publishes partial staging.  Retry the legacy pass
		# with the same knobs so feature-flag rollback remains lossless.
		var fallback_res: Dictionary = owner._generator._data_core_world_ext.run_bio_occupancy_pass(knobs)
		fallback_res["path"] = "gdext_one_shot_fallback"
		fallback_res["bio_slice_fallback_reason"] = str(res.get("reason", "slice_failed"))
		fallback_res["fallback_reason"] = str(res.get("reason", "slice_failed"))
		fallback_res["fail_stage"] = str(res.get("fail_stage", "bio_occupancy_slice"))
		res = fallback_res
		owner._generator._bio_occupancy_slice_inflight = false
	if bool(res.get("ok", false)):
		var slice_done := bool(res.get("done", true))
		owner._generator._bio_occupancy_slice_inflight = slice_enabled and not slice_done
		if not slice_done:
			return res
		var occupancy: PackedInt32Array = res.get("occupancy_bits", PackedInt32Array())
		if occupancy.size() == map_ref.cell_count():
			map_ref.bio_occupancy_bits_arr = occupancy
			owner._generator._publish_bio_occupancy_to_runtime(map_ref)
			res["published_to_slot"] = true
	return res
