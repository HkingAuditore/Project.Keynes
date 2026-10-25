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
## 石器时代交互式配乐组曲（含 Intro + 三段常态循环 + Population 人口变体 + CameraZoom 镜头变体）。
const STONE_AGE_SUITE_EVENT := "event:/Music/StoneAge/Suite"
const STONE_AGE_INTRO_MS := 0
const STONE_AGE_SECTION_MS := {
	0: 18000,
	1: 18000,
	2: 72000,
	3: 126000,
}
## 农耕时代交互式配乐组曲（含 Intro + 三段常态循环 + Population 人口变体 + CameraZoom 镜头变体）。
const AGRARIAN_AGE_SUITE_EVENT := "event:/Music/AgrarianAge/Suite"
const AGRARIAN_AGE_INTRO_MS := 0
const AGRARIAN_AGE_SECTION_MS := {
	0: 16000,
	1: 16000,
	2: 68000,
	3: 120000,
}
## 王国时代交互式配乐组曲（含 Intro + 三段常态循环变体 + Population 人口变体 + CameraZoom 镜头变体）。
const KINGDOM_AGE_SUITE_EVENT := "event:/Music/KingdomAge/Suite"
const KINGDOM_AGE_INTRO_MS := 0
const KINGDOM_AGE_SECTION_MS := {
	0: 16000,
	1: 16000,
	2: 66000,
	3: 116000,
}
## 帝国时代交互式配乐组曲（含 Intro + 三段常态循环变体 + Population 人口变体 + CameraZoom 镜头变体）。
const EMPIRE_AGE_SUITE_EVENT := "event:/Music/EmpireAge/Suite"
const EMPIRE_AGE_INTRO_MS := 0
const EMPIRE_AGE_SECTION_MS := {
	0: 15000,
	1: 15000,
	2: 65000,
	3: 115000,
}

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
var _stone_age_pop_tier := 0
var _agrarian_age_pop_tier := 0
var _kingdom_age_pop_tier := 0
var _empire_age_pop_tier := 0
var _last_camera_zoom_ratio := 0.5
var _last_population_count := 0
var _last_tension := 0.0
var _last_war := 0.0
var _last_ceremony := 0.0
var _timeline_jump_seq := 0
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
	for suite_path in [STONE_AGE_SUITE_EVENT, AGRARIAN_AGE_SUITE_EVENT, KINGDOM_AGE_SUITE_EVENT, EMPIRE_AGE_SUITE_EVENT]:
		_music_description(suite_path)
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


## 时代推进驱动音乐。接入前四个时代的交互式配乐组曲（石器/农耕/王国/帝国），
## 更靠后的时代沿用「帝国时代」组曲。
## 首次进入会话（_era_index < 0）时从 0.0s「刚进入游戏」引子起播；
## 会话内时代升级（_era_index >= 0 且晋升）时叠加 9.6s 时代升级礼乐过渡曲并切入新时代主循环。
func set_era(era_index: int) -> bool:
	if era_index < 0:
		return false
	var clamped := mini(era_index, ERA_MUSIC.size() - 1)
	var target_key := _era_suite_key(clamped)
	if clamped == _era_index and _music != 0 and _music_key == target_key:
		return true
	var advancing := _era_index >= 0 and clamped > _era_index
	var from_intro := not advancing
	if advancing:
		var transition := _era_transition_key(clamped)
		if not transition.is_empty():
			play_transition(transition)
	var ok := false
	match clamped:
		0:
			ok = play_stone_age_suite(from_intro, 0.0, _last_camera_zoom_ratio, 0)
		1:
			ok = play_agrarian_age_suite(from_intro, 0.0, _last_camera_zoom_ratio, 0)
		2:
			ok = play_kingdom_age_suite(from_intro, 0.0, _last_camera_zoom_ratio, 0)
		_:
			ok = play_empire_age_suite(from_intro, 0.0, _last_camera_zoom_ratio, 0)
	if ok:
		_era_index = clamped
		if _last_population_count > 0:
			update_active_suite_population_count(_last_population_count)
		if _music_key in [&"kingdom_age_suite", &"empire_age_suite"]:
			set_active_suite_emotion(_last_tension, _last_war, _last_ceremony, true)
	return ok


