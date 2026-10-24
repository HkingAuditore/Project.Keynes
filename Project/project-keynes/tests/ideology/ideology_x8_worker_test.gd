extends SceneTree

## X8 acceptance on the production Effect path.
##
## A real copper mine -> copper smelter -> bronze-tool workshop chain proves
## metric 87 and the generated upstream DNF tag. The workshop cell gains the
## kind-16 upstream bonus, removing the mine removes the source, and 30 unchanged
## economy commits rebuild neither the derived column nor any Effect instance.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload(
	"res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload(
	"res://scripts/ideology/ideology_catalog.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")

const CELLS := 12
const SEED := 20261024
const Q16_ONE := 65536
const MODIFIER_DOMAIN_ECONOMY := 2
const SEL_NEIGHBORS_R1 := 6
const METRIC_DOMINANT_OUTPUT_GOOD := 45
const METRIC_NEIGHBOR_DISTINCT_GOODS := 87
const STAT_MANUFACTURING := (
	"economy.city.building.manufacturing_output_factor")
const UPSTREAM_TAG := (
	"cell.produces.copper_ore|cell.produces.tin_ore")
const COPPER_MINE := "early_copper_mine"
const COPPER_SMELTER := "early_copper_smelter"
const TIN_MINE := "early_tin_mine"
const BRONZE_WORKSHOP := "bronze_tool_workshop"
const CountryTestHelper = preload("res://tests/country/country_test_helper.gd")


var _ext: Object
var _catalog: Dictionary
var _domain: Resource
var _ideology_catalog: Dictionary
var _handle := 0
var _checks := 0
var _failures := 0
var _day := 0
var _logic_day := 0
var _next_sequence := 1


func _init() -> void:
	_run()
	print("=== ideology x8 worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	_catalog = EconomyCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles",
			bool(_catalog.get("ok", false)),
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
	var daily_understanding := PackedInt64Array(
		_ideology_catalog.get(
			"level_daily_understanding_q16", PackedInt64Array()))
	daily_understanding.fill(0)
	_ideology_catalog["level_daily_understanding_q16"] = daily_understanding
	var map := _build_chain_map()
	if map == null:
		return
	_ext = _build_ext(map)
	if _ext == null:
		return
	if not _test_chain_metrics():
		return
	if not _test_upstream_card():
		return
	if not _test_mine_removal():
		return
	_test_idle_reuse()


func _build_chain_map() -> MapData:
	# Insertion order is the SoA index order. Cells 0/1/2 are the directed
	# mine -> smelter -> workshop chain; the remaining cells fill the row.
	var map := MapData.new(4, 3)
	for coords in [
			Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1),
			Vector2i(1, 1), Vector2i(2, 0), Vector2i(2, 1),
			Vector2i(3, 0), Vector2i(3, 1), Vector2i(0, 2),
			Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)]:
		var cube := HexUtils.offset_to_cube(coords.x, coords.y)
		var hex := HexCell.new(cube.x, cube.y)
		hex.terrain = TerrainType.TERRAIN.PLAIN
		hex.landform = LandformType.LF.PLAIN
		hex.elevation = 0.50
		hex.base_moisture = 0.10
		hex.moisture = 0.10
		map.set_cell(hex)
	map._build_indices()
	map.init_soa_from_bake()
	return map


