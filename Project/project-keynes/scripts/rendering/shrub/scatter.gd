extends RefCounted

const CellAppearance = preload("res://scripts/rendering/shrub/cell_appearance.gd")

const CellSuitability = preload("res://scripts/rendering/shrub/cell_suitability.gd")

const VegetationColors = preload("res://scripts/rendering/shrub/vegetation_colors.gd")

const DECORATION_VEG_RESIDUAL := 0.12

## Stateless scatter and ecology helpers for ShrubLayer.

static func _cell_quota(host, suitability: float, max_per_cell: int) -> Vector2:
	return CellSuitability._cell_quota(host, suitability, max_per_cell)


static func _cell_suitability(host, cell, idx: int, _key: int, state: Dictionary) -> float:
	return CellSuitability._cell_suitability(host, cell, idx, _key, state)


static func _biomass_factor(host, veg: int) -> float:
	return CellSuitability._biomass_factor(host, veg)


static func _river_density_factor(host, state: Dictionary) -> float:
	return CellSuitability._river_density_factor(host, state)


static func _elevation_modifier(host, arch: int, elev: float) -> float:
	return CellSuitability._elevation_modifier(host, arch, elev)


static func _wind_exposure_modifier(host, arch: int, wind_speed: float) -> float:
	return CellSuitability._wind_exposure_modifier(host, arch, wind_speed)


static func _archetype_affinity(host, arch: int, veg: int, lf: int, _cover: int, river: bool, state: Dictionary) -> float:
	return CellSuitability._archetype_affinity(host, arch, veg, lf, _cover, river, state)


static func _is_decoration_archetype(host, arch: int) -> bool:
	return CellSuitability._is_decoration_archetype(host, arch)


static func _aquatic_suitability(host, _arch: int, lf: int, veg: int, cover: int, state: Dictionary) -> float:
	return CellSuitability._aquatic_suitability(host, _arch, lf, veg, cover, state)


static func _decoration_suitability(host, arch: int, lf: int, cover: int, river: bool, state: Dictionary) -> float:
	return CellSuitability._decoration_suitability(host, arch, lf, cover, river, state)


static func _decoration_vegetation_filter(host, veg: int) -> float:
	return CellSuitability._decoration_vegetation_filter(host, veg)


static func _try_append_instance(host, 
		cell,
		idx: int,
		key: int,
		attempt: int,
		cell_suitability: float,
		accept_p: float,
		state: Dictionary) -> void:

	var cfg = _profile(host)
	var climate_presence = _scatter_presence(host, state)
	if climate_presence <= 0.02:
		return
	var vitality = clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	if vitality <= cfg.vitality_dead_threshold:
		var dieback_noise = host._hash01(key, 931 + attempt)
		if dieback_noise < 1.0 - cfg.vitality_dieback_noise_strength:
			return
	var center = _cell_center(host, cell, idx)
	var pos = _candidate_position(host, center, key, attempt)
	var domain = _spawn_domain(host)
	var world_noise = _world_noise_suitability(host, pos)
	if world_noise <= 0.001:
		return
	var form = _candidate_form(host, key, attempt, world_noise, cell_suitability,
		clampf(_sample_density_for_size(host, idx, cell), 0.0, 1.0))
	var size = form.z
	# Candidate discs intentionally overlap adjacent hexes. Check the actual
	# destination cell and its six neighbours, not the source cell, so a canopy
	# spawned across a boundary cannot intrude into a known settlement.
	if domain != host.SPAWN_WATER and _overlaps_known_settlement(host, pos, size):
		return
	var candidate_is_water = _is_water_position(host, pos, cell, idx)
	if domain == host.SPAWN_LAND and candidate_is_water:
		return
	if domain == host.SPAWN_WATER and not candidate_is_water:
		return
	if domain != host.SPAWN_WATER and _is_river_body_position(host, pos):
		return
	var micro_noise = _world_micro_gap(host, pos, key, attempt)
	if micro_noise < cfg.micro_gap_threshold:
		return
	# world_noise_acceptance 现在只作用在斑块门上（决定噪声多快饱和到"满密度"），
	# 不再乘进密度量级。它原本是用来补偿 suitability² 压缩的，配额化之后如果继续
	# 乘在量级上，accept_p 只要超过 1/acceptance 就会被 clamp 到 1，顶端差异又被抹平。
	var noise_gate = pow(clampf(world_noise, 0.0, 1.0), 1.35)
	var patch_gate = clampf(noise_gate * cfg.world_noise_acceptance, 0.0, 1.0)
	var local_acceptance = clampf(accept_p * patch_gate, 0.0, 1.0)
	if host._hash01(key, 9300 + attempt) > local_acceptance:
		return
	if _sub_form_enabled(host) and _overlaps_cell_instance(host, idx, pos, size):
		return
	var variant = host._hash01(key, 300 + attempt)

	host._instance_cell_indices.append(idx)
	host._instance_cells.append(cell)
	host._instance_positions.append(pos)
	host._instance_rotations.append(_instance_rotation(host, key, attempt))
	host._instance_sizes.append(size)
	host._instance_seeds.append(host._hash01(key, 600 + attempt))
	host._instance_variants.append(variant)
	host._instance_forms.append(host.pack_form(int(form.x), int(form.y)))
	host._instance_scores.append(world_noise * 0.66 + cell_suitability * 0.27 + host._hash01(key, 7600 + attempt) * 0.07)