func _era_suite_key(era_index: int) -> StringName:
	match clampi(era_index, 0, 3):
		0: return &"stone_age_suite"
		1: return &"agrarian_age_suite"
		2: return &"kingdom_age_suite"
		_: return &"empire_age_suite"


## 当前音乐对应的时代索引；未接入时为 -1。
func era_index() -> int:
	return _era_index


func _era_transition_key(era_index: int) -> StringName:
	match era_index:
		1: return &"trans_stone_to_agrarian"
		2: return &"trans_agrarian_to_kingdom"
		3: return &"trans_kingdom_to_empire"
	return &""


## 根据玩家国家当前总人口更新当前激活时代组曲的 Population 参数（带各时代专属双阈值滞回防抖）。
func update_active_suite_population_count(pop_count: int) -> float:
	_last_population_count = maxi(0, pop_count)
	match _music_key:
		&"stone_age_suite":
			return update_stone_age_population_count(_last_population_count)
		&"agrarian_age_suite":
			return update_agrarian_age_population_count(_last_population_count)
		&"kingdom_age_suite":
			return update_kingdom_age_population_count(_last_population_count)
		&"empire_age_suite":
			return update_empire_age_population_count(_last_population_count)
	return 0.0


## 设置当前激活时代组曲的「拉近/拉远地图变体」连续参数 CameraZoom (0.0=拉近聚落近景 .. 0.5=标准中景 .. 1.0=拉远大陆苍穹)。
func set_active_suite_camera_zoom(zoom_out_ratio: float, ignore_seek_speed: bool = false) -> bool:
	_last_camera_zoom_ratio = clampf(zoom_out_ratio, 0.0, 1.0)
	match _music_key:
		&"stone_age_suite":
			return set_stone_age_camera_zoom(_last_camera_zoom_ratio, ignore_seek_speed)
		&"agrarian_age_suite":
			return set_agrarian_age_camera_zoom(_last_camera_zoom_ratio, ignore_seek_speed)
		&"kingdom_age_suite":
			return set_kingdom_age_camera_zoom(_last_camera_zoom_ratio, ignore_seek_speed)
		&"empire_age_suite":
			return set_empire_age_camera_zoom(_last_camera_zoom_ratio, ignore_seek_speed)
	return false


## 当前 Kingdom/Empire 组曲的情绪层控制。Stone/Agrarian 保持接口兼容，暂不暴露五声部自动化。
func set_active_suite_emotion(tension: float, war: float, ceremony: float,
		ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key not in [&"kingdom_age_suite", &"empire_age_suite"]:
		return false
	var values := {
		"Tension": clampf(tension, 0.0, 1.0),
		"War": clampf(war, 0.0, 1.0),
		"Ceremony": clampf(ceremony, 0.0, 1.0),
	}
	var ok := true
	for parameter_name in values:
		ok = int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name", _music,
			parameter_name, float(values[parameter_name]), ignore_seek_speed)) == 0 and ok
	_last_tension = values["Tension"]
	_last_war = values["War"]
	_last_ceremony = values["Ceremony"]
	return ok


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
		if ClassDB.class_has_method("StudioEventDescription", "load_sample_data"):
			ClassDB.class_call_static("StudioEventDescription", "load_sample_data", description)
		_music_descriptions[event_path] = description
	return description


func _ensure_suite_timeline_start(instance: int, start_ms: int) -> void:
	_timeline_jump_seq += 1
	var seq := _timeline_jump_seq
	if instance == 0 or _music != instance:
		return
	ClassDB.class_call_static("StudioEventInstance", "set_timeline_position", _music, maxi(0, start_ms))
	if start_ms <= 0 or not is_inside_tree():
		return
	for _attempt in range(12):
		await get_tree().create_timer(0.05).timeout
		if seq != _timeline_jump_seq or _music != instance or _music == 0:
			return
		ClassDB.class_call_static("StudioSystem", "flush_commands", _system)
		var cur_pos := int(ClassDB.class_call_static("StudioEventInstance", "get_timeline_position", _music))
		if cur_pos < start_ms - 500:
			ClassDB.class_call_static("StudioEventInstance", "set_timeline_position", _music, start_ms)
			ClassDB.class_call_static("StudioSystem", "flush_commands", _system)
		elif cur_pos > start_ms:
			return


