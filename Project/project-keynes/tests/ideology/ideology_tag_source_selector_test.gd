extends SceneTree

## X1: the radial selector evaluated once per SOURCE cell.
##
## Why this exists
## ---------------
## `resolve_effect_targets()` used to expand every selector from
## `country_anchor_cell()`, so "主产铁矿石的地块：周围 1 格工业 +10%" silently
## buffed the country's first owned cell's neighbourhood and nothing else. The
## new kinds 14/15 walk the country's own territory for a tag, expand one ring
## per source, union, dedupe and cap.
##
## What is proved
## --------------
##  1. With one settlement cell, the source-tag result equals the plain R1 result
##     from that cell (the control: X1 must not change the old answer).
##  2. With several settlement cells, the target set equals the **union** of each
##     source's R1 neighbours, computed independently through the economy
##     selector. That union is strictly larger than the anchor's own ring, which
##     is exactly the bug X1 fixes.
##  3. With no settlement cell the card owns no instance (a source tag that
##     matches nothing must not fall back to the anchor).
##
## The fixture drives a synthetic program rather than a production card on
## purpose: the tag is the variable, and seeding real iron production would make
## the test depend on the economy's good-dominance rules instead of the selector.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyEffectDefinitionScript = preload("res://scripts/ideology/ideology_effect_definition.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 12
const PROGRAM_KEY := "x1_probe"
const Q16_ONE := 65536
const SETTLEMENT_MIN := 400
const EMPTY_CELL := 2
const SEL_NEIGHBORS_R1 := 6
const SEL_TAG_SOURCE_R1 := 14
const DOMAIN_SETTLEMENT_CELL := 2
const MODIFIER_DOMAIN_ECONOMY := 2
const OP_CONST := 1
const OP_EMIT_COMMAND := 11
## Ids 51..55, appended this round: X3 profession mix, X2 neighbourhood, X11 tax.
const METRIC_DOMINANT_OUTPUT_GOOD_ID := 45
const METRIC_DOMINANT_PROFESSION_ID := 51
const METRIC_DOMINANT_PROFESSION_SHARE_Q16 := 52
const METRIC_PROFESSION_COUNT := 53
const METRIC_NEIGHBOR_POPULATION_Q16 := 54
const METRIC_INCOME_TAX_BURDEN_BP := 55
## Ids 56..61: X7 per-country tag counts.
const METRIC_COUNTRY_AGRICULTURE_CELL_COUNT := 56
const METRIC_COUNTRY_EXTRACTIVE_CELL_COUNT := 57
const METRIC_COUNTRY_MANUFACTURING_CELL_COUNT := 58
const METRIC_COUNTRY_CHAINED_CELL_COUNT := 59
const METRIC_COUNTRY_SPECIALIZED_CELL_COUNT := 60
const METRIC_COUNTRY_MARKET_CELL_COUNT := 61
const METRIC_COUNTRY_SETTLEMENT_CELL_COUNT := 62
## Ids 63..67: per-good counts + distinct specialized goods.
const METRIC_COUNTRY_SILVER_CELL_COUNT := 63
const METRIC_COUNTRY_SALT_CELL_COUNT := 64
const METRIC_COUNTRY_IRON_ORE_CELL_COUNT := 65
const METRIC_COUNTRY_COAL_CELL_COUNT := 66
const METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT := 67

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _country_ir: Dictionary = {}
var _map_stub: Object = null


## The economy reads the neighbour graph from `map_data.neighbor_indices_packed()`
## when it captures the building context. Without a map the twelve cells are
## isolated and every R1/R2 ring is empty, which would make this whole test pass
## vacuously. The stub is a single row of cells: 0-1-2-...-11.
class MapStub extends RefCounted:
	var _packed := PackedInt32Array()

	func _init(cells: int) -> void:
		_packed.resize(cells * 6)
		_packed.fill(-1)
		for cell in range(cells):
			var deltas: Array[int] = [1, -1, 2, -2, 3, -3]
			for direction in range(6):
				var neighbour: int = cell + deltas[direction]
				if neighbour >= 0 and neighbour < cells:
					_packed[cell * 6 + direction] = neighbour

	func neighbor_indices_packed() -> PackedInt32Array:
		return _packed


