extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("聚居地目录可编译", bool(compiled.get("ok", false)))
	if bool(compiled.get("ok", false)) and ClassDB.class_exists("DCWorldExt"):
		_run_runtime_checks(compiled)
	print("=== settlement runtime %s: checks=%d failures=%d ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run_runtime_checks(compiled: Dictionary) -> void:
	var populations := PackedInt64Array(
		[0, 1, 100, 500, 2500, 12500, 62500, 312500])
	var source: Object = _configured_world(compiled, populations, 7401)
	if source == null:
		return
	var expected := PackedStringArray([
		"wilderness", "settlement", "rural", "town",
		"county_seat", "city", "metropolis", "megacity"])
	var names := {}
	for cell in range(populations.size()):
		var summary: Dictionary = source.get_population_cell_summary(cell)
		_expect("边界等级 %d" % cell,
			String(summary.get("prosperity_id", "")) == expected[cell])
		if cell >= 2:
			var visible_name := String(summary.get("settlement_name", ""))
			_expect("乡村以上有名 %d" % cell,
				bool(summary.get("settlement_name_active", false)) and
				not visible_name.is_empty())
			_expect("活跃地名世界唯一 %d" % cell, not names.has(visible_name))
			names[visible_name] = true
	var snapshot: Dictionary = source.get_named_settlement_snapshot()
	_expect("完整快照只含有名聚居地",
		bool(snapshot.get("full_snapshot", false)) and
		(snapshot.get("cell_indices", PackedInt32Array()) as PackedInt32Array).size() == 6)
	var replay: Object = _configured_world(compiled, populations, 7401)
	_expect("同种子重放状态哈希一致",
		replay != null and source.get_economy_state_hash() ==
			replay.get_economy_state_hash())
	var exhaustion_populations := PackedInt64Array()
	exhaustion_populations.resize(4097)
	exhaustion_populations.fill(100)
	var exhausted: Object = _configured_world(
		compiled, exhaustion_populations, 7402)
	if exhausted != null:
		var exhausted_snapshot: Dictionary = exhausted.get_named_settlement_snapshot()
		var exhausted_names: PackedStringArray = exhausted_snapshot.get(
			"settlement_names", PackedStringArray())
		var unique_exhausted := {}
		var has_disambiguator := false
		for visible_name in exhausted_names:
			unique_exhausted[String(visible_name)] = true
			has_disambiguator = has_disambiguator or String(visible_name).contains("·")
		_expect("组合耗尽后仍保持世界唯一并追加序号",
			exhausted_names.size() == 4097 and
			unique_exhausted.size() == 4097 and has_disambiguator)

	var rural_before: Dictionary = source.get_population_cell_summary(2)
	var handle := int((source.get_population_cell_snapshot(2).get(
		"handles", PackedInt64Array()) as PackedInt64Array)[0])
	_submit_population_delta(source, handle, -10, 0, 1)
	_run_cycle(source, 0)
	var at_ninety: Dictionary = source.get_population_cell_summary(2)
	_expect("90 人保留乡村滞回",
		String(at_ninety.get("prosperity_id", "")) == "rural" and
		String(at_ninety.get("settlement_name", "")) ==
			String(rural_before.get("settlement_name", "")))
	_submit_population_delta(source, handle, -1, 5, 2)
	_run_cycle(source, 1)
	var at_eighty_nine: Dictionary = source.get_population_cell_summary(2)
	_expect("89 人降为聚落并释放地名",
		String(at_eighty_nine.get("prosperity_id", "")) == "settlement" and
		not bool(at_eighty_nine.get("settlement_name_active", true)) and
		int(at_eighty_nine.get("name_roll_generation", 0)) == 1)
	_submit_population_delta(source, handle, 11, 10, 3)
	_run_cycle(source, 2)
	var renamed: Dictionary = source.get_population_cell_summary(2)
	_expect("再次达到 100 人按新代次命名",
		String(renamed.get("prosperity_id", "")) == "rural" and
		bool(renamed.get("settlement_name_active", false)) and
		int(renamed.get("name_roll_generation", 0)) == 1)

	var chunks := _save_chunks(source)
	_expect("PKEC v24 可导出", not chunks.is_empty())
	var restored: Object = _configured_world(
		compiled, PackedInt64Array(), 7401, false)
	if restored != null and not chunks.is_empty():
		var begin: Dictionary = restored.begin_economy_restore()
		var restore_ok := bool(begin.get("ok", false))
		for chunk in chunks:
			if not restore_ok:
				break
			restore_ok = bool(restored.feed_economy_restore_chunk(chunk).get(
				"ok", false))
		var ended: Dictionary = restored.end_economy_restore() if restore_ok else {}
		_expect("PKEC v24 可往返恢复", bool(ended.get("ok", false)))
		_expect("PKEC v24 状态哈希一致",
			bool(ended.get("ok", false)) and
			restored.get_economy_state_hash() ==
				source.get_economy_state_hash())


func _configured_world(compiled: Dictionary, populations: PackedInt64Array,
		seed: int, bootstrap: bool = true):
	var cells := maxi(1, populations.size())
	if not bootstrap:
		cells = 8
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover",
			&"cell_weather_intensity"]:
		var values := PackedFloat32Array()
		values.resize(cells)
		values.fill(0.5)
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, values)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	if not CountryTestHelper.configure_all_technologies(
			ext, catalog, cells, seed):
		_expect("国家运行时可配置", false)
		return null
	var profile = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.starvation_death_rate_q32 = 0
	if not bool(ext.configure_economy(
			catalog, profile, cells, seed).get("ok", false)):
		_expect("经济运行时可配置", false)
		return null
	if not bootstrap:
		return ext
	var worker_signature := (catalog.signature_keys as PackedStringArray).find(
		"worker|default")
	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var nonzero_populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(populations.size()):
		if populations[cell] <= 0:
			continue
		cell_indices.append(cell)
		signature_ids.append(worker_signature)
		nonzero_populations.append(populations[cell])
		funds.append(0)
	if not bool(ext.bootstrap_economy({
			"cell_indices": cell_indices,
			"signature_ids": signature_ids,
			"population": nonzero_populations,
			"funds": funds,
		}, {}).get("ok", false)):
		_expect("人口可初始化", false)
		return null
	return ext


func _submit_population_delta(ext: Object, handle: int, amount: int,
		effective_day: int, sequence: int) -> void:
	var result: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([6]),
		"effective_days": PackedInt64Array([effective_day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([amount]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("人口变更命令已接收", bool(result.get("ok", false)))


func _run_cycle(ext: Object, cycle: int) -> void:
	for slice in range(512):
		var report: Dictionary = ext.run_economy_slice({
			"day_index": cycle * 5,
			"tick_index": slice,
		})
		if bool(report.get("done", false)):
			return
	_expect("经济周期可提交", false)


func _save_chunks(ext: Object) -> Array[PackedByteArray]:
	var chunks: Array[PackedByteArray] = []
	if not bool(ext.begin_economy_save(65536).get("ok", false)):
		return chunks
	for guard in range(10000):
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
		if int(chunk.decode_u16(6)) == 15:
			break
	if not bool(ext.end_economy_save().get("ok", false)):
		chunks.clear()
	return chunks


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