## 启动石器时代交互式配乐组曲。
## from_intro=true 时从 0.0s「刚进入游戏 · 荒原初醒」引子开始，播完自动滑入 12.8s..60.8s 常态循环；
## from_intro=false 时直接从 12.8s 常态循环起点切入。
func play_stone_age_suite(from_intro: bool = true, population_ratio: float = 0.0,
		camera_zoom_ratio: float = 0.5, loop_section: int = 0) -> bool:
	if status != "ready":
		return false
	var description := _music_description(STONE_AGE_SUITE_EVENT)
	if description == 0:
		return false
	if _music == 0 or _music_key != &"stone_age_suite":
		stop_music()
		_music = int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
		if _music == 0:
			return false
		_music_key = &"stone_age_suite"
		_music_parameterized = false
		set_stone_age_population(population_ratio, true)
		set_stone_age_camera_zoom(camera_zoom_ratio, true)
		set_stone_age_loop_section(loop_section, false)
		if int(ClassDB.class_call_static("StudioEventInstance", "start", _music)) != 0:
			stop_music()
			return false
	else:
		set_stone_age_population(population_ratio, false)
		set_stone_age_camera_zoom(camera_zoom_ratio, false)
		set_stone_age_loop_section(loop_section, false)
	var start_ms: int = STONE_AGE_INTRO_MS if from_intro else int(STONE_AGE_SECTION_MS.get(clampi(loop_section, 0, 3), 12800))
	_ensure_suite_timeline_start(_music, start_ms)
	return true


## 设置石器时代「人口阈值变体」连续参数 Population (0.0 .. 1.0)。
##   0.00 ~ 0.18: 零散采集者（仅基础骨笛/陶埙/石磬）
##   0.32 ~ 0.50: 聚落初成（部落兽皮帧鼓、木柷、果壳摇铃、猎弓低音律动渐入）
##   0.68 ~ 1.00: 氏族繁盛（氏族多声部呼麦/人声吟唱 + 高音双骨笛华彩对位渐入）
func set_stone_age_population(ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"stone_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "Population", clampf(ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 根据真实聚落人口数更新 Population 参数（内置双阈值滞回防抖，防止阈值边缘反复进出）：
##   Tier 1 (聚落律动轨): 满 300 人进入，跌破 240 人退出
##   Tier 2 (氏族繁盛轨): 满 800 人进入，跌破 680 人退出
func update_stone_age_population_count(pop_count: int) -> float:
	var p := maxi(0, pop_count)
	match _stone_age_pop_tier:
		0:
			if p >= 800:
				_stone_age_pop_tier = 2
			elif p >= 300:
				_stone_age_pop_tier = 1
		1:
			if p >= 800:
				_stone_age_pop_tier = 2
			elif p < 240:
				_stone_age_pop_tier = 0
		2:
			if p < 240:
				_stone_age_pop_tier = 0
			elif p < 680:
				_stone_age_pop_tier = 1
	var target_ratio := 0.0
	match _stone_age_pop_tier:
		0:
			target_ratio = clampf(float(p) / 300.0 * 0.16, 0.0, 0.16)
		1:
			target_ratio = clampf(0.42 + float(p - 240) / 560.0 * 0.10, 0.40, 0.52)
		2:
			target_ratio = clampf(0.84 + float(p - 680) / 520.0 * 0.16, 0.84, 1.0)
	set_stone_age_population(target_ratio, false)
	return target_ratio


## 设置石器时代「拉近/拉远地图变体」连续参数 CameraZoom (0.0 .. 1.0)。
##   0.00 (拉近地图): 近景篝火木柴噼啪 + 燧石打制石器 + 近场陶罐手鼓 + 高频清脆提亮
##   0.50 (标准中景): 均衡室内乐混音
##   1.00 (拉远地图): 高空旷野苍穹风声 + 远古泛音云层 + 大陆地平线低音 + 远景柔化滤波
func set_stone_age_camera_zoom(zoom_out_ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"stone_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "CameraZoom", clampf(zoom_out_ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 设置石器时代常态循环段落 LoopSection (0=三段自动轮转 A→B→C, 1=锁定循环A, 2=锁定循环B, 3=锁定循环C)。
func set_stone_age_loop_section(section: int, jump_immediately: bool = true) -> bool:
	if _music == 0 or _music_key != &"stone_age_suite":
		return false
	var clamped := clampi(section, 0, 3)
	var ok := int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "LoopSection", float(clamped), true)) == 0
	if jump_immediately and clamped >= 1:
		jump_stone_age_timeline_ms(int(STONE_AGE_SECTION_MS.get(clamped, 12800)))
	return ok


