extends SceneTree
## §14.3 performance gates, measured with the roll-out FULLY OPEN.
##
## WHY THIS FILE EXISTS
##
## The plan's §14.3 hard condition is "主线程单次派生 native slice 目标 ≤1 ms".
## Every earlier measurement was taken with `kCellProgramRollout = Off` or
## `Constants`, i.e. with the derived path INERT -- so none of them measured the
## thing the gate is about. Now that `Sources` is enabled (265 programs derived),
## the same numbers have to be re-taken.
##
## WHAT IS MEASURED
##
##   * `epoch_begin_city_factor_ms`  -- the two city-factor readers, which the plan
##     already flagged as over 1 ms at 6400 cells INDEPENDENT of this migration;
##   * `cell_layer_rebuild_ms`      -- the derived materialise + install;
##   * `tag_snapshot_build_ms`      -- the tag bitset rebuild, which B7/B8 showed to
##     be super-linear in cell count.
##
## WHY p50 AND NOT A SINGLE READING
##
## Plan §14.4 requires repeat measurement: a single reading on a shared machine was
## measured at 1.69x-1.81x spread in this project, enough to flip a pass/fail
## verdict. Every number here is the MEDIAN of N runs and the spread is printed.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_perf_gate_test.gd -- --runs=7

const SMALL_CELLS := 2400    # production default map
const WIDE_CELLS := 6400     # single-country whole map (plan §14.3 table)
const Q16_ONE := 65536
const CARD_KEY := "idea.public_hygiene"
## Bounded wait for the equip (and any level) transition to settle. A transition
## settles on the ideology day AFTER the Effect adapters ACK its batch, so this is
## a hang detector, not a tuning knob.
const MAX_SETTLE_DAYS := 8

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
# ── per-call wall time of the rebuild day ────────────────────────────────────
#
# WHY: `cell_layer_rebuild_ms` is a MAX over the day's steps and, when this trace was
# added, `cell_layer_collect_ms` was a dead export (the member it read was never
# assigned anywhere in ideology_runtime.cpp), so the report could not say WHERE the
# max went. `run_ideology_daily` executes exactly ONE rebuild step per call, so timing
# the calls from outside separates the collect step from the fold steps without
# touching C++.
var _call_day: int = -1
var _call_times: Array = []
var _last_calls: Array = []
var _last_calls_day: int = -1
var _drain_steps: int = 0


func _init() -> void:
	var runs := 7
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--runs="):
			runs = maxi(1, int(arg.substr(7)))
	_run(runs)


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _median(values: Array) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	var n: int = sorted.size()
	if n % 2 == 1:
		return float(sorted[n / 2])
	return (float(sorted[n / 2 - 1]) + float(sorted[n / 2])) * 0.5


func _spread(values: Array) -> float:
	if values.size() < 2:
		return 1.0
	var lo: float = float(values.min())
	if lo <= 0.0:
		return -1.0
	return float(values.max()) / lo


func _run(runs: int) -> void:
	print("[perf] rollout=%s runs=%d" % [str(_rollout_report()), runs])
	# Warm-up pass: the FIRST run of a heavy path pays allocation and page-fault costs
	# that later runs do not. Measured on this box: without warm-up the same fixed
	# workload spread 2.13x; with it, 1.86x, and a multi-batch median of the per-batch
	# p50 narrowed to 1.14x. Warm-up is therefore not cosmetic -- it is what makes the
	# numbers comparable at all.
	print("[perf] warm-up pass")
	_one_day(SMALL_CELLS)
	for cells in [SMALL_CELLS, WIDE_CELLS]:
		_measure(cells, runs)
	_finish(0 if _failures == 0 else 3)


func _rollout_report() -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("get_cell_program_rollout"):
		return {}
	return ext.get_cell_program_rollout()