static func _form_knobs(host) -> Dictionary:

	var cfg = _profile(host)
	return {
		"sub_form_enabled": _sub_form_enabled(host),
		"crown_diameter_hex": float(cfg.get("crown_diameter_hex")),
		"cluster_density_threshold": float(cfg.get("cluster_density_threshold")),
		"grove_density_threshold": float(cfg.get("grove_density_threshold")),
		"grove_crown_min": int(cfg.get("grove_crown_min")),
		"grove_crown_max": int(cfg.get("grove_crown_max")),
		"edge_single_bias": float(cfg.get("edge_single_bias")),
		"element_count_min": int(cfg.get("element_count_min")),
		"element_count_max": int(cfg.get("element_count_max")),
		"impostor_quad_half": host.IMPOSTOR_QUAD_HALF,
	}



static func _sub_form_enabled(host) -> bool:

	var value = _profile(host).get("sub_form_enabled")
	return value != null and bool(value)


# Instances of one cell are appended consecutively; canopy patches of the same
# cell must not pile on each other (SAME_SOURCE: world_ext_detail.cpp).

static func _overlaps_cell_instance(host, idx: int, pos: Vector2, size: float) -> bool:

	var radius = size * host.IMPOSTOR_QUAD_HALF * host.SUB_FORM_PATCH_RADIUS
	var j = host._instance_cell_indices.size() - 1
	while j >= 0 and host._instance_cell_indices[j] == idx:
		var other = host._instance_sizes[j] * host.IMPOSTOR_QUAD_HALF * host.SUB_FORM_PATCH_RADIUS
		var limit = (radius + other) * host.SUB_FORM_OVERLAP
		if pos.distance_squared_to(host._instance_positions[j]) < limit * limit:
			return true
		j -= 1
	return false


# Returns (sub_form, count, size). Canopy profiles pick single / cluster /
# grove from local density and patch edge, and size the instance so each
# crown keeps crown_diameter_hex; other profiles draw element_count elements
# at their authored size. SAME_SOURCE: world_ext_detail.cpp candidate_form.