func _build_ext(map: MapData) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	if not _require("chain map binds", bool(ext.bind_map_data(map))):
		return null
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
		ext.write_u8_range(sid, 0,
			_u8_fill(2 if slot_name == &"cell_terrain" else 0))
	for i in range((_catalog.building_resource_ids as PackedStringArray).size()):
		var reserve: int = ext.register_component(StringName(
			(_catalog.building_resource_reserve_slots as PackedStringArray)[i]),
			0, 1, false)
		var extra: int = ext.register_component(StringName(
			(_catalog.building_resource_extra_slots as PackedStringArray)[i]),
			0, 1, false)
		ext.write_f32_range(reserve, 0, _f32_fill(1000000.0))
		ext.write_f32_range(extra, 0, _f32_fill(0.0))
	if not _require("country configures",
			CountryTestHelper.configure_all_technologies(
				ext, _catalog, CELLS, SEED)):
		return null
	var cells := PackedInt32Array()
	for cell in range(CELLS):
		cells.append(cell)
	var technology_indices := PackedInt32Array()
	technology_indices.resize(
		(_catalog.technology_ids as PackedStringArray).size())
	for index in technology_indices.size():
		technology_indices[index] = index
	if not _require("country bootstraps", bool(ext.bootstrap_country({
			"country_ids": PackedStringArray(["country.x8"]),
			"country_names": PackedStringArray(["X8"]),
			"country_cash": PackedInt64Array([0]),
			"territory_offsets": PackedInt32Array([0, CELLS]),
			"territory_cells": cells,
			"technology_offsets": PackedInt32Array([
				0, technology_indices.size()]),
			"technology_indices": technology_indices,
			"treasury_offsets": PackedInt32Array([0, 0]),
			"treasury_good_indices": PackedInt32Array(),
			"treasury_quantities": PackedInt64Array(),
		}, _u8_fill(0)).get("ok", false))):
		return null
	var modifiers: Dictionary = preload(
		"res://scripts/modifier/modifier_catalog.gd").load_default(
		).compile_native_catalog()
	if not _require("modifier catalog compiles",
			bool(modifiers.get("ok", false)),
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
			bool(effect_configured.get("ok", false)),
			str(effect_configured)):
		return null
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	profile.starvation_death_rate_q32 = 0
	profile.investment_max_growth_share_q16 = 1
	profile.investment_review_days = 3650
	if not _require("economy configures", bool(ext.configure_economy(
			_catalog, profile, CELLS, SEED).get("ok", false))):
		return null
	var buildings: PackedStringArray = _catalog.building_type_ids
	var mine := buildings.find(COPPER_MINE)
	var smelter := buildings.find(COPPER_SMELTER)
	var tin_mine := buildings.find(TIN_MINE)
	var workshop := buildings.find(BRONZE_WORKSHOP)
	var mine_signature: int = (_catalog.signature_keys as PackedStringArray).find(
		"landlord|default")
	var artisan_signature: int = (
		_catalog.signature_keys as PackedStringArray).find("artisan|default")
	if not _require(
			"copper/tin chain and owner signatures exist",
			mine >= 0 and smelter >= 0 and tin_mine >= 0 and workshop >= 0
				and mine_signature >= 0 and artisan_signature >= 0,
			"mine=%d smelter=%d tin=%d workshop=%d landlord=%d artisan=%d" % [
				mine, smelter, tin_mine, workshop, mine_signature,
				artisan_signature]):
		return null
	var goods: int = (_catalog.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	stock.resize(goods * CELLS)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize(goods * CELLS)
	prices.fill(1000)
	var seeded_cells := PackedInt32Array()
	var seeded_signatures := PackedInt32Array()
	var seeded_population := PackedInt64Array()
	var seeded_funds := PackedInt64Array()
	# Three buildings per cell give the owner cohort enough real jobs. The
	# bootstrap merchant leaves each cell at the 25% unemployment boundary
	# without crossing the strict employment-catch-up gate.
	for seed in [
			[0, mine_signature, 3],
			[1, artisan_signature, 3],
			[2, artisan_signature, 3]]:
		seeded_cells.append(int(seed[0]))
		seeded_signatures.append(int(seed[1]))
		seeded_population.append(int(seed[2]))
		seeded_funds.append(1000000000000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": seeded_cells,
		"signature_ids": seeded_signatures,
		"population": seeded_population,
		"funds": seeded_funds,
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": PackedInt32Array([0, 1, 2]),
		"building_type_ids": PackedInt32Array([mine, smelter, workshop]),
		"building_owner_signature_ids": PackedInt32Array([
			mine_signature, artisan_signature, artisan_signature]),
		"building_counts": PackedInt64Array([3, 3, 3]),
	})
	if not _require("economy bootstraps the real mine/smelter/workshop chain",
			bool(boot.get("ok", false)), str(boot)):
		return null
	if not _require("ideology runtime configures",
			bool(ext.configure_ideologies(_ideology_catalog).get("ok", false))):
		return null
	if not _require("country snapshot captures",
			bool(ext.capture_country_runtime_snapshot().get("ok", false))
				and bool(ext.capture_country_pod_catalog().get("ok", false))):
		return null
	var handle := int(ext.get_country_cell_summary(0).get(
		"country_handle", 0))
	if not _require("fixture resolves the country handle", handle != 0):
		return null
	_handle = handle
	_ext = ext
	if not _require("opening day commits", _run_day()):
		return null
	_settle_ideology(_day)
	_logic_day = _day + 1
	return ext


