extends SceneTree

## X13a: climate derived/persistent columns through the real Economy commit path.
##
## T1 dry streak + dry-spell tag, T2 hazard mask + days since hazard, T3 annual
## temperature tags, and T4 schema-57 stream save/restore. Every measurement uses
## the production metric sampler and tag query; no metric override is involved.
## T5/T6 equip refrigeration / little_ice_age against hot/cold cells and restore
## the untouched base on unequip. T7 restores a scheme-57 stream whose six of
## twelve persisted counters are at least 365 days and verifies metric 88.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const CELLS := 12
const SEED := 20261024
const Q16_ONE := 65536
const MODIFIER_DOMAIN_ECONOMY := 2
const REFRIGERATION_FISH_STAT := "economy.city.good.fish.output_factor"
const LITTLE_ICE_AGE_OUTPUT_STAT := "economy.city.output_factor"
const METRIC_ANNUAL_TEMPERATURE := 70
const METRIC_DRY_STREAK := 71
const METRIC_HAZARD_TODAY := 72
const METRIC_DAYS_SINCE_HAZARD := 73
const METRIC_TEMPERATURE_ANOMALY := 74
const METRIC_HAZARD_FREE_CELL_SHARE := 88
const SEL_OWN_TERRITORY := 12
const TAG_COLD := "cell.climate.cold"
const TAG_HOT := "cell.climate.hot"
const TAG_DRY_SPELL := "cell.climate.dry_spell"

var _ext: Object
var _catalog: Dictionary
var _domain: Resource
var _ideology_catalog: Dictionary
var _handle := 0
var _checks := 0
var _failures := 0
var _day := 0
var _next_sequence := 1


func _init() -> void:
	_run()
	print("=== ideology x13a worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	_catalog = EconomyCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles", bool(_catalog.get("ok", false)),
			str(_catalog.get("reason", ""))):
		return
	_catalog.erase("ok")
	_domain = EffectDomainCatalogScript.build()
	if not _require("production Effect domain catalog builds", _domain != null):
		return
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if not _require("production ideology catalog loads", catalog != null):
		return
	_ideology_catalog = catalog.compile_native_catalog(_catalog, _catalog)
	if not _require("production ideology catalog compiles",
			bool(_ideology_catalog.get("ok", false)),
			str(_ideology_catalog.get("reason", ""))):
		return
	_ext = _build_ext()
	if _ext == null:
		return
	if not _test_t1_dry_streak():
		return
	if not _test_t2_hazard():
		return
	if not _test_t3_annual_temperature():
		return
	if not _test_t4_save_restore():
		return
	if not _test_t7_hazard_free_cell_share():
		return
	_test_t5_refrigeration_card()
	_test_t6_little_ice_age_card()


