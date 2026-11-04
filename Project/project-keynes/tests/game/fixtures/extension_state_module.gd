extends RefCounted

const Provider = preload("res://scripts/game/runtime_state_provider.gd")
var value := PackedByteArray([3, 1, 4, 1, 5])
var restored := false

func provider():
	return Provider.new().configure(&"test_extension", 1,
		PackedStringArray(["test_extension"]), _can_save, _write, _restore, _hash)

func _can_save(_context: Dictionary) -> Dictionary:
	return {"ok": true}

func _write(_context: Dictionary) -> Dictionary:
	return {"ok": true, "sections": {"test_extension": value.duplicate()}}

func _restore(sections: Dictionary, _context: Dictionary) -> Dictionary:
	value = sections.test_extension.duplicate()
	restored = true
	return {"ok": true}

func _hash(context: Dictionary) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(var_to_bytes(context.get("current_provider_sections", {})))
	return hashing.finish().hex_encode()