static func _candidate_form(host, key: int, attempt: int, world_noise: float, cell_suitability: float,
		size_density: float) -> Vector3:

	var cfg = _profile(host)
	var size_hash = host._hash01(key, 400 + attempt)
	var count_hash = host._hash01(key, 8100 + attempt)
	if _sub_form_enabled(host):
		var density = clampf(sqrt(clampf(world_noise, 0.0, 1.0)) * 0.6
			+ minf(cell_suitability, 1.0) * 0.4, 0.0, 1.0)
		var single_p = float(cfg.edge_single_bias) * (1.0 - smoothstep(0.15, 0.55, world_noise))
		var edge_roll = host._hash01(key, 8200 + attempt)
		var sub_form = host.SUB_FORM_SINGLE
		var count = 1
		if density >= float(cfg.grove_density_threshold) and edge_roll >= single_p:
			sub_form = host.SUB_FORM_GROVE
			var t = (density - float(cfg.grove_density_threshold)) \
				/ maxf(1.0 - float(cfg.grove_density_threshold), 0.001)
			var lo = mini(int(cfg.grove_crown_min), int(cfg.grove_crown_max))
			var hi = maxi(int(cfg.grove_crown_min), int(cfg.grove_crown_max))
			count = int(round(lerpf(float(lo), float(hi), clampf(t * 0.8 + count_hash * 0.35, 0.0, 1.0))))
			count = clampi(count, 5, host.FORM_COUNT_MAX)
		elif density >= float(cfg.cluster_density_threshold) and edge_roll >= single_p:
			sub_form = host.SUB_FORM_CLUSTER
			count = 2 + int(floor(count_hash * 2.999))
		var crown_world = float(cfg.crown_diameter_hex) * host._hex_size
		var size = crown_world / (2.0 * host.IMPOSTOR_QUAD_HALF * host.crown_local_radius(count))
		size *= lerpf(0.88, 1.12, size_hash) * lerpf(0.92, 1.06, size_density)
		size *= _quality_size_scale(host)
		return Vector3(float(sub_form), float(count), size)
	var min_size: float = minf(cfg.min_size_factor, cfg.max_size_factor)
	var max_size: float = maxf(cfg.min_size_factor, cfg.max_size_factor)
	var size = host._hex_size * lerpf(min_size, max_size, size_hash)
	size *= lerpf(0.85, 1.12, size_density)
	size *= _quality_size_scale(host)
	var lo_n = clampi(mini(int(cfg.element_count_min), int(cfg.element_count_max)), 1, host.FORM_COUNT_MAX)
	var hi_n = clampi(maxi(int(cfg.element_count_min), int(cfg.element_count_max)), 1, host.FORM_COUNT_MAX)
	var n = lo_n + int(floor(count_hash * float(hi_n - lo_n + 1) * 0.9999))
	return Vector3(float(host.SUB_FORM_SINGLE), float(n), size)



static func _overlaps_known_settlement(host, pos: Vector2, candidate_size: float) -> bool:

	if host._map == null or host._settlement_core_buckets.is_empty():
		return false
	var destination = HexUtils.world_to_wrapped_cell(host._map, pos, host._hex_size)
	if destination == null:
		return false
	if _cell_overlaps_settlement(host, destination, pos, candidate_size):
		return true
	for neighbour in host._map.get_neighbors(destination):
		if _cell_overlaps_settlement(host, neighbour, pos, candidate_size):
			return true
	return false



static func _cell_overlaps_settlement(host, cell, pos: Vector2, candidate_size: float) -> bool:

	if cell == null:
		return false
	var idx = _cell_index(host, cell, -1)
	if idx < 0 or idx >= host._settlement_core_buckets.size():
		return false
	var bucket = mini(15, int(host._settlement_core_buckets[idx]))
	if bucket <= 0:
		return false
	var canonical_center = HexUtils.cube_to_world(
		int(cell.q), int(cell.r), host._hex_size)
	var period = HexUtils.wrap_period_x(int(host._map.width), host._hex_size)
	var display_center = HexUtils.nearest_display_world(
		canonical_center, pos.x, period)
	var radius = _settlement_core_radius(host, bucket) \
		+ maxf(0.0, candidate_size) * host.SETTLEMENT_DETAIL_FOOTPRINT_RADIUS
	return pos.distance_squared_to(display_center) < radius * radius



