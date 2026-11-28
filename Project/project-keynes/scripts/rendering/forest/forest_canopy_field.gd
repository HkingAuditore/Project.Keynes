class_name ForestCanopyField
extends RefCounted

## Continuous static forest coverage and species-weight field derived strictly
## from immutable/persisted opening geography (never from daily-mutated
## succession columns), so new games, saves after succession, and legacy loads
## evaluate to identical forest boundaries.

const TerrainType = preload("res://scripts/geography/terrain_type.gd")
const VegetationType = preload("res://scripts/geography/vegetation_type.gd")

const CHUNK_CELLS := 16
const SAMPLES_PER_CELL := 4
const CHUNK_TEXELS := CHUNK_CELLS * SAMPLES_PER_CELL
const HALO_TEXELS := 8
const PAGE_TEXELS := CHUNK_TEXELS + HALO_TEXELS * 2

const SPECIES_BROADLEAF := 0
const SPECIES_CONIFER := 1
const SPECIES_PALM := 2

const RIVER_FLOW_LOW := 0.12
const RIVER_FLOW_HIGH := 0.34
const COVERAGE_EPSILON := 0.02

var _map: MapData = null
var _world: WorldData = null
var _hex_size: float = 32.0
var _wrap_period_x: float = 0.0
var _world_bounds: Rect2 = Rect2()
var _seed: int = 1
var _sea_level: float = 0.50
var _chunk_world_size: float = 512.0

# Static per-cell derived caches (computed once from immutable map columns).
var _cell_forest_potential: PackedFloat32Array = PackedFloat32Array()
var _cell_conifer_weight: PackedFloat32Array = PackedFloat32Array()
var _cell_palm_weight: PackedFloat32Array = PackedFloat32Array()


func configure(map: MapData, world: WorldData, hex_size: float, wrap_period_x: float = 0.0) -> bool:
	_map = map
	_world = world
	_hex_size = maxf(hex_size, 1.0)
	_wrap_period_x = maxf(wrap_period_x, 0.0)
	_chunk_world_size = float(CHUNK_CELLS) * _hex_size * 1.5
	if _map == null:
		return false
	if _world != null and _world.world_bounds.has_area():
		_world_bounds = _world.world_bounds
	else:
		var w := float(maxi(_map.width, 1)) * _hex_size * 1.7320508
		var h := float(maxi(_map.height, 1)) * _hex_size * 1.5
		_world_bounds = Rect2(Vector2.ZERO, Vector2(w, h))
	_seed = _resolve_stable_seed(_map)
	_sea_level = _resolve_sea_level(_world)
	_build_static_cell_tables()
	return true


func chunk_world_size() -> float:
	return _chunk_world_size


func world_bounds() -> Rect2:
	return _world_bounds


func wrap_period_x() -> float:
	return _wrap_period_x


func stable_seed() -> int:
	return _seed


func chunk_rect(chunk_x: int, chunk_y: int) -> Rect2:
	var origin := Vector2(
		_world_bounds.position.x + float(chunk_x) * _chunk_world_size,
		_world_bounds.position.y + float(chunk_y) * _chunk_world_size
	)
	return Rect2(origin, Vector2(_chunk_world_size, _chunk_world_size))


func chunk_grid_dimensions() -> Vector2i:
	var span_x := _wrap_period_x if _wrap_period_x > 0.001 else _world_bounds.size.x
	var cx := maxi(1, int(ceil(span_x / maxf(_chunk_world_size, 1.0))))
	var cy := maxi(1, int(ceil(_world_bounds.size.y / maxf(_chunk_world_size, 1.0))))
	return Vector2i(cx, cy)


func canonicalize_world_pos(pos: Vector2) -> Vector2:
	if _wrap_period_x <= 0.001:
		return pos
	var origin_x := _world_bounds.position.x
	var rel_x := fposmod(pos.x - origin_x, _wrap_period_x)
	return Vector2(origin_x + rel_x, pos.y)