## 跳转当前音乐事件的时间轴毫秒位置（用于试听台直接切入 Intro 或各段循环）。
func jump_stone_age_timeline_ms(timeline_ms: int) -> bool:
	_timeline_jump_seq += 1
	if _music == 0:
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_timeline_position",
		_music, maxi(0, timeline_ms))) == 0


## 启动农耕时代交互式配乐组曲。
## from_intro=true 时从 0.0s「刚进入游戏 · 晨曦开犁」引子开始，播完自动滑入 12.0s..57.0s 常态循环；
## from_intro=false 时直接从 12.0s 常态循环起点切入。
func play_agrarian_age_suite(from_intro: bool = true, population_ratio: float = 0.0,
		camera_zoom_ratio: float = 0.5, loop_section: int = 0) -> bool:
	if status != "ready":
		return false
	var description := _music_description(AGRARIAN_AGE_SUITE_EVENT)
	if description == 0:
		return false
	if _music == 0 or _music_key != &"agrarian_age_suite":
		stop_music()
		_music = int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
		if _music == 0:
			return false
		_music_key = &"agrarian_age_suite"
		_music_parameterized = false
		set_agrarian_age_population(population_ratio, true)
		set_agrarian_age_camera_zoom(camera_zoom_ratio, true)
		set_agrarian_age_loop_section(loop_section, false)
		if int(ClassDB.class_call_static("StudioEventInstance", "start", _music)) != 0:
			stop_music()
			return false
	else:
		set_agrarian_age_population(population_ratio, false)
		set_agrarian_age_camera_zoom(camera_zoom_ratio, false)
		set_agrarian_age_loop_section(loop_section, false)
	var start_ms: int = AGRARIAN_AGE_INTRO_MS if from_intro else int(AGRARIAN_AGE_SECTION_MS.get(clampi(loop_section, 0, 3), 12000))
	_ensure_suite_timeline_start(_music, start_ms)
	return true


