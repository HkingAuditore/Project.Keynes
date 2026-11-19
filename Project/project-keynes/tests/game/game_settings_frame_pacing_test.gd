extends SceneTree

const GameSettingsService := preload("res://scripts/game/game_settings_service.gd")
const GraphicsQualitySettings := preload("res://scripts/game/graphics_quality_settings.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var service := GameSettingsService.new()
	root.add_child(service)
	service._frame_limit = GraphicsQualitySettings.ADAPTIVE_FPS
	var camera := MapCamera.new()
	var clock := WorldClock.new()
	root.add_child(camera)
	root.add_child(clock)
	clock.pause(false)
	service.follow_map_camera(camera, clock)
	assert(Engine.max_fps == 60, "running simulation must keep 60 fps on a still map")
	clock.pause(true)
	service._process(0.0)
	assert(Engine.max_fps == 30, "paused still map may use the idle 30 fps cap")
	clock.pause(false)
	service._process(0.0)
	assert(Engine.max_fps == 60, "resuming simulation restores 60 fps")
	camera.free()
	clock.free()
	service.free()
	print("game settings frame pacing: PASS")
	quit(0)
