extends SceneTree

## L0-2 acceptance: an ideology program that conditions on a metric must
## receive a published metric column for every instance it owns.
##
## Why this exists
## ---------------
## Before this, `NativeIdeologyRuntime` never called `set_metric`. Effect
## instances therefore held a metric slab of zeros with every `present` bit
## clear, so a `METRIC_GTE` condition compared `0 >= threshold` forever:
## permanently false for any positive threshold, permanently true for `LTE 0`.
## The six V1..V6 mechanism cards in `data/ideologies/default_ideology_effects.tres`
## were only ever asserted as declarations (`ideology_mechanism_matrix_test`
## says so itself: "does not simulate the economy"), which is how the gap
## stayed invisible.
##
## What is proved here
## -------------------
##  * a metric-conditioned program creates one instance on the country's anchor
##    cell, and that instance carries a *present* metric column;
##  * the same metric with an impossible threshold blocks the emitted command,
##    which is only possible if the condition reads the published value rather
##    than a constant 0;
##  * a program with no metric condition publishes nothing, so the publisher
##    cannot be paying for cards that do not ask for metrics.
##
## Fixture notes
## -------------
## A cell-targeted (target_domain 2) program resolves through
## `country_anchor_cell()`, which reads `_epoch_cell_country`. That column is
## filled by `configure_economy`, not by `configure_country` -- a fixture that
## only configures the country sees zero targets, which is exactly why the
## pre-existing ideology tests only ever used country-domain programs.
## `target_selector_kind = OWNER` keeps the target at the anchor cell so the
## test does not depend on a neighbour snapshot.
##
## This file also owns the **domain-2 real fixture** (`_test_cell_domain_*`).
## Every other cell-domain test either drives a single-cell world or synthesises
## its catalog in C++; neither can tell "one instance per resolved cell" apart
## from the failure the whole redesign exists to fix -- a card that lands on the
## country's first cell and nowhere else. The multi-cell section seeds a real
## 12-cell territory and counts instances, so a program that silently collapses
## to the anchor fails on the count instead of passing on a single-cell world.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyEffectDefinitionScript = preload("res://scripts/ideology/ideology_effect_definition.gd")

const Q16_ONE := 65536
## The authored card row that routes through a declared program.
const CARD_DEFINITION_KEY := "v1_granary_belt"
const PROGRAM_KEY := "ideology.effect.v1_granary_belt"
## Modifier the fixture program drives. A cell-domain (`target_domain = 2`)
## managed definition is validated against `ModifierRuntime::ECONOMY`, so the
## command must name an economy-domain modifier key -- `family.city.*` and
## `economy.city.*` rows are the ones the shipped V2..V6 cards use.
const TEST_MODIFIER_KEY := "economy.city.output_factor"
## `cell.population` sits at index 9 of the authoritative metric table in
## `effect_domain_catalog.gd`. Asserted in `_metric_keys()` so a table reorder
## fails here instead of silently measuring a different metric.
const METRIC_CELL_POPULATION := 9
## Far above any fixture population, so the gate can only pass if it reads the
## published value (a hard-coded 0 would make it pass).
const IMPOSSIBLE_POPULATION_Q16 := 1 << 40
## The seeded cell population in both sampling fixtures. Two worlds that differ
## only here must publish two different values, which is what proves the sample
## is live rather than a constant.
const POPULATION_BASELINE := 2
const POPULATION_SCALED := 64

const OP_METRIC_GTE := 2
const OP_METRIC_LTE := 3
const OP_CONST := 1
const OP_EMIT_COMMAND := 11
const SEL_OWNER := 0
## Selector kinds the shipped cell-domain cards use. Mirrored from
## `IdeologyEffectDefinition.TargetSelectorKind`; the mechanism-matrix test pins
## the same numbers from the content side.
const SEL_NEIGHBORS_R1 := 6
const SEL_NEIGHBORS_R2 := 7
const SEL_SAME_TERRAIN_COMPONENT := 8
const SEL_DISTANCE_N := 11
const SEL_TAG_ANY_CELL := 13
const DOMAIN_SETTLEMENT_CELL := 2
## `ModifierRuntime::ECONOMY`. A managed cell-domain definition is rejected with
## `effect_family_target_adapter_mismatch` unless every command targets it.
const MODIFIER_DOMAIN_ECONOMY := 2

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _metric_keys_cache := PackedStringArray()


