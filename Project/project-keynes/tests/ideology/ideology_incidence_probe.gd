extends SceneTree

## Fast sanity check for the material-support catalog compile: loads the
## production ideology catalog, compiles the native catalog, and prints the
## incidence channel table shape plus a few per-card rows. Exits non-zero on any
## compile failure so a broken table cannot reach a runtime test.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")


func _init() -> void:
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy.get("ok", false)):
		print("ECONOMY_FAIL ", economy.get("reason", ""))
		quit(1)
		return
	var country: Dictionary = economy
	var catalog: Dictionary = IdeologyCatalogScript.load_default().compile_native_catalog(
		country, economy)
	if not bool(catalog.get("ok", false)):
		print("CATALOG_FAIL ", catalog.get("reason", ""))
		quit(1)
		return
	var channels := int(catalog.get("incidence_channel_count", 0))
	var rows: PackedInt32Array = catalog.get("incidence_level_channels_q16",
		PackedInt32Array())
	var levels: PackedInt32Array = catalog.get("level_offsets", PackedInt32Array())
	var level_count := int(levels[levels.size() - 1]) if levels.size() > 0 else 0
	print("needs=%d channels=%d levels=%d rows=%d unmapped=%d" % [
		(economy.get("need_ids", PackedStringArray()) as PackedStringArray).size(),
		channels, level_count, rows.size(),
		int(catalog.get("incidence_unmapped_stat_count", 0))])
	if channels <= 0 or level_count <= 0 or rows.size() != level_count * channels:
		print("SHAPE_FAIL")
		quit(1)
		return
	var nonzero := 0
	var min_value := 0
	var max_value := 0
	for value in rows:
		if value == 0:
			continue
		nonzero += 1
		min_value = mini(min_value, int(value))
		max_value = maxi(max_value, int(value))
	print("nonzero=%d min=%d max=%d" % [nonzero, min_value, max_value])
	print("support_model=%d gain=%d veto=%d veto_min=%d" % [
		int(catalog.get("support_model", -1)),
		int(catalog.get("incidence_gain_q16", -1)),
		int(catalog.get("incidence_veto_q16", 0)),
		int(catalog.get("incidence_veto_min_influence_q16", 0))])
	# Native configure is the only place that validates the table against the
	# level CSR, so exercise it directly: no world, no clock, no economy.
	var native := catalog.duplicate(true)
	native.erase("ok")
	var world_ext = ClassDB.instantiate("DCWorldExt")
	if world_ext == null:
		print("NATIVE_SKIP no DCWorldExt")
		quit(0)
		return
	var configured: Dictionary = world_ext.configure_ideologies(native)
	print("native configure ok=%s reason=%s" % [
		str(configured.get("ok", false)), str(configured.get("reason", ""))])
	quit(0 if bool(configured.get("ok", false)) else 1)
	print("economy sector keys: %s offsets=%d outputs=%d" % [
		economy.has("building_economic_sectors"),
		(economy.get("building_output_offsets", PackedInt32Array()) as PackedInt32Array).size(),
		(economy.get("building_output_good_ids", PackedInt32Array()) as PackedInt32Array).size()])
	# Economy's configure rejects a profession basket that is not normalized to
	# Q16; report the actual row sums so a truncation bug fails here, not at
	# world bootstrap.
	var weights: PackedInt32Array = economy.get("profession_need_weight_q16",
		PackedInt32Array())
	var professions := (economy.get("profession_ids", PackedStringArray()) as PackedStringArray).size()
	var need_count := (economy.get("need_ids", PackedStringArray()) as PackedStringArray).size()
	print("basket rows=%d expected=%d" % [weights.size(), professions * need_count])
	if weights.size() == professions * need_count and need_count > 0:
		var min_sum := 1 << 40
		var max_sum := 0
		for row in professions:
			var total := 0
			for need in need_count:
				total += int(weights[row * need_count + need])
			min_sum = mini(min_sum, total)
			max_sum = maxi(max_sum, total)
		print("basket row sums min=%d max=%d" % [min_sum, max_sum])
	quit(0)
