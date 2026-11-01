extends Node

signal settings_changed(settings: Dictionary)

## 移动端 UI 缩放策略的唯一入口（content_scale_mode/aspect/factor + 安全区）。
## 用 preload 而不是 class_name：新脚本还没进 global_script_class_cache 时裸类名会编译失败。
const MobileUIScalingScript := preload("res://scripts/ui/mobile_ui_scaling.gd")
const SETTINGS_PATH := "user://settings.cfg"
const DEFAULTS := {
	"window_mode": "borderless",
	"resolution_width": 1600,
	"resolution_height": 960,
	"vsync": true,
	"render_quality": "auto",
	"ui_scale_percent": 100,
	"reduce_motion": false,
	"master_volume": 0.8,
	"master_muted": false,
	"autosave_enabled": true,
}

var _settings: Dictionary = DEFAULTS.duplicate(true)
var _ui_scaling: Node = null


func _ready() -> void:
	_ui_scaling = MobileUIScalingScript.new()
	_ui_scaling.name = "MobileUIScaling"
	add_child(_ui_scaling)
	load_settings()
	apply()


## 移动端缩放策略节点（安全区 / 总缩放 / dp 换算都问它）。
func ui_scaling() -> Node:
	return _ui_scaling


func values() -> Dictionary:
	return _settings.duplicate(true)


func update(values_to_apply: Dictionary, persist: bool = true) -> Dictionary:
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
	return {"ok": true, "code": "ok", "message": ""}


func load_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	var error := cfg.load(SETTINGS_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		return {"ok": false, "code": "settings_read_failed", "message": "无法读取设置文件。"}
	if error == OK:
		for key in DEFAULTS:
			_settings[key] = cfg.get_value("settings", key, DEFAULTS[key])
	_validate()
	return {"ok": true, "code": "ok", "message": ""}


func save_settings() -> Dictionary:
	var cfg := ConfigFile.new()
	for key in _settings:
		cfg.set_value("settings", key, _settings[key])
	var error := cfg.save(SETTINGS_PATH)
	return {"ok": error == OK, "code": "ok" if error == OK else "settings_write_failed",
		"message": "" if error == OK else "无法保存设置。"}


func apply() -> void:
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
		_ui_scaling.call("configure", int(_settings.ui_scale_percent))
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
	if String(_settings.render_quality) not in ["auto", "low", "medium", "high"]:
		_settings.render_quality = "auto"
	if int(_settings.ui_scale_percent) not in [80, 100, 125, 150]:
		_settings.ui_scale_percent = 100
	_settings.master_volume = clampf(float(_settings.master_volume), 0.0, 1.0)
	_settings.autosave_enabled = bool(_settings.autosave_enabled)
	_settings.reduce_motion = bool(_settings.reduce_motion)
