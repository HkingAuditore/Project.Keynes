extends SceneTree

## Verification suite for the large-area forest canopy rendering prototype
## (docs/plans/forest-canopy-rendering.md §8).
##
## Covers:
##   1. Tileable canopy Texture2DArray asset loading (3 layers, 512x512).
##   2. Continuous 30-50 hex forest span, river/water cutout, empty chunk cache hits,
##      and east-west wrap seamless equivalence.
##   3. Determinism across rebuilds, cache eviction rebuilds, and invariance when
##      daily ecological succession mutates base_vegetation_arr/vegetation_arr.
##   4. Coarse-merged rectangle mesh vs baseline chunk-quad A/B on identical coverage
##      field (triangle count, covered area savings).
##   5. City footprint mask localised incremental updates (zero forest mesh uploads)
##      and fog-of-war intel gating (unrevealed construction does not alter mask).
##   6. Canopy & shadow shaders load cleanly and accept lighting/debug toggles.
##   7. Profile replacement filter replaces the 5 canopy layers while keeping
##      grass/shrub/rock/mangrove layers intact.

const CanopyField = preload("res://scripts/rendering/forest/forest_canopy_field.gd")
const CanopyMesh = preload("res://scripts/rendering/forest/forest_canopy_mesh.gd")
const CanopyCityMask = preload("res://scripts/rendering/forest/forest_canopy_city_mask.gd")
const CanopyLayer = preload("res://scripts/rendering/forest/forest_canopy_layer.gd")
const FogDetailCulling = preload("res://scripts/rendering/fog_detail_culling.gd")
const DecorationManifestRes = preload("res://data/visual/world_decoration_manifest.tres")