static func _settlement_core_radius(host, bucket: int) -> float:

	var density = clampf(float(bucket) / 15.0, 0.0, 1.0)
	var spread = lerpf(
		host.SETTLEMENT_BUILDING_SPREAD_MIN,
		host.SETTLEMENT_BUILDING_SPREAD_MAX,
		density)
	var building_scale = lerpf(
		host.SETTLEMENT_BUILDING_SCALE_MIN,
		host.SETTLEMENT_BUILDING_SCALE_MAX,
		density)
	return (host.SETTLEMENT_OUTER_RING_FACTOR * spread
		+ host.SETTLEMENT_ART_HALF_WIDTH * building_scale
			* host.SETTLEMENT_BUILDING_VISUAL_SCALE) * host._hex_size



static func _apply_instance_cap(host) -> void:

	var cap = _instance_cap(host)
	if cap <= 0:
		host.clear()
		return
	var n = host._instance_cell_indices.size()
	if n <= cap:
		return
	var order: Array[int] = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		return host._instance_scores[a] > host._instance_scores[b]
	)
	var keep_lookup = {}
	for i in range(cap):
		keep_lookup[order[i]] = true
	var next_cell_indices = PackedInt32Array()
	var next_positions = PackedVector2Array()
	var next_rotations = PackedFloat32Array()
	var next_sizes = PackedFloat32Array()
	var next_seeds = PackedFloat32Array()
	var next_variants = PackedFloat32Array()
	var next_forms = PackedFloat32Array()
	var next_scores = PackedFloat32Array()
	var next_cells: Array = []
	for i in range(n):
		if not keep_lookup.has(i):
			continue
		next_cell_indices.append(host._instance_cell_indices[i])
		next_positions.append(host._instance_positions[i])
		next_rotations.append(host._instance_rotations[i])
		next_sizes.append(host._instance_sizes[i])
		next_seeds.append(host._instance_seeds[i])
		next_variants.append(host._instance_variants[i])
		next_forms.append(host._instance_forms[i])
		next_scores.append(host._instance_scores[i])
		next_cells.append(host._instance_cells[i])
	host._instance_cell_indices = next_cell_indices
	host._instance_positions = next_positions
	host._instance_rotations = next_rotations
	host._instance_sizes = next_sizes
	host._instance_seeds = next_seeds
	host._instance_variants = next_variants
	host._instance_forms = next_forms
	host._instance_scores = next_scores
	host._instance_cells = next_cells



static func _candidate_position(host, center: Vector2, key: int, attempt: int) -> Vector2:

	var cfg = _profile(host)
	# R2 low-discrepancy sequence: successive attempts cover the hex disc evenly.
	var angle: float = fposmod(host._hash01(key, 101) + float(attempt) * 0.7548776662, 1.0) * TAU
	var radius: float = sqrt(fposmod(host._hash01(key, 200) + float(attempt) * 0.5698402910, 1.0)) \
		* host._hex_size * _effective_spawn_radius_factor(host)
	var jitter: Vector2 = Vector2(cos(angle), sin(angle)) * radius
	var base_pos: Vector2 = center + jitter
	var warp: Vector2 = Vector2(
		host.Diagnostics._value_noise2(host, base_pos.x * 0.033, base_pos.y * 0.033, 911) - 0.5,
		host.Diagnostics._value_noise2(host, base_pos.x * 0.033, base_pos.y * 0.033, 977) - 0.5
	) * (host._hex_size * cfg.world_noise_warp_strength)
	return base_pos + warp



