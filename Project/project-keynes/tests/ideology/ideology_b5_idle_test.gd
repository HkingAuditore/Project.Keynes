extends SceneTree
## B5 — 30 days with no relevant change must do ZERO work.
##
## WHY THIS GATE EXISTS
##
## §14.1's idle row: "常数／版本检查；无物化与安装". Without this, a rebuild that runs
## every day but produces the same rows still costs a full fold and still bumps the
## layer generation -- every reader downstream then invalidates for nothing. The failure
## mode this catches is a rebuild that is *cheap per step* yet runs perpetually: the
## per-step gate (§14.3) is green while the machine burns a full materialise every day.
##
## WHAT IS ASSERTED
##
##   1. the front's `layer_generation` does not move across 30 idle days;
##   2. `cell_layer_rebuild_steps` does not grow;
##   3. `derived_rebuild_pending` stays false;
##   4. the layer is still installed and still covers its cells (idle is not "torn down").
##
## A NEGATIVE CONTROL runs first: the same world WITH an epoch change must bump the
## generation. Without it, "generation unchanged" would also pass on a fixture where the
## rebuild never ran at all, which proves nothing.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b5_idle_test.gd

const WIDTH := 20
const HEIGHT := 20
const CELLS: int = WIDTH * HEIGHT
const Q16_ONE := 65536
const IDLE_DAYS := 30
## Defensive ceiling for the transition settle handshake. A transition that needs
## more rounds than this is stuck, not slow.
const SETTLE_ROUNDS := 16

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

var _checks := 0
var _failures := 0
var _seq := 0
## The last ideology day the fixture has consumed. `run_ideology_daily` day indices
## must be STRICTLY MONOTONIC, so every phase asks this counter for the next day
## instead of re-using a literal.
var _day := -1


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	var world := _build()
	if world.is_empty():
		_finish(1)
		return
	var ext: Object = world["ext"]
	var dense: int = world["dense"]

	_equip(ext, dense)
	var first := _snapshot(ext, _day)
	print("[B5] after equip: gen=%s steps=%s cells=%s pending=%s"
		% [str(first.get("layer_generation", "?")),
			str(first.get("cell_layer_rebuild_steps", "?")),
			str(first.get("cell_count", "?")),
			str(first.get("derived_rebuild_pending", "?"))])
	# Premise: the layer must actually be installed and non-empty, or "nothing changed"
	# is trivially true.
	_expect("the layer is installed after equipping",
		bool(first.get("installed", false)), str(first))
	_expect("the layer covers the territory", int(first.get("cell_count", 0)) > 0,
		str(first.get("cell_count", "?")))

	# ── NEGATIVE CONTROL: a CONTENT change must move the generation ─────────
	#
	# NOT "an epoch change". Measured: reopening the epoch with identical inputs left
	# the generation at 1, because the front came out identical and `install` correctly
	# declines to bump (§I13). That is right behaviour; it just makes an epoch change a
	# useless control. What must move the generation is a change the LAYER can see, so
	# this moves a metric the card ramps on.
	var before_probe: Dictionary = ext.get_effective_stat_value(
		"economy.city.building.extractive_output_factor", 1, 0, 1.0)
	print("[B5] add BEFORE override = %s" % str(before_probe.get("derived_add", "?")))
	# BELOW the program's clamp (15), so the contribution really moves. An override of
	# 40 is absorbed by `min(metric,15)` and changes nothing -- measured.
	ext.set_effect_metric_override_for_test(57, 5 * Q16_ONE, true)
	ext.begin_or_reuse_economy_input_epoch(1, _epoch(1, 2))
	_step_day(ext)
	ext.drain_derived_cell_layer(_day)
	var after_probe: Dictionary = ext.get_effective_stat_value(
		"economy.city.building.extractive_output_factor", 1, 0, 1.0)
	var bumped := _snapshot(ext, _day)
	print("[B5] add AFTER override = %s   gen=%s epoch=%s sample_day=%s"
		% [str(after_probe.get("derived_add", "?")),
			str(bumped.get("layer_generation", "?")),
			str(bumped.get("epoch_id", "?")),
			str(bumped.get("sample_day", "?"))])
	print("[B5] after content change: gen=%s steps=%s"
		% [str(bumped.get("layer_generation", "?")),
			str(bumped.get("cell_layer_rebuild_steps", "?"))])
	var after_add := float(after_probe.get("derived_add", -1.0))
	var before_add := float(before_probe.get("derived_add", -1.0))
	_expect("NEGATIVE CONTROL: the override really moved the contribution",
		absf(after_add - before_add) > 1e-6,
		"before=%.8f after=%.8f" % [before_add, after_add])
	_expect("NEGATIVE CONTROL: a content change moves the layer generation",
		int(bumped.get("layer_generation", 0)) != int(first.get("layer_generation", 0)),
		"before=%s after=%s" % [str(first.get("layer_generation", "?")),
			str(bumped.get("layer_generation", "?"))])

	# ── IDLE: 30 days, no epoch change ─────────────────────────────────────
	var base_gen := int(bumped.get("layer_generation", 0))
	var base_steps := int(bumped.get("cell_layer_rebuild_steps", 0))  # printed only
	for _i in range(IDLE_DAYS):
		_step_day(ext)
		ext.drain_derived_cell_layer(_day)
	var idle := _snapshot(ext, _day)
	print("[B5] after %d idle days: gen=%s (was %d)  steps=%s (was %d)  cells=%s pending=%s"
		% [IDLE_DAYS, str(idle.get("layer_generation", "?")), base_gen,
			str(idle.get("cell_layer_rebuild_steps", "?")), base_steps,
			str(idle.get("cell_count", "?")),
			str(idle.get("derived_rebuild_pending", "?"))])

	_expect("30 idle days do NOT bump the layer generation",
		int(idle.get("layer_generation", -1)) == base_gen,
		"was %d now %s" % [base_gen, str(idle.get("layer_generation", "?"))])
	# `cell_layer_rebuild_steps` is NOT cumulative (measured 16 -> 14 -> 15 -> 13 -> 14
	# across runs), so it cannot express "no extra work". `sample_day` can: it records
	# the day the installed front was built from, and a rebuild that did not happen
	# leaves it exactly where it was.
	_expect("30 idle days do NOT rebuild the front (sample_day frozen)",
		int(idle.get("sample_day", -1)) == int(bumped.get("sample_day", -2)),
		"was %s now %s" % [str(bumped.get("sample_day", "?")),
			str(idle.get("sample_day", "?"))])
	_expect("nothing is pending after the idle window",
		not bool(idle.get("derived_rebuild_pending", true)),
		str(idle.get("derived_rebuild_pending", "?")))
	# Idle must not mean torn down: the coverage has to survive.
	_expect("the layer still covers the territory after idling",
		int(idle.get("cell_count", 0)) == int(bumped.get("cell_count", -1)),
		"%s vs %s" % [str(idle.get("cell_count", "?")),
			str(bumped.get("cell_count", "?"))])
	# And the value must still be the equipped card's contribution, not reset to base.
	var probe: Dictionary = ext.get_effective_stat_value(
		"economy.city.building.extractive_output_factor", 1, 0, 1.0)
	print("[B5] idle value probe: %s" % str(probe))
	_expect("the contribution survives the idle window",
		bool(probe.get("derived_present", false)) and
			absf(float(probe.get("derived_add", 0.0))) > 1e-9,
		str(probe))

	_finish(0 if _failures == 0 else 3)