## Sample continuous forest parameters at a world position:
##   x = coverage [0, 1]
##   y = conifer weight [0, 1]
##   z = palm weight [0, 1]   (broadleaf = max(0, 1 - y - z))
##   w = effective canopy height [0, 1]
func sample_at_world(raw_pos: Vector2) -> Vector4:
	if _map == null or _cell_forest_potential.is_empty():
		return Vector4.ZERO
	var pos := canonicalize_world_pos(raw_pos)
	if pos.y < _world_bounds.position.y or pos.y > _world_bounds.end.y:
		return Vector4.ZERO
	if _wrap_period_x <= 0.001 and (pos.x < _world_bounds.position.x or pos.x > _world_bounds.end.x):
		return Vector4.ZERO

	var cell = HexUtils.world_to_wrapped_cell(_map, pos, _hex_size)
	if cell == null:
		return Vector4.ZERO
	var idx := int(cell.index)
	if idx < 0 or idx >= _cell_forest_potential.size():
		return Vector4.ZERO

	# Inverse-distance weighted interpolation across the cell and its 6 neighbours
	# for smooth forest boundaries and species transitions.
	var potential := 0.0
	var conifer_w := 0.0
	var palm_w := 0.0
	var weight_sum := 0.0

	var center := HexUtils.cube_to_world(int(cell.q), int(cell.r), _hex_size)
	if _wrap_period_x > 0.001:
		center = HexUtils.nearest_display_world(center, pos.x, _wrap_period_x)
	var d0 := pos.distance_to(center)
	var w0 := 1.0 / maxf(d0 / _hex_size + 0.35, 0.35)
	w0 *= w0
	potential += _cell_forest_potential[idx] * w0
	conifer_w += _cell_conifer_weight[idx] * w0
	palm_w += _cell_palm_weight[idx] * w0
	weight_sum += w0

	for nb in _map.get_neighbors(cell):
		if nb == null:
			continue
		var nidx := int(nb.index)
		if nidx < 0 or nidx >= _cell_forest_potential.size():
			continue
		var nc := HexUtils.cube_to_world(int(nb.q), int(nb.r), _hex_size)
		if _wrap_period_x > 0.001:
			nc = HexUtils.nearest_display_world(nc, pos.x, _wrap_period_x)
		var dn := pos.distance_to(nc)
		var wn := 1.0 / maxf(dn / _hex_size + 0.35, 0.35)
		wn *= wn
		potential += _cell_forest_potential[nidx] * wn
		conifer_w += _cell_conifer_weight[nidx] * wn
		palm_w += _cell_palm_weight[nidx] * wn
		weight_sum += wn

	if weight_sum <= 0.0001:
		return Vector4.ZERO
	potential /= weight_sum
	conifer_w /= weight_sum
	palm_w /= weight_sum
	if potential <= COVERAGE_EPSILON:
		return Vector4.ZERO

	# Water & river coarse mask (pixel-exact river/coast clip is also enforced in shader).
	var water_mask := 1.0
	if idx < _map.is_water_arr.size() and int(_map.is_water_arr[idx]) != 0:
		return Vector4.ZERO
	if _world != null:
		if not _world.height_buffer.is_empty():
			var h := _world.sample_height(pos)
			if h <= _sea_level + 0.004:
				return Vector4.ZERO
			water_mask *= smoothstep(_sea_level + 0.004, _sea_level + 0.025, h)
		if not _world.flow_buffer.is_empty():
			var flow := _world.sample_flow(pos)
			var river := smoothstep(RIVER_FLOW_LOW, RIVER_FLOW_HIGH, flow)
			water_mask *= (1.0 - river)
	if water_mask <= COVERAGE_EPSILON:
		return Vector4.ZERO

	# Multi-scale low-frequency periodic noise:
	# - extent_n (7.5 hex): organic macro forest boundary with 2-3 hex feathered margin.
	# - clearing_n (4.5 hex): genuine interior clearings & open glades.
	# - clump_n (2.4 hex): grove-scale density variation between sparse and dense stands.
	var extent_n := _periodic_fbm(pos, _hex_size * 7.5, _seed ^ 0x1B873593)
	var clearing_n := _periodic_fbm(pos, _hex_size * 4.5, _seed ^ 0x5BD1E995)
	var clump_n := _periodic_fbm(pos, _hex_size * 2.4, _seed ^ 0x3C6EF372)

	var macro_edge := smoothstep(0.26, 0.68, potential + (extent_n - 0.5) * 0.48)
	# Keep interior density genuinely varied [0.0..1.0] even where potential == 1.0:
	# deep clearings drop below 0.15, sparse groves sit at 0.30-0.60, dense cores reach 0.85-1.0.
	var glade_cut := smoothstep(0.24, 0.74, clearing_n * 0.72 + clump_n * 0.28 + (potential - 0.5) * 0.25)
	var cov := clampf(macro_edge * (0.14 + 0.92 * glade_cut) * water_mask, 0.0, 1.0)
	if cov <= COVERAGE_EPSILON:
		return Vector4.ZERO

	# Normalise species weights so conifer + palm <= 1.0 (broadleaf is remainder).
	var total_cp := conifer_w + palm_w
	if total_cp > 1.0:
		conifer_w /= total_cp
		palm_w /= total_cp

	# Effective canopy height scales with density and species (conifers slightly taller).
	var species_h := 0.82 + 0.18 * conifer_w - 0.08 * palm_w
	var height := clampf(cov * species_h * (0.78 + 0.22 * clump_n), 0.0, 1.0)
	return Vector4(cov, clampf(conifer_w, 0.0, 1.0), clampf(palm_w, 0.0, 1.0), height)


