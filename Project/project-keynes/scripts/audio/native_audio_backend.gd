extends Node
## Portable full-mix playback for Web. Windows retains the interactive FMOD suites.
## Godot's Web audio driver resumes its AudioContext on the first user gesture.

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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	music = _player("Music")
	for index in MAX_VOICES:
		_voices.append(_player("Effect%d" % index))


func _player(player_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	# Decode music as a stream instead of expanding minutes of audio into Web samples.
	player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
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
	if music.playing and music_key == key:
		return true
	var stream := _stream(ROOT + "music/" + String(ERAS[index]) + ".ogg")
	if stream == null:
		return false
	stream.loop = true
	stream.loop_offset = INTRO_SECONDS[index]
	music.stream = stream
	music_key = key
	var start: float = 0.0 if from_intro else INTRO_SECONDS[index]
	if section > 0:
		start = INTRO_SECONDS[index] + (clampi(section, 1, 3) - 1) * SECTION_SECONDS[index]
	music.play(start)
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
	return _one_shot(ROOT + "music/trans_" + String(aliases[cue]) + ".ogg")


func _one_shot(path: String) -> bool:
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
	voice.stream = stream
	voice.play()
	return true


func apply_settings(values: Dictionary) -> void:
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master,
		linear_to_db(maxf(0.0001, clampf(float(values.get("master_volume", 0.8)), 0.0, 1.0))))
	AudioServer.set_bus_mute(master, bool(values.get("master_muted", false)))


func stop_music() -> void:
	music.stop()
	music_key = &""


func diagnostics() -> Dictionary:
	var voices := 0
	for voice in _voices:
		if voice.playing:
			voices += 1
	var master := AudioServer.get_bus_index("Master")
	return {"status": "ready", "backend": "godot", "mix": "full_mix", "banks": 0,
		"music_playing": music.playing, "music_key": music_key, "ui_voices": voices,
		"master_volume": db_to_linear(AudioServer.get_bus_volume_db(master)),
		"master_muted": AudioServer.is_bus_mute(master),
		"timeline_ms": roundi(music.get_playback_position() * 1000.0)}
