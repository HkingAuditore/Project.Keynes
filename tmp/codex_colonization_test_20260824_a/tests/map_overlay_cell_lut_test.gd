extends SceneTree

# Headless:
# godot --headless --path . --script tests/map_overlay_cell_lut_test.gd

var _checks := 0
var _failures := 0


func _init() -> void:
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

	print("=== map overlay cell LUT: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


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
