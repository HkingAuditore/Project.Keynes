extends SceneTree

## X9-a: derived per-cell family metrics 84-86 and the clan tags.
##
## A deterministic founder-family packet creates one branch on cell 0.
## Metrics/tags must describe that frozen branch table, unchanged days must not
## recompute it, and equipping kin_hearth / ancestral_hall must change the real
## Modifier rows for clan / eminent-clan cells before unequip restores them.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload(
	"res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const CELLS := 12
const SEED := 20261024
const Q16_ONE := 65536
const MODIFIER_DOMAIN_COUNTRY := 1
const MODIFIER_DOMAIN_ECONOMY := 2
const SEL_OWN_TERRITORY := 12
const METRIC_FAMILY_BRANCH_COUNT := 84
const METRIC_MAX_BRANCH_PRESTIGE := 85
const METRIC_FAMILY_ASSET_SHARE := 86
const TAG_CLAN := "cell.clan"
const TAG_EMINENT_CLAN := "cell.eminent_clan"
const BIRTH_STAT := "economy.city.birth_factor"
const OUTPUT_STAT := "economy.city.output_factor"
const AGRICULTURE_STAT := "economy.city.building.agriculture_output_factor"
const MANUFACTURING_STAT := "economy.city.building.manufacturing_output_factor"
const INPUT_STAT := "country.production.input_factor"
const KNOWLEDGE_STAT := "economy.city.building.knowledge_output_factor"

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
	print("=== ideology x9a worker: %d checks, %d failures ===" % [
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
	# Keep the card-effect fixture on L1. Daily understanding would otherwise
	# start a legitimate L2 transition while the reverse transition is settling,
	# coupling the modifier assertion to the progression cadence.
	var daily_understanding := PackedInt64Array(
		_ideology_catalog.get("level_daily_understanding_q16", PackedInt64Array()))
	daily_understanding.fill(0)
	_ideology_catalog["level_daily_understanding_q16"] = daily_understanding
	_ext = _build_ext()
	if _ext == null:
		return
	if not _test_metrics_and_tags():
		return
	if not _test_eminent_threshold():
		return
	if not _test_idle_reuse():
		return
	_test_kin_hearth_card()
	_test_ancestral_hall_card()
	_test_clan_fields_card()
	_test_clan_fields_penalty()
	_test_merchant_houses_card()
	_test_family_enterprise_card()
	_test_family_enterprise_penalty()


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
			"starting_technology_ids": PackedStringArray([
				"tech.hunting", "tech.kingdom_administration",
				"tech.global_exchange", "tech.enlightenment_institutions"]),
		}, CELLS, SEED).get("ok", false))):
		return null
	var cells := PackedInt32Array()
	for cell in range(CELLS):
		cells.append(cell)
	if not _require("country bootstraps", bool(ext.bootstrap_country({
			"country_ids": PackedStringArray(["country.x9a"]),
			"country_names": PackedStringArray(["X9a"]),
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
		"res://scripts/modifier/modifier_catalog.gd").load_default(
		).compile_native_catalog()
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
	profile.family_runtime_mode = "ACTIVE"
	profile.family_review_days = 1
	profile.family_milestone_populations = PackedInt64Array([1, 2, 3, 4, 5, 6, 7, 8])
	profile.family_min_founder_people = 20
	profile.family_founding_choice_mode = "AUTO"
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	if not _require("economy configures", bool(ext.configure_economy(
			_catalog, profile, CELLS, SEED).get("ok", false))):
		return null
	var signature: int = (_catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	var building_id: int = (_catalog.building_type_ids as PackedStringArray).find(
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
		populations.append(120)
		funds.append(1000000)
	# Market stock is matrix-shaped (cell market x good), not just one good row.
	var stock := PackedInt64Array()
	stock.resize(CELLS * (_catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
				"cell_indices": cell_indices, "signature_ids": signature_ids,
				"population": populations, "funds": funds,
				"forced_named_cells": PackedInt32Array([0]),
				"founder_family_cells": PackedInt32Array([0]),
				"founder_family_building_type_ids": PackedInt32Array([building_id]),
				"founder_family_owner_signature_ids":
					PackedInt32Array([signature]),
			}, {
				"stock": stock,
				"building_cells": PackedInt32Array([0]),
				"building_type_ids": PackedInt32Array([building_id]),
				"building_owner_signature_ids": PackedInt32Array([signature]),
				"building_counts": PackedInt64Array([1]),
			})
	if not _require("economy bootstraps one founder branch",
			bool(boot.get("ok", false)), str(boot)):
		return null
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
	# The caller owns _ext once construction succeeds; commit day zero through
	# that state so _run_day sees the same runtime.
	_ext = ext
	if not _require("opening day commits", _run_day()):
		return null
	return ext


## T1: the sole founder branch publishes count=1 / prestige / asset share and
## lights both clan tags on its own cell (not on untouched owned cells).
func _test_metrics_and_tags() -> bool:
	var branch_count := _metric(METRIC_FAMILY_BRANCH_COUNT, 0)
	var prestige := _metric(METRIC_MAX_BRANCH_PRESTIGE, 0)
	var asset_share := _metric(METRIC_FAMILY_ASSET_SHARE, 0)
	_expect("T1 branch count is count_q16(1) (got %d)" % branch_count,
		branch_count == Q16_ONE, str(branch_count))
	_expect("T1 highest branch prestige is populated (got %d)" % prestige,
		prestige > 0, str(prestige))
	_expect("T1 family asset share is populated (got %d)" % asset_share,
		asset_share >= 0, str(asset_share))
	_expect("T1 untouched owned cell has no branch (got %d)" %
			_metric(METRIC_FAMILY_BRANCH_COUNT, 1),
		_metric(METRIC_FAMILY_BRANCH_COUNT, 1) == 0,
		str(_metric(METRIC_FAMILY_BRANCH_COUNT, 1)))
	_expect("T1 cell.clan selects the founder cell",
		_has_tag(TAG_CLAN, 0), str(_tagged(TAG_CLAN)))
	_expect("T1 cell.clan excludes an untouched owned cell",
		not _has_tag(TAG_CLAN, 1), str(_tagged(TAG_CLAN)))
	_expect("T1 cell.eminent_clan follows prestige >= 50%",
		_has_tag(TAG_EMINENT_CLAN, 0) == (prestige >= 50 * Q16_ONE / 100),
		"prestige=%d tagged=%s" % [prestige, str(_tagged(TAG_EMINENT_CLAN))])
	return true


## T2: threshold behavior without touching the branch table. A synthetic query
## can only be made through real branch data, so assert the tag contract at the
## actual prestige value and its exact 50% boundary arithmetic.
func _test_eminent_threshold() -> bool:
	var prestige := _metric(METRIC_MAX_BRANCH_PRESTIGE, 0)
	var expected := prestige >= 50 * Q16_ONE / 100
	_expect("T2 eminent-clan threshold is exactly 50%% Q16",
		_has_tag(TAG_EMINENT_CLAN, 0) == expected,
		"prestige=%d expected=%s tagged=%s" % [
			prestige, str(expected), str(_tagged(TAG_EMINENT_CLAN))])
	return true


## T3: stable branch table + unchanged days => zero derived-column rebuilds.
func _test_idle_reuse() -> bool:
	var before := int(_ext.get_economy_report().get(
		"family_cell_metric_rebuilds", -1))
	for _index in range(5):
		if not _run_day():
			return false
	var after := int(_ext.get_economy_report().get(
		"family_cell_metric_rebuilds", -1))
	_expect("T3 five unchanged days rebuild metrics 84-86 zero times",
		after == before, "%d -> %d" % [before, after])
	return true


## T4: kin_hearth L1's cell.clan row is +6% birth and +5% housing demand.
func _test_kin_hearth_card() -> void:
	if not _fresh_world():
		return
	var baseline := _read_cell_stat(0, BIRTH_STAT)
	_expect("T4 kin_hearth starts at base birth factor",
		_is_close(baseline, 1.0), "%.5f" % baseline)
	if not _equip_card("kin_hearth"):
		return
	var equipped := _read_cell_stat(0, BIRTH_STAT)
	_expect("T4 kin_hearth adds +6%% birth on the clan cell (got %.5f)" %
			equipped, _is_close(equipped, 1.06), "%.5f" % equipped)
	if not _unequip_card("kin_hearth"):
		return
	var restored := _read_cell_stat(0, BIRTH_STAT)
	_expect("T4 unequipping kin_hearth restores birth (got %.5f)" % restored,
		_is_close(restored, 1.0), "%.5f" % restored)


## T5: ancestral_hall L1's cell.eminent_clan row is +6% output. The fixture's
## founder branch has full asset ownership, so it crosses the 50% threshold.
func _test_ancestral_hall_card() -> void:
	if not _fresh_world():
		return
	if not _require("T5 founder cell is eminent before ancestral_hall",
			_has_tag(TAG_EMINENT_CLAN, 0), str(_tagged(TAG_EMINENT_CLAN))):
		return
	var baseline := _read_cell_stat(0, OUTPUT_STAT)
	_expect("T5 ancestral_hall starts at base output factor",
		_is_close(baseline, 1.0), "%.5f" % baseline)
	if not _equip_card("ancestral_hall"):
		return
	var equipped := _read_cell_stat(0, OUTPUT_STAT)
	_expect("T5 ancestral_hall adds +6%% output on the eminent-clan cell "
			+ "(got %.5f)" % equipped, _is_close(equipped, 1.06),
		"%.5f" % equipped)
	if not _unequip_card("ancestral_hall"):
		return
	var restored := _read_cell_stat(0, OUTPUT_STAT)
	_expect("T5 unequipping ancestral_hall restores output (got %.5f)" % restored,
		_is_close(restored, 1.0), "%.5f" % restored)


func _test_clan_fields_card() -> void:
	if not _fresh_world():
		return
	if not _install_card_fixture(
			"cell.eminent_clan&cell.sector.agriculture",
			{"cell.family_asset_share_q16": Q16_ONE}):
		return
	var baseline := _read_cell_stat(0, AGRICULTURE_STAT)
	_expect("T6 clan_fields starts at base agriculture factor",
		_is_close(baseline, 1.0), "%.5f" % baseline)
	if not _equip_card("clan_fields"):
		return
	var equipped := _read_cell_stat(0, AGRICULTURE_STAT)
	_expect("T6 clan_fields adds +12%% agriculture on the family cell "
			+ "(got %.5f)" % equipped, _is_close(equipped, 1.12),
		"%.5f" % equipped)
	if not _unequip_card("clan_fields"):
		return
	var restored := _read_cell_stat(0, AGRICULTURE_STAT)
	_expect("T6 unequipping clan_fields restores agriculture (got %.5f)"
			% restored, _is_close(restored, 1.0), "%.5f" % restored)


func _test_clan_fields_penalty() -> void:
	if not _fresh_world():
		return
	if not _install_penalty_fixture("cell.sector.agriculture"):
		return
	if not _equip_card("clan_fields"):
		return
	if not _require("T7 metric 86 override reaches the tag sampler",
			_metric(_metric_id("cell.family_asset_share_q16"), 0) == 0,
			str(_metric(_metric_id("cell.family_asset_share_q16"), 0))):
		return
	if not _require("T7 non-family agriculture tag resolves",
			_has_tag("cell.sector.agriculture", 0),
			str(_tagged("cell.sector.agriculture"))):
		return
	var equipped := _read_cell_stat(0, AGRICULTURE_STAT)
	_expect("T7 clan_fields penalizes non-family agriculture by 5%% "
			+ "(got %.5f)" % equipped, _is_close(equipped, 0.95),
		"%.5f" % equipped)
	if not _unequip_card("clan_fields"):
		return
	var restored := _read_cell_stat(0, AGRICULTURE_STAT)
	_expect("T7 unequipping clan_fields restores penalized agriculture "
			+ "(got %.5f)" % restored, _is_close(restored, 1.0),
		"%.5f" % restored)


func _test_merchant_houses_card() -> void:
	if not _fresh_world():
		return
	if not _install_card_fixture(
			"cell.clan&cell.diversified",
			{"cell.distinct_sector_count": 3 * Q16_ONE}):
		return
	var baseline := _read_cell_stat(0, OUTPUT_STAT)
	var input_baseline := _read_country_stat(INPUT_STAT)
	_expect("T8 merchant_houses starts at base output factor",
		_is_close(baseline, 1.0), "%.5f" % baseline)
	_expect("T8 merchant_houses starts at base production input factor",
		_is_close(input_baseline, 1.0), "%.5f" % input_baseline)
	if not _equip_card("merchant_houses"):
		return
	var equipped := _read_cell_stat(0, OUTPUT_STAT)
	var input_equipped := _read_country_stat(INPUT_STAT)
	_expect("T8 merchant_houses adds +10%% output on the diversified clan "
			+ "cell (got %.5f)" % equipped, _is_close(equipped, 1.10),
		"%.5f" % equipped)
	_expect("T8 merchant_houses raises national production input by 2%% "
			+ "(got %.5f)" % input_equipped,
		_is_close(input_equipped, 1.02), "%.5f" % input_equipped)
	if not _unequip_card("merchant_houses"):
		return
	var restored := _read_cell_stat(0, OUTPUT_STAT)
	var input_restored := _read_country_stat(INPUT_STAT)
	_expect("T8 unequipping merchant_houses restores output (got %.5f)"
			% restored, _is_close(restored, 1.0), "%.5f" % restored)
	_expect("T8 unequipping merchant_houses restores production input "
			+ "(got %.5f)" % input_restored,
		_is_close(input_restored, 1.0), "%.5f" % input_restored)


func _test_family_enterprise_card() -> void:
	if not _fresh_world():
		return
	if not _install_card_fixture(
			"cell.clan&cell.sector.manufacturing",
			{"cell.family_asset_share_q16": Q16_ONE}):
		return
	var baseline := _read_cell_stat(0, MANUFACTURING_STAT)
	_expect("T9 family_enterprise starts at base manufacturing factor",
		_is_close(baseline, 1.0), "%.5f" % baseline)
	if not _equip_card("family_enterprise"):
		return
	var equipped := _read_cell_stat(0, MANUFACTURING_STAT)
	_expect("T9 family_enterprise adds +12%% manufacturing on the family "
			+ "cell (got %.5f)" % equipped, _is_close(equipped, 1.12),
		"%.5f" % equipped)
	if not _unequip_card("family_enterprise"):
		return
	var restored := _read_cell_stat(0, MANUFACTURING_STAT)
	_expect("T9 unequipping family_enterprise restores manufacturing "
			+ "(got %.5f)" % restored, _is_close(restored, 1.0),
		"%.5f" % restored)


func _test_family_enterprise_penalty() -> void:
	if not _fresh_world():
		return
	if not _install_penalty_fixture("cell.sector.manufacturing"):
		return
	if not _equip_card("family_enterprise"):
		return
	if not _require("T10 metric 86 override reaches the tag sampler",
			_metric(_metric_id("cell.family_asset_share_q16"), 0) == 0,
			str(_metric(_metric_id("cell.family_asset_share_q16"), 0))):
		return
	if not _require("T10 non-family manufacturing tag resolves",
			_has_tag("cell.sector.manufacturing", 0),
			str(_tagged("cell.sector.manufacturing"))):
		return
	var equipped := _read_cell_stat(0, MANUFACTURING_STAT)
	_expect("T10 family_enterprise penalizes non-family manufacturing by 6%% "
			+ "(got %.5f)" % equipped, _is_close(equipped, 0.94),
		"%.5f" % equipped)
	if not _unequip_card("family_enterprise"):
		return
	var restored := _read_cell_stat(0, MANUFACTURING_STAT)
	_expect("T10 unequipping family_enterprise restores penalized "
			+ "manufacturing (got %.5f)" % restored,
		_is_close(restored, 1.0), "%.5f" % restored)


## Card programmes consume Effect days 0..2 for equip and 3..5 for unequip.
## Reusing that world for the next card would stamp its commands on a day the
## Effect runtime has already completed, so every card assertion gets a world.
func _fresh_world() -> bool:
	_day = 0
	_next_sequence = 1
	_handle = 0
	var ext := _build_ext()
	if ext == null:
		return false
	_ext = ext
	return true


func _install_card_fixture(composite_tag: String,
		overrides: Dictionary) -> bool:
	var cleared: Dictionary = _ext.clear_cell_tag_overrides_for_test()
	if not _require("fixture clears prior tag overrides",
			bool(cleared.get("ok", false)), str(cleared)):
		return false
	var metric_ids := PackedStringArray(_domain.metric_keys)
	for metric_key_value in overrides:
		var metric_key := String(metric_key_value)
		var metric := metric_ids.find(metric_key)
		if not _require("fixture resolves metric %s" % metric_key,
				metric >= 0, str(metric_ids)):
			return false
		var applied: Dictionary = _ext.set_effect_metric_override_for_test(
			metric, int(overrides[metric_key_value]), true)
		if not _require("fixture overrides %s" % metric_key,
				bool(applied.get("ok", false)), str(applied)):
			return false
	for cell in range(CELLS):
		var applied: Dictionary = _ext.set_cell_tag_override_for_test(
			composite_tag, cell, cell == 0)
		if not _require("fixture sets %s=%s on cell %d" % [
				composite_tag, str(cell == 0), cell],
				bool(applied.get("ok", false)), str(applied)):
			return false
	for tag in composite_tag.split("&"):
		for cell in range(CELLS):
			var applied: Dictionary = _ext.set_cell_tag_override_for_test(
				tag, cell, cell == 0)
			if not _require("fixture sets %s=%s on cell %d" % [
					tag, str(cell == 0), cell],
					bool(applied.get("ok", false)), str(applied)):
				return false
	var refreshed: Dictionary = _ext.refresh_effect_input_digest_for_test()
	return _require("fixture refreshes the effect input digest",
		bool(refreshed.get("ok", false)), str(refreshed))


func _install_penalty_fixture(sector_tag: String) -> bool:
	var cleared: Dictionary = _ext.clear_cell_tag_overrides_for_test()
	if not _require("penalty fixture clears prior tag overrides",
			bool(cleared.get("ok", false)), str(cleared)):
		return false
	var metric := _metric_id("cell.family_asset_share_q16")
	if metric < 0:
		return false
	var applied: Dictionary = _ext.set_effect_metric_override_for_test(
		metric, 0, true)
	if not _require("penalty fixture overrides cell.family_asset_share_q16",
			bool(applied.get("ok", false)), str(applied)):
		return false
	for cell in range(CELLS):
		var sector_applied: Dictionary = _ext.set_cell_tag_override_for_test(
			sector_tag, cell, true)
		if not _require("penalty fixture sets %s on cell %d" % [
				sector_tag, cell],
				bool(sector_applied.get("ok", false)), str(sector_applied)):
			return false
		var clan_applied: Dictionary = _ext.set_cell_tag_override_for_test(
			"cell.eminent_clan", cell, false)
		if not _require("penalty fixture clears eminent clan on cell %d" % cell,
				bool(clan_applied.get("ok", false)), str(clan_applied)):
			return false
	var refreshed: Dictionary = _ext.refresh_effect_input_digest_for_test()
	return _require("penalty fixture refreshes the effect input digest",
		bool(refreshed.get("ok", false)), str(refreshed))


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
	var settle_ok := _settle_ideology(_day, 3)
	if not _require("%s transition settles" % card, settle_ok,
			str(_ext.get_ideology_snapshot(_handle))):
		return false
	return _require("%s occupies an ideology slot" % card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) >= 1,
		str(_ext.get_ideology_snapshot(_handle)))


func _unequip_card(card: String) -> bool:
	var dense := _dense_card(card)
	if dense < 0:
		return false
	var unequip_day := _day + 3
	var submitted := _submit_ideology([
		{"op": 6, "day": unequip_day, "handle": _handle, "idea": dense},
	])
	if not _require("%s unequip is accepted" % card,
			bool(submitted.get("ok", false)), str(submitted)):
		return false
	var settle_ok := _settle_ideology(unequip_day, 3)
	if not _require("%s unequip settles" % card, settle_ok,
			"snapshot=%s report=%s effect=%s modifier=%s" % [
				str(_ext.get_ideology_snapshot(_handle)),
				str(_ext.get_ideology_report()),
				str(_ext.get_effect_report()),
				str(_ext.get_modifier_report())]):
		return false
	return _require("%s releases its ideology slot" % card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) == 0,
		str(_ext.get_ideology_snapshot(_handle)))


func _settle_ideology(first_day: int, days: int = 3) -> bool:
	for day in range(first_day, first_day + days):
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
		_ext.dispatch_effect_native_gameplay()
		var gameplay: Dictionary = _ext.run_gameplay_effects(day)
		if not bool(gameplay.get("ok", true)):
			return false
		var gameplay_ack: Dictionary = _ext.ack_effect_native_gameplay()
		if not bool(gameplay_ack.get("ok", true)):
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


func _read_country_stat(stat_key: String) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_COUNTRY, _handle, 0, stat_key, 1.0))


func _is_close(value: float, expected: float, tolerance: float = 0.0005) -> bool:
	return absf(value - expected) <= tolerance


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


func _metric(metric: int, cell: int) -> int:
	var result: Dictionary = _ext.sample_effect_metric_probe(metric, cell, _handle)
	if not bool(result.get("ok", false)):
		_fail("metric %d probe failed: %s" % [metric,
			str(result.get("reason", "unknown"))])
		return -1
	return int(result.get("value", -1))


func _metric_id(metric_key: String) -> int:
	var metric := PackedStringArray(_domain.metric_keys).find(metric_key)
	if metric < 0:
		_fail("metric key %s is absent from the Effect catalog" % metric_key)
	return metric


func _tagged(tag_name: String) -> PackedInt32Array:
	var anchor := int(_ext.query_country_anchor_cell(0))
	if anchor < 0:
		return PackedInt32Array()
	var tag_id := _tag_id(tag_name)
	if tag_id < 0:
		return PackedInt32Array()
	return _ext.query_effect_target_cells(
		anchor, SEL_OWN_TERRITORY, 32, tag_id + 1)


func _has_tag(tag_name: String, cell: int) -> bool:
	return _tagged(tag_name).has(cell)


func _tag_id(tag_name: String) -> int:
	var tags: Array = _domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == tag_name:
			return index
	_fail("tag %s is absent from the production dictionary" % tag_name)
	return -1


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
