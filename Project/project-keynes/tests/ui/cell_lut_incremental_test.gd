extends SceneTree

# Headless:
#   godot --headless --path . --script res://tests/ui/cell_lut_incremental_test.gd

const RendererWeatherState = preload("res://scripts/rendering/renderer_weather_state.gd")
const WindSource = preload("res://scripts/rendering/weather_wind_source.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run_and_exit.call_deferred()


func _run_and_exit() -> void:
	_run()
	await _test_late_presentation()
	print("=== cell LUT incremental: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt is available", false)
		return

	var map := _make_map()
	var dirty_world := DCWorld.new()
	dirty_world.bind_map_data(map)
	_expect("dirty world binds", dirty_world.is_bound())

	var ext := DCWorldExt.new()
	_expect("native world binds", bool(ext.bind_map_data(map)))
	ext.bind_dirty_world(dirty_world)

	_test_precise_native_flush(ext, dirty_world)
	_test_dense_native_flush(ext, dirty_world, map)
	_test_incremental_lut(ext, dirty_world, map)
	_test_cell_table_selective_upload()
	_test_worker_lut_upload_batch()
	_test_worker_ecology_frame(ext, map)
	_test_held_distinct_cells()


func _make_map() -> MapData:
	var map := MapData.new(4, 1)
	for q in range(4):
		var cell := HexCell.new(q, 0)
		cell.terrain = int(TerrainType.TERRAIN.PLAIN)
		cell.base_terrain = int(TerrainType.TERRAIN.PLAIN)
		cell.vegetation = int(VegetationType.VEG.NONE)
		cell.base_vegetation = int(VegetationType.VEG.NONE)
		cell.cover = 0
		cell.temperature = 0.5
		cell.moisture = 0.5
		cell.snow_cover = 0.0
		cell.vegetation_vitality = 0.5
		cell.passable_land = true
		cell.passable_sea = false
		map.set_cell(cell)
	map.rebuild_soa_from_cells()
	return map


func _test_cell_table_selective_upload() -> void:
	var map := _make_map()
	var baker := MapBaker.new()
	baker._last_bake_map = map
	var world := WorldData.new()
	world.lut_dims = Vector2i(4, 1)
	var enums := PackedByteArray()
	enums.resize(16)
	for cell in map.cell_count():
		enums[cell * 4 + 3] = 255
	var state := PackedByteArray()
	state.resize(16)
	var eco := state.duplicate()
	var initial := {}
	DCCellLutBaker._publish_cell_lut_textures(baker, world, enums, state, eco, initial)
	_expect("cold cell table publishes the fog layer",
		"aux" in String(initial.get("cell_table_layers", "")).split(","))
	var initial_fog_revision := world.fog_texture_revision
	var initial_land_revision := world.land_base_revision
	var initial_fog := world.cell_table_fog_coverage_source
	state = state.duplicate()
	state[4] = 100
	var daily := {}
	DCCellLutBaker._publish_cell_lut_textures(baker, world, enums, state, eco, daily,
		PackedInt32Array([1]), false, PackedInt32Array())
	_expect("a state-only update skips the unchanged class and fog layers",
		daily.get("cell_table_layers") == "state"
		and world.fog_texture_revision == initial_fog_revision
		and world.land_base_revision == initial_land_revision
		and world.cell_table_fog_coverage_source == initial_fog)

	var land_before_reveal := world.land_base_revision
	enums = enums.duplicate()
	enums[7] = 64
	var reveal := {}
	DCCellLutBaker._publish_cell_lut_textures(baker, world, enums, state, eco, reveal,
		PackedInt32Array([1]), false, PackedInt32Array([1]))
	var fog := world.cell_table_fog_coverage_source
	_expect("a changed fog cell publishes its new coverage byte",
		reveal.get("cell_table_layers") == "aux" and fog != null and fog.get_data()[4] == 64
		and world.land_base_revision == land_before_reveal + 1)

	var new_landform := (int(map.landform_arr[2]) + 1) % 16
	map.landform_arr[2] = new_landform
	var recovered := {}
	DCCellLutBaker._publish_cell_lut_textures(baker, world, enums, state, eco, recovered,
		PackedInt32Array(), true, PackedInt32Array())
	_expect("a full recovery picks up landform changes and retains the installed fog bytes",
		world.cell_table_bound and (baker._cell_table_source_cache["class"][2] >> 24) == new_landform
		and world.cell_table_fog_coverage_source.get_data() == fog.get_data())


func _test_precise_native_flush(ext: DCWorldExt, dirty_world: DCWorld) -> void:
	var temp_id: int = ext.component_id(&"cell_temp")
	_expect("temperature slot exists", temp_id >= 0)
	ext.write_f32(temp_id, 2, 0.75)
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_temp"]))
	_expect("flush defers dirty publication", dirty_world.peek_dirty_count() == 0)
	ext.flush_pending_mark_dirty_all()
	var dirty := dirty_world.read_and_clear_dirty_mask()
	_expect("native flush marks only cell 2", dirty == PackedInt32Array([2]))

	# Re-publishing an identical value must not create another dirty cell.
	ext.write_f32(temp_id, 2, 0.75)
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_temp"]))
	ext.flush_pending_mark_dirty_all()
	_expect("unchanged native flush stays clean", dirty_world.peek_dirty_count() == 0)


func _test_dense_native_flush(ext: DCWorldExt, dirty_world: DCWorld, map: MapData) -> void:
	var temp_id: int = ext.component_id(&"cell_temp")
	for idx in range(map.cell_count()):
		ext.write_f32(temp_id, idx, 0.6 + float(idx) * 0.01)
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_temp"]))
	ext.flush_pending_mark_dirty_all()
	var report: Dictionary = ext.get_native_dirty_report()
	_expect("dense native flush publishes full dirty mask", dirty_world.peek_dirty_count() == 4)
	_expect("dense native flush reports threshold fallback",
		bool(report.get("flush_dirty_dense_fallback", false))
		and int(report.get("flush_dirty_dense_threshold", -1)) == 4
		and int(report.get("flush_dirty_indexed_count", -1)) == 0)
	dirty_world.clear_dirty_mask()
	_expect("clear_dirty_mask clears without index materialization",
		dirty_world.peek_dirty_count() == 0)


func _test_incremental_lut(ext: DCWorldExt, dirty_world: DCWorld, map: MapData) -> void:
	var baker := MapBaker.new()
	baker.set_world_ext(ext)
	var world := WorldData.new()
	world.lut_dims = Vector2i(4, 1)

	var first: Dictionary = baker.refresh_cell_luts_daily(
		map, world, PackedInt32Array(), false)
	_expect("cold LUT encode uses native path", not bool(first.get("fallback", true)))
	_expect("cold LUT encode is full", bool(first.get("full_encode", false)))
	_expect("cold LUT encode processes all cells", int(first.get("processed_cells", -1)) == 4)
	_expect("cold LUT report accounts for all cells", int(first.get("dirty_cells", -1)) == 4)
	_expect("scheduler report omits LUT payloads", _report_has_no_lut_payload(first))

	var temp_id: int = ext.component_id(&"cell_temp")
	ext.write_f32(temp_id, 2, 0.85)
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_temp"]))
	ext.flush_pending_mark_dirty_all()
	var dirty := dirty_world.read_and_clear_dirty_mask()
	var temp_update: Dictionary = baker.refresh_cell_luts_daily(map, world, dirty, false)
	_expect("single dirty cell processes one cell", int(temp_update.get("processed_cells", -1)) == 1)
	_expect("temperature-only update leaves enum unchanged",
		int(temp_update.get("enum_changed_cells", -1)) == 0)
	_expect("temperature-only update changes dynamic LUT",
		int(temp_update.get("dynamic_changed_cells", 0)) == 1)
	_expect("incremental report omits LUT payloads", _report_has_no_lut_payload(temp_update))

	var vegetation_id: int = ext.component_id(&"cell_vegetation")
	ext.write_u8(vegetation_id, 2, int(VegetationType.VEG.TEMPERATE_GRASSLAND))
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_vegetation"]))
	ext.flush_pending_mark_dirty_all()
	dirty = dirty_world.read_and_clear_dirty_mask()
	_expect("vegetation flush marks only cell 2", dirty == PackedInt32Array([2]))
	var vegetation_update: Dictionary = baker.refresh_cell_luts_daily(map, world, dirty, false)
	_expect("vegetation change starts one transition",
		int(vegetation_update.get("active_transition_count", 0)) == 1)
	var transition_before := _eco_transition_byte(baker, 2)
	_expect("vegetation transition starts at 255", transition_before == 255)

	var decay: Dictionary = baker.refresh_cell_luts_daily(
		map, world, PackedInt32Array(), false)
	var transition_after := _eco_transition_byte(baker, 2)
	_expect("empty dirty set still advances active transition",
		int(decay.get("processed_cells", -1)) == 1)
	_expect("transition byte decays without simulation dirty",
		transition_after >= 0 and transition_after < transition_before)
	_expect("transition-only update skips enum upload",
		float(decay.get("enum_lut_upload_ms", -1.0)) == 0.0)
	_expect("transition-only update skips dynamic upload",
		float(decay.get("dyn_lut_upload_ms", -1.0)) == 0.0)

	# Drain the transition. The next empty refresh should perform and upload no work.
	var guard := 32
	while baker.cell_lut_active_transition_pending() and guard > 0:
		baker.refresh_cell_luts_daily(map, world, PackedInt32Array(), false)
		guard -= 1
	_expect("transition drains within bounded refreshes", guard > 0)
	var stable: Dictionary = baker.refresh_cell_luts_daily(
		map, world, PackedInt32Array(), false)
	_expect("stable empty refresh processes no cells", int(stable.get("processed_cells", -1)) == 0)
	_expect("stable empty refresh changes no LUT cells",
		int(stable.get("enum_changed_cells", -1)) == 0
		and int(stable.get("dynamic_changed_cells", -1)) == 0
		and int(stable.get("ecology_changed_cells", -1)) == 0)
	_expect("stable empty refresh uploads no cell LUT",
		float(stable.get("enum_lut_upload_ms", -1.0)) == 0.0
		and float(stable.get("dyn_lut_upload_ms", -1.0)) == 0.0
		and float(stable.get("eco_lut_upload_ms", -1.0)) == 0.0)

	# 生产调度入口在达到 dense 阈值时应清 mask + force full encode，不构造
	# PackedInt32Array([0..N))。
	var upload_system := DynamicVisualAtlasUploadSystem.new(
		baker, map, world, 1, null, dirty_world, ext)
	dirty_world.mark_dirty_all()
	var dense_refresh: Dictionary = upload_system.tick({"tick_index": 0, "day_index": 0})
	_expect("dense scheduler refresh uses full encode",
		bool(dense_refresh.get("lut_dense_dirty_fallback", false))
		and bool(dense_refresh.get("full_encode", false))
		and int(dense_refresh.get("processed_cells", -1)) == map.cell_count())
	_expect("dense scheduler reports threshold and clears mask",
		int(dense_refresh.get("lut_dense_dirty_threshold", -1)) == map.cell_count()
		and int(dense_refresh.get("lut_dense_fallback_count", 0)) == 1
		and dirty_world.peek_dirty_count() == 0)


func _eco_transition_byte(baker: MapBaker, cell_index: int) -> int:
	var data: PackedByteArray = baker._cell_eco_lut_bytes_cache
	var byte_index := cell_index * 4 + 2
	return int(data[byte_index]) if byte_index < data.size() else -1


class RecordingBaker extends MapBaker:
	var upload_count := 0
	var upload_bytes := 0
	var uploaded_bytes: Dictionary = {}

	func _lut_tex_from_data(data: PackedByteArray, w: int, h: int, fmt: int,
			existing: ImageTexture) -> ImageTexture:
		var texture := super(data, w, h, fmt, existing)
		upload_count += 1
		upload_bytes += data.size()
		uploaded_bytes[texture.get_instance_id()] = data.duplicate()
		return texture

	func bytes_for(texture: ImageTexture) -> PackedByteArray:
		return uploaded_bytes.get(texture.get_instance_id(), PackedByteArray())


func _test_worker_ecology_frame(ext: DCWorldExt, map: MapData) -> void:
	# Match the native slot to the test map's current vitality before comparing bytes.
	ext.write_f32(ext.component_id(&"cell_vegetation_vitality"), 0, 0.5)
	var frame := {"transition_age": PackedByteArray([237, 0, 0, 0]),
		"previous_vitality": PackedByteArray([64, 128, 128, 128])}
	var bad_frames := [{}, null, {"transition_age": PackedByteArray([237]),
		"previous_vitality": frame.previous_vitality}, {"transition_age": frame.transition_age,
		"previous_vitality": PackedByteArray([64])}, {"transition_age": frame.transition_age,
		"previous_vitality": [64, 128, 128, 128]}]
	for path in ["gdscript", "gdext"]:
		var baker := RecordingBaker.new()
		if path == "gdext":
			baker.set_world_ext(ext)
		var world := WorldData.new()
		world.lut_dims = Vector2i(4, 1)
		var report := DCCellLutBaker.bake_cell_luts(baker, map, world, true, false,
			PackedInt32Array(), true, false, {"cell_lut_frame": frame})
		var ecology := baker.bytes_for(world.eco_lut_tex) if world.eco_lut_tex != null else PackedByteArray()
		_expect("%s uses published transition age and previous vitality" % path,
			report.get("lut_encode_path") == path and ecology.size() == 16
			and ecology[2] == 237 and ecology[3] == 255)
		var uploads := baker.upload_count
		for i in bad_frames.size():
			report = DCCellLutBaker.bake_cell_luts(baker, map, world, true, false,
				PackedInt32Array(), true, false, {"cell_lut_frame": bad_frames[i]})
			_expect("%s refuses malformed worker ecology %d before upload" % [path, i],
				report.get("lut_encode_path") == "none" and report.get("reason") == "invalid_cell_lut_frame"
				and baker.upload_count == uploads and world.eco_lut_tex != null
				and baker.bytes_for(world.eco_lut_tex) == ecology)
		world.lut_dims = Vector2i(1, 1)
		report = DCCellLutBaker.refresh_cell_luts_daily(baker, map, world,
			PackedInt32Array(), true, false, false, {"cell_lut_frame": frame})
		_expect("%s refuses a texture grid smaller than the map" % path,
			report.get("lut_encode_path") == "none" and report.get("reason") == "invalid_lut_dims"
			and baker.upload_count == uploads)
	for i in bad_frames.size():
		var report: Dictionary = ext.encode_cell_luts({"map": map, "n_cells": 4, "lut_w": 4,
			"lut_h": 1, "cache_valid": true, "cell_lut_frame": bad_frames[i]})
		_expect("native encoder refuses malformed worker ecology %d" % i,
			report.get("reason") == "invalid_cell_lut_frame" and not report.has("eco_lut"))


func _test_worker_lut_upload_batch() -> void:
	var reference: Dictionary = _run_worker_lut_days(false)
	var batched: Dictionary = _run_worker_lut_days(true)
	print("  worker texture uploads for three committed days: immediate=%d (%d B) batched=%d (%d B)"
			% [reference.uploads, reference.bytes, batched.uploads, batched.bytes])
	_expect("worker commits keep intermediate textures out of the render queue",
			int(batched.uploads_before_flush) == 0)
	_expect("worker batch uploads fewer textures than three individual days",
			int(batched.uploads) > 0 and int(batched.uploads) < int(reference.uploads) \
			and int(batched.bytes) > 0 and int(batched.bytes) < int(reference.bytes))
	for lane in ["enum_lut_tex", "dyn_lut_tex", "eco_lut_tex", "bounce_lut_tex",
			"weather_lut_tex", "weather_lut_prev_tex"]:
		_expect("worker batch preserves %s bytes" % lane,
				not batched[lane].is_empty() and batched[lane] == reference[lane])
	_expect("worker batch keeps the previous distinct weather for interpolation",
			batched.weather_lut_prev_tex != batched.weather_lut_tex)
	_expect("worker batch keeps ecological transitions advancing each day",
			int(batched.eco_lut_tex[2]) == 255 - 2 * 18)
	_expect("an ordinary LUT update and world replacement keep staged bytes ordered",
			bool(batched.ordered_flush) and bool(batched.replacement_isolated))


func _test_held_distinct_cells() -> void:
	var reference := _encode_distinct_days(false)
	var held := _encode_distinct_days(true)
	_expect("recovery processes both earlier-only and latest changed cells",
		held.processed == 2 and reference.processed == 1)
	_expect("the merged update produces the same class, dynamic and ecology bytes as daily builds",
		held.atlas == reference.atlas and held.atlas[2][6] == 237)


func _encode_distinct_days(hold: bool) -> Dictionary:
	var map := _make_map()
	var ext := DCWorldExt.new()
	ext.bind_map_data(map)
	var baker := RecordingBaker.new()
	baker.set_world_ext(ext)
	var world := WorldData.new()
	world.lut_dims = Vector2i(4, 1)
	baker.bake_cell_luts(map, world)
	var updates := preload("res://scripts/game/world_runtime_map_updates.gd").new()
	var report: Dictionary
	for day in [1, 2]:
		var cell: int = day - 1
		if day == 1:
			ext.write_f32(ext.component_id(&"cell_temp"), cell, 0.8)
		else:
			ext.write_u8(ext.component_id(&"cell_vegetation"), cell, int(VegetationType.VEG.TEMPERATE_GRASSLAND))
		var ages := PackedByteArray([0, 0, 0, 0])
		ages[1] = 237 if day == 2 else 0
		updates.queue({"display_dirty_cells": PackedInt32Array([cell]),
			"display_class_cells": PackedInt32Array([cell]) if day == 2 else PackedInt32Array(),
			"cell_lut_frame": {"transition_age": ages, "previous_vitality": PackedByteArray([128, 128, 128, 128])}})
		if not hold or day == 2:
			var update: Dictionary = updates.collect(PackedInt32Array())
			report = DCCellLutBaker.refresh_cell_luts_daily(baker, map, world,
				update.display_dirty_cells, false, true, false, update)
			updates.applied(day, 0)
	return {"processed": report.get("processed_cells", -1),
		"atlas": [baker._cell_enum_lut_bytes_cache, baker._cell_dyn_lut_bytes_cache, baker._cell_eco_lut_bytes_cache]}


func _run_worker_lut_days(batch: bool) -> Dictionary:
	var map := _make_map()
	var ext := DCWorldExt.new()
	ext.bind_map_data(map)
	var baker := RecordingBaker.new()
	baker.set_world_ext(ext)
	var world := WorldData.new()
	world.lut_dims = Vector2i(4, 1)
	baker.bake_cell_luts(map, world)
	baker.upload_count = 0
	baker.upload_bytes = 0
	var veg_id := ext.component_id(&"cell_vegetation")
	var temp_id := ext.component_id(&"cell_temp")
	var weather_id := ext.component_id(&"cell_weather_intensity")
	ext.write_u8(veg_id, 0, int(VegetationType.VEG.TEMPERATE_GRASSLAND))
	for day in range(3):
		ext.write_f32(temp_id, 0, 0.6 + day * 0.1)
		ext.write_f32(weather_id, 0, 0.25 if day == 0 else 0.75)
		if batch:
			DCCellLutBaker.refresh_cell_luts_daily(baker, map, world,
					PackedInt32Array(), true, true, true)
		else:
			baker.refresh_cell_luts_daily(map, world, PackedInt32Array(), true, true)
	var uploads_before_flush := baker.upload_count
	if batch:
		DCCellLutBaker.flush_staged_cell_lut_upload(baker, world)
	var result := {"uploads_before_flush": uploads_before_flush,
			"uploads": baker.upload_count, "bytes": baker.upload_bytes}
	for lane in ["enum_lut_tex", "dyn_lut_tex", "eco_lut_tex", "bounce_lut_tex",
			"weather_lut_tex", "weather_lut_prev_tex"]:
		result[lane] = baker.bytes_for(world.get(lane))
	if batch:
		ext.write_f32(weather_id, 0, 0.375)
		DCCellLutBaker.refresh_cell_luts_daily(baker, map, world,
				PackedInt32Array(), true, true, true)
		ext.write_f32(weather_id, 0, 0.5)
		baker.refresh_cell_luts_daily(map, world, PackedInt32Array(), true, true)
		var weather_prev := baker.bytes_for(world.weather_lut_prev_tex)
		result.ordered_flush = weather_prev[1] == 96
		ext.write_f32(weather_id, 0, 1.0)
		DCCellLutBaker.refresh_cell_luts_daily(baker, map, world,
				PackedInt32Array(), true, true, true)
		var replacement := WorldData.new()
		replacement.lut_dims = Vector2i(4, 1)
		ext.write_f32(weather_id, 0, 0.125)
		baker.bake_cell_luts(map, replacement)
		var weather_before := baker.bytes_for(replacement.weather_lut_tex)
		DCCellLutBaker.flush_staged_cell_lut_upload(baker, replacement)
		result.replacement_isolated = baker.bytes_for(replacement.weather_lut_tex) == weather_before \
				and weather_before[1] == 32
	return result


class WeatherReader extends Node:
	var timestamp := 0
	var changed_frame := -1

	func _process(_delta: float) -> void:
		var renderer = get_parent()
		var next_timestamp: int = renderer._world.weather_lut_update_usec
		if next_timestamp != timestamp:
			timestamp = next_timestamp
			changed_frame = Engine.get_process_frames()


class RendererFixture extends Node:
	var _map_baker: RecordingBaker
	var _world: WorldData
	var _weather_layer: WeatherReader
	var publish: Callable
	var committed_frame := -1

	func _process(_delta: float) -> void:
		if publish.is_valid():
			committed_frame = Engine.get_process_frames()
			publish.call()
			publish = Callable()


func _test_late_presentation() -> void:
	var map := _make_map()
	var ext := DCWorldExt.new()
	ext.bind_map_data(map)
	var renderer := RendererFixture.new()
	var world := WorldData.new()
	world.lut_dims = Vector2i(4, 1)
	var baker := RecordingBaker.new()
	baker.set_world_ext(ext)
	baker._last_bake_map = map
	baker.bake_cell_luts(map, world)
	var wind := WindSource.new()
	wind.bind(world, map)
	_expect("initial weather upload provides the first wind endpoint", wind.update() and wind.current != null)
	var first_wind: Texture2D = wind.current
	renderer._map_baker = baker
	renderer._world = world
	renderer._weather_layer = WeatherReader.new()
	var prior := world.weather_lut_update_usec
	renderer._weather_layer.timestamp = prior
	renderer.add_child(renderer._weather_layer)
	RendererWeatherState.configure_weather_presentation(renderer)
	root.add_child(renderer)
	var intensity_id := ext.component_id(&"cell_weather_intensity")
	renderer.publish = func() -> void:
		_expect("live renderer accepts a staged upload",
				RendererWeatherState.can_defer_cell_lut_upload(renderer, baker, world))
		map.wind_x_arr[0] = 1.0
		map.wind_speed_arr[0] = 20.0
		ext.write_f32(intensity_id, 0, 0.5)
		DCCellLutBaker.refresh_cell_luts_daily(baker, map, world,
				PackedInt32Array(), true, true, true)
		map.wind_x_arr[0] = -1.0
		ext.write_f32(intensity_id, 0, 0.625)
		DCCellLutBaker.refresh_cell_luts_daily(baker, map, world,
				PackedInt32Array(), true, true, true)
		_expect("worker commit leaves the previous interpolation timestamp alone",
				world.weather_lut_update_usec == prior)
		_expect("a wind read before the late upload still sees the last publication",
				not wind.update() and wind.current == first_wind)
	await process_frame
	await process_frame
	_expect("weather reads the new timestamp in the commit's render frame",
			world.weather_lut_update_usec > prior \
			and renderer._weather_layer.timestamp == world.weather_lut_update_usec \
			and renderer._weather_layer.changed_frame == renderer.committed_frame)
	_expect("render flush consumes the pending batch", world.staged_cell_lut_upload.is_empty())
	_expect("late weather upload flips the weather table once for two staged updates",
			world.weather_table_valid and world.weather_table_cur == 1)
	_expect("late upload supplies the batch's final wind with the previous texture as its endpoint",
			wind.update() and wind.has_previous and wind.previous == first_wind
			and wind._current_wind_bytes.slice(0, 4) == PackedByteArray([0, 127, 255, 255]))
	renderer.free()


func _report_has_no_lut_payload(report: Dictionary) -> bool:
	return not report.has("enum_lut") \
		and not report.has("dyn_lut") \
		and not report.has("eco_lut") \
		and not report.has("weather_lut")


func _expect(name: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % name)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % name)
