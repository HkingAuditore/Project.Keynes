extends SceneTree

# Settlement vegetation clearance + local refresh contract.
# Headless:
#   godot --headless --path Project/project-keynes --script res://tests/settlement_vegetation_avoidance_test.gd

const ShrubLayerScript := preload("res://scripts/rendering/shrub_layer.gd")
const HexRendererScript := preload("res://scripts/rendering/hex_renderer.gd")
const PlayerControllerScript := preload("res://scripts/game/player_controller.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_gdscript_destination_and_neighbour_clearance()
	_test_wrap_seam_clearance()
	_test_native_cross_cell_cull()
	_test_dirty_neighbour_ring()
	await _test_camera_zoom_six_and_restore()
	print("=== settlement vegetation avoidance: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_gdscript_destination_and_neighbour_clearance() -> void:
	var hex_size := 10.0
	var map := _make_map(8, 6)
	var city := map.get_cell_by_cube(HexUtils.offset_to_cube(4, 3))
	var neighbour = map.get_neighbors(city)[0] if city != null else null
	_expect("fixture city exists", city != null and neighbour != null)
	if city == null:
		return

	var layer = ShrubLayerScript.new()
	layer._map = map
	layer._hex_size = hex_size
	var buckets := PackedByteArray()
	buckets.resize(map.cell_count())
	buckets.fill(0)
	buckets[city.index] = 15
	layer.set_settlement_core_buckets(buckets)

	var city_center := HexUtils.cube_to_world(int(city.q), int(city.r), hex_size)
	var neighbour_center := HexUtils.cube_to_world(
		int(neighbour.q), int(neighbour.r), hex_size)
	var far := city_center + Vector2(hex_size * 4.0, 0.0)
	var canopy := hex_size * 0.20

	_expect("city centre is inside the known settlement core",
		bool(layer.call("_overlaps_known_settlement", city_center, canopy)))
	_expect("empty neighbour centre stays vegetated",
		not bool(layer.call("_overlaps_known_settlement", neighbour_center, canopy)))
	_expect("far land stays vegetated",
		not bool(layer.call("_overlaps_known_settlement", far, canopy)))

	# A tree whose source is the neighbour, but whose disc landed in the city.
	# The old path keyed clearance off the source cell and leaked this instance.
	_expect("cross-cell candidate uses the destination settlement, not the source",
		bool(layer.call("_overlaps_known_settlement", city_center, canopy)))

	# Canopy footprint: a trunk just outside the core still overlaps if the
	# authored lobe would paint over the buildings.
	var core_radius: float = float(layer.call("_settlement_core_radius", 15))
	var just_outside := city_center + Vector2(core_radius + 0.02, 0.0)
	_expect("core radius alone does not reject a trunk past the envelope",
		not bool(layer.call("_cell_overlaps_settlement", city, just_outside, 0.0)))
	_expect("candidate canopy radius is added to the settlement envelope",
		bool(layer.call("_overlaps_known_settlement", just_outside, canopy)))

	layer.free()


func _test_wrap_seam_clearance() -> void:
	var hex_size := 10.0
	var map := _make_map(8, 5)
	var city := map.get_cell_by_cube(HexUtils.offset_to_cube(0, 2))
	_expect("wrap fixture city exists", city != null)
	if city == null:
		return

	var layer = ShrubLayerScript.new()
	layer._map = map
	layer._hex_size = hex_size
	var buckets := PackedByteArray()
	buckets.resize(map.cell_count())
	buckets.fill(0)
	buckets[city.index] = 12
	layer.set_settlement_core_buckets(buckets)

	var period := HexUtils.wrap_period_x(map.width, hex_size)
	var city_center := HexUtils.cube_to_world(int(city.q), int(city.r), hex_size)
	var wrapped_copy := city_center + Vector2(period, 0.0)
	_expect("east-wrap copy still maps onto the settlement cell",
		bool(layer.call("_overlaps_known_settlement", wrapped_copy, hex_size * 0.16)))

	var west_neighbour: HexCell = null
	for neighbour in map.get_neighbors(city):
		var off := HexUtils.cube_to_offset(int(neighbour.q), int(neighbour.r))
		if off.x == map.width - 1:
			west_neighbour = neighbour
			break
	_expect("left-edge city has a wrapped right-edge neighbour", west_neighbour != null)
	layer.free()


func _test_native_cross_cell_cull() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt unavailable; native cull path not exercised")
		return

	var hex_size := 10.0
	var grid_w := 8
	var grid_h := 6
	var map := _make_map(grid_w, grid_h)
	var city := map.get_cell_by_cube(HexUtils.offset_to_cube(4, 3))
	var neighbour = map.get_neighbors(city)[0] if city != null else null
	_expect("native fixture cells exist", city != null and neighbour != null)
	if city == null or neighbour == null:
		return

	var city_center := HexUtils.cube_to_world(int(city.q), int(city.r), hex_size)
	var layer = ShrubLayerScript.new()
	layer._hex_size = hex_size
	var core_radius: float = float(layer.call("_settlement_core_radius", 15))

	var clear_buckets := PackedByteArray()
	clear_buckets.resize(map.cell_count())
	clear_buckets.fill(0)
	var city_buckets := clear_buckets.duplicate()
	city_buckets[city.index] = 15

	var ext := DCWorldExt.new()
	var open: Dictionary = ext.call(
		"encode_detail_scatter",
		_scatter_knobs(map, hex_size, [neighbour], clear_buckets))
	var culled: Dictionary = ext.call(
		"encode_detail_scatter",
		_scatter_knobs(map, hex_size, [neighbour], city_buckets))
	_expect("native open encode succeeds", not bool(open.get("fallback", true)))
	_expect("native culled encode succeeds", not bool(culled.get("fallback", true)))
	if bool(open.get("fallback", true)) or bool(culled.get("fallback", true)):
		layer.free()
		return

	var open_buf: PackedFloat32Array = open.get("buffer", PackedFloat32Array())
	var culled_buf: PackedFloat32Array = culled.get("buffer", PackedFloat32Array())
	var open_in_hex := _count_in_cell(open_buf, map, hex_size, city)
	var culled_hits := _count_inside_instance_envelope(
		culled_buf, city_center, core_radius, float(layer.SETTLEMENT_DETAIL_FOOTPRINT_RADIUS), 0.0)
	_expect("neighbour source can reach the city hex without settlement intel",
		open_in_hex > 0)
	_expect("native path culls neighbour-sourced canopies that enter the city",
		culled_hits == 0)
	_expect("native cull does not wipe vegetation outside the city envelope",
		int(culled.get("instance_count", 0)) > 0)

	# Empty destination keeps the open result.
	var empty: Dictionary = ext.call(
		"encode_detail_scatter",
		_scatter_knobs(map, hex_size, [neighbour], clear_buckets))
	_expect("no-settlement rerun matches the open encode",
		int(empty.get("instance_count", 0)) == int(open.get("instance_count", 0)))

	# East-west wrap: city on the left edge, source on the right edge.
	var seam_city := map.get_cell_by_cube(HexUtils.offset_to_cube(0, 2))
	var seam_source: HexCell = null
	for candidate in map.get_neighbors(seam_city):
		if HexUtils.cube_to_offset(int(candidate.q), int(candidate.r)).x == grid_w - 1:
			seam_source = candidate
			break
	_expect("wrap neighbour exists for the seam city", seam_source != null)
	if seam_source != null:
		var seam_center := HexUtils.cube_to_world(
			int(seam_city.q), int(seam_city.r), hex_size)
		var period := HexUtils.wrap_period_x(grid_w, hex_size)
		var seam_clear := clear_buckets.duplicate()
		var seam_city_buckets := clear_buckets.duplicate()
		seam_city_buckets[seam_city.index] = 15
		var seam_open: Dictionary = ext.call(
			"encode_detail_scatter",
			_scatter_knobs(map, hex_size, [seam_source], seam_clear))
		var seam_culled: Dictionary = ext.call(
			"encode_detail_scatter",
			_scatter_knobs(map, hex_size, [seam_source], seam_city_buckets))
		var seam_open_hits := _count_in_cell(
			seam_open.get("buffer", PackedFloat32Array()),
			map, hex_size, seam_city)
		var seam_culled_hits := _count_inside_instance_envelope(
			seam_culled.get("buffer", PackedFloat32Array()),
			seam_center, core_radius, float(layer.SETTLEMENT_DETAIL_FOOTPRINT_RADIUS), period)
		_expect("wrap-source candidates can enter the left-edge city",
			seam_open_hits > 0)
		_expect("native wrap path culls the left-edge settlement core",
			seam_culled_hits == 0)

	layer.free()


func _test_dirty_neighbour_ring() -> void:
	var map := _make_map(8, 5)
	var city := map.get_cell_by_cube(HexUtils.offset_to_cube(3, 2))
	_expect("refresh fixture city exists", city != null)
	if city == null:
		return

	var renderer = HexRendererScript.new()
	renderer.set("_map", map)
	var expanded: PackedInt32Array = renderer.call(
		"_expand_building_detail_refresh_cells",
		PackedInt32Array([city.index]))
	var expected := {city.index: true}
	for neighbour in map.get_neighbors(city):
		expected[neighbour.index] = true
	_expect("building dirty set expands to self plus six neighbours",
		expanded.size() == expected.size())
	var extras := 0
	for idx in expanded:
		if not expected.has(int(idx)):
			extras += 1
	_expect("expanded refresh never includes a cell outside the 1-ring", extras == 0)
	_expect("local refresh is not a full-map rebuild",
		expanded.size() < map.cell_count())

	var edge := map.get_cell_by_cube(HexUtils.offset_to_cube(0, 2))
	var edge_expanded: PackedInt32Array = renderer.call(
		"_expand_building_detail_refresh_cells",
		PackedInt32Array([edge.index]))
	var wrapped := false
	for idx in edge_expanded:
		var cell: HexCell = map.cell_at(int(idx))
		if cell != null and HexUtils.cube_to_offset(int(cell.q), int(cell.r)).x == map.width - 1:
			wrapped = true
			break
	_expect("left-edge dirty cell also refreshes the wrapped right-edge neighbour",
		wrapped)
	_expect("invalid dirty indices are ignored",
		renderer.call(
			"_expand_building_detail_refresh_cells",
			PackedInt32Array([-1, map.cell_count()])).size() == 0)

	var layer = ShrubLayerScript.new()
	renderer.set("_detail_layers", [layer])
	renderer.detail_scatter_enqueue_coalesce_ms = 999999.0
	renderer.detail_scatter_enqueue_max_pending_cells = 64
	renderer.set("_scatter_last_enqueue_msec", Time.get_ticks_msec())
	var buckets := PackedByteArray()
	buckets.resize(map.cell_count())
	buckets.fill(0)
	buckets[city.index] = 8
	layer.set_settlement_core_buckets(buckets)
	renderer.queue_detail_scatter_refresh(expanded)
	var pending: Dictionary = renderer.get("_scatter_pending_seen")
	_expect("vegetation layer keeps the pushed settlement buckets",
		layer.get("_settlement_core_buckets")[city.index] == 8)
	_expect("queued refresh is only the expanded 1-ring",
		pending.size() == expected.size())
	_expect("local refresh does not start a full-map rebuild batch",
		renderer.get("_detail_refresh_queue").is_empty()
		and renderer.get("_detail_refresh_batches").is_empty())
	layer.free()
	renderer.free()


func _test_camera_zoom_six_and_restore() -> void:
	var camera := MapCamera.new()
	root.add_child(camera)
	await process_frame
	_expect("MapCamera default max zoom is 6", is_equal_approx(camera.zoom_max, 6.0))

	var center := root.get_viewport().get_visible_rect().size * 0.5
	camera.call("_set_target_zoom", 10.0, center)
	_expect("smooth zoom target clamps to 6", is_equal_approx(camera.get("_target_zoom").x, 6.0))

	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = center
	camera.zoom = Vector2(6.0, 6.0)
	camera.set("_target_zoom", Vector2(6.0, 6.0))
	camera.handle_player_input(wheel)
	_expect("wheel cannot push zoom past 6", is_equal_approx(camera.get("_target_zoom").x, 6.0))

	var pinch := InputEventMagnifyGesture.new()
	pinch.factor = 4.0
	pinch.position = center
	camera.handle_player_input(pinch)
	_expect("pinch cannot push zoom past 6", is_equal_approx(camera.get("_target_zoom").x, 6.0))

	camera.restore_view_state(Vector2(40.0, 25.0), Vector2(12.0, 12.0))
	_expect("restore clamps an oversized save to 6",
		is_equal_approx(camera.zoom.x, 6.0)
		and is_equal_approx(camera.get("_target_zoom").x, 6.0))
	_expect("restore writes the camera position",
		camera.global_position.is_equal_approx(Vector2(40.0, 25.0)))

	camera.restore_view_state(Vector2(8.0, 9.0), 0.05)
	_expect("restore clamps a tiny save up to zoom_min",
		is_equal_approx(camera.zoom.x, camera.zoom_min)
		and is_equal_approx(camera.get("_target_zoom").x, camera.zoom_min))

	var layer := ShrubLayer.new()
	var profile := ShrubVisualProfile.new()
	profile.detail_kind = ShrubVisualProfile.DetailKind.TREE
	layer.profile = profile
	root.add_child(layer)
	await process_frame
	var count_before := layer.instance_count()
	layer.set_family_batch_suppressed(true)
	layer.set_camera_zoom(3.0)
	var mid_fraction := float(layer.get("_zoom_visible_fraction"))
	layer.set_camera_zoom(6.0)
	_expect("zoom 6 keeps the saturated near prefix",
		is_equal_approx(float(layer.get("_zoom_visible_fraction")), 1.0)
		and mid_fraction >= 0.99)
	_expect("zoom 3→6 does not regenerate vegetation instances",
		layer.instance_count() == count_before)
	root.remove_child(layer)
	layer.free()

	var controller = PlayerControllerScript.new()
	controller.set("_camera", camera)
	controller.restore_view_state(null, {
		"camera_position": Vector2(11.0, 13.0),
		"camera_zoom": Vector2(20.0, 20.0),
		"next_command_sequence": 7,
	})
	_expect("PlayerController restore goes through MapCamera clamp",
		is_equal_approx(camera.zoom.x, 6.0)
		and is_equal_approx(camera.get("_target_zoom").x, 6.0)
		and camera.global_position.is_equal_approx(Vector2(11.0, 13.0)))
	controller.free()
	root.remove_child(camera)
	camera.free()


func _make_map(w: int, h: int) -> MapData:
	var map := MapData.new(w, h)
	for row in range(h):
		for col in range(w):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	return map


func _scatter_knobs(map: MapData, hex_size: float, sources: Array, buckets: PackedByteArray) -> Dictionary:
	var grid_w: int = map.width
	var grid_h: int = map.height
	var period := HexUtils.wrap_period_x(grid_w, hex_size)
	var offw := PackedByteArray()
	offw.resize(grid_w * grid_h)
	offw.fill(0)
	var offi := PackedInt32Array()
	offi.resize(grid_w * grid_h)
	offi.fill(-1)
	for cell in map.iter_cells():
		var off := HexUtils.cube_to_offset(int(cell.q), int(cell.r))
		offi[off.y * grid_w + off.x] = cell.index

	var keys := PackedInt32Array()
	var cells := PackedInt32Array()
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var suit := PackedFloat32Array()
	var att := PackedInt32Array()
	var accp := PackedFloat32Array()
	var vit := PackedFloat32Array()
	var sized := PackedFloat32Array()
	var cr := PackedFloat32Array()
	var cg := PackedFloat32Array()
	var cb := PackedFloat32Array()
	var ca := PackedFloat32Array()
	var salt := 0
	for source in sources:
		var center := HexUtils.cube_to_world(int(source.q), int(source.r), hex_size)
		keys.append(1400 + salt)
		cells.append(int(source.index))
		cx.append(center.x)
		cy.append(center.y)
		suit.append(1.0)
		att.append(192)
		accp.append(1.0)
		vit.append(1.0)
		sized.append(1.0)
		cr.append(0.4)
		cg.append(0.5)
		cb.append(0.3)
		ca.append(1.0)
		salt += 1
	return {
		"hex_size": hex_size,
		"origin_x": 0.0,
		"origin_y": 0.0,
		"size_x": period,
		"size_y": float(grid_h) * hex_size * 1.5 + hex_size,
		"wrap_period_x": period,
		"wrap_edge_margin": 0.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": offw,
		"offset_cell_indices": offi,
		"settlement_core_buckets": buckets,
		"flow_buffer": PackedFloat32Array(),
		"flow_w": 0,
		"flow_h": 0,
		"keys": keys,
		"cell_indices": cells,
		"center_x": cx,
		"center_y": cy,
		"suitability": suit,
		"attempts": att,
		"accept_p": accp,
		"vitality": vit,
		"size_density": sized,
		"color_r": cr,
		"color_g": cg,
		"color_b": cb,
		"color_a": ca,
		"spawn_domain": 0,
		"spawn_radius_factor": 1.35,
		"world_noise_warp_strength": 0.0,
		"patch_cutoff": -1.0,
		"patch_contrast": 1.0,
		"instance_cap": 100000,
		"micro_gap_threshold": -1.0,
		"world_noise_acceptance": 10.0,
		"vitality_dieback_noise_strength": 0.0,
		"min_size_factor": 0.16,
		"max_size_factor": 0.20,
	}


func _count_in_cell(buffer: PackedFloat32Array, map: MapData, hex_size: float, cell: HexCell) -> int:
	var hits := 0
	for i in range(int(buffer.size() / 16)):
		var pos := Vector2(buffer[i * 16 + 3], buffer[i * 16 + 7])
		var destination = HexUtils.world_to_wrapped_cell(map, pos, hex_size)
		if destination != null and int(destination.index) == cell.index:
			hits += 1
	return hits


func _count_inside_instance_envelope(
		buffer: PackedFloat32Array, center: Vector2, core_radius: float,
		footprint_scale: float, period: float) -> int:
	var hits := 0
	for i in range(int(buffer.size() / 16)):
		var pos := Vector2(buffer[i * 16 + 3], buffer[i * 16 + 7])
		var size := Vector2(buffer[i * 16 + 0], buffer[i * 16 + 4]).length()
		var display := HexUtils.nearest_display_world(center, pos.x, period) \
			if period > 0.0001 else center
		var radius := core_radius + maxf(0.0, size) * footprint_scale
		if pos.distance_squared_to(display) < radius * radius:
			hits += 1
	return hits


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
