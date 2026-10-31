extends SceneTree
## §13.1 layer 2 — the derived fold and the shipping stack machine must agree.
##
## WHY THIS TEST EXISTS
##
## The original oracle (`derived_layer_oracle_test`, 735 checks) was lost to a `git pull`
## along with the other untracked files, and §18.2's first item went from "pass" back to
## "no evidence". This is the rebuilt core of it.
##
## WHAT IS COMPARED
##
## Two independent implementations of "what does this card add":
##
##   * the STACK MACHINE — `run_program_machine`, the interpreter every cell card was
##     originally specified in, reached through `evaluate_effect_program_magnitude`;
##   * the DERIVED FOLD — what `DerivedCellMaterializeJob` produced, read back per cell
##     through `get_effective_stat_value().derived_add`.
##
## WHY THE COMPARISON IS A RATIO
##
## The derived contribution carries a scale the fold applies (`ramp_scale`, from
## `term.value * stacks / Q16`) that the interpreter's magnitude does not. Rather than
## reconstruct that scale — which would mean re-deriving the very code under test — two
## different metric values are used and the RATIOS compared:
##
##     derived(M1) / derived(M2)  ==  interp(M1) / interp(M2)
##
## Any disagreement in the FUNCTION both sides evaluate shows up here, and the unknown
## constant cancels. This is scale-free, so it cannot pass by accident on a scale bug.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_oracle_cross_check_test.gd