func _init() -> void:
	_run()
	print("ideology tag source selector: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not _require("country catalog compiles", bool(_country_ir.get("ok", false))):
		return
	var domain: Resource = EffectDomainCatalogScript.build()
	if not _require("effect domain catalog builds", domain != null):
		return
	var tag_id := _tag_id(domain, "cell.settlement")
	if not _require("settlement tag exists", tag_id >= 0):
		return

	_test_single_source_matches_r1(tag_id)
	_test_multiple_sources_union(tag_id)
	_test_no_source_no_targets(tag_id)
	_test_metric_extensions()
	_test_economy_day_commits()
	_test_linear_magnitude()
	_test_instance_refresh_gate(tag_id)


## 1. Control: one source must reproduce the plain R1 answer.
func _test_single_source_matches_r1(tag_id: int) -> void:
	var populations := [SETTLEMENT_MIN, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL,
		EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL,
		EMPTY_CELL, EMPTY_CELL]
	var fixture := _fixture(_source_program(tag_id), populations)
	if fixture.is_empty():
		return
	var expected := _union_of_sources(fixture["ext"], [0])
	_expect("one source: targets equal the plain R1 ring of that cell",
		_same_set(fixture["targets"], expected),
		"got=%s expected=%s" % [str(fixture["targets"]), str(expected)])


## 2. Several sources: the target set is their union, not the anchor's ring.
func _test_multiple_sources_union(tag_id: int) -> void:
	var populations := [SETTLEMENT_MIN, SETTLEMENT_MIN, SETTLEMENT_MIN,
		SETTLEMENT_MIN, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL,
		EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL]
	var fixture := _fixture(_source_program(tag_id), populations)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	var expected := _union_of_sources(ext, [0, 1, 2, 3])
	_expect("four sources: targets equal the union of every source's ring",
		_same_set(fixture["targets"], expected),
		"got=%s expected=%s" % [str(fixture["targets"]), str(expected)])
	var anchor_only := _union_of_sources(ext, [0])
	_expect("four sources reach cells the anchor alone cannot",
		fixture["targets"].size() > anchor_only.size(),
		"union=%d anchor=%d" % [fixture["targets"].size(), anchor_only.size()])


## 3. A source tag that matches nothing yields nothing.
func _test_no_source_no_targets(tag_id: int) -> void:
	var populations := []
	for _cell in range(CELLS):
		populations.append(EMPTY_CELL)
	var fixture := _fixture(_source_program(tag_id), populations)
	if fixture.is_empty():
		return
	_expect("no matching source: the card owns no instance",
		fixture["targets"].is_empty(), str(fixture["targets"]))


## The oracle: ask the economy selector for each source's R1 ring and union it.
func _union_of_sources(ext: Object, sources: Array) -> PackedInt64Array:
	var seen := {}
	for source in sources:
		var ring: Array = ext.query_effect_target_cells(int(source),
			SEL_NEIGHBORS_R1, 8, 0)
		for cell in ring:
			seen[int(cell)] = true
	var out := PackedInt64Array()
	var keys := seen.keys()
	keys.sort()
	for key in keys:
		out.append(int(key))
	return out


func _same_set(left: PackedInt64Array, right: PackedInt64Array) -> bool:
	if left.size() != right.size():
		return false
	var l := Array(left)
	var r := Array(right)
	l.sort()
	r.sort()
	return l == r


func _tag_id(domain: Resource, tag_name: String) -> int:
	var tags: Array = domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == tag_name:
			return index
	return -1


func _fixture(program_source: Resource, populations: Array,
		settle_days: int = 0) -> Dictionary:
	var ext: Object = _build_ext()
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	if not _require("modifier catalog configures",
			bool(ext.configure_modifiers(modifier_catalog, CELLS).get("ok", false))):
		return {}
	var economy_outcome: Dictionary = ext.configure_economy(_country_ir,
		load("res://data/economy/default_economy.tres").to_native_profile(), CELLS, 97)
	if not _require("economy configures", bool(economy_outcome.get("ok", false)),
			str(economy_outcome)):
		return {}
	if not _bootstrap_economy(ext, populations):
		return {}
	if settle_days > 0 and not _run_economy_days(ext, settle_days):
		return {}
	# Give the economy a real neighbour graph, then force the building-context
	# capture that fills `_building_neighbors`.
	_map_stub = MapStub.new(CELLS)
	ext.bind_map_data(_map_stub)
	ext.run_economy_slice({"day_index": 0, "tick_index": 0})
	var program := program_source
	var effect_ir: Dictionary = _effect_catalog(program)
	if not _require("effect catalog compiles", bool(effect_ir.get("ok", false)),
			str(effect_ir.get("reason", ""))):
		return {}
	effect_ir.erase("ok")
	if not _require("effect catalog configures",
			bool(ext.configure_effects(effect_ir).get("ok", false))):
		return {}
	if not _require("ideology catalog configures",
			bool(ext.configure_ideologies(_ideology_catalog()).get("ok", false))):
		return {}
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("fixture resolves a country handle", handle != 0):
		return {}
	var submitted: Dictionary = ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": 0},
		{"op": 5, "day": 0, "handle": handle, "idea": 0},
	]))
	if not _require("probe card is adopted", bool(submitted.get("ok", false)),
			str(submitted)):
		return {}
	for _slice in range(16):
		var day: Dictionary = ext.run_ideology_daily(0)
		if not bool(day.get("ok", false)):
			_expect("ideology day runs", false, str(day))
			return {}
		if bool(day.get("done", true)):
			break
	var report: Dictionary = ext.get_ideology_effect_instance_report(handle)
	var handles: PackedInt64Array = report.get("target_handles", PackedInt64Array())
	ext.run_effect_daily(0)
	ext.dispatch_effect_native_modifier()
	var instance_ids: PackedInt64Array = report.get("instance_ids", PackedInt64Array())
	return {"ext": ext, "targets": _distinct(handles), "instances": instance_ids}


