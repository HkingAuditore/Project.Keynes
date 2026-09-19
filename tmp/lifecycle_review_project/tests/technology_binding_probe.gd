extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		print("[BINDING_CATALOG_ERROR] ", JSON.stringify(catalog))
		quit(1)
		return
	var ids: PackedStringArray = catalog.technology_ids
	var offsets: PackedInt32Array = catalog.technology_content_binding_offsets
	var kinds: PackedByteArray = catalog.technology_content_binding_kinds
	var binding_ids: PackedStringArray = catalog.technology_content_binding_ids
	for technology_index in range(ids.size()):
		var total := offsets[technology_index + 1] - offsets[technology_index]
		var buildings := 0
		for edge in range(offsets[technology_index], offsets[technology_index + 1]):
			if int(kinds[edge]) == 2:
				buildings += 1
		if total > 4 or buildings > 2:
			var values := PackedStringArray()
			for edge in range(offsets[technology_index], offsets[technology_index + 1]):
				values.append("%d:%s" % [int(kinds[edge]), String(binding_ids[edge])])
			print("[FANOUT] ", ids[technology_index], " total=", total,
				" buildings=", buildings, " -> ", ",".join(values))
	quit(0)
