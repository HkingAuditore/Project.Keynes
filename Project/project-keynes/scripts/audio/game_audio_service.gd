extends Node
## Presentation-only FMOD boundary. Unsupported platforms retain the native audio path.

const EXTENSION := "res://addons/FmodGodot/FmodGodot.gdextension"
const BANK_ROOT := "res://assets/audio/banks/Desktop/"
const MUSIC_EVENT := "event:/Music/Prototype"
const CLICK_EVENT := "event:/UI/Click"
var status := "not_initialized"
var _system := 0
var _master := 0
var _music := 0
var _banks: Array[int] = []


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
	return set_tension(tension)


func set_tension(value: float) -> bool:
	if _music == 0:
		return false
	return int(ClassDB.class_call_static("StudioEventInstance", "set_parameter_by_name", _music,
		"Tension", clampf(value, 0.0, 1.0), false)) == 0


func play_ui_click() -> bool:
	if status != "ready":
		return false
	var description := int(ClassDB.class_call_static("StudioSystem", "get_event", _system, CLICK_EVENT))
	var instance := int(ClassDB.class_call_static("StudioEventDescription", "create_instance", description))
	if instance == 0:
		return false
	var result := int(ClassDB.class_call_static("StudioEventInstance", "start", instance))
	ClassDB.class_call_static("StudioEventInstance", "release", instance)
	return result == 0


func stop_music() -> void:
	if _music != 0:
		ClassDB.class_call_static("StudioEventInstance", "stop", _music, 1)
		ClassDB.class_call_static("StudioEventInstance", "release", _music)
		_music = 0


func diagnostics() -> Dictionary:
	if status != "ready":
		return {"status": status}
	ClassDB.class_call_static("StudioSystem", "flush_commands", _system)
	return {"status": status, "banks": _banks.size(), "music_playing": _music != 0,
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
