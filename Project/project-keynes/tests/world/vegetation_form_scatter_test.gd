extends SceneTree

# Headless:
#   godot --headless --path Project/project-keynes --script res://tests/world/vegetation_form_scatter_test.gd
#
# Top-down impostor scatter contract: native encode_detail_scatter and the
# GDScript fallback agree on candidate position, sub_form / element count and
# crown-scaled size; output is deterministic; denser cells promote canopy
# candidates from singles to clusters and groves; same-cell patches respect
# the exclusion radius.

const ShrubLayerScript := preload("res://scripts/rendering/shrub_layer.gd")
const TreeProfile := preload("res://data/visual/tree_default.tres")
const ShrubProfile := preload("res://data/visual/shrub_default.tres")

const HEX := 10.0
const GRID_W := 8
const GRID_H := 6
const ATTEMPTS := 96

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_pack_round_trip()
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt unavailable; native form scatter not exercised")
	else:
		_test_canopy_native()
		_test_element_count_native()
	print("=== vegetation form scatter: %d checks, %d failures ===" % [_checks, _failures])


func _test_pack_round_trip() -> void:
	var ok := true
	for sub_form in range(3):
		for count in range(1, ShrubLayerScript.FORM_COUNT_MAX + 1):
			var packed: float = ShrubLayerScript.pack_form(sub_form, count)
			ok = ok and ShrubLayerScript.unpack_sub_form(packed) == sub_form \
				and ShrubLayerScript.unpack_form_count(packed) == count
	_expect("pack_form round-trips every sub_form and element count", ok)


func _test_canopy_native() -> void:
	var layer = _make_layer(TreeProfile)
	var suits := [0.10, 0.35, 0.65, 1.0]
	var knobs := _knobs(layer, suits)
	var ext := DCWorldExt.new()
	var a: Dictionary = ext.call("encode_detail_scatter", knobs)
	var b: Dictionary = ext.call("encode_detail_scatter", knobs)
	_expect("native canopy encode succeeds", not bool(a.get("fallback", true)))
	if bool(a.get("fallback", true)):
		layer.free()
		return
	var buf: PackedFloat32Array = a.get("buffer", PackedFloat32Array())
	_expect("native canopy encode is deterministic", buf == b.get("buffer", PackedFloat32Array()))
	_expect("native canopy encode produces instances", buf.size() >= 16)

	var cells: PackedInt32Array = a.get("cell_indices", PackedInt32Array())
	var mean_count := {}
	var n_by_cell := {}
	var groves := 0
	var sizes_ok := true
	var crown := float(TreeProfile.crown_diameter_hex)
	var size_scale: float = layer._quality_size_scale()
	for i in range(int(buf.size() / 16)):
		var packed := buf[i * 16 + 15]
		var sub_form: int = ShrubLayerScript.unpack_sub_form(packed)
		var count: int = ShrubLayerScript.unpack_form_count(packed)
		var size := Vector2(buf[i * 16 + 0], buf[i * 16 + 4]).length()
		var crown_hex := size * 2.0 * ShrubLayerScript.IMPOSTOR_QUAD_HALF \
			* ShrubLayerScript.crown_local_radius(count) / (HEX * size_scale)
		sizes_ok = sizes_ok and crown_hex >= crown * 0.88 * 0.92 - 1e-3 \
			and crown_hex <= crown * 1.12 * 1.06 + 1e-3
		if sub_form == ShrubLayerScript.SUB_FORM_GROVE:
			groves += 1
			sizes_ok = sizes_ok and count >= 5
		var cell := cells[i]
		mean_count[cell] = float(mean_count.get(cell, 0.0)) + float(count)
		n_by_cell[cell] = int(n_by_cell.get(cell, 0)) + 1
	_expect("every canopy crown keeps crown_diameter_hex across sub_forms", sizes_ok)
	_expect("dense canopy cells form groves", groves > 0)
	var sparse_mean := float(mean_count.get(0, 0.0)) / maxf(float(n_by_cell.get(0, 0)), 1.0)
	var dense_mean := float(mean_count.get(3, 0.0)) / maxf(float(n_by_cell.get(3, 0)), 1.0)
	_expect("crowns per instance grow with cell suitability (%.2f -> %.2f)" % [sparse_mean, dense_mean],
		dense_mean > sparse_mean)
	_expect("same-cell canopy patches respect the exclusion radius", _exclusion_ok(buf, cells))
	_expect("GDScript fallback reproduces native canopy scatter", _gd_parity(layer, knobs, buf))
	layer.free()


