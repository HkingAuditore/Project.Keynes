extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IntelCacheScript = preload(
	"res://scripts/rendering/building_visual_intel_cache.gd")
const LayerScript = preload("res://scripts/rendering/building_visual_layer.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var map := _make_map()
	var world := WorldData.new()
	world.world_bounds = Rect2(-80.0, -80.0, 240.0, 240.0)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	var intel: BuildingVisualIntelCache = IntelCacheScript.new()
	intel.configure(map.cell_count())
	var applied := intel.apply_snapshot({
		"cell_indices": PackedInt32Array([0, 1]),
		"country_slots": PackedInt32Array([0, 0]),
		"era_indices": PackedInt32Array([6, 6]),
		"type_offsets": PackedInt32Array([0, 1, 2]),
		"type_indices": PackedInt32Array([0, 0]),
		"counts": PackedInt64Array([32, 32]),
	})
	_expect("fixture intelligence is accepted", bool(applied.get("ok", false)))
	var compiled := EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	var layer: BuildingVisualLayer = LayerScript.new()
	get_root().add_child(layer)
	_expect("layer has no GDScript baker to fall back on",
		bool(layer.diagnostics().get("native_required", false))
		and not ("allow_gdscript_baker_fallback" in layer))
	var setup := layer.configure(map, world, 22.0, compiled, intel)
	_expect("building layer configures all authored types", bool(setup.get("ok", false)))
	layer.set_visual_quality(1)
	layer.set_camera_view(world.world_bounds, Vector2.ZERO, 1.5)
	if not ClassDB.class_exists("NativeBuildingVisualCache"):
		var missing := layer.diagnostics()
		_expect("missing extension disables geometry instead of faking it",
			int(missing.get("body_instances", -1)) == 0
			and int(missing.get("native_failures", 0)) > 0)
		_finish(layer)
		return
	_expect("worker finishes the submitted cells", layer.wait_for_layout(5000))
	var diagnostic := layer.diagnostics()
	var cache: Dictionary = diagnostic.get("cache", {})
	print("building visual cache: worker avg=%.1f us max=%.1f us, submit=%.4f ms, upload frame max=%.4f ms" % [
		float(cache.get("worker_plan_us_avg", -1.0)), float(cache.get("worker_plan_us_max", -1.0)),
		float(diagnostic.get("max_submit_ms", -1.0)), float(diagnostic.get("max_upload_frame_ms", -1.0))])
	_expect("layout is planned per cell on the worker thread",
		bool(cache.get("worker_running", false))
		and int(cache.get("planned_cells", 0)) == 2
		and int(cache.get("cached_cells", 0)) == 2)
	_expect("ready chunk becomes resident without a main-thread bake",
		int(diagnostic.get("resident_chunks", 0)) == 1
		and int(diagnostic.get("body_instances", 0)) > 0
		and int(diagnostic.get("queued_chunks", -1)) == 0
		and int(diagnostic.get("native_failures", 0)) == 0
		and int(diagnostic.get("last_chunk_lot_count", 0)) > 0
		and int(diagnostic.get("last_chunk_decal_count", 0)) > 0)
	var nodes: Dictionary = layer._chunk_nodes.values()[0] if not layer._chunk_nodes.is_empty() else {}
	_expect("q1 chunk uses body, ground decal and shadow batches",
		nodes.has("body") and nodes.has("decal") and nodes.has("shadow")
		and nodes.size() == 3)
	var body = nodes.get("body")
	var shadow = nodes.get("shadow")
	_expect("shadow pass reuses the body instance buffer on its hull fan mesh",
		body is MultiMeshInstance2D and shadow is MultiMeshInstance2D
		and body.multimesh.buffer == shadow.multimesh.buffer
		and shadow.multimesh.mesh == layer._shadow_hull_mesh
		and shadow.multimesh.mesh.surface_get_array_len(0) == 9)
	var first_buffer: PackedFloat32Array = body.multimesh.buffer.duplicate() \
		if body is MultiMeshInstance2D else PackedFloat32Array()

	layer.update_intel(intel, PackedInt32Array([0, 1]))
	layer.wait_for_layout(5000)
	cache = layer.diagnostics().get("cache", {})
	_expect("resubmitting unchanged rows plans nothing",
		int(cache.get("planned_cells", 0)) == 2
		and int(cache.get("unchanged_cells", 0)) == 2)

	layer.set_visual_quality(2)
	layer.wait_for_layout(5000)
	layer.set_visual_quality(1)
	layer.wait_for_layout(5000)
	var rebuilt_nodes: Dictionary = layer._chunk_nodes.get(0, {})
	var rebuilt_body = rebuilt_nodes.get("body")
	var second_buffer: PackedFloat32Array = rebuilt_body.multimesh.buffer \
		if rebuilt_body is MultiMeshInstance2D else PackedFloat32Array()
	_expect("quality round trip replans to an identical buffer in the same node",
		not first_buffer.is_empty() and first_buffer == second_buffer
		and rebuilt_body == body)

	var planned_before := int(layer.diagnostics().get("cache", {}).get("planned_cells", 0))
	var grown := intel.apply_snapshot({
		"cell_indices": PackedInt32Array([0, 1]),
		"country_slots": PackedInt32Array([0, 0]),
		"era_indices": PackedInt32Array([6, 6]),
		"type_offsets": PackedInt32Array([0, 1, 2]),
		"type_indices": PackedInt32Array([0, 0]),
		"counts": PackedInt64Array([400, 32]),
	})
	var changed := PackedInt32Array(grown.get("changed_cells", PackedInt32Array()))
	layer.update_intel(intel, changed)
	layer.wait_for_layout(5000)
	var planned_after := int(layer.diagnostics().get("cache", {}).get("planned_cells", 0))
	_expect("a changed cell replans only itself",
		changed == PackedInt32Array([0]) and planned_after - planned_before == 1)
	var grown_body = layer._chunk_nodes.get(0, {}).get("body")
	_expect("grown settlement re-uploads into the resident chunk",
		grown_body is MultiMeshInstance2D
		and grown_body.multimesh.instance_count > first_buffer.size() / 16)
	var grown_buffer: PackedFloat32Array = grown_body.multimesh.buffer.duplicate() \
		if grown_body is MultiMeshInstance2D else PackedFloat32Array()

	var social_snapshot := {
		"cell_indices": PackedInt32Array([0, 1]),
		"country_slots": PackedInt32Array([0, 0]),
		"era_indices": PackedInt32Array([6, 6]),
		"type_offsets": PackedInt32Array([0, 1, 2]),
		"type_indices": PackedInt32Array([0, 0]),
		"counts": PackedInt64Array([400, 32]),
		"settlement_tiers": PackedByteArray([6, 0]),
		"living_levels": PackedByteArray([5, 255]),
		"rich_buckets": PackedByteArray([3, 255]),
		"poor_buckets": PackedByteArray([3, 255]),
	}
	var planned_social_before := int(layer.diagnostics().get("cache", {}).get("planned_cells", 0))
	var social := intel.apply_snapshot(social_snapshot)
	var social_changed := PackedInt32Array(social.get("changed_cells", PackedInt32Array()))
	layer.update_intel(intel, social_changed)
	layer.wait_for_layout(5000)
	var social_body = layer._chunk_nodes.get(0, {}).get("body")
	_expect("population and inequality bands replan only the changed rows",
		social_changed.has(0)
		and int(layer.diagnostics().get("cache", {}).get("planned_cells", 0))
			- planned_social_before == social_changed.size()
		and social_body is MultiMeshInstance2D
		and social_body.multimesh.buffer != grown_buffer)

	layer.set_camera_view(world.world_bounds, Vector2.ZERO, 0.7)
	_expect("far zoom thins settlements through the shader rank cutoff",
		is_equal_approx(float(layer._body_material.get_shader_parameter("lod_fraction")), 0.28)
		and is_equal_approx(float(layer._shadow_material.get_shader_parameter("lod_fraction")), 0.28))
	layer.set_camera_view(world.world_bounds, Vector2.ZERO, 1.5)
	var ranks_valid := true
	for i in second_buffer.size() / 16:
		var rank := second_buffer[i * 16 + 11]
		if rank <= 0.0 or rank >= 1.0:
			ranks_valid = false
	_expect("every body carries its in-cell rank in color alpha", ranks_valid)
	# custom.b carries cell / (cell_count - 1). Cell 1 is water and must stay
	# empty even though its cached row holds the same 32 buildings.
	var instance_count := second_buffer.size() / 16
	var cell_scale := 1.0 / float(map.cell_count() - 1)
	var only_land := true
	var inside_hex := true
	var center := layer._cell_world_position(0)
	for i in instance_count:
		var base := i * 16
		if absf(second_buffer[base + 14]) > cell_scale * 0.5:
			only_land = false
		# Basis column lengths are the half extents of the footprint; its
		# farthest corner must stay within the hex circumradius.
		var half_l := Vector2(second_buffer[base + 0], second_buffer[base + 4]).length()
		var half_w := Vector2(second_buffer[base + 1], second_buffer[base + 5]).length()
		var origin := Vector2(second_buffer[base + 3], second_buffer[base + 7])
		if origin.distance_to(center) + Vector2(half_l, half_w).length() > layer._hex_size:
			inside_hex = false
	_expect("water cells never create building geometry", only_land)
	_expect("every building footprint stays inside its own hex", inside_hex)
	_expect("main-thread submit and upload costs are recorded",
		float(layer.diagnostics().get("max_submit_ms", -1.0)) >= 0.0
		and float(layer.diagnostics().get("max_upload_frame_ms", -1.0)) >= 0.0)

	layer.set_season_phase(2.25)
	layer.set_day_phase(0.73)
	layer.set_day_night_enabled(true)
	layer.set_tod_debug_sun_position(true, Vector2(0.61, 0.42))
	layer.set_tod_debug_sun_height_scale(0.8)
	layer.set_tod_sun_dir(Vector3(0.2, -0.4, 0.8))
	layer.set_tod(Color.WHITE, Color.WHITE, 0.7, 1.15)
	_expect("body receives shared TOD phase",
		is_equal_approx(float(layer._body_material.get_shader_parameter("day_phase")), 0.73)
		and is_equal_approx(float(layer._body_material.get_shader_parameter("season_phase")), 2.25))
	_expect("ground decal receives shared TOD phase",
		is_equal_approx(float(layer._decal_material.get_shader_parameter("day_phase")), 0.73)
		and is_equal_approx(float(layer._decal_material.get_shader_parameter("season_phase")), 2.25))
	_expect("macro receives shared TOD phase",
		is_equal_approx(float(layer._macro_material.get_shader_parameter("day_phase")), 0.73))
	_expect("cast shadow receives shared astronomical phase",
		is_equal_approx(float(layer._shadow_material.get_shader_parameter("day_phase")), 0.73))
	_expect("body receives TOD debug and exposure state",
		bool(layer._body_material.get_shader_parameter("tod_debug_sun_position_enabled"))
		and Vector2(layer._body_material.get_shader_parameter("tod_debug_sun_uv"))
			.is_equal_approx(Vector2(0.61, 0.42))
		and is_equal_approx(float(layer._body_material.get_shader_parameter("tod_exposure")), 1.15))
	# [building-terrain-light 2026-10-18] 高画质建筑共享地形光照。弱绑定失败不会报错，
	# 只会让 shader 静默退回中性值（屋顶与脚下地形对山体阴影给出不同结论），所以这里
	# 同时锁 uniform 存在性与参数到底有没有落到材质上；这个 fixture 没有地形贴图，
	# bound 必须是 false（中性回退），否则测试就成了假通过。
	var uniform_names := {}
	for entry in layer._body_material.shader.get_shader_uniform_list():
		uniform_names[String(entry.get("name", ""))] = true
	_expect("body shader exposes the terrain horizon inputs",
		uniform_names.has("terrain_horizon_tex_bound")
		and uniform_names.has("terrain_normal_tex_bound")
		and uniform_names.has("gi_horizon_lut")
		and uniform_names.has("gi_bent_strength"))
	var terrain_source := ShaderMaterial.new()
	terrain_source.set_shader_parameter("terrain_horizon_strength", 0.37)
	terrain_source.set_shader_parameter("gi_lut_bound", true)
	layer.set_terrain_lighting(terrain_source)
	_expect("terrain lighting parameters reach the building materials",
		is_equal_approx(float(layer._body_material.get_shader_parameter(
			"terrain_horizon_strength")), 0.37)
		and is_equal_approx(float(layer._decal_material.get_shader_parameter(
			"terrain_horizon_strength")), 0.37)
		and bool(layer._body_material.get_shader_parameter("gi_lut_bound"))
		and bool(layer._decal_material.get_shader_parameter("gi_lut_bound")))
	_expect("a world without terrain textures keeps the passes neutral",
		not bool(layer._body_material.get_shader_parameter("terrain_horizon_tex_bound"))
		and not bool(layer._body_material.get_shader_parameter("terrain_normal_tex_bound"))
		and not layer._shader_tiled)
	var first := PackedInt32Array()
	var counts := PackedInt32Array()
	first.resize(65537)
	counts.resize(65537)
	first.fill(-1)
	first[65536] = 0
	counts[65536] = 1
	var high_bytes: PackedByteArray = layer._encode_macro_index_high_bytes(
		65537, first, counts, PackedInt32Array([0]), 2)
	_expect("macro index preserves the third byte beyond 65535 cells",
		high_bytes == PackedByteArray([1, 255]))
	_finish(layer)


func _finish(layer: Node) -> void:
	layer.free()
	print("building visual layer: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _make_map() -> MapData:
	var map := MapData.new(4, 4)
	for row in 4:
		for col in 4:
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.landform = LandformType.LF.PLAIN
			cell.terrain = TerrainType.TERRAIN.GRASSLAND
			map.set_cell(cell)
	map.rebuild_soa_from_cells()
	map.is_water_arr[1] = 1
	return map


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error(label)