## 设置农耕时代「人口阈值变体」连续参数 Population (0.0 .. 1.0)。
##   0.00 ~ 0.18: 初始农庄（仅竹笛/排箫/五弦古瑟/陶埙/青铜古铃）
##   0.32 ~ 0.50: 灌溉村落（春耕社祭土鼓、竹梆春杵、谷物沙锤、低音拨弦律动渐入）
##   0.68 ~ 1.00: 宗族城邑（丰收社祭人声合唱 + 青铜编铃华彩 + 高音双笛芦笙渐入）
func set_agrarian_age_population(ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"agrarian_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "Population", clampf(ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 根据农耕时代聚落人口数更新 Population 参数（内置双阈值滞回防抖）：
##   Tier 1 (灌溉村落律动轨): 满 600 人进入，跌破 480 人退出
##   Tier 2 (宗族城邑繁盛轨): 满 1600 人进入，跌破 1360 人退出
func update_agrarian_age_population_count(pop_count: int) -> float:
	var p := maxi(0, pop_count)
	match _agrarian_age_pop_tier:
		0:
			if p >= 1600:
				_agrarian_age_pop_tier = 2
			elif p >= 600:
				_agrarian_age_pop_tier = 1
		1:
			if p >= 1600:
				_agrarian_age_pop_tier = 2
			elif p < 480:
				_agrarian_age_pop_tier = 0
		2:
			if p < 480:
				_agrarian_age_pop_tier = 0
			elif p < 1360:
				_agrarian_age_pop_tier = 1
	var target_ratio := 0.0
	match _agrarian_age_pop_tier:
		0:
			target_ratio = clampf(float(p) / 600.0 * 0.16, 0.0, 0.16)
		1:
			target_ratio = clampf(0.42 + float(p - 480) / 1120.0 * 0.10, 0.40, 0.52)
		2:
			target_ratio = clampf(0.84 + float(p - 1360) / 1040.0 * 0.16, 0.84, 1.0)
	set_agrarian_age_population(target_ratio, false)
	return target_ratio


## 设置农耕时代「拉近/拉远地图变体」连续参数 CameraZoom (0.0 .. 1.0)。
##   0.00 (拉近地图): 水渠潺潺流水 + 石磨碾谷与连枷脱粒 + 田间晨鸟 + 高频清脆提亮
##   0.50 (标准中景): 丝竹田园室内乐均衡混音
##   1.00 (拉远地图): 沃野季风麦浪 + 天文历法星穹泛音 + 黄土地脉共鸣 + 远景柔化滤波
func set_agrarian_age_camera_zoom(zoom_out_ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"agrarian_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "CameraZoom", clampf(zoom_out_ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 设置农耕时代常态循环段落 LoopSection (0=三段自动轮转 A→B→C, 1=锁定循环A, 2=锁定循环B, 3=锁定循环C)。
func set_agrarian_age_loop_section(section: int, jump_immediately: bool = true) -> bool:
	if _music == 0 or _music_key != &"agrarian_age_suite":
		return false
	var clamped := clampi(section, 0, 3)
	var ok := int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "LoopSection", float(clamped), true)) == 0
	if jump_immediately and clamped >= 1:
		jump_agrarian_age_timeline_ms(int(AGRARIAN_AGE_SECTION_MS.get(clamped, 12000)))
	return ok


## 跳转农耕时代音乐事件的时间轴毫秒位置。
func jump_agrarian_age_timeline_ms(timeline_ms: int) -> bool:
	return jump_stone_age_timeline_ms(timeline_ms)


## 单独播放「石器时代 ──► 农耕时代」时代升级礼乐过渡曲《破晓定居 · 迈入农耕》(9.6s)。
##   0.0s .. 2.4s: 告别荒原（D 调远古骨角号 + 石磬滚奏 + 陶埙）
##   2.4s .. 4.5s: 破晓铸铜（五弦古瑟刮奏转入 D 大调属和弦 + 第一声先秦青铜古铃 + 土鼓渐强滚奏）
##   4.5s .. 9.6s: 万象更新（辉煌解决至 G 五声田园大调，社祭丰收合唱 + 青铜编铃 + 竹笛排箫齐鸣）
func play_stone_to_agrarian_transition() -> bool:
	return play_transition(&"trans_stone_to_agrarian")


## 执行「石器时代 ──► 农耕时代」完整时代升级音乐演出：
##   1. 立即奏响时代升级过渡曲 `event:/Music/Transition/era_stone_to_agrarian`
##   2. 将旧的石器时代音乐淡出，并平滑切入农耕时代交互式组曲 `event:/Music/AgrarianAge/Suite`
func advance_stone_to_agrarian_suite(population_ratio: float = 0.04,
		camera_zoom_ratio: float = 0.5, from_intro: bool = false) -> bool:
	if status != "ready":
		return false
	var trans_ok := play_stone_to_agrarian_transition()
	var suite_ok := play_agrarian_age_suite(from_intro, population_ratio, camera_zoom_ratio, 0)
	return trans_ok and suite_ok