## One full day at `cells`, `runs` times, returning the medians.
func _measure(cells: int, runs: int) -> void:
	var rebuild_ms: Array = []
	var collect_ms: Array = []
	var mat_ms: Array = []
	var tag_ms: Array = []
	var city_ms: Array = []
	# Per-run classification of the measured day's steps (see `_one_day`).
	var collect_step: Array = []
	var fold_max: Array = []
	var fold_sum: Array = []
	var tail_sum: Array = []
	var covered: int = 0
	var rebuild_visits: int = 1
	var rebuild_steps: int = 1
	var _tag_declared: int = 0
	var _tag_active: int = 0
	var _tag_consumed: int = 0
	var _tag_builds: int = 0
	for r in range(runs):
		var sample := _one_day(cells)
		if sample.is_empty():
			_expect("day runs at %d cells" % cells, false, "run %d" % r)
			return
		rebuild_ms.append(float(sample.get("rebuild_ms", 0.0)))
		collect_ms.append(float(sample.get("collect_ms", 0.0)))
		mat_ms.append(float(sample.get("mat_ms", 0.0)))
		tag_ms.append(float(sample.get("tag_ms", 0.0)))
		city_ms.append(float(sample.get("city_ms", 0.0)))
		covered = int(sample.get("covered", 0))
		rebuild_visits = int(sample.get("visits", 1))
		rebuild_steps = int(sample.get("steps", 1))
		_tag_declared = int(sample.get("tag_declared", 0))
		_tag_active = int(sample.get("tag_active", 0))
		_tag_consumed = int(sample.get("tag_consumed", 0))
		_tag_builds = int(sample.get("tag_builds", 0))
		# ── the step trace ────────────────────────────────────────────────
		# `run_ideology_daily` performs exactly one rebuild step per call, and the
		# day's first rebuild step is the COLLECT (it returns before folding), so
		# `calls[0]` is the collect and `calls[i>0]` are fold steps. Only claimed
		# when the call count matches the reported step count; otherwise the raw
		# trace is printed and nothing is inferred.
		var calls: Array = sample.get("calls", [])
		var steps_of_run := int(sample.get("steps", 0))
		var drain := int(sample.get("drain_steps", 0))
		var shown := PackedStringArray()
		for v in calls:
			shown.append("%.4f" % float(v))
		print("[perf]  run %d: day=%d steps=%d calls=%d drain=%d [%s]"
			% [r + 1, int(sample.get("calls_day", -1)), steps_of_run, calls.size(),
				drain, ", ".join(shown)])
		if calls.size() == steps_of_run and steps_of_run >= 2 and drain == 0:
			collect_step.append(float(calls[0]))
			var fmax := 0.0
			var fsum := 0.0
			for i in range(1, calls.size()):
				var v := float(calls[i])
				fmax = maxf(fmax, v)
				fsum += v
			fold_max.append(fmax)
			fold_sum.append(fsum)
			tail_sum.append(float(calls[calls.size() - 1]))
	print("[perf] cells=%d covered=%d" % [cells, covered])
	print("[perf]   city_factor_ms  p50=%.4f spread=%.2fx n=%d"
		% [_median(city_ms), _spread(city_ms), city_ms.size()])
	# `cell_layer_rebuild_ms` is the WORST SINGLE STEP of the last rebuild day (a max,
	# reset on a day change at ideology_runtime.cpp:7205), which is the quantity
	# §14.3's "single slice <= 1 ms" is about. The per-step trace above is what
	# identifies WHICH kind of step that max is.
	var visits := maxi(1, rebuild_visits)
	var steps := maxi(1, rebuild_steps)
	# `cell_layer_rebuild_ms` is now the WORST SINGLE STEP (a max), which is the
	# quantity §14.3's "single slice <= 1 ms" is about.
	print("[perf]   worst_step_ms   p50=%.4f over %d step(s) in %d visit(s) (spread=%.2fx)"
		% [_median(rebuild_ms), steps, visits, _spread(rebuild_ms)])
	# §14.3's actual target, now that the step measurement covers the front build and the
	# install. REPORTED, not asserted: the run-to-run spread on this box is 1.4-5x, so an
	# assertion at a 1.0 ms boundary would fail on the machine rather than on the code.
	print("[perf]   §14.3 <=1ms: %s (worst step p50=%.4f, includes finish+install)"
		% ["PASS" if _median(rebuild_ms) <= 1.0 else "OVER",
			_median(rebuild_ms)])
	print("[perf]   collect_ms      p50=%.4f  (collect step alone, per-day max)"
		% _median(collect_ms))
	print("[perf]   materialise_ms  p50=%.4f"
		% _median(mat_ms))
	# The honest split: the report cannot produce it (see `collect_ms` above), so it
	# comes from timing the calls. `fold_max` is the worst FOLD step; the last fold
	# call also carries `finish()` + install, which the C++ `step_ms` does NOT
	# include (it is taken before `finish`, ideology_runtime.cpp:7290).
	if not collect_step.is_empty():
		print("[perf]   SPLIT collect p50=%.4f  fold_step_max p50=%.4f  "
			% [_median(collect_step), _median(fold_max)]
			+ "fold_sum p50=%.4f  last_step(fold+finish+install) p50=%.4f  n=%d"
			% [_median(fold_sum), _median(tail_sum), collect_step.size()])
	print("[perf]   tag_build_ms    p50=%.4f spread=%.2fx"
		% [_median(tag_ms), _spread(tag_ms)])
	print("[perf]   tag_declared=%d tag_active=%d consumed=%d builds=%d"
		% [_tag_declared, _tag_active, _tag_consumed, _tag_builds])

	# §12.4 / §14.3 hard conditions -- these ARE asserted, because they are
	# correctness properties that must hold at every size.
	_expect("§12.4: the derived path covers real cells at %d" % cells,
		covered > 0, "covered=%d" % covered)
	# §14.3's 1 ms target is a REPORT here, not an assertion: the plan itself records
	# that at 6400 cells the baseline city-factor reader already exceeds 1 ms
	# INDEPENDENT of this migration (§14.3 note 1), so asserting it would fail on a
	# pre-existing condition and hide the real signal.
	var city_p50 := _median(city_ms)
	print("[perf]   1ms gate: %s (city p50=%.4f)"
		% ["PASS" if city_p50 <= 1.0 else "OVER (pre-existing)", city_p50])