static func _world_noise_suitability(host, world_pos: Vector2) -> float:

	var cfg = _profile(host)
	var p = world_pos / maxf(host._hex_size, 1.0)
	var warp = Vector2(
		host.Diagnostics._value_noise2(host, p.x * cfg.patch_frequency * 0.55, p.y * cfg.patch_frequency * 0.55, 313) - 0.5,
		host.Diagnostics._value_noise2(host, p.x * cfg.patch_frequency * 0.55, p.y * cfg.patch_frequency * 0.55, 719) - 0.5
	) * 7.0
	var coarse = host.Diagnostics._value_noise2(host, (p.x + warp.x) * cfg.patch_frequency, (p.y + warp.y) * cfg.patch_frequency, 17)
	var mid = host.Diagnostics._value_noise2(host, p.x * cfg.patch_frequency * 3.1 + 19.0, p.y * cfg.patch_frequency * 3.1 - 11.0, 41)
	var fine = host.Diagnostics._value_noise2(host, p.x * cfg.patch_frequency * 8.5 - 37.0, p.y * cfg.patch_frequency * 8.5 + 23.0, 83)
	var patch = smoothstep(cfg.patch_cutoff, 1.0, coarse)
	patch = pow(patch, cfg.patch_contrast)
	patch *= lerpf(1.0, lerpf(0.55, 1.35, mid), cfg.world_noise_mid_mix)
	patch *= lerpf(1.0, lerpf(0.82, 1.18, fine), cfg.world_noise_fine_mix)
	return clampf(patch, 0.0, 1.0)



static func _world_micro_gap(host, world_pos: Vector2, key: int, attempt: int) -> float:

	var p = world_pos / maxf(host._hex_size, 1.0)
	var continuous = host.Diagnostics._value_noise2(host, p.x * 0.82 + 23.0, p.y * 0.82 - 17.0, 131)
	var dither = host._hash01(key, 9900 + attempt * 19)
	return clampf(continuous * 0.72 + dither * 0.28, 0.0, 1.0)



static func _instance_transform(host, i: int) -> Transform2D:

	var rot = host._instance_rotations[i]
	var size = host._instance_sizes[i]
	var x_axis = Vector2(cos(rot), sin(rot)) * size
	var y_axis = Vector2(-sin(rot), cos(rot)) * size
	return Transform2D(x_axis, y_axis, host._instance_positions[i])



static func _instance_rotation(host, key: int, attempt: int) -> float:

	var full = host._hash01(key, 500 + attempt) * TAU
	match _rotation_mode(host):
		host.ROT_UPRIGHT:
			return 0.0
		host.ROT_UPRIGHT_JITTER:
			return (host._hash01(key, 501 + attempt) * 2.0 - 1.0) * deg_to_rad(_upright_jitter_degrees(host))
	var strength = _random_rotation_strength(host)
	if strength >= 0.999:
		return full
	return (host._hash01(key, 501 + attempt) * 2.0 - 1.0) * PI * strength



static func _cached_detail_mesh(host) -> ArrayMesh:

	if host._mesh_cache.has("quad"):
		return host._mesh_cache["quad"]
	var mesh = _build_shrub_mesh(host)
	host._mesh_cache["quad"] = mesh
	return mesh


# Every form samples bitmap sprites within one quad (vegetation_forms.gdshaderinc).
# Its half extent keeps the old mesh footprint so instance size, settlement
# avoidance and wrap margins keep their meaning.