## 启动王国时代交互式配乐组曲 (53.20s @ 85.7 BPM, C 雅乐宫调)。
## from_intro=true 时从 0.0s「刚进入游戏 · 钟鸣鼎食」引子开始，播完自动滑入 11.2s..53.2s 常态循环；
## from_intro=false 时直接从 11.2s 常态循环起点切入。
func play_kingdom_age_suite(from_intro: bool = true, population_ratio: float = 0.0,
		camera_zoom_ratio: float = 0.5, loop_section: int = 0) -> bool:
	if status != "ready":
		return false
	var description := _music_description(KINGDOM_AGE_SUITE_EVENT)
	if description == 0:
		return false
	if _music == 0 or _music_key != &"kingdom_age_suite":
		stop_music()
		_music = int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
		if _music == 0:
			return false
		_music_key = &"kingdom_age_suite"
		_music_parameterized = false
		set_kingdom_age_population(population_ratio, true)
		set_kingdom_age_camera_zoom(camera_zoom_ratio, true)
		set_kingdom_age_loop_section(loop_section, false)
		if int(ClassDB.class_call_static("StudioEventInstance", "start", _music)) != 0:
			stop_music()
			return false
	else:
		set_kingdom_age_population(population_ratio, false)
		set_kingdom_age_camera_zoom(camera_zoom_ratio, false)
		set_kingdom_age_loop_section(loop_section, false)
	var start_ms: int = KINGDOM_AGE_INTRO_MS if from_intro else int(KINGDOM_AGE_SECTION_MS.get(clampi(loop_section, 0, 3), 16000))
	_ensure_suite_timeline_start(_music, start_ms)
	return true


## 设置王国时代「人口阈值变体」连续参数 Population (0.0 .. 1.0)。
func set_kingdom_age_population(ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"kingdom_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "Population", clampf(ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 根据王国时代城邦人口数更新 Population 参数（双阈值滞回防抖）：
##   Tier 1 (筑城首府律动轨): 满 1500 人进入，跌破 1200 人退出
##   Tier 2 (王畿盛世合唱轨): 满 4000 人进入，跌破 3400 人退出
func update_kingdom_age_population_count(pop_count: int) -> float:
	var p := maxi(0, pop_count)
	match _kingdom_age_pop_tier:
		0:
			if p >= 4000:
				_kingdom_age_pop_tier = 2
			elif p >= 1500:
				_kingdom_age_pop_tier = 1
		1:
			if p >= 4000:
				_kingdom_age_pop_tier = 2
			elif p < 1200:
				_kingdom_age_pop_tier = 0
		2:
			if p < 1200:
				_kingdom_age_pop_tier = 0
			elif p < 3400:
				_kingdom_age_pop_tier = 1
	var target_ratio := 0.0
	match _kingdom_age_pop_tier:
		0:
			target_ratio = clampf(float(p) / 1500.0 * 0.16, 0.0, 0.16)
		1:
			target_ratio = clampf(0.42 + float(p - 1200) / 2800.0 * 0.10, 0.40, 0.52)
		2:
			target_ratio = clampf(0.84 + float(p - 3400) / 2600.0 * 0.16, 0.84, 1.0)
	set_kingdom_age_population(target_ratio, false)
	return target_ratio


## 设置王国时代「拉近/拉远地图变体」连续参数 CameraZoom (0.0 .. 1.0)。
func set_kingdom_age_camera_zoom(zoom_out_ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"kingdom_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "CameraZoom", clampf(zoom_out_ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 设置王国时代常态循环段落 LoopSection (0=三段自动轮转, 1..3=锁定对应 50 秒循环块)。
func set_kingdom_age_loop_section(section: int, jump_immediately: bool = false) -> bool:
	if _music == 0 or _music_key != &"kingdom_age_suite":
		return false
	var clamped := clampi(section, 0, 3)
	var ok := int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "LoopSection", float(clamped), false)) == 0
	if jump_immediately and clamped >= 1:
		jump_kingdom_age_timeline_ms(int(KINGDOM_AGE_SECTION_MS.get(clamped, 11200)))
	return ok


func jump_kingdom_age_timeline_ms(timeline_ms: int) -> bool:
	return jump_stone_age_timeline_ms(timeline_ms)


## 单独播放「农耕时代 ──► 王国时代」时代升级礼乐过渡曲《铸鼎立邦 · 礼乐初成》(9.6s)。
func play_agrarian_to_kingdom_transition() -> bool:
	return play_transition(&"trans_agrarian_to_kingdom")


## 执行「农耕时代 ──► 王国时代」完整时代升级音乐演出。
func advance_agrarian_to_kingdom_suite(population_ratio: float = 0.04,
		camera_zoom_ratio: float = 0.5, from_intro: bool = false) -> bool:
	if status != "ready":
		return false
	var trans_ok := play_agrarian_to_kingdom_transition()
	var suite_ok := play_kingdom_age_suite(from_intro, population_ratio, camera_zoom_ratio, 0)
	return trans_ok and suite_ok