func _init() -> void:
	_run()
	print("ideology effect metric publish: %d checks, %d failures"
		% [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	if not ClassDB.class_has_method("DCWorldExt", "query_effect_instance_metric"):
		_expect("query_effect_instance_metric is exported", false)
		return
	var catalog: Dictionary = _country_catalog()
	if catalog.is_empty():
		return
	_test_cell_domain_production_programs()
	_test_published_column(catalog)
	_test_condition_reads_column(catalog)
	_test_value_tracks_world(catalog)
	_test_no_condition_no_publish(catalog)
	_test_cell_domain_projects_per_cell(catalog)


## The real half of the domain-2 fixture: the shipped catalog must actually
## contain cell-domain programs, and they must be the selector kinds the
## mechanism matrix claims. Everything below drives a *synthetic* program
## through the same runtime; this is the only place that pins the production
## catalog to the domain, so a card that silently reverts to `COUNTRY` (and
## therefore lands on one handle instead of N cells) fails here.
func _test_cell_domain_production_programs() -> void:
	var domain: Resource = EffectDomainCatalogScript.build()
	if not _require("production domain catalog builds", domain != null):
		return
	var wanted := {
		"ideology.effect.v2_forge_ring": SEL_NEIGHBORS_R1,
		"ideology.effect.v3_vein_dominance": SEL_NEIGHBORS_R1,
		"ideology.effect.v4_iron_throne": SEL_NEIGHBORS_R2,
		"ideology.effect.v5_stacked_workshop": SEL_SAME_TERRAIN_COMPONENT,
		"ideology.effect.v6_guild_monopoly": SEL_DISTANCE_N,
	}
	var found := {}
	for definition in domain.definitions:
		if definition == null or not wanted.has(String(definition.key)):
			continue
		var key := String(definition.key)
		found[key] = true
		_expect("%s targets a settlement cell" % key,
			int(definition.target_domain) == DOMAIN_SETTLEMENT_CELL,
			"target_domain=%d" % int(definition.target_domain))
		_expect("%s uses selector kind %d" % [key, int(wanted[key])],
			int(definition.target_selector_kind) == int(wanted[key]),
			"kind=%d" % int(definition.target_selector_kind))
	for key in wanted:
		_expect("%s is in the compiled catalog" % key, found.has(key), str(found.keys()))
	# V2 and V3 cap their fan-out; an uncapped R1 is legal but a card that
	# quietly lost its cap would sweep the whole neighbourhood of every cell.
	for key in ["ideology.effect.v2_forge_ring", "ideology.effect.v3_vein_dominance"]:
		if not found.has(key):
			continue
		var definition: Resource = _find_definition(domain.definitions, key)
		if definition == null:
			continue
		_expect("%s declares a fan-out cap" % key,
			definition.target_selector_param.size() > 0
				and int(definition.target_selector_param[0]) > 0,
			str(definition.target_selector_param))


## The per-cell proof. Twelve owned cells, one card, one program; the whole
## point of the redesign is that this yields twelve instances, not one.
##
## The `OWNER` case is not filler: it is the pre-redesign semantics, kept as a
## control so the two counts differing proves the *selector* chooses the cell
## count rather than the fixture happening to collapse to one row.
func _test_cell_domain_projects_per_cell(catalog: Dictionary) -> void:
	const CELLS := 12
	var owner_fixture := _fixture(catalog, _metric_program(0, 0, SEL_OWNER, 0), CELLS)
	if not _require("owner-selector fixture builds", not owner_fixture.is_empty()):
		return
	var owner_report: Dictionary = owner_fixture["report"]
	_expect("OWNER projects onto exactly one cell",
		int(owner_report.get("count", -1)) == 1, str(owner_report.get("count", -1)))

	var wide_fixture := _fixture(catalog,
		_metric_program(0, 0, SEL_TAG_ANY_CELL, 0), CELLS)
	if not _require("grid-wide fixture builds", not wide_fixture.is_empty()):
		return
	var wide_report: Dictionary = wide_fixture["report"]
	_expect("TAG_ANY_CELL projects onto every owned cell",
		int(wide_report.get("count", -1)) == CELLS,
		"got %d, expected %d" % [int(wide_report.get("count", -1)), CELLS])
	# Distinct cell handles, not twelve rows pointing at the same cell — the
	# exact failure the redesign exists to fix.
	var cells_hit := {}
	var handles: PackedInt64Array = wide_report.get(
		"target_handles", PackedInt64Array())
	for handle in handles:
		cells_hit[int(handle)] = true
	_expect("the grid-wide instances address distinct cells",
		cells_hit.size() == CELLS,
		"%d distinct of %d rows" % [cells_hit.size(), handles.size()])


## The publisher must write a `present` value for the metric a card conditions
## on. Before L0-2 this was absent for every ideology instance, everywhere.
func _test_published_column(catalog: Dictionary) -> void:
	var fixture := _fixture(catalog, _metric_program(OP_METRIC_GTE, 0))
	if not _require("published-column fixture builds", not fixture.is_empty()):
		return
	var report: Dictionary = fixture["report"]
	_expect("metric program creates one instance on the anchor cell",
		int(report.get("count", -1)) == 1, str(report))
	var ids: PackedInt64Array = report.get("instance_ids", PackedInt64Array())
	if not _require("instance id is available", ids.size() == 1, str(report)):
		return
	var metric: Dictionary = fixture["ext"].query_effect_instance_metric(
		ids[0], METRIC_CELL_POPULATION)
	_expect("metric column is present for the ideology instance",
		bool(metric.get("ok", false)) and bool(metric.get("present", false)),
		str(metric))
	_expect("published population is a real reading, not the mask default",
		int(metric.get("value", -1)) >= 0, str(metric))


## A threshold the world cannot reach must block the command; a reachable one
## must let it through. Both cases read the same published column, so the two
## outcomes differing is only possible if the sample is genuine.
func _test_condition_reads_column(catalog: Dictionary) -> void:
	var blocked := _fixture(catalog,
		_metric_program(OP_METRIC_GTE, IMPOSSIBLE_POPULATION_Q16))
	if _require("blocked fixture builds", not blocked.is_empty()):
		var blocked_dispatch: Dictionary = blocked["dispatch"]
		_expect("impossible threshold blocks the emitted command",
			bool(blocked_dispatch.get("ok", false))
			and int(blocked_dispatch.get("submitted_commands", -1)) == 0,
			str(blocked_dispatch))
	var allowed := _fixture(catalog, _metric_program(OP_METRIC_GTE, 0))
	if _require("allowed fixture builds", not allowed.is_empty()):
		var allowed_dispatch: Dictionary = allowed["dispatch"]
		_expect("satisfied threshold lets the command through",
			bool(allowed_dispatch.get("ok", false))
			and int(allowed_dispatch.get("submitted_commands", -1)) == 1,
			str(allowed_dispatch))


## Guards against the vacuous version of the check above: a publisher that
## wrote a constant (or a zero) would still pass "present" and "blocked".
func _test_value_tracks_world(catalog: Dictionary) -> void:
	var low := _published_population(catalog, POPULATION_BASELINE)
	var high := _published_population(catalog, POPULATION_SCALED)
	if not _require("both sampling fixtures build",
			not low.is_empty() and not high.is_empty()):
		return
	var low_value := int(low.get("value", -1))
	var high_value := int(high.get("value", -1))
	_expect("published population is positive in a populated world",
		low_value > 0, "value=%d" % low_value)
	_expect("published population rises with the simulated population",
		high_value > low_value,
		"low=%d (pop %d) high=%d (pop %d)"
			% [low_value, POPULATION_BASELINE, high_value, POPULATION_SCALED])


func _published_population(catalog: Dictionary, population: int) -> Dictionary:
	var fixture := _fixture(catalog, _metric_program(OP_METRIC_GTE, 0), 1, population)
	if fixture.is_empty():
		return {}
	var ids: PackedInt64Array = (fixture["report"] as Dictionary).get(
		"instance_ids", PackedInt64Array())
	if ids.size() != 1:
		_expect("sampling fixture owns exactly one instance", false, str(ids))
		return {}
	return fixture["ext"].query_effect_instance_metric(
		ids[0], METRIC_CELL_POPULATION)


## A program with no metric condition must not pay for sampling: the publisher
## skips it, so its metric column stays unpublished.
func _test_no_condition_no_publish(catalog: Dictionary) -> void:
	var plain := _fixture(catalog, _metric_program(0, 0))
	if not _require("condition-free fixture builds", not plain.is_empty()):
		return
	var report: Dictionary = plain["report"]
	var ids: PackedInt64Array = report.get("instance_ids", PackedInt64Array())
	_expect("condition-free program still creates its instance",
		ids.size() == 1, str(report))
	if ids.size() != 1:
		return
	var metric: Dictionary = plain["ext"].query_effect_instance_metric(
		ids[0], METRIC_CELL_POPULATION)
	_expect("condition-free program publishes nothing",
		bool(metric.get("ok", false)) and not bool(metric.get("present", false)),
		str(metric))


## Builds a world, adopts the card and returns the instance report plus the
## first dispatch result. Empty on a fixture failure (reported as a check).
## `population` sizes the single seeded cell so a caller can prove the
## published metric follows the world rather than a constant.
func _fixture(catalog: Dictionary, program: Resource,
		cells: int = 1,
		population: int = POPULATION_BASELINE) -> Dictionary:
	var ext: Object = _build_ext(catalog, cells)
	var economy_outcome: Dictionary = ext.configure_economy(catalog,
		load("res://data/economy/default_economy.tres").to_native_profile(),
		cells, 97)
	if not bool(economy_outcome.get("ok", false)):
		_expect("economy configures (fills the epoch ownership column)", false,
			str(economy_outcome))
		return {}
	if not _bootstrap_economy(ext, catalog, population, cells):
		return {}
	var effect_catalog: Dictionary = _effect_catalog(program)
	if not bool(effect_catalog.get("ok", false)):
		_expect("effect catalog compiles", false,
			str(effect_catalog.get("reason", "")))
		return {}
	effect_catalog.erase("ok")
	var effects_configured: Dictionary = ext.configure_effects(effect_catalog)
	if not bool(effects_configured.get("ok", false)):
		_expect("effect catalog configures", false, str(effects_configured))
		return {}
	var ideology_configured: Dictionary = ext.configure_ideologies(_ideology_catalog())
	if not bool(ideology_configured.get("ok", false)):
		_expect("ideology catalog configures", false, str(ideology_configured))
		return {}
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("fixture resolves a country handle", handle != 0)
	_expect("fixture resolves the anchor cell",
		int(ext.query_country_anchor_cell(0)) == 0,
		"anchor=%d" % int(ext.query_country_anchor_cell(0)))
	if not bool(ext.submit_ideology_commands(_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": 0},
			{"op": 5, "day": 0, "handle": handle, "idea": 0},
		])).get("ok", false)):
		_expect("card is discovered and adopted", false)
		return {}
	_expect("ideology day reconciles the program",
		bool(ext.run_ideology_daily(0).get("ok", false)))
	var report: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("effect day runs", bool(ext.run_effect_daily(0).get("ok", false)))
	var dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	ext.ack_effect_native_modifier()
	return {"ext": ext, "report": report, "dispatch": dispatch}


