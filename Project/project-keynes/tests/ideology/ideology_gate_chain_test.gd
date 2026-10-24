extends SceneTree

## §22 first gate: one REAL production card, end to end.
##
## Why this exists
## ---------------
## Every mechanism layer is green, yet until now no production card had ever
## left the national-Modifier path: the generator could not emit a program, so
## "condition changes -> the hit set changes -> the panel shows N cells" had
## never been demonstrated on content the player can actually draw. This test
## drives `idea.public_hygiene` from `data/ideologies/default_ideology_catalog.tres`
## through the whole chain:
##
##   Python table -> generated .tres -> IdeologyCatalog.compile_native_catalog
##   -> configure_ideologies -> reconcile -> Effect instance per target cell
##   -> dispatch -> Modifier command on that cell
##
## What is proved
## --------------
##  1. A world whose cells are below the settlement threshold submits ZERO
##     commands: the tag matched no cell, so the program had no target.
##  2. The same card in a world whose cells are settlements submits
##     2 commands per matched cell (the program emits two modifier rows).
##  3. Re-pointing the SAME program at `cell.metropolis` (a higher threshold)
##     returns to zero commands in that same populated world. The only thing
##     that changed is the tag, so the hit set is decided by tag evaluation --
##     not by the fixture being uniformly populated.
##
## The card-face count is the instance count, not the condition-pass count.
## With a pure tag selector they coincide, which is exactly why the gate card
## was chosen to be tag-shaped; `ideology_effect_report_test` covers the case
## where they diverge.
##
## Fixture notes (learned the hard way, see §23.3)
## -----------------------------------------------
##  * `configure_economy` must run: the anchor cell comes from
##    `_epoch_cell_country`, which only that call fills.
##  * Order is fixed: country -> economy -> effects -> ideologies.
##  * A card that ALSO carries a legacy cost row submits a real equip
##    transaction. Until that transaction is ACKed the activation reconcile is
##    deferred, so the fixture must: run_ideology_daily -> run_effect_daily ->
##    dispatch -> run_modifier_daily -> ack, and only then read the report.
##    `run_modifier_daily` is the one that makes the Modifier side complete the
##    request; without it the ack finds nothing complete and the transition sits
##    PENDING forever.
##  * Both daily slices have a work budget and must be continued until `done`.
##    One call per day silently emits only the first N instances (8 of 12 here).
##  * The support gate is disabled for this fixture (stances zeroed, adopt
##    threshold 0). Class opinion is a different authority with its own test
##    (`ideology_opinion_synergy_test`); leaving it on would only prove that
##    this fixture has no class data.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const CELLS := 12
const CARD_ID := "idea.public_hygiene"
const PROGRAM_PREFIX := "ideology.effect.public_hygiene_l1"
const Q16_ONE := 65536
## Below `TargetTagDictionary.FRONTIER_POPULATION * 10000` (a cell nobody lives
## in yet) so no size tag can match.
const POPULATION_EMPTY := 2
## At or above the settlement threshold. Read from the dictionary rather than
## hard-coded, so a threshold recalibration moves the fixture with it instead
## of silently turning the gate red.
const SETTLEMENT_MIN := 400
const COMMANDS_PER_CELL := 2

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _economy_ir: Dictionary = {}
var _country_ir: Dictionary = {}


func _init() -> void:
	_run()
	print("ideology gate chain: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	_country_ir = CountryCatalogScript.compile_native_catalog()
	_expect("country catalog compiles", bool(_country_ir.get("ok", false)))
	_economy_ir = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(_economy_ir.get("ok", false)))
	if _country_ir.is_empty() or _economy_ir.is_empty():
		return
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if not _require("production ideology catalog loads", catalog != null):
		return
	var native: Dictionary = catalog.compile_native_catalog(_country_ir, _economy_ir)
	if not _require("production ideology catalog compiles",
			bool(native.get("ok", false)), String(native.get("reason", ""))):
		return
	var dense := (native["ideology_ids"] as PackedStringArray).find(CARD_ID)
	if not _require("gate card is in the production catalog", dense >= 0,
			"dense=%d" % dense):
		return

	_test_empty_world(native, dense)
	_test_settlement_world(native, dense)
	_test_tag_is_the_switch(native, dense)


## 1. Nobody lives here yet: the settlement tag matches nothing, so the card
## owns no instance and submits no command.
func _test_empty_world(native: Dictionary, dense: int) -> void:
	var fixture := _fixture(native, dense, POPULATION_EMPTY, -1)
	if fixture.is_empty():
		return
	var report: Dictionary = fixture["report"]
	_expect("empty world: no instance is created",
		int(report.get("count", -1)) == 0, str(report.get("count", -1)))
	_expect("empty world: no modifier command is submitted",
		int(fixture["dispatch"].get("submitted_commands", -1)) == 0,
		str(fixture["dispatch"].get("submitted_commands", -1)))


