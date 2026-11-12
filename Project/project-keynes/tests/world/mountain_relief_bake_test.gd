extends SceneTree

var _checks := 0
var _failures := 0

func _init() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_generation(ext)
	_bake(ClassDB.instantiate("DCWorldExt"))
	print("[mountain-relief] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _generation(ext: Object) -> void:
	for dims in [Vector2i(40, 28), Vector2i(80, 60), Vector2i(160, 100)]:
		for sea in [0.42, 0.64, 0.80]:
			var cfg := {"width": dims.x, "height": dims.y, "num_continents": 3, "sea_level": sea, "continent_size": 0.9}
			var profile := {"native_generation_mode": 2, "ridge_boost_amp": 0.60}
			var a: Dictionary = ext.run_native_world_generate_base_pass(20261109, cfg, profile)
			var b: Dictionary = ext.run_native_world_generate_base_pass(20261109, cfg, profile)
			var label := "%dx%d sea=%.2f" % [dims.x, dims.y, sea]
			_expect(int(a.get("rc", -1)) == 0, label + " native generation")
			var h: PackedFloat32Array = a.get("elevation_arr", PackedFloat32Array())
			_expect(h.size() == dims.x * dims.y and h == b.get("elevation_arr"), label + " deterministic elevation")
			var valid := h.size() > 0
			for z in h:
				valid = valid and is_finite(z) and z >= 0.0 and z <= 1.0
			_expect(valid, label + " finite bounded elevation")
			var land := int(a.get("ridge_land_cells", 0))
			var tail := int(a.get("ridge_tail_cells", -1))
			_expect(land > 0 and tail >= 0 and tail <= ceili(land * 0.01) + 1, label + " compression limited to summit tail")
			var g := float(a.get("ridge_budget_scale", -1.0))
			_expect(g > 0.0 and g <= 1.0, label + " positive ridge budget")
			print("[mountain-relief/budget] %s g=%.6f base=%.6f tail=%d/%d" % [label, g, a.get("ridge_base_scale", -1), tail, land])
	var full: Dictionary = ext.run_native_world_generate_full_pass(20261109, {"width": 40, "height": 28, "sea_level": 0.64, "num_continents": 3, "continent_size": 0.9}, {"native_generation_mode": 2})
	_expect(int(full.get("rc", -1)) == 0 and full.has("ridge_budget_scale"), "fused generation preserves budget diagnostics")

func _knobs(lf: int, sloped := false) -> Dictionary:
	var h := PackedFloat32Array()
	var ids := PackedInt32Array()
	var t := PackedByteArray()
	var l := PackedByteArray()
	var v := PackedByteArray()
	var wet := PackedFloat32Array()
	for row in range(7):
		for col in range(7):
			h.append(0.86 + (row - 3) * 0.012 if sloped else 0.86)
			ids.append(row * 7 + col)
			t.append(6)
			l.append(lf)
			v.append(0)
			wet.append(0.5)
	return {"width": 256, "height": 160, "map_width": 7, "map_height": 7, "n_cells": 49,
		"origin_x": 0.0, "origin_y": 15.0, "size_x": sqrt(3.0) * 70.0, "size_y": 60.0,
		"hex_size": 10.0, "wrap_period_x": sqrt(3.0) * 70.0, "seed": 20261109, "sea_level": 0.64,
		"cell_elevation": h, "cell_moisture": wet, "cell_terrain": t, "cell_landform": l,
		"cell_vegetation": v, "cell_cover": v, "offset_to_index": ids,
		"num_drops": 0, "shore_carve_amp": 0.0, "dem_valley_river_outlet_flow": 1.0}

func _bake(ext: Object) -> void:
	var ranges := {}
	for lf in [4, 13, 7, 8]:
		var k := _knobs(lf)
		var a: Dictionary = ext.run_bake_terrain_index_pass(k)
		var h: PackedFloat32Array = a.get("height_buffer", PackedFloat32Array())
		_expect(not bool(a.get("fallback", true)) and h.size() == 40960, "landform %d native bake" % lf)
		var lo := 1.0
		var hi := 0.0
		for z in h:
			lo = minf(lo, z)
			hi = maxf(hi, z)
			ranges[lf] = hi - lo
		_expect(lo > 0.64 and hi < 1.0, "landform %d remains above water without clipping" % lf)
		print("[mountain-relief/bake] lf=%d span=%.6f" % [lf, hi - lo])
		if lf == 7:
			var again: Dictionary = ext.run_bake_terrain_index_pass(k)
			_expect(h == again.height_buffer, "mountain bake deterministic")
			k.origin_x += k.wrap_period_x
			var wrapped: Dictionary = ext.run_bake_terrain_index_pass(k)
			_expect(_max_delta(h, wrapped.height_buffer) < 0.00002, "mountain shape repeats across longitude seam")
	_expect(float(ranges[4]) < 0.00001 and float(ranges[13]) < 0.00001, "flat plains and plateau interiors stay flat")
	_expect(float(ranges[7]) > 0.003 and float(ranges[8]) > float(ranges[7]) * 1.2, "flat high summit retains mountain and peak relief")
	var k := _knobs(7, true)
	var before: Dictionary = ext.run_bake_terrain_index_pass(k)
	var after: Dictionary = ext.run_bake_geometry_fields_pass(k)
	_expect(not bool(after.get("fallback", true)), "fused valley bake succeeds")
	var changed := 0
	var monotonic := true
	var a: PackedFloat32Array = before.height_buffer
	var b: PackedFloat32Array = after.height_buffer
	for i in range(a.size()):
		monotonic = monotonic and b[i] <= a[i] + 0.000001 and b[i] > 0.64 and is_finite(b[i])
		if b[i] < a[i] - 0.0001:
			changed += 1
	_expect(monotonic and changed > 100, "drainage cuts valleys without raising terrain or drowning land")
	print("[mountain-relief/valley] cut_pixels=%d" % changed)
	k.cell_landform = PackedByteArray([7])
	_expect(bool(ext.run_bake_terrain_index_pass(k).get("fallback", false)), "malformed landform input fails explicitly")

func _max_delta(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var delta := 0.0
	for i in range(a.size()):
		delta = maxf(delta, absf(a[i] - b[i]))
	return delta

func _expect(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[mountain-relief/FAIL] " + label)