## P1-A: the instance refresh must follow INPUT CONTENT, never the clock. A
## managed cell card plus five days of ideology work with no economy commit has
## to leave the revision, the pass count and the visit count untouched -- this is
## the gate Doc 03 §6.2 calls B5.
##
## The mirror case matters just as much: once a day actually commits, the digest
## hook must run and the next ideology day must execute exactly one refresh pass.
func _test_instance_refresh_gate(tag_id: int) -> void:
	var populations := [SETTLEMENT_MIN, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL,
		EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL,
		EMPTY_CELL, EMPTY_CELL]
	var fixture := _fixture(_source_program(tag_id), populations, 1)
	if not _require("refresh fixture builds", not fixture.is_empty()):
		return
	var ext: Object = fixture["ext"]
	var before: Dictionary = ext.get_ideology_report()
	if not _require("refresh fixture keeps a managed card in play",
			int(before.get("managed_idea_count", 0)) > 0, str(before)):
		return
	for day in range(1, 6):
		ext.run_ideology_daily(day)
	var idle: Dictionary = ext.get_ideology_report()
	_expect("a quiet economy does not advance the input revision",
		int(idle.get("effect_input_revision", -1)) ==
			int(before.get("effect_input_revision", -2)), str(idle))
	_expect("a quiet economy does not run a refresh pass",
		int(idle.get("instance_refresh_passes", -1)) ==
			int(before.get("instance_refresh_passes", -2)), str(idle))
	_expect("a quiet economy visits no managed card",
		int(idle.get("instance_refresh_visits", -1)) ==
			int(before.get("instance_refresh_visits", -2)), str(idle))
	if not _require("a further economy day commits",
			_run_economy_days(ext, 2)):
		return
	var committed: Dictionary = ext.get_ideology_report()
	var economy: Dictionary = ext.get_economy_report()
	_expect("the commit tail recomputes the input digest",
		int(economy.get("effect_input_digest_computations", 0)) > 0,
		str(economy.get("effect_input_digest_computations", "missing")))
	var moved: bool = int(committed.get("effect_input_revision", 0)) \
		> int(idle.get("effect_input_revision", 0))
	_expect("a settled day moves the tag input", moved,
		"revision stayed at %d" % int(committed.get("effect_input_revision", 0)))
	if not moved:
		return
	ext.run_ideology_daily(6)
	var refreshed: Dictionary = ext.get_ideology_report()
	_expect("a moved revision runs a refresh pass",
		int(refreshed.get("instance_refresh_passes", 0)) >
			int(committed.get("instance_refresh_passes", 0)), str(refreshed))
	_expect("the pass actually looked at the managed card",
		int(refreshed.get("instance_refresh_visits", 0)) +
			int(refreshed.get("instance_refresh_skips", 0)) > 0, str(refreshed))