const WIDTH := 20
const HEIGHT := 20
const CELLS: int = WIDTH * HEIGHT
const Q16_ONE := 65536
## `salt_monopoly_l1` is one of the 24 kind-12 cards whose magnitude is a live metric
## ramp; its instruction stream reads metric 57 (`op = 2, arg0 = 57`).
const RAMP_METRIC := 57
const PROGRAM_KEY := "ideology.effect.salt_monopoly_l1"
const CARD_KEY := "idea.salt_monopoly"
## The program is `min(metric, 15) * 655 / Q16`. Two values BELOW that clamp keep the
## comparison discriminating (a saturated pair would agree trivially), and one ABOVE it
## checks that the clamp itself is reproduced.
const M_LOW := 5 * Q16_ONE
const M_MID := 10 * Q16_ONE
const M_HIGH := 120 * Q16_ONE
## Well past the clamp, to prove saturation rather than mere growth.
const M_HUGE := 500 * Q16_ONE
const PROBE_CELL := 0
## The stat `salt_monopoly` commands (it is `economy.city.*` because gdext reads cell
## output through its own economy stat ids).
## Read off the card's own command (`definition_key`) rather than guessed: an earlier
## version used `economy.city.output_factor` and measured `derived_add = 0` because the
## 400 rows the front carried were for a different stat.
const STAT_KEY := "economy.city.building.extractive_output_factor"
## Defensive ceiling for the transition settle handshake.
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
## Last ideology day consumed. `run_ideology_daily` day indices must be STRICTLY
## MONOTONIC, so every measurement asks this counter for the next day.
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
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	# The shipped card filters on `cell.sector.extractive`, which no bootstrapped cell
	# satisfies; swap in a population threshold so the target set is non-empty.
	_install_satisfiable_tag(domain, "cell.sector.extractive")
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var native_ideology: Dictionary = IdeologyCatalogScript.load_default() \
		.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the ramp card is in the compiled catalog", dense >= 0,
		"dense=%d of %d" % [dense, ids.size()])
	if dense < 0:
		_finish(1)
		return

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_fill_environment(ext)
	if not bool(ext.configure_economy(country_ir, profile, CELLS, 71).get("ok", false)):
		_expect("economy configures", false)
		_finish(1)
		return
	ext.configure_effects(effect_ir)
	ext.configure_modifiers(mod_ir, CELLS)
	ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 71)
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.oracle"]),
		"country_names": PackedStringArray(["Oracle"]),
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
	ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
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
	# `collect_effect_activations` implements plan §10.1 ("an equip that is not yet
	# ACKed contributes nothing"): while the equip transition's Effect transactions
	# are un-ACKed the card contributes nothing, so EVERY measurement below would
	# read `derived_present=false` and the whole cross-check would compare 0 against
	# the interpreter. The production settle handshake runs first.
	_settle_transitions(ext, "equip")
	var locs: PackedInt32Array = ext.get_ideology_snapshot(handle).get(
		"locations", PackedInt32Array())
	var active := 0
	for loc in locs:
		if int(loc) != 0:
			active += 1
	_expect("the ramp card is equipped", active == 1, str(locs))

	# The card commands an ADD term, so the derived contribution IS the program's
	# magnitude expressed as a ratio: `derived_add == interp_magnitude / Q16`.
	# That makes this an ABSOLUTE comparison, not just a ratio -- stronger, and it fails
	# on a wrong scale as well as a wrong function.
	var points := [M_LOW, M_MID, M_HIGH]
	var matched := 0
	for value in points:
		var derived := _measure(ext, value)
		var interp := _interp(ext, value)
		var expected := interp / float(Q16_ONE)
		var delta := absf(derived - expected)
		print("[oracle] metric=%.3f  derived=%.8f  interp/Q16=%.8f  delta=%.8f"
			% [float(value) / Q16_ONE, derived, expected, delta])
		# 2% of the expected value, plus an absolute floor for the near-zero case. Q16
		# quantisation happens on BOTH sides, so an exact match is not a fair demand.
		var tolerance := maxf(0.02 * absf(expected), 1e-6)
		var ok := delta <= tolerance
		_expect("derived equals interp/Q16 at metric=%.2f" % (float(value) / Q16_ONE),
			ok, "derived=%.8f expected=%.8f" % [derived, expected])
		if ok:
			matched += 1
	# And the shape: below the clamp the two points must DIFFER (proving the ramp is
	# live), above it the value must equal the mid one (proving the clamp is applied).
	var low := _measure(ext, M_LOW)
	var mid := _measure(ext, M_MID)
	var high := _measure(ext, M_HIGH)
	print("[oracle] shape: low=%.8f mid=%.8f high=%.8f" % [low, mid, high])
	_expect("below the clamp a bigger metric gives a bigger contribution", mid > low,
		"low=%.8f mid=%.8f" % [low, mid])
	# Saturation must be compared against ANOTHER value above the clamp, not against
	# `mid`: `mid` is deliberately below the clamp, so of course it differs. (The first
	# version of this assertion compared mid/high and failed for exactly that reason --
	# the code was right and the assertion was wrong.)
	var huge := _measure(ext, M_HUGE)
	print("[oracle] clamp: high=%.8f huge=%.8f" % [high, huge])
	_expect("above the clamp the contribution saturates (high == huge)",
		absf(high - huge) <= maxf(0.02 * absf(high), 1e-6),
		"high=%.8f huge=%.8f" % [high, huge])
	# And the saturated value must equal `min(clamp, metric) * 655 / Q16` for the
	# program's own clamp of 15.
	var expected_clamp := 15.0 * 655.0 / float(Q16_ONE)
	_expect("the saturated value is the program's own clamp",
		absf(high - expected_clamp) <= maxf(0.02 * expected_clamp, 1e-6),
		"high=%.8f expected=%.8f" % [high, expected_clamp])
	_expect("every measured point matched the interpreter", matched == points.size(),
		"%d of %d" % [matched, points.size()])

	# The program path must actually have run: a silent fallback would still "match" if
	# both sides were wrong the same way.
	var report: Dictionary = ext.get_ideology_report()
	print("[oracle] program_evaluations=%s failures=%s"
		% [str(report.get("derived_program_evaluations", "?")),
			str(report.get("derived_program_failures", "?"))])
	_expect("the materializer ran the PROGRAM, not the metric fallback",
		int(report.get("derived_program_evaluations", 0)) > 0,
		str(report.get("derived_program_evaluations", "?")))
	_expect("no program evaluation failed",
		int(report.get("derived_program_failures", 0)) == 0,
		str(report.get("derived_program_failures", "?")))

	# ── B9: 200+ cells, per-cell ramp -- thresholds hold, values move ──────
	#
	# The points above prove ONE cell agrees with the interpreter. B9 asks a different
	# question: across the whole 400-cell territory, does every cell carry the same
	# contribution at a given metric, and does the set of contributing cells stay stable
	# while the VALUE moves?
	#
	# Metrics are uniform per cell in this fixture by construction (a global override),
	# so "per-cell" here means "every cell evaluated independently", not "different cells
	# see different metrics". That distinction is stated rather than glossed: a genuinely
	# per-cell varying ramp needs building state this fixture does not create.
	var sweep := [
		{"metric": 0, "expect_zero": true, "label": "below the ramp"},
		{"metric": 5 * Q16_ONE, "expect_zero": false, "label": "mid ramp"},
		{"metric": 120 * Q16_ONE, "expect_zero": false, "label": "past the clamp"},
	]
	var previous_nonzero := -1
	for point in sweep:
		var metric_value := int(point["metric"])
		_measure(ext, metric_value)
		var nonzero := 0
		var distinct := {}
		for cell in range(CELLS):
			var probe: Dictionary = ext.get_effective_stat_value(STAT_KEY, cell, 0, 1.0)
			if not bool(probe.get("derived_present", false)):
				continue
			var add := float(probe.get("derived_add", 0.0))
			if absf(add) > 1e-12:
				nonzero += 1
				distinct[snappedf(add, 1e-6)] = true
		print("[B9] %s (metric=%.3f): contributing=%d/%d distinct_values=%d"
			% [String(point["label"]), float(metric_value) / Q16_ONE, nonzero, CELLS,
				distinct.size()])
		if bool(point["expect_zero"]):
			_expect("B9: below the ramp NO cell contributes", nonzero == 0, str(nonzero))
		else:
			# Every cell must contribute: the card covers the whole territory, so a
			# partial count would mean the fan-out drops cells.
			_expect("B9: at metric=%.2f EVERY cell contributes" % (float(metric_value) / Q16_ONE),
				nonzero == CELLS, "%d of %d" % [nonzero, CELLS])
			# Uniform metrics must give a uniform value; more than one distinct value
			# would mean the per-cell evaluation depends on something other than the
			# metric.
			_expect("B9: the contribution is uniform across the territory",
				distinct.size() == 1, str(distinct.keys()))
		if previous_nonzero >= 0 and not bool(point["expect_zero"]):
			_expect("B9: the contributing set did not shrink as the metric rose",
				nonzero >= previous_nonzero, "%d vs %d" % [nonzero, previous_nonzero])
		previous_nonzero = nonzero

	_finish(0 if _failures == 0 else 3)


