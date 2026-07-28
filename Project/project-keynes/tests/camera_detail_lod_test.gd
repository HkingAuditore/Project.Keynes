extends SceneTree

var _checks := 0
var _failures := 0
var _zoom_events: Array[float] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var camera := MapCamera.new()
	root.add_child(camera)
	camera.zoom_changed.connect(func(value: float) -> void:
		_zoom_events.append(value)
	)
	await process_frame
	_zoom_events.clear()

	var center := root.get_viewport().get_visible_rect().size * 0.5
	camera.call("_apply_zoom_anchored", 1.5, center)
	_expect(_zoom_events.size() == 1 and is_equal_approx(_zoom_events[0], 1.5),
		"anchored zoom emits the applied value")
	camera.call("_apply_zoom_anchored", 1.5005, center)
	_expect(_zoom_events.size() == 1, "zoom delta below 0.001 is suppressed")
	camera.set_world_bounds(Rect2(Vector2.ZERO, Vector2(800.0, 500.0)))
	camera.fit_to_viewport(1.0)
	_expect(_zoom_events.size() >= 2, "fit_to_viewport emits zoom_changed")

	var layer := ShrubLayer.new()
	var profile := ShrubVisualProfile.new()
	profile.detail_kind = ShrubVisualProfile.DetailKind.TREE
	layer.profile = profile
	root.add_child(layer)
	await process_frame
	var count_before := layer.instance_count()
	layer.set_camera_zoom(0.34)
	_expect(not bool(layer.get("_camera_lod_hidden")), "far LOD never hides the whole tree layer")
	_expect(is_equal_approx(float(layer.get("_zoom_visible_fraction")), 1.0 / 1.75),
		"far tree LOD preserves the original profile count within the expanded near pool")
	_expect(is_equal_approx(float(layer.get("_lod_alpha")), 1.0),
		"far tree baseline keeps its original alpha")
	layer.set_camera_zoom(0.45)
	_expect(is_equal_approx(float(layer.get("_zoom_visible_fraction")), 1.0 / 1.75),
		"tree fade start begins from the original-count baseline")
	layer.set_camera_zoom(0.80)
	_expect(is_equal_approx(float(layer.get("_zoom_visible_fraction")), 1.0),
		"tree layer reveals all pre-generated near detail at the near threshold")
	_expect(layer.instance_count() == count_before, "zoom LOD never rebuilds or redistributes instances")
	var synthetic_cells := PackedInt32Array([10, 10, 10, 20, 20, 30])
	var synthetic_buffer := PackedFloat32Array()
	synthetic_buffer.resize(synthetic_cells.size() * 16)
	for i in range(synthetic_cells.size()):
		synthetic_buffer[i * 16 + 14] = float(i + 1) / 10.0
	var synthetic_sources: Array = [0, 1, 2, 3, 4, 5]
	var lod_order: Dictionary = layer.call(
		"_lod_order_sources",
		synthetic_sources,
		synthetic_cells,
		synthetic_buffer
	)
	var ordered_sources: Array = lod_order.get("order", [])
	var first_cells := {}
	for i in range(mini(3, ordered_sources.size())):
		first_cells[synthetic_cells[int(ordered_sources[i])]] = true
	_expect(first_cells.size() == 3,
		"far prefix is cell-stratified instead of consuming one cell at a time")
	_expect(int(lod_order.get("far_count", 0)) == 5,
		"far baseline reserves a stable per-cell subset before near-only extras")
	_expect(float(layer.call("_effective_spawn_radius_factor")) >= 1.06,
		"PCG candidate discs overlap hex boundaries")

	var grass_layer := ShrubLayer.new()
	var grass_profile := ShrubVisualProfile.new()
	grass_profile.detail_kind = ShrubVisualProfile.DetailKind.GRASS
	grass_layer.profile = grass_profile
	root.add_child(grass_layer)
	await process_frame
	grass_layer.set_camera_zoom(1.0)
	_expect(not bool(grass_layer.get("_camera_lod_hidden")),
		"far grass layer preserves its original baseline")
	_expect(is_equal_approx(float(grass_layer.get("_zoom_visible_fraction")), 1.0 / 1.35),
		"grass reserves a smaller near-detail surplus than trees")

	print("=== camera/detail LOD: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
