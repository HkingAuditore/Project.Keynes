extends SceneTree

# Headless:
# godot --headless --path . --script tests/map_overlay_cell_lut_test.gd

const RuntimeOverlay = preload("res://scripts/game/world_runtime_overlay.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var map := MapData.new(3, 1)
	for q in range(3):
		var cell := HexCell.new(q, 0)
		cell.elevation = float(q) * 0.5
		cell.landform = q
		cell.vegetation = q
		map.set_cell(cell)
	map.rebuild_soa_from_cells()

	var world := WorldData.new()
	world.lut_dims = Vector2i(4, 1)
	world.derived_size = Vector2i(1024, 606)
	var adapter := DCViewAdapter.Cell.new(map.iter_cells())
	var elevation := DataOverlayBaker.bake_cell_lut(
		map, world, OverlayMode.MODE.ELEVATION, null, 0.0, adapter)
	var elevation_buf: PackedByteArray = elevation.get("buf", PackedByteArray())
	_expect("LUT allocates lut_dims only", elevation_buf.size() == 16)
	_expect("upload byte count is cell LUT size", int(elevation.get("upload_bytes", 0)) == 16)
	_expect("elevation cell 0 encoded", elevation_buf[0] == 0 and elevation_buf[3] == 255)
	_expect("elevation cell 2 encoded", elevation_buf[8] == 255 and elevation_buf[11] == 255)
	_expect("unused LUT texel transparent", elevation_buf[15] == 0)

	var timber: ResourceProfile = ResourceProfileRegistry.ordered()[0]
	map.resource_habitat_mask_arr[0] = 1
	map.resource_habitat_mask_arr[1] = 1
	map.resource_habitat_mask_arr[2] = 1
	map.res_timber_reserve_arr[0] = 0.0
	map.res_timber_reserve_arr[1] = ResourceProfileRegistry.reference_reserve(timber) * 0.5
	map.res_timber_reserve_arr[2] = ResourceProfileRegistry.reference_reserve(timber)
	var resource := DataOverlayBaker.bake_cell_lut(
		map, world, OverlayMode.MODE.RESOURCE_RESERVE, null, 0.0, adapter,
		timber, elevation.get("texture"), elevation_buf, elevation.get("image"))
	var resource_buf: PackedByteArray = resource.get("buf", PackedByteArray())
	_expect("zero reserve is transparent", resource_buf[3] == 0)
	_expect("half reference reserve is mid ramp", absi(int(resource_buf[4]) - 128) <= 1)
	_expect("reference reserve saturates", resource_buf[8] == 255)
	_expect("texture and buffer reused", resource.get("texture") == elevation.get("texture"))
	_expect("Image object reused", resource.get("image") == elevation.get("image"))
	_expect("reference reserve is stable positive", ResourceProfileRegistry.reference_reserve(timber) >= 1.0)
	var arable: ResourceProfile = null
	for profile in ResourceProfileRegistry.ordered():
		if profile != null and profile.id == &"arable_land":
			arable = profile
			break
	_expect("coverage floor uses the same scaled units as generated reserves",
		arable != null and is_equal_approx(
			ResourceProfileRegistry.reference_reserve(arable),
			float(arable.init_min_reserve) * ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
		))
	var all_icons_registered := true
	for profile in ResourceProfileRegistry.ordered():
		if profile != null and profile.icon == null \
				and ResourceProfileRegistry.icon_key(profile) == "unknown":
			all_icons_registered = false
			break
	_expect("all current resources have registered icon semantics", all_icons_registered)
	_expect("resource ramp separates low and middle reserves",
		_ramp_has_separated_steps(OverlayMode.MODE.RESOURCE_RESERVE,
			PackedFloat32Array([0.05, 0.15, 0.30, 0.60]), 0.24))
	_expect("elevation ramp separates adjacent altitude bands",
		_ramp_has_separated_steps(OverlayMode.MODE.ELEVATION,
			PackedFloat32Array([0.10, 0.30, 0.50, 0.70, 0.90]), 0.24))

	var catalog := ResearchSignalCatalog.compile_native_catalog()
	var maize_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.maize")
	_expect("maize occupancy bit is valid", maize_bit >= 0 and maize_bit < 32)
	map.bio_occupancy_bits_arr[0] = 1 << maize_bit
	map.bio_occupancy_bits_arr[1] = 0
	map.bio_occupancy_bits_arr[2] = 0
	var occupancy := DataOverlayBaker.bake_cell_lut(
		map, world, OverlayMode.MODE.BIO_OCCUPANCY, null, 0.0, adapter,
		null, resource.get("texture"), resource_buf, resource.get("image"),
		maize_bit)
	var occupancy_buf: PackedByteArray = occupancy.get("buf", PackedByteArray())
	_expect("maize occupancy cell is opaque", occupancy_buf[3] == 255)
	_expect("maize occupancy encodes occupancy bit", occupancy_buf[0] == maize_bit)
	_expect("neighbor without maize occupancy is transparent", occupancy_buf[7] == 0)
	_expect("far cell without maize occupancy is transparent", occupancy_buf[11] == 0)
	_expect("maize occupancy stays on cell LUT path",
		String(occupancy.get("path", "")) == "cell_lut")
	_expect("maize occupancy valid count is one cell",
		int(occupancy.get("stats", {}).get("count", 0)) == 1)

	_check_runtime_refresh(map, world)
	print("=== map overlay cell LUT: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_runtime_refresh(map: MapData, world: WorldData) -> void:
	var ext = ClassDB.instantiate("DCWorldExt")
	var bound: bool = ext != null and ext.bind_map_data(map)
	_expect("native display inputs are bound", bound)
	if not bound:
		return
	map.wind_x_arr = PackedFloat32Array([1, 1, 1])
	map.wind_y_arr = PackedFloat32Array([0, 0, 0])
	map.wind_speed_arr = PackedFloat32Array([0.25, 0.25, 0.25])

	var layer := DataOverlayLayer.new()
	root.add_child(layer)
	var atlas := DataOverlayBaker.get_empty_texture()
	layer.configure_cell_lut(atlas, world.lut_dims)
	var overlay := RuntimeOverlay.new()
	var adapter := DCViewAdapter.Cell.new(map.iter_cells())
	var request_process := func(_enabled: bool) -> void: pass
	overlay.bind_resources(null, layer, map, world, adapter, null, null, true, request_process)
	overlay.set_map_overlay({"mode": OverlayMode.MODE.ELEVATION})
	var shared_texture := overlay._map_overlay_tex
	_expect("first open generates elevation", overlay._map_overlay_refresh_count == 1)
	_expect_current_bake("first elevation", overlay, map, world, OverlayMode.MODE.ELEVATION)
	overlay.set_map_overlay({"mode": OverlayMode.MODE.ELEVATION})
	_expect("reselecting the active layer reuses it", overlay._map_overlay_refresh_count == 1)
	for i in range(3):
		_refresh(overlay, 0, "unchanged elevation %d" % i)
	_expect_current_bake("unchanged elevation", overlay, map, world, OverlayMode.MODE.ELEVATION)
	map.wind_y_arr[0] = 1.0
	_refresh(overlay, 0, "wind direction does not rebuild elevation")

	var original_pixels := overlay._map_overlay_image.get_data()
	var heights := map.elevation_arr
	heights.set(1, 0.22)
	_refresh(overlay, 1, "one height edited through a packed array alias")
	_expect("only the edited elevation texel changes",
		overlay._map_overlay_buf.slice(0, 4) == original_pixels.slice(0, 4)
		and overlay._map_overlay_buf.slice(4, 8) != original_pixels.slice(4, 8)
		and overlay._map_overlay_buf.slice(8) == original_pixels.slice(8))
	_expect_current_bake("edited elevation", overlay, map, world, OverlayMode.MODE.ELEVATION)
	var saved_height := heights[1]
	heights[1] = 0.75
	overlay.mark_map_overlay_dirty(&"test")
	heights[1] = saved_height
	_refresh(overlay, 0, "coalesced height edits return to the last baked bytes")
	map.elevation_arr = map.elevation_arr.duplicate()
	_refresh(overlay, 0, "equal replacement elevation column")
	ext.write_f32(ext.component_id(&"cell_elevation"), 1, 0.85)
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_elevation"]))
	_refresh(overlay, 1, "native whole-column height writeback")
	_expect_current_bake("native elevation", overlay, map, world, OverlayMode.MODE.ELEVATION)

	var previous_count := overlay._map_overlay_refresh_count
	overlay.set_map_overlay({"mode": OverlayMode.MODE.WIND_DIR})
	_expect("switch to wind builds into the shared texture",
		overlay._map_overlay_refresh_count == previous_count + 1
		and overlay._map_overlay_tex == shared_texture)
	_expect_current_bake("first wind", overlay, map, world, OverlayMode.MODE.WIND_DIR)
	_install_test_wind_receipt(map)
	for i in range(3):
		_refresh(overlay, 0, "unchanged wind %d" % i)
	map.wind_x_arr = map.wind_x_arr.duplicate()
	map.wind_y_arr = map.wind_y_arr.duplicate()
	map.wind_speed_arr = map.wind_speed_arr.duplicate()
	_install_test_wind_receipt(map)
	_refresh(overlay, 0, "republished columns from the same wind solve")
	_expect("unchanged wind retains the verified solve",
		overlay._baked_inputs.get("solve_id", 0) == 11)
	_expect_current_bake("unchanged wind", overlay, map, world, OverlayMode.MODE.WIND_DIR)
	map.elevation_arr[0] = 0.19
	_refresh(overlay, 0, "elevation does not rebuild wind")
	var old_wind := overlay._map_overlay_image.get_data()
	map.wind_x_arr[0] = -1.0
	_refresh(overlay, 1, "one cell changes wind x")
	_expect("changing x changes hue", old_wind[0] != overlay._map_overlay_buf[0])
	_expect("an edit rejects the stale wind receipt", overlay._baked_inputs.get("solve_id", -1) == 0)
	old_wind = overlay._map_overlay_image.get_data()
	map.wind_y_arr[0] = -1.0
	_refresh(overlay, 1, "one cell changes wind y")
	_expect("changing y changes hue", old_wind[0] != overlay._map_overlay_buf[0])
	_expect_current_bake("direction alone", overlay, map, world, OverlayMode.MODE.WIND_DIR)
	old_wind = overlay._map_overlay_image.get_data()
	map.wind_speed_arr[0] = 1.25
	_refresh(overlay, 1, "one cell changes only wind speed")
	_expect("changing speed changes brightness and preserves hue",
		old_wind[0] == overlay._map_overlay_buf[0] and old_wind[1] != overlay._map_overlay_buf[1]
		and old_wind.slice(4) == overlay._map_overlay_buf.slice(4))
	_expect_current_bake("speed alone", overlay, map, world, OverlayMode.MODE.WIND_DIR)
	map.wind_speed_arr[0] = 0.45
	overlay.mark_map_overlay_dirty(&"test")
	map.wind_speed_arr[0] = 1.25
	_refresh(overlay, 0, "coalesced wind edits return to the last baked bytes")

	overlay._map_overlay_tex = null
	_refresh(overlay, 1, "lost texture regenerates unchanged wind")
	_expect("lost texture is replaced", overlay._map_overlay_tex != shared_texture)
	var resized_texture := overlay._map_overlay_tex
	resized_texture.set_image(Image.create_empty(1, 1, false, Image.FORMAT_RGBA8))
	_refresh(overlay, 1, "wrong-sized texture regenerates unchanged wind")
	_expect("texture dimensions are restored", overlay._map_overlay_tex.get_size() == Vector2(world.lut_dims))
	layer.set_cell_lut_texture(null)
	_refresh(overlay, 1, "unchanged inputs repopulate a cleared texture binding")
	layer.configure_cell_lut(atlas, world.lut_dims)
	_refresh(overlay, 1, "same-dimension layout rebinding rebuilds")

	var same_cells := map.iter_cells().duplicate()
	map._cells.clear()
	for i in range(same_cells.size() - 1, -1, -1):
		map.set_cell(same_cells[i])
	map._build_indices()
	_expect("test reorders cells without changing column bytes", map.cell_at(0) == same_cells.back())
	_refresh(overlay, 1, "changed cell ordering rebuilds at the same size")

	var replacement := MapData.new(map.width, map.height)
	for q in range(3):
		var cell := HexCell.new(2 - q, 0)
		cell.elevation = 0.1 + float(q) * 0.3
		cell.wind_vector = Vector2.DOWN
		cell.wind_speed = float(q + 1)
		replacement.set_cell(cell)
	replacement.rebuild_soa_from_cells()
	_expect("replacement map binds", ext.bind_map_data(replacement))
	adapter = DCViewAdapter.Cell.new(replacement.iter_cells())
	overlay.bind_resources(null, layer, replacement, world, adapter, null, null, true, request_process)
	_refresh(overlay, 1, "same-size replacement map rebuilds")
	_expect_current_bake("replacement wind", overlay, replacement, world, OverlayMode.MODE.WIND_DIR)
	_expect("old map no longer tracks wind", not map.has_meta(RuntimeOverlay.TRACK_WIND))
	previous_count = overlay._map_overlay_refresh_count
	overlay.set_map_overlay({"mode": OverlayMode.MODE.ELEVATION})
	_expect("switching back rebuilds elevation", overlay._map_overlay_refresh_count == previous_count + 1)
	_expect_current_bake("replacement elevation", overlay, replacement, world, OverlayMode.MODE.ELEVATION)
	replacement.remove_meta(RuntimeOverlay.OVERLAY_INPUT_READER)
	_refresh(overlay, 1, "missing change information falls back to a full refresh")
	_expect("missing input snapshot is reported", overlay._input_check == &"inputs_unavailable")
	_expect_current_bake("fallback elevation", overlay, replacement, world, OverlayMode.MODE.ELEVATION)
	overlay.set_map_overlay({"mode": OverlayMode.MODE.HUMIDITY})
	_refresh(overlay, 1, "humidity still follows the existing refresh rules")
	overlay.clear_map_overlay()
	overlay.release_resources()
	layer.free()


func _install_test_wind_receipt(map: MapData) -> void:
	# Use the native reader to retain each typed column independently of its
	# script alias, as the real committed writeback does.
	var reader: Callable = map.get_meta(RuntimeOverlay.OVERLAY_INPUT_READER, Callable())
	var snapshot: Dictionary = reader.call(map, true, map.cell_count(), {})
	map.set_meta(RuntimeOverlay.WIND_PUBLICATION, {"lanes": snapshot.lanes, "solve_id": 11, "solve_day": 3})


func _refresh(overlay, bakes: int, label: String) -> void:
	var before: int = overlay._map_overlay_refresh_count
	overlay.mark_map_overlay_dirty(&"test")
	overlay._map_overlay_last_refresh_msec = Time.get_ticks_msec()
	overlay._refresh_map_overlay(false)
	_expect(label + " waits for the refresh interval",
		overlay._map_overlay_dirty and overlay._map_overlay_refresh_count == before)
	overlay._map_overlay_last_refresh_msec -= overlay._map_overlay_refresh_interval_msec()
	overlay._refresh_map_overlay(false)
	_expect(label, not overlay._map_overlay_dirty and overlay._map_overlay_refresh_count == before + bakes)


func _expect_current_bake(label: String, overlay, map: MapData, world: WorldData, mode: int) -> void:
	# Direct unchanged encoder is the full-refresh reference.
	var expected := DataOverlayBaker.bake_cell_lut(map, world, mode, null, 0.0)
	_expect(label + " image and stats match full refresh byte for byte",
		overlay._map_overlay_image != null and overlay._map_overlay_image.get_data() == expected.buf
		and var_to_bytes(overlay._map_overlay_last_result.stats) == var_to_bytes(expected.stats)
		and overlay._map_overlay_layer.has_cell_lut_texture(overlay._map_overlay_tex))


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


func _ramp_has_separated_steps(
		mode: int,
		samples: PackedFloat32Array,
		min_rgb_distance: float
) -> bool:
	var legend := OverlayLegend.new()
	var previous: Color = legend.call("_sample_ramp_color", mode, samples[0])
	var separated := true
	for i in range(1, samples.size()):
		var current: Color = legend.call("_sample_ramp_color", mode, samples[i])
		var dr := current.r - previous.r
		var dg := current.g - previous.g
		var db := current.b - previous.b
		if sqrt(dr * dr + dg * dg + db * db) < min_rgb_distance:
			separated = false
			break
		previous = current
	legend.free()
	return separated
