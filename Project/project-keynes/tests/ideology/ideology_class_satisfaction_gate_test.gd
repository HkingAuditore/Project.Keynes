extends SceneTree

## End-to-end acceptance for relaxed ideology support gates + dual-layer
## political-class cohort satisfaction buffs (persistent attitude + 180-day
## enactment shock).

const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _checks := 0
var _failures := 0
var _sequence := 1


func _init() -> void:
	_run()
	print("ideology class satisfaction gate: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
		return
	_failures += 1
	printerr("  [FAIL] %s%s" % [label, "" if detail.is_empty() else " -- " + detail])


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var native_economy := compiled.duplicate(true)
	native_economy.erase("ok")

	var modifier_catalog: Resource = ModifierCatalogScript.load_default()
	var native_modifier: Dictionary = modifier_catalog.compile_native_catalog()
	_expect("modifier catalog compiles", bool(native_modifier.get("ok", false)))
	if not bool(native_modifier.get("ok", false)):
		return

	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var native_ideology: Dictionary = ideology_catalog.compile_native_catalog(
		native_economy, native_economy)
	_expect("ideology catalog compiles", bool(native_ideology.get("ok", false)))
	if not bool(native_ideology.get("ok", false)):
		return

	var view: Dictionary = ideology_catalog.catalog_view(
		native_economy, native_economy)
	var free_exchange_view: Dictionary = {}
	for row in view.get("ideologies", []):
		if String(row.get("id", "")) == "idea.free_exchange":
			free_exchange_view = row
			break
	_expect("free_exchange appears in catalog view", not free_exchange_view.is_empty())
	var l1_lines: PackedStringArray = PackedStringArray()
	var levels_view: Array = free_exchange_view.get("level_effect_lines", [])
	if not levels_view.is_empty():
		l1_lines = levels_view[0]
	var joined_l1 := "\n".join(l1_lines)
	_expect("free_exchange L1 view presents persistent farmer satisfaction debuff",
		joined_l1.find("农民阶层满意度降低 1 点") >= 0, joined_l1)
	_expect("free_exchange L1 view presents 180-day enactment shock",
		joined_l1.find("首次推行冲击（持续 180 天）") >= 0
		and joined_l1.find("农民阶层满意度降低 3 点") >= 0, joined_l1)

	var ext := _new_ext(native_economy)
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, native_economy, 1, 20260818))
	var modifier := ModifierFacadeScript.new()
	_expect("modifier configures", bool(modifier.configure(ext, 1).get("ok", false)))

	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	_expect("economy configures", bool(ext.configure_economy(
		native_economy, profile, 1, 20260818).get("ok", false)))

	var signatures: PackedStringArray = compiled.signature_keys
	var hunter_sig := signatures.find("hunter|default")
	var sharecropper_sig := signatures.find("sharecropper|default")
	var worker_sig := signatures.find("corvee_worker|default")
	var scholar_sig := signatures.find("scholar|default")
	_expect("farmer and scholar signatures exist",
		hunter_sig >= 0 and sharecropper_sig >= 0 and worker_sig >= 0 and scholar_sig >= 0)
	if hunter_sig < 0 or sharecropper_sig < 0 or worker_sig < 0 or scholar_sig < 0:
		return

	# Bootstrap a heavily farmer-majority country so free_exchange has negative
	# weighted support, reproducing the early-game situation that previously
	# hard-blocked enactment.
	_expect("population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([hunter_sig, sharecropper_sig, worker_sig, scholar_sig]),
		"population": PackedInt64Array([180, 180, 20, 20]),
		"funds": PackedInt64Array([0, 0, 0, 0]),
	}, {}).get("ok", false)))
	_expect("economy COMMIT publishes farmer-majority opinion",
		bool(_run_economy(ext, 0).get("done", false)))

	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_expect("effect catalog builds", effect_catalog != null)
	if effect_catalog == null:
		return
	var effect_ir: Dictionary = effect_catalog.compile_native_catalog()
	_expect("effect configures", bool(ext.configure_effects(effect_ir).get("ok", false)))

	var ideology_ir := native_ideology.duplicate(true)
	ideology_ir.erase("ok")
	_expect("ideology configures", bool(ext.configure_ideologies(ideology_ir).get("ok", false)))

	var handle := int(ext.get_country_cell_summary(0).country_handle)
	var ideology_ids: PackedStringArray = native_ideology.ideology_ids
	var exchange_id := ideology_ids.find("idea.free_exchange")
	_expect("free_exchange id resolves", exchange_id >= 0)

	_expect("free_exchange discovers", _submit(ext, 1, [
		{"opcode": 1, "idea": exchange_id},
	]) and _drain_ideology(ext, 1))

	var explain: Dictionary = ext.explain_ideologies(handle, PackedInt32Array([exchange_id]))
	var scores: PackedInt32Array = explain.get("support_q16", PackedInt32Array())
	var thresholds: PackedInt32Array = explain.get("support_thresholds_q16", PackedInt32Array())
	var blockers: PackedInt32Array = explain.get("support_blocking_classes", PackedInt32Array())
	var allowed_flags: PackedByteArray = explain.get("support_allowed", PackedByteArray())
	_expect("free_exchange has negative support score under farmer majority",
		scores.size() >= 1 and int(scores[0]) < 0,
		"scores=%s opinion=%s" % [str(scores), str(ext.get_country_class_opinion_snapshot())])
	_expect("free_exchange has relaxed adopt threshold (-0.50)",
		thresholds.size() >= 1 and int(thresholds[0]) == -32768, str(thresholds))
	_expect("free_exchange has no critical-class veto blocker",
		blockers.size() >= 1 and int(blockers[0]) == -1, str(blockers))
	_expect("free_exchange is allowed despite negative support",
		allowed_flags.size() >= 1 and int(allowed_flags[0]) == 1, str(allowed_flags))
	var adopt_stances: PackedInt32Array = explain.get("adopt_stances_q16", PackedInt32Array())
	var total_inf := int(explain.get("total_influence", 0))
	_expect("explain_ideologies exposes per-class adopt stances and total influence",
		adopt_stances.size() == 3 and total_inf >= 380,
		"stances=%s total_inf=%d" % [str(adopt_stances), total_inf])

	# Enact free_exchange on day 2 and commit Effect -> Modifier.
	_expect("free_exchange equip starts transition", _submit(ext, 2, [
		{"opcode": 5, "idea": exchange_id},
	]) and _drain_ideology(ext, 2))
	_expect("free_exchange transition commits", _commit_effect(ext, 2) and _drain_ideology(ext, 3))

	var farmer_stat_key := "economy.class.farmer.satisfaction_bp"
	var tech_stat_key := "economy.class.technology.satisfaction_bp"
	var general_stat_key := "economy.class.general.satisfaction_bp"
	_expect("class satisfaction stat ids resolve",
		_stat_id(native_modifier, farmer_stat_key) >= 0
		and _stat_id(native_modifier, tech_stat_key) >= 0
		and _stat_id(native_modifier, general_stat_key) >= 0)

	var farmer_day3 := float(ext.evaluate_modifier_stat(1, handle, 0, farmer_stat_key, 0.0))
	var tech_day3 := float(ext.evaluate_modifier_stat(1, handle, 0, tech_stat_key, 0.0))
	var general_day3 := float(ext.evaluate_modifier_stat(1, handle, 0, general_stat_key, 0.0))
	_expect("on enactment day, farmer class gets persistent (-100) + 180d shock (-300) = -400 bp",
		is_equal_approx(farmer_day3, -400.0), str(farmer_day3))
	_expect("on enactment day, technology class gets persistent (+200) + 180d shock (+600) = +800 bp",
		is_equal_approx(tech_day3, 800.0), str(tech_day3))
	_expect("on enactment day, general class gets persistent (+100) + 180d shock (+300) = +400 bp",
		is_equal_approx(general_day3, 400.0), str(general_day3))

	# Verify NativeEconomyRuntime freezes the class bias into per-profession epoch table.
	_expect("economy runs day 3 epoch", bool(_run_economy(ext, 3).get("done", false)))
	var prof_report: Dictionary = ext.get_epoch_profession_report(0)
	var prof_ids: PackedStringArray = native_economy.profession_ids
	var farmer_prof := prof_ids.find("subsistence_farmer")
	var scholar_prof := prof_ids.find("scholar")
	var frozen_sat: PackedInt64Array = prof_report.get("satisfaction_bp", PackedInt64Array())
	_expect("frozen economy epoch carries -400 bp for subsistence_farmer",
		farmer_prof >= 0 and farmer_prof < frozen_sat.size()
		and int(frozen_sat[farmer_prof]) == -400, str(frozen_sat))
	_expect("frozen economy epoch carries +800 bp for scholar",
		scholar_prof >= 0 and scholar_prof < frozen_sat.size()
		and int(frozen_sat[scholar_prof]) == 800, str(frozen_sat))

	# Advance past 180 days so the timed shock expires while persistent attitude remains.
	ext.run_modifier_daily(200)
	var farmer_day200 := float(ext.evaluate_modifier_stat(1, handle, 0, farmer_stat_key, 0.0))
	var tech_day200 := float(ext.evaluate_modifier_stat(1, handle, 0, tech_stat_key, 0.0))
	var general_day200 := float(ext.evaluate_modifier_stat(1, handle, 0, general_stat_key, 0.0))
	_expect("after 180 days, farmer class keeps only persistent -100 bp",
		is_equal_approx(farmer_day200, -100.0), str(farmer_day200))
	_expect("after 180 days, technology class keeps only persistent +200 bp",
		is_equal_approx(tech_day200, 200.0), str(tech_day200))
	_expect("after 180 days, general class keeps only persistent +100 bp",
		is_equal_approx(general_day200, 100.0), str(general_day200))

	# Repeal free_exchange: persistent attitude is removed cleanly.
	_expect("free_exchange repeal starts transition", _submit(ext, 201, [
		{"opcode": 6, "idea": exchange_id},
	]) and _drain_ideology(ext, 201))
	_expect("free_exchange repeal commits", _commit_effect(ext, 201) and _drain_ideology(ext, 202))
	var farmer_repeal := float(ext.evaluate_modifier_stat(1, handle, 0, farmer_stat_key, 0.0))
	var tech_repeal := float(ext.evaluate_modifier_stat(1, handle, 0, tech_stat_key, 0.0))
	_expect("after repeal, farmer and technology class satisfaction biases return to 0",
		is_equal_approx(farmer_repeal, 0.0) and is_equal_approx(tech_repeal, 0.0),
		"farmer=%s tech=%s" % [str(farmer_repeal), str(tech_repeal)])

	# Re-enact free_exchange: persistent attitude returns, but 180-day shock does NOT re-fire.
	_expect("free_exchange re-enact starts transition", _submit(ext, 203, [
		{"opcode": 5, "idea": exchange_id},
	]) and _drain_ideology(ext, 203))
	_expect("free_exchange re-enact commits", _commit_effect(ext, 203) and _drain_ideology(ext, 204))
	var farmer_reenact := float(ext.evaluate_modifier_stat(1, handle, 0, farmer_stat_key, 0.0))
	var tech_reenact := float(ext.evaluate_modifier_stat(1, handle, 0, tech_stat_key, 0.0))
	_expect("re-enacting applies persistent attitude without re-triggering 180d shock",
		is_equal_approx(farmer_reenact, -100.0) and is_equal_approx(tech_reenact, 200.0),
		"farmer=%s tech=%s" % [str(farmer_reenact), str(tech_reenact)])


func _stat_id(native_modifier: Dictionary, key: String) -> int:
	var keys: PackedStringArray = native_modifier.get("stat_keys", PackedStringArray())
	return keys.find(key)


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
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