func _test_element_count_native() -> void:
	var layer = _make_layer(ShrubProfile)
	var knobs := _knobs(layer, [0.5, 1.0])
	var ext := DCWorldExt.new()
	var res: Dictionary = ext.call("encode_detail_scatter", knobs)
	_expect("native shrub encode succeeds", not bool(res.get("fallback", true)))
	if bool(res.get("fallback", true)):
		layer.free()
		return
	var buf: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var lo := int(ShrubProfile.element_count_min)
	var hi := int(ShrubProfile.element_count_max)
	var ok := buf.size() >= 16
	for i in range(int(buf.size() / 16)):
		var packed := buf[i * 16 + 15]
		var count: int = ShrubLayerScript.unpack_form_count(packed)
		ok = ok and ShrubLayerScript.unpack_sub_form(packed) == ShrubLayerScript.SUB_FORM_SINGLE \
			and count >= lo and count <= hi
	_expect("non-canopy profiles draw element_count_min..max elements per instance", ok)
	_expect("GDScript fallback reproduces native shrub scatter", _gd_parity(layer, knobs, buf))
	layer.free()


func _make_layer(source_profile: Resource):
	var layer = ShrubLayerScript.new()
	var cfg: Resource = source_profile.duplicate()
	cfg.set("world_noise_warp_strength", 0.0)
	cfg.set("patch_cutoff", -1.0)
	cfg.set("micro_gap_threshold", -1.0)
	cfg.set("world_noise_acceptance", 10.0)
	cfg.set("vitality_dieback_noise_strength", 0.0)
	layer.profile = cfg
	layer._hex_size = HEX
	return layer


func _knobs(layer, suits: Array) -> Dictionary:
	var cfg: Resource = layer.profile
	var offw := PackedByteArray()
	offw.resize(GRID_W * GRID_H)
	var offi := PackedInt32Array()
	offi.resize(GRID_W * GRID_H)
	for i in range(GRID_W * GRID_H):
		offi[i] = i
	var keys := PackedInt32Array()
	var cells := PackedInt32Array()
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var suit := PackedFloat32Array()
	var att := PackedInt32Array()
	var accp := PackedFloat32Array()
	var vit := PackedFloat32Array()
	var sized := PackedFloat32Array()
	var col := PackedFloat32Array()
	for c in range(suits.size()):
		var row := 2 + int(c / 3)
		var colx := 1 + 2 * (c % 3)
		var q := colx - (row - (row & 1)) / 2
		var center := Vector2(HEX * sqrt(3.0) * (float(q) + float(row) * 0.5), HEX * 1.5 * float(row))
		keys.append(5100 + c * 37)
		cells.append(c)
		cx.append(center.x)
		cy.append(center.y)
		suit.append(float(suits[c]))
		att.append(ATTEMPTS)
		accp.append(1.0)
		vit.append(1.0)
		sized.append(1.0)
		col.append(0.5)
	var knobs := {
		"hex_size": HEX,
		"origin_x": 0.0,
		"origin_y": 0.0,
		"size_x": float(GRID_W) * HEX * sqrt(3.0),
		"size_y": float(GRID_H) * HEX * 1.5 + HEX,
		"wrap_period_x": 0.0,
		"wrap_edge_margin": 0.0,
		"grid_w": GRID_W,
		"grid_h": GRID_H,
		"offset_is_water": offw,
		"offset_cell_indices": offi,
		"settlement_core_buckets": PackedByteArray(),
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
		"color_r": col,
		"color_g": col,
		"color_b": col,
		"color_a": col,
		"spawn_domain": 0,
		"rotation_mode": 1,
		"spawn_radius_factor": layer._effective_spawn_radius_factor(),
		"world_noise_warp_strength": float(cfg.world_noise_warp_strength),
		"patch_frequency": float(cfg.patch_frequency),
		"patch_cutoff": float(cfg.patch_cutoff),
		"patch_contrast": float(cfg.patch_contrast),
		"world_noise_mid_mix": float(cfg.world_noise_mid_mix),
		"world_noise_fine_mix": float(cfg.world_noise_fine_mix),
		"micro_gap_threshold": float(cfg.micro_gap_threshold),
		"world_noise_acceptance": float(cfg.world_noise_acceptance),
		"vitality_dieback_noise_strength": 0.0,
		"min_size_factor": minf(cfg.min_size_factor, cfg.max_size_factor),
		"max_size_factor": maxf(cfg.min_size_factor, cfg.max_size_factor),
		"size_scale": layer._quality_size_scale(),
		"instance_cap": 100000,
	}
	knobs.merge(layer._form_knobs())
	return knobs


