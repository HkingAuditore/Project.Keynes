extends Node

signal settings_changed(settings: Dictionary)
signal event_pause_changed(mask: int)
signal ai_narrative_changed(enabled: bool)

## 移动端 UI 缩放策略的唯一入口（content_scale_mode/aspect/factor + 安全区）。
## 用 preload 而不是 class_name：新脚本还没进 global_script_class_cache 时裸类名会编译失败。
const MobileUIScalingScript := preload("res://scripts/ui/mobile_ui_scaling.gd")
const GraphicsQualitySettings := preload("res://scripts/game/graphics_quality_settings.gd")
const SETTINGS_PATH := "user://settings.cfg"
const DEFAULTS := {
	"window_mode": "borderless",
	"resolution_width": 1600,
	"resolution_height": 960,
	"vsync": true,
	"render_quality": "auto",
	"graphics_custom": false,
	"map_render_scale": null,
	"water_detail": null,
	"fog_render_scale": null,
	"vegetation_detail": null,
	"weather_detail": null,
	"cloud_shadow": null,
	"frame_rate_limit": null,
	"ui_scale_percent": 100,
	## 触摸档的界面布局：fill（默认，EXPAND 宽屏黄金画布 ~1600×720）/ fit（KEEP 1600×960）/ dense（EXPAND 高密度）。
	## 桌面档忽略。见 scripts/ui/mobile_ui_scaling.gd:LAYOUT_MODES。
	"ui_layout_mode": "fill",
	## 布局配置迁移版本：2 起将旧版默认 "fit" 升级为移动端推荐 "fill"，避免老设备沿用旧缓存。
	"ui_layout_version": 2,
	## 触摸档在布局之上的再缩放（%）。50~200 六档。
	## >100 会把逻辑画布压到 1600×960 以下（200% ⇒ 800×480），`is_short_viewport()` 变 true，
	## 各工作台自动切 compact 版式（收摘要卡/科技侧栏）—— 这是放大档的既定代价，不是 bug。
	"ui_layout_scale": 100,
	"reduce_motion": false,
	"master_volume": 0.8,
	"master_muted": false,
	"autosave_enabled": true,
	"ai_narrative_enabled": false,
	"event_pause_mask": 255,
	"ai_llm_base_url": "https://api.deepseek.com/v1/chat/completions",
	"ai_llm_model": "deepseek-chat",
	"ai_image_enabled": false,
	"ai_image_base_url": "https://api.openai.com/v1/images/generations",
	"ai_image_model": "dall-e-3",
}

var _settings: Dictionary = DEFAULTS.duplicate(true)
var _ui_scaling: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	set_process_input(false)
	_ui_scaling = MobileUIScalingScript.new()
	_ui_scaling.name = "MobileUIScaling"
	add_child(_ui_scaling)
	if coast_pan_requested():
		# Start windowed before the OS begins an asynchronous fullscreen transition.
		_settings.window_mode = "windowed"
		_settings.resolution_width = 1600
		_settings.resolution_height = 960
	else:
		load_settings()
	apply()


func coast_pan_requested() -> bool:
	return "--coast-pan" in OS.get_cmdline_user_args() or OS.has_feature("coast_pan")


## 移动端缩放策略节点（安全区 / 总缩放 / dp 换算都问它）。
func ui_scaling() -> Node:
	return _ui_scaling


func values() -> Dictionary:
	return _settings.duplicate(true)


func update(values_to_apply: Dictionary, persist: bool = true) -> Dictionary:
	if values_to_apply.has("render_quality") and not values_to_apply.has("graphics_custom"):
		_settings.graphics_custom = false
	for key in DEFAULTS:
		if values_to_apply.has(key):
			_settings[key] = values_to_apply[key]
	_validate()
	apply()
	if persist:
		var saved := save_settings()
		if not bool(saved.get("ok", false)):
			return saved
	settings_changed.emit(values())
	if values_to_apply.has("event_pause_mask"):
		event_pause_changed.emit(int(_settings.event_pause_mask))
	if values_to_apply.has("ai_narrative_enabled"):
		ai_narrative_changed.emit(bool(_settings.ai_narrative_enabled))
	return {"ok": true, "code": "ok", "message": ""}


## 世界设置页使用 0/1/2 的画质档；正式游戏统一读取 render_quality 字符串。
## 在进入场景前转换并持久化，避免两套画质配置长期分叉。
func apply_render_quality_mode(mode: int, persist: bool = true) -> Dictionary:
	var quality := "auto"
	match mode:
		0:
			quality = "low"
		1:
			quality = "medium"
		2:
			quality = "high"
	return update({"render_quality": quality}, persist)


