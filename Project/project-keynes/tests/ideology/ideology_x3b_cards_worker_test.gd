extends SceneTree

## X3-b card acceptance on the real Effect path.
##
## The fixture pins the two cell-share metrics and the committed worker-opinion
## row, then equips trade_unions / cooperative. Each card must:
##   * stay inert below its share threshold,
##   * occupy a slot and move exactly the authored factor,
##   * charge its national price,
##   * restore both cell and national values on unequip.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload(
	"res://scripts/modifier/modifier_catalog.gd")
const EffectDomainCatalogScript = preload(
	"res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const CELLS := 12
const SEED := 20261024
const Q16_ONE := 65536
const MODIFIER_DOMAIN_COUNTRY := 1
const MODIFIER_DOMAIN_ECONOMY := 2

const INDUSTRIAL_SHARE := "cell.profession_share_industrial_q16"
const COOPERATIVE_SHARE := "cell.profession_share_cooperative_q16"
const WORKER_SATISFACTION := "country.worker_class_satisfaction_q16"
const MANUFACTURING_STAT := \
	"economy.city.building.manufacturing_output_factor"
const AGRICULTURE_STAT := "economy.city.building.agriculture_output_factor"
const INPUT_STAT := "country.production.input_factor"
const TRADE_CAPACITY_STAT := "country.trade.capacity_factor"

var _ext: Object
var _country_catalog: Dictionary
var _domain: Resource
var _ideology_catalog: Dictionary
var _handle := 0
var _checks := 0
var _failures := 0
var _day := 0
var _next_sequence := 1
var _last_settle_error := ""


func _init() -> void:
	_run()
	print("=== ideology x3b cards worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	_country_catalog = EconomyCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles",
			bool(_country_catalog.get("ok", false)),
			str(_country_catalog.get("reason", ""))):
		return
	_country_catalog.erase("ok")
	_domain = EffectDomainCatalogScript.build()
	if not _require("Effect domain catalog builds", _domain != null):
		return
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if not _require("production ideology catalog loads", catalog != null):
		return
	_ideology_catalog = catalog.compile_native_catalog(
		_country_catalog, _country_catalog)
	if not _require("production ideology catalog compiles",
			bool(_ideology_catalog.get("ok", false)),
			str(_ideology_catalog.get("reason", ""))):
		return
	var daily: PackedInt64Array = _ideology_catalog.get(
		"level_daily_understanding_q16", PackedInt64Array())
	daily.fill(0)
	_ideology_catalog["level_daily_understanding_q16"] = daily
	if not _test_trade_unions():
		return
	if not _test_cooperative():
		return


func _fresh_world() -> bool:
	_day = 0
	_next_sequence = 1
	_handle = 0
	var ext := _build_ext()
	if ext == null:
		return false
	_ext = ext
	return true


func _build_ext() -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation",
			&"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(0.5))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type",
			&"cell_cover"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, _u8_fill(2 if slot_name == &"cell_terrain" else 0))
	for i in range((_country_catalog.building_resource_ids as PackedStringArray).size()):
		var reserve: int = ext.register_component(StringName(
			(_country_catalog.building_resource_reserve_slots as PackedStringArray)[i]),
			0, 1, false)
		var extra: int = ext.register_component(StringName(
			(_country_catalog.building_resource_extra_slots as PackedStringArray)[i]),
			0, 1, false)
		ext.write_f32_range(reserve, 0, _f32_fill(1000000.0))
		ext.write_f32_range(extra, 0, _f32_fill(0.0))
	if not _require("country configures", bool(ext.configure_country(
			_country_catalog, {
				"country_runtime_mode": "ACTIVE",
				"starting_technology_ids": PackedStringArray([
					"tech.hunting", "tech.industrialization",
					"tech.electrical_society"]),
			}, CELLS, SEED).get("ok", false))):
		return null
	var cells := PackedInt32Array()
	for cell in range(CELLS):
		cells.append(cell)
	if not _require("country bootstraps", bool(ext.bootstrap_country({
			"country_ids": PackedStringArray(["country.x3b_cards"]),
			"country_names": PackedStringArray(["X3b cards"]),
			"country_cash": PackedInt64Array([1000000000]),
			"territory_offsets": PackedInt32Array([0, CELLS]),
			"territory_cells": cells,
			"technology_offsets": PackedInt32Array([0, 0]),
			"technology_indices": PackedInt32Array(),
			"treasury_offsets": PackedInt32Array([0, 0]),
			"treasury_good_indices": PackedInt32Array(),
			"treasury_quantities": PackedInt64Array(),
		}, _u8_fill(0)).get("ok", false))):
		return null
	var modifiers: Dictionary = ModifierCatalogScript.load_default(
		).compile_native_catalog()
	if not _require("modifier catalog compiles",
			bool(modifiers.get("ok", false)), str(modifiers.get("reason", ""))):
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
	if not _require("Effect runtime configures",
			bool(ext.configure_effects(effects).get("ok", false))):
		return null
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.starvation_death_rate_q32 = 0
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	if not _require("economy configures", bool(ext.configure_economy(
			_country_catalog, profile, CELLS, SEED).get("ok", false))):
		return null
	var signature: int = (_country_catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	var building_id: int = (_country_catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	if not _require("forager signature and gathering ground exist",
			signature >= 0 and building_id >= 0):
		return null
	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(CELLS):
		cell_indices.append(cell)
		signature_ids.append(signature)
		populations.append(180)
		funds.append(1000000)
	var stock := PackedInt64Array()
	stock.resize(CELLS * (_country_catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signature_ids,
		"population": populations,
		"funds": funds,
		"forced_named_cells": PackedInt32Array([0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building_id]),
		"building_owner_signature_ids": PackedInt32Array([signature]),
		"building_counts": PackedInt64Array([1]),
	})
	if not _require("economy bootstraps", bool(boot.get("ok", false)),
			str(boot)):
		return null
	if not _require("ideology runtime configures", bool(ext.configure_ideologies(
			_support_gate_off(_ideology_catalog)).get("ok", false))):
		return null
	if not _require("country snapshots capture",
			bool(ext.capture_country_runtime_snapshot().get("ok", false))
				and bool(ext.capture_country_pod_catalog().get("ok", false))):
		return null
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("fixture resolves the country handle", handle != 0):
		return null
	_handle = handle
	_ext = ext
	if not _require("opening day commits", _run_day()):
		return null
	return ext


func _test_trade_unions() -> bool:
	if not _fresh_world():
		return false
	if not _install_share_fixture(INDUSTRIAL_SHARE, 24):
		return false
	var below := _read_cell(0, MANUFACTURING_STAT)
	_expect("trade_unions does not fire at 24% industrial share",
		_is_close(below, 1.0), "%.5f" % below)
	if not _equip("trade_unions"):
		return false
	var still_below := _wait_cell(0, MANUFACTURING_STAT, 1.0, 3)
	_expect("trade_unions stays inert below its 25% threshold",
		_is_close(still_below, 1.0), "%.5f" % still_below)
	if not _set_metric(INDUSTRIAL_SHARE, 26):
		return false
	if not _set_metric(WORKER_SATISFACTION, 10):
		return false
	var low_opinion := _wait_cell(0, MANUFACTURING_STAT, 1.10, 5)
	_expect("trade_unions L1 at 26% / worker opinion 0.10 gives +10%",
		_is_close(low_opinion, 1.10), "%.5f" % low_opinion)
	if not _set_metric(WORKER_SATISFACTION, 30):
		return false
	var high_opinion := _wait_cell(0, MANUFACTURING_STAT, 1.20, 5)
	_expect("worker opinion >=0.2 doubles trade_unions to +20% at L1",
		_is_close(high_opinion, 1.20), "%.5f" % high_opinion)
	_expect("trade_unions charges +3% national production input",
		_is_close(_read_country(INPUT_STAT), 1.03),
		"%.5f" % _read_country(INPUT_STAT))
	if not _raise_level("trade_unions", 2):
		return false
	var l2 := _wait_cell(0, MANUFACTURING_STAT, 1.28, 5)
	_expect("trade_unions L2 at high opinion gives +28%",
		_is_close(l2, 1.28), "%.5f" % l2)
	if not _raise_level("trade_unions", 3):
		return false
	if not _set_metric(INDUSTRIAL_SHARE, 22):
		return false
	var l3 := _wait_cell(0, MANUFACTURING_STAT, 1.28, 5)
	_expect("trade_unions L3 fires at 22% industrial share",
		_is_close(l3, 1.28), "%.5f" % l3)
	if not _unequip("trade_unions"):
		return false
	_expect("unequipping trade_unions restores manufacturing",
		_is_close(_read_cell(0, MANUFACTURING_STAT), 1.0),
		"%.5f" % _read_cell(0, MANUFACTURING_STAT))
	_expect("unequipping trade_unions restores production input",
		_is_close(_read_country(INPUT_STAT), 1.0),
		"%.5f" % _read_country(INPUT_STAT))
	return true


func _test_cooperative() -> bool:
	if not _fresh_world():
		return false
	if not _install_share_fixture(COOPERATIVE_SHARE, 14):
		return false
	if not _equip("cooperative"):
		return false
	var below := _wait_cell(0, AGRICULTURE_STAT, 1.0, 3)
	_expect("cooperative L1 stays inert at 14% share",
		_is_close(below, 1.0), "%.5f" % below)
	if not _set_metric(COOPERATIVE_SHARE, 22):
		return false
	var l1 := _wait_cell(0, AGRICULTURE_STAT, 1.12, 5)
	_expect("cooperative L1 at 22% share gives +12%",
		_is_close(l1, 1.12), "%.5f" % l1)
	_expect("cooperative charges -2% national trade capacity",
		_is_close(_read_country(TRADE_CAPACITY_STAT), 0.98),
		"%.5f" % _read_country(TRADE_CAPACITY_STAT))
	if not _raise_level("cooperative", 2):
		return false
	var l2 := _wait_cell(0, AGRICULTURE_STAT, 1.16, 5)
	_expect("cooperative L2 at 22% share gives +16%",
		_is_close(l2, 1.16), "%.5f" % l2)
	if not _raise_level("cooperative", 3):
		return false
	if not _set_metric(COOPERATIVE_SHARE, 17):
		return false
	var l3 := _wait_cell(0, AGRICULTURE_STAT, 1.16, 5)
	_expect("cooperative L3 fires at 17% share",
		_is_close(l3, 1.16), "%.5f" % l3)
	if not _unequip("cooperative"):
		return false
	_expect("unequipping cooperative restores agriculture",
		_is_close(_read_cell(0, AGRICULTURE_STAT), 1.0),
		"%.5f" % _read_cell(0, AGRICULTURE_STAT))
	_expect("unequipping cooperative restores trade capacity",
		_is_close(_read_country(TRADE_CAPACITY_STAT), 1.0),
		"%.5f" % _read_country(TRADE_CAPACITY_STAT))
	return true


func _install_share_fixture(metric_key: String, percent: int) -> bool:
	var cleared: Dictionary = _ext.clear_cell_tag_overrides_for_test()
	if not _require("fixture clears prior tag overrides",
			bool(cleared.get("ok", false)), str(cleared)):
		return false
	for cell in range(CELLS):
		var sector := "cell.sector.manufacturing" \
			if metric_key == INDUSTRIAL_SHARE else "cell.sector.agriculture"
		var applied: Dictionary = _ext.set_cell_tag_override_for_test(
			sector, cell, cell == 0)
		if not _require("fixture sets %s on cell 0" % sector,
				bool(applied.get("ok", false)), str(applied)):
			return false
	if not _set_metric(metric_key, percent):
		return false
	return _require("share fixture refreshes the input digest",
		bool(_ext.refresh_effect_input_digest_for_test().get("ok", false)))


func _set_metric(metric_key: String, percent: int) -> bool:
	var metric := _metric_id(metric_key)
	if metric < 0:
		return false
	var value_q16 := int(round(percent / 100.0 * Q16_ONE))
	var applied: Dictionary = _ext.set_effect_metric_override_for_test(
		metric, value_q16, true)
	if not _require("metric %s override applies" % metric_key,
			bool(applied.get("ok", false)), str(applied)):
		return false
	return _require("metric %s digest refreshes" % metric_key,
		bool(_ext.refresh_effect_input_digest_for_test().get("ok", false)))


func _metric_id(metric_key: String) -> int:
	var metric := PackedStringArray(_domain.metric_keys).find(metric_key)
	if metric < 0:
		_fail("metric key %s is absent" % metric_key)
	return metric


func _equip(card: String) -> bool:
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
	if not _require("%s transition settles" % card,
			_settle_ideology(_day), str(_ext.get_ideology_snapshot(_handle))):
		return false
	return _require("%s occupies an ideology slot" % card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) >= 1,
		str(_ext.get_ideology_snapshot(_handle)))


func _unequip(card: String) -> bool:
	var dense := _dense_card(card)
	if dense < 0:
		return false
	var unequip_day := _day
	var submitted := _submit_ideology([{
		"op": 6, "day": unequip_day, "handle": _handle, "idea": dense,
	}])
	if not _require("%s unequip is accepted" % card,
			bool(submitted.get("ok", false)), str(submitted)):
		return false
	if not _require("%s unequip settles" % card,
			_settle_ideology(unequip_day),
			"snapshot=%s effect=%s modifier=%s" % [
				str(_ext.get_ideology_snapshot(_handle)),
				str(_ext.get_effect_report()),
				str(_ext.get_modifier_report())]):
		return false
	return _require("%s releases its ideology slot" % card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) == 0,
		str(_ext.get_ideology_snapshot(_handle)))


