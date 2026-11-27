extends RefCounted

## Optional pure-math acceleration. Dynamic lookup keeps web and older native
## libraries on the complete script algorithm without introducing parse deps.
static func create(context) -> RefCounted:
	if context.map == null or not ClassDB.class_exists("NativeResourceVisualBuilder"):
		return null
	var builder: RefCounted = ClassDB.instantiate("NativeResourceVisualBuilder")
	if builder == null or not builder.has_method("configure_slice") or not builder.has_method("select_cell") or not builder.has_method("append_style"):
		return null
	var values := inputs(context)
	if values.is_empty():
		return null
	var result: Dictionary = builder.call("configure_slice", values)
	return builder if bool(result.get("ok", false)) else null

static func inputs(context) -> Dictionary:
	var world: WorldData = context.world
	var profile: ResourceVisualProfile = context.profile
	var has_world := world != null
	var has_object_lookup := has_world and not world.pixel_to_cell_lookup.is_empty()
	var has_numeric_lookup := has_world and not world.pixel_owner_indices.is_empty() \
		and world.pixel_owner_indices.size() == int(world.derived_size.x) * int(world.derived_size.y)
	var has_lookup := has_object_lookup or has_numeric_lookup
	# The same bake publication owns object lookup and its pure-value columns.
	# Unknown/custom lookups use the script path; never rescan a raster per frame.
	var owner_index := world.pixel_owner_indices if has_lookup else PackedInt64Array()
	var owner_present := world.pixel_owner_present if has_lookup else PackedByteArray()
	if has_object_lookup and owner_index.size() != world.pixel_to_cell_lookup.size():
		return {}
	return {
		"families": context.inputs.families, "forms": context.inputs.forms,
		"land_plans": context.inputs.land_plans, "water_plans": context.inputs.water_plans,
		"priorities": context.priorities, "size_scales": context.size_scales, "allowed": context.allowed,
		"water": context.map.is_water_arr, "elevation": context.map.elevation_arr,
		"flow": world.flow_buffer if has_world else PackedFloat32Array(),
		"biome": world.biome_buffer if has_world else PackedByteArray(),
		"water_terrains": PackedInt32Array([TerrainType.TERRAIN.OCEAN, TerrainType.TERRAIN.COAST,
			TerrainType.TERRAIN.LAKE, TerrainType.TERRAIN.SEA_ICE]),
		"owner_index": owner_index, "owner_present": owner_present,
		"seed": context.seed, "type_cap": context.type_cap,
		"filter_direct": context.filter_direct, "filter_prefixed": context.filter_prefixed,
		"mineral_min_band": context.mineral_min_band, "lens": context.lens,
		"has_world": has_world, "has_lookup": has_lookup,
		"hex": context.hex, "animal_presence": context.animal_presence,
		"mineral_presence": context.mineral_presence, "plant_diameter": context.plant_diameter,
		"patch_diameter": context.patch_diameter, "fertility_diameter": context.fertility_diameter,
		"decal_diameter": context.decal_diameter, "cluster_spread": context.cluster_spread,
		"patch_noise_strength": context.patch_noise_strength, "density_scale": context.density_scale,
		"shoal_density": context.shoal_density, "herd_radius": context.herd_radius,
		"water_falloff": float(profile.water_depth_falloff), "river_clear": float(profile.river_clear_threshold),
		"sea": world.sea_level if has_world else 0.42, "wrap": world.wrap_period_x if has_world else 0.0,
		"bounds": world.world_bounds if has_world else Rect2(),
		"derived": world.derived_size if has_world else Vector2i(),
		"scale_min": 0.82, "scale_max": 1.22, "aspect_min": 0.78, "aspect_max": 1.28, "tau": TAU,
	}