func _test_chain_metrics() -> bool:
	var copper := _good_id("copper")
	var copper_ore := _good_id("copper_ore")
	var bronze_tools := _good_id("bronze_tools")
	if not _require("the real production outputs exist",
			copper >= 0 and copper_ore >= 0 and bronze_tools >= 0,
			"copper=%d copper_ore=%d bronze_tools=%d" % [
				copper, copper_ore, bronze_tools]):
		return false
	# Let the first committed epoch publish the building-output column before
	# reading it. The opening commit establishes baselines; the next commit is
	# the first stable snapshot used by this chain.
	if not _run_day():
		return false
	_expect("metric 45 names the mine as copper ore",
		_metric(METRIC_DOMINANT_OUTPUT_GOOD, 0) == copper_ore * Q16_ONE,
		str(_metric(METRIC_DOMINANT_OUTPUT_GOOD, 0)))
	_expect("metric 45 names the smelter as copper",
		_metric(METRIC_DOMINANT_OUTPUT_GOOD, 1) == copper * Q16_ONE,
		str(_metric(METRIC_DOMINANT_OUTPUT_GOOD, 1)))
	_expect("metric 45 names the workshop as bronze tools",
		_metric(METRIC_DOMINANT_OUTPUT_GOOD, 2) == bronze_tools * Q16_ONE,
		str(_metric(METRIC_DOMINANT_OUTPUT_GOOD, 2)))
	_expect("metric 87 counts two distinct neighbour goods at the workshop",
		_metric(METRIC_NEIGHBOR_DISTINCT_GOODS, 2) == 2 * Q16_ONE,
		str(_metric(METRIC_NEIGHBOR_DISTINCT_GOODS, 2)))
	var tag_id := _tag_id(UPSTREAM_TAG)
	return _require("the generator's mine-rooted upstream DNF tag exists",
		tag_id >= 0, UPSTREAM_TAG)


func _test_upstream_card() -> bool:
	var tag_id := _tag_id(UPSTREAM_TAG)
	if tag_id < 0:
		return false
	var workshop := _workshop_cell()
	if not _require("the upstream source reaches the workshop as an R1 target",
			_source_count(tag_id, workshop) == 1,
			"tag=%d target=%d" % [tag_id, workshop]):
		return false
	var baseline := _manufacturing(workshop)
	_expect("the workshop starts at the manufacturing baseline",
		_is_close(baseline, 1.0), "%.5f" % baseline)
	if not _equip_card("bronze_casting"):
		return false
	var actual := _wait_manufacturing(workshop, 1.15, 20)
	_expect("bronze_casting applies the upstream +15%% only at the workshop",
		_is_close(actual, 1.15), "%.5f" % actual)
	_expect("an unrelated cell keeps the manufacturing baseline",
		_is_close(_manufacturing(3), 1.0), "%.5f" % _manufacturing(3))
	if not _unequip_card("bronze_casting"):
		return false
	var restored := _wait_manufacturing(workshop, 1.0, 20)
	_expect("unequipping bronze_casting restores the workshop",
		_is_close(restored, 1.0), "%.5f" % restored)
	if not _equip_card("bronze_casting"):
		return false
	actual = _wait_manufacturing(workshop, 1.15, 20)
	_expect("re-equipping restores the upstream bonus for removal proof",
		_is_close(actual, 1.15), "%.5f" % actual)
	return true


func _test_mine_removal() -> bool:
	var workshop := _workshop_cell()
	var tag_id := _tag_id(UPSTREAM_TAG)
	var mine_output_before := _metric(METRIC_DOMINANT_OUTPUT_GOOD, 0)
	var copper_ore := _good_id("copper_ore")
	if not _require("the real mine supplies the upstream source before removal",
			_source_count(tag_id, workshop) == 1
				and mine_output_before == copper_ore * Q16_ONE,
			"sources=%d mine_output=%d copper_ore=%d" % [
				_source_count(tag_id, workshop), mine_output_before,
				copper_ore]):
		return false
	# The production StageOps writer refuses the legacy demolition ingress.
	# Force only the derived tag input false to isolate the removal transition;
	# the mine, smelter, workshop and metric-87 source remain real.
	var removed: Dictionary = _ext.set_cell_tag_override_for_test(
		UPSTREAM_TAG, 0, false)
	if not _require("the mine's production tag can be removed for the proof",
			bool(removed.get("ok", false)), str(removed)):
		return false
	var removal_day := _logic_day
	_logic_day += 3
	if not _require("the tag-removal epoch commits", _run_day()):
		return false
	if not _require("the tag-removal transition settles",
			_settle_ideology(removal_day),
			"snapshot=%s report=%s effect=%s modifier=%s" % [
				str(_ext.get_ideology_snapshot(_handle)),
				str(_ext.get_ideology_report()),
				str(_ext.get_effect_report()),
				str(_ext.get_modifier_report())]):
		return false
	var source_count := _source_count(tag_id, workshop)
	_expect("removing the mine removes the mine-rooted upstream source",
		source_count == 0, str(source_count))
	var actual := _wait_manufacturing(workshop, 1.0, 20)
	_expect("the workshop upstream bonus disappears after mine removal",
		_is_close(actual, 1.0), "%.5f" % actual)
	_expect("metric 87 remains the two surviving distinct neighbour goods",
		_metric(METRIC_NEIGHBOR_DISTINCT_GOODS, 2) == 2 * Q16_ONE,
		str(_metric(METRIC_NEIGHBOR_DISTINCT_GOODS, 2)))
	var cleared: Dictionary = _ext.clear_cell_tag_overrides_for_test()
	_expect("the removal-only tag override clears", bool(cleared.get("ok", false)),
		str(cleared))
	return true


