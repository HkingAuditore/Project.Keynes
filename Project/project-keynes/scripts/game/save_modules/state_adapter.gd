extends RefCounted

func _hash_provider_sections(context: Dictionary) -> String:
	var bytes := var_to_bytes(context.get("current_provider_sections", {}))
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		hashing.update(bytes)
	return hashing.finish().hex_encode()

func _capture_native(facade, provider_name: String) -> Dictionary:
	var begun: Dictionary = facade.begin_save()
	if not bool(begun.get("ok", false)):
		return _result(false, "%s_save_begin_failed" % provider_name,
			String(begun.get("reason", "无法开始 native 存档。")))
	var bytes := PackedByteArray()
	while true:
		var chunk: PackedByteArray = facade.read_save_chunk()
		if chunk.is_empty(): break
		bytes.append_array(chunk)
	var ended: Dictionary = facade.end_save()
	if not bool(ended.get("ok", false)):
		return _result(false, "%s_save_end_failed" % provider_name,
			String(ended.get("reason", "无法结束 native 存档。")))
	return {"ok": true, "code": "ok", "message": "", "bytes": bytes}


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return {"ok": ok, "code": code, "message": message}


func section_codecs(_id: StringName, _sections: PackedStringArray) -> Dictionary:
	return {}


func configure_provider(_provider: RuntimeStateProvider) -> void:
	pass