## Bake an 80x80 RGBA8 coverage page AND a matching 80x80 RGBA8 cell_meta page
## (RG = 16-bit cell index for dyn/eco/enum LUT lookups, BA = terrain macro
## slope normal XY encoded in [0, 1]) for a 16x16 chunk.
func bake_chunk_coverage(chunk_x: int, chunk_y: int) -> Dictionary:
	var t0_us := Time.get_ticks_usec()
	var rect := chunk_rect(chunk_x, chunk_y)
	var texel_world := _chunk_world_size / float(CHUNK_TEXELS)
	var bytes := PackedByteArray()
	bytes.resize(PAGE_TEXELS * PAGE_TEXELS * 4)
	var meta_bytes := PackedByteArray()
	meta_bytes.resize(PAGE_TEXELS * PAGE_TEXELS * 4)

	var max_cov := 0.0
	var interior_max_cov := 0.0
	var non_empty_samples := 0
	var has_hm := _world != null and not _world.height_buffer.is_empty()
	var slope_step := _hex_size * 0.35

	for py in range(PAGE_TEXELS):
		var wy := rect.position.y + (float(py - HALO_TEXELS) + 0.5) * texel_world
		var in_y := py >= HALO_TEXELS and py < HALO_TEXELS + CHUNK_TEXELS
		for px in range(PAGE_TEXELS):
			var wx := rect.position.x + (float(px - HALO_TEXELS) + 0.5) * texel_world
			var wpos := Vector2(wx, wy)
			var s := sample_at_world(wpos)
			var off := (py * PAGE_TEXELS + px) * 4
			bytes[off] = clampi(int(round(s.x * 255.0)), 0, 255)
			bytes[off + 1] = clampi(int(round(s.y * 255.0)), 0, 255)
			bytes[off + 2] = clampi(int(round(s.z * 255.0)), 0, 255)
			bytes[off + 3] = clampi(int(round(s.w * 255.0)), 0, 255)

			var cell_idx := 0
			var cpos := canonicalize_world_pos(wpos)
			var cell = HexUtils.world_to_wrapped_cell(_map, cpos, _hex_size)
			if cell != null and int(cell.index) >= 0:
				cell_idx = int(cell.index)
			meta_bytes[off] = cell_idx & 0xFF
			meta_bytes[off + 1] = (cell_idx >> 8) & 0xFF

			var tnx := 0.0
			var tny := 0.0
			if has_hm:
				var hx0 := _world.sample_height(canonicalize_world_pos(wpos - Vector2(slope_step, 0.0)))
				var hx1 := _world.sample_height(canonicalize_world_pos(wpos + Vector2(slope_step, 0.0)))
				var hy0 := _world.sample_height(canonicalize_world_pos(wpos - Vector2(0.0, slope_step)))
				var hy1 := _world.sample_height(canonicalize_world_pos(wpos + Vector2(0.0, slope_step)))
				tnx = clampf((hx0 - hx1) * 5.5, -0.85, 0.85)
				tny = clampf((hy0 - hy1) * 5.5, -0.85, 0.85)
			meta_bytes[off + 2] = clampi(int(round((tnx * 0.5 + 0.5) * 255.0)), 0, 255)
			meta_bytes[off + 3] = clampi(int(round((tny * 0.5 + 0.5) * 255.0)), 0, 255)

			if s.x > max_cov:
				max_cov = s.x
			if in_y and px >= HALO_TEXELS and px < HALO_TEXELS + CHUNK_TEXELS:
				if s.x > interior_max_cov:
					interior_max_cov = s.x
				if s.x > COVERAGE_EPSILON:
					non_empty_samples += 1

	var img := Image.create_from_data(PAGE_TEXELS, PAGE_TEXELS, false, Image.FORMAT_RGBA8, bytes)
	var meta_img := Image.create_from_data(PAGE_TEXELS, PAGE_TEXELS, false, Image.FORMAT_RGBA8, meta_bytes)
	var elapsed_ms := float(Time.get_ticks_usec() - t0_us) / 1000.0
	return {
		"chunk": Vector2i(chunk_x, chunk_y),
		"rect": rect,
		"image": img,
		"meta_image": meta_img,
		"bytes": bytes,
		"meta_bytes": meta_bytes,
		"has_forest": interior_max_cov > COVERAGE_EPSILON,
		"has_halo_forest": max_cov > COVERAGE_EPSILON,
		"max_coverage": interior_max_cov,
		"non_empty_samples": non_empty_samples,
		"bake_ms": elapsed_ms,
	}


