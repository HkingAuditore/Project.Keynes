extends Node
## Portable full-mix playback for Web and Android. Windows keeps the interactive
## FMOD suites; PK_AUDIO_FORCE_NATIVE=1 / --audio-native force this backend there
## for local smoke tests.
##
## Godot's Web audio driver resumes its AudioContext on the first user gesture.
## Android additionally gets explicit lifecycle handling: the app going to the
## background (or losing focus) pauses music and stops one-shots; coming back
## resumes the exact same playback position.

const ROOT := "res://assets/audio/native/"
const ERAS := [&"stone", &"agrarian", &"kingdom", &"empire"]
const INTRO_SECONDS := [18.0, 16.0, 16.0, 15.0]
const SECTION_SECONDS := [54.0, 52.0, 50.0, 50.0]
const MAX_VOICES := 12

var music: AudioStreamPlayer
var music_key := &""
var _voices: Array[AudioStreamPlayer] = []
var _streams: Dictionary = {}
var _next_voice := 0
## [web-music-defer 2026-11-01] Web 把音乐拆成 `music_<era>.pck` / `music_trans.pck`，
## 首屏不再背 17.7 MB。这里记录"因为包还没挂上而没放成"的请求，挂载完成后重放。
## 注意：`_stream()` **不缓存失败**（只缓存成功的 stream），所以重试天然安全；
## 缺的只是"谁来重试"，由下面的 pending 字段提供。
var _music_loader: Node = null
var _pending_suite := -1
var _pending_cue_path := ""
## True between APPLICATION_PAUSED/FOCUS_OUT and APPLICATION_RESUMED/FOCUS_IN.
## Also exposed to tests through pause_for_lifecycle()/resume_from_lifecycle().
var _lifecycle_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	music = _player("Music")
	for index in MAX_VOICES:
		_voices.append(_player("Effect%d" % index))
	if OS.has_feature("web"):
		var script: Variant = load("res://scripts/audio/web_music_stream.gd")
		if script != null:
			_music_loader = script.new()
			_music_loader.name = "WebMusicStream"
			add_child(_music_loader)


## 挂载完成后重放"当前时代那首"。
func _on_suite_pack_ready() -> void:
	if _pending_suite < 0:
		return
	var era := _pending_suite
	_pending_suite = -1
	play_suite(era)


## 挂载完成后重放过场音效。
func _on_transitions_pack_ready() -> void:
	var path := _pending_cue_path
	_pending_cue_path = ""
	if path.is_empty():
		return
	_one_shot(path)


func _request_suite_pack(era: int) -> void:
	if not OS.has_feature("web") or _music_loader == null:
		return
	_pending_suite = era
	_music_loader.ensure_pack(String(ERAS[clampi(era, 0, 3)]),
		Callable(self, "_on_suite_pack_ready"))


func _request_transitions_pack(path: String) -> void:
	if not OS.has_feature("web") or _music_loader == null:
		return
	_pending_cue_path = path
	_music_loader.ensure_pack("trans", Callable(self, "_on_transitions_pack_ready"))


