extends "res://scripts/audio/game_audio_platform.gd"

## Music instance playback, transitions between instances, and parameter updates.

const MUSIC_EVENT := "event:/Music/Prototype"

## 前四个时代（石器/农耕/王国/帝国）到探索音乐档位的映射。
const ERA_MUSIC := [&"dark", &"feudal", &"castle", &"imperial"]

## 参数化探索事件：一个事件内用全局参数 Era 选档，12 段音频完全复用。
const PARAM_EXPLORE_EVENT := "event:/Music/Library/Explore_Param"

var _music := 0
var _music_key := &""
var _era_index := -1
var _music_parameterized := false
var _last_tension := 0.0
var _last_war := 0.0
var _last_ceremony := 0.0
var _timeline_jump_seq := 0


func play_prototype(tension: float = 0.0) -> bool:
	if _native != null:
		return _play_native_suite(0, true, 0)
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
	if _native != null:
		# The portable full mixes are pre-authored per era (no FMOD Tension parameter).
		return false
	if _music == 0:
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name", _music,
		"Tension", clampf(value, 0.0, 1.0), false)) == 0


## 按 key 切换循环音乐。同一首重复调用不会重启。
func play_music(key: StringName) -> bool:
	if _native != null:
		var ok := _native.play_music(key)
		if ok:
			if _music_key != _native.music_key:
				_era_index = -1
			_music_key = _native.music_key
		return ok
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
	if _native != null:
		return _play_native_suite(era_index, false, 0)
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
	if _native != null:
		return _play_native_suite(era_index, false, 0)
	if _music == 0 or not _music_parameterized:
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name",
		_music, "Era", float(clampi(era_index, 0, ERA_MUSIC.size() - 1)), false)) == 0


## 当前音乐对应的时代索引；未接入时为 -1。
func era_index() -> int:
	return _era_index


## 按时代播放探索音乐。pick_random 时在同代多段里随机挑一首。
func play_explore(era: StringName, pick_random: bool = true) -> bool:
	var tracks := MusicCatalog.tracks_for(era)
	if tracks.is_empty():
		return false
	var key: StringName = tracks[randi() % tracks.size()] if pick_random else tracks[0]
	return play_music(key)


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


func _play_native_suite(era: int, from_intro: bool, section: int) -> bool:
	var ok := _native.play_suite(era, from_intro, section)
	if ok:
		if _music_key != _native.music_key:
			_era_index = -1
		_music_key = _native.music_key
	return ok


func stop_music() -> void:
	if _native != null:
		_native.stop_music()
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