func _expect_nonzero(a: float, b: float) -> bool:
	if absf(a) > 1e-12 and absf(b) > 1e-12:
		return true
	_expect("both measurements are non-zero", false, "a=%.10f b=%.10f" % [a, b])
	return false


## Freezes `RAMP_METRIC` at `value`, rebuilds, and returns the derived delta on PROBE_CELL.
func _measure(ext: Object, value: int) -> float:
	ext.set_effect_metric_override_for_test(RAMP_METRIC, value, true)
	# The override lands on the economy side, so the epoch has to be re-frozen and the
	# derived layer rebuilt from the new samples.
	ext.begin_or_reuse_economy_input_epoch(1, {
		"sample_day": 1, "epoch_id": 2, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	_step_day(ext)
	ext.drain_derived_cell_layer(_day)
	var probe: Dictionary = ext.get_effective_stat_value(STAT_KEY, PROBE_CELL, 0, 1.0)
	if not bool(probe.get("derived_present", false)):
		return 0.0
	return float(probe.get("derived_add", 0.0))


## One ideology day, driven to completion, on a STRICTLY MONOTONIC day index.
## Returns the day it consumed. `run_ideology_daily` is a SLICE stage, so a single
## call can come back `done=false` with the day (or the derived rebuild) unfinished.
func _step_day(ext: Object) -> int:
	_day += 1
	_advance(ext, _day, 1)
	return _day


## Drains every in-flight ideology transition. The order is the production one
## (`world_ext_bind_methods.cpp:635-648`) and it is MANDATORY before a layer read:
##
##   dispatch_effect_native_modifier()  ->  run_modifier_daily(day)
##                                      ->  ack_effect_native_modifier()
##                                      ->  run_ideology_daily(day)   # polls
##
## `run_modifier_daily` between dispatch and ACK applies the dispatched rows; without
## it the ACK never lands and `pending_transitions` never reaches 0. The adapters are
## served for the day the POLL will run on, because the poll is the FIRST stage of
## `run_daily_slices` (`ideology_runtime.cpp:4953-4968`) -- that keeps every ideology
## day strictly monotonic AND in the right order for the ACK to be seen.
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
	print("[oracle] settle %s: pending %d -> %d in %d handshake round(s), last day=%d"
		% [label, start, end, rounds, _day])
	_expect("settle %s: every transition is ACKed before the layer is read" % label,
		end == 0, "pending=%d" % end)


## The interpreter's magnitude (Q16) for the same frozen metric value.
func _interp(ext: Object, value: int) -> float:
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	metrics[RAMP_METRIC] = value
	var out: Dictionary = ext.evaluate_effect_program_magnitude(PROGRAM_KEY, metrics)
	if not bool(out.get("ok", false)):
		printerr("[oracle] interpreter rejected the program: %s" % str(out))
		return 0.0
	return float(int(out.get("magnitude", 0)))


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
	print("=== oracle cross-check: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