func _distinct(handles: PackedInt64Array) -> PackedInt64Array:
	var seen := {}
	for handle in handles:
		seen[int(handle)] = true
	var out := PackedInt64Array()
	var keys := seen.keys()
	keys.sort()
	for key in keys:
		out.append(int(key))
	return out


## The commit helper's own contract: one whole economy day reaches `done` without
## a fatal. This is deliberately NOT asserting production -- that needs a real
## MapData fixture (see §43.5) -- but it does prove the day loop terminates, which
## every future producing fixture will rely on.
func _test_economy_day_commits() -> void:
	var populations := []
	for _cell in range(CELLS):
		populations.append(SETTLEMENT_MIN)
	var ext: Object = _build_ext()
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	if not _require("modifier catalog configures",
			bool(ext.configure_modifiers(modifier_catalog, CELLS).get("ok", false))):
		return
	if not _require("economy configures", bool(ext.configure_economy(_country_ir,
			load("res://data/economy/default_economy.tres").to_native_profile(),
			CELLS, 97).get("ok", false))):
		return
	if not _bootstrap_economy(ext, populations):
		return
	# `done` is only set after the commit stage has run, so the helper returning
	# true is the commit assertion. See the header of `_run_economy_days`.
	_expect("one economy day reaches a commit", _run_economy_days(ext, 1))