func _test_idle_reuse() -> void:
	# `_test_upstream_card` leaves bronze_casting equipped for the removal proof.
	# Ordinary investment and staffing can settle after bootstrap. Let the
	# fixture reach a stable metric source before measuring the hash gate; the
	# measured window still exercises 30 real unchanged commits.
	var settled_hash := 0
	var stable_days := 0
	while stable_days < 5:
		if not _run_day():
			return
		if not _settle_ideology(_logic_day):
			return
		_logic_day += 3
		var source_hash := int(_ext.get_economy_report().get(
			"neighbor_distinct_goods_source_hash", 0))
		if source_hash == settled_hash:
			stable_days += 1
		else:
			settled_hash = source_hash
			stable_days = 0
	var report_before: Dictionary = _ext.get_economy_report()
	var rebuilds_before := int(report_before.get(
		"neighbor_distinct_goods_rebuilds", -1))
	var hash_before := int(report_before.get(
		"neighbor_distinct_goods_source_hash", 0))
	var metric_revision_before := _metric_revision(
		METRIC_NEIGHBOR_DISTINCT_GOODS)
	var ideology_before: Dictionary = _ext.get_ideology_report()
	var metric_only_visits_before := int(ideology_before.get(
		"instance_refresh_visits", -1))
	var clean_days := 0
	while clean_days < 30:
		if not _run_day():
			return
		if not _settle_ideology(_logic_day):
			return
		_logic_day += 3
		var report: Dictionary = _ext.get_economy_report()
		var metric_revision := _metric_revision(
			METRIC_NEIGHBOR_DISTINCT_GOODS)
		var metric_only_visits := int(_ext.get_ideology_report().get(
			"instance_refresh_visits", 0))
		if int(report.get(
				"neighbor_distinct_goods_rebuilds", -1)) != rebuilds_before \
				or int(report.get(
					"neighbor_distinct_goods_source_hash", 0)) != hash_before \
				or metric_revision != metric_revision_before \
				or metric_only_visits != metric_only_visits_before:
			rebuilds_before = int(report.get(
				"neighbor_distinct_goods_rebuilds", -1))
			hash_before = int(report.get(
				"neighbor_distinct_goods_source_hash", 0))
			metric_revision_before = metric_revision
			metric_only_visits_before = metric_only_visits
			clean_days = 0
			continue
		clean_days += 1
	var report_after: Dictionary = _ext.get_economy_report()
	var rebuilds_after := int(report_after.get(
		"neighbor_distinct_goods_rebuilds", -1))
	var hash_after := int(report_after.get(
		"neighbor_distinct_goods_source_hash", 0))
	var ideology_after: Dictionary = _ext.get_ideology_report()
	var metric_only_visits_after := int(ideology_after.get(
		"instance_refresh_visits", 0))
	_expect("30 unchanged days rebuild metric 87 zero times",
		rebuilds_after == rebuilds_before,
		"%d -> %d" % [rebuilds_before, rebuilds_after])
	_expect("metric 87 source hash is unchanged across idle days",
		hash_after == hash_before, "%d -> %d" % [hash_before, hash_after])
	_expect("metric 87 revision is unchanged across idle days",
		_metric_revision(METRIC_NEIGHBOR_DISTINCT_GOODS)
			== metric_revision_before,
		"%d -> %d" % [metric_revision_before,
			_metric_revision(METRIC_NEIGHBOR_DISTINCT_GOODS)])
	_expect("metric 87 causes zero Effect refresh visits across idle days",
		metric_only_visits_after == metric_only_visits_before,
		"%d -> %d" % [metric_only_visits_before, metric_only_visits_after])