## 启动帝国时代交互式配乐组曲（Intro + 三段 50 秒循环，F 大调交响调式）。
## from_intro=true 时从 0.0s 引子开始，随后进入 15.0s..165.0s 常态循环；
## from_intro=false 时直接从 15.0s 常态循环起点切入。
func play_empire_age_suite(from_intro: bool = true, population_ratio: float = 0.0,
		camera_zoom_ratio: float = 0.5, loop_section: int = 0) -> bool:
	if status != "ready":
		return false
	var description := _music_description(EMPIRE_AGE_SUITE_EVENT)
	if description == 0:
		return false
	if _music == 0 or _music_key != &"empire_age_suite":
		stop_music()
		_music = int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
		if _music == 0:
			return false
		_music_key = &"empire_age_suite"
		_music_parameterized = false
		set_empire_age_population(population_ratio, true)
		set_empire_age_camera_zoom(camera_zoom_ratio, true)
		set_empire_age_loop_section(loop_section, false)
		if int(ClassDB.class_call_static("StudioEventInstance", "start", _music)) != 0:
			stop_music()
			return false
	else:
		set_empire_age_population(population_ratio, false)
		set_empire_age_camera_zoom(camera_zoom_ratio, false)
		set_empire_age_loop_section(loop_section, false)
	var start_ms: int = EMPIRE_AGE_INTRO_MS if from_intro else int(EMPIRE_AGE_SECTION_MS.get(clampi(loop_section, 0, 3), 15000))
	_ensure_suite_timeline_start(_music, start_ms)
	return true


## 设置帝国时代「人口阈值变体」连续参数 Population (0.0 .. 1.0)。
func set_empire_age_population(ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"empire_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "Population", clampf(ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 根据帝国时代大都会人口数更新 Population 参数（双阈值滞回防抖）：
##   Tier 1 (繁华都护府律动轨): 满 4000 人进入，跌破 3200 人退出
##   Tier 2 (盛世帝京交响合唱轨): 满 10000 人进入，跌破 8500 人退出
func update_empire_age_population_count(pop_count: int) -> float:
	var p := maxi(0, pop_count)
	match _empire_age_pop_tier:
		0:
			if p >= 10000:
				_empire_age_pop_tier = 2
			elif p >= 4000:
				_empire_age_pop_tier = 1
		1:
			if p >= 10000:
				_empire_age_pop_tier = 2
			elif p < 3200:
				_empire_age_pop_tier = 0
		2:
			if p < 3200:
				_empire_age_pop_tier = 0
			elif p < 8500:
				_empire_age_pop_tier = 1
	var target_ratio := 0.0
	match _empire_age_pop_tier:
		0:
			target_ratio = clampf(float(p) / 4000.0 * 0.16, 0.0, 0.16)
		1:
			target_ratio = clampf(0.42 + float(p - 3200) / 6800.0 * 0.10, 0.40, 0.52)
		2:
			target_ratio = clampf(0.84 + float(p - 8500) / 6500.0 * 0.16, 0.84, 1.0)
	set_empire_age_population(target_ratio, false)
	return target_ratio


## 设置帝国时代「拉近/拉远地图变体」连续参数 CameraZoom (0.0 .. 1.0)。
func set_empire_age_camera_zoom(zoom_out_ratio: float, ignore_seek_speed: bool = false) -> bool:
	if _music == 0 or _music_key != &"empire_age_suite":
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "CameraZoom", clampf(zoom_out_ratio, 0.0, 1.0), ignore_seek_speed)) == 0


## 设置帝国时代常态循环段落 LoopSection (0=三段自动轮转, 1..3=锁定对应 50 秒循环块)。
func set_empire_age_loop_section(section: int, jump_immediately: bool = false) -> bool:
	if _music == 0 or _music_key != &"empire_age_suite":
		return false
	var clamped := clampi(section, 0, 3)
	var ok := int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "LoopSection", float(clamped), false)) == 0
	if jump_immediately and clamped >= 1:
		jump_empire_age_timeline_ms(int(EMPIRE_AGE_SECTION_MS.get(clamped, 10400)))
	return ok