func _build_ext() -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	var scalar := _f32_fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation",
			&"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type",
			&"cell_cover"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, _u8_fill(2 if slot_name == &"cell_terrain" else 0))
	for i in range((_catalog.building_resource_ids as PackedStringArray).size()):
		var reserve: int = ext.register_component(StringName(
			(_catalog.building_resource_reserve_slots as PackedStringArray)[i]),
			0, 1, false)
		var extra: int = ext.register_component(StringName(
			(_catalog.building_resource_extra_slots as PackedStringArray)[i]),
			0, 1, false)
		ext.write_f32_range(reserve, 0, _f32_fill(1000000.0))
		ext.write_f32_range(extra, 0, _f32_fill(0.0))
	if not _require("country configures", bool(ext.configure_country(_catalog, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": PackedStringArray(["tech.hunting"]),
		}, CELLS, SEED).get("ok", false))):
		return null
	var cells := PackedInt32Array()
	for cell in range(CELLS):
		cells.append(cell)
	if not _require("country bootstraps", bool(ext.bootstrap_country({
			"country_ids": PackedStringArray(["country.x13a"]),
			"country_names": PackedStringArray(["X13a"]),
			"country_cash": PackedInt64Array([0]),
			"territory_offsets": PackedInt32Array([0, CELLS]),
			"territory_cells": cells,
			"technology_offsets": PackedInt32Array([0, 0]),
			"technology_indices": PackedInt32Array(),
			"treasury_offsets": PackedInt32Array([0, 0]),
			"treasury_good_indices": PackedInt32Array(),
			"treasury_quantities": PackedInt64Array(),
		}, _u8_fill(0)).get("ok", false))):
		return null
	var modifiers: Dictionary = preload(
		"res://scripts/modifier/modifier_catalog.gd").load_default().compile_native_catalog()
	if not _require("modifier configures", bool(modifiers.get("ok", false)),
			str(modifiers.get("reason", ""))):
		return null
	modifiers.erase("ok")
	if not _require("modifier runtime configures",
			bool(ext.configure_modifiers(modifiers, CELLS).get("ok", false))):
		return null
	var effects: Dictionary = _domain.compile_native_catalog()
	if not _require("Effect catalog compiles", bool(effects.get("ok", false)),
			str(effects.get("reason", ""))):
		return null
	effects.erase("ok")
	var effect_configured: Dictionary = ext.configure_effects(effects)
	if not _require("Effect runtime configures",
			bool(effect_configured.get("ok", false)), str(effect_configured)):
		return null
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	if not _require("economy configures", bool(ext.configure_economy(
			_catalog, profile, CELLS, SEED).get("ok", false))):
		return null
	var signature: int = (_catalog.signature_keys as PackedStringArray).find(
		"hunter|default")
	if not _require("hunter signature exists", signature >= 0):
		return null
	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(CELLS):
		cell_indices.append(cell)
		signature_ids.append(signature)
		populations.append(120)
		funds.append(1000)
	if not _require("economy bootstraps", bool(ext.bootstrap_economy({
			"cell_indices": cell_indices, "signature_ids": signature_ids,
			"population": populations, "funds": funds,
		}, {}).get("ok", false))):
		return null
	# Cell target selection resolves the anchor through Economy, so this must
	# follow configure_economy (the production card fixture documents the same
	# ordering contract).
	if not _require("ideology runtime configures",
			bool(ext.configure_ideologies(_ideology_catalog).get("ok", false))):
		return null
	if not _require("country snapshot captures",
			bool(ext.capture_country_runtime_snapshot().get("ok", false))
			and bool(ext.capture_country_pod_catalog().get("ok", false))):
		return null
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("fixture resolves the country handle", handle != 0):
		return null
	_handle = handle
	return ext


## T1: no rain for 25 days; the dry-spell tag appears on day 20. A real rain
## event on the next day resets the counter and clears the tag.
func _test_t1_dry_streak() -> bool:
	_set_precipitation(0.0)
	for _index in range(19):
		if not _run_day():
			return false
	var value_19 := _metric(METRIC_DRY_STREAK, 0)
	_expect("T1 dry streak is 19 before the tag threshold (got %d)" % value_19,
		value_19 == 19 * Q16_ONE, str(value_19))
	_expect("T1 dry-spell tag is off at 19 days",
		not _has_tag(TAG_DRY_SPELL, 0), str(_tagged(TAG_DRY_SPELL)))
	if not _run_day():
		return false
	var value_20 := _metric(METRIC_DRY_STREAK, 0)
	_expect("T1 dry streak reaches 20 days (got %d)" % value_20,
		value_20 == 20 * Q16_ONE, str(value_20))
	_expect("T1 dry-spell tag turns on at 20 days",
		_has_tag(TAG_DRY_SPELL, 0), str(_tagged(TAG_DRY_SPELL)))
	for _index in range(5):
		if not _run_day():
			return false
	var value_25 := _metric(METRIC_DRY_STREAK, 0)
	_expect("T1 dry streak is 25 after five more dry days (got %d)" % value_25,
		value_25 == 25 * Q16_ONE, str(value_25))
	_set_precipitation(0.5)
	if not _run_day():
		return false
	var reset := _metric(METRIC_DRY_STREAK, 0)
	_expect("T1 rain resets the dry streak to zero (got %d)" % reset,
		reset == 0, str(reset))
	_expect("T1 rain clears the dry-spell tag",
		not _has_tag(TAG_DRY_SPELL, 0), str(_tagged(TAG_DRY_SPELL)))
	return true