func _raise_level(card: String, level: int) -> bool:
	var dense := _dense_card(card)
	if dense < 0:
		return false
	var understanding := 8 * Q16_ONE if level == 2 else 24 * Q16_ONE
	var submitted := _submit_ideology([{
		"op": 8, "day": _day, "handle": _handle, "idea": dense,
		"value": understanding,
	}])
	if not _require("%s reaches L%d" % [card, level],
			bool(submitted.get("ok", false)), str(submitted)):
		return false
	return _require("%s L%d settles" % [card, level],
		_settle_ideology(_day),
		"%s snapshot=%s effect=%s" % [
			_last_settle_error,
			str(_ext.get_ideology_snapshot(_handle)),
			str(_ext.get_effect_report())])


func _settle_ideology(first_day: int, days: int = 3) -> bool:
	_last_settle_error = ""
	# Effect rejects a day rewind. Keep every fixture stage on the shared
	# monotonic clock even when a wait request starts before the last finish.
	var start := maxi(first_day, _day)
	for day in range(start, start + days):
		for _slice in range(16):
			var ideology_slice: Dictionary = _ext.run_ideology_daily(day)
			if not bool(ideology_slice.get("ok", false)):
				_last_settle_error = "ideology day=%d slice=%d report=%s" % [
					day, _slice, str(ideology_slice)]
				return false
			if bool(ideology_slice.get("done", false)):
				break
		for _effect_slice in range(16):
			var effect_slice: Dictionary = _ext.run_effect_daily(day)
			if not bool(effect_slice.get("ok", true)):
				_last_settle_error = "effect day=%d slice=%d report=%s" % [
					day, _effect_slice, str(effect_slice)]
				return false
			if bool(effect_slice.get("done", true)):
				break
		_ext.dispatch_effect_native_modifier()
		var modifier_day: Dictionary = _ext.run_modifier_daily(day)
		if not bool(modifier_day.get("ok", true)):
			_last_settle_error = "modifier day=%d report=%s" % [day, str(modifier_day)]
			return false
		var ack: Dictionary = _ext.ack_effect_native_modifier()
		if not bool(ack.get("ok", true)):
			_last_settle_error = "modifier ack day=%d report=%s" % [day, str(ack)]
			return false
		_ext.dispatch_effect_native_gameplay()
		var gameplay: Dictionary = _ext.run_gameplay_effects(day)
		if not bool(gameplay.get("ok", true)):
			_last_settle_error = "gameplay day=%d report=%s" % [day, str(gameplay)]
			return false
		var gameplay_ack: Dictionary = _ext.ack_effect_native_gameplay()
		if not bool(gameplay_ack.get("ok", true)):
			_last_settle_error = "gameplay ack day=%d report=%s" % [
				day, str(gameplay_ack)]
			return false
		_day = maxi(_day, day + 1)
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


