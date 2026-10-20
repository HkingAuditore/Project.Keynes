extends SceneTree

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native climate modes state test ===")
	_expect("DCWorldExt class exists", ClassDB.class_exists("DCWorldExt"))
	if not ClassDB.class_exists("DCWorldExt"):
		_finish()
		return
	var ext := DCWorldExt.new()
	for method_name in [
		"get_active_cyclone_snapshot",
		"get_climate_modes_report",
		"capture_climate_modes_state",
		"restore_climate_modes_state",
	]:
		_expect("%s is bound" % method_name, ext.has_method(method_name))

	var report: Dictionary = ext.get_climate_modes_report()
	_expect("empty runtime starts without active cyclones",
			int(report.get("cyclone_active_count", -1)) == 0)
	_expect("empty runtime starts without ENSO basin cache",
			int(report.get("enso_basin_count", -1)) == 0)

	var state: Dictionary = ext.capture_climate_modes_state()
	_expect("state has versioned schema",
			String(state.get("schema", "")) == "PKClimateModes" and int(state.get("version", 0)) == 1)
	var restored: Dictionary = ext.restore_climate_modes_state(state)
	_expect("empty state round-trips", bool(restored.get("ok", false)))
	var rejected: Dictionary = ext.restore_climate_modes_state({"schema": "bad", "version": 1})
	_expect("bad state is rejected", not bool(rejected.get("ok", true)))

	var desktop := load("res://data/world/earth_like.tres") as ClimateProfile
	var mobile := load("res://data/world/earth_like_mobile_complex.tres") as ClimateProfile
	_expect("desktop enables all three emergent modes", desktop != null
			and desktop.thermal_monsoon_enabled
			and desktop.native_tropical_cyclone_enabled
			and desktop.enso_basin_modes_enabled)
	_expect("mobile enables bounded all-three mode", mobile != null
			and mobile.thermal_monsoon_enabled
			and mobile.native_tropical_cyclone_enabled
			and mobile.enso_basin_modes_enabled
			and mobile.tropical_cyclone_capacity < desktop.tropical_cyclone_capacity)
	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)


func _finish() -> void:
	print("checks=%d failures=%d" % [_checks, _failures])