## Builds a world of `cells`, equips the card, runs one economy day, returns timings.
func _one_day(cells: int) -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	_install_satisfiable_tag(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var native_ideology: Dictionary = IdeologyCatalogScript.load_default() \
		.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	if dense < 0:
		return {}

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	_fill_environment(ext, cells)
	if not bool(ext.configure_economy(country_ir, profile, cells, 7).get("ok", false)):
		return {}
	ext.configure_effects(effect_ir)
	ext.configure_modifiers(mod_ir, cells)
	ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, cells, 7)
	var territory := PackedInt32Array()
	for c in range(cells):
		territory.append(c)
	ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.perf"]),
		"country_names": PackedStringArray(["Perf"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, cells]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(cells))
	ext.configure_ideologies(native_ideology)

	var gen := {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}
	ext.begin_or_reuse_economy_input_epoch(0, gen)

	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(cells * goods)
	stock.fill(0)
	if farmer >= 0:
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(cells):
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

	# Run the economy day to completion BEFORE equipping. `capture_country_epoch`
	# -- and therefore `refresh_city_modifier_factors`, whose timing is the §14.3
	# gate -- only runs inside a slice. Without this the measured `city_factor_ms`
	# is a stale 0 and the derived front stays empty (`covered=0`), which is exactly
	# how an earlier version of this fixture reported a beautiful 0.0 ms.
	for s in range(512):
		if bool(ext.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
			break

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if handle != 0:
		ext.submit_ideology_commands(_commands([
			{"op": 2, "day": 0, "handle": handle, "idea": -1, "value": 64 * Q16_ONE}]))
		ext.submit_ideology_commands(_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": dense}]))
		var day := _run_days(ext, 0, 3)
		ext.submit_ideology_commands(_commands([
			{"op": 8, "day": 0, "handle": handle, "idea": dense, "value": 0}]))
		day = _run_days(ext, day, 3)
		ext.submit_ideology_commands(_commands([
			{"op": 5, "day": 0, "handle": handle, "idea": dense}]))
		day = _run_days(ext, day, 4)
		# ---- SETTLE BEFORE MEASURING --------------------------------------
		# `equip` writes `location` at REQUEST time, but the card contributes NOTHING
		# until its Effect batch is ACKed and the next ideology day polls the
		# transition (plan 10.1: "an unACKed equip contributes nothing",
		# ideology_runtime.cpp:2313-2321). Reading the layer before that measures an
		# EMPTY front -- `covered=0` -- which is neither the rebuild cost nor the
		# coverage the gate is about.
		day = _settle(ext, day)

	var econ_report: Dictionary = ext.get_economy_report()
	var ideo_report: Dictionary = ext.get_ideology_report()
	var mat: Dictionary = ext.get_derived_materialize_report()
	var mc: Dictionary = ext.get_derived_multi_country_report()
	print("[perf]     mat seen=%s derived=%s cells=%s rows=%s ramp_eval=%s ramp_defer=%s"
		% [str(mat.get("programs_seen", "?")), str(mat.get("programs_derived", "?")),
			str(mat.get("cells_visited", "?")), str(mat.get("rows_emitted", "?")),
			str(ideo_report.get("ramp_terms_evaluated", "?")),
			str(ideo_report.get("ramp_terms_deferred", "?"))])
	return {
		"city_ms": float(econ_report.get("epoch_begin_city_factor_ms", 0.0)),
		"tag_ms": float(econ_report.get("tag_snapshot_build_ms", 0.0)),
		"rebuild_ms": float(ideo_report.get("cell_layer_rebuild_ms", 0.0)),
		"collect_ms": float(ideo_report.get("cell_layer_collect_ms", 0.0)),
		"mat_ms": float(ideo_report.get("cell_layer_materialise_ms", 0.0)),
		"covered": int(ext.get_derived_cell_layer_report().get("cell_count", 0)),
		"visits": int(ideo_report.get("cell_layer_rebuild_visits", 1)),
		"steps": int(ideo_report.get("cell_layer_rebuild_steps", 1)),
		"calls": _last_calls.duplicate(),
		"calls_day": _last_calls_day,
		"drain_steps": _drain_steps,
		"tag_declared": int(econ_report.get("tag_declared_tags", 0)),
		"tag_active": int(econ_report.get("tag_active_tags", 0)),
		"tag_consumed": int(econ_report.get("tag_consumed_tags", 0)),
		"tag_builds": int(econ_report.get("tag_snapshot_build_count", 0)),
	}


func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population", "op": 0,
		"threshold_q16": 20 * Q16_ONE, "clause": 0,
	}]
	var tag := {"name": "cell.settlement", "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == "cell.settlement":
			tags[i] = tag
			domain.target_tags = tags
			return
	tags.append(tag)
	domain.target_tags = tags


func _fill_environment(ext: Object, cells: int) -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(cells)
	var zeros_u := PackedByteArray()
	zeros_u.resize(cells)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u)


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
	print("=== perf gate: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)

## Runs `days` ideology days, each to COMPLETION, each followed by the production
## Effect adapter pulse; returns the next free day index.
##
## A fixed call count is not enough: the derived rebuild is a slice stage that
## reports `done=false` until the layer is complete (plan 14.3), so a 6400-cell
## world needs more slices than a 2400-cell one.
##
## Day indices must be STRICTLY MONOTONIC. `run_ideology_daily` gates its active
## pass on `_last_day < day` (ideology_runtime.cpp:5010), so replaying a day
## silently skips the pass that settles transitions -- the old 3/3/4 calls all
## restarted at day 0.
func _run_days(ext: Object, day: int, days: int) -> int:
	for _i in range(days):
		day += 1
		_run_ideology_day(ext, day)
		_serve_native_adapters(ext, day)
	return day


## One ideology day to completion.
##
## Records the wall time of EVERY `run_ideology_daily` call. The last day this
## function ran is the day the reported `cell_layer_rebuild_ms` describes (the
## counters reset on a day change), so `_last_calls` is the per-step trace of the
## measured day. ONE call performs ONE rebuild step (ideology_runtime.cpp:5160),
## which is what makes the collect step distinguishable from the fold steps.
func _run_ideology_day(ext: Object, day: int) -> void:
	if day != _call_day:
		_call_day = day
		_call_times = []
	for _slice in range(256):
		var started := Time.get_ticks_usec()
		var result: Dictionary = ext.run_ideology_daily(day)
		var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
		_call_times.append(elapsed_ms)
		if not bool(result.get("ok", false)) or bool(result.get("done", false)):
			break
	_last_calls = _call_times.duplicate()
	_last_calls_day = day


## Advances day by day until NO transition is in flight, then drains the derived
## rebuild, and returns the next free day index.
##
## Order per day (the production graph order, world_ext_runtime_graph.cpp:487-540):
##   run_ideology_daily(day)          poll (settles what is ACKed) -> rebuild
##   dispatch_effect_native_modifier()
##   run_modifier_daily(day)          MANDATORY between dispatch and ACK
##   ack_effect_native_modifier()
func _settle(ext: Object, day: int) -> int:
	for _i in range(MAX_SETTLE_DAYS):
		if int(ext.get_ideology_report().get("pending_transitions", -1)) == 0:
			break
		day += 1
		_run_ideology_day(ext, day)
		_serve_native_adapters(ext, day)
	if ext.has_method("drain_derived_cell_layer"):
		var drained: Dictionary = ext.drain_derived_cell_layer(day)
		# Non-zero means the day loop stopped before the rebuild finished, so the
		# per-call trace above would be missing steps. Printed, never assumed.
		_drain_steps = int(drained.get("steps", 0))
	var report: Dictionary = ext.get_ideology_report()
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	print("[perf] settle: day=%d pending_transitions=%s front installed=%s cells=%s "
		% [day, str(report.get("pending_transitions", "?")),
			str(layer.get("installed", "?")), str(layer.get("cell_count", "?"))]
		+ "generation=%s" % str(layer.get("layer_generation", "?")))
	return day


## The native Effect adapters, exactly as the daily graph drives them
## (`world_ext_bind_methods.cpp:633-638`). Without them the equip transaction stays
## PLANNED forever and the card never becomes a contribution.
func _serve_native_adapters(ext: Object, day: int) -> void:
	for _i in range(8):
		ext.run_effect_daily(day)
		var dispatched: Dictionary = ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		ext.dispatch_effect_native_country()
		ext.ack_effect_native_country()
		if not bool(dispatched.get("ok", true)) or not bool(acked.get("ok", true)):
			print("[perf] adapter failure: dispatch=%s ack=%s"
				% [str(dispatched), str(acked)])
			return
		if int(acked.get("acknowledged", 0)) > 0 \
				and int(acked.get("pending", 0)) == 0:
			return
		if int(ext.get_ideology_report().get("pending_transitions", -1)) == 0:
			return