func _support_gate_off(native: Dictionary) -> Dictionary:
	var out := native.duplicate(false)
	var count := (out["ideology_ids"] as PackedStringArray).size()
	var zeros := PackedInt32Array()
	zeros.resize(count + 1)
	zeros.fill(0)
	out["stance_offsets"] = zeros
	out["stance_class_indices"] = PackedInt32Array()
	out["stance_adopt_q16"] = PackedInt32Array()
	out["stance_repeal_q16"] = PackedInt32Array()
	out["stance_promote_q16"] = PackedInt32Array()
	out["stance_adopt_min_q16"] = PackedInt32Array()
	out["stance_repeal_min_q16"] = PackedInt32Array()
	out["stance_promote_min_q16"] = PackedInt32Array()
	var thresholds := PackedInt32Array()
	thresholds.resize(count)
	thresholds.fill(0)
	out["adopt_thresholds_q16"] = thresholds
	out["repeal_thresholds_q16"] = thresholds.duplicate()
	out["promote_thresholds_q16"] = thresholds.duplicate()
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
	_expect("day %d reaches a commit" % _day, false, "256 slices")
	return false


func _wait_cell(cell: int, stat_key: String, expected: float,
		days: int) -> float:
	var value := _read_cell(cell, stat_key)
	for _index in range(days):
		if _is_close(value, expected):
			return value
		# Keep the fixture's metric overrides intact. An Economy commit republishes
		# these metrics; Effect/Modifier reconciliation alone is enough to apply
		# the program commands and their persistent factors.
		_settle_ideology(_day, 1)
		value = _read_cell(cell, stat_key)
	return value


func _read_cell(cell: int, stat_key: String) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, stat_key, 1.0))


func _read_country(stat_key: String) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_COUNTRY, _handle, 0, stat_key, 1.0))


func _dense_card(card: String) -> int:
	var ids := PackedStringArray(_ideology_catalog.get(
		"ideology_ids", PackedStringArray()))
	var dense := ids.find("idea.%s" % card)
	_expect("%s is published in the production catalog" % card, dense >= 0,
		str(ids))
	return dense


func _is_close(value: float, expected: float,
		tolerance: float = 0.0005) -> bool:
	return absf(value - expected) <= tolerance


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
