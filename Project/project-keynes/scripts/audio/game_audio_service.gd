extends Node
## Presentation-only FMOD boundary. Unsupported platforms retain the native audio path.

const EXTENSION := "res://addons/FmodGodot/FmodGodot.gdextension"
const BANK_ROOT := "res://assets/audio/banks/Desktop/"
const MUSIC_EVENT := "event:/Music/Prototype"
const CLICK_EVENT := "event:/UI/Click"
const UIFeedback := preload("res://scripts/ui/ui_audio_feedback.gd")
const UI_EVENTS := {
	&"click": "Click", &"page": "Page", &"open": "Open", &"close": "Close",
	&"confirm": "Confirm", &"toggle_on": "ToggleOn", &"toggle_off": "ToggleOff", &"tick": "Tick",
}
const UI_COOLDOWN_MS := {&"click": 45, &"page": 90, &"open": 120, &"close": 120,
	&"confirm": 100, &"toggle_on": 45, &"toggle_off": 45, &"tick": 65}
const MusicCatalog := preload("res://scripts/audio/music_event_catalog.gd")
## 前四个时代（石器/农耕/王国/帝国）到探索音乐档位的映射。
const ERA_MUSIC := [&"dark", &"feudal", &"castle", &"imperial"]
## 参数化探索事件：一个事件内用全局参数 Era 选档，12 段音频完全复用。
const PARAM_EXPLORE_EVENT := "event:/Music/Library/Explore_Param"

## 游戏事件音效（UI bank）。素材为 CC0，源文件在 Audio/Sources/UI/events/。
const EVENT_CUES := {
	&"tech_research": "event:/UI/Event/tech_research",
	&"territory_expand": "event:/UI/Event/territory_expand",
	&"ideology_draw": "event:/UI/Event/ideology_draw",
	&"ideology_use": "event:/UI/Event/ideology_use",
	&"building_complete": "event:/UI/Event/building_complete",
	&"population_grow": "event:/UI/Event/population_grow",
	&"trade": "event:/UI/Event/trade",
}

## 每个 cue 的最小间隔（毫秒）。高频事件必须稀疏，否则会糊成噪音墙：
## 贸易单次结算上限 32768 条信号，人口是 cell 级，逐个播没有意义。
const EVENT_COOLDOWN_MS := {
	&"tech_research": 0,
	&"territory_expand": 0,
	&"ideology_draw": 0,
	&"ideology_use": 0,
	&"building_complete": 150,
	&"population_grow": 2500,
	&"trade": 2500,
}
signal ui_sound_played(cue: StringName)

var status := "not_initialized"
var _system := 0
var _master := 0
var _music := 0
var _banks: Array[int] = []
var _ui_descriptions: Dictionary = {}
var _ui_next_ms: Dictionary = {}
var _music_key := &""
var _music_descriptions: Dictionary = {}
var _era_index := -1
var _music_parameterized := false
var _event_descriptions: Dictionary = {}
var _event_next_ms: Dictionary = {}

## 3D 空间化开关：事件在 Studio 里必须有 Spatialiser 才生效，
## 否则 set_3d_attributes 是空操作。默认关闭，不影响现有 2D 行为。
var _spatial_enabled := false


func _ready() -> void:
	if OS.get_name() != "Windows" or OS.get_environment("PK_FMOD_DISABLE") == "1":
		status = "platform_disabled"
		return
	if DisplayServer.get_name() == "headless" and OS.get_environment("PK_FMOD_TEST") != "1":
		status = "headless_disabled"
		return
	print_verbose("[audio] Loading Windows FMOD extension")
	var loaded := GDExtensionManager.load_extension(EXTENSION)
	print_verbose("[audio] Extension load status: ", loaded)
	if loaded not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
		status = "extension_load_failed"
		push_warning("[audio] FMOD extension load failed: %s" % loaded)
		return
	if not Engine.has_singleton("FmodAudioServer"):
		status = "server_missing"
		return
	_system = int(Engine.get_singleton("FmodAudioServer").call("get_studio"))
	for name in ["Master.strings", "Master", "Music", "UI"]:
		var bank := int(ClassDB.class_call_static("StudioSystem", "load_bank_file", _system,
			BANK_ROOT + name + ".bank", 0))
		if bank == 0:
			status = "bank_load_failed:" + name
			push_warning("[audio] " + status)
			_release_banks()
			return
		_banks.append(bank)
	_master = int(ClassDB.class_call_static("StudioSystem", "get_bus", _system, "bus:/"))
	status = "ready"
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null:
		settings.settings_changed.connect(apply_settings)
		apply_settings(settings.values())
	var feedback := UIFeedback.new()
	feedback.name = "UIFeedback"
	feedback.audio = self
	add_child(feedback)


func apply_settings(values: Dictionary) -> void:
	if status != "ready" or _master == 0:
		return
	ClassDB.class_call_static("StudioBus", "set_volume", _master,
		clampf(float(values.get("master_volume", 0.8)), 0.0, 1.0))
	ClassDB.class_call_static("StudioBus", "set_mute", _master, bool(values.get("master_muted", false)))


