extends SceneTree

# 物种保底阶梯的纯逻辑回归：用假的 run_seed 回调验证“只放宽失败物种、逐级加深、
# 不污染原 knobs、阶梯用尽时报告 unplaceable”。真实地图上的断言在
# tests/world/bio_coverage_guarantee_test.gd。
# Headless:
#   godot --headless --path . --script res://tests/world/bio_guarantee_ladder_test.gd

const Guarantee = preload("res://scripts/geography/map_generation/bio_occupancy_guarantee.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_ladder_fixes_species_at_first_level()
	_test_ladder_reports_unplaceable()
	_test_disabled_when_every_species_lands()
	print("=== bio guarantee ladder: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_ladder_fixes_species_at_first_level() -> void:
	var knobs := _knobs()
	var calls: Array = []
	var seed_pass := func(call_knobs: Dictionary) -> Dictionary:
		calls.append(call_knobs)
		var veg: PackedInt32Array = call_knobs["species_veg_mask0"]
		var relaxed_species := int(veg[1]) == 0
		var occupied := PackedInt32Array([2, 1 if relaxed_species else 0, 1])
		return {"ok": true, "occupied_cell_counts": occupied, "occupancy_bits": PackedInt32Array()}
	var first: Dictionary = seed_pass.call(knobs)
	var result: Dictionary = Guarantee.run(knobs, first, seed_pass)
	_expect("one relaxation round", int(result.get("attempts", 0)) == 2)
	_expect("only the failing species is relaxed",
		result.get("relaxed_levels", PackedInt32Array()) == PackedInt32Array([-1, 0, -1]))
	_expect("source knobs keep the catalog vegetation mask",
		int((knobs["species_veg_mask0"] as PackedInt32Array)[1]) != 0)
	_expect("relaxed request clears that species mask",
		int((calls[1]["species_veg_mask0"] as PackedInt32Array)[1]) == 0)
	_expect("relaxed request keeps the other species mask",
		int((calls[1]["species_veg_mask0"] as PackedInt32Array)[0]) != 0)
	_expect("relaxed request shrinks the relict patch",
		float((calls[1]["species_fill_keep"] as PackedFloat32Array)[1]) <= Guarantee.FILL_KEEP)
	_expect("unplaceable list empty", (result.get("unplaceable", PackedStringArray()) as PackedStringArray).is_empty())
	_expect("final seed result is the relaxed one",
		int((result["seed_res"]["occupied_cell_counts"] as PackedInt32Array)[1]) == 1)


func _test_ladder_reports_unplaceable() -> void:
	var knobs := _knobs()
	var calls: Array = []
	var seed_pass := func(call_knobs: Dictionary) -> Dictionary:
		calls.append(call_knobs)
		var occupied := PackedInt32Array([1, 0, 1])
		return {"ok": true, "occupied_cell_counts": occupied, "occupancy_bits": PackedInt32Array()}
	var first: Dictionary = seed_pass.call(knobs)
	var result: Dictionary = Guarantee.run(knobs, first, seed_pass)
	_expect("every ladder level is tried", int(result.get("attempts", 0)) == 1 + Guarantee.LEVELS.size())
	_expect("unplaceable species is reported",
		(result.get("unplaceable", PackedStringArray()) as PackedStringArray).size() == 1)
	_expect("unplaceable species encodes -2",
		int((result.get("relaxed_levels", PackedInt32Array()))[1]) == -2)


func _test_disabled_when_every_species_lands() -> void:
	var knobs := _knobs()
	var calls: Array = []
	var seed_pass := func(call_knobs: Dictionary) -> Dictionary:
		calls.append(call_knobs)
		return {"ok": true, "occupied_cell_counts": PackedInt32Array([1, 2, 3]),
			"occupancy_bits": PackedInt32Array()}
	var first: Dictionary = seed_pass.call(knobs)
	var result: Dictionary = Guarantee.run(knobs, first, seed_pass)
	_expect("no extra seed request when everyone landed", calls.size() == 1)
	_expect("no species marked relaxed",
		result.get("relaxed_levels", PackedInt32Array()) == PackedInt32Array([-1, -1, -1]))


func _knobs() -> Dictionary:
	return {
		"species_signal_ids": PackedInt32Array([0, 1, 2]),
		"species_veg_mask0": PackedInt32Array([0b1010, 0b0110, 0b1100]),
		"species_veg_mask1": PackedInt32Array([0, 0, 0]),
		"species_flags": PackedInt32Array([1, 2, 0]),
		"species_carrier_index": PackedInt32Array([0, 1, -1]),
		"species_carrier_alt_index": PackedInt32Array([-1, -1, -1]),
		"species_temp_lo": PackedFloat32Array([0.2, 0.4, 0.1]),
		"species_temp_hi": PackedFloat32Array([0.7, 0.9, 0.6]),
		"species_moist_lo": PackedFloat32Array([0.2, 0.3, 0.2]),
		"species_moist_hi": PackedFloat32Array([0.8, 0.95, 0.8]),
		"species_elev_lo": PackedFloat32Array([0.0, 0.1, 0.0]),
		"species_elev_hi": PackedFloat32Array([0.8, 0.9, 0.8]),
		"species_fill_keep": PackedFloat32Array([0.55, 0.58, 0.80]),
		"species_max_cost": PackedInt32Array([16, 14, 10]),
	}


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