func _exclusion_ok(buf: PackedFloat32Array, cells: PackedInt32Array) -> bool:
	var n := int(buf.size() / 16)
	for i in range(n):
		for j in range(i + 1, n):
			if cells[i] != cells[j]:
				continue
			var ri := Vector2(buf[i * 16], buf[i * 16 + 4]).length() * ShrubLayerScript.IMPOSTOR_QUAD_HALF \
				* ShrubLayerScript.SUB_FORM_PATCH_RADIUS
			var rj := Vector2(buf[j * 16], buf[j * 16 + 4]).length() * ShrubLayerScript.IMPOSTOR_QUAD_HALF \
				* ShrubLayerScript.SUB_FORM_PATCH_RADIUS
			var limit := (ri + rj) * ShrubLayerScript.SUB_FORM_OVERLAP
			var d := Vector2(buf[i * 16 + 3], buf[i * 16 + 7]).distance_to(Vector2(buf[j * 16 + 3], buf[j * 16 + 7]))
			if d < limit - 1e-3:
				return false
	return true


# Replays the candidate gates of ShrubLayer._try_append_instance for an
# all-land, settlement-free grid and compares against the native buffer.
func _gd_parity(layer, knobs: Dictionary, buf: PackedFloat32Array) -> bool:
	var keys: PackedInt32Array = knobs.keys
	var cx: PackedFloat32Array = knobs.center_x
	var cy: PackedFloat32Array = knobs.center_y
	var suit: PackedFloat32Array = knobs.suitability
	var cfg: Resource = layer.profile
	var expected_pos := PackedVector2Array()
	var expected_size := PackedFloat32Array()
	var expected_pack := PackedFloat32Array()
	for c in range(keys.size()):
		var key := int(keys[c])
		for attempt in range(ATTEMPTS):
			var pos: Vector2 = layer._candidate_position(Vector2(cx[c], cy[c]), key, attempt)
			var wn: float = layer._world_noise_suitability(pos)
			if wn <= 0.001:
				continue
			var form: Vector3 = layer._candidate_form(key, attempt, wn, suit[c], 1.0)
			var gate := clampf(pow(clampf(wn, 0.0, 1.0), 1.35) * float(cfg.world_noise_acceptance), 0.0, 1.0)
			if layer._hash01(key, 9300 + attempt) > gate:
				continue
			if layer._sub_form_enabled() and layer._overlaps_cell_instance(c, pos, form.z):
				continue
			layer._instance_cell_indices.append(c)
			layer._instance_positions.append(pos)
			layer._instance_sizes.append(form.z)
			expected_pos.append(pos)
			expected_size.append(form.z)
			expected_pack.append(ShrubLayerScript.pack_form(int(form.x), int(form.y)))
	layer._instance_cell_indices = PackedInt32Array()
	layer._instance_positions = PackedVector2Array()
	layer._instance_sizes = PackedFloat32Array()
	var n := int(buf.size() / 16)
	if n != expected_pos.size():
		printerr("    parity count gd=%d native=%d" % [expected_pos.size(), n])
		return false
	for i in range(n):
		var pos := Vector2(buf[i * 16 + 3], buf[i * 16 + 7])
		var size := Vector2(buf[i * 16], buf[i * 16 + 4]).length()
		if pos.distance_to(expected_pos[i]) > 1e-3 or absf(size - expected_size[i]) > 1e-3 \
				or absf(buf[i * 16 + 15] - expected_pack[i]) > 1e-5:
			printerr("    parity mismatch at %d" % i)
			return false
	return true


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