static func _build_shrub_mesh(host) -> ArrayMesh:

	var h = host.IMPOSTOR_QUAD_HALF
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([
		Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh




static func _sample_cell_state(host, idx: int, cell = null) -> Dictionary:
	return CellAppearance._sample_cell_state(host, idx, cell)


static func _base_color_for_state(host, state: Dictionary, variant: float) -> Color:
	return CellAppearance._base_color_for_state(host, state, variant)


static func _base_color_for_vegetation(host, veg: int) -> Color:
	return CellAppearance._base_color_for_vegetation(host, veg)


static func _tree_base_color_for_vegetation(host, veg: int) -> Color:
	return CellAppearance._tree_base_color_for_vegetation(host, veg)


static func _grass_base_color_for_vegetation(host, veg: int) -> Color:
	return CellAppearance._grass_base_color_for_vegetation(host, veg)


static func _profile_weight_override(host, prop: StringName, key: int, fallback: float) -> float:
	return CellAppearance._profile_weight_override(host, prop, key, fallback)


static func _vegetation_weight(host, veg: int) -> float:
	return CellAppearance._vegetation_weight(host, veg)


static func _tree_vegetation_weight(host, veg: int) -> float:
	return CellAppearance._tree_vegetation_weight(host, veg)


static func _grass_vegetation_weight(host, veg: int) -> float:
	return CellAppearance._grass_vegetation_weight(host, veg)


static func _landform_weight(host, lf: int) -> float:
	return CellAppearance._landform_weight(host, lf)


static func _tree_landform_weight(host, lf: int) -> float:
	return CellAppearance._tree_landform_weight(host, lf)


static func _grass_landform_weight(host, lf: int) -> float:
	return CellAppearance._grass_landform_weight(host, lf)


static func _cover_weight(host, cover: int) -> float:
	return CellAppearance._cover_weight(host, cover)


static func _sample_density_for_size(host, idx: int, cell = null) -> float:
	return CellAppearance._sample_density_for_size(host, idx, cell)


static func _cell_ecology_density_bias(host, state: Dictionary) -> float:
	return CellAppearance._cell_ecology_density_bias(host, state)


static func _climate_presence(host, state: Dictionary) -> float:
	return CellAppearance._climate_presence(host, state)


static func _scatter_presence(host, state: Dictionary) -> float:
	return CellAppearance._scatter_presence(host, state)


static func _vitality_normalized(host, vitality: float) -> float:
	return CellAppearance._vitality_normalized(host, vitality)


static func _vitality_density_factor(host, state: Dictionary) -> float:
	return CellAppearance._vitality_density_factor(host, state)


static func _vitality_size_scale(host, state: Dictionary) -> float:
	return CellAppearance._vitality_size_scale(host, state)


static func _is_water_cell(host, cell, idx: int) -> bool:

	if idx >= 0 and idx < host._map.is_water_arr.size() and host._map.is_water_arr[idx] > 0:
		return true
	var lf = host._u8(host._map.landform_arr, idx, cell.landform if cell != null else LandformType.LF.OCEAN)
	if LandformType.is_water(lf):
		return true
	if cell != null and LandformType.is_water(cell.landform):
		return true
	return false



static func _has_river_cell(host, cell, idx: int) -> bool:

	if idx >= 0 and idx < host._map.has_river_arr.size():
		return host._map.has_river_arr[idx] > 0
	return bool(cell.has_river) if cell != null else false



static func _is_water_position(host, world_pos: Vector2, _fallback_cell, fallback_idx: int) -> bool:

	if host._map == null:
		return false
	var cell = HexUtils.world_to_wrapped_cell(host._map, world_pos, host._hex_size)
	if cell == null:
		return true
	var idx = _cell_index(host, cell, fallback_idx)
	return _is_water_cell(host, cell, idx)



static func _is_river_body_position(host, world_pos: Vector2) -> bool:

	if host._world == null or host._world.flow_buffer.is_empty():
		return false
	return host._world.sample_flow(world_pos) >= _profile(host).river_clear_threshold



static func _cell_center(host, cell, idx: int) -> Vector2:

	if idx >= 0 and idx < host._map.cell_pos_x_arr.size() and idx < host._map.cell_pos_y_arr.size():
		return Vector2(host._map.cell_pos_x_arr[idx], host._map.cell_pos_y_arr[idx]) * host._hex_size
	return HexUtils.cube_to_world(int(cell.q), int(cell.r), host._hex_size)



static func _cell_index(host, cell, fallback: int) -> int:

	var idx = int(cell.index)
	return idx if idx >= 0 else -1



static func _cell_hash_key(host, cell, fallback: int) -> int:

	if cell != null:
		var idx = int(cell.index)
		if idx >= 0:
			return idx
		return int(cell.q) * 4099 + int(cell.r) * 9176 + fallback
	return fallback



static func _base_max_per_cell(host) -> int:

	var cfg = _profile(host)
	if _limited_platform_density_tier(host):
		match _density_tier(host):
			0:
				return maxi(0, cfg.mobile_max_per_cell_quality0)
			1:
				return maxi(0, cfg.mobile_max_per_cell_quality1)
			_:
				return maxi(0, cfg.mobile_max_per_cell_quality2)
	match _density_tier(host):
		0:
			return maxi(0, cfg.desktop_max_per_cell_quality0)
		1:
			return maxi(0, cfg.desktop_max_per_cell_quality1)
		_:
			return maxi(0, cfg.desktop_max_per_cell_quality2)



static func _max_per_cell(host) -> int:

	var baseline = _base_max_per_cell(host)
	return maxi(baseline, int(ceil(float(baseline) * host._resolved_lod_near_density_multiplier())))



static func _base_instance_cap(host) -> int:

	var cfg = _profile(host)
	if _limited_platform_density_tier(host):
		match _density_tier(host):
			0:
				return maxi(0, cfg.mobile_max_instances_quality0)
			1:
				return maxi(0, cfg.mobile_max_instances_quality1)
			_:
				return maxi(0, cfg.mobile_max_instances_quality2)
	match _density_tier(host):
		0:
			return maxi(0, cfg.desktop_max_instances_quality0)
		1:
			return maxi(0, cfg.desktop_max_instances_quality1)
		_:
			return maxi(0, cfg.desktop_max_instances_quality2)



static func _instance_cap(host) -> int:

	var baseline = _base_instance_cap(host)
	return maxi(baseline, int(ceil(float(baseline) * host._resolved_lod_near_density_multiplier())))



static func _quality_lobe_count(host) -> int:

	var cfg = _profile(host)
	if OS.has_feature("mobile"):
		match _density_tier(host):
			0:
				return clampi(cfg.mobile_lobes_quality0, 2, 8)
			1:
				return clampi(cfg.mobile_lobes_quality1, 2, 8)
			_:
				return clampi(cfg.mobile_lobes_quality2, 2, 8)
	match _density_tier(host):
		0:
			return clampi(cfg.desktop_lobes_quality0, 2, 8)
		1:
			return clampi(cfg.desktop_lobes_quality1, 2, 8)
		_:
			return clampi(cfg.desktop_lobes_quality2, 2, 8)



static func _quality_density_scale(host) -> float:

	var cfg = _profile(host)
	if _limited_platform_density_tier(host):
		match _density_tier(host):
			0:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality0)
			1:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality1)
			_:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality2)
	match _density_tier(host):
		0:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality0)
		1:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality1)
		_:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality2)