func load_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	var error := cfg.load(SETTINGS_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		return {"ok": false, "code": "settings_read_failed", "message": "无法读取设置文件。"}
	if error == OK:
		for key in DEFAULTS:
			_settings[key] = cfg.get_value("settings", key) if cfg.has_section_key("settings", key) \
				else DEFAULTS[key]
		if int(cfg.get_value("settings", "ui_layout_version", 1)) < int(DEFAULTS.ui_layout_version):
			if String(_settings.get("ui_layout_mode", "fit")) == "fit":
				_settings.ui_layout_mode = "fill"
			_settings.ui_layout_version = int(DEFAULTS.ui_layout_version)
	_validate()
	return {"ok": true, "code": "ok", "message": ""}


func save_settings() -> Dictionary:
	# The benchmark starts with its own profile and must never replace player preferences.
	if coast_pan_requested():
		return {"ok": true, "code": "coast_pan_ephemeral", "message": ""}
	var cfg := ConfigFile.new()
	for key in _settings:
		cfg.set_value("settings", key, _settings[key])
	var error := cfg.save(SETTINGS_PATH)
	return {"ok": error == OK, "code": "ok" if error == OK else "settings_write_failed",
		"message": "" if error == OK else "无法保存设置。"}


var _frame_limit := 0
var _map_camera: MapCamera
var _map_clock: WorldClock
var _held_inputs: Dictionary = {}
var _gesture_event := false
var _last_view: Transform2D


func follow_map_camera(camera: MapCamera, clock: WorldClock = null) -> void:
	if is_instance_valid(_map_camera):
		_release_map_camera()
	_map_camera = camera
	_map_clock = clock
	camera.tree_exiting.connect(_release_map_camera)
	_configure_frame_limit()


func _release_map_camera() -> void:
	_map_camera.tree_exiting.disconnect(_release_map_camera)
	_map_camera = null
	_map_clock = null
	_configure_frame_limit()


func _configure_frame_limit() -> void:
	var adaptive := _frame_limit == GraphicsQualitySettings.ADAPTIVE_FPS
	var watch := adaptive and _map_camera != null
	set_process(watch)
	set_process_input(watch)
	if watch:
		_last_view = _map_camera.get_canvas_transform()
		_update_navigation_limit(false)
	else:
		_held_inputs.clear()
		_gesture_event = false
		Engine.max_fps = 60 if adaptive else _frame_limit


func _input(event: InputEvent) -> void:
	# Observe presses and releases before GUI consumption, including dragging a panel.
	if event is InputEventScreenTouch:
		_track_press(event.index, event.pressed and not event.canceled)
	elif event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_track_press(-int(event.button_index), event.pressed and not event.canceled)
		else:
			_gesture_event = event.pressed
	elif event is InputEventGesture or event is InputEventScreenDrag:
		_gesture_event = true
	elif event is InputEventKey and event.pressed and (event.is_action("player_zoom_in") or event.is_action("player_zoom_out")):
		_gesture_event = true
	else:
		return
	_update_navigation_limit(false)


func _track_press(id: int, pressed: bool) -> void:
	if pressed:
		_held_inputs[id] = true
	else:
		_held_inputs.erase(id)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_held_inputs.clear()
		_gesture_event = false


func _process(_delta: float) -> void:
	var view := _map_camera.get_canvas_transform()
	_update_navigation_limit(view != _last_view)
	_last_view = view
	_gesture_event = false


func _update_navigation_limit(moved: bool) -> void:
	var simulation_running := _map_clock != null and not _map_clock.paused \
		and _map_clock.speed_multiplier > 0.0
	var active := simulation_running or moved or _gesture_event or not _held_inputs.is_empty() \
		or _map_camera.is_animating_view()
	var limit := 60 if active else 30
	if Engine.max_fps != limit:
		Engine.max_fps = limit


func apply() -> void:
	var graphics := GraphicsQualitySettings.resolve(
		_settings, OS.has_feature("mobile") or DCFeatureFlags.is_mobile_web())
	_frame_limit = int(graphics.frame_rate_limit)
	_configure_frame_limit()
	# Web 没有原生窗口概念："fullscreen"在浏览器里必须由用户输入手势触发，
	# 否则 requestFullscreen() 会被静默拒绝（见 DisplayServerWeb::window_set_mode
	# 的报错提示）；WINDOW_FLAG_BORDERLESS / window_set_size 在 Web 平台也均为
	# no-op。这些调用在 Web 上不会生效，干脆跳过，交给浏览器自身的画布自适应
	# (canvasResizePolicy=adaptive) 去决定实际尺寸，避免和它产生不必要的冲突。
	#
	# 移动端同理：安卓/iOS 的窗口模式与像素尺寸由系统窗口管理器决定，
	# window_set_mode(FULLSCREEN)/window_set_size(1600,960)/vsync 在安卓上要么是
	# no-op，要么会在全屏与任务栏之间来回切（真机表现为黑边/闪一下）。显示相关的
	# 唯一有效旋钮是 content scale，交给 MobileUIScaling 统一处理。
	if not OS.has_feature("web") and not OS.has_feature("mobile"):
		var mode := String(_settings.window_mode)
		match mode:
			"fullscreen":
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			"windowed":
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				DisplayServer.window_set_size(Vector2i(_settings.resolution_width, _settings.resolution_height))
			_:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
				DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if _settings.vsync else DisplayServer.VSYNC_DISABLED)
	# 用户 UI 缩放（80/100/125/150%）不再直接写 content_scale_factor：
	# 移动端必须再乘上「设计像素 → dp」的设备倍率，否则 100% 在安卓上等于不缩放。
	if _ui_scaling != null:
		_ui_scaling.call("configure", int(_settings.ui_scale_percent),
			String(_settings.get("ui_layout_mode", "fill")),
			int(_settings.get("ui_layout_scale", 100)))
	else:
		get_tree().root.content_scale_factor = float(_settings.ui_scale_percent) / 100.0
	var bus := AudioServer.get_bus_index("Master")
	if bus >= 0:
		AudioServer.set_bus_mute(bus, bool(_settings.master_muted))
		var linear := clampf(float(_settings.master_volume), 0.0, 1.0)
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(linear, 0.0001)))