## T2: flooding sets bit 0 and resets days-since-hazard; the next clear day
## increments it and clears today's mask.
func _test_t2_hazard() -> bool:
	_set_climate_u8(&"cell_cover", 5)
	if not _run_day():
		return false
	var mask := _metric(METRIC_HAZARD_TODAY, 0)
	var since := _metric(METRIC_DAYS_SINCE_HAZARD, 0)
	_expect("T2 flooding sets hazard bit 0 (got %d)" % mask,
		mask == Q16_ONE, str(mask))
	_expect("T2 hazard day resets days-since-hazard (got %d)" % since,
		since == 0, str(since))
	_set_climate_u8(&"cell_cover", 0)
	if not _run_day():
		return false
	mask = _metric(METRIC_HAZARD_TODAY, 0)
	since = _metric(METRIC_DAYS_SINCE_HAZARD, 0)
	_expect("T2 clear day clears the hazard mask (got %d)" % mask,
		mask == 0, str(mask))
	_expect("T2 clear day makes days-since-hazard one (got %d)" % since,
		since == Q16_ONE, str(since))
	return true


## T3: annual temperature is quantized from temp_365d and drives cold/hot tags.
func _test_t3_annual_temperature() -> bool:
	_set_f32(&"cell_temp_365d", 0.2)
	if not _run_day():
		return false
	var cold_value := _metric(METRIC_ANNUAL_TEMPERATURE, 0)
	_expect("T3 annual temperature quantizes 0.2 to 13107 (got %d)" % cold_value,
		cold_value == 13107, str(cold_value))
	_expect("T3 cold tag is on at 0.2", _has_tag(TAG_COLD, 0),
		str(_tagged(TAG_COLD)))
	_expect("T3 hot tag is off at 0.2", not _has_tag(TAG_HOT, 0),
		str(_tagged(TAG_HOT)))
	_set_f32(&"cell_temp_365d", 0.8)
	if not _run_day():
		return false
	var hot_value := _metric(METRIC_ANNUAL_TEMPERATURE, 0)
	_expect("T3 annual temperature quantizes 0.8 to 52429 (got %d)" % hot_value,
		hot_value == 52429, str(hot_value))
	_expect("T3 hot tag is on at 0.8", _has_tag(TAG_HOT, 0),
		str(_tagged(TAG_HOT)))
	_expect("T3 cold tag is off at 0.8", not _has_tag(TAG_COLD, 0),
		str(_tagged(TAG_COLD)))
	return true