static func _quality_size_scale(host) -> float:

	var cfg = _profile(host)
	if OS.has_feature("mobile"):
		match _active_quality_tier(host):
			0:
				return maxf(0.0, cfg.mobile_size_scale_quality0)
			1:
				return maxf(0.0, cfg.mobile_size_scale_quality1)
			_:
				return maxf(0.0, cfg.mobile_size_scale_quality2)
	match _active_quality_tier(host):
		0:
			return maxf(0.0, cfg.desktop_size_scale_quality0)
		1:
			return maxf(0.0, cfg.desktop_size_scale_quality1)
		_:
			return maxf(0.0, cfg.desktop_size_scale_quality2)



static func _active_quality_tier(host) -> int:

	# [android-runtime-quality 2026-11-17] 受限平台（web / mobile）的编译期档都保持
	# LOW：web 为了预热缓存命中，mobile 为了每像素分支成本（见
	# player_game._shader_quality_define_from_setting 的实测注释）。**实例预算、LOD
	# 密度与 form/着色档必须跟随玩家的运行期画质**，否则设置里的"最高画质"在植被/
	# 点缀上是空操作：所有层按 quality0 的每格上限散布，道具全走 !detailed 的简化
	# 形体，远看就是一块块纯色方块。
	#
	# 注意二分手段：要量"运行期档"的代价用 pk_debug.cfg 的 `[render] visual_quality`，
	# 要量"编译期分支"的代价用 `tier_override` —— 后者不再影响本函数。
	return clampi(host._visual_quality, 0, 2)


