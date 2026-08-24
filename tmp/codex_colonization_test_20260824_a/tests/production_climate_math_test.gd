extends SceneTree

var failures := 0


func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		printerr("[FAIL] DCWorldExt unavailable")
		quit(1)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var probe: Dictionary = ext.run_economy_production_climate_math_probe({
		"temperature_q16": PackedInt32Array([32768, 49152, 65536, 49152,
			40960, 1, 0]),
		"temperature_opt_q16": PackedInt32Array([32768, 32768, 32768, 32768,
			32768, 0, 65536]),
		"temperature_tolerance_q16": PackedInt32Array([16384, 16384, 16384,
			16384, 16384, 3, 1]),
		"water_q16": PackedInt32Array([32768, 32768, 32768, 32768, 32768, 0, 0]),
		"water_opt_q16": PackedInt32Array([32768, 32768, 32768, 32768, 32768, 0,
			65536]),
		"water_tolerance_q16": PackedInt32Array([16384, 16384, 16384, 16384,
			16384, 3, 1]),
		"exposure_q16": PackedInt32Array([65536, 65536, 65536, 32768, 65536,
			65536, 65536]),
		"floor_q16": PackedInt32Array([13107, 13107, 13107, 13107, 13107, 0, 0]),
		"enabled": PackedInt32Array([1, 1, 1, 1, 1, 1, 0]),
	})
	_expect("climate fixed-point probe succeeds", bool(probe.get("ok", false)))
	if not bool(probe.get("ok", false)):
		print("  probe=", probe)
		quit(1)
		return
	var temp_fit: PackedInt64Array = probe.get(
		"temperature_fit_q16", PackedInt64Array())
	var water_fit: PackedInt64Array = probe.get("water_fit_q16", PackedInt64Array())
	var capacity: PackedInt64Array = probe.get("capacity_q16", PackedInt64Array())
	_expect("optimum is full fit and capacity",
		temp_fit[0] == 65536 and water_fit[0] == 65536 and capacity[0] == 65536)
	_expect("tolerance boundary reaches floor", temp_fit[1] == 0 and capacity[1] == 13107)
	_expect("outside tolerance saturates at floor", temp_fit[2] == 0 and capacity[2] == 13107)
	_expect("partial exposure interpolates toward one", capacity[3] == 39322)
	_expect("half fit preserves half capacity", temp_fit[4] == 32768 and capacity[4] == 32768)
	_expect("Q16 interpolation truncates deterministically",
		temp_fit[5] == 43691 and capacity[5] == 43691)
	_expect("missing profile is identity",
		temp_fit[6] == 65536 and water_fit[6] == 65536 and capacity[6] == 65536)
	_expect("golden vectors do not saturate", int(probe.get("saturation_count", -1)) == 0)
	var invalid: Dictionary = ext.run_economy_production_climate_math_probe({
		"temperature_q16": PackedInt32Array([0]),
		"temperature_opt_q16": PackedInt32Array([0]),
		"temperature_tolerance_q16": PackedInt32Array([0]),
		"water_q16": PackedInt32Array([0]),
		"water_opt_q16": PackedInt32Array([0]),
		"water_tolerance_q16": PackedInt32Array([1]),
		"exposure_q16": PackedInt32Array([65536]),
		"floor_q16": PackedInt32Array([0]),
	})
	_expect("zero tolerance is rejected", not bool(invalid.get("ok", true)) and
		String(invalid.get("reason", "")) == "production_climate_math_vector_invalid")
	print("=== production climate math %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