## X3 / X2 / X11: five newly appended metrics, each referenced by a condition so
## the publisher is forced to write it. Values are asserted, not just presence --
## a metric that compiles, publishes 0 and never moves is the failure mode this
## whole table exists to prevent.
func _test_metric_extensions() -> void:
	var populations := [SETTLEMENT_MIN, SETTLEMENT_MIN, SETTLEMENT_MIN,
		EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL,
		EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL]
	var fixture := _fixture(_metrics_program(), populations)
	if fixture.is_empty():
		return
	var instances: PackedInt64Array = fixture["instances"]
	if not _require("metric probe owns one instance", instances.size() == 1,
			str(instances)):
		return
	var ext: Object = fixture["ext"]
	var dominant_id: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_DOMINANT_PROFESSION_ID)
	var dominant_share: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_DOMINANT_PROFESSION_SHARE_Q16)
	var profession_count: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_PROFESSION_COUNT)
	var neighbor_population: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_NEIGHBOR_POPULATION_Q16)
	var tax_burden: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_INCOME_TAX_BURDEN_BP)
	for pair in [
			["dominant profession id", dominant_id],
			["dominant profession share", dominant_share],
			["profession count", profession_count],
			["neighbor population", neighbor_population],
			["income tax burden", tax_burden]]:
		_expect("%s is published" % pair[0],
			bool((pair[1] as Dictionary).get("ok", false))
			and bool((pair[1] as Dictionary).get("present", false)), str(pair[1]))
	_expect("dominant profession id is a valid index",
		int(dominant_id.get("value", -Q16_ONE)) >= 0, str(dominant_id))
	_expect("dominant profession share is a real ratio",
		int(dominant_share.get("value", -1)) > 0
		and int(dominant_share.get("value", -1)) <= Q16_ONE, str(dominant_share))
	_expect("profession count is at least one",
		int(profession_count.get("value", 0)) >= Q16_ONE, str(profession_count))
	# Three seeded neighbours at 400 people each: the sum can only be non-zero if
	# the neighbour graph is wired and the column is read per neighbour.
	_expect("neighbor population sums the seeded ring",
		int(neighbor_population.get("value", 0)) > 0, str(neighbor_population))
	_expect("income tax burden is a sane rate",
		int(tax_burden.get("value", -1)) >= 0, str(tax_burden))
	# Settlement is a population tag, so it does not need production: all twelve
	# seeded cells are at 400 people, which is exactly the settlement threshold.
	# This is the non-vacuous "the count really ran" assertion -- the sector rows
	# stay 0 here because the fixture's buildings never produce output.
	var settlement: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_COUNTRY_SETTLEMENT_CELL_COUNT)
	# This fixture seeds exactly three settlement cells (the other nine are at
	# POPULATION 2), so the count is the number of *owned, matching* cells -- not
	# the world size. Getting 12 here would mean the count ignored the tag.
	_expect("settlement count equals the seeded settlement cells",
		int(settlement.get("value", -1)) == 3 * Q16_ONE, str(settlement))
	var sector_total := 0
	for metric_id in [METRIC_COUNTRY_AGRICULTURE_CELL_COUNT,
			METRIC_COUNTRY_EXTRACTIVE_CELL_COUNT,
			METRIC_COUNTRY_MANUFACTURING_CELL_COUNT]:
		sector_total += int(ext.query_effect_instance_metric(
			instances[0], metric_id).get("value", -1))
	# X7b: these five are driven by *output dominance*, and this fixture never
	# produces: `_run_economy_days` reaches a commit but the cohorts do not
	# survive a whole day without a map / trade topology, so by the time the
	# report is read the cells are empty again. See `_test_economy_day_commits`
	# for what the helper does prove, and §43.5 for the producing fixture that is
	# still missing (it needs `EconomyTestBootstrap.build` + a real MapData).
	var dominant_good: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_DOMINANT_OUTPUT_GOOD_ID)
	_expect("no production means no dominant good",
		int(dominant_good.get("value", -1)) == -Q16_ONE, str(dominant_good))
	var good_total := 0
	for metric_id in [METRIC_COUNTRY_SILVER_CELL_COUNT,
			METRIC_COUNTRY_SALT_CELL_COUNT, METRIC_COUNTRY_IRON_ORE_CELL_COUNT,
			METRIC_COUNTRY_COAL_CELL_COUNT,
			METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT]:
		var reading: Dictionary = ext.query_effect_instance_metric(
			instances[0], metric_id)
		_expect("good-derived metric %d is published" % metric_id,
			bool(reading.get("present", false)), str(reading))
		good_total += int(reading.get("value", -1))
	# Pinned at 0 so a count mistakenly wired to "any owned cell" turns this red.
	_expect("good-derived counts are zero without production",
		good_total == 0, "sum=%d" % good_total)
	# Nothing produces here, so no cell has a sector output share and all three
	# rows are 0. Pinned at 0: a count wired to territory size would say 12.
	_expect("sector counts are zero when nothing produces",
		sector_total == 0, "sum=%d" % sector_total)
	var chained: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_COUNTRY_CHAINED_CELL_COUNT)
	var market: Dictionary = ext.query_effect_instance_metric(
		instances[0], METRIC_COUNTRY_MARKET_CELL_COUNT)
	# Negative control: the fixture has no production chain and no trade events,
	# so these two must be exactly 0. Without this, a metric that published a
	# constant (or the cell count) would still pass the "> 0" check above.
	_expect("chained count is zero in a chained-free world",
		int(chained.get("value", -1)) == 0, str(chained))
	_expect("market count is zero in a trade-free world",
		int(market.get("value", -1)) == 0, str(market))


## Linear amplitude: the command value must be `per * min(metric, cap)`, driven by
## the metric rather than by the level. Three settlement cells in this fixture, so
## per=1% must apply 3% and per=2% must apply 6% -- two runs, because one run
## cannot tell "reads the metric" from "happens to equal the fixture's cell count".
func _test_linear_magnitude() -> void:
	var populations := [SETTLEMENT_MIN, SETTLEMENT_MIN, SETTLEMENT_MIN,
		EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL,
		EMPTY_CELL, EMPTY_CELL, EMPTY_CELL, EMPTY_CELL]
	# 1% x 3 settlement cells = 3%. The fixture publishes settlement count = 3,
	# so a wrong constant (or a metric that never reached the instance) shows up
	# as a magnitude of 0 rather than "close enough".
	var one_percent := _ramp_magnitude(populations, 0.01, 15)
	if one_percent < 0:
		return
	_expect("ramp applies per * metric (1% x 3 = 3%)",
		_is_close(one_percent, 0.03, 0.001), "magnitude=%.5f" % one_percent)
	# Doubling `per` doubles the contribution: 2% x 3 = 6%.
	var two_percent := _ramp_magnitude(populations, 0.02, 15)
	if two_percent < 0:
		return
	_expect("ramp is linear in per (2% x 3 = 6%)",
		_is_close(two_percent, 0.06, 0.002), "magnitude=%.5f" % two_percent)
	# The MIN step must bite: cap=2 turns 1% x 3 into 1% x 2 = 2%.
	var capped := _ramp_magnitude(populations, 0.01, 2)
	if capped < 0:
		return
	_expect("ramp honours the cap (1% x min(3, 2) = 2%)",
		_is_close(capped, 0.02, 0.001), "magnitude=%.5f" % capped)