func _build_static_cell_tables() -> void:
	var n := _map.cell_count()
	_cell_forest_potential.resize(n)
	_cell_conifer_weight.resize(n)
	_cell_palm_weight.resize(n)
	var has_water := _map.is_water_arr.size() >= n
	var has_elev := _map.elevation_arr.size() >= n
	var has_moist := _map.base_moisture_arr.size() >= n
	var has_temp := _map.temp_baseline_year_arr.size() >= n
	var has_lat := _map.cell_lat_norm_arr.size() >= n
	var has_terrain := _map.base_terrain_arr.size() >= n
	var has_gen_veg := _map.generation_vegetation_arr.size() >= n

	for i in range(n):
		if has_water and int(_map.is_water_arr[i]) != 0:
			_cell_forest_potential[i] = 0.0
			_cell_conifer_weight[i] = 0.0
			_cell_palm_weight[i] = 0.0
			continue

		var elev := float(_map.elevation_arr[i]) if has_elev else 0.58
		var moist := float(_map.base_moisture_arr[i]) if has_moist else 0.55
		var temp := 0.55
		if has_temp:
			temp = float(_map.temp_baseline_year_arr[i])
		elif has_lat:
			var lat := absf(float(_map.cell_lat_norm_arr[i]) * 2.0 - 1.0)
			temp = clampf(1.0 - lat * lat * 0.85, 0.05, 0.95)
		else:
			var c = _map.cell_at(i)
			if c != null:
				var ny := clampf(float(c.r) / float(maxi(_map.height, 1)), 0.0, 1.0)
				var lat2 := absf(ny * 2.0 - 1.0)
				temp = clampf(1.0 - lat2 * lat2 * 0.85, 0.05, 0.95)

		var land_h := clampf((elev - _sea_level) / maxf(1.0 - _sea_level, 0.05), 0.0, 1.0)
		var eff_temp := clampf(temp - land_h * 0.42, 0.0, 1.0)

		var potential := 0.0
		var conifer := 0.0
		var palm := 0.0

		# Prefer immutable generation-time vegetation classification when present;
		# fall back to immutable base_terrain_arr (never daily-mutated vegetation_arr).
		var gv := int(_map.generation_vegetation_arr[i]) if has_gen_veg else -1
		if gv >= 0:
			match gv:
				VegetationType.VEG.TAIGA:
					potential = 0.82
					conifer = 0.95
				VegetationType.VEG.TEMPERATE_CONIFER:
					potential = 0.80
					conifer = 0.82
				VegetationType.VEG.TEMPERATE_DECIDUOUS:
					potential = 0.84
					conifer = 0.10
				VegetationType.VEG.SUBTROPICAL_FOREST:
					potential = 0.86
					palm = 0.18
				VegetationType.VEG.MONSOON_FOREST:
					potential = 0.84
					palm = 0.25
				VegetationType.VEG.CLOUD_FOREST:
					potential = 0.88
					conifer = 0.20
					palm = 0.15
				VegetationType.VEG.TROPICAL_RAINFOREST:
					potential = 0.94
					palm = 0.34
				VegetationType.VEG.TROPICAL_DRY_FOREST:
					potential = 0.58
					palm = 0.28
				VegetationType.VEG.SAVANNA:
					potential = 0.20
					palm = 0.55
				VegetationType.VEG.OASIS_VEG:
					potential = 0.45
					palm = 0.92
				_:
					potential = 0.0
		elif has_terrain:
			var bt := int(_map.base_terrain_arr[i])
			match bt:
				TerrainType.TERRAIN.TAIGA:
					potential = 0.82
					conifer = 0.95
				TerrainType.TERRAIN.FOREST:
					potential = 0.84
					conifer = clampf(smoothstep(0.46, 0.26, eff_temp), 0.0, 0.85)
				TerrainType.TERRAIN.JUNGLE:
					potential = 0.94
					palm = 0.34
				TerrainType.TERRAIN.SAVANNA:
					potential = 0.20
					palm = 0.55
				TerrainType.TERRAIN.OASIS:
					potential = 0.45
					palm = 0.92
				TerrainType.TERRAIN.HILL:
					# Moist forested hills only; dry hills stay open.
					potential = smoothstep(0.54, 0.78, moist) * smoothstep(0.18, 0.36, eff_temp) * 0.65
					conifer = clampf(smoothstep(0.50, 0.28, eff_temp) + 0.30, 0.0, 0.95)
				_:
					potential = 0.0
		else:
			# Fallback for minimal synthetic maps without terrain/vegetation tags.
			var moist_ok := smoothstep(0.42, 0.74, moist)
			var temp_ok := smoothstep(0.12, 0.30, eff_temp)
			var alpine_ok := 1.0 - smoothstep(0.64, 0.86, land_h)
			potential = clampf(moist_ok * temp_ok * alpine_ok, 0.0, 1.0)
			conifer = clampf(smoothstep(0.50, 0.24, eff_temp), 0.0, 1.0)
			palm = clampf(smoothstep(0.68, 0.86, eff_temp) * (1.0 - smoothstep(0.20, 0.45, land_h)), 0.0, 0.85)

		var cp_sum := conifer + palm
		if cp_sum > 1.0:
			conifer /= cp_sum
			palm /= cp_sum

		_cell_forest_potential[i] = clampf(potential, 0.0, 1.0)
		_cell_conifer_weight[i] = conifer
		_cell_palm_weight[i] = palm