## T4: schema-57 stream restore is bit-equal for the persistent climate
## counters and the state hash; a schema-56 stream migrates with zero counters.
func _test_t4_save_restore() -> bool:
	_set_climate_u8(&"cell_cover", 5)
	if not _run_day():
		return false
	_set_climate_u8(&"cell_cover", 0)
	_set_precipitation(0.0)
	for _index in range(5):
		if not _run_day():
			return false
	# Keep a non-zero previous-hazard byte in the saved fixture. Cell 3 remains
	# clear, so its days-since-hazard counter is also non-zero.
	_set_cell_climate_u8(5, &"cell_cover", 5)
	if not _run_day():
		return false
	var source_streak := _metric(METRIC_DRY_STREAK, 3)
	var source_since := _metric(METRIC_DAYS_SINCE_HAZARD, 3)
	var source_hash := int(_ext.get_economy_state_hash())
	var saved := _save_economy(_ext)
	if not _require("T4 economy save begins and finishes", bool(saved.get("ok", false)),
			str(saved.get("reason", ""))):
		return false
	if not _require("T4 save schema is 57", int(saved.get("schema_version", 0)) == 57,
			str(saved.get("schema_version", 0))):
		return false
	var record_bytes := _cell_record_bytes(saved.get("chunks", []))
	if not _require("T4 cell record layout is discoverable", record_bytes > 9,
			str(record_bytes)):
		return false
	var saved_suffixes := _cell_climate_suffixes(saved.get("chunks", []), record_bytes)
	_expect("T4 save carries a non-zero previous hazard mask",
		int(saved_suffixes.get(5, {}).get("mask", 0)) == 1,
		str(saved_suffixes.get(5, {})))
	var restored := _build_ext()
	if restored == null:
		return false
	var restored_result := _restore_economy(restored, saved.get("chunks", []))
	if not _require("T4 schema-57 stream restores", bool(restored_result.get("ok", false)),
			str(restored_result)):
		return false
	_expect("T4 dry streak is bit-equal after restore",
		_metric_on(restored, METRIC_DRY_STREAK, 3) == source_streak,
		"%d vs %d" % [_metric_on(restored, METRIC_DRY_STREAK, 3), source_streak])
	_expect("T4 days-since-hazard is bit-equal after restore",
		_metric_on(restored, METRIC_DAYS_SINCE_HAZARD, 3) == source_since,
		"%d vs %d" % [_metric_on(restored, METRIC_DAYS_SINCE_HAZARD, 3), source_since])
	_expect("T4 economy state hash is bit-equal after restore",
		int(restored.get_economy_state_hash()) == source_hash,
		"%d vs %d" % [int(restored.get_economy_state_hash()), source_hash])
	var resaved := _save_economy(restored)
	_expect("T4 resave remains schema 57",
		bool(resaved.get("ok", false)) and int(resaved.get("schema_version", 0)) == 57,
		str(resaved))
	var resaved_suffixes := _cell_climate_suffixes(resaved.get("chunks", []), record_bytes)
	_expect("T4 persistent climate suffixes are byte-equal after restore",
		resaved_suffixes == saved_suffixes,
		"source=%s restored=%s" % [str(saved_suffixes), str(resaved_suffixes)])

	var schema56_chunks := _downgrade_cells_to_schema56(
		saved.get("chunks", []), record_bytes)
	var migrated := _build_ext()
	if migrated == null:
		return false
	var migrated_result := _restore_economy(migrated, schema56_chunks)
	if not _require("T4 schema-56 stream migrates", bool(migrated_result.get("ok", false)),
			str(migrated_result)):
		return false
	_expect("T4 migration is reported as the X13a column bootstrap",
		String(migrated_result.get("migration", "")) == "v56_x13a_climate_columns",
		str(migrated_result.get("migration", "")))
	_expect("T4 schema-56 migration zero-initializes the dry streak",
		_metric_on(migrated, METRIC_DRY_STREAK, 3) == 0,
		str(_metric_on(migrated, METRIC_DRY_STREAK, 3)))
	_expect("T4 schema-56 migration zero-initializes days since hazard",
		_metric_on(migrated, METRIC_DAYS_SINCE_HAZARD, 3) == 0,
		str(_metric_on(migrated, METRIC_DAYS_SINCE_HAZARD, 3)))
	return true


## T7: the country aggregate is derived from persisted metric-73 counters. Restore
## a schema-57 stream with six of twelve cells hazard-free and expect exactly 0.5.
func _test_t7_hazard_free_cell_share() -> bool:
	if not _fresh_world():
		return false
	if not _run_day():
		return false
	var saved := _save_economy(_ext)
	if not _require("T7 economy save begins and finishes", bool(saved.get("ok", false)),
			str(saved.get("reason", ""))):
		return false
	var record_bytes := _cell_record_bytes(saved.get("chunks", []))
	if not _require("T7 cell record layout is discoverable", record_bytes > 9,
			str(record_bytes)):
		return false
	var chunks := _patch_days_since_hazard(
		saved.get("chunks", []), record_bytes)
	if not _require("T7 fixture patches all twelve counters", chunks.size() > 0,
			str(chunks.size())):
		return false
	var restored := _build_ext()
	if restored == null:
		return false
	var restored_result := _restore_economy(restored, chunks)
	if not _require("T7 patched schema-57 stream restores",
			bool(restored_result.get("ok", false)), str(restored_result)):
		return false
	var share := _metric_on(restored, METRIC_HAZARD_FREE_CELL_SHARE, 0)
	_expect("T7 six of twelve hazard-free cells publish Q16 one-half (got %d)"
			% share, share == Q16_ONE / 2, str(share))
	return true


