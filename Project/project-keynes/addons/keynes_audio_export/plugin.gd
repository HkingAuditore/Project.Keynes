@tool
extends EditorPlugin

class AudioExport extends EditorExportPlugin:
	const ROOT := "res://addons/FmodGodot/"
	func _get_name() -> String:
		return "KeynesFmodWindows"
	func _export_begin(features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
		if not features.has("windows"):
			return
		add_file(ROOT + "FmodGodot.gdextension", FileAccess.get_file_as_bytes(ROOT + "FmodGodot.gdextension"), false)
		var banks := "res://assets/audio/banks/Desktop/"
		for name in DirAccess.get_files_at(banks):
			if name.ends_with(".bank"):
				add_file(banks + name, FileAccess.get_file_as_bytes(banks + name), false)
		var binaries := ROOT + "bin/windows/x86_64/"
		for name in DirAccess.get_files_at(binaries):
			if name.ends_with(".dll"):
				add_shared_object(binaries + name, PackedStringArray(["windows", "x86_64"]), "addons/FmodGodot/bin/windows/x86_64")
	func _export_file(path: String, _type: String, features: PackedStringArray) -> void:
		# FMOD Desktop banks are Windows-only. Web/Android use the portable Vorbis
		# full mixes in assets/audio/native, so those must ship on every host whose
		# GameAudio selects the native backend (web, Android).
		if path.begins_with("res://assets/audio/banks/") and not features.has("windows"):
			skip()
			return
		if path.begins_with("res://assets/audio/native/"):
			# Keep this list in sync with GameAudio._native_backend_reason_for():
			# only Web and Android actually instantiate the portable backend.
			for feature in ["web", "android"]:
				if features.has(feature):
					return
			skip()

var _audio_export: AudioExport
func _enter_tree() -> void:
	_audio_export = AudioExport.new()
	add_export_plugin(_audio_export)
func _exit_tree() -> void:
	remove_export_plugin(_audio_export)