func _periodic_fbm(pos: Vector2, wavelength: float, salt: int) -> float:
	var period_x := 0
	var sx := pos.x / maxf(wavelength, 1.0)
	var sy := pos.y / maxf(wavelength, 1.0)
	if _wrap_period_x > 0.001:
		period_x = maxi(2, int(round(_wrap_period_x / maxf(wavelength, 1.0))))
		sx = fposmod(pos.x - _world_bounds.position.x, _wrap_period_x) / _wrap_period_x * float(period_x)
	var n0 := _value_noise(sx, sy, period_x, salt)
	var n1 := _value_noise(sx * 2.0, sy * 2.0, period_x * 2, salt ^ 0x27D4EB2D)
	return clampf(n0 * 0.68 + n1 * 0.32, 0.0, 1.0)


static func _value_noise(x: float, y: float, period_x: int, salt: int) -> float:
	var ix := int(floor(x))
	var iy := int(floor(y))
	var fx := x - float(ix)
	var fy := y - float(iy)
	var ux := fx * fx * (3.0 - 2.0 * fx)
	var uy := fy * fy * (3.0 - 2.0 * fy)

	var ix0 := posmod(ix, period_x) if period_x > 0 else ix
	var ix1 := posmod(ix + 1, period_x) if period_x > 0 else (ix + 1)

	var v00 := _hash01(ix0, iy, salt)
	var v10 := _hash01(ix1, iy, salt)
	var v01 := _hash01(ix0, iy + 1, salt)
	var v11 := _hash01(ix1, iy + 1, salt)
	return lerpf(lerpf(v00, v10, ux), lerpf(v01, v11, ux), uy)


static func _hash01(x: int, y: int, salt: int) -> float:
	var h := (x * 374761393) ^ (y * 668265263) ^ (salt * 1442695041)
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float(h & 0xFFFF) / 65535.0


static func _resolve_stable_seed(map: MapData) -> int:
	if "seed" in map and int(map.get("seed")) != 0:
		return int(map.get("seed"))
	if "world_seed" in map and int(map.get("world_seed")) != 0:
		return int(map.get("world_seed"))
	return (map.width * 73856093) ^ (map.height * 19349663) ^ 0x51F02E57


static func _resolve_sea_level(world: WorldData) -> float:
	if world != null and "sea_level" in world:
		var sl := float(world.get("sea_level"))
		if is_finite(sl) and sl > 0.0 and sl < 1.0:
			return sl
	return 0.50