func _find_definition(definitions: Array, key: String) -> Resource:
	for definition in definitions:
		if definition != null and String(definition.key) == key:
			return definition
	return null


func _country_catalog() -> Dictionary:
	var ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	_expect("country catalog compiles", bool(ir.get("ok", false)))
	if not bool(ir.get("ok", false)):
		return {}
	ir.erase("ok")
	return ir


func _build_ext(catalog: Dictionary, cells: int = 1) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	_expect("modifier catalog configures",
		bool(ext.configure_modifiers(modifier_catalog, 1).get("ok", false)))
	# The economy reads these columns; without them a cell has no terrain, no
	# landform and no resource reserves, and configure_economy cannot build the
	# epoch ownership index this test depends on.
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(cells, 0.5))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid2: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid2, 0, _u8_fill(cells, 0))
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(catalog.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _f32_fill(cells, 1000000.0))
		ext.write_f32_range(extra_sid, 0, _f32_fill(cells, 0.0))
	# Third argument is `cell_count`, not "number of countries": the country
	# runtime sizes its water mask from it, so a one-cell value in a twelve-cell
	# world fails with `country_water_mask_size_mismatch` before any card runs.
	_expect("country configures", bool(ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, cells, 97).get("ok", false)))
	var territory := PackedInt32Array()
	for cell in range(cells):
		territory.append(cell)
	var country_outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.ideology_metric_test"]),
		"country_names": PackedStringArray(["理念指标测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, cells]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	# `is_water` is the world's cell count, not the country count: the country
	# runtime rejects a mask whose length differs from its cell count
	# (`country_water_mask_size_mismatch`), which in a one-cell world hid the
	# fact that this array has to grow with the map.
	}, _u8_fill(cells, 0))
	_expect("country bootstraps", bool(country_outcome.get("ok", false)),
		str(country_outcome))
	return ext