## T5: refrigeration is a hot-annual-temperature card. In a fresh world, equipping
## it applies +10% to fish output; unequipping restores the untouched base.
func _test_t5_refrigeration_card() -> bool:
	if not _fresh_world():
		return false
	_set_f32(&"cell_temp_365d", 0.8)
	if not _run_day():
		return false
	if not _require("T5 hot annual temperature lights the hot tag",
			_has_tag(TAG_HOT, 0), str(_tagged(TAG_HOT))):
		return false
	var baseline := _read_cell_stat(0, REFRIGERATION_FISH_STAT)
	_expect("T5 refrigeration starts at base 1.0 (got %.5f)" % baseline,
		_is_close(baseline, 1.0), "%.5f" % baseline)
	if not _equip_card("refrigeration"):
		return false
	var level_one := _read_cell_stat(0, REFRIGERATION_FISH_STAT)
	_expect("T5 refrigeration L1 adds 10%% to hot-cell fish output (got %.5f)"
			% level_one, _is_close(level_one, 1.10), "%.5f" % level_one)
	if not _unequip_card("refrigeration"):
		return false
	var restored := _read_cell_stat(0, REFRIGERATION_FISH_STAT)
	_expect("T5 unequipping refrigeration restores fish output (got %.5f)" % restored,
		_is_close(restored, 1.0), "%.5f" % restored)
	return true


## T6: little_ice_age is the cold-side counterpart. In a second fresh world, its
## cold row adds 12% to aggregate output and unequipping restores the base.
func _test_t6_little_ice_age_card() -> bool:
	if not _fresh_world():
		return false
	_set_f32(&"cell_temp_365d", 0.2)
	if not _run_day():
		return false
	if not _require("T6 cold annual temperature lights the cold tag",
			_has_tag(TAG_COLD, 0), str(_tagged(TAG_COLD))):
		return false
	var baseline := _read_cell_stat(0, LITTLE_ICE_AGE_OUTPUT_STAT)
	_expect("T6 little_ice_age starts at base 1.0 (got %.5f)" % baseline,
		_is_close(baseline, 1.0), "%.5f" % baseline)
	if not _equip_card("little_ice_age"):
		return false
	var equipped := _read_cell_stat(0, LITTLE_ICE_AGE_OUTPUT_STAT)
	_expect("T6 little_ice_age adds 12%% to cold-cell output (got %.5f)" % equipped,
		_is_close(equipped, 1.12), "%.5f" % equipped)
	if not _unequip_card("little_ice_age"):
		return false
	var restored := _read_cell_stat(0, LITTLE_ICE_AGE_OUTPUT_STAT)
	_expect("T6 unequipping little_ice_age restores cold-cell output (got %.5f)"
			% restored, _is_close(restored, 1.0), "%.5f" % restored)
	return true


## Equip through the existing four-stage daily chain. The card's DISCOVER and
## EQUIP share the current day, just like the card-content fixture; each settle
## window starts at that day so the transition cannot remain pending.
func _equip_card(card: String) -> bool:
	var dense := _dense_card(card)
	if dense < 0:
		return false
	var submitted := _submit_ideology([
		{"op": 1, "day": _day, "handle": _handle, "idea": dense},
		{"op": 5, "day": _day, "handle": _handle, "idea": dense},
	])
	if not _require("%s discover+equip is accepted" % card,
			bool(submitted.get("ok", false)), str(submitted)):
		return false
	if not _require("%s transition settles" % card, _settle_ideology(_day), card):
		return false
	return _require("%s occupies an ideology slot" % card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) >= 1,
		str(_ext.get_ideology_snapshot(_handle)))


func _fresh_world() -> bool:
	_day = 0
	_next_sequence = 1
	_handle = 0
	var ext := _build_ext()
	if ext == null:
		return false
	_ext = ext
	return true


