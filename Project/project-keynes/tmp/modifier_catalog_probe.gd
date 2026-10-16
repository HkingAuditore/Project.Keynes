extends SceneTree

func _init() -> void:
	var catalog: Dictionary = ModifierCatalog.load_default().compile_native_catalog()
	var file := FileAccess.open("res://tmp/modifier_catalog_probe.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(catalog))
	file.close()
	file = FileAccess.open("res://tmp/modifier_catalog_canonical.bin", FileAccess.WRITE)
	for i in catalog.stat_keys.size():
		file.store_buffer(catalog.stat_keys[i].to_utf8_buffer())
		file.store_32(catalog.stat_domains[i])
		file.store_double(catalog.stat_min_values[i])
		file.store_double(catalog.stat_max_values[i])
	for i in catalog.definition_keys.size():
		file.store_buffer(catalog.definition_keys[i].to_utf8_buffer())
		file.store_32(catalog.definition_versions[i])
	for i in catalog.term_stat_ids.size():
		var op: int = catalog.term_operations[i]
		var value: float = catalog.term_values[i]
		file.store_32(catalog.term_stat_ids[i])
		file.store_32(0)
		file.store_double(value if op == 0 else -value if op == 1 else 0.0)
		file.store_double(value if op == 2 else 1.0 / value if op == 3 else 1.0)
	file.close()
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	for i in range(3):
		print("[modifier-catalog-probe] ", ext.configure_modifiers(catalog, 16))
	ext = null
	quit()
