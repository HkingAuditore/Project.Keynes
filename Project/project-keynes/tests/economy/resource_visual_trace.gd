extends SceneTree

## Same fixture runs against the old and new layer. Captures every instance field,
## per-cell selected styles, saved observations and CPU texture pixels.
const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
var _output := "res://tmp/resource_visual_trace"

func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output="):
			_output = arg.trim_prefix("output=")
	call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output))
	var map := Fixtures.make_map(16, 12)
	for cell in map.cell_count():
		map.bio_occupancy_bits_arr[cell] = (1 << 20) - 1
		map.res_iron_ore_reserve_arr[cell] = 1000000.0
		map.res_coal_reserve_arr[cell] = 1000000.0
	var intel := Intel.new()
	intel.configure(map.cell_count())
	var world := WorldData.new()
	world.lut_dims = Vector2i(map.cell_count(), 1)
	world.world_bounds = Rect2(-40, -40, 700, 450)
	var layer := Layer.new()
	root.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	layer.configure(map, world, 22.0, intel)
	layer.set_context(true, 20261016)
	layer.set_quality(2)
	layer.set_camera_view(world.world_bounds, world.world_bounds.get_center(), 2.0)
	await _capture(layer, intel, "initial")
	map.bio_occupancy_bits_arr[4] = 0
	map.res_iron_ore_reserve_arr[4] = 0.0
	map.res_coal_reserve_arr[4] = 0.0
	_notify(map, 1, PackedInt32Array([4]))
	await _capture(layer, intel, "resource_change")
	map.temp_arr[3] = 0.2
	map.moisture_arr[3] = 0.4
	_notify(map, 2, PackedInt32Array([3]))
	await _capture(layer, intel, "climate_change")
	map.visible_arr[5] = 0
	map.bio_occupancy_bits_arr[5] = 0
	map.res_iron_ore_reserve_arr[5] = 0.0
	map.temp_arr[5] = 0.1
	_notify(map, 7, PackedInt32Array([5]))
	await _capture(layer, intel, "hidden")
	map.visible_arr[5] = 1
	_notify(map, 7, PackedInt32Array([5]))
	await _capture(layer, intel, "revealed")
	var saved := {"version": 4}
	saved.merge(intel.to_pkfg_fields())
	map.visible_arr.fill(0)
	map.bio_occupancy_bits_arr.fill(0)
	map.temp_arr.fill(0.9)
	if not bool(intel.restore_pkfg(saved).ok):
		quit(1)
		return
	await _capture(layer, intel, "restored_hidden")
	layer.queue_free()
	await process_frame
	print("resource visual trace: complete")
	quit(0)

func _capture(layer, intel, label: String) -> void:
	for frame in 400:
		layer.prepare_frame(0.0, Vector3.UP, {})
		layer.drain_one_upload()
		await process_frame
	var keys: Array = layer._active.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))
	var geometry: Array = []
	for key in keys:
		var resident: Dictionary = layer._resident.get(key, {})
		for family in Layer.BATCH_COUNT:
			var buffer := PackedFloat32Array()
			if resident.has(family):
				buffer = resident[family].multimesh.buffer
			geometry.append([key, family, buffer])
	var cells: Array = intel.resource_observations.rows.keys()
	cells.sort()
	var observations: Array = []
	for cell in cells:
		var row: Dictionary = intel.resource_observations.rows[cell]
		observations.append([cell, row.bands, row.climate, layer.selected_styles(cell)])
	var payload: Array = [geometry, observations, layer._memory_image.get_data(),
		layer.ground_cover()._image.get_data()]
	var file := FileAccess.open(_output.path_join(label + ".bin"), FileAccess.WRITE)
	file.store_buffer(var_to_bytes(payload))
	print("resource visual trace: %s cells=%d instances=%d" % [label, observations.size(), int(layer.diagnostics().instances)])

func _notify(map, flags: int, cells: PackedInt32Array) -> void:
	# The old implementation polls; the new implementation consumes publication.
	if map.has_signal("resource_visual_inputs_changed"):
		map.emit_signal("resource_visual_inputs_changed", flags, cells)
