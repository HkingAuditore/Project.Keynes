extends SceneTree

const GraphicsQualitySettings := preload("res://scripts/game/graphics_quality_settings.gd")
const GraphicsOptionsScene := preload("res://scenes/ui/graphics_quality_options.tscn")

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
	_check_graphics_options(service)
	_check_map_frame_limit(service)
	_finish()


func _check_graphics_options(service: Node) -> void:
	var older_file := ConfigFile.new()
	older_file.set_value("settings", "render_quality", "medium")
	_expect("legacy fixture is written", older_file.save("user://settings.cfg") == OK)
	_expect("legacy settings load successfully", service.load_settings().get("ok", false))
	_expect("settings file from before individual controls still loads",
		service.values().render_quality == "medium" and not service.values().graphics_custom)
	var desktop := GraphicsQualitySettings.resolve({}, false)
	var mobile := GraphicsQualitySettings.resolve({}, true)
	_expect("desktop automatic uses full detail and follows the display",
		desktop.render_quality == "high" and desktop.map_render_scale == 100 \
		and desktop.fog_render_scale == 100 and desktop.cloud_shadow and desktop.frame_rate_limit == 0)
	_expect("mobile automatic defaults to 75% terrain and half-size fog",
		mobile.render_quality == "low" and mobile.map_render_scale == 75 \
		and mobile.fog_render_scale == 50 and not mobile.cloud_shadow and mobile.frame_rate_limit == GraphicsQualitySettings.ADAPTIVE_FPS)
	var legacy := GraphicsQualitySettings.resolve({"render_quality": "medium"}, true)
	_expect("an existing preset remains valid without new fields",
		legacy.render_quality == "medium" and legacy.water_detail == 1
		and legacy.map_render_scale == 75 and legacy.fog_render_scale == 50)
	var mobile_high := GraphicsQualitySettings.resolve({"render_quality": "high"}, true)
	_expect("mobile high detail uses the same default render sizes",
		mobile_high.water_detail == 2 and mobile_high.map_render_scale == 75 and mobile_high.fog_render_scale == 50)

	var options := GraphicsOptionsScene.instantiate()
	root.add_child(options)
	options.configure({"render_quality": "medium"}, true)
	var preset := options.get_node("RenderQuality") as OptionButton
	var water := options.get_node("WaterDetail") as OptionButton
	water.select(2)
	water.item_selected.emit(2)
	var draft: Dictionary = options.settings_payload()
	_expect("changing one field starts a custom profile from the displayed preset",
		preset.get_selected_metadata() == "custom" and draft.graphics_custom \
		and draft.render_quality == "medium" and draft.water_detail == 2 \
		and draft.fog_render_scale == legacy.fog_render_scale \
		and draft.vegetation_detail == legacy.vegetation_detail)
	preset.select(1)
	preset.item_selected.emit(1)
	_expect("selecting a preset again resets the individual values in the form",
		options.settings_payload() == {"render_quality": "low", "graphics_custom": false} \
		and water.get_selected_metadata() == 0)
	options.free()

	draft.frame_rate_limit = 30
	draft.map_render_scale = 85
	draft.fog_render_scale = 75
	draft.cloud_shadow = true
	_expect("custom settings and frame cap apply",
		bool(service.update(draft).get("ok", false)) and Engine.max_fps == 30)
	service._settings = service.DEFAULTS.duplicate(true)
	_expect("custom settings survive reload", bool(service.load_settings().get("ok", false)) \
		and GraphicsQualitySettings.resolve(service.values(), true).map_render_scale == 85
		and GraphicsQualitySettings.resolve(service.values(), true).fog_render_scale == 75 \
		and GraphicsQualitySettings.resolve(service.values(), true).water_detail == 2 \
		and GraphicsQualitySettings.resolve(service.values(), true).cloud_shadow)
	service.update({"map_render_scale": 82, "cloud_shadow": 7}, false)
	var fallbacks := GraphicsQualitySettings.resolve(service.values(), true)
	_expect("unsupported individual settings fall back to their base preset",
		fallbacks.map_render_scale == legacy.map_render_scale and not fallbacks.cloud_shadow \
		and fallbacks.water_detail == 2)
	service.update({"render_quality": "high"}, false)
	_expect("older preset callers can still leave custom mode", not service.values().graphics_custom)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	print("game settings service: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_map_frame_limit(service: Node) -> void:
	var camera := MapCamera.new()
	root.add_child(camera)
	service.update({"graphics_custom": true, "frame_rate_limit": GraphicsQualitySettings.ADAPTIVE_FPS}, false)
	service.follow_map_camera(camera)
	_expect("stationary map uses 30 fps", Engine.max_fps == 30)
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	service._input(touch)
	_expect("touch immediately requests 60 fps", Engine.max_fps == 60)
	touch.index = 1
	service._input(touch)
	touch.index = 0
	touch.pressed = false
	service._input(touch)
	_expect("second finger keeps interactive rate", Engine.max_fps == 60)
	touch.index = 1
	service._input(touch)
	_expect("reading after release returns to 30 fps", Engine.max_fps == 30)
	camera._pan_anim_active = true
	service._process(0.0)
	_expect("camera animation keeps 60 fps", Engine.max_fps == 60)
	camera._pan_anim_active = false
	for limit in [30, 60, 0]:
		service.update({"graphics_custom": true, "frame_rate_limit": limit}, false)
		_expect("fixed option %d ignores adaptive pacing" % limit,
			Engine.max_fps == limit and not service.is_processing_input())
	service.update({"graphics_custom": true, "frame_rate_limit": GraphicsQualitySettings.ADAPTIVE_FPS}, false)
	camera.free()
	_expect("leaving the map releases its idle cap", Engine.max_fps == 60 and not service.is_processing())