func jump_empire_age_timeline_ms(timeline_ms: int) -> bool:
	return jump_stone_age_timeline_ms(timeline_ms)


## 单独播放「王国时代 ──► 帝国时代」时代升级礼乐过渡曲《四海一统 · 万邦来朝》(9.6s)。
func play_kingdom_to_empire_transition() -> bool:
	return play_transition(&"trans_kingdom_to_empire")


## 执行「王国时代 ──► 帝国时代」完整时代升级音乐演出。
func advance_kingdom_to_empire_suite(population_ratio: float = 0.04,
		camera_zoom_ratio: float = 0.5, from_intro: bool = false) -> bool:
	if status != "ready":
		return false
	var trans_ok := play_kingdom_to_empire_transition()
	var suite_ok := play_empire_age_suite(from_intro, population_ratio, camera_zoom_ratio, 0)
	return trans_ok and suite_ok


func stop_music() -> void:
	_timeline_jump_seq += 1
	if _music != 0:
		ClassDB.class_call_static("StudioEventInstance", "stop", _music, 1)
		ClassDB.class_call_static("StudioEventInstance", "release", _music)
		_music = 0
	_music_parameterized = false
	_music_key = &""
	_era_index = -1
	_last_tension = 0.0
	_last_war = 0.0
	_last_ceremony = 0.0


func diagnostics() -> Dictionary:
	if status != "ready":
		return {"status": status}
	ClassDB.class_call_static("StudioSystem", "flush_commands", _system)
	var ui_voices := 0
	for description in _ui_descriptions.values():
		ui_voices += int(ClassDB.class_call_static("StudioEventDescription", "get_instance_count", description))
	var active_pop_tier := _stone_age_pop_tier
	match _music_key:
		&"agrarian_age_suite":
			active_pop_tier = _agrarian_age_pop_tier
		&"kingdom_age_suite":
			active_pop_tier = _kingdom_age_pop_tier
		&"empire_age_suite":
			active_pop_tier = _empire_age_pop_tier
	return {"status": status, "banks": _banks.size(), "music_playing": _music != 0,
		"music_key": _music_key,
		"ui_voices": ui_voices,
		"spatial": _spatial_enabled,
		"master_volume": ClassDB.class_call_static("StudioBus", "get_volume", _master),
		"master_muted": ClassDB.class_call_static("StudioBus", "get_mute", _master),
		"tension": ClassDB.class_call_static("StudioEventInstance", "get_parameter_by_name", _music, "Tension") if _music != 0 else 0.0,
		"war": ClassDB.class_call_static("StudioEventInstance", "get_parameter_by_name", _music, "War") if _music != 0 else 0.0,
		"ceremony": ClassDB.class_call_static("StudioEventInstance", "get_parameter_by_name", _music, "Ceremony") if _music != 0 else 0.0,
		"population": ClassDB.class_call_static("StudioEventInstance", "get_parameter_by_name", _music, "Population") if _music != 0 else 0.0,
		"camera_zoom": ClassDB.class_call_static("StudioEventInstance", "get_parameter_by_name", _music, "CameraZoom") if _music != 0 else 0.5,
		"loop_section": int(round(float(ClassDB.class_call_static("StudioEventInstance", "get_parameter_by_name", _music, "LoopSection")))) if _music != 0 else 0,
		"pop_tier": active_pop_tier,
		"stone_pop_tier": _stone_age_pop_tier,
		"agrarian_pop_tier": _agrarian_age_pop_tier,
		"kingdom_pop_tier": _kingdom_age_pop_tier,
		"empire_pop_tier": _empire_age_pop_tier,
		"timeline_ms": ClassDB.class_call_static("StudioEventInstance", "get_timeline_position", _music) if _music != 0 else 0}


func _release_banks() -> void:
	for index in range(_banks.size() - 1, -1, -1):
		ClassDB.class_call_static("StudioBank", "unload", _banks[index])
	_banks.clear()


func _exit_tree() -> void:
	stop_music()
	_release_banks()
