extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const UNUSED_RESOURCES := {"freshwater_fish": "marine_fish", "plantation_land": "arable_land"}


func _run() -> void:
	# Retain the same building IDs and technology bindings. Only their
	# resource references change in this process's ResourceLoader cache.
	var profiles := EconomyCatalogScript._load_resources(EconomyCatalogScript.BUILDING_DIR)
	var changed := 0
	for profile in profiles:
		for property in ["resource_ids", "resource_generation_ids", "condition_reference_ids"]:
			var ids: PackedStringArray = profile.get(property)
			for index in range(ids.size()):
				if UNUSED_RESOURCES.has(ids[index]):
					ids[index] = UNUSED_RESOURCES[ids[index]]
					changed += 1
			profile.set(property, ids)
	_expect("fixture removed real resource references from buildings", changed > 0)
	var catalog := EconomyCatalogScript.compile_native_catalog()
	_expect("the authored fixture compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		print("RESOURCE_CATALOG_COMPILE=" + JSON.stringify(catalog))
		_finish()
		return
	for name in UNUSED_RESOURCES:
		var resource: int = catalog.building_resource_ids.find(name)
		_expect("compiled catalog keeps %s without building references" % name,
			resource >= 0 and not catalog.building_production_resource_ids.has(resource)
			and not catalog.building_resource_generation_ids.has(resource))
	LoadingCatalogCache._economy = catalog
	LoadingCatalogCache._ready = true
	await _run_world(false)
	LoadingCatalogCache.invalidate()
	_finish()


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var map := host.current_map()
	var knobs: Dictionary = generator._bio_occupancy_knob_cache
	var carrier: int = knobs.carrier_unique_ids.find("plantation_land")
	_expect("species configuration uses the resource without building references", carrier >= 0)
	var previous_fish := map.res_freshwater_fish_reserve_arr.duplicate()
	var previous_plantation := map.res_plantation_land_reserve_arr.duplicate()
	var previous_bits := map.bio_occupancy_bits_arr.duplicate()
	var fish_recovered := -1
	var plantation_recovered := -1
	var species_cell := -1
	var species_bit := -1
	clock.set_speed(SPEED)
	for day in range(1, 25):
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("catalog fixture commits day %d" % day, settled)
		if not settled:
			print("RESOURCE_CATALOG_UNSETTLED=" + JSON.stringify(generator.get_runtime_thread_report()))
			break
		for cell in range(map.cell_count()):
			if map.res_freshwater_fish_reserve_arr[cell] > previous_fish[cell]:
				fish_recovered = cell
			if map.res_plantation_land_reserve_arr[cell] > previous_plantation[cell]:
				plantation_recovered = cell
			if day % 8 == 0 and map.res_plantation_land_reserve_arr[cell] > 0.0:
				var added := map.bio_occupancy_bits_arr[cell] & ~previous_bits[cell]
				for species in range(knobs.species_carrier_index.size()):
					var bit: int = knobs.species_occupancy_bits[species]
					if knobs.species_carrier_index[species] == carrier \
							and knobs.species_carrier_alt_index[species] < 0 and added & (1 << bit):
						species_cell = cell
						species_bit = bit
		previous_fish = map.res_freshwater_fish_reserve_arr.duplicate()
		previous_plantation = map.res_plantation_land_reserve_arr.duplicate()
		previous_bits = map.bio_occupancy_bits_arr.duplicate()
		if fish_recovered >= 0 and plantation_recovered >= 0 and species_cell >= 0:
			break
	_expect("unused freshwater fish reserve increases on a committed day", fish_recovered >= 0)
	_expect("unused plantation reserve increases on a committed day", plantation_recovered >= 0)
	_expect("species expands into a cell where the unused resource is its only carrier", species_cell >= 0)
	print("RESOURCE_CATALOG_RESULT=" + JSON.stringify({
		"freshwater_fish_recovered_cell": fish_recovered, "plantation_land_recovered_cell": plantation_recovered,
		"species_cell": species_cell, "species_bit": species_bit,
	}))
	return {}
