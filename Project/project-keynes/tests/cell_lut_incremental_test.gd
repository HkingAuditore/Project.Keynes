extends SceneTree

# Headless:
#   godot --headless --path . --script res://tests/cell_lut_incremental_test.gd --quit

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
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
