extends SceneTree
## Why does a kind-14 card produce no derived coverage?
##
## Three earlier attempts failed at different stages (M5-34 native-tag, M5-40 pod_fail).
## The `collect_pod_fail` counter could not distinguish "the card never became active"
## from "the card is active but its declarative program is missing", so this fixture
## prints the new `collect_pod_fail_keys` list, which names the programs.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_kind14_diagnosis_test.gd

const WIDTH := 20
const HEIGHT := 20
const CELLS: int = WIDTH * HEIGHT
const Q16_ONE := 65536
const CARD_KEY := "idea.autonomous_logistics"
const TAG_METRIC := "cell.trade_events"

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

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

	func economy_trade_passable_lut() -> PackedByteArray:
		var out := PackedByteArray()
		out.resize(_packed.size() / 6)
		out.fill(1)
		return out

	func economy_trade_move_cost_lut() -> PackedInt32Array:
		var out := PackedInt32Array()
		out.resize(_packed.size() / 6)
		out.fill(1)
		return out


var _checks := 0
var _failures := 0
var _seq := 0
## Day cursor for `run_ideology_daily`. Indices must be STRICTLY MONOTONIC: the
## active pass is gated on `_last_day < day` (ideology_runtime.cpp:5010), so
## replaying a day silently skips the pass that settles a transition.
var _day := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	var metric_keys: PackedStringArray = domain.metric_keys
	var tag_metric_id: int = metric_keys.find(TAG_METRIC)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var native_ideology: Dictionary = IdeologyCatalogScript.load_default() \
		.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the kind-14 card is in the compiled catalog", dense >= 0, str(dense))
	if dense < 0:
		_finish(1)
		return

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_fill_environment(ext)
	ext.configure_economy(country_ir, profile, CELLS, 103)
	ext.configure_effects(effect_ir)
	ext.configure_modifiers(mod_ir, CELLS)
	ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 103)
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.diag"]),
		"country_names": PackedStringArray(["Diag"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	# The tag snapshot is an IMMUTABLE snapshot built lazily on first use, so the metric
	# override has to be in place BEFORE anything can trigger that build -- i.e. before the
	# epoch opens. Applying it just before the equip (the first version) was too late and
	# the tag matched nothing (`targets_fanout_ring_empty`).
	if tag_metric_id >= 0:
		ext.set_effect_metric_override_for_test(tag_metric_id, 40 * Q16_ONE, true)
	# `bind_map_data` is NOT used here: a hand-written MapData stub crashes the topology
	# capture (`world_ext_economy.cpp:929-930`, 0xC0000005) -- measured this round.
	# Without a neighbour table `dilate_cell_set` returns nothing, so this fixture proves
	# everything up to the ring walk and stops there. Closing that last step needs a REAL
	# generated MapData, which is the same prerequisite as the >32 production sample.
	ext.configure_ideologies(native_ideology)
	ext.begin_or_reuse_economy_input_epoch(0, _epoch(1, 0))
	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	if farmer >= 0:
		var stock := PackedInt64Array()
		stock.resize(CELLS * goods)
		stock.fill(0)
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(CELLS):
			ci.append(c)
			si.append(farmer)
			pp.append(30)
			ff.append(10000000)
		ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si, "population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		for s in range(512):
			if bool(ext.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
				break

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("the country resolves", handle != 0, str(handle))
	if handle == 0:
		_finish(1)
		return
	_equip(ext, handle, dense)

	var rep: Dictionary = ext.get_ideology_report()
	print("[diag] templates=%s pod_fail=%s program_empty=%s targets_fail=%s entries=%s"
		% [str(rep.get("collect_templates", "?")),
			str(rep.get("collect_pod_fail", "?")),
			str(rep.get("collect_program_empty", "?")),
			str(rep.get("collect_targets_fail", "?")),
			str(rep.get("collect_entries", "?"))])
	print("[diag] pod_fail_keys=%s" % str(rep.get("collect_pod_fail_keys", [])))
	print("[diag] pod_ok_keys  =%s" % str(rep.get("collect_pod_ok_keys", [])))
	print("[diag] targets: anchor_neg=%s no_tag=%s ring_empty=%s no_source=%s empty=%s domain_gate=%s economy_null=%s country_zero=%s"
		% [str(rep.get("targets_anchor_neg", "?")),
			str(rep.get("targets_fanout_no_tag", "?")),
			str(rep.get("targets_fanout_ring_empty", "?")),
			str(rep.get("targets_fanout_no_source", "?")),
			str(rep.get("targets_collected_empty", "?")),
			str(rep.get("targets_domain_gate", "?")),
			str(rep.get("targets_economy_null", "?")),
			str(rep.get("targets_country_zero", "?"))])
	print("[diag] derived_emitted=%s matches=%s locations=%s"
		% [str(rep.get("collect_derived_emitted", "?")),
			str(rep.get("cell_layer_rebuild_slice_matches", "?")),
			str(ext.get_ideology_snapshot(handle).get("locations", PackedInt32Array()))])

	var keys: PackedStringArray = rep.get("collect_pod_fail_keys", PackedStringArray())
	var card_program := "ideology.effect.autonomous_logistics_l1"
	print("[diag] does the CARD's program appear among the failures? %s"
		% str(keys.has(card_program)))
	_expect("the diagnostic reports some pod failures", int(rep.get("collect_pod_fail", 0)) > 0,
		str(rep.get("collect_pod_fail", "?")))
	_finish(0 if _failures == 0 else 3)


func _equip(ext: Object, handle: int, dense: int) -> void:
	ext.submit_ideology_commands(_commands([
		{"op": 2, "day": _day, "handle": handle, "idea": -1, "value": 64 * Q16_ONE}]))
	ext.submit_ideology_commands(_commands([
		{"op": 1, "day": _day, "handle": handle, "idea": dense}]))
	_advance(ext, 3)
	ext.submit_ideology_commands(_commands([
		{"op": 8, "day": _day, "handle": handle, "idea": dense, "value": 0}]))
	_advance(ext, 3)
	ext.submit_ideology_commands(_commands([
		{"op": 5, "day": _day, "handle": handle, "idea": dense}]))
	_advance(ext, 4)
	# ---- SETTLE BEFORE READING THE DIAGNOSTIC -------------------------------
	# `equip` writes `location` at REQUEST time (`start_transition`,
	# ideology_runtime.cpp:3631-3633), but while the equip transition is UNACKed
	# `collect_effect_activations` contributes nothing at all: it returns before
	# even counting a template when `previous_location == INACTIVE` (:2313-2321,
	# plan 10.1). Reading the counters before the ACK therefore reported
	# `collect_templates=0` for a card that had in fact equipped -- a read taken
	# too early, not a defect of the card. The adapter handshake plus one more
	# ideology day is what makes the counters describe the card.
	var guard := 0
	while int(ext.get_ideology_report().get("pending_transitions", -1)) != 0 \
			and guard < 16:
		_advance(ext, 1)
		guard += 1
	print("[diag] settle: pending_transitions=%s after %d extra day(s)"
		% [str(ext.get_ideology_report().get("pending_transitions", "?")), guard])


## Runs `days` ideology days TO COMPLETION, each followed by the native Effect
## adapter pulse, advancing the day cursor.
func _advance(ext: Object, days: int) -> void:
	for _i in range(days):
		_day += 1
		for _slice in range(128):
			var r: Dictionary = ext.run_ideology_daily(_day)
			if bool(r.get("done", true)) or not bool(r.get("ok", true)):
				break
		_serve_native_adapters(ext, _day)


## The production Effect adapter handshake (`world_ext_bind_methods.cpp:633-638`).
## `run_modifier_daily` between dispatch and ACK is MANDATORY: it is what completes
## the rows the dispatch submitted, and only then can the ACK close the batch.
func _serve_native_adapters(ext: Object, day: int) -> void:
	for _i in range(8):
		ext.run_effect_daily(day)
		var dispatched: Dictionary = ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		ext.dispatch_effect_native_country()
		ext.ack_effect_native_country()
		if not bool(dispatched.get("ok", true)) or not bool(acked.get("ok", true)):
			printerr("[diag/adapters day=%d] dispatch=%s ack=%s"
				% [day, str(dispatched), str(acked)])
			return
		if int(acked.get("acknowledged", 0)) > 0 \
				and int(acked.get("pending", 0)) == 0:
			return
		if int(ext.get_ideology_report().get("pending_transitions", -1)) == 0:
			return


func _epoch(epoch: int, sample_day: int) -> Dictionary:
	return {
		"sample_day": sample_day, "epoch_id": epoch, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}


func _fill_environment(ext: Object) -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zf := PackedFloat32Array()
	zf.resize(CELLS)
	var zu := PackedByteArray()
	zu.resize(CELLS)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zf)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zu)


func _u8_zero(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	return out


func _commands(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		producers.append(1)
		_seq += 1
		sequences.append(_seq)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days,
		"source_priorities": priorities, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	}


func _finish(code: int) -> void:
	print("=== kind14 diagnosis: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
