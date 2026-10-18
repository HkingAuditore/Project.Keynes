extends SceneTree

var _checks := 0
var _failures := 0
var _zoom_events: Array[float] = []
var _view_events: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var camera := MapCamera.new()
	root.add_child(camera)
	camera.zoom_changed.connect(func(value: float) -> void:
		_zoom_events.append(value)
	)
	camera.view_changed.connect(func(_rect: Rect2, _center: Vector2, _zoom: float) -> void:
		_view_events += 1
	)
	await process_frame
	_zoom_events.clear()
	_view_events = 0

	var center := root.get_viewport().get_visible_rect().size * 0.5
	camera.call("_apply_zoom_anchored", 1.5, center)
	_expect(_zoom_events.size() == 1 and is_equal_approx(_zoom_events[0], 1.5),
		"anchored zoom emits the applied value")
	camera.call("_apply_zoom_anchored", 1.5005, center)
	_expect(_zoom_events.size() == 1, "zoom delta below 0.001 is suppressed")
	camera.set_world_bounds(Rect2(Vector2.ZERO, Vector2(800.0, 500.0)))
	camera.fit_to_viewport(1.0)
	_expect(_zoom_events.size() >= 2, "fit_to_viewport emits zoom_changed")
	camera.call("_emit_view_changed_if_needed", true)
	_expect(_view_events == 1, "camera emits a world-space view rectangle")

	var layer := ShrubLayer.new()
	var profile := ShrubVisualProfile.new()
	profile.detail_kind = ShrubVisualProfile.DetailKind.TREE
	layer.profile = profile
	root.add_child(layer)
	await process_frame
	var count_before := layer.instance_count()
	layer.set_camera_zoom(0.34)
	_expect(not bool(layer.get("_camera_lod_hidden")),
		"legacy profile renderer never inherits family overview hiding")
	_expect(float(layer.get("_zoom_visible_fraction")) > 0.08,
		"legacy profile renderer keeps its original density curve")
	layer.set_family_batch_suppressed(true)
	layer.set_camera_zoom(0.34)
	_expect(not bool(layer.get("_camera_lod_hidden")), "far canopy keeps sparse overview crowns")
	_expect(is_equal_approx(float(layer.get("_zoom_visible_fraction")), 0.08),
		"far canopy uses the eight-percent overview prefix")
	_expect(is_equal_approx(float(layer.get("_lod_alpha")), 1.0),
		"far tree baseline keeps its original alpha")
	layer.set_camera_zoom(0.45)
	_expect(is_equal_approx(float(layer.get("_zoom_visible_fraction")), 0.08),
		"canopy first crossfade starts from the overview prefix")
	layer.set_camera_zoom(0.55)
	_expect(is_equal_approx(float(layer.get("_zoom_visible_fraction")), 0.40),
		"canopy mid LOD uses forty percent density")
	layer.set_camera_zoom(0.95)
	_expect(is_equal_approx(float(layer.get("_zoom_visible_fraction")), 1.0),
		"canopy near LOD reveals the full deterministic prefix")
	_expect(layer.instance_count() == count_before, "zoom LOD never rebuilds or redistributes instances")
	# [shadow-zoom-fade 2026-10-18] 投影按 zoom 淡入而不是在 1.10 上硬关：门槛只决定
	# 开始淡入的位置，之后 0.20 zoom 内升到全强度。
	var min_zoom := float(layer.call("_shadow_min_zoom"))
	_expect(min_zoom <= 1.05, "tree shadow fade-in starts well before the old 1.10 hard cut")
	layer.set_camera_zoom(min_zoom - 0.05)
	_expect(is_equal_approx(float(layer.call("_shadow_zoom_gain")), 0.0),
		"shadows are off below their fade-in threshold")
	layer.set_camera_zoom(min_zoom + 0.10)
	var shadow_ramp := float(layer.call("_shadow_zoom_gain"))
	_expect(shadow_ramp > 0.0 and shadow_ramp < 1.0,
		"shadows ramp in across the threshold instead of popping")
	layer.set_camera_zoom(min_zoom + 0.30)
	_expect(is_equal_approx(float(layer.call("_shadow_zoom_gain")), 1.0),
		"shadows reach full strength above the ramp")
	# [veg-lod-high 2026-10-18] 高画质两件事：树影在总览 zoom 仍然存在，远景树密度接近满值。
	layer.set_visual_quality(2)
	_expect(is_equal_approx(float(layer.call("_shadow_min_zoom")), 0.45),
		"high quality keeps tree shadows down to overview zoom")
	_expect(is_equal_approx(float(layer.call("_resolved_lod_near_density_multiplier")), 1.12),
		"high quality keeps the far tree prefix near full density")
	layer.set_visual_quality(1)
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
	grass_layer.set_family_batch_suppressed(true)
	grass_layer.set_camera_zoom(1.0)
	_expect(bool(grass_layer.get("_camera_lod_hidden")),
		"ground family is hidden in overview LOD")
	grass_layer.set_camera_zoom(1.10)
	_expect(is_equal_approx(float(grass_layer.get("_zoom_visible_fraction")), 0.25),
		"ground mid LOD uses a quarter-density prefix")

	_expect(is_equal_approx(camera.zoom_max, 6.0), "MapCamera zoom_max is 6")
	camera.call("_set_target_zoom", 8.0, center)
	_expect(is_equal_approx(camera.get("_target_zoom").x, 6.0),
		"interactive zoom target clamps at 6")
	camera.restore_view_state(camera.global_position, 6.0)
	_expect(is_equal_approx(camera.zoom.x, 6.0)
		and is_equal_approx(camera.get("_target_zoom").x, 6.0),
		"instant restore can sit at zoom 6")
	var count_at_six := layer.instance_count()
	layer.set_camera_zoom(6.0)
	_expect(layer.instance_count() == count_at_six,
		"zoom 6 only adjusts the visible prefix and never rebuilds instances")

	print("=== camera/detail LOD: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