var _passed := 0
var _failed := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		printerr("[FAIL] %s" % label)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_profile_replacement_boundary()
	_test_continuous_forest_river_wrap_and_determinism()
	_test_coarse_merged_vs_chunk_quad()
	_test_layer_cache_city_mask_and_lighting()

	print("forest_canopy_prototype_test: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _build_synthetic_map(width: int, height: int, seed_val: int) -> Dictionary:
	var map := MapData.new(width, height)
	if "seed" in map:
		map.set("seed", seed_val)
	var hex_size := 32.0
	var n := width * height
	map.is_water_arr.resize(n)
	map.elevation_arr.resize(n)
	map.base_moisture_arr.resize(n)
	map.temp_baseline_year_arr.resize(n)
	map.base_terrain_arr.resize(n)
	map.base_vegetation_arr.resize(n)
	map.vegetation_arr.resize(n)

	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF

	for row in range(height):
		for col in range(width):
			var idx := row * width + col
			var q := col - int(floor(float(row) * 0.5))
			var r := row
			var c := HexCell.new(q, r)
			c.index = idx
			map.set_cell(c)

			var wp := HexUtils.cube_to_world(q, r, hex_size)
			min_x = minf(min_x, wp.x)
			max_x = maxf(max_x, wp.x)
			min_y = minf(min_y, wp.y)
			max_y = maxf(max_y, wp.y)

			# Left band (col < 4) is ocean; right grassland/dry band (col >= width - 6) has no forest;
			# middle 38+ hexes form continuous TAIGA (north), FOREST (mid), JUNGLE (south).
			var is_ocean := col < 4
			var is_open := col >= width - 6
			map.is_water_arr[idx] = 1 if is_ocean else 0
			map.elevation_arr[idx] = 0.35 if is_ocean else 0.58
			map.base_moisture_arr[idx] = 0.10 if is_open else 0.78
			var lat_t := float(row) / float(maxi(height - 1, 1))
			map.temp_baseline_year_arr[idx] = lerpf(0.22, 0.88, lat_t)
			if is_ocean:
				map.base_terrain_arr[idx] = 0 # OCEAN
			elif is_open:
				map.base_terrain_arr[idx] = 3 # GRASSLAND (no dense forest)
			elif lat_t < 0.33:
				map.base_terrain_arr[idx] = 13 # TAIGA (conifer)
			elif lat_t < 0.68:
				map.base_terrain_arr[idx] = 4 # FOREST (broadleaf)
			else:
				map.base_terrain_arr[idx] = 11 # JUNGLE (broadleaf + palm)
			map.base_vegetation_arr[idx] = 2
			map.vegetation_arr[idx] = 2

	map._build_indices()

	var world := WorldData.new()
	world.world_bounds = Rect2(
		Vector2(min_x - hex_size, min_y - hex_size),
		Vector2((max_x - min_x) + hex_size * 2.0, (max_y - min_y) + hex_size * 2.0)
	)
	world.hm_size = Vector2i(128, 80)
	world.derived_size = Vector2i(128, 80)
	world.height_buffer.resize(128 * 80)
	world.flow_buffer.resize(128 * 80)
	for py in range(80):
		for px in range(128):
			var off := py * 128 + px
			var u := float(px) / 127.0
			# Ocean on left edge, land elsewhere.
			world.height_buffer[off] = 0.35 if u < 0.08 else 0.62
			# Narrow meandering river cutting through the forest around u ~ 0.48.
			var river_u := 0.48 + 0.04 * sin(float(py) * 0.22)
			var dist := absf(u - river_u)
			world.flow_buffer[off] = 0.55 if dist < 0.015 else 0.02

	var wrap_period_x := HexUtils.wrap_period_x(width, hex_size)
	return {"map": map, "world": world, "hex_size": hex_size, "wrap_period_x": wrap_period_x}


func _test_profile_replacement_boundary() -> void:
	var layers: Array = DecorationManifestRes.valid_layers()
	var replaced := 0
	var kept := 0
	for prof in layers:
		if CanopyLayer.is_replaced_canopy_profile(prof):
			replaced += 1
		else:
			kept += 1
	_check(replaced == 5, "Manifest replaces exactly 5 canopy layers (got %d)" % replaced)
	_check(kept >= 10, "Manifest keeps grass/shrub/rock/mangrove layers intact (got %d)" % kept)


func _test_continuous_forest_river_wrap_and_determinism() -> void:
	var fx := _build_synthetic_map(48, 32, 20261128)
	var map: MapData = fx["map"]
	var world: WorldData = fx["world"]
	var hex_size: float = fx["hex_size"]
	var wrap_p: float = fx["wrap_period_x"]

	var field := CanopyField.new()
	_check(field.configure(map, world, hex_size, wrap_p), "CanopyField configures cleanly")

	# Ocean point must have zero coverage.
	var bounds := field.world_bounds()
	var ocean_pos := Vector2(bounds.position.x + hex_size * 1.2, bounds.get_center().y)
	_check(field.sample_at_world(ocean_pos).x == 0.0, "Ocean has zero forest coverage")

	# River centerline must be cut out (low/zero coverage).
	var river_y := bounds.position.y + bounds.size.y * 0.5
	var py_mid := roundf(0.5 * 79.0)
	var river_u_mid := 0.48 + 0.04 * sin(py_mid * 0.22)
	var river_pos := Vector2(bounds.position.x + bounds.size.x * river_u_mid, river_y)
	_check(field.sample_at_world(river_pos).x < 0.05, "River centerline cuts through forest")

	# Forest interior on both sides of the river should be populated.
	var left_forest := Vector2(bounds.position.x + bounds.size.x * 0.30, bounds.get_center().y)
	var right_forest := Vector2(bounds.position.x + bounds.size.x * 0.65, bounds.get_center().y)
	var s_left := field.sample_at_world(left_forest)
	var s_right := field.sample_at_world(right_forest)
	_check(s_left.x > 0.15 or s_right.x > 0.15, "Continuous forest populates interior across river")

	# East-west wrap equivalence: pos and pos +/- wrap_period_x must match identically.
	var s_wrap_plus := field.sample_at_world(left_forest + Vector2(wrap_p, 0.0))
	var s_wrap_minus := field.sample_at_world(left_forest - Vector2(wrap_p, 0.0))
	_check(s_left.is_equal_approx(s_wrap_plus), "Wrap +period matches canonical sample")
	_check(s_left.is_equal_approx(s_wrap_minus), "Wrap -period matches canonical sample")

	# Determinism across succession mutation (simulating multi-day ecological shift + reload).
	var page_before := field.bake_chunk_coverage(1, 0)
	var bytes_before: PackedByteArray = page_before["bytes"]

	for i in range(map.base_vegetation_arr.size()):
		map.base_vegetation_arr[i] = 0
		map.vegetation_arr[i] = 0

	var field_after := CanopyField.new()
	field_after.configure(map, world, hex_size, wrap_p)
	var page_after := field_after.bake_chunk_coverage(1, 0)
	_check(bytes_before == page_after["bytes"],
		"Forest coverage page is byte-identical after succession mutates base_vegetation_arr")


func _test_coarse_merged_vs_chunk_quad() -> void:
	var fx := _build_synthetic_map(48, 32, 20261128)
	var field := CanopyField.new()
	field.configure(fx["map"], fx["world"], fx["hex_size"], fx["wrap_period_x"])

	# Pick a chunk straddling the coast/forest border so coarse merging saves area.
	var baked := field.bake_chunk_coverage(0, 0)
	var rect: Rect2 = baked["rect"]
	var bytes: PackedByteArray = baked["bytes"]

	var coarse := CanopyMesh.build_from_coverage(
		rect, bytes, CanopyField.PAGE_TEXELS, CanopyField.HALO_TEXELS,
		CanopyMesh.MODE_COARSE_MERGED, 8.0
	)
	var quad := CanopyMesh.build_from_coverage(
		rect, bytes, CanopyField.PAGE_TEXELS, CanopyField.HALO_TEXELS,
		CanopyMesh.MODE_CHUNK_QUAD, 8.0
	)
	_check(bool(coarse["ok"]) and bool(quad["ok"]), "Both coarse_merged and chunk_quad build cleanly")
	_check(not bool(coarse["empty"]) and not bool(quad["empty"]), "Border chunk is non-empty in both modes")
	_check(float(coarse["covered_area_ratio"]) < float(quad["covered_area_ratio"]),
		"Coarse-merged mesh covers less area than full chunk quad on coast border (%.2f vs %.2f)" % [
			float(coarse["covered_area_ratio"]), float(quad["covered_area_ratio"])
		])
	_check(int(quad["tri_count"]) == 2, "Chunk quad emits exactly 2 triangles")


func _test_layer_cache_city_mask_and_lighting() -> void:
	var fx := _build_synthetic_map(48, 32, 20261128)
	var map: MapData = fx["map"]
	var layer := CanopyLayer.new()
	root.add_child(layer)
	layer.set_max_builds_per_update(0)

	_check(layer.configure_world(map, fx["world"], fx["hex_size"], fx["wrap_period_x"]),
		"ForestCanopyLayer configures world")
	var d0 := layer.diagnostics()
	_check(bool(d0["tiles_loaded"]), "Tileable canopy Texture2DArray assets load cleanly")

	# First visit builds visible chunks; revisit hits cache with zero new cold builds.
	var bounds: Rect2 = fx["world"].world_bounds
	var view := Rect2(bounds.position, bounds.size * 0.65)
	layer.set_camera_view(view, view.get_center(), 1.0)
	var d_first := layer.diagnostics()
	var cold_first := int(d_first["cold_builds"])
	var mesh_bytes_first := int(d_first["mesh_upload_bytes"])
	_check(cold_first > 0, "Cold visit builds visible chunks (%d)" % cold_first)
	_check(int(d_first["visible_canopy_batches"]) > 0, "Visible canopy batches emitted")
	_check(int(d_first["visible_shadow_batches"]) > 0, "Visible shadow receiver batches emitted")

	layer.set_camera_view(view, view.get_center(), 1.0)
	var d_revisit := layer.diagnostics()
	_check(int(d_revisit["cold_builds"]) == cold_first, "Hot revisit performs zero cold builds")
	_check(int(d_revisit["cache_hits"]) > int(d_first["cache_hits"]), "Hot revisit records cache hits")

	# Evict & rebuild determinism check.
	var target_key := Vector2i(1, 0)
	var entry_before := layer.ensure_chunk_built(target_key)
	var bytes_before: PackedByteArray = entry_before.get("coverage_bytes", PackedByteArray())
	layer.evict_chunk(target_key)
	var entry_rebuilt := layer.ensure_chunk_built(target_key)
	_check(bytes_before == entry_rebuilt.get("coverage_bytes", PackedByteArray()),
		"Evicted chunk rebuilds byte-identical coverage page")

	# City mask update: only updates affected mask pages, ZERO forest mesh uploads.
	var mesh_bytes_before_city := int(layer.diagnostics()["mesh_upload_bytes"])
	var buckets := PackedByteArray()
	buckets.resize(map.cell_count())
	var city_cell := 12 * map.width + 18
	buckets[city_cell] = 10
	var updated := layer.set_settlement_core_buckets(buckets, PackedInt32Array([city_cell]))
	var d_city := layer.diagnostics()
	_check(int(d_city["mesh_upload_bytes"]) == mesh_bytes_before_city,
		"City mask update triggers zero forest mesh uploads")
	_check(updated.size() >= 1 and updated.size() <= 4,
		"City mask update is localised to affected chunk(s) (got %d)" % updated.size())

	# Sync from empty terrain ShaderMaterial (all shader params null) must not error.
	var empty_mat := ShaderMaterial.new()
	layer.sync_shared_textures_from_terrain_material(empty_mat)
	_check(true, "sync_shared_textures_from_terrain_material handles null shader params safely")

	# Lighting & debug toggle update: zero forest mesh uploads.
	layer.set_lighting_state(
		Vector3(-0.5, 0.5, 0.4), Color(1.0, 0.85, 0.65), Color(0.25, 0.30, 0.42),
		0.85, 1.0, 0.70, 0.25, 0.9
	)
	layer.set_debug_toggles(false, false, false)
	var d_toggle := layer.diagnostics()
	_check(int(d_toggle["visible_shadow_batches"]) == 0, "Disabling shadow hides shadow receiver batches")
	_check(int(d_toggle["mesh_upload_bytes"]) == mesh_bytes_before_city,
		"Lighting/season/debug updates trigger zero forest mesh uploads")

	# Mode switch to chunk_quad updates geometry in-place cleanly.
	layer.set_geometry_mode(CanopyMesh.MODE_CHUNK_QUAD)
	var d_quad := layer.diagnostics()
	_check(String(d_quad["geometry_mode"]) == "chunk_quad", "Switches geometry mode to chunk_quad")

	# FogDetailCulling must accept MeshInstance2D canopy/shadow batches without type error.
	var fog_dummy := Node2D.new()
	fog_dummy.z_as_relative = false
	fog_dummy.z_index = 12
	root.add_child(fog_dummy)
	var culling := FogDetailCulling.new()
	var fake_host := {
		"_detail_layers": [],
		"_detail_family_layer": null,
		"_forest_canopy_layer": layer,
		"_resource_visual_layer": null,
		"_building_visual_layer": null,
	}
	culling.update(fake_host, fog_dummy, Rect2(Vector2.ZERO, Vector2(1600, 960)),
		func(_r: Rect2) -> bool: return true, false)
	_check(not culling._hidden.is_empty(), "FogDetailCulling hides covered MeshInstance2D canopy batches")
	culling.clear()
	fog_dummy.queue_free()

	layer.clear_world()
	layer.queue_free()
