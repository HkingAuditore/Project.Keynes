extends SceneTree

const CountryTestHelper = preload("res://tests/country_test_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _checks := 0
var _failures := 0
var _sequence := 1


func _init() -> void:
	_run()
	print("ideology opinion/synergy: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var ext := _new_ext(native_catalog)
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, native_catalog, 1, 20260818))
	var modifier := ModifierFacadeScript.new()
	_expect("modifier configures",
		bool(modifier.configure(ext, 1).get("ok", false)))
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	_expect("economy configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 20260818).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	var selected := PackedInt32Array([
		signatures.find("hunter|default"),
		signatures.find("sharecropper|default"),
		signatures.find("corvee_worker|default"),
		signatures.find("scholar|default"),
	])
	_expect("four political-class signatures exist", selected.find(-1) == -1)
	_expect("population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": selected,
		"population": PackedInt64Array([100, 100, 100, 100]),
		"funds": PackedInt64Array([0, 0, 0, 0]),
	}, {}).get("ok", false)))
	var economy_report := _run_economy(ext, 0)
	var economy_diagnostics: Dictionary = ext.get_economy_report()
	_expect("economy COMMIT publishes class opinion",
		bool(economy_report.get("done", false))
		and int(economy_diagnostics.get("class_opinion_last_cells_scanned", 0)) == 1
		and int(economy_diagnostics.get("class_opinion_last_slots_scanned", 0)) >= 4)
	var class_snapshot: Dictionary = ext.get_country_class_opinion_snapshot()
	_expect("class snapshot has one country and four nonzero rows",
		int(class_snapshot.get("revision", 0)) > 0
		and int(class_snapshot.get("country_count", 0)) == 1
		and _positive_count(class_snapshot.get(
			"population", PackedInt64Array())) == 4)

	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_expect("Effect domain catalog builds", effect_catalog != null)
	if effect_catalog == null:
		return
	_expect("Effect runtime configures", bool(ext.configure_effects(
		effect_catalog.compile_native_catalog()).get("ok", false)))
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
		native_catalog, native_catalog)
	_expect("ideology content compiles", bool(ideology_ir.get("ok", false)))
	if not bool(ideology_ir.get("ok", false)):
		return
	var ideology_ids: PackedStringArray = ideology_ir.ideology_ids
	var collective := ideology_ids.find("idea.collective_stewardship")
	var exchange := ideology_ids.find("idea.free_exchange")
	var scholar := ideology_ids.find("idea.scholar_office")
	var runtime_ir := ideology_ir.duplicate(true)
	runtime_ir.erase("ok")
	_expect("ideology runtime configures",
		bool(ext.configure_ideologies(runtime_ir).get("ok", false)))
	var handle := int(ext.get_country_cell_summary(0).country_handle)
	_expect("opinion country handle exists", handle != 0)
	_expect("test ideologies discover", _submit(ext, 1, [
		{"opcode": 1, "idea": collective},
		{"opcode": 1, "idea": exchange},
		{"opcode": 1, "idea": scholar},
	]) and _drain_ideology(ext, 1))

	var explain: Dictionary = ext.explain_ideologies(
		handle, PackedInt32Array([collective, exchange, scholar]))
	var rows := _explain_rows(explain)
	_expect("collective adoption passes positive support",
		bool(rows[collective].support[0].allowed)
		and int(rows[collective].support[0].support_q16)
			>= int(rows[collective].support[0].threshold_q16))
	var farmer_index := (ideology_ir.political_class_ids as PackedStringArray).find(
		"farmer")
	_expect("free exchange is blocked by its critical farmer class",
		not bool(rows[exchange].support[0].allowed)
		and int(rows[exchange].support[0].blocking_class) == farmer_index)
	_expect("directional thresholds differ for scholar adoption/promotion",
		bool(rows[scholar].support[0].allowed)
		and not bool(rows[scholar].support[2].allowed))

	_expect("collective equip starts one atomic transition",
		_submit(ext, 2, [{"opcode": 5, "idea": collective}])
		and _drain_ideology(ext, 2)
		and int(ext.get_effect_report().get("pending_transactions", 0)) == 1)
	_expect("collective transition commits", _commit_effect(ext, 2)
		and _drain_ideology(ext, 3))
	explain = ext.explain_ideologies(
		handle, PackedInt32Array([collective, exchange, scholar]))
	rows = _explain_rows(explain)
	_expect("exclusive free-exchange equip becomes unavailable",
		not bool(rows[exchange].exclusion_allowed)
		and not bool(rows[exchange].equip_allowed))
	_expect("inactive promotion is rejected", _submit(ext, 3, [
		{"opcode": 7, "idea": exchange},
	]) and _drain_ideology(ext, 3)
		and _latest_reason(ext) == "ideology_promotion_requires_equipped")

	_expect("scholar equip starts base plus synergy in one transaction",
		_submit(ext, 4, [{"opcode": 5, "idea": scholar}])
		and _drain_ideology(ext, 4)
		and int(ext.get_effect_report().get("pending_transactions", 0)) == 1)
	_expect("synergy transaction commits", _commit_effect(ext, 4)
		and _drain_ideology(ext, 5))
	explain = ext.explain_ideologies(
		handle, PackedInt32Array([collective, scholar]))
	rows = _explain_rows(explain)
	_expect("reverse-CSR synergy is active for both member explanations",
		_has_active_synergy(rows[collective])
		and _has_active_synergy(rows[scholar]))


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var slot: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(slot, 0, PackedByteArray([0]))
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for index in reserve_slots.size():
		var reserve: int = ext.register_component(
			StringName(reserve_slots[index]), 0, 1, false)
		var extra: int = ext.register_component(
			StringName(extra_slots[index]), 0, 1, false)
		ext.write_f32_range(reserve, 0, PackedFloat32Array([1000000.0]))
		ext.write_f32_range(extra, 0, PackedFloat32Array([0.0]))
	return ext