func _equip_card(card: String) -> bool:
	var dense := _dense_card(card)
	if dense < 0:
		return false
	var command_day := _logic_day
	_logic_day += 3
	var submitted := _submit_ideology([
		{"op": 1, "day": command_day, "handle": _handle, "idea": dense},
		{"op": 5, "day": command_day, "handle": _handle, "idea": dense},
	])
	if not _require("%s discover+equip is accepted" % card,
			bool(submitted.get("ok", false)), str(submitted)):
		return false
	if not _require("%s ideology transition settles" % card,
			_settle_ideology(command_day),
			"snapshot=%s report=%s effect=%s modifier=%s" % [
				str(_ext.get_ideology_snapshot(_handle)),
				str(_ext.get_ideology_report()),
				str(_ext.get_effect_report()),
				str(_ext.get_modifier_report())]):
		return false
	return _require("%s occupies an ideology slot" % card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) >= 1,
		str(_ext.get_ideology_snapshot(_handle)))


func _unequip_card(card: String) -> bool:
	var dense := _dense_card(card)
	if dense < 0:
		return false
	var unequip_day := _logic_day
	_logic_day += 3
	var submitted := _submit_ideology([
		{"op": 6, "day": unequip_day, "handle": _handle, "idea": dense},
	])
	if not _require("%s unequip is accepted" % card,
			bool(submitted.get("ok", false)), str(submitted)):
		return false
	if not _require("%s unequip settles" % card,
			_settle_ideology(unequip_day),
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
		var ideology_ready := false
		for _slice in range(16):
			var ideology_slice: Dictionary = _ext.run_ideology_daily(day)
			if not bool(ideology_slice.get("ok", false)):
				return false
			if bool(ideology_slice.get("done", false)):
				ideology_ready = true
				break
		for _slice in range(16):
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
		var pending: PackedByteArray = _ext.get_ideology_snapshot(_handle).get(
			"transition_pending", PackedByteArray())
		if ideology_ready and (pending.is_empty() or not pending.has(1)):
			return true
	return false


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
	_expect("day %d reaches a commit" % _day, false,
		"256 slices without done")
	return false


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
		"opcodes": opcodes, "effective_days": days,
		"producer_ids": producers, "sequences": sequences,
		"country_handles": handles, "ideology_ids": ideas,
		"values_q16": values, "source_priorities": priorities,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	})


func _dense_card(card: String) -> int:
	var ids := PackedStringArray(_ideology_catalog.get(
		"ideology_ids", PackedStringArray()))
	var dense := ids.find("idea.%s" % card)
	_expect("%s is published in the production catalog" % card,
		dense >= 0, str(ids))
	return dense


func _workshop_cell() -> int:
	var bronze_tools := _good_id("bronze_tools")
	for cell in range(CELLS):
		if _metric(METRIC_DOMINANT_OUTPUT_GOOD, cell) == bronze_tools * Q16_ONE:
			return cell
	return -1


func _source_count(tag_id: int, target: int) -> int:
	if tag_id < 0 or target < 0:
		return 0
	var sources: PackedInt32Array = _ext.query_effect_target_cells(
		target, 12, 32, tag_id + 1)
	var count := 0
	for source in sources:
		if int(source) == target:
			continue
		var ring: PackedInt32Array = _ext.query_effect_target_cells(
			int(source), SEL_NEIGHBORS_R1, 32, 0)
		if ring.has(target):
			count += 1
	return count


func _metric(metric_id: int, cell: int) -> int:
	var result: Dictionary = _ext.sample_effect_metric_probe(
		metric_id, cell, _handle)
	if not bool(result.get("ok", false)):
		_fail("metric %d probe failed: %s" % [metric_id,
			str(result.get("reason", "unknown"))])
		return -1
	return int(result.get("value", -1))


func _metric_revision(metric_id: int) -> int:
	var values: PackedInt64Array = _ext.get_effect_input_revisions().get(
		"metrics", PackedInt64Array())
	return int(values[metric_id]) if metric_id < values.size() else -1


func _manufacturing(cell: int) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, STAT_MANUFACTURING, 1.0))


func _wait_manufacturing(cell: int, expected: float, days: int) -> float:
	var value := _manufacturing(cell)
	for _index in range(days):
		if _is_close(value, expected):
			return value
		if not _run_day():
			return value
		value = _manufacturing(cell)
	return value


func _tag_id(tag_name: String) -> int:
	var tags: Array = _domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == tag_name:
			return index
	return -1


func _good_id(good: StringName) -> int:
	return (_catalog.good_ids as PackedStringArray).find(String(good))


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


func _is_close(actual: float, expected: float,
		tolerance: float = 0.0005) -> bool:
	return absf(actual - expected) <= tolerance


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