## 密度档：移动端整体降一档，着色档不变。
##
## [mobile-density-trim 2026-11-17] 作者定夺：点缀/植被数量可以少一半，但 HIGH 的
## 着色与光照要保留。所以只有"每格上限 / 实例上限 / 密度倍率 / 叶瓣数"读这个函数，
## `veg_shade_quality` 仍然读 `_active_quality_tier()`。
static func _density_tier(host) -> int:
	if host._density_detail >= 0:
		return host._density_detail
	var tier := _active_quality_tier(host)
	return mini(tier, 1) if DCFeatureFlags.density_trim_enabled() else tier


# [web-mobile-density-halving 2026-10-30] 受限平台（浏览器 WebGL2 / 移动 GPU）共用
# 同一套"性能换密度"档。web 之前走的是桌面档（density 1.0–1.35、每层上限
# 14000–24000 实例），浏览器里根本跑不动；现在 web 自动拿到 Profile 上已有的
# mobile_* 档（density 0.46–0.70、每层上限 1800–2600，约为桌面的 45%），
# 移动端行为不变，桌面端仍然走 desktop_* 档、完全不受影响。
# 只切"密度 / 每格上限 / 每层上限"这三项；尺寸档与 lobe 档仍按移动端原判定，
# 避免在 web 上额外改变植株大小（那属于另一条视觉口径）。

static func _limited_platform_density_tier(_host) -> bool:
	return DCFeatureFlags.is_limited_render_platform()



static func _detail_kind(host) -> int:

	var cfg = _profile(host)
	return clampi(int(cfg.detail_kind), host.DETAIL_SHRUB, host.DETAIL_DEAD_SNAG)



static func _profile(host) -> Resource:

	return host.profile if host.profile != null else host.DEFAULT_PROFILE



static func _effective_spawn_radius_factor(host) -> float:

	var cfg = _profile(host)
	var configured_floor = cfg.get("seamless_spawn_radius_floor")
	var overlap_floor = 1.06 if configured_floor == null else float(configured_floor)
	return maxf(float(cfg.spawn_radius_factor), clampf(overlap_floor, 0.85, 1.35))



static func _profile_int(host, prop: StringName, fallback: int) -> int:

	var v = _profile(host).get(prop)
	return fallback if v == null else int(v)



static func _profile_float(host, prop: StringName, fallback: float) -> float:

	var v = _profile(host).get(prop)
	return fallback if v == null else float(v)



static func _spawn_domain(host) -> int:

	return clampi(_profile_int(host, &"spawn_domain", host.SPAWN_LAND), host.SPAWN_LAND, host.SPAWN_ANY)



static func _rotation_mode(host) -> int:

	return clampi(_profile_int(host, &"rotation_mode", host.ROT_RANDOM_FULL), host.ROT_RANDOM_FULL, host.ROT_UPRIGHT_JITTER)



static func _random_rotation_strength(host) -> float:

	return clampf(_profile_float(host, &"random_rotation_strength", 1.0), 0.0, 1.0)



static func _upright_jitter_degrees(host) -> float:

	return clampf(_profile_float(host, &"upright_jitter_degrees", 6.0), 0.0, 35.0)
