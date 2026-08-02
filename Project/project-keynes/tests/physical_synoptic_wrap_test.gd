extends SceneTree

# Headless:
#   godot --headless --path . --script res://tests/physical_synoptic_wrap_test.gd

const CPP_PATH := "../../gdext/src/world_ext_physical.cpp"
const BAKER_PATH := "res://scripts/rendering/map_baker.gd"
const FALLBACK_PATH := "res://scripts/rendering/physical_circulation_solver.gd"

var _checks := 0
var _failures := 0


func _init() -> void:
	var cpp := FileAccess.get_file_as_string(CPP_PATH)
	var baker := FileAccess.get_file_as_string(BAKER_PATH)
	var fallback := FileAccess.get_file_as_string(FALLBACK_PATH)
	_expect(not cpp.is_empty(), "physical C++ source is readable")
	_expect(cpp.contains("physical_wrap01(double world_x"), "native passes share positive periodic longitude")
	_expect(cpp.contains("const double k1x = 1.0 + double(seed_bits & 1u);") \
		and cpp.contains("const double slp_syn_k1x = 1.0 + double(slp_seed_bits & 1u);"),
		"wind and SLP use integer zonal harmonics")
	_expect(not cpp.contains("std::sin(seed_a) * 0.80 + 0.35") \
		and not cpp.contains("0.90 + 0.40 * std::sin(slp_syn_sa)"),
		"non-periodic zonal wave numbers are absent")
	_expect(baker.count('"wrap_period_x":') >= 5 and baker.count('"wrap_origin_x":') >= 5,
		"daily, sliced, and oneshot physical paths pass the wrap contract")
	_expect(fallback.contains("static func _neighbor_for_dir") \
		and fallback.contains("posmod(off.x, map.width)"),
		"GDScript fallback resolves physical neighbors across the cylinder seam")

	for seed in [0, 1, 17, 90421, 2147483647]:
		for day in [0, 1, 6, 37, 365]:
			_check_periodic_formula(seed, day)

	print("physical_synoptic_wrap_test: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_periodic_formula(seed: int, day: int) -> void:
	var bits := seed & 0x7fffffff
	var k1 := 1 + (bits & 1)
	var k2 := 1 + ((bits >> 1) & 1)
	var phase_a := float(bits & 1023) * TAU / 1024.0 + float(day) * TAU / 6.0
	var phase_b := float((bits >> 10) & 1023) * TAU / 1024.0 - float(day) * TAU / 6.0 * 0.56
	var value_0 := sin(TAU * float(k1) * 0.0 + phase_a) + cos(TAU * float(k2) * 0.0 + phase_b)
	var value_1 := sin(TAU * float(k1) * 1.0 + phase_a) + cos(TAU * float(k2) * 1.0 + phase_b)
	var deriv_0 := TAU * float(k1) * cos(phase_a) - TAU * float(k2) * sin(phase_b)
	var deriv_1 := TAU * float(k1) * cos(TAU * float(k1) + phase_a) \
		- TAU * float(k2) * sin(TAU * float(k2) + phase_b)
	_expect(absf(value_0 - value_1) < 0.00001 and absf(deriv_0 - deriv_1) < 0.0001,
		"seed=%d day=%d seam value/derivative continuity" % [seed, day])


func _expect(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[FAIL] %s" % label)
