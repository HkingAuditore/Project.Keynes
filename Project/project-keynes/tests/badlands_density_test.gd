extends SceneTree

# Headless:
#   godot --headless --script tests/badlands_density_test.gd --quit

const TERRAIN_BADLANDS := 25
const MAX_LAND_RATIO := 0.04
const MAX_ARID_RATIO := 0.25
const MAX_PATCH_CELLS := 48

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("[badlands-density] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[badlands-density] SKIP DCWorldExt missing")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("DCWorldExt instantiated", ext != null)
	if ext == null:
		return

	for seed in [20260728, 717171, 10086]:
		var post := _generate(ext, seed, MAX_LAND_RATIO, MAX_ARID_RATIO)
		_validate_report("seed=%d" % seed, post)

	var disabled := _generate(ext, 20260728, 0.0, 0.0)
	_expect("zero budget disables badlands", int(disabled.get("badlands_selected_count", -1)) == 0)


func _generate(ext: Object, seed: int, land_ratio: float, arid_ratio: float) -> Dictionary:
	var cfg := {
		"width": 80,
		"height": 80,
		"num_continents": 3,
		"sea_level": 0.42,
		"continent_size": 0.9,
	}
	var profile := {
		"native_generation_mode": 2,
		"badlands_min_relief": 0.06,
		"badlands_min_rugged_neighbors": 2,
		"badlands_max_land_ratio": land_ratio,
		"badlands_max_arid_ratio": arid_ratio,
		"badlands_max_patch_cells": MAX_PATCH_CELLS,
	}
	var base: Dictionary = ext.call("run_native_world_generate_base_pass", seed, cfg, profile)
	_expect("base succeeds seed=%d" % seed, int(base.get("rc", -1)) == 0)
	if int(base.get("rc", -1)) != 0:
		return {}
	return ext.call("run_native_world_generate_post_base_pass", seed, cfg, profile, base)


func _validate_report(label: String, post: Dictionary) -> void:
	_expect("%s post succeeds" % label, int(post.get("rc", -1)) == 0)
	if int(post.get("rc", -1)) != 0:
		return
	var terrain: PackedByteArray = post.get("terrain_arr", PackedByteArray())
	var landform: PackedByteArray = post.get("landform_arr", PackedByteArray())
	var land_count := int(post.get("land_count", 0))
	var arid_count := int(post.get("badlands_arid_source_count", 0))
	var selected := int(post.get("badlands_selected_count", -1))
	var candidates := int(post.get("badlands_candidate_count", -1))
	var budget := int(post.get("badlands_budget", -1))
	var rejected := int(post.get("badlands_budget_rejected", -1))
	var largest := int(post.get("badlands_largest_component", -1))
	print("[badlands-density] %s land=%d candidates=%d selected=%d budget=%d largest=%d" % [
		label, land_count, candidates, selected, budget, largest])

	var actual := 0
	var all_landforms_are_land := true
	for i in range(terrain.size()):
		if terrain[i] != TERRAIN_BADLANDS:
			continue
		actual += 1
		# BADLANDS normally derives landform 10, but later structural overrides such
		# as RIFT_VALLEY may legitimately replace that axis.
		if i >= landform.size() or landform[i] <= 3:
			all_landforms_are_land = false
	_expect("%s report matches terrain" % label, actual == selected)
	_expect("%s badlands remain land" % label, all_landforms_are_land)
	_expect("%s produces candidates" % label, candidates > 0)
	_expect("%s candidates cover selection" % label, candidates >= selected)
	_expect("%s rejected accounting" % label, rejected == candidates - selected)
	_expect("%s selection respects computed budget" % label, selected <= budget)
	_expect("%s selection respects land cap" % label,
		selected <= int(floor(float(land_count) * MAX_LAND_RATIO)))
	_expect("%s selection respects arid cap" % label,
		selected <= int(floor(float(arid_count) * MAX_ARID_RATIO)))
	_expect("%s largest patch capped" % label, largest <= MAX_PATCH_CELLS)
	var stages: Dictionary = post.get("stage_counts", {})
	_expect("%s stage count matches" % label, int(stages.get("badlands", -1)) == selected)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	push_error("[badlands-density] FAIL: %s" % label)
