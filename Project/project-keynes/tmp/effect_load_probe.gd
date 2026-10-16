extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var catalog = EffectDomainCatalog.build()
	var ext = ClassDB.instantiate("DCWorldExt")
	var compiled: Dictionary = catalog.compile_native_catalog()
	var configured: Dictionary = ext.configure_effects(compiled)
	if not configured.get("ok", false):
		print("[effect-load-probe] configure ", configured)
		quit(1)
		return
	for slot in ["manual_1", "manual_2"]:
		var bytes := FileAccess.get_file_as_bytes("D:/Godot/ProjectKeynes/Project.Keynes/tmp/%s_effect.bin" % slot)
		var result: Dictionary = ext.restore_effect_state(bytes)
		print("[effect-load-probe] ", slot, " ", result)
		if not result.get("ok", false):
			quit(1)
			return
		var canonical: PackedByteArray = ext.capture_effect_state()
		result = ext.restore_effect_state(canonical)
		print("[effect-load-probe] canonical ", result)
		if not result.get("ok", false):
			quit(1)
			return
		if canonical != ext.capture_effect_state():
			print("[effect-load-probe] roundtrip differs")
			quit(1)
			return
	print("[effect-load-probe] PASS")
	quit(0)