## Slot payloads are size-`cells` on purpose: `capture_building_context` takes
## its cell count from `cell_temp`'s length, so a one-entry payload in a
## twelve-cell world silently truncates the map to one cell.
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


## Seeds `cells` populated settlements so `sample_effect_metrics` has a real
## reading to publish. Must run after `configure_economy` (that call builds the
## epoch ownership column the anchor-cell lookup walks).
func _bootstrap_economy(ext: Object, catalog: Dictionary, population: int,
		cells: int = 1) -> bool:
	var building_id := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (catalog.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		_expect("fixture finds its building type and owner signature", false,
			"building=%d signature=%d" % [building_id, owner_sig])
		return false
	var stock := PackedInt64Array()
	# The market matrix is (goods x cells), not (goods): a one-cell world made
	# `good_ids.size()` the same number by accident, and the native side sizes
	# the check from `matrix_size` (`market_stock_invalid` otherwise).
	stock.resize((catalog.good_ids as PackedStringArray).size() * cells)
	stock.fill(100000000)
	# One seeded settlement per cell, not one per world: a multi-cell fixture
	# needs every cell to be a real populated settlement, otherwise the tag and
	# ownership columns are empty for all but the anchor and the instance count
	# measures the fixture rather than the selector.
	var seeded_cells := PackedInt32Array()
	var seeded_signatures := PackedInt32Array()
	var seeded_population := PackedInt64Array()
	var seeded_funds := PackedInt64Array()
	var seeded_buildings := PackedInt32Array()
	var seeded_owners := PackedInt32Array()
	var seeded_counts := PackedInt64Array()
	for cell in range(cells):
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


## The authoritative metric table, read from the same builder production uses so
## the fixture cannot drift from `FamilyEffectMetricId`. Cached: building it
## loads several domain catalogs.
func _metric_keys() -> PackedStringArray:
	if not _metric_keys_cache.is_empty():
		return _metric_keys_cache
	var domain: Resource = EffectDomainCatalogScript.build()
	_expect("effect domain catalog builds", domain != null)
	if domain == null:
		return PackedStringArray()
	var keys: PackedStringArray = domain.metric_keys
	_expect("fixture metric id points at cell.population",
		keys.size() > METRIC_CELL_POPULATION
		and String(keys[METRIC_CELL_POPULATION]) == "cell.population",
		"size=%d id=%d" % [keys.size(), METRIC_CELL_POPULATION])
	_metric_keys_cache = keys
	return keys


## `condition_op` 0 disables the condition entirely (metrics must then stay
## unpublished). `selector_kind` / `selector_param1` let the cell-domain
## fixture swap the target resolver without a second program builder; the
## default reproduces the anchor-only card every other test here uses.
func _metric_program(condition_op: int, threshold_q16: int,
		selector_kind: int = SEL_OWNER,
		selector_param1: int = 0) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = StringName(CARD_DEFINITION_KEY)
	program.target_domain = DOMAIN_SETTLEMENT_CELL
	program.target_selector_kind = selector_kind
	program.target_selector_param = PackedInt32Array([0, selector_param1])
	program.cadence_days = 1
	if condition_op != 0:
		var condition: Resource = EffectConditionScript.new()
		condition.op = condition_op
		condition.arg0 = METRIC_CELL_POPULATION
		condition.value_q16 = threshold_q16
		var conditions: Array[Resource] = [condition]
		program.conditions = conditions
	var constant: Resource = EffectInstructionScript.new()
	constant.op = OP_CONST
	constant.value_q16 = Q16_ONE
	var emit: Resource = EffectInstructionScript.new()
	emit.op = OP_EMIT_COMMAND
	emit.arg0 = 0
	var instructions: Array[Resource] = [constant, emit]
	program.instructions = instructions
	var command: Resource = EffectCommandScript.new()
	command.action = 1
	command.domain = MODIFIER_DOMAIN_ECONOMY
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 1
	command.value_q16 = Q16_ONE
	command.duration_days = -1
	command.stacks = 1
	command.command_key = &"ideology.persistent"
	command.definition_key = StringName(TEST_MODIFIER_KEY)
	var commands: Array[Resource] = [command]
	program.commands = commands
	return program


func _effect_catalog(program_source: Resource) -> Dictionary:
	var catalog: Resource = EffectCatalogScript.new()
	# EffectRuntime validates `METRIC_GTE.arg0 < metric_count`, so the fixture
	# catalog has to carry the real metric table rather than an empty one.
	catalog.metric_keys = _metric_keys()
	var definitions: Array[Resource] = []
	var registry: Resource = EffectDefinitionScript.new()
	registry.key = &"ideology.command"
	registry.cadence_days = 3650
	var end := EffectInstruction.new()
	end.op = 12
	var registry_instructions: Array[Resource] = [end]
	registry.instructions = registry_instructions
	var template: Resource = EffectCommandScript.new()
	template.action = 1
	template.domain = 1
	template.opcode = 1
	template.target_resolver = 1
	template.value_mode = 0
	template.command_key = &"ideology.persistent"
	template.definition_key = StringName(TEST_MODIFIER_KEY)
	var registry_commands: Array[Resource] = [template]
	registry.commands = registry_commands
	definitions.append(registry)
	definitions.append(program_source.to_effect_definition())
	catalog.definitions = definitions
	return catalog.compile_native_catalog()


func _ideology_catalog() -> Dictionary:
	var ids := PackedStringArray(["idea.granary_belt"])
	return {
		"protocol_version": 1,
		"ideology_capacity": 2,
		"national_spirit_capacity": 1,
		"offer_choice_count": 3,
		"offer_cost_q16": Q16_ONE,
		"max_commands_per_slice": 64,
		"max_transition_commands": 256,
		"max_effect_instances": 128,
		"political_class_ids": PackedStringArray(["general"]),
		"stance_offsets": PackedInt32Array([0, 0]),
		"stance_class_indices": PackedInt32Array(),
		"stance_adopt_q16": PackedInt32Array(),
		"stance_repeal_q16": PackedInt32Array(),
		"stance_promote_q16": PackedInt32Array(),
		"stance_adopt_min_q16": PackedInt32Array(),
		"stance_repeal_min_q16": PackedInt32Array(),
		"stance_promote_min_q16": PackedInt32Array(),
		"adopt_thresholds_q16": PackedInt32Array([0]),
		"repeal_thresholds_q16": PackedInt32Array([0]),
		"promote_thresholds_q16": PackedInt32Array([0]),
		"exclusion_group_ids": PackedInt32Array([-1]),
		"synergy_ids": PackedStringArray(),
		"synergy_requirement_offsets": PackedInt32Array([0]),
		"synergy_requirement_ideology_ids": PackedInt32Array(),
		"synergy_requirement_min_levels": PackedInt32Array(),
		"synergy_requirement_location_masks": PackedByteArray(),
		"synergy_effect_offsets": PackedInt32Array([0]),
		"synergy_effect_actions": PackedInt32Array(),
		"synergy_effect_domains": PackedInt32Array(),
		"synergy_effect_opcodes": PackedInt32Array(),
		"synergy_effect_values_q16": PackedInt64Array(),
		"synergy_effect_duration_days": PackedInt32Array(),
		"synergy_effect_stacks": PackedInt32Array(),
		"synergy_effect_command_keys": PackedStringArray(),
		"synergy_effect_definition_keys": PackedStringArray(),
		"synergy_effect_payload_i0": PackedInt64Array(),
		"synergy_effect_payload_i1": PackedInt64Array(),
		"synergy_effect_payload_i2": PackedInt64Array(),
		"synergy_effect_payload_i3": PackedInt64Array(),
		"ideology_synergy_offsets": PackedInt32Array([0, 0]),
		"ideology_synergy_ids": PackedInt32Array(),
		"ideology_ids": ids,
		"acquisition_flags": PackedByteArray([3]),
		"rarity_weights": PackedInt32Array([1]),
		"ideology_slot_costs": PackedInt32Array([1]),
		"spirit_slot_costs": PackedInt32Array([1]),
		"national_spirit_min_levels": PackedInt32Array([1]),
		"level_offsets": PackedInt32Array([0, 3]),
		"level_thresholds_q16": PackedInt64Array([0, 3 * Q16_ONE, 5 * Q16_ONE]),
		"level_daily_understanding_q16": PackedInt64Array([
			Q16_ONE, Q16_ONE, Q16_ONE]),
		"technology_requirement_offsets": PackedInt32Array([0, 0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0, 0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0, 0]),
		"gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0, 1, 2, 3]),
		"persistent_actions": PackedInt32Array([1, 1, 1]),
		"persistent_domains": PackedInt32Array([1, 1, 1]),
		"persistent_opcodes": PackedInt32Array([1, 1, 1]),
		"persistent_values_q16": PackedInt64Array([Q16_ONE, Q16_ONE, Q16_ONE]),
		"persistent_duration_days": PackedInt32Array([-1, -1, -1]),
		"persistent_stacks": PackedInt32Array([1, 1, 1]),
		"persistent_command_keys": PackedStringArray([
			"ideology.persistent", "ideology.persistent", "ideology.persistent"]),
		"persistent_definition_keys": PackedStringArray([
			CARD_DEFINITION_KEY, CARD_DEFINITION_KEY, CARD_DEFINITION_KEY]),
		"persistent_payload_i0": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i1": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i2": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i3": PackedInt64Array([0, 0, 0]),
		"level_on_enter_offsets": PackedInt32Array([0, 0, 0, 0]),
		"on_enter_actions": PackedInt32Array(),
		"on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(),
		"on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(),
		"on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(),
		"on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(),
		"on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(),
		"on_enter_payload_i3": PackedInt64Array(),
	}


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


## Same as `_expect`, but returns the verdict so a caller can bail out early.
## Every fixture-dependent block goes through this: a silently empty fixture
## must fail the suite, never skip its assertions.
func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition
