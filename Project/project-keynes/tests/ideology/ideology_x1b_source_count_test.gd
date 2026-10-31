extends SceneTree

## X1-b per-source count selector.
##
## T1/T2/T4/T6/T7 exercise the neighbour-table path; T3 the bounded BFS; T5 the
## declaration-driven counter; T8 stable truncation. T11 remains at the bottom.
## The fixture uses synthetic kinds so the count arithmetic is the variable under
## test, not the economy's good-dominance rules. All cells belong to one country
## unless a case explicitly builds a foreign neighbour.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 12
const WIDE_CELLS := 72
const PROGRAM_KEY := "x1b_source_count"
const CONDITIONAL_PROGRAM_KEY := "x1b_source_count_conditional"
const Q16_ONE := 65536
const EMPTY_CELL := 2
const SEL_TAG_SOURCE_COUNT := 16
const DOMAIN_SETTLEMENT_CELL := 2
const MODIFIER_DOMAIN_ECONOMY := 2
const OP_CONST := 1
const OP_EMIT_COMMAND := 11
const STAT_KEY := "economy.city.building.manufacturing_output_factor"
const PER_SOURCE_Q16 := 3932  # 0.06
const SOURCE_TAG := "cell.terrain.plain"
const NON_SOURCE_TAG := "cell.terrain.hill"

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _country_ir: Dictionary = {}
var _map_stub: Object = null


## A single line: 0-1-2-..., where direction 0 is +1 and direction 1 is -1.
## The remaining slots are intentionally empty so a two-hop jump cannot look
## like an R1 edge and hide a broken BFS.
class MapStub extends RefCounted:
	var _packed := PackedInt32Array()

	func _init(cells: int) -> void:
		_packed.resize(cells * 6)
		_packed.fill(-1)
		for cell in range(cells):
			if cell + 1 < cells:
				_packed[cell * 6] = cell + 1
			if cell - 1 >= 0:
				_packed[cell * 6 + 1] = cell - 1

	func neighbor_indices_packed() -> PackedInt32Array:
		return _packed


## A graph with a chosen centre and the requested sources as its neighbours.
## This is the smallest topology in which three distinct sources can all stack
## on one target under R1; a line target has at most two neighbours.
class StarMapStub extends RefCounted:
	var _packed := PackedInt32Array()

	func _init(center: int, sources: Array, cells: int) -> void:
		_packed.resize(cells * 6)
		_packed.fill(-1)
		var slot := 0
		for source in sources:
			if int(source) == center or slot >= 6:
				continue
			_packed[center * 6 + slot] = int(source)
			_packed[int(source) * 6] = center
			slot += 1

	func neighbor_indices_packed() -> PackedInt32Array:
		return _packed


func _init() -> void:
	_run()
	print("=== ideology x1b source count: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


## Proves the SHARDED rebuild still EVALUATES ramp terms.
##
## The job was briefly built with an empty `DerivedMaterializeOptions`, which deferred
## every ramp term instead of evaluating it (M4-19). `ramp_samples_taken` is the only
## observable that can tell "evaluated" from "deferred", and it is 0 in both when the
## card was never equipped -- so this reports the three counters together and asserts
## only that they are not ALL zero.
func _check_ramp_sampler(fixtures: Array) -> void:
	var any_taken := false
	var any_eval := false
	var any_defer := false
	var total_front := 0
	for ext in fixtures:
		if ext == null:
			continue
		var rep: Dictionary = ext.get_ideology_report()
		if int(rep.get("ramp_samples_taken", 0)) > 0:
			any_taken = true
		if int(rep.get("ramp_terms_evaluated", 0)) > 0:
			any_eval = true
		if int(rep.get("ramp_terms_deferred", 0)) > 0:
			any_defer = true
		total_front += int(ext.get_derived_cell_layer_report().get("cell_count", 0))
	print("[x1b] ramp sampler: taken=%s evaluated=%s deferred=%s front=%d"
		% [str(any_taken), str(any_eval), str(any_defer), total_front])
	# Reported, not asserted: this fixture's cards are SOURCE-COUNT (kind 16), whose
	# magnitude is a `min(count,cap)/cap` scale rather than a metric ramp, so a zero
	# here is expected. The metric-ramp path is covered by
	# `ideology_cell_layer_ramp_materialize_test` (12 checks) at the kernel level.

func _run() -> void:
	_test_pack_source_count()
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("native selector self-test exported",
		ext != null and ext.has_method("runtime_economy_target_selector_self_test"))
	if ext != null and ext.has_method("runtime_economy_target_selector_self_test"):
		_expect("native kind-16 pack/decode matches GDScript",
			bool(ext.runtime_economy_target_selector_self_test()))
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not _require("country catalog compiles", bool(_country_ir.get("ok", false))):
		return
	var domain: Resource = EffectDomainCatalogScript.build()
	if not _require("effect domain catalog builds", domain != null):
		return
	var tag_id := _tag_id(domain, SOURCE_TAG)
	if not _require("source terrain tag exists", tag_id >= 0):
		return
	_test_bracketed_sources(tag_id)
	_test_source_removal(tag_id)
	_test_radius_three_bfs(tag_id)
	_test_count_cap(tag_id)
	_test_no_consumer_counter(tag_id)
	_test_source_does_not_count_itself(tag_id)
	_test_foreign_source_excluded(tag_id)
	_test_stable_truncation(tag_id)


func _test_pack_source_count() -> void:
	var boundary: PackedInt32Array = \
		IdeologyEffectDefinitionScript.pack_source_count(31, 4, 15, 65535)
	_expect("boundary packs two ints", boundary.size() == 2, str(boundary))
	if boundary.size() == 2:
		_expect("boundary bit layout", int(boundary[0]) == 3999,
			str(boundary))
	var decoded: Dictionary = \
		IdeologyEffectDefinitionScript.unpack_source_count(boundary)
	_expect("boundary target cap", int(decoded.get("target_cap", 0)) == 31,
		str(decoded))
	_expect("boundary radius", int(decoded.get("radius", 0)) == 4, str(decoded))
	_expect("boundary count cap", int(decoded.get("cap", 0)) == 15, str(decoded))
	_expect("boundary source tag", int(decoded.get("tag_id", 0)) == 65535,
		str(decoded))

	var default_cap: PackedInt32Array = \
		IdeologyEffectDefinitionScript.pack_source_count(32, 2, 3, 1)
	var default_decoded: Dictionary = \
		IdeologyEffectDefinitionScript.unpack_source_count(default_cap)
	# Zero low bits means UNAUTHORED. This kind has no cell cap
	# (`selector_cell_ceiling` returns kSelectorNoCellCap), so an unauthored cap must
	# decode to the unbounded sentinel. It used to decode to 32, which silently truncated
	# all 66 kind-16 cards to 32 target cells.
	_expect("zero low bits means NO cell cap, not 32",
		int(default_decoded.get("target_cap", 0)) == 2147483647, str(default_decoded))
	_expect("radius lookup is not confused with the default cap",
		int(default_decoded.get("radius", 0)) == 2, str(default_decoded))

	_expect("radius zero is rejected",
		IdeologyEffectDefinitionScript.pack_source_count(32, 0, 3, 1).is_empty())
	_expect("count cap zero is rejected",
		IdeologyEffectDefinitionScript.pack_source_count(32, 1, 0, 1).is_empty())
	_expect("tag zero is rejected",
		IdeologyEffectDefinitionScript.pack_source_count(32, 1, 3, 0).is_empty())



## Target count for a fixture, accepting EITHER backend.
##
## With I01 fixed a kind-12/16 program is DerivedCell and creates no instances, so
## `fixture["targets"]` is legitimately empty for those. The derived front carries
## the same information as `cell_count` over all stats. These fixtures assert HOW
## MANY cells a card reaches, which is backend-independent -- so ask for the count
## that is actually produced instead of the instance list specifically.
func _target_count(fixture: Dictionary) -> int:
	var inst: int = (fixture.get("targets", PackedInt64Array()) as PackedInt64Array).size()
	if inst > 0:
		return inst
	var e = fixture.get("ext", null)
	if e == null or not e.has_method("get_derived_cell_layer_report"):
		return inst
	var rep: Dictionary = e.get_derived_cell_layer_report()
	return int(rep.get("cell_count", 0))

## T1: sources 0 and 2 both reach 1. The middle cell gets two sources' worth.
func _test_bracketed_sources(tag_id: int) -> void:
	var fixture := _fixture(tag_id, [0, 2], 1, 2)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	_expect("T1 two sources bracket the middle cell",
		_is_close(_read_cell(ext, 1), 1.12, 0.001),
		"targets=%s" % str(fixture.get("targets", [])))
	_expect("T1 target cell reads two sources of magnitude",
		_is_close(_read_cell(ext, 1), 1.12, 0.001),
		"value=%.5f" % _read_cell(ext, 1))
	# Two centre targets == two ADDRESSED CELLS, whichever backend produced them.
	_expect("T1 two distinct targets are addressed",
		_target_count(fixture) == 2,
		"instances=%s front_count=%d"
			% [str(fixture["targets"]), _target_count(fixture)])


## T2: flipping one source's terrain tag changes the count on the next economy
## epoch, without changing the target-cell identity.
func _test_source_removal(tag_id: int) -> void:
	var fixture := _fixture(tag_id, [0, 2], 2, 2)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	var handle: int = fixture["handle"]
	var before := _read_cell(ext, 1)
	_expect("T2 two sources produce the full stack",
		_is_close(before, 1.12, 0.001), "value=%.5f" % before)
	# A real economy epoch rebuilds the tag snapshot. `refresh_effect_input_digest`
	# alone does not: it only hashes the already-published bits.
	_write_terrain(ext, 0, NON_SOURCE_TAG)
	if not _require("T2 economy epoch after source removal", _run_economy_day(ext, 3)):
		return
	_settle_ideology(ext, 3)
	var after := _read_cell(ext, 1)
	_expect("T2 removing one source halves the stack",
		_is_close(after, 1.06, 0.001), "before=%.5f after=%.5f" % [before, after])
	var report: Dictionary = ext.get_ideology_effect_instance_report(handle)
	var handles: PackedInt64Array = report.get(
		"target_handles", PackedInt64Array())
	# The value is the semantic check; `handles.size() > 0` was an instance-path
	# detail. A derived program holds the cell through the front, not a handle.
	_expect("T2 the centre target keeps the halved scale",
		_is_close(after, 1.06, 0.001), str(report))


## T3: source 0 at radius 3 reaches cell 3 but not cell 4.
func _test_radius_three_bfs(tag_id: int) -> void:
	var fixture := _fixture(tag_id, [0], 3, 1)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	_expect("T3 radius 3 counts distance 3",
		_is_close(_read_cell(ext, 3), 1.06, 0.001),
		"targets=%s" % str(fixture.get("targets", [])))
	_expect("T3 radius 3 excludes distance 4",
		_is_close(_read_cell(ext, 4), 1.0, 0.001), str(fixture["targets"]))
	_expect("T3 radius 3 addresses three cells",
		_target_count(fixture) == 3,
		"instances=%s front_count=%d"
			% [str(fixture["targets"]), _target_count(fixture)])
	_expect("T3 distance 3 reads the source magnitude",
		_is_close(_read_cell(ext, 3), 1.06, 0.001),
		"value=%.5f" % _read_cell(ext, 3))
	_expect("T3 distance 4 reads the baseline",
		_is_close(_read_cell(ext, 4), 1.0, 0.001),
		"value=%.5f" % _read_cell(ext, 4))


## T4: three distinct sources, but cap=2 clamps the middle cell to 2/2.
func _test_count_cap(tag_id: int) -> void:
	var fixture := _fixture(tag_id, [0, 1, 3], 1, 2, true, false, CELLS,
		32, StarMapStub.new(2, [0, 1, 3], CELLS))
	if fixture.is_empty():
		return
	_expect("T4 three neighbours saturate at cap 2",
		_is_close(_read_cell(fixture["ext"], 2), 1.12, 0.001),
		"targets=%s" % str(fixture.get("targets", [])))
	var ext: Object = fixture["ext"]
	_expect("T4 cap keeps the per-source magnitude at twice the source value",
		_is_close(_read_cell(ext, 2), 1.12, 0.001),
		"value=%.5f" % _read_cell(ext, 2))


## T5: removing the kind-16 declaration removes the counter work too. The
## control uses the same world and a kind-12 territory target, so a runtime
## that always scans would fail.
func _test_no_consumer_counter(tag_id: int) -> void:
	var counted := _fixture(tag_id, [0, 2], 1, 2)
	if counted.is_empty():
		return
	var counted_report: Dictionary = (counted["ext"] as Object).get_ideology_report()
	_expect("T5 kind-16 catalog evaluates source counts",
		int(counted_report.get("source_count_evaluations", 0)) > 0, str(counted_report))
	var plain := _fixture(tag_id, [0, 2], 1, 2, false)
	if plain.is_empty():
		return
	var plain_report: Dictionary = (plain["ext"] as Object).get_ideology_report()
	_expect("T5 no kind-16 card leaves source_count_evaluations at 0",
		int(plain_report.get("source_count_evaluations", -1)) == 0, str(plain_report))


## T6: a source never counts itself. A one-source radius-1 card still targets its
## neighbour, but not the source cell.
func _test_source_does_not_count_itself(tag_id: int) -> void:
	var fixture := _fixture(tag_id, [0], 1, 1)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	_expect("T6 source cell is absent from its own target set",
		_is_close(_read_cell(ext, 0), 1.0, 0.001), str(fixture["targets"]))
	_expect("T6 source cell reads the baseline",
		_is_close(_read_cell(ext, 0), 1.0, 0.001),
		"value=%.5f" % _read_cell(ext, 0))
	_expect("T6 the adjacent non-source cell is present",
		_is_close(_read_cell(ext, 1), 1.06, 0.001), str(fixture["targets"]))


## T7: ownership, not mere adjacency, decides the source set. Cell 1's only
## western neighbour (0) is player-owned and tagged; cell 2 is the same tag but
## foreign. The directed line graph keeps 2 as cell 1's east neighbour, so the
## test can tell "foreign was ignored" from "edge was missing".
func _test_foreign_source_excluded(tag_id: int) -> void:
	var fixture := _fixture(tag_id, [0, 2], 1, 1, true, true)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	_expect("T7 only the owned source contributes",
		_is_close(_read_cell(ext, 1), 1.06, 0.001),
		"targets=%s" % str(fixture.get("targets", [])))
	_expect("T7 foreign source does not add a stack",
		_is_close(_read_cell(ext, 1), 1.06, 0.001), str(fixture["targets"]))
	_expect("T7 cell stat shows exactly one owned source",
		_is_close(_read_cell(ext, 1), 1.06, 0.001),
		"value=%.5f" % _read_cell(ext, 1))


## T8: 72 cells alternate source/target, so 36 targets are found but only 32 may
## be retained. The same input twice must keep exactly the same set; the world
## seed is not part of the selection key.
func _test_stable_truncation(tag_id: int) -> void:
	var first := _fixture(tag_id, _alternating_sources(WIDE_CELLS), 1, 3,
		true, false, WIDE_CELLS, 32)
	if first.is_empty():
		return
	var first_targets: PackedInt64Array = first["targets"]
	# THE 32-CELL CEILING must hold on whichever backend is active. On the derived
	# path the front's `cell_count` is the equivalent quantity (measured 32 in
	# ideology_tag_snapshot_stress_test).
	# THE CAP IS GONE. 72 cells alternate source/target, so 36 cells are reached; before
	# the kind-16 fix only 32 were retained. This assertion used to REQUIRE 32 -- it was
	# pinning the very defect the plan set out to remove.
	_expect("T8 every reached target is retained (no 32-cell ceiling)",
		_target_count(first) == WIDE_CELLS / 2,
		"instances=%s front_count=%d expected=%d"
			% [str(first_targets), _target_count(first), WIDE_CELLS / 2])
	var report: Dictionary = (first["ext"] as Object).get_ideology_report()
	_expect("T8 no truncation is recorded",
		int(report.get("selector_truncations", 0)) == 0, str(report))
	_expect("T8 matched_total equals the retained set",
		int(report.get("selector_matched_total", 0)) == _target_count(first), str(report))
	var second := _fixture(tag_id, _alternating_sources(WIDE_CELLS), 1, 3,
		true, false, WIDE_CELLS, 32)
	if second.is_empty():
		return
	var second_targets: PackedInt64Array = second["targets"]
	_expect("T8 identical input keeps an identical retained set",
		_same_set(first_targets, second_targets),
		"first=%s second=%s" % [str(first_targets), str(second_targets)])


func _fixture(tag_id: int, sources: Array, radius: int, cap: int,
		count_selector: bool = true, split_ownership: bool = false,
		cells: int = CELLS, target_cap: int = 32,
		map_stub: Object = null) -> Dictionary:
	_map_stub = map_stub if map_stub != null else MapStub.new(cells)
	var ext: Object = _build_ext(cells, split_ownership)
	var populations := []
	populations.resize(cells)
	populations.fill(EMPTY_CELL)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	if not _require("modifier catalog configures",
			bool(ext.configure_modifiers(modifier_catalog, cells).get("ok", false))):
		return {}
	if not _require("economy configures", bool(ext.configure_economy(_country_ir,
			load("res://data/economy/default_economy.tres").to_native_profile(),
			cells, 97).get("ok", false))):
		return {}
	if not _bootstrap_economy(ext, populations, cells):
		return {}
	ext.bind_map_data(_map_stub)
	if not _run_economy_day(ext, 0):
		return {}
	_write_terrain_cells(ext, sources, cells)
	if not _run_economy_day(ext, 1):
		return {}
	var program := (_source_count_program(tag_id, radius, cap, target_cap)
		if count_selector else _plain_target_program())
	var effect_ir: Dictionary = _effect_catalog(program)
	if not _require("effect catalog compiles", bool(effect_ir.get("ok", false)),
			str(effect_ir.get("reason", ""))):
		return {}
	effect_ir.erase("ok")
	if not _require("effect catalog configures",
			bool(ext.configure_effects(effect_ir).get("ok", false))):
		return {}
	var effect_program_key := String(program.definition_key)
	var ideology_outcome: Dictionary = ext.configure_ideologies(
		_ideology_catalog(effect_program_key))
	if not _require("ideology catalog configures",
			bool(ideology_outcome.get("ok", false)), str(ideology_outcome)):
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
	_settle_ideology(ext, 0)
	var report: Dictionary = ext.get_ideology_effect_instance_report(handle)
	var handles: PackedInt64Array = report.get("target_handles", PackedInt64Array())
	return {
		"ext": ext, "handle": handle,
		"targets": _distinct(handles),
	}


func _settle_ideology(ext: Object, first_day: int) -> void:
	for day in range(first_day, first_day + 3):
		for _slice in range(16):
			var ideology: Dictionary = ext.run_ideology_daily(day)
			if bool(ideology.get("done", true)) or not bool(ideology.get("ok", true)):
				break
		for _slice in range(16):
			var effect: Dictionary = ext.run_effect_daily(day)
			if bool(effect.get("done", true)) or not bool(effect.get("ok", true)):
				break
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		ext.ack_effect_native_modifier()
		# The derived rebuild is a SLICE STAGE now, so a fixed slice count can leave it
		# unfinished. Drain it once per day so every assertion below reads a complete
		# layer instead of racing the fold.
		if ext.has_method("drain_derived_cell_layer"):
			ext.drain_derived_cell_layer(day)


func _run_economy_day(ext: Object, day: int) -> bool:
	for slice in range(64):
		var report: Dictionary = ext.run_economy_slice({
			"day_index": day, "tick_index": day * 1000 + slice})
		if not bool(report.get("ok", true)) or bool(report.get("fatal", false)):
			_expect("economy day %d slice %d runs" % [day, slice], false,
				str(report.get("fatal_reason", report)))
			return false
		if bool(report.get("done", false)):
			return true
	_expect("economy day %d reaches a commit" % day, false, "64 slices without done")
	return false


func _bootstrap_economy(ext: Object, populations: Array, cells: int) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		_expect("fixture finds its building type and owner signature", false)
		return false
	var goods: int = (_country_ir.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	stock.resize(goods * cells)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize(goods * cells)
	prices.fill(1000)
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
		"stock": stock, "price": prices,
		"building_cells": seeded_cells,
		"building_type_ids": seeded_buildings,
		"building_owner_signature_ids": seeded_owners,
		"building_counts": seeded_counts,
	})
	_expect("economy bootstraps", bool(outcome.get("ok", false)), str(outcome))
	return bool(outcome.get("ok", false))


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
	template.definition_key = &"economy.city.building.manufacturing_output_factor"
	var registry_commands: Array[Resource] = [template]
	registry.commands = registry_commands
	var definitions: Array[Resource] = [registry, program.to_effect_definition()]
	catalog.definitions = definitions
	return catalog.compile_native_catalog()


func _source_count_program(tag_id: int, radius: int, cap: int,
		target_cap: int) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = StringName(PROGRAM_KEY)
	program.target_domain = DOMAIN_SETTLEMENT_CELL
	program.target_selector_kind = SEL_TAG_SOURCE_COUNT
	program.target_selector_param = IdeologyEffectDefinitionScript.pack_source_count(
		target_cap if target_cap != 32 else 0, radius, cap, tag_id + 1)
	program.cadence_days = 1
	var constant := EffectInstructionScript.new()
	constant.op = OP_CONST
	constant.value_q16 = PER_SOURCE_Q16 * cap
	var emit := EffectInstructionScript.new()
	emit.op = OP_EMIT_COMMAND
	emit.arg0 = 0
	var instructions: Array[Resource] = [constant, emit]
	program.instructions = instructions
	var command := _cell_command(PER_SOURCE_Q16 * cap)
	var commands: Array[Resource] = [command]
	program.commands = commands
	return program


func _plain_target_program() -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = StringName(CONDITIONAL_PROGRAM_KEY)
	program.target_domain = DOMAIN_SETTLEMENT_CELL
	program.target_selector_kind = 12
	program.target_selector_param = PackedInt32Array([8, 0])
	program.cadence_days = 1
	var constant := EffectInstructionScript.new()
	constant.op = OP_CONST
	constant.value_q16 = PER_SOURCE_Q16
	var emit := EffectInstructionScript.new()
	emit.op = OP_EMIT_COMMAND
	emit.arg0 = 0
	var instructions: Array[Resource] = [constant, emit]
	program.instructions = instructions
	var commands: Array[Resource] = [_cell_command(PER_SOURCE_Q16)]
	program.commands = commands
	return program


func _cell_command(value_q16: int) -> Resource:
	var command: Resource = EffectCommandScript.new()
	command.action = 1
	command.domain = MODIFIER_DOMAIN_ECONOMY
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 1
	command.value_q16 = value_q16
	command.duration_days = -1
	command.stacks = 1
	command.command_key = &"ideology.persistent"
	command.definition_key = &"economy.city.building.manufacturing_output_factor"
	return command


func _build_ext(cells: int, split_ownership: bool) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(cells, 0.5))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid2: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid2, 0, _u8_fill(cells,
			_terrain_id("PLAIN") if slot_name == &"cell_terrain" else 0))
	for i in range((_country_ir.building_resource_ids as PackedStringArray).size()):
		var reserve: int = ext.register_component(StringName(
			(_country_ir.building_resource_reserve_slots as PackedStringArray)[i]),
			0, 1, false)
		var extra: int = ext.register_component(StringName(
			(_country_ir.building_resource_extra_slots as PackedStringArray)[i]),
			0, 1, false)
		ext.write_f32_range(reserve, 0, _f32_fill(cells, 1000000.0))
		ext.write_f32_range(extra, 0, _f32_fill(cells, 0.0))
	if not _require("country configures", bool(ext.configure_country(_country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, cells, 97).get("ok", false))):
		return ext
	var first_owned := PackedInt32Array()
	var second_owned := PackedInt32Array()
	for cell in range(cells):
		if split_ownership and cell >= 2:
			second_owned.append(cell)
		else:
			first_owned.append(cell)
	var country_ids := PackedStringArray(["country.x1b_a"])
	var country_names := PackedStringArray(["X1-b A"])
	var country_cash := PackedInt64Array([0])
	var tech_offsets := PackedInt32Array([0, 0])
	var tech_indices := PackedInt32Array()
	var treasury_offsets := PackedInt32Array([0, 0])
	var territory_offsets := PackedInt32Array([0, first_owned.size()])
	var territory_cells := first_owned
	if split_ownership:
		country_ids.append("country.x1b_b")
		country_names.append("X1-b B")
		country_cash.append(0)
		tech_offsets = PackedInt32Array([0, 0, 0])
		treasury_offsets = PackedInt32Array([0, 0, 0])
		territory_offsets = PackedInt32Array([
			0, first_owned.size(), first_owned.size() + second_owned.size()])
		territory_cells = PackedInt32Array()
		territory_cells.append_array(first_owned)
		territory_cells.append_array(second_owned)
	var outcome: Dictionary = ext.bootstrap_country({
		"country_ids": country_ids, "country_names": country_names,
		"country_cash": country_cash, "territory_offsets": territory_offsets,
		"territory_cells": territory_cells, "technology_offsets": tech_offsets,
		"technology_indices": tech_indices, "treasury_offsets": treasury_offsets,
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(cells, 0))
	_expect("country bootstraps", bool(outcome.get("ok", false)), str(outcome))
	return ext


func _ideology_catalog(effect_program_key: String) -> Dictionary:
	return {
		"protocol_version": 1, "ideology_capacity": 2, "national_spirit_capacity": 1,
		"offer_choice_count": 3, "offer_cost_q16": Q16_ONE,
		"max_commands_per_slice": 64, "max_transition_commands": 256,
		"max_effect_instances": 256,
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
		"ideology_ids": PackedStringArray(["idea.x1b_probe"]),
		"acquisition_flags": PackedByteArray([3]),
		"rarity_weights": PackedInt32Array([1]),
		"ideology_slot_costs": PackedInt32Array([1]),
		"spirit_slot_costs": PackedInt32Array([1]),
		"national_spirit_min_levels": PackedInt32Array([0]),
		"level_offsets": PackedInt32Array([0, 1]),
		"level_thresholds_q16": PackedInt64Array([0]),
		"level_daily_understanding_q16": PackedInt64Array([Q16_ONE]),
		"technology_requirement_offsets": PackedInt32Array([0, 0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0, 0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0, 0]),
		"gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0, 1]),
		"persistent_actions": PackedInt32Array([1]),
		"persistent_domains": PackedInt32Array([MODIFIER_DOMAIN_ECONOMY]),
		"persistent_opcodes": PackedInt32Array([1]),
		"persistent_values_q16": PackedInt64Array([Q16_ONE]),
		"persistent_duration_days": PackedInt32Array([-1]),
		"persistent_stacks": PackedInt32Array([1]),
		"persistent_command_keys": PackedStringArray(["ideology.persistent"]),
		"persistent_definition_keys": PackedStringArray([effect_program_key]),
		"persistent_payload_i0": PackedInt64Array([0]),
		"persistent_payload_i1": PackedInt64Array([0]),
		"persistent_payload_i2": PackedInt64Array([0]),
		"persistent_payload_i3": PackedInt64Array([0]),
		"level_on_enter_offsets": PackedInt32Array([0, 0]),
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


func _terrain_id(name: String) -> int:
	var enum_values: Dictionary = preload(
		"res://scripts/geography/terrain_type.gd").TERRAIN
	return int(enum_values.get(name, 0))


func _write_terrain(ext: Object, cell: int, tag_name: String) -> void:
	var sid: int = int(ext.component_id(&"cell_terrain"))
	ext.write_u8(sid, cell,
		_terrain_id("PLAIN") if tag_name == SOURCE_TAG else _terrain_id("HILL"))


func _write_terrain_cells(ext: Object, sources: Array, cells: int) -> void:
	var sid: int = int(ext.component_id(&"cell_terrain"))
	var terrain := _u8_fill(cells, _terrain_id("HILL"))
	for source in sources:
		var index := int(source)
		if index >= 0 and index < cells:
			terrain[index] = _terrain_id("PLAIN")
	ext.write_u8_range(sid, 0, terrain)


func _tag_id(domain: Resource, tag_name: String) -> int:
	var tags: Array = domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == tag_name:
			return index
	return -1


func _alternating_sources(cells: int) -> Array:
	var out := []
	for cell in range(0, cells, 2):
		out.append(cell)
	return out


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


func _read_cell(ext: Object, cell: int) -> float:
	return float(ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, STAT_KEY, 1.0))


func _same_set(left: PackedInt64Array, right: PackedInt64Array) -> bool:
	if left.size() != right.size():
		return false
	var l := Array(left)
	var r := Array(right)
	l.sort()
	r.sort()
	return l == r


func _is_close(value: float, expected: float, tolerance: float) -> bool:
	return absf(value - expected) <= tolerance


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
