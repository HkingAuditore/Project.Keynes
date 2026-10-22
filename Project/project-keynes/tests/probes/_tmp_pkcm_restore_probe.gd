extends SceneTree

## 一次性探针：用当前（已重编）DLL 恢复旧存档的 PKCM/PKGP 段，确认 header 校验
## 现在会给出哪一条具体原因。用完即删。

const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const AUTOSAVE_PKCM := "D:/Godot/ProjectKeynes/tmp/autosave_pkcm.bin"
const MANUAL1_PKCM := "D:/Godot/ProjectKeynes/tmp/manual1_pkcm.bin"
const MANUAL1_PKGP := "D:/Godot/ProjectKeynes/tmp/manual1_pkgp.bin"


func _init() -> void:
	call_deferred("_run")


func _read(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return bytes


func _run() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var facade = ModifierFacadeScript.new()
	var configured: Dictionary = facade.configure(ext, 16)
	print("[probe] configure ok=%s hash=0x%X stats=%s defs=%s" % [
		str(configured.get("ok", false)),
		int(configured.get("catalog_hash", 0)),
		str(configured.get("stat_count", -1)),
		str(configured.get("definition_count", -1))])
	for entry in [[0, AUTOSAVE_PKCM, "autosave.pkcm"],
			[0, MANUAL1_PKCM, "manual_1.pkcm"],
			[3, MANUAL1_PKGP, "manual_1.pkgp"]]:
		var bytes := _read(String(entry[1]))
		if bytes.is_empty():
			print("[probe] %s missing" % String(entry[2]))
			continue
		var result: Dictionary = ext.restore_modifier_domain(int(entry[0]), bytes)
		print("[probe] %s ok=%s reason=%s" % [
			String(entry[2]), str(result.get("ok", false)),
			String(result.get("reason", ""))])
	quit(0)
