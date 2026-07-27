extends SceneTree

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var service := root.get_node_or_null("GameSettings")
	_expect("settings autoload is available", service != null)
	if service == null:
		_finish()
		return
	var updated: Dictionary = service.update({
		"window_mode": "windowed",
		"resolution_width": 1366,
		"resolution_height": 768,
		"vsync": false,
		"render_quality": "medium",
		"ui_scale_percent": 125,
		"master_volume": 0.35,
		"master_muted": true,
	}, true)
	_expect("settings persist", bool(updated.get("ok", false)) \
		and FileAccess.file_exists("user://settings.cfg"))
	var cfg := ConfigFile.new()
	_expect("settings file is readable", cfg.load("user://settings.cfg") == OK)
	_expect("all global settings are written", \
		String(cfg.get_value("settings", "window_mode", "")) == "windowed" \
		and int(cfg.get_value("settings", "resolution_width", 0)) == 1366 \
		and int(cfg.get_value("settings", "resolution_height", 0)) == 768 \
		and not bool(cfg.get_value("settings", "vsync", true)) \
		and String(cfg.get_value("settings", "render_quality", "")) == "medium" \
		and int(cfg.get_value("settings", "ui_scale_percent", 0)) == 125 \
		and is_equal_approx(float(cfg.get_value("settings", "master_volume", 0.0)), 0.35) \
		and bool(cfg.get_value("settings", "master_muted", false)))

	service._settings = service.DEFAULTS.duplicate(true)
	_expect("saved settings reload", bool(service.load_settings().get("ok", false)) \
		and service.values().window_mode == "windowed" \
		and service.values().render_quality == "medium" \
		and int(service.values().ui_scale_percent) == 125)
	service.update({
		"window_mode": "invalid",
		"resolution_width": 100,
		"resolution_height": 10000,
		"render_quality": "ultra",
		"ui_scale_percent": 90,
		"master_volume": 4.0,
	}, false)
	var validated: Dictionary = service.values()
	_expect("invalid enums fall back", validated.window_mode == "borderless" \
		and validated.render_quality == "auto" and int(validated.ui_scale_percent) == 100)
	_expect("numeric settings clamp", int(validated.resolution_width) == 800 \
		and int(validated.resolution_height) == 4320 \
		and is_equal_approx(float(validated.master_volume), 1.0))
	_finish()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	print("game settings service: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
