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
	var policy_probe: BuildingVisualLayer = LayerScript.new()
	_expect("native C++ baker is the production default",
		not policy_probe.allow_gdscript_baker_fallback)
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
	var native_ext: Object = ClassDB.instantiate("DCWorldExt") \
		if ClassDB.class_exists("DCWorldExt") else null
	if native_ext != null:
		layer.set_world_ext(native_ext)
	else:
		# The production default is native-only. Explicitly opt into the legacy
		# baker here so the script smoke test remains useful with an old/missing DLL.
		layer.allow_gdscript_baker_fallback = true
	var setup := layer.configure(map, world, 22.0, compiled, intel)
	_expect("building layer configures all authored types", bool(setup.get("ok", false)))
	layer.set_visual_quality(1)
	layer.set_camera_view(world.world_bounds, Vector2.ZERO, 1.5)
	await process_frame
	await process_frame
	var diagnostic := layer.diagnostics()
	print("building visual native timing: last=%.4f ms max=%.4f ms" % [
		float(diagnostic.get("last_native_bake_ms", -1.0)),
		float(diagnostic.get("max_native_bake_ms", -1.0))])
	_expect("resident geometry builds through one-chunk-per-frame queue",
		int(diagnostic.get("resident_chunks", 0)) == 1
		and int(diagnostic.get("body_instances", 0)) > 0
		and int(diagnostic.get("queued_chunks", -1)) == 0)
	if native_ext != null:
		_expect("resident chunk uses the C++ numeric baker by default",
			int(diagnostic.get("native_bake_calls", 0)) > 0
			and int(diagnostic.get("native_bake_failures", 0)) == 0
			and not bool(diagnostic.get("gdscript_fallback_enabled", true))
			and int(diagnostic.get("gdscript_fallback_calls", 0)) == 0)
	var nodes: Dictionary = layer._chunk_nodes.values()[0] if not layer._chunk_nodes.is_empty() else {}
	_expect("q1 chunk uses body, decal and shadow shared batches",
		nodes.has("body") and nodes.has("decal") and nodes.has("shadow")
		and nodes.size() == 3)
	var body = nodes.get("body")
	var first_buffer: PackedFloat32Array = body.multimesh.buffer.duplicate() \
		if body is MultiMeshInstance2D else PackedFloat32Array()
	var first_instances := _snapshot_instances(body.multimesh) \
		if body is MultiMeshInstance2D else []
	layer._enqueue_chunk_rebuild(0)
	await process_frame
	var rebuilt_nodes: Dictionary = layer._chunk_nodes.get(0, {})
	var rebuilt_body = rebuilt_nodes.get("body")
	var second_buffer: PackedFloat32Array = rebuilt_body.multimesh.buffer \
		if rebuilt_body is MultiMeshInstance2D else PackedFloat32Array()
	var second_instances := _snapshot_instances(rebuilt_body.multimesh) \
		if rebuilt_body is MultiMeshInstance2D else []
	_expect("same input deterministically regenerates identical MultiMesh buffer",
		(first_buffer == second_buffer and not first_buffer.is_empty())
		or (first_buffer.is_empty() and second_buffer.is_empty()
			and not first_instances.is_empty() and first_instances == second_instances))
	# Cell 1 is water, so both cached rows would produce twice as many compounds
	# without the land gate. The land row holds 32 buildings, which sits at
	# density 0.304 on the ladder and therefore rounds to 7 compounds.
	_expect("water cells never create building geometry",
		int(layer.diagnostics().get("body_instances", 0)) == 7)
	_expect("worst fixture bake records a measurable performance diagnostic",
		float(layer.diagnostics().get("max_chunk_bake_ms", -1.0)) >= 0.0)
	var lone_specs := layer._build_cell_specs(2, {
		"observed_era_index": 0,
		"type_indices": PackedInt32Array([0]),
		"counts": PackedInt64Array([1]),
	})
	_expect("one authoritative building stays one visual compound",
		lone_specs.size() == 1)
	if lone_specs.size() == 1:
		var lone_transform: Transform2D = lone_specs[0].transform
		_expect("single compound keeps an upright authored orientation",
			is_zero_approx(lone_transform.x.y)
			and is_zero_approx(lone_transform.y.x)
			and lone_transform.x.x > 0.0 and lone_transform.y.y > 0.0)
		_expect("single compound is anchored at the cell center",
			lone_transform.origin == layer._cell_world_position(2))
	# A compound is drawn on a quad two units wide with artwork over about 85%
	# of it, while a pointy-top hex is only sqrt(3) * hex_size wide. Buildings
	# that eat the whole hex bury the terrain and vegetation underneath, so the
	# largest settlement reads as a marker occupying a small fraction of it.
	var hex_width := sqrt(3.0) * layer._hex_size
	var widest_specs := layer._build_cell_specs(2, {
		"observed_era_index": 10,
		"type_indices": PackedInt32Array([0]),
		"counts": PackedInt64Array([1 << 40]),
	})
	_expect("the largest settlement still produces geometry", widest_specs.size() >= 1)
	if widest_specs.size() >= 1:
		var widest := 0.0
		for spec in widest_specs:
			var spec_transform: Transform2D = spec.transform
			widest = maxf(widest, spec_transform.x.x * 2.0 * 0.85
				* layer.COMPOUND_VISUAL_SCALE)
		_expect("widest compound stays inside the hex width budget (%.3f)"
			% (widest / hex_width),
			widest <= hex_width * layer.COMPOUND_MAX_HEX_WIDTH_FRACTION)
		_expect("widest compound is not degenerate (%.3f)"
			% (widest / hex_width), widest > hex_width * 0.05)
	# The settlement ring must keep the whole cluster inside its own cell and
	# clear of the neighbours, otherwise buildings read as belonging to the
	# wrong hex. The widest ring belongs to agriculture/extractive at 0.54, and
	# the ladder top opens the ring furthest.
	var cluster_reach := (0.54 * layer.COMPOUND_SPREAD_MAX
		+ layer.COMPOUND_SCALE_MAX * 0.85 * layer.COMPOUND_VISUAL_SCALE) \
		* layer._hex_size
	_expect("settlement cluster stays within the hex inradius (%.3f)"
		% (cluster_reach / layer._hex_size),
		cluster_reach < layer._hex_size * sqrt(3.0) * 0.5)
	# The density ladder is the single source of truth for how big a settlement
	# looks. Pin the documented anchors so a tuning change cannot silently
	# collapse the mid-game range or overshoot the hex. Hex area is sqrt(3)/2 of
	# its bounding width squared.
	for anchor in [
		{"total": 1, "compounds": 1, "coverage": 0.009},
		{"total": 15, "compounds": 6, "coverage": 0.073},
		{"total": 100, "compounds": 10, "coverage": 0.152},
		{"total": 1000, "compounds": 14, "coverage": 0.270},
		{"total": 10000, "compounds": 19, "coverage": 0.456},
		{"total": 100000, "compounds": 24, "coverage": 0.700},
	]:
		var density: float = layer._settlement_density(int(anchor.total))
		var compounds := roundi(float(layer.COMPOUND_COUNT_MAX) * density)
		var width_fraction := lerpf(layer.COMPOUND_SCALE_MIN,
			layer.COMPOUND_SCALE_MAX, density) * 2.0 * 0.85 \
			* layer.COMPOUND_VISUAL_SCALE / sqrt(3.0)
		var coverage := float(compounds) * width_fraction * width_fraction \
			/ (sqrt(3.0) * 0.5)
		_expect("ladder anchor total=%d draws %d compounds covering %.3f of the hex"
			% [int(anchor.total), compounds, coverage],
			compounds == int(anchor.compounds)
			and absf(coverage - float(anchor.coverage)) < 0.005)
	# Drawing more compounds than the cell actually owns would misreport the
	# economy. Rounding the ladder keeps the count honest at every small total.
	var honest := true
	for total in range(1, 11):
		var specs := layer._build_cell_specs(2, {
			"observed_era_index": 3,
			"type_indices": PackedInt32Array([0]),
			"counts": PackedInt64Array([total]),
		})
		if specs.size() > total:
			honest = false
	_expect("compound count never exceeds the authoritative building total",
		honest)
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
	_expect("macro receives shared TOD phase",
		is_equal_approx(float(layer._macro_material.get_shader_parameter("day_phase")), 0.73))
	_expect("analytic shadow receives shared astronomical phase",
		is_equal_approx(float(layer._shadow_material.get_shader_parameter("day_phase")), 0.73))
	_expect("body receives TOD debug and exposure state",
		bool(layer._body_material.get_shader_parameter("tod_debug_sun_position_enabled"))
		and Vector2(layer._body_material.get_shader_parameter("tod_debug_sun_uv"))
			.is_equal_approx(Vector2(0.61, 0.42))
		and is_equal_approx(float(layer._body_material.get_shader_parameter("tod_exposure")), 1.15))
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
	layer.free()
	# DCWorldExt is RefCounted; dropping the local reference releases it.
	native_ext = null
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


func _snapshot_instances(multimesh: MultiMesh) -> Array:
	var out := []
	if multimesh == null:
		return out
	for i in multimesh.instance_count:
		out.append(multimesh.get_instance_transform_2d(i))
		out.append(multimesh.get_instance_custom_data(i))
	return out


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error(label)