func _unequip_card(card: String) -> bool:
	var dense := _dense_card(card)
	if dense < 0:
		return false
	# Equip settlement consumes this day and the next two. Reusing the consumed
	# day leaves the retire transition pending, so stamp it after that window.
	var unequip_day := _day + 3
	var submitted := _submit_ideology([
		{"op": 6, "day": unequip_day, "handle": _handle, "idea": dense},
	])
	if not _require("%s unequip is accepted" % card,
			bool(submitted.get("ok", false)), str(submitted)):
		return false
	if not _require("%s unequip settles" % card,
			_settle_ideology(unequip_day), card):
		return false
	return _require("%s releases its ideology slot" % card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) == 0,
		str(_ext.get_ideology_snapshot(_handle)))


## Drive ideology -> Effect -> Modifier -> ACK for three days. Unlike the
## production worker path, this direct fixture's Economy day remains explicit so
## T5/T6 observe a single deterministic Modifier value at each stage.
func _settle_ideology(first_day: int) -> bool:
	for day in range(first_day, first_day + 3):
		for _slice in range(16):
			var ideology_slice: Dictionary = _ext.run_ideology_daily(day)
			if not bool(ideology_slice.get("ok", false)):
				return false
			if bool(ideology_slice.get("done", false)):
				break
		for _effect_slice in range(16):
			var effect_slice: Dictionary = _ext.run_effect_daily(day)
			if not bool(effect_slice.get("ok", true)):
				return false
			if bool(effect_slice.get("done", true)):
				break
		_ext.dispatch_effect_native_modifier()
		var modifier_day: Dictionary = _ext.run_modifier_daily(day)
		if not bool(modifier_day.get("ok", true)):
			return false
		var ack: Dictionary = _ext.ack_effect_native_modifier()
		if not bool(ack.get("ok", true)):
			return false
	return true


func _submit_ideology(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row_value in rows:
		var row: Dictionary = row_value
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", _day)))
		producers.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", _handle)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return _ext.submit_ideology_commands({
		"opcodes": opcodes, "effective_days": days, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"source_priorities": priorities, "offer_generations": generations,
		"choice_indices": choices, "gate_ids": gates,
	})


func _dense_card(card: String) -> int:
	var ids := PackedStringArray(_ideology_catalog.get(
		"ideology_ids", PackedStringArray()))
	var dense := ids.find("idea.%s" % card)
	_expect("%s is published in the production catalog" % card, dense >= 0,
		str(ids))
	return dense


func _read_cell_stat(cell: int, stat_key: String) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, stat_key, 1.0))


func _is_close(value: float, expected: float, tolerance: float = 0.0005) -> bool:
	return absf(value - expected) <= tolerance


func _cell_record_bytes(chunks: Array) -> int:
	for value in chunks:
		var chunk := value as PackedByteArray
		if chunk.size() < 16 or int(chunk.decode_u16(6)) != 3:
			continue
		var records := int(chunk.decode_u32(8))
		if records <= 0:
			continue
		return (chunk.size() - 16) / records
	return -1


func _cell_climate_suffixes(chunks: Array, record_bytes: int) -> Dictionary:
	var out := {}
	for value in chunks:
		var chunk := value as PackedByteArray
		if chunk.size() < 16 or int(chunk.decode_u16(6)) != 3:
			continue
		var records := int(chunk.decode_u32(8))
		for record in range(records):
			var at := 16 + record * record_bytes
			if at + record_bytes > chunk.size():
				return {}
			var cell := int(chunk.decode_s32(at))
			out[cell] = {
				"dry_streak": int(chunk.decode_s32(at + record_bytes - 9)),
				"days_since_hazard": int(chunk.decode_s32(at + record_bytes - 5)),
				"mask": int(chunk[at + record_bytes - 1]),
			}
	return out


func _downgrade_cells_to_schema56(chunks: Array, record_bytes: int) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var schema56_record_bytes := record_bytes - 9
	for value in chunks:
		var source := value as PackedByteArray
		var chunk := source.duplicate()
		chunk.encode_u16(4, 56)
		if int(chunk.decode_u16(6)) != 3:
			out.append(chunk)
			continue
		var records := int(chunk.decode_u32(8))
		if chunk.size() != 16 + records * record_bytes:
			return []
		var payload := PackedByteArray()
		payload.resize(records * schema56_record_bytes)
		for record in range(records):
			var source_at := 16 + record * record_bytes
			var target_at := record * schema56_record_bytes
			for offset in range(schema56_record_bytes):
				payload[target_at + offset] = chunk[source_at + offset]
		chunk.resize(16)
		chunk.append_array(payload)
		chunk.encode_u32(12, payload.size())
		out.append(chunk)
	return out