func _run_economy(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in 512:
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _submit(ext: Object, day: int, rows: Array[Dictionary]) -> bool:
	var handle := int(ext.get_country_cell_summary(0).country_handle)
	var batch := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"producer_ids": PackedInt32Array(),
		"source_priorities": PackedInt32Array(),
		"sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(),
		"ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(),
		"offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(),
		"gate_ids": PackedInt32Array(),
	}
	for row in rows:
		batch.opcodes.append(int(row.opcode))
		batch.effective_days.append(day)
		batch.producer_ids.append(1)
		batch.source_priorities.append(0)
		batch.sequences.append(_sequence)
		_sequence += 1
		batch.country_handles.append(handle)
		batch.ideology_ids.append(int(row.get("idea", -1)))
		batch.values_q16.append(0)
		batch.offer_generations.append(0)
		batch.choice_indices.append(-1)
		batch.gate_ids.append(-1)
	return bool(ext.submit_ideology_commands(batch).get("ok", false))


func _drain_ideology(ext: Object, day: int) -> bool:
	for _slice in 128:
		var report: Dictionary = ext.run_ideology_daily(day)
		if not bool(report.get("ok", false)):
			return false
		if bool(report.get("done", false)):
			return true
	return false


func _commit_effect(ext: Object, day: int) -> bool:
	for _slice in 128:
		var report: Dictionary = ext.run_effect_daily(day)
		if not bool(report.get("ok", false)):
			return false
		if bool(report.get("done", false)):
			break
	var dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	if not bool(dispatch.get("ok", false)) \
			or int(dispatch.get("submitted_transactions", 0)) != 1:
		return false
	if not bool(ext.run_modifier_daily(day).get("ok", false)):
		return false
	return bool(ext.ack_effect_native_modifier().get("ok", false))


func _explain_rows(explain: Dictionary) -> Dictionary:
	var out := {}
	var ids: PackedInt32Array = explain.get("ideology_ids", PackedInt32Array())
	var support: PackedInt32Array = explain.get("support_q16", PackedInt32Array())
	var thresholds: PackedInt32Array = explain.get(
		"support_thresholds_q16", PackedInt32Array())
	var blockers: PackedInt32Array = explain.get(
		"support_blocking_classes", PackedInt32Array())
	var allowed: PackedByteArray = explain.get(
		"support_allowed", PackedByteArray())
	var exclusion: PackedByteArray = explain.get(
		"exclusion_allowed", PackedByteArray())
	var equip: PackedByteArray = explain.get(
		"equip_allowed", PackedByteArray())
	var synergy_offsets: PackedInt32Array = explain.get(
		"affected_synergy_offsets", PackedInt32Array())
	var synergy_active: PackedByteArray = explain.get(
		"current_synergy_active", PackedByteArray())
	for index in ids.size():
		var support_rows: Array[Dictionary] = []
		for direction in 3:
			var row := index * 3 + direction
			support_rows.append({
				"support_q16": int(support[row]),
				"threshold_q16": int(thresholds[row]),
				"blocking_class": int(blockers[row]),
				"allowed": allowed[row] != 0,
			})
		var active := PackedByteArray()
		for row in range(int(synergy_offsets[index]),
				int(synergy_offsets[index + 1])):
			active.append(synergy_active[row])
		out[int(ids[index])] = {
			"support": support_rows,
			"exclusion_allowed": exclusion[index] != 0,
			"equip_allowed": equip[index] != 0,
			"synergy_active": active,
		}
	return out


func _has_active_synergy(row: Dictionary) -> bool:
	for active in row.get("synergy_active", PackedByteArray()):
		if active != 0:
			return true
	return false


func _latest_reason(ext: Object) -> String:
	var receipts: Dictionary = ext.poll_ideology_receipts(0, 128)
	var reasons: PackedStringArray = receipts.get("reasons", PackedStringArray())
	return String(reasons[-1]) if not reasons.is_empty() else ""


func _positive_count(values: PackedInt64Array) -> int:
	var count := 0
	for value in values:
		if value > 0:
			count += 1
	return count


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
