extends SceneTree

func _init() -> void:
	var catalog: Dictionary = load("res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	catalog.erase("ok")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(6400)
	var scalar := PackedFloat32Array()
	scalar.resize(6400)
	scalar.fill(0.5)
	for name in ["cell_temp", "cell_temp_30d", "cell_moisture", "cell_plant_available_water", "cell_weather_precip", "cell_snow_cover", "cell_weather_intensity", "cell_elevation"]:
		ext.write_f32_range(ext.register_component(name, 0, 1, false), 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(6400)
	for name in ["cell_terrain", "cell_landform", "cell_vegetation", "cell_is_water", "cell_has_river"]:
		terrain.fill(2 if name == "cell_terrain" else 0)
		ext.write_u8_range(ext.register_component(name, 2, 1, false), 0, terrain)
	var zeros := scalar.duplicate()
	zeros.fill(0.0)
	for name in catalog.building_resource_reserve_slots:
		ext.write_f32_range(ext.register_component(name, 0, 1, false), 0, zeros)
	for name in catalog.building_resource_extra_slots:
		ext.write_f32_range(ext.register_component(name, 0, 1, false), 0, zeros)
	var modifiers: Dictionary = load("res://scripts/modifier/modifier_catalog.gd").load_default().compile_native_catalog()
	modifiers.erase("ok")
	print("modifiers ", ext.configure_modifiers(modifiers, 6400))
	var seed_value := 172763467
	print("country config ", ext.configure_country(catalog, {"country_runtime_mode": "ACTIVE"}, 6400, seed_value))
	print("country begin ", ext.begin_country_restore())
	print("country feed ", ext.feed_country_restore_chunk(FileAccess.get_file_as_bytes("F:/Developent/Godot/Project.Keynes/tmp/runtime_snapshots_economy_fatal_20261016_021032/country.pkcn")))
	print("country end ", ext.end_country_restore())
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	print("economy config ", ext.configure_economy(catalog, profile, 6400, seed_value))
	print("economy begin ", ext.begin_economy_restore())
	var bytes := FileAccess.get_file_as_bytes("F:/Developent/Godot/Project.Keynes/tmp/runtime_snapshots_economy_fatal_20261016_021032/economy.pkec")
	var cursor := 0
	while cursor < bytes.size():
		var length := bytes.decode_u32(cursor + 12) + 16
		var chunk := bytes.slice(cursor, cursor + length)
		# Diagnostic candidate only: never write this stream back to a save.
		if chunk.decode_u16(6) == 5:
			var row := 16
			for index in range(chunk.decode_u32(8)):
				var type_id := chunk.decode_s32(row + 4)
				var units := chunk.decode_s64(row + 12)
				var roles := chunk.decode_s32(row + 327)
				var offsets: PackedInt32Array = catalog.building_employee_offsets
				var slots: PackedInt64Array = catalog.building_employee_slots
				for role in range(roles):
					var at := row + 331 + role * 72
					var filled := chunk.decode_s64(at)
					var cap := units * slots[offsets[type_id] + role]
					if filled > cap:
						print("diagnostic role clip cell=", chunk.decode_s32(row), " type=", type_id, " filled=", filled, " cap=", cap)
						chunk.encode_s64(at, cap)
				row += 331 + roles * 72
		var result: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not result.get("ok", false):
			print("feed rejected ", cursor, " ", result)
			quit(1)
			return
		cursor += length
	var ended: Dictionary = ext.end_economy_restore()
	print("economy end ", ended)
	if ended.get("ok", false):
		for day in range(10315, 10616):
			for pulse in range(20000):
				var report: Dictionary = ext.run_economy_slice({"day_index": day, "slice_budget_ms": 1000.0, "cohort_budget": 100000})
				if report.get("fatal", false):
					print("diagnostic fatal ", report.get("fatal_reason"), " day=", day)
					print(ext.get_economy_report())
					quit(2)
					return
				if report.get("done", false):
					print("diagnostic day ", day, " done")
					break
	ext = null
	quit()