func _snapshot(ext: Object, day: int) -> Dictionary:
	var out: Dictionary = ext.get_derived_cell_layer_report()
	var rep: Dictionary = ext.get_ideology_report()
	out["cell_layer_rebuild_steps"] = rep.get("cell_layer_rebuild_steps", -1)
	out["derived_rebuild_pending"] = rep.get("derived_rebuild_pending", true)
	out["day"] = day
	return out


func _epoch(epoch: int, sample_day: int) -> Dictionary:
	return {
		"sample_day": sample_day, "epoch_id": epoch, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}


func _build() -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	_install_satisfiable_tag(domain, "cell.sector.extractive")
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var native_ideology: Dictionary = IdeologyCatalogScript.load_default() \
		.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find("idea.salt_monopoly")
	if dense < 0:
		_expect("the card is in the compiled catalog", false)
		return {}

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_fill_environment(ext)
	if not bool(ext.configure_economy(country_ir, profile, CELLS, 83).get("ok", false)):
		_expect("economy configures", false)
		return {}
	ext.configure_effects(effect_ir)
	ext.configure_modifiers(mod_ir, CELLS)
	ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 83)
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.b5"]),
		"country_names": PackedStringArray(["B5"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
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
	return {"ext": ext, "dense": dense}


func _equip(ext: Object, dense: int) -> void:
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	ext.submit_ideology_commands(_commands([
		{"op": 2, "day": 0, "handle": handle, "idea": -1, "value": 64 * Q16_ONE}]))
	ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": dense}]))
	for _i in range(3):
		_step_day(ext)
	ext.submit_ideology_commands(_commands([
		{"op": 8, "day": 0, "handle": handle, "idea": dense, "value": 0}]))
	for _i in range(3):
		_step_day(ext)
	ext.submit_ideology_commands(_commands([
		{"op": 5, "day": 0, "handle": handle, "idea": dense}]))
	for _i in range(4):
		_step_day(ext)
	# ── THE EQUIP HAS TO SETTLE BEFORE THE LAYER IS READ ───────────────────
	# `NativeIdeologyRuntime::collect_effect_activations` implements plan §10.1
	# ("pending -- use the old basis: an equip that is not yet ACKed contributes
	# NOTHING"): while the equip transition's Effect transactions are un-ACKed the
	# card contributes nothing, so the front reads
	# `installed=false, layer_generation=0`. Every assertion below is about the
	# INSTALLED front, so the production settle handshake runs first.
	#
	# The handshake alone is NOT enough since plan §9.3 landed: the projection
	# confirmed on day D is `eligible_from_day = D+1`, so `_settle_transitions` also
	# consumes day D+1 (the first day the rebuild may adopt) before returning.
	_settle_transitions(ext, "equip")
	ext.drain_derived_cell_layer(_day)


## One ideology day, driven to completion, on a STRICTLY MONOTONIC day index.
## Returns the day it consumed.
func _step_day(ext: Object) -> int:
	_day += 1
	_advance(ext, _day, 1)
	return _day


## Drains every in-flight ideology transition. The order is the production one
## (`world_ext_bind_methods.cpp:635-648`) and it is MANDATORY before any derived-layer
## read:
##
##   dispatch_effect_native_modifier()  ->  run_modifier_daily(day)
##                                      ->  ack_effect_native_modifier()
##                                      ->  run_ideology_daily(day)   # polls
##
## `run_modifier_daily` between dispatch and ACK is what applies the dispatched rows;
## without it the ACK never lands and `pending_transitions` never reaches 0. The
## adapters are served for the day the POLL will run on: the poll is the FIRST stage of
## `run_daily_slices` (`ideology_runtime.cpp:4953-4968`), so the ACK has to be in place
## before that day is entered, and every ideology day stays strictly monotonic.
func _settle_transitions(ext: Object, label: String) -> void:
	var start := int(ext.get_ideology_report().get("pending_transitions", -1))
	var rounds := 0
	for _round in range(SETTLE_ROUNDS):
		if int(ext.get_ideology_report().get("pending_transitions", 0)) == 0:
			break
		rounds += 1
		var poll_day := _day + 1
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(poll_day)
		ext.ack_effect_native_modifier()
		_step_day(ext)
	var end := int(ext.get_ideology_report().get("pending_transitions", -1))
	print("[B5] settle %s: pending %d -> %d in %d handshake round(s), last day=%d"
		% [label, start, end, rounds, _day])
	_expect("settle %s: every transition is ACKed before the layer is read" % label,
		end == 0, "pending=%d" % end)
	# ── plan §9.3: a confirmation is eligible TOMORROW, not today ──────────
	#
	# Plan §9.3: the confirmed projection's `eligible_from_day` is D+1, and at the new
	# economy freeze boundary `sample_day = S` ONLY the newest confirmed projection
	# satisfying `eligible_from_day <= S` may be chosen. `poll_pending_transition`'s
	# success path records `confirmed_day = D` / `eligible_from_day = D + 1`, and
	# `step_derived_rebuild` RETURNS EARLY without adopting on any day below that
	# (`ideology_runtime.cpp:7045-7048`, counted in
	# `derived_rebuild_gated_by_eligibility`).
	#
	# So on the settle day itself the front still serves the PREVIOUS basis -- here
	# nothing was ever installed, so it reads `installed=false, layer_generation=0`.
	# The gate is ASSERted rather than assumed: otherwise "the layer is not installed"
	# would be indistinguishable from a fixture that simply read too early for some
	# unrelated reason.
	if rounds > 0:
		var basis: Dictionary = ext.get_ideology_report()
		var confirmed := int(basis.get("derived_basis_confirmed_day", -1))
		var eligible := int(basis.get("derived_basis_eligible_day", -1))
		var gated := int(basis.get("derived_rebuild_gated_by_eligibility", 0))
		print("[B5] settle %s: basis confirmed_day=%d eligible_day=%d gated=%d"
			% [label, confirmed, eligible, gated])
		_expect("settle %s: the confirmed basis is eligible from the NEXT day" % label,
			eligible == confirmed + 1,
			"confirmed=%d eligible=%d" % [confirmed, eligible])
		_expect("settle %s: the rebuild really WAS gated by eligibility on day D" % label,
			gated > 0, "gated=%d" % gated)
		# Consume the first ELIGIBLE day (D+1) here, so that every caller reads an
		# adopted front instead of the pre-settle one. `_step_day` keeps the day index
		# strictly monotonic; the drain finishes the sharded rebuild if the day's
		# slices stopped short of a full install.
		_step_day(ext)
		ext.drain_derived_cell_layer(_day)


func _advance(ext: Object, day: int, days: int) -> void:
	for d in range(day, day + days):
		for _slice in range(128):
			var r: Dictionary = ext.run_ideology_daily(d)
			if bool(r.get("done", true)) or not bool(r.get("ok", true)):
				break


func _install_satisfiable_tag(domain: Resource, tag_name: String) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population", "op": 0,
		"threshold_q16": 20 * Q16_ONE, "clause": 0,
	}]
	var tag := {"name": tag_name, "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == tag_name:
			tags[i] = tag
			domain.target_tags = tags
			return
	tags.append(tag)
	domain.target_tags = tags


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
	print("=== B5 idle: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
