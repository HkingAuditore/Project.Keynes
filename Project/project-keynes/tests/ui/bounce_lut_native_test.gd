extends SceneTree

# Exact byte/output comparisons against the retained production GDScript path.
# No simulation binding is needed: bounce is derived rendering data only.
const CellLut = preload("res://scripts/rendering/bakers/cell_lut_baker.gd")
var _checks := 0
var _failures := 0
var _ext: DCWorldExt
var _native: MapBaker
var _reference: MapBaker
var _world_native: WorldData
var _world_reference: WorldData


func _init() -> void:
	_ext = DCWorldExt.new()
	_native = MapBaker.new()
	_native.set_world_ext(_ext)
	_reference = MapBaker.new()
	_world_native = WorldData.new()
	_world_reference = WorldData.new()
	_test_all_terrain_boundaries()
	_test_all_snow_vitality_pairs()
	_test_partial_and_restore()
	_test_dispatch_paths()
	print("=== bounce LUT native: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_all_terrain_boundaries() -> void:
	var edges := [0, 1, 63, 127, 128, 254, 255]
	var slots := 256 * edges.size() * edges.size()
	var enums := PackedByteArray()
	var dynamics := PackedByteArray()
	enums.resize(slots * 4)
	dynamics.resize(slots * 4)
	var i := 0
	for terrain in range(256):
		for vitality in edges:
			for snow in edges:
				enums[i * 4] = terrain
				dynamics[i * 4 + 2] = snow
				dynamics[i * 4 + 3] = vitality
				i += 1
	_compare("all terrain bytes and snow/vitality endpoints", enums, dynamics, 256, int(slots / 256))


func _test_all_snow_vitality_pairs() -> void:
	# These include ordinary land, water, sea ice and an unknown terrain fallback.
	# All 65536 byte pairs lock the two float lerps and final integer truncation.
	var terrains := [2, 0, 20, 255]
	var slots := terrains.size() * 256 * 256
	var enums := PackedByteArray()
	var dynamics := PackedByteArray()
	enums.resize(slots * 4)
	dynamics.resize(slots * 4)
	var i := 0
	for terrain in terrains:
		for snow in range(256):
			for vitality in range(256):
				enums[i * 4] = terrain
				dynamics[i * 4 + 2] = snow
				dynamics[i * 4 + 3] = vitality
				i += 1
	_compare("every snow/vitality pair", enums, dynamics, 1024, int(slots / 1024))


func _test_partial_and_restore() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261115
	var enums := PackedByteArray()
	var dynamics := PackedByteArray()
	enums.resize(4096 * 4)
	dynamics.resize(4096 * 4)
	for i in range(4096):
		enums[i * 4] = rng.randi_range(0, 255)
		for c in range(4):
			dynamics[i * 4 + c] = rng.randi_range(0, 255)
	_compare("random full data including 1696 padding slots", enums, dynamics, 2048, 2)
	_expect("padding is encoded", _native._cell_bounce_lut_bytes_cache.slice(2400 * 4) != PackedByteArray())
	var old_bytes: PackedByteArray = _native._cell_bounce_lut_bytes_cache.duplicate()
	for i in [4, 99, 4095]:
		enums[i * 4] = 2
		dynamics[i * 4 + 2] = 255
		dynamics[i * 4 + 3] = 0
	_compare("partial duplicate and invalid indices", enums, dynamics, 2048, 2,
		PackedInt32Array([-1, 4, 4096, 4, 4095, 2147483647]), false)
	_expect("unrequested changed input leaves cached bytes alone",
		_native._cell_bounce_lut_bytes_cache.slice(99 * 4, 100 * 4) == old_bytes.slice(99 * 4, 100 * 4))
	_compare("empty dirty set", enums, dynamics, 2048, 2, PackedInt32Array(), false)
	_compare("only invalid dirty indices", enums, dynamics, 2048, 2, PackedInt32Array([-3, 4096]), false)
	_compare("full forced update", enums, dynamics, 2048, 2)
	var texture_id := _world_native.bounce_lut_tex.get_instance_id()
	_compare("identical full update still publishes", enums, dynamics, 2048, 2)
	_expect("full update retains texture object", _world_native.bounce_lut_tex.get_instance_id() == texture_id)
	_compare("identical valid dirty update", enums, dynamics, 2048, 2, PackedInt32Array([4]), false)
	# Restore a byte-only cache with the texture absent; this must rebuild all slots.
	_world_native.bounce_lut_tex = null
	_world_reference.bounce_lut_tex = null
	_compare("texture missing after restore", enums, dynamics, 2048, 2, PackedInt32Array(), false)
	_native._cell_bounce_lut_bytes_cache.resize(7)
	_reference._cell_bounce_lut_bytes_cache.resize(7)
	_compare("short restored cache", enums, dynamics, 2048, 2, PackedInt32Array(), false)
	var short_enum := enums.slice(0, enums.size() - 1)
	_compare("short enum leaves state unchanged", short_enum, dynamics, 2048, 2)
	var short_dynamic := dynamics.slice(0, dynamics.size() - 1)
	_compare("short dynamic leaves state unchanged", enums, short_dynamic, 2048, 2)
	_compare("both inputs empty leave state unchanged", PackedByteArray(), PackedByteArray(), 2048, 2)


func _test_dispatch_paths() -> void:
	var map := MapData.new(4, 1)
	var terrains := [2, 0, 20, 5]
	for i in range(4):
		var cell := HexCell.new(i, 0)
		cell.terrain = terrains[i]
		cell.base_terrain = terrains[i]
		cell.vegetation = int(VegetationType.VEG.TEMPERATE_GRASSLAND) if i == 0 or i == 3 else int(VegetationType.VEG.NONE)
		cell.base_vegetation = cell.vegetation
		cell.temperature = 0.5
		cell.moisture = 0.5
		cell.snow_cover = float(i) / 3.0
		cell.vegetation_vitality = 1.0 - float(i) / 3.0
		map.set_cell(cell)
	map.rebuild_soa_from_cells()
	var ext := DCWorldExt.new()
	_expect("integrated LUT native bind", bool(ext.bind_map_data(map)))
	var native_baker := MapBaker.new()
	native_baker.set_world_ext(ext)
	var gd_baker := MapBaker.new()
	var native_world := WorldData.new()
	var gd_world := WorldData.new()
	var native_report := native_baker.bake_cell_luts(map, native_world, false, false)
	var gd_report := gd_baker.bake_cell_luts(map, gd_world, false, false)
	_expect("integrated normal path uses native LUTs", not bool(native_report.get("fallback", true)))
	_expect("unavailable native retains whole GD path", bool(gd_report.get("fallback", false))
		and str(gd_report.get("path", "")) == "gdscript")
	_expect("integrated normal path publishes bounce", bool(native_report.get("bounce_lut_published", false)))
	var gd_enums: Image = gd_world.enum_lut_tex.get_image()
	var gd_dynamics: Image = gd_world.dyn_lut_tex.get_image()
	_expect("complete GD LUT images available", gd_enums != null and gd_dynamics != null)
	if gd_enums != null and gd_dynamics != null:
		_bytes_equal("integrated enum inputs match before bounce", native_baker._cell_enum_lut_bytes_cache, gd_enums.get_data())
		_bytes_equal("integrated dynamic inputs match before bounce", native_baker._cell_dyn_lut_bytes_cache, gd_dynamics.get_data())
	_bytes_equal("integrated native and complete GD bounce bytes",
		native_baker._cell_bounce_lut_bytes_cache, gd_baker._cell_bounce_lut_bytes_cache)
	_expect("integrated LUT report contains no payload", not native_report.has("bounce_lut")
		and not native_report.has("enum_lut") and not native_report.has("dyn_lut")
		and not native_report.has("eco_lut") and not native_report.has("weather_lut"))


func _compare(label: String, enums: PackedByteArray, dynamics: PackedByteArray,
		width: int, height: int, dirty: PackedInt32Array = PackedInt32Array(), full: bool = true) -> void:
	var before: PackedByteArray = _native._cell_bounce_lut_bytes_cache.duplicate()
	var opts := {
		"bounce_only": true, "lut_w": width, "lut_h": height, "n_cells": 2400,
		"enum_lut": enums, "dyn_lut": dynamics,
		"bounce_lut": _native._cell_bounce_lut_bytes_cache,
		"dirty_indices": dirty, "force_full_encode": full or _world_native.bounce_lut_tex == null,
		"bounce_palette": MapBaker._BOUNCE_ALBEDO,
		"bounce_fallback": MapBaker._BOUNCE_FALLBACK,
		"bounce_dry": MapBaker._BOUNCE_DRY, "bounce_snow": MapBaker._BOUNCE_SNOW,
		"bounce_water_terrains": MapBaker._BOUNCE_WATER_TERRAINS,
	}
	var out: Dictionary = _ext.encode_cell_luts(opts)
	var inputs_valid := enums.size() >= width * height * 4 and dynamics.size() >= width * height * 4
	_expect(label + ": native input validity", bool(out.get("fallback", true)) == (not inputs_valid))
	_expect(label + ": native does not mutate supplied cache", before == _native._cell_bounce_lut_bytes_cache)
	var expected := CellLut._publish_bounce_lut_gd(_reference, enums, dynamics,
		_world_reference, width, height, dirty, full)
	if inputs_valid:
		_expect(label + ": native changed flag", bool(out.get("bounce_lut_changed", false)) == expected)
		_bytes_equal(label + ": direct native bytes", out["bounce_lut"], _reference._cell_bounce_lut_bytes_cache)
	var actual := _native._publish_bounce_lut(enums, dynamics, _world_native, width, height, dirty, full)
	_expect(label + ": published flag", actual == expected)
	_bytes_equal(label + ": dispatcher bytes", _native._cell_bounce_lut_bytes_cache, _reference._cell_bounce_lut_bytes_cache)
	if not inputs_valid:
		_expect(label + ": cache unchanged", _native._cell_bounce_lut_bytes_cache == before)


func _bytes_equal(label: String, actual: PackedByteArray, expected: PackedByteArray) -> void:
	_expect(label, actual == expected)
	if actual != expected and actual.size() == expected.size():
		for i in range(actual.size()):
			if actual[i] != expected[i]:
				push_error("first byte mismatch at %d: native=%d reference=%d" % [i, actual[i], expected[i]])
				break


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(label)