## 2. The same card in a settlement world: one instance per matched cell and two
## commands per instance.
func _test_settlement_world(native: Dictionary, dense: int) -> void:
	var fixture := _fixture(native, dense, SETTLEMENT_MIN, -1)
	if fixture.is_empty():
		return
	var report: Dictionary = fixture["report"]
	var cells := _distinct_targets(report)
	_expect("settlement world: every owned cell is a target",
		cells == CELLS, "cells=%d expected=%d" % [cells, CELLS])
	_expect("settlement world: card face counts one instance per target cell",
		int(report.get("count", -1)) == cells,
		"count=%d cells=%d" % [int(report.get("count", -1)), cells])
	var submitted := int(fixture["dispatch"].get("submitted_commands", -1))
	_expect("settlement world: two modifier commands per target cell",
		submitted == cells * COMMANDS_PER_CELL,
		"submitted=%d expected=%d" % [submitted, cells * COMMANDS_PER_CELL])


## 3. The switch is the tag, not the population. Re-point the program at
## `cell.metropolis` in the same populated world and the hit set empties.
func _test_tag_is_the_switch(native: Dictionary, dense: int) -> void:
	var metropolis := _tag_id("cell.metropolis")
	if not _require("metropolis tag is in the catalog", metropolis >= 0):
		return
	var fixture := _fixture(native, dense, SETTLEMENT_MIN, metropolis)
	if fixture.is_empty():
		return
	_expect("tag switch: swapping the tag empties the hit set",
		int(fixture["report"].get("count", -1)) == 0,
		str(fixture["report"].get("count", -1)))
	_expect("tag switch: swapping the tag submits no command",
		int(fixture["dispatch"].get("submitted_commands", -1)) == 0,
		str(fixture["dispatch"].get("submitted_commands", -1)))


## `tag_override >= 0` rewrites the L1 program's tag id before compiling the
## effect catalog, which is the only thing differing in test 3.
func _fixture(native_ideology: Dictionary, dense: int, population: int,
		tag_override: int) -> Dictionary:
	var ext: Object = _build_ext(CELLS)
	var economy_outcome: Dictionary = ext.configure_economy(_country_ir,
		load("res://data/economy/default_economy.tres").to_native_profile(),
		CELLS, 97)
	if not bool(economy_outcome.get("ok", false)):
		_expect("economy configures", false, str(economy_outcome))
		return {}
	if not _bootstrap_economy(ext, population):
		return {}
	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		_expect("effect domain catalog builds", false)
		return {}
	if tag_override >= 0:
		var patched := 0
		for definition in domain.definitions:
			if definition == null:
				continue
			if not String(definition.key).begins_with(PROGRAM_PREFIX):
				continue
			definition.target_selector_param[1] = tag_override + 1
			patched += 1
		_expect("tag switch: the L1 program was re-pointed", patched == 1,
			"patched=%d" % patched)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	if not bool(effect_ir.get("ok", false)):
		_expect("effect catalog compiles", false, str(effect_ir.get("reason", "")))
		return {}
	effect_ir.erase("ok")
	var effects_configured: Dictionary = ext.configure_effects(effect_ir)
	if not bool(effects_configured.get("ok", false)):
		_expect("effect catalog configures", false, str(effects_configured))
		return {}
	var ideology_configured: Dictionary = ext.configure_ideologies(
		_support_gate_off(native_ideology))
	if not bool(ideology_configured.get("ok", false)):
		_expect("ideology catalog configures", false, str(ideology_configured))
		return {}
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("fixture resolves a country handle", handle != 0):
		return {}
	var submitted: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": dense},
		{"op": 5, "day": 0, "handle": handle, "idea": dense},
	]))
	if not _require("gate card is discovered and adopted",
			bool(submitted.get("ok", false)), str(submitted)):
		return {}
	# Day 0 submits the equip transition. While that transaction is pending the
	# activation reconcile is deliberately deferred, so the fixture has to settle
	# it before the program can own any instance. This is the one ordering fact
	# a program card introduces that a program-only fixture never sees.
	if not _require("ideology day 0 submits the equip transition",
			bool(ext.run_ideology_daily(0).get("ok", false))):
		return {}
	ext.run_effect_daily(0)
	ext.dispatch_effect_native_modifier()
	ext.run_modifier_daily(0)
	ext.ack_effect_native_modifier()
	# Day 0's dispatch belongs to the equip transition (the card's cost row), not
	# to the program. The gate measures the program, so counting starts on day 1.
	var best_dispatch := {"submitted_commands": 0}
	for day in range(1, 4):
		# The daily slice has a visit budget; a country with more active cards
		# than one slice can carry needs same-day continuation, exactly like the
		# world host does. Folding that in here is why the fixture sees every
		# target on day 1 instead of a fraction of them.
		for _slice in range(16):
			var slice: Dictionary = ext.run_ideology_daily(day)
			if not _require("ideology day %d runs" % day,
					bool(slice.get("ok", false)), str(slice)):
				return {}
			if bool(slice.get("done", false)):
				break
		for _effect_slice in range(16):
			var effect_slice: Dictionary = ext.run_effect_daily(day)
			if not bool(effect_slice.get("ok", false)):
				break
			if bool(effect_slice.get("done", true)):
				break
		var day_dispatch: Dictionary = ext.dispatch_effect_native_modifier()
		if int(day_dispatch.get("submitted_commands", 0)) > int(
				best_dispatch.get("submitted_commands", 0)):
			best_dispatch = day_dispatch
		ext.run_modifier_daily(day)
		ext.ack_effect_native_modifier()
	var report: Dictionary = ext.get_ideology_effect_instance_report(handle)
	return {"ext": ext, "report": report, "dispatch": best_dispatch}