func play_prototype(tension: float = 0.0) -> bool:
	if status != "ready":
		return false
	if _music == 0:
		var description := int(ClassDB.class_call_static("StudioSystem", "get_event", _system, MUSIC_EVENT))
		_music = int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
		if _music == 0:
			return false
		if int(ClassDB.class_call_static("StudioEventInstance", "start", _music)) != 0:
			stop_music()
			return false
	_music_key = &"__prototype"
	return set_tension(tension)


func set_tension(value: float) -> bool:
	if _music == 0:
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name", _music,
		"Tension", clampf(value, 0.0, 1.0), false)) == 0


## 启用 3D 监听（相机位置驱动）。调用前请确认事件已在 Studio 里加了 Spatialiser，
## 可以用哪个事件试：print(ClassDB.class_call_static("StudioEventDescription", "is3D", desc))
func enable_spatial_listener() -> bool:
	if status != "ready":
		return false
	var r := int(ClassDB.class_call_static("StudioSystem", "set_num_listeners", _system, 1))
	_spatial_enabled = r == 0
	if _spatial_enabled:
		set_process(true)
		_update_listener()
	return _spatial_enabled


func spatial_enabled() -> bool:
	return _spatial_enabled


## 2D 地图坐标映射到 3D 平面（z=0）。相机朝向固定，因为地图是俯视 2D。
func _update_listener() -> void:
	if not _spatial_enabled or _system == 0:
		return
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	var pos := camera.global_position
	ClassDB.class_call_static("StudioSystem", "set_listener_attributes", _system, 0,
		Transform3D(Basis(), Vector3(pos.x, pos.y, 0.0)), Vector3.ZERO)


func _process(_delta: float) -> void:
	_update_listener()


## 播放一次游戏事件音效。按 cue 冷却，高频事件不会刷屏。
## 返回 false 表示被冷却挡下或事件不在 bank 里 —— 调用方不需要处理。
func play_event_cue(cue: StringName, world_pos: Vector2 = Vector2.INF) -> bool:
	if status != "ready" or not EVENT_CUES.has(cue):
		return false
	var now := Time.get_ticks_msec()
	if now < int(_event_next_ms.get(cue, 0)):
		return false
	var description := int(_event_descriptions.get(cue, 0))
	if description == 0:
		description = int(ClassDB.class_call_static("StudioSystem", "get_event", _system, EVENT_CUES[cue]))
		if description == 0:
			return false
		_event_descriptions[cue] = description
	var instance := int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if instance == 0:
		return false
	if _spatial_enabled and world_pos != Vector2.INF:
		ClassDB.class_call_static("StudioEventInstance", "set_3d_attributes", instance,
			Transform3D(Basis(), Vector3(world_pos.x, world_pos.y, 0.0)), Vector3.ZERO)
	var result := int(ClassDB.class_call_static("StudioEventInstance", "start", instance))
	ClassDB.class_call_static("StudioEventInstance", "release", instance)
	if result == 0:
		_event_next_ms[cue] = now + int(EVENT_COOLDOWN_MS.get(cue, 0))
	return result == 0


func play_ui_click() -> bool:
	return play_ui(&"click")


## Semantic one-shots share the FMOD Master bus with music and settings.
func play_ui(cue: StringName = &"click") -> bool:
	if status != "ready" or not UI_EVENTS.has(cue):
		return false
	var now := Time.get_ticks_msec()
	if now < int(_ui_next_ms.get(cue, 0)):
		return false
	var description := int(_ui_descriptions.get(cue, 0))
	if description == 0:
		description = int(ClassDB.class_call_static("StudioSystem", "get_event", _system,
			"event:/UI/" + String(UI_EVENTS[cue])))
		if description == 0:
			return false
		_ui_descriptions[cue] = description
	var instance := int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if instance == 0:
		return false
	var result := int(ClassDB.class_call_static("StudioEventInstance", "start", instance))
	ClassDB.class_call_static("StudioEventInstance", "release", instance)
	if result == 0:
		_ui_next_ms[cue] = now + int(UI_COOLDOWN_MS[cue])
		ui_sound_played.emit(cue)
	return result == 0


## 按 key 切换循环音乐。同一首重复调用不会重启。
func play_music(key: StringName) -> bool:
	if status != "ready":
		return false
	var event_path := MusicCatalog.path(key)
	if event_path.is_empty():
		return false
	if _music != 0 and _music_key == key:
		return true
	stop_music()
	var description := _music_description(event_path)
	if description == 0:
		return false
	_music = int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if _music == 0:
		return false
	if int(ClassDB.class_call_static("StudioEventInstance", "start", _music)) != 0:
		stop_music()
		return false
	_music_key = key
	return true


