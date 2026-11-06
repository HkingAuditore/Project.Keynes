extends SceneTree

const Geography = preload("res://scripts/game/save_modules/geography_state.gd")
var checks := 0
var failures := 0

func _init() -> void:
	var owner := Geography.new()
	for rc in [-1, 0, 7]:
		var calls := {"restore": 0, "rc": 999}
		var context := {
			"capture_environment": func(): return {"schema": "PKEnvironmentRuntime", "schema_version": 2},
			"weather_result": func(): return rc,
			"restore_environment": func(_state):
				calls.restore += 1
				return {"ok": true},
			"restore_weather_result": func(value): calls.rc = value,
		}
		var saved: Dictionary = owner._write_environment_provider(context)
		var state: Dictionary = saved.sections.environment
		_expect("weather publication gate saved exactly", state.native_daily_weather_rc == rc)
		var restored: Dictionary = owner._restore_environment_provider(saved.sections, context)
		_expect("weather gate restored after core success", restored.ok and calls.restore == 1 and calls.rc == rc)
		state.erase("adapter_version")
		var rejected: Dictionary = owner._restore_environment_provider(saved.sections, context)
		_expect("old adapter rejects before mutation", not rejected.ok and rejected.code == "environment_adapter_version_mismatch" and calls.restore == 1)
	print("environment continuation: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[FAIL] " + label)
