extends SceneTree

# 物种保底回归：小地图也必须让目录里的每个 bio.* 物种至少有一格占领，
# 否则依赖目击揭示的科技（芦苇收割 → 野生稻采集等）会整条线断掉。
# 同时验证同 seed 两次生成逐字节一致（保底阶梯是确定性的）。
# Headless:
#   godot --headless --path . --script res://tests/world/bio_coverage_guarantee_test.gd

const SIZES := [Vector2i(10, 8), Vector2i(14, 10)]
const SEED := 20260723

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	_expect("research catalog compiles", bool(catalog.get("ok", false)))
	var species_ids: PackedStringArray = _species_ids(catalog)
	_expect("catalog exposes bio species", species_ids.size() >= 20)
	for size in SIZES:
		var first: Dictionary = await _generate(size)
		_expect("%s world generated" % str(size), first.get("map", null) is MapData)
		if not (first.get("map", null) is MapData):
			continue
		var map: MapData = first.map
		var generator = first.get("generator", null)
		var initial_occupancy: PackedInt32Array = map.bio_occupancy_bits_arr.duplicate()
		var counts: PackedInt32Array = _species_counts(map, catalog)
		var missing := PackedStringArray()
		for species in range(mini(species_ids.size(), counts.size())):
			if int(counts[species]) > 0:
				continue
			missing.append(species_ids[species])
		_expect("%s every bio species occupies at least one cell" % str(size),
			missing.is_empty())
		if not missing.is_empty():
			print("  missing on %s: %s" % [str(size), str(missing)])
		_expect("%s never stacks more than three species per cell" % str(size),
			_max_stack(map) <= 3)
		# 保底残存格可能在目录气候带外：再推进几日，persist 也不能把它们剔除。
		var survived := _species_counts_after_days(generator, map, 3)
		var extinct := PackedStringArray()
		for species in range(mini(species_ids.size(), survived.size())):
			if int(survived[species]) > 0:
				continue
			extinct.append(species_ids[species])
		_expect("%s guarantee relicts survive three daily persist passes" % str(size),
			extinct.is_empty())
		if not extinct.is_empty():
			print("  extinct after 3 days on %s: %s" % [str(size), str(extinct)])
		# 同 seed 再生成一次，占领位集必须逐字节一致。
		var second: Dictionary = await _generate(size)
		var repeat_ok := second.get("map", null) is MapData \
			and (second.map as MapData).bio_occupancy_bits_arr == initial_occupancy
		_expect("%s occupancy is deterministic for one seed" % str(size), repeat_ok)
	print("=== bio coverage guarantee: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _generate(size: Vector2i) -> Dictionary:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var cfg := MapConfig.make(size.x, size.y)
	cfg.seed = SEED
	cfg.num_continents = 1
	cfg.sea_level = 0.45
	cfg.continent_size = 0.82
	cfg.climate_profile = profile
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = await generator.generate(cfg, 30.0)
	generated["generator"] = generator
	return generated


## 用生成期 knobs（含 realize_bounds 写回的地图本地气候边界）跑若干天日推进，
## 返回每物种剩余占领格数：保底残存格不得被 persist 剔除。
func _species_counts_after_days(generator, map: MapData, days: int) -> PackedInt32Array:
	var ext = generator._data_core_world_ext
	var tg = generator._get_terrain_generator()
	var knobs: Dictionary = tg._bio_occupancy_base_knobs(map)
	if not bool(knobs.get("ok", false)) or ext == null:
		return PackedInt32Array()
	knobs["province_ids"] = map.province_id_arr
	knobs["landmass_ids"] = map.landmass_id_arr
	knobs["explored"] = map.explored_arr
	var occupancy: PackedInt32Array = map.bio_occupancy_bits_arr
	for day in range(days):
		knobs["occupancy_bits"] = occupancy
		knobs["day_index"] = day + 1
		knobs["run_diffusion"] = false
		var result: Dictionary = ext.run_bio_occupancy_pass(knobs)
		if not bool(result.get("ok", false)):
			return PackedInt32Array()
		occupancy = result.get("occupancy_bits", occupancy)
	map.bio_occupancy_bits_arr = occupancy
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	return _species_counts(map, catalog)


static func _species_ids(catalog: Dictionary) -> PackedStringArray:
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var kinds: PackedInt32Array = catalog.get("research_signal_kinds", PackedInt32Array())
	var bits: PackedInt32Array = catalog.get("research_signal_occupancy_bit", PackedInt32Array())
	var out := PackedStringArray()
	for index in range(mini(ids.size(), mini(kinds.size(), bits.size()))):
		if int(kinds[index]) != ResearchSignalDefinition.Kind.BIO:
			continue
		if int(bits[index]) < 0:
			continue
		out.append(String(ids[index]))
	return out


static func _species_counts(map: MapData, catalog: Dictionary) -> PackedInt32Array:
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var kinds: PackedInt32Array = catalog.get("research_signal_kinds", PackedInt32Array())
	var bits: PackedInt32Array = catalog.get("research_signal_occupancy_bit", PackedInt32Array())
	var counts := PackedInt32Array()
	for index in range(mini(ids.size(), mini(kinds.size(), bits.size()))):
		if int(kinds[index]) != ResearchSignalDefinition.Kind.BIO:
			continue
		var bit := int(bits[index])
		if bit < 0:
			continue
		var total := 0
		for cell in range(map.bio_occupancy_bits_arr.size()):
			if (int(map.bio_occupancy_bits_arr[cell]) & (1 << bit)) != 0:
				total += 1
		counts.append(total)
	return counts


static func _max_stack(map: MapData) -> int:
	var worst := 0
	for cell in range(map.bio_occupancy_bits_arr.size()):
		var bits := int(map.bio_occupancy_bits_arr[cell])
		var count := 0
		while bits != 0:
			bits &= bits - 1
			count += 1
		worst = maxi(worst, count)
	return worst


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