## Returns the applied magnitude (as a fraction, e.g. 0.03) of the ramp program, or
## -1 when the fixture could not build. Read from `list_modifiers` rather than
## `evaluate_modifier_stat`: the latter wants the modifier's own entity handle, and
## silently returns the base when it does not match.
func _ramp_magnitude(populations: Array, per: float, cap: float) -> float:
	var fixture := _fixture(_ramp_program(per, cap), populations)
	if fixture.is_empty():
		return -1.0
	var ext: Object = fixture["ext"]
	ext.run_modifier_daily(0)
	var rows: Dictionary = ext.list_modifiers(
		MODIFIER_DOMAIN_ECONOMY, 0, "economy.city.output_factor")
	var magnitudes: PackedInt32Array = rows.get(
		"magnitude_q16", PackedInt32Array())
	if not _require("ramp produced a modifier row", magnitudes.size() >= 1,
			str(rows)):
		return -1.0
	return float(magnitudes[0]) / float(Q16_ONE)


func _is_close(value: float, expected: float, tolerance: float) -> bool:
	return absf(value - expected) <= tolerance


## One command, one ramp: value = per * min(country.settlement_cell_count, cap).
func _ramp_program(per: float, cap: float) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = StringName(PROGRAM_KEY)
	program.target_domain = DOMAIN_SETTLEMENT_CELL
	program.target_selector_kind = 12  # OWN_TERRITORY
	program.target_selector_param = PackedInt32Array([32, 0])
	program.cadence_days = 1
	var instructions: Array[Resource] = []
	var steps := [
		[OP_CONST, 0, int(round(per * Q16_ONE))],
		[2, METRIC_COUNTRY_SETTLEMENT_CELL_COUNT, 0],   # READ_METRIC
		[OP_CONST, 0, int(round(cap * Q16_ONE))],
		[8, 0, 0],                                     # MIN
		[6, 0, 0],                                     # MUL_Q16
		[OP_EMIT_COMMAND, 0, 0],
	]
	for step in steps:
		var instruction: Resource = EffectInstructionScript.new()
		instruction.op = int(step[0])
		instruction.arg0 = int(step[1])
		instruction.value_q16 = int(step[2])
		instructions.append(instruction)
	program.instructions = instructions
	var command: Resource = EffectCommandScript.new()
	command.action = 1
	command.domain = MODIFIER_DOMAIN_ECONOMY
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 1
	command.value_q16 = int(round(per * Q16_ONE))
	command.duration_days = -1
	command.stacks = 1
	command.command_key = &"ideology.persistent"
	command.definition_key = &"economy.city.output_factor"
	var commands: Array[Resource] = [command]
	program.commands = commands
	return program