## 参数化探索音乐：单个事件 + 参数 Era 选档。
## 与 play_explore 的区别：只有一条事件路径，切换靠参数，音频在 bank 里完全复用。
func play_explore_parameterized(era_index: int) -> bool:
	if status != "ready":
		return false
	var clamped := clampi(era_index, 0, ERA_MUSIC.size() - 1)
	var description := _music_description(PARAM_EXPLORE_EVENT)
	if description == 0:
		return false
	if _music != 0 and _music_parameterized:
		return set_era_parameter(clamped)
	stop_music()
	_music = int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if _music == 0:
		return false
	_music_parameterized = true
	_music_key = &"__param_explore"
	var applied := set_era_parameter(clamped)
	if int(ClassDB.class_call_static("StudioEventInstance", "start", _music)) != 0:
		stop_music()
		return false
	return applied


## 设置参数化事件的 Era 档位（0=黑暗 1=封建 2=城堡 3=帝王）。
func set_era_parameter(era_index: int) -> bool:
	if _music == 0 or not _music_parameterized:
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "Era", float(clampi(era_index, 0, ERA_MUSIC.size() - 1)), false)) == 0


## 时代推进驱动音乐。只接前四个时代（石器/农耕/王国/帝国），
## 更靠后的时代沿用"帝国"这一档 —— 素材只有 AoE4 的四套探索曲。
func set_era(era_index: int) -> bool:
	if era_index < 0:
		return false
	var clamped := mini(era_index, ERA_MUSIC.size() - 1)
	if clamped == _era_index and _music != 0:
		return true
	var advancing := _era_index >= 0
	_era_index = clamped
	if advancing:
		var transition := _era_transition_key(clamped)
		if not transition.is_empty():
			play_transition(transition)
	return play_explore(ERA_MUSIC[clamped])


## 当前音乐对应的时代索引；未接入时为 -1。
func era_index() -> int:
	return _era_index


func _era_transition_key(era_index: int) -> StringName:
	match era_index:
		1: return &"trans_explore_feudal"
		2: return &"trans_explore_castle"
		3: return &"trans_explore_imperial"
	return &""


## 按时代播放探索音乐。pick_random 时在同代多段里随机挑一首。
func play_explore(era: StringName, pick_random: bool = true) -> bool:
	var tracks := MusicCatalog.tracks_for(era)
	if tracks.is_empty():
		return false
	var key: StringName = tracks[randi() % tracks.size()] if pick_random else tracks[0]
	return play_music(key)


## 时代升级过渡：单次播放，叠加在当前音乐上，不打断它。
func play_transition(key: StringName) -> bool:
	return _play_one_shot(MusicCatalog.transition_path(key))


## 胜利 stinger：单次播放，叠加在当前音乐上，不打断它。
func play_stinger(key: StringName) -> bool:
	return _play_one_shot(MusicCatalog.stinger_path(key))


func _play_one_shot(event_path: String) -> bool:
	if status != "ready" or event_path.is_empty():
		return false
	var description := _music_description(event_path)
	if description == 0:
		return false
	var instance := int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if instance == 0:
		return false
	var result := int(ClassDB.class_call_static("StudioEventInstance", "start", instance))
	ClassDB.class_call_static("StudioEventInstance", "release", instance)
	return result == 0


func _music_description(event_path: String) -> int:
	var cached := int(_music_descriptions.get(event_path, 0))
	if cached != 0:
		return cached
	var description := int(ClassDB.class_call_static("StudioSystem", "get_event", _system, event_path))
	if description != 0:
		_music_descriptions[event_path] = description
	return description


func stop_music() -> void:
	if _music != 0:
		ClassDB.class_call_static("StudioEventInstance", "stop", _music, 1)
		ClassDB.class_call_static("StudioEventInstance", "release", _music)
		_music = 0
	_music_parameterized = false


func diagnostics() -> Dictionary:
	if status != "ready":
		return {"status": status}
	ClassDB.class_call_static("StudioSystem", "flush_commands", _system)
	var ui_voices := 0
	for description in _ui_descriptions.values():
		ui_voices += int(ClassDB.class_call_static("StudioEventDescription", "get_instance_count", description))
	return {"status": status, "banks": _banks.size(), "music_playing": _music != 0,
		"ui_voices": ui_voices,
		"spatial": _spatial_enabled,
		"master_volume": ClassDB.class_call_static("StudioBus", "get_volume", _master),
		"master_muted": ClassDB.class_call_static("StudioBus", "get_mute", _master),
		"tension": ClassDB.class_call_static("StudioEventInstance", "get_parameter_by_name", _music, "Tension") if _music != 0 else 0.0,
		"timeline_ms": ClassDB.class_call_static("StudioEventInstance", "get_timeline_position", _music) if _music != 0 else 0}


func _release_banks() -> void:
	for index in range(_banks.size() - 1, -1, -1):
		ClassDB.class_call_static("StudioBank", "unload", _banks[index])
	_banks.clear()


func _exit_tree() -> void:
	stop_music()
	_release_banks()