func _player(player_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	# Decode music as a stream instead of expanding minutes of audio into Web samples.
	player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	player.bus = &"Master"
	add_child(player)
	return player


func _stream(path: String) -> AudioStreamOggVorbis:
	if _streams.has(path):
		return _streams[path] as AudioStreamOggVorbis
	if not ResourceLoader.exists(path):
		push_warning("[audio] Missing portable audio: " + path)
		return null
	var stream := load(path) as AudioStreamOggVorbis
	if stream != null:
		_streams[path] = stream
	return stream


func play_suite(era: int, from_intro: bool = true, section: int = 0) -> bool:
	var index := clampi(era, 0, 3)
	var key := StringName(String(ERAS[index]) + "_age_suite")
	if music_key == key and (music.playing or music.stream_paused):
		return true
	var stream := _stream(ROOT + "music/" + String(ERAS[index]) + ".ogg")
	if stream == null:
		# Web：这首时代曲在独立 pck 里，异步拉取，挂载后重放（_on_suite_pack_ready）。
		_request_suite_pack(index)
		return false
	stream.loop = true
	stream.loop_offset = INTRO_SECONDS[index]
	music.stream = stream
	music_key = key
	var start: float = 0.0 if from_intro else INTRO_SECONDS[index]
	if section > 0:
		start = INTRO_SECONDS[index] + (clampi(section, 1, 3) - 1) * SECTION_SECONDS[index]
	music.play(start)
	# If a suite is requested while the app is in the background, remember it but
	# do not leak audio until the next foreground resume.
	music.stream_paused = _lifecycle_paused
	return true


func play_music(key: StringName) -> bool:
	if key == &"hall":
		return play_suite(0)
	for index in ERAS.size():
		if key == StringName(String(ERAS[index]) + "_age_suite"):
			return play_suite(index)
	for index in ["dark", "feudal", "castle", "imperial"].size():
		if String(key).begins_with("explore_" + ["dark", "feudal", "castle", "imperial"][index] + "_"):
			return play_suite(index, false)
	return false


func play_cue(category: String, cue: StringName) -> bool:
	return _one_shot(ROOT + category + "/" + String(cue) + ".ogg")


func play_transition(event_path: String) -> bool:
	var cue := event_path.get_file()
	var aliases := {"trans_explore_feudal": "stone_to_agrarian",
		"trans_explore_castle": "agrarian_to_kingdom", "trans_explore_imperial": "kingdom_to_empire",
		"era_stone_to_agrarian": "stone_to_agrarian",
		"era_agrarian_to_kingdom": "agrarian_to_kingdom", "era_kingdom_to_empire": "kingdom_to_empire"}
	if not aliases.has(cue):
		return false
	var path := ROOT + "music/trans_" + String(aliases[cue]) + ".ogg"
	var played := _one_shot(path)
	if not played:
		# Web：过场音效在 music_trans.pck 里，异步拉取后重放。
		_request_transitions_pack(path)
	return played


func _one_shot(path: String) -> bool:
	if _lifecycle_paused:
		return false
	var stream := _stream(path)
	if stream == null:
		return false
	# Reuse idle voices first; bound the mixer even when events arrive in a burst.
	var voice := _voices[_next_voice]
	for candidate in _voices:
		if not candidate.playing:
			voice = candidate
			break
	_next_voice = (_next_voice + 1) % MAX_VOICES
	voice.stop()
	voice.stream_paused = false
	voice.stream = stream
	voice.play()
	return true


## Settings own the Godot Master bus on native platforms. GameSettings applies the
## same linear -> dB conversion, so both writers are absolute and idempotent; never
## use linear values here or the two would multiply.
func apply_settings(values: Dictionary) -> void:
	var master := AudioServer.get_bus_index("Master")
	if master < 0:
		return
	var linear := clampf(float(values.get("master_volume", 0.8)), 0.0, 1.0)
	AudioServer.set_bus_volume_db(master, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(master, bool(values.get("master_muted", false)))


func stop_music() -> void:
	music.stop()
	music_key = &""


## Android is the platform that wants lifecycle muting. The forced-native Windows
## test path enables it too so the notification handler can be exercised without a
## device; Web keeps its old behaviour (music continues while the tab is in the
## background).
func _lifecycle_enabled() -> bool:
	return OS.has_feature("android") or OS.get_environment("PK_AUDIO_FORCE_NATIVE") == "1"


func _notification(what: int) -> void:
	# A notification can theoretically arrive before _ready() creates the players.
	if music == null or not _lifecycle_enabled():
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			pause_for_lifecycle("notification:%d" % what)
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			resume_from_lifecycle("notification:%d" % what)


## Pause music in place and drop short one-shots. Returns true when music was
## actually playing (useful for tests/logs).
func pause_for_lifecycle(reason: String = "") -> bool:
	if music == null or _lifecycle_paused:
		return false
	_lifecycle_paused = true
	var was_playing := music.playing and not music.stream_paused
	if music.playing:
		music.stream_paused = true
	for voice in _voices:
		if voice.playing:
			voice.stop()
	# Verbose: lifecycle notifications are engine/platform dependent and must not
	# look like a failure when a host does not deliver them (see report).
	print_verbose("[audio] lifecycle=pause reason=%s music_playing=%s" % [reason, was_playing])
	return was_playing


## Resume the exact stream position that was paused. Returns true when music is
## playing again.
func resume_from_lifecycle(reason: String = "") -> bool:
	if music == null or not _lifecycle_paused:
		return false
	_lifecycle_paused = false
	# AudioStreamPlayer.playing turns false while stream_paused is set (Godot
	# suspends the playback), so unpause unconditionally instead of gating on it.
	if music.stream_paused:
		music.stream_paused = false
	print_verbose("[audio] lifecycle=resume reason=%s music_playing=%s pos=%.2f" % [
		reason, music.playing, music.get_playback_position()])
	return music.playing


func is_lifecycle_paused() -> bool:
	return _lifecycle_paused


func diagnostics() -> Dictionary:
	var voices := 0
	for voice in _voices:
		if voice.playing:
			voices += 1
	var master := AudioServer.get_bus_index("Master")
	return {"status": "ready", "backend": "native", "engine_backend": "godot", "mix": "full_mix",
		"platform": OS.get_name(), "banks": 0,
		"music_playing": music.playing, "music_key": music_key, "ui_voices": voices,
		"lifecycle_paused": _lifecycle_paused, "music_stream_paused": music.stream_paused,
		"master_volume": db_to_linear(AudioServer.get_bus_volume_db(master)),
		"master_muted": AudioServer.is_bus_mute(master),
		"timeline_ms": roundi(music.get_playback_position() * 1000.0)}