## One program, five conditions: the metric mask is the union of every id a
## condition names, so a single instance carries all five columns.
func _metrics_program() -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = StringName(PROGRAM_KEY)
	program.target_domain = DOMAIN_SETTLEMENT_CELL
	program.target_selector_kind = 0
	program.target_selector_param = PackedInt32Array([0, 0])
	program.cadence_days = 1
	var conditions: Array[Resource] = []
	for metric_id in [METRIC_DOMINANT_PROFESSION_ID, METRIC_DOMINANT_PROFESSION_SHARE_Q16,
			METRIC_PROFESSION_COUNT, METRIC_NEIGHBOR_POPULATION_Q16,
			METRIC_INCOME_TAX_BURDEN_BP, METRIC_DOMINANT_OUTPUT_GOOD_ID,
			METRIC_COUNTRY_AGRICULTURE_CELL_COUNT,
			METRIC_COUNTRY_EXTRACTIVE_CELL_COUNT,
			METRIC_COUNTRY_MANUFACTURING_CELL_COUNT,
			METRIC_COUNTRY_CHAINED_CELL_COUNT,
			METRIC_COUNTRY_SPECIALIZED_CELL_COUNT,
			METRIC_COUNTRY_MARKET_CELL_COUNT,
			METRIC_COUNTRY_SETTLEMENT_CELL_COUNT,
			METRIC_COUNTRY_SILVER_CELL_COUNT, METRIC_COUNTRY_SALT_CELL_COUNT,
			METRIC_COUNTRY_IRON_ORE_CELL_COUNT, METRIC_COUNTRY_COAL_CELL_COUNT,
			METRIC_COUNTRY_DISTINCT_SPECIALIZED_GOOD_COUNT]:
		var condition: Resource = EffectConditionScript.new()
		condition.op = 2
		condition.arg0 = int(metric_id)
		condition.value_q16 = 0
		conditions.append(condition)
	for _index in range(conditions.size() - 1):
		var and_row: Resource = EffectConditionScript.new()
		and_row.op = 6
		conditions.append(and_row)
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
	command.definition_key = &"ideology.city.output_factor"
	var commands: Array[Resource] = [command]
	program.commands = commands
	return program


## Selector 14 with `param[1]` = 1-based tag id, exactly like the production
## generator emits.
func _source_program(tag_id: int) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = StringName(PROGRAM_KEY)
	program.target_domain = DOMAIN_SETTLEMENT_CELL
	program.target_selector_kind = SEL_TAG_SOURCE_R1
	program.target_selector_param = PackedInt32Array([32, tag_id + 1])
	program.cadence_days = 1
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
	command.definition_key = &"ideology.city.output_factor"
	var commands: Array[Resource] = [command]
	program.commands = commands
	return program


## The fixture catalog needs the real metric table (tags resolve against it) and
## the real tag table (the economy evaluates the tag), so both come from the
## production domain catalog instead of being invented here.
func _effect_catalog(program: Resource) -> Dictionary:
	var domain: Resource = EffectDomainCatalogScript.build()
	var catalog: Resource = EffectCatalogScript.new()
	catalog.metric_keys = domain.metric_keys
	catalog.target_tags = domain.target_tags
	var registry: Resource = EffectDefinitionScript.new()
	registry.key = &"ideology.command"
	registry.cadence_days = 3650
	var end := EffectInstructionScript.new()
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
	template.definition_key = &"ideology.city.output_factor"
	var registry_commands: Array[Resource] = [template]
	registry.commands = registry_commands
	var definitions: Array[Resource] = [registry, program.to_effect_definition()]
	catalog.definitions = definitions
	return catalog.compile_native_catalog()