func _patch_days_since_hazard(chunks: Array,
		record_bytes: int) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var patched := 0
	for value in chunks:
		var source := value as PackedByteArray
		var chunk := source.duplicate()
		if int(chunk.decode_u16(6)) != 3:
			out.append(chunk)
			continue
		var records := int(chunk.decode_u32(8))
		if chunk.size() != 16 + records * record_bytes or records != CELLS:
			return []
		for record in range(records):
			var at := 16 + record * record_bytes
			chunk.encode_s32(at + record_bytes - 5,
				365 if record < CELLS / 2 else 0)
			patched += 1
		out.append(chunk)
	if patched != CELLS:
		return []
	return out


func _run_day() -> bool:
	for slice in range(256):
		var report: Dictionary = _ext.run_economy_slice({
			"day_index": _day, "tick_index": _day * 1000 + slice,
		})
		if bool(report.get("fatal", false)):
			_expect("day %d slice %d is nonfatal" % [_day, slice], false,
				str(report.get("fatal_reason", report)))
			return false
		if bool(report.get("done", false)):
			_day += 1
			return true
	_expect("day %d reaches a commit" % _day, false, "256 slices without done")
	return false


func _save_economy(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var end: Dictionary = ext.end_economy_save()
	return {
		"ok": bool(end.get("ok", false)),
		"reason": String(end.get("reason", "")),
		"chunks": chunks,
		"schema_version": int(begin.get("schema_version", 0)),
	}


func _restore_economy(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for value in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(value as PackedByteArray)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()


func _metric(metric: int, cell: int) -> int:
	return _metric_on(_ext, metric, cell)


func _metric_on(ext: Object, metric: int, cell: int) -> int:
	var result: Dictionary = ext.sample_effect_metric_probe(metric, cell, 0)
	if not bool(result.get("ok", false)):
		_fail("metric %d probe failed: %s" % [metric,
			str(result.get("reason", "unknown"))])
		return -1
	return int(result.get("value", -1))


func _tagged(tag_name: String) -> PackedInt32Array:
	var anchor := int(_ext.query_country_anchor_cell(0))
	if anchor < 0:
		return PackedInt32Array()
	var tag_id := _tag_id(tag_name)
	if tag_id < 0:
		return PackedInt32Array()
	return _ext.query_effect_target_cells(anchor, SEL_OWN_TERRITORY, 32, tag_id + 1)


func _has_tag(tag_name: String, cell: int) -> bool:
	return _tagged(tag_name).has(cell)


func _tag_id(tag_name: String) -> int:
	var tags: Array = _domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == tag_name:
			return index
	_fail("tag %s is absent from the production dictionary" % tag_name)
	return -1


func _set_precipitation(value: float) -> void:
	_set_f32(&"cell_weather_precip", value)


func _set_f32(slot_name: StringName, value: float) -> void:
	var sid: int = int(_ext.component_id(slot_name))
	if sid >= 0:
		_ext.write_f32_range(sid, 0, _f32_fill(value))


func _set_climate_u8(slot_name: StringName, value: int) -> void:
	var sid: int = int(_ext.component_id(slot_name))
	if sid >= 0:
		_ext.write_u8_range(sid, 0, _u8_fill(value))


func _set_cell_climate_u8(cell: int, slot_name: StringName, value: int) -> void:
	var sid: int = int(_ext.component_id(slot_name))
	if sid < 0:
		return
	var values := PackedByteArray()
	values.resize(CELLS)
	values.fill(0)
	values[cell] = value
	_ext.write_u8_range(sid, 0, values)


func _f32_fill(value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(CELLS)
	out.fill(value)
	return out


func _u8_fill(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(CELLS)
	out.fill(value)
	return out


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [
		label, "" if detail.is_empty() else " (%s)" % detail])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(reason: String) -> void:
	_checks += 1
	_failures += 1
	printerr("ERROR: [FAIL] %s" % reason)