func _validate() -> void:
	if String(_settings.window_mode) not in ["windowed", "borderless", "fullscreen"]:
		_settings.window_mode = DEFAULTS.window_mode
	_settings.resolution_width = clampi(int(_settings.resolution_width), 800, 7680)
	_settings.resolution_height = clampi(int(_settings.resolution_height), 600, 4320)
	if str(_settings.render_quality) not in GraphicsQualitySettings.PRESET_IDS:
		_settings.render_quality = "auto"
	var custom = _settings.graphics_custom
	_settings.graphics_custom = custom is bool and custom
	for key in GraphicsQualitySettings.OPTION_VALUES:
		if not GraphicsQualitySettings.is_supported_value(key, _settings[key]):
			_settings[key] = null
	if int(_settings.ui_scale_percent) not in [80, 100, 125, 150]:
		_settings.ui_scale_percent = 100
	if String(_settings.get("ui_layout_mode", "fill")) not in ["fit", "fill", "dense"]:
		_settings.ui_layout_mode = "fill"
	if int(_settings.get("ui_layout_scale", 100)) not in [50, 75, 100, 125, 150, 200]:
		_settings.ui_layout_scale = 100
	_settings.master_volume = clampf(float(_settings.master_volume), 0.0, 1.0)
	_settings.autosave_enabled = bool(_settings.autosave_enabled)
	_settings.reduce_motion = bool(_settings.reduce_motion)
	_settings.event_pause_mask = clampi(int(_settings.event_pause_mask), 0, 65535)
	_settings.ai_narrative_enabled = bool(_settings.get("ai_narrative_enabled", DEFAULTS.ai_narrative_enabled))
	var llm_url := String(_settings.get("ai_llm_base_url", DEFAULTS.ai_llm_base_url)).strip_edges()
	_settings.ai_llm_base_url = llm_url if not llm_url.is_empty() else String(DEFAULTS.ai_llm_base_url)
	var llm_model := String(_settings.get("ai_llm_model", DEFAULTS.ai_llm_model)).strip_edges()
	_settings.ai_llm_model = llm_model if not llm_model.is_empty() else String(DEFAULTS.ai_llm_model)
	_settings.ai_image_enabled = bool(_settings.get("ai_image_enabled", DEFAULTS.ai_image_enabled))
	var img_url := String(_settings.get("ai_image_base_url", DEFAULTS.ai_image_base_url)).strip_edges()
	_settings.ai_image_base_url = img_url if not img_url.is_empty() else String(DEFAULTS.ai_image_base_url)
	var img_model := String(_settings.get("ai_image_model", DEFAULTS.ai_image_model)).strip_edges()
	_settings.ai_image_model = img_model if not img_model.is_empty() else String(DEFAULTS.ai_image_model)