func _build_ext() -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(CELLS, 0.5))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid2: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid2, 0, _u8_fill(CELLS, 0))
	for i in range((_country_ir.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(_country_ir.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(_country_ir.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _f32_fill(CELLS, 1000000.0))
		ext.write_f32_range(extra_sid, 0, _f32_fill(CELLS, 0.0))
	_expect("country configures", bool(ext.configure_country(_country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 97).get("ok", false)))
	var territory := PackedInt32Array()
	for cell in range(CELLS):
		territory.append(cell)
	var country_outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.x1_probe"]),
		"country_names": PackedStringArray(["X1 探针国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(CELLS, 0))
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


## Drives whole economy days until each one reports `done`. A single
## `run_economy_slice` call only advances one slice of one day, so a fixture that
## needs *production* has to run the day out and then a few more: the settlement
## phase rotates, and only cells that have settled produce output.
##
## This is the helper §43.5 asked for: without it every output-derived metric
## (dominant good, top-output share, sector share) reads 0 and a test that
## "passes" proves nothing about them.
func _run_economy_days(ext: Object, days: int) -> bool:
	for day in range(days):
		var finished := false
		for slice in range(64):
			var report: Dictionary = ext.run_economy_slice({
				"day_index": day,
				"tick_index": day * 1000 + slice,
			})
			if not bool(report.get("ok", true)) or bool(report.get("fatal", false)):
				_expect("economy day %d slice %d runs" % [day, slice], false,
					str(report.get("fatal_reason", report)))
				return false
			if bool(report.get("done", false)):
				finished = true
				break
		if not finished:
			_expect("economy day %d reaches a commit" % day, false,
				"64 slices without done")
			return false
	return true


func _bootstrap_economy(ext: Object, populations: Array) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		_expect("fixture finds its building type and owner signature", false)
		return false
	var goods: int = (_country_ir.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	stock.resize(goods * CELLS)
	stock.fill(100000000)
	# Without a price row the market cannot clear and the cohorts starve on day 0,
	# which is what made the first version of this helper look broken.
	var prices := PackedInt32Array()
	prices.resize(goods * CELLS)
	prices.fill(1000)
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
		seeded_population.append(int(populations[cell]))
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
		"price": prices,
		"building_cells": seeded_cells,
		"building_type_ids": seeded_buildings,
		"building_owner_signature_ids": seeded_owners,
		"building_counts": seeded_counts,
	})
	_expect("economy bootstraps", bool(outcome.get("ok", false)), str(outcome))
	return bool(outcome.get("ok", false))


## Minimal ideology catalog with exactly one program-only card: no legacy row
## means no equip transaction, so the instance set is ready on day 0.
func _ideology_catalog() -> Dictionary:
	return {
		"protocol_version": 1, "ideology_capacity": 2, "national_spirit_capacity": 1,
		"offer_choice_count": 3, "offer_cost_q16": Q16_ONE, "max_commands_per_slice": 64,
		"max_transition_commands": 256, "max_effect_instances": 256,
		"political_class_ids": PackedStringArray(["general"]),
		"stance_offsets": PackedInt32Array([0, 0]),
		"stance_class_indices": PackedInt32Array(),
		"stance_adopt_q16": PackedInt32Array(), "stance_repeal_q16": PackedInt32Array(),
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
		"ideology_ids": PackedStringArray(["idea.x1_probe"]),
		"acquisition_flags": PackedByteArray([3]),
		"rarity_weights": PackedInt32Array([1]),
		"ideology_slot_costs": PackedInt32Array([1]),
		"spirit_slot_costs": PackedInt32Array([1]),
		"national_spirit_min_levels": PackedInt32Array([1]),
		"level_offsets": PackedInt32Array([0, 3]),
		"level_thresholds_q16": PackedInt64Array([0, 3 * Q16_ONE, 5 * Q16_ONE]),
		"level_daily_understanding_q16": PackedInt64Array([Q16_ONE, Q16_ONE, Q16_ONE]),
		"technology_requirement_offsets": PackedInt32Array([0, 0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0, 0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0, 0]),
		"gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0, 1, 2, 3]),
		"persistent_actions": PackedInt32Array([1, 1, 1]),
		"persistent_domains": PackedInt32Array([2, 2, 2]),
		"persistent_opcodes": PackedInt32Array([1, 1, 1]),
		"persistent_values_q16": PackedInt64Array([Q16_ONE, Q16_ONE, Q16_ONE]),
		"persistent_duration_days": PackedInt32Array([-1, -1, -1]),
		"persistent_stacks": PackedInt32Array([1, 1, 1]),
		"persistent_command_keys": PackedStringArray([
			"ideology.persistent", "ideology.persistent", "ideology.persistent"]),
		"persistent_definition_keys": PackedStringArray([
			PROGRAM_KEY, PROGRAM_KEY, PROGRAM_KEY]),
		"persistent_payload_i0": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i1": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i2": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i3": PackedInt64Array([0, 0, 0]),
		"level_on_enter_offsets": PackedInt32Array([0, 0, 0, 0]),
		"on_enter_actions": PackedInt32Array(), "on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(), "on_enter_values_q16": PackedInt64Array(),
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
		"sequences": PackedInt64Array(), "country_handles": PackedInt64Array(),
		"ideology_ids": PackedInt32Array(), "values_q16": PackedInt64Array(),
		"offer_generations": PackedInt64Array(), "choice_indices": PackedInt32Array(),
		"gate_ids": PackedInt32Array(),
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