## Zeroes the stance table and the support thresholds so `adopt` does not wait
## for a committed class-opinion snapshot. Everything else stays production.
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


func _tag_id(tag_name: String) -> int:
	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		return -1
	var tags: Array = domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == tag_name:
			return index
	return -1


func _distinct_targets(report: Dictionary) -> int:
	var handles: PackedInt64Array = report.get("target_handles", PackedInt64Array())
	var seen := {}
	for handle in handles:
		seen[int(handle)] = true
	return seen.size()


func _build_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	# cell_count must be the world size: a cell-domain modifier applied to cell 7
	# in a 1-cell store is rejected as out of range.
	_expect("modifier catalog configures",
		bool(ext.configure_modifiers(modifier_catalog, cells).get("ok", false)))
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(cells, 0.5))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid2: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid2, 0, _u8_fill(cells, 0))
	for i in range((_country_ir.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(_country_ir.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(_country_ir.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _f32_fill(cells, 1000000.0))
		ext.write_f32_range(extra_sid, 0, _f32_fill(cells, 0.0))
	_expect("country configures", bool(ext.configure_country(_country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, cells, 97).get("ok", false)))
	var territory := PackedInt32Array()
	for cell in range(cells):
		territory.append(cell)
	var country_outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.ideology_gate_test"]),
		"country_names": PackedStringArray(["理念闸门测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, cells]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(cells, 0))
	_expect("country bootstraps", bool(country_outcome.get("ok", false)),
		str(country_outcome))
	return ext


func _f32_fill(cells: int, value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(cells)
	out.fill(value)
	return out


func _u8_fill(cells: int, value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(cells)
	out.fill(value)
	return out


func _bootstrap_economy(ext: Object, population: int) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		_expect("fixture finds its building type and owner signature", false,
			"building=%d signature=%d" % [building_id, owner_sig])
		return false
	var stock := PackedInt64Array()
	stock.resize((_country_ir.good_ids as PackedStringArray).size() * CELLS)
	stock.fill(100000000)
	var seeded_cells := PackedInt32Array()
	var seeded_signatures := PackedInt32Array()
	var seeded_population := PackedInt64Array()
	var seeded_funds := PackedInt64Array()
	var seeded_buildings := PackedInt32Array()
	var seeded_owners := PackedInt32Array()
	var seeded_counts := PackedInt64Array()
	for cell in range(CELLS):
		seeded_cells.append(cell)
		seeded_signatures.append(owner_sig)
		seeded_population.append(population)
		seeded_funds.append(1000000000000000)
		seeded_buildings.append(building_id)
		seeded_owners.append(owner_sig)
		seeded_counts.append(1)
	var outcome: Dictionary = ext.bootstrap_economy({
		"cell_indices": seeded_cells,
		"signature_ids": seeded_signatures,
		"population": seeded_population,
		"funds": seeded_funds,
		"forced_named_cells": seeded_cells,
		"founder_family_cells": seeded_cells,
		"founder_family_building_type_ids": seeded_buildings,
		"founder_family_owner_signature_ids": seeded_owners,
	}, {
		"stock": stock,
		"building_cells": seeded_cells,
		"building_type_ids": seeded_buildings,
		"building_owner_signature_ids": seeded_owners,
		"building_counts": seeded_counts,
	})
	_expect("economy bootstraps", bool(outcome.get("ok", false)), str(outcome))
	return bool(outcome.get("ok", false))


func _commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {
		"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"source_priorities": PackedInt32Array(), "producer_ids": PackedInt32Array(),
		"sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array(),
	}
	for row in rows:
		out.opcodes.append(int(row.op))
		out.effective_days.append(int(row.day))
		out.source_priorities.append(0)
		out.producer_ids.append(1)
		out.sequences.append(_next_sequence)
		_next_sequence += 1
		out.country_handles.append(int(row.handle))
		out.ideology_ids.append(int(row.get("idea", -1)))
		out.values_q16.append(int(row.get("value", 0)))
		out.offer_generations.append(int(row.get("offer", 0)))
		out.choice_indices.append(int(row.get("choice", -1)))
		out.gate_ids.append(-1)
	return out


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		push_error("[FAIL] %s" % label)
	else:
		push_error("[FAIL] %s (%s)" % [label, detail])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition
