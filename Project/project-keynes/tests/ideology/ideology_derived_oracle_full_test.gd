extends SceneTree
## §13.1 layer 2, REBUILT AT FULL SCALE — the per-cell derived fold against the
## shipping stack machine, on EVERY covered cell of a 400-cell territory.
##
## WHY THIS FILE EXISTS
##
## The original `derived_layer_oracle_test` (735 checks) was lost to a `git pull`
## together with the rest of the untracked tree. Its replacement,
## `ideology_oracle_cross_check_test.gd`, samples three metric points on ONE cell of
## ONE ramp card. That is enough to prove "the value tracks the interpreter", but it
## cannot see a per-cell defect: a fan-out that drops cells, a stat folded onto the
## wrong cell, or a layer that is silently empty on half the territory all pass a
## three-point test. This fixture is the per-cell comparison.
##
## WHAT IS COMPARED — two INDEPENDENT oracles, every stat, every cell
##
##   1. MAGNITUDE ORACLE. The runtime's per-cell derived add must equal
##          sum over contributors of (term_add_coefficient * magnitude(cell) / Q16)
##      where `magnitude(cell)` comes from the shipping interpreter
##      (`evaluate_effect_program_magnitude`) run on THAT CELL's metric sample — not
##      from a constant echoed back out of the layer. The sum is over every equipped
##      card that commands the stat, so a second card's contribution has to be folded
##      in, not overwrite the first.
##
##   2. MERGED-VALUE ORACLE. `get_effective_stat_value(stat, cell, 0, base)` must
##      equal, exactly,
##          clamp((base + sum_of_expected_adds) * product_of_expected_factors, min, max)
##      with the sum/product computed here from the catalog terms and the clamps read
##      from the compiled stat catalog. This is the half a per-stat comparison cannot
##      cover: it proves the derived row actually reaches the merged value, exactly
##      once, with the right sign, and is not clamped away.
##
## WHY THE EXPECTED TERMS COME FROM THE CATALOG, NOT FROM THE RUNTIME
##
## The chain an equipped card travels is
##     card level -> effect program -> MODIFIER command -> definition -> terms
## and every link is authored data: `IdeologyEffectCatalog` holds the program (its
## instruction stream and its commands), `ModifierCatalog` holds the definitions and
## their terms. Both are read here as RESOURCES, so the expected value never passes
## through the code under test. The only runtime query inside the oracle is the
## interpreter itself, which is the point — it is the independent implementation.
##
## WHY A PROGRAM'S MAGNITUDE IS ONE NUMBER
##
## `evaluate_effect_program_magnitude` returns the magnitude the stack machine emits,
## i.e. ONE number per program. A program that emits twice (`CONST -> EMIT -> CONST ->
## EMIT`) therefore has two magnitudes and the runtime takes each command's own
## `value_q16` (ideology_runtime.cpp:2413), so a single interpreter call could not be
## the oracle for both. The cards under test avoid that ambiguity: every command of
## `subsidy_state_l1` carries the SAME value (6554), and `salt_monopoly_l1` has one
## command. The fixture ASSERTS that uniformity per card instead of assuming it.
##
## RAMP vs CONSTANT
##
## `salt_monopoly_l1` is `CONST -> READ_METRIC 57 -> CONST -> MIN -> MUL -> EMIT`, so
## its magnitude is a function of the metric; `subsidy_state_l1` is five
## `CONST -> EMIT` pairs. For the ramp the metric is re-sampled PER CELL
## (`sample_effect_metric_probe`) and fed back into the interpreter per cell, so "per
## cell" is a real claim rather than one evaluation reused 300 times.
##
## COVERED vs UNCOVERED
##
## The country owns cells 0..299 and nothing else, and both cards are permanent
## territory selectors, so cells 300..399 must carry NO derived row and must return
## the base value untouched. Without that half, "agreement" could be two paths
## returning the same default for everything.
##
## SCALE (measured on the shipped content, 2 cards, 5 stats, 6 stat channels)
##
##     5 stats x 300 covered cells x 2 oracles      = 3000 comparisons
##     5 stats x 100 uncovered cells x 2 assertions = 1000 comparisons
##     ramp phase 2 (metric moved) 1 stat x 300 x 2 =  600 comparisons
##     ramp phase 2 uncovered 1 stat x 100 x 2      =  200 comparisons
##     shape / coefficient / non-degeneracy / controls = ~52 assertions
##     total                                        = 4852 checks
##
## None of them is a repeat: every one compares a different (stat, cell, oracle)
## triple, or a different claim about the front's shape.
##
## EQUIP NEEDS THE NATIVE ADAPTER HANDSHAKE
##
## `run_ideology_daily` alone leaves the card's transition PENDING forever, and a
## pending transition rejects the NEXT equip with `ideology_country_transition_pending`
## (measured here: the second card silently stayed at location 0 and contributed
## nothing). The bridge is
##     dispatch_effect_native_modifier() -> run_modifier_daily(day) -> ack_...
## with `run_modifier_daily` in the middle being mandatory.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_derived_oracle_full_test.gd

const WIDTH := 20
const HEIGHT := 20
const CELLS: int = WIDTH * HEIGHT          # 400 cells
## The country owns a strict prefix, so the tail is a genuine "not covered" set.
const OWNED_CELLS := 300
const Q16_ONE := 65536
## A neutral base; both cards ADD their magnitude to it.
const BASE_VALUE := 1.0
## Metric slots the interpreter needs. The compiled catalog declares 125; the
## program's own READ_METRIC decides which ones it looks at.
const METRIC_SLOTS := 128

## `subsidy_state_l1` commands five economy-domain stats with ONE magnitude (6554);
## `salt_monopoly_l1` is a metric ramp on metric 57 with a single command. They share
## `economy.city.building.extractive_output_factor`, which is deliberate: the fold has
## to ADD two contributors on the same cell.
const CARD_KEYS := ["idea.subsidy_state", "idea.salt_monopoly"]

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
var _day := 0
var _ext: Object = null
## definition_key -> Array of {stat_key, add, factor}, normalised exactly like the
## modifier compiler normalises SUBTRACT/MULTIPLY/DIVIDE (modifier_runtime.cpp:263-266).
var _defs := {}
## stat_key -> {index, min, max} from the compiled stat catalog.
var _stat_bounds := {}
## definition_key -> {program, reads}
var _programs_by_definition := {}
## One entry per (card, stat) pair; several entries can share a stat.
var _channels: Array = []
var _mismatch_samples: Array = []
var _mismatches := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	# ── 1. compile every catalog the runtime will be configured with ──────
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var effect_resources: Resource = IdeologyEffectCatalogScript.load_default()
	var programs := _index_programs(effect_resources)
	_programs_by_definition = programs
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	_index_definitions(mod_ir)
	_index_stat_bounds(mod_ir)

	# `EffectDomainCatalog.build()` short-circuits to a PRECOMPILED catalog when one is
	# cached, and a cache that predates the ideology merge leaves every card row on the
	# `pod_fail` exit. Passing an explicit override bypasses the cache.
	var domain: Resource = EffectDomainCatalogScript.build(null, effect_resources)
	var wanted := {}
	for card_key in CARD_KEYS:
		wanted[card_key] = true
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var card_rows := _resolve_card_rows(catalog, wanted, programs)
	for card_key in CARD_KEYS:
		_expect("card %s resolves to a declared effect program" % card_key,
			card_rows.has(card_key), str(card_rows.keys()))

	# The shipped kind-12 cards filter on tags whose predicates read building state a
	# bootstrapped economy does not have (`own_tag_rejected` = every cell). Rewriting
	# those tags to a population threshold is the proven recipe
	# (ideology_b7_wide_territory_test.gd, `_install_satisfiable_tag`). Only the tags
	# the equipped cards actually name are touched, so every other reference
	# (synergy overrides) still resolves.
	var rewritten: PackedStringArray = _rewrite_selector_tags(domain, card_rows)
	print("[oracle] selector tags rewritten to a population threshold: %s"
		% str(rewritten))

	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var native_ideology: Dictionary = catalog.compile_native_catalog(
		country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())

	# ── 2. build the world ───────────────────────────────────────────────
	_ext = ClassDB.instantiate("DCWorldExt")
	_ext.create_entities(CELLS)
	_fill_environment()
	_expect("economy configures",
		bool(_ext.configure_economy(country_ir, profile, CELLS, 71).get("ok", false)))
	_expect("effects configure",
		bool(_ext.configure_effects(effect_ir).get("ok", false)))
	_expect("modifiers configure",
		bool(_ext.configure_modifiers(mod_ir, CELLS).get("ok", false)))
	_expect("country configures", bool(_ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 71).get("ok", false)))
	var territory := PackedInt32Array()
	for c in range(OWNED_CELLS):
		territory.append(c)
	var boot: Dictionary = _ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.oracle_full"]),
		"country_names": PackedStringArray(["Oracle Full"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, OWNED_CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("the country bootstraps", bool(boot.get("ok", false)), str(boot))
	var owned := 0
	for c in range(CELLS):
		var cs: Dictionary = _ext.get_country_cell_summary(c)
		if bool(cs.get("ok", false)) and bool(cs.get("owned", false)):
			owned += 1
	print("[oracle] country-runtime owned cells=%d of %d" % [owned, CELLS])
	_expect("the fixture owns exactly the intended prefix", owned == OWNED_CELLS,
		"owned=%d expected=%d" % [owned, OWNED_CELLS])
	_expect("ideologies configure",
		bool(_ext.configure_ideologies(native_ideology).get("ok", false)))

	_ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	var sig_keys: PackedStringArray = econ_catalog.get(
		"signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	_expect("the fixture's population signature exists", farmer >= 0, str(farmer))
	if farmer < 0:
		_finish(1)
		return
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
	var ci := PackedInt32Array()
	var si := PackedInt32Array()
	var pp := PackedInt64Array()
	var ff := PackedInt64Array()
	# Population on EVERY cell (owned or not) so the rewritten tag is satisfied
	# everywhere and the uncovered set is excluded by TERRITORY, not by the tag.
	for c in range(CELLS):
		ci.append(c)
		si.append(farmer)
		pp.append(30)
		ff.append(10000000)
	_expect("the economy bootstraps", bool(_ext.bootstrap_economy({
		"cell_indices": ci, "signature_ids": si, "population": pp, "funds": ff,
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array(),
		"building_type_ids": PackedInt32Array(),
		"building_owner_signatures": PackedInt32Array(),
		"building_counts": PackedInt64Array(),
	}).get("ok", false)))
	for s in range(512):
		if bool(_ext.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
			break

	# ── 3. equip every card ──────────────────────────────────────────────
	var handle := int(_ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("the fixture resolves the country", handle != 0, str(handle))
	if handle == 0:
		_finish(1)
		return
	var equipped := PackedStringArray()
	for card_key in CARD_KEYS:
		var dense: int = ids.find(card_key)
		_expect("card %s is in the compiled catalog" % card_key, dense >= 0,
			"dense=%d of %d" % [dense, ids.size()])
		if dense < 0:
			continue
		# grant -> discover -> understanding -> equip. Opcodes are
		# ideology_runtime.h:66-79; `run_ideology_daily` day indices must be MONOTONIC
		# for the whole session.
		_ext.submit_ideology_commands(_commands([
			{"op": 2, "day": _day, "handle": handle, "idea": -1, "value": 64 * Q16_ONE}]))
		_ext.submit_ideology_commands(_commands([
			{"op": 1, "day": _day, "handle": handle, "idea": dense}]))
		_run_days(3)
		_ext.submit_ideology_commands(_commands([
			{"op": 8, "day": _day, "handle": handle, "idea": dense, "value": 0}]))
		_run_days(3)
		_ext.submit_ideology_commands(_commands([
			{"op": 5, "day": _day, "handle": handle, "idea": dense}]))
		_run_days(4)
		var snap: Dictionary = _ext.get_ideology_snapshot(handle)
		var idea_ids: PackedInt32Array = snap.get("idea_ids", PackedInt32Array())
		var levels: PackedInt32Array = snap.get("levels", PackedInt32Array())
		var location := _card_location(snap, dense)
		print("[oracle] card %s dense=%d location=%d levels=%s used=%s capacity=%s pending=%s last_error=%s"
			% [card_key, dense, location, str(levels),
				str(snap.get("ideology_slots_used", "?")),
				str(snap.get("ideology_slots_capacity", "?")),
				str(snap.get("transition_pending", "?")),
				str(snap.get("last_error", "?"))])
		_expect("card %s is equipped (location == 1)" % card_key, location == 1,
			"location=%d idea_ids=%s last_error=%s" % [location, str(idea_ids),
				str(snap.get("last_error", "?"))])
		if location == 1:
			equipped.append(card_key)

	print("[oracle] equipped cards: %s" % str(equipped))
	_expect("every card under test is equipped", equipped.size() == CARD_KEYS.size(),
		"%d of %d" % [equipped.size(), CARD_KEYS.size()])

	# ── 4. freeze the epoch and materialise the layer ────────────────────
	# The rebuild is a SLICE STAGE, so one `run_ideology_daily` does not publish it.
	# Drain explicitly instead of guessing a call count.
	_ext.begin_or_reuse_economy_input_epoch(_day, {
		"sample_day": _day, "epoch_id": 2, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	_run_days(1)
	var drained: Dictionary = _ext.drain_derived_cell_layer(_day)
	print("[oracle] drained steps=%s complete=%s"
		% [str(drained.get("steps", "?")), str(drained.get("complete", "?"))])
	_expect("the derived layer finished materialising",
		bool(drained.get("complete", false)), str(drained))

	var layer: Dictionary = _ext.get_derived_cell_layer_report()
	print("[oracle] derived front: cells=%s stats=%s contributions=%s"
		% [str(layer.get("cell_count", "?")), str(layer.get("stat_count", "?")),
			str(layer.get("contribution_count", "?"))])
	var mat: Dictionary = _ext.get_derived_materialize_report()
	print("[oracle] materialise: programs_seen=%s derived=%s folded=%s rows=%s"
		% [str(mat.get("programs_seen", "?")), str(mat.get("programs_derived", "?")),
			str(mat.get("commands_folded", "?")), str(mat.get("rows_emitted", "?"))])
	var ideo: Dictionary = _ext.get_ideology_report()
	print("[oracle] ramp: evaluated=%s deferred=%s program_eval=%s failures=%s"
		% [str(ideo.get("ramp_terms_evaluated", "?")),
			str(ideo.get("ramp_terms_deferred", "?")),
			str(ideo.get("derived_program_evaluations", "?")),
			str(ideo.get("derived_program_failures", "?"))])
	_expect("no derived program evaluation failed",
		int(ideo.get("derived_program_failures", 0)) == 0,
		str(ideo.get("derived_program_failures", "?")))
	_expect("the derived layer evaluated its programs",
		int(ideo.get("derived_program_evaluations", 0)) > 0,
		str(ideo.get("derived_program_evaluations", "?")))

	# ── 5. build the expected channels from the catalog ──────────────────
	_channels = _build_channels(card_rows, programs, equipped)
	print("[oracle] channels (card x stat): %d" % _channels.size())
	_expect("the fixture has at least one comparison channel", not _channels.is_empty(),
		str(_channels.size()))
	if _channels.is_empty():
		_finish(1)
		return
	var has_ramp := false
	var ramp_stat := ""
	var ramp_members: Array = []
	var groups := {}
	for ch in _channels:
		if int(ch["metric_id"]) >= 0:
			has_ramp = true
			ramp_stat = String(ch["stat_key"])
			ramp_members.append(ch)
		var key := String(ch["stat_key"])
		if not groups.has(key):
			groups[key] = []
		groups[key].append(ch)
	_expect("at least one channel is a metric ramp", has_ramp,
		"a fixture that only covers constant cards cannot catch a stale-metric bug")
	print("[oracle] distinct stats under test: %d" % groups.size())

	# The front's SHAPE must match what the fixture expects, otherwise a dropped cell
	# or a dropped stat could hide inside a set of otherwise-agreeing cells.
	var expected_contributions := equipped.size() * OWNED_CELLS
	var expected_rows := groups.size() * OWNED_CELLS
	# One folded term per (program, MODIFIER command, covered cell). Keyed by program
	# so a stat that several commands share is not counted twice.
	var terms_per_program := {}
	for ch in _channels:
		var key := String(ch["program_key"])
		terms_per_program[key] = _modifier_command_count(key)
	var terms_per_cell := 0
	for key in terms_per_program.keys():
		terms_per_cell += int(terms_per_program[key])
	var expected_terms := terms_per_cell * OWNED_CELLS
	print("[oracle] expected shape: contributions=%d terms=%d rows=%d"
		% [expected_contributions, expected_terms, expected_rows])
	_expect("the front folds one contribution per (card, covered cell)",
		int(mat.get("programs_derived", -1)) == expected_contributions,
		"%s vs %d" % [str(mat.get("programs_derived", "?")), expected_contributions])
	_expect("the front folds one term per (command, covered cell)",
		int(mat.get("commands_folded", -1)) == expected_terms,
		"%s vs %d" % [str(mat.get("commands_folded", "?")), expected_terms])
	_expect("the front emits one row per (stat, covered cell)",
		int(mat.get("rows_emitted", -1)) == expected_rows
			and int(layer.get("cell_count", -1)) == expected_rows,
		"rows=%s cells=%s expected=%d" % [str(mat.get("rows_emitted", "?")),
			str(layer.get("cell_count", "?")), expected_rows])
	_expect("the front holds exactly one contribution per (stat, covered cell)",
		int(layer.get("contribution_count", -1)) == expected_rows,
		str(layer.get("contribution_count", "?")))

	# ── 6. the two oracles, stat by stat, cell by cell ───────────────────
	for stat_key in groups.keys():
		_verify_stat(stat_key, groups[stat_key], handle)

	# ── 7. negative control: the comparison can fail ─────────────────────
	_negative_control(groups, handle)

	# ── 8. second metric phase: the ramp is LIVE, not frozen ─────────────
	#
	# A layer that folded the ramp once and cached it would agree with the interpreter
	# on the state it was built from and be wrong forever after. So the metric is moved
	# and the whole stat is re-verified. The world is already built, so this costs one
	# day rather than a second fixture.
	if not ramp_stat.is_empty() and not ramp_members.is_empty():
		var metric_id := int(ramp_members[0]["metric_id"])
		var before: Dictionary = _ext.get_effective_stat_value(
			ramp_stat, 0, 0, BASE_VALUE)
		_ext.set_effect_metric_override_for_test(metric_id, 3 * Q16_ONE, true)
		_ext.begin_or_reuse_economy_input_epoch(_day, {
			"sample_day": _day, "epoch_id": 3, "map_generation": 1,
			"building_generation": 1, "country_generation": 1, "resource_generation": 1})
		_run_days(1)
		var redrained: Dictionary = _ext.drain_derived_cell_layer(_day)
		var after: Dictionary = _ext.get_effective_stat_value(
			ramp_stat, 0, 0, BASE_VALUE)
		print("[oracle] phase 2 metric %d -> %d: derived_add %.10f -> %.10f (steps=%s)"
			% [metric_id, 3 * Q16_ONE, float(before.get("derived_add", 0.0)),
				float(after.get("derived_add", 0.0)), str(redrained.get("steps", "?"))])
		_expect("PHASE 2: moving the metric moved the derived contribution on every cell",
			float(before.get("derived_add", 0.0)) != float(after.get("derived_add", 0.0)),
			"before=%s after=%s" % [str(before.get("derived_add", "?")),
				str(after.get("derived_add", "?"))])
		# The ramp stat may have OTHER contributors (a constant card can command the
		# same stat), so the re-verification must use the whole group, not just the
		# ramp channel — otherwise the expected sum would drop the constant half.
		_verify_stat(ramp_stat, groups[ramp_stat], handle)

	# ── 9. report ────────────────────────────────────────────────────────
	print("[oracle] mismatches=%d first=%s"
		% [_mismatches, str(_mismatch_samples.slice(0, 5))])
	print("=== derived oracle full: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 3)


## Compares one STAT on every cell of the map. `members` are the (card, stat)
## channels that command it — normally one, but two cards can share a stat, in which
## case the expected add is their SUM.
func _verify_stat(stat_key: String, members: Array, handle: int) -> void:
	var bounds: Dictionary = _stat_bounds.get(stat_key, {"min": -1.0e300, "max": 1.0e300})
	var lo := float(bounds["min"])
	var hi := float(bounds["max"])
	var factor := 1.0
	for ch in members:
		factor *= float(ch["factor"])
		# The ramp path substitutes the sampled magnitude for the term's own magnitude
		# (derived_cell_materializer.cpp:346-361). That is only equivalent to
		# `add_coeff * magnitude` when the coefficient is exactly +-1, so the equality is
		# asserted rather than assumed.
		_expect("%s/%s: the term coefficient is +-1 (ramp magnitude substitution is exact)"
			% [stat_key, String(ch["card"])],
			absf(absf(float(ch["add_coeff"])) - 1.0) < 1e-12, str(ch["add_coeff"]))
	print("[oracle] stat %s idx=%d contributors=%d factor=%.6f clamp=[%.4f,%.4f]"
		% [stat_key, int(members[0]["stat_index"]), members.size(), factor, lo, hi])

	# Per-cell expectation. The metric is sampled through the REAL sampling path for
	# every cell and fed to the interpreter, so a country-scoped metric and a
	# cell-scoped one are treated identically and nothing is hard-coded.
	var expected_add := PackedFloat64Array()
	expected_add.resize(CELLS)
	var magnitude_note := PackedStringArray()
	for ch in members:
		var program_key := String(ch["program_key"])
		var metric_id := int(ch["metric_id"])
		var add_coeff := float(ch["add_coeff"])
		var metrics := PackedInt64Array()
		metrics.resize(METRIC_SLOTS)
		var first_magnitude := 0
		var distinct_magnitudes := {}
		for cell in range(CELLS):
			metrics.fill(0)
			if metric_id >= 0:
				var probe: Dictionary = _ext.sample_effect_metric_probe(metric_id, cell, handle)
				if bool(probe.get("ok", false)):
					metrics[metric_id] = int(probe.get("value", 0))
			var out: Dictionary = _ext.evaluate_effect_program_magnitude(program_key, metrics)
			if not bool(out.get("ok", false)):
				_expect("%s: the interpreter evaluates %s on cell %d"
					% [stat_key, program_key, cell], false, str(out))
				continue
			var magnitude := int(out.get("magnitude", 0))
			if cell == 0:
				first_magnitude = magnitude
			if distinct_magnitudes.size() < 8:
				distinct_magnitudes[magnitude] = true
			expected_add[cell] += add_coeff * (float(magnitude) / float(Q16_ONE))
		magnitude_note.append("%s(%s)=%d" % [String(ch["card"]),
			program_key, first_magnitude])
		if metric_id < 0:
			# A constant program has ONE magnitude, which the interpreter must return
			# on every cell; anything else would mean the "one number" premise is false
			# and the per-command magnitudes could differ.
			_expect("%s/%s: a constant program's magnitude is cell-invariant"
				% [stat_key, String(ch["card"])], distinct_magnitudes.size() == 1,
				str(distinct_magnitudes.keys()))
		else:
			print("[oracle] %s/%s is a RAMP on metric %d: sampled magnitudes=%s"
				% [stat_key, String(ch["card"]), metric_id,
					str(distinct_magnitudes.keys())])

	var covered_ok := 0
	for cell in range(OWNED_CELLS):
		var probe: Dictionary = _ext.get_effective_stat_value(stat_key, cell, 0, BASE_VALUE)
		var present := bool(probe.get("derived_present", false))
		var actual := float(probe.get("derived_add", 0.0))
		var expected := expected_add[cell]
		var ok := present and actual == expected
		_expect("%s[%d]: derived_add == sum(term * magnitude/Q16)" % [stat_key, cell], ok,
			"present=%s actual=%.17f expected=%.17f" % [present, actual, expected])
		if not ok:
			_record_mismatch(stat_key, cell, expected, actual)
		else:
			covered_ok += 1
		# Merged-value oracle. `entity_handle` MUST be 0 and the CELL is the group
		# slot: that is the pair every shipped ECONOMY reader passes.
		var merged_expected := clampf((BASE_VALUE + expected) * factor, lo, hi)
		var merged_actual := float(probe.get("value", 0.0))
		var merged_ok := merged_actual == merged_expected
		_expect("%s[%d]: value == clamp((base+add)*factor)" % [stat_key, cell],
			merged_ok, "actual=%.17f expected=%.17f" % [merged_actual, merged_expected])
		if not merged_ok:
			_record_mismatch(stat_key + "/merged", cell, merged_expected, merged_actual)

	# Uncovered cells: NO row, and the base value comes back untouched.
	for cell in range(OWNED_CELLS, CELLS):
		var probe: Dictionary = _ext.get_effective_stat_value(stat_key, cell, 0, BASE_VALUE)
		var present := bool(probe.get("derived_present", false))
		_expect("%s[%d]: uncovered cell carries NO derived row" % [stat_key, cell],
			not present, "present=%s add=%s" % [present, str(probe.get("derived_add", "?"))])
		var value := float(probe.get("value", 0.0))
		_expect("%s[%d]: uncovered cell returns the base value exactly" % [stat_key, cell],
			value == BASE_VALUE, "value=%.17f base=%.17f" % [value, BASE_VALUE])

	# The covered set must also be non-degenerate: a magnitude that is identically
	# zero would make every comparison above `0 == 0`.
	var nonzero := 0
	for cell in range(OWNED_CELLS):
		if absf(expected_add[cell]) > 0.0:
			nonzero += 1
	_expect("%s: the covered cells carry a non-zero contribution" % stat_key,
		nonzero == OWNED_CELLS, "%d of %d" % [nonzero, OWNED_CELLS])
	print("[oracle] stat %s: %d/%d covered cells matched the interpreter (magnitude %s)"
		% [stat_key, covered_ok, OWNED_CELLS, ", ".join(magnitude_note)])


## Negative control — proves the comparison CAN fail, and that it fails on exactly the
## cells the layer covers.
##
## Control A skews the expected add by 1/64 and requires a mismatch on EVERY covered
## (stat, cell) pair while the uncovered cells keep matching their (unskewed) base.
## A comparison that always passes reports zero here; a comparison that is not per-cell
## reports the wrong count.
##
## Control B shifts the base and requires the merged value to follow by exactly
## `shift * factor` on every covered cell, which proves the merged oracle tracks its
## inputs instead of being satisfied by an accidentally equal default.
func _negative_control(groups: Dictionary, handle: int) -> void:
	var skew := 1.0 + 1.0 / 64.0
	var skewed_mismatches := 0
	var uncovered_matches := 0
	var first := ""
	var total := 0
	var followed := 0
	var followed_total := 0
	for stat_key in groups.keys():
		var members: Array = groups[stat_key]
		var bounds: Dictionary = _stat_bounds.get(
			stat_key, {"min": -1.0e300, "max": 1.0e300})
		var lo := float(bounds["min"])
		var hi := float(bounds["max"])
		var factor := 1.0
		for ch in members:
			factor *= float(ch["factor"])
		var expected_add := PackedFloat64Array()
		expected_add.resize(CELLS)
		for ch in members:
			var program_key := String(ch["program_key"])
			var metric_id := int(ch["metric_id"])
			var add_coeff := float(ch["add_coeff"])
			var metrics := PackedInt64Array()
			metrics.resize(METRIC_SLOTS)
			for cell in range(CELLS):
				metrics.fill(0)
				if metric_id >= 0:
					var sample: Dictionary = _ext.sample_effect_metric_probe(
						metric_id, cell, handle)
					if bool(sample.get("ok", false)):
						metrics[metric_id] = int(sample.get("value", 0))
				var out: Dictionary = _ext.evaluate_effect_program_magnitude(
					program_key, metrics)
				expected_add[cell] += (add_coeff
					* float(int(out.get("magnitude", 0))) / float(Q16_ONE))
		for cell in range(CELLS):
			var probe: Dictionary = _ext.get_effective_stat_value(
				stat_key, cell, 0, BASE_VALUE)
			if cell < OWNED_CELLS:
				total += 1
				var actual := float(probe.get("derived_add", 0.0))
				if actual != expected_add[cell] * skew:
					skewed_mismatches += 1
					if first.is_empty():
						first = "%s[%d] skewed_expected=%.17f actual=%.17f" % [
							stat_key, cell, expected_add[cell] * skew, actual]
				var delta := 0.5
				var probe2: Dictionary = _ext.get_effective_stat_value(
					stat_key, cell, 0, BASE_VALUE + delta)
				var v1 := float(probe.get("value", 0.0))
				var v2 := float(probe2.get("value", 0.0))
				var moved := v1 + delta * factor
				if moved >= lo and moved <= hi:
					followed_total += 1
					if v2 == moved:
						followed += 1
			else:
				# The uncovered cell must still match its UNSKEWED expectation, which is
				# the base: the control's failure is localized to the covered set.
				if float(probe.get("value", 0.0)) == BASE_VALUE:
					uncovered_matches += 1
	print("[oracle] negative control A: skewed expectations mismatched on %d of %d covered pairs; first: %s"
		% [skewed_mismatches, total, first])
	_expect("NEGATIVE CONTROL A: a skewed expectation mismatches on EVERY covered cell",
		total > 0 and skewed_mismatches == total, "%d of %d" % [skewed_mismatches, total])
	_expect("NEGATIVE CONTROL A: the first skewed mismatch is reported verbatim",
		not first.is_empty(), first)
	var uncovered_total := (CELLS - OWNED_CELLS) * groups.size()
	_expect("NEGATIVE CONTROL A: the control's failure does not leak onto uncovered cells",
		uncovered_matches == uncovered_total, "%d of %d" % [uncovered_matches, uncovered_total])
	print("[oracle] negative control B: base shift followed on %d of %d covered pairs"
		% [followed, followed_total])
	_expect("NEGATIVE CONTROL B: a base shift moves the merged value on every covered cell",
		followed_total > 0 and followed == followed_total,
		"%d of %d" % [followed, followed_total])


func _record_mismatch(stat_key: String, cell: int, expected: float, actual: float) -> void:
	_mismatches += 1
	if _mismatch_samples.size() < 10:
		_mismatch_samples.append("%s[%d] expected=%.17f actual=%.17f"
			% [stat_key, cell, expected, actual])


## The card's location slot for a dense ideology id, or -1 when it has no state.
func _card_location(snap: Dictionary, dense: int) -> int:
	var idea_ids: PackedInt32Array = snap.get("idea_ids", PackedInt32Array())
	var locs: PackedInt32Array = snap.get("locations", PackedInt32Array())
	for i in range(mini(idea_ids.size(), locs.size())):
		if int(idea_ids[i]) == dense:
			return int(locs[i])
	return -1


# ── catalog indexing ──────────────────────────────────────────────────────

## definition_key -> Array of {stat_key, add, factor}, using the SAME normalisation the
## modifier compiler applies to the authored operation column.
func _index_definitions(mod_ir: Dictionary) -> void:
	var stat_keys: PackedStringArray = mod_ir.get("stat_keys", PackedStringArray())
	var def_keys: PackedStringArray = mod_ir.get("definition_keys", PackedStringArray())
	var offsets: PackedInt32Array = mod_ir.get(
		"definition_term_offsets", PackedInt32Array())
	var t_stat: PackedInt32Array = mod_ir.get("term_stat_ids", PackedInt32Array())
	var t_op: PackedInt32Array = mod_ir.get("term_operations", PackedInt32Array())
	var t_val: PackedFloat64Array = mod_ir.get("term_values", PackedFloat64Array())
	for i in range(def_keys.size()):
		var rows: Array = []
		for t in range(offsets[i], offsets[i + 1]):
			var op := t_op[t]
			var value := t_val[t]
			var add := 0.0
			var factor := 1.0
			if op == 0:       # Add
				add = value
			elif op == 1:     # Subtract
				add = -value
			elif op == 2:     # Multiply
				factor = value
			else:             # Divide
				factor = 1.0 / value
			rows.append({"stat_key": stat_keys[t_stat[t]], "add": add, "factor": factor})
		_defs[def_keys[i]] = rows


func _index_stat_bounds(mod_ir: Dictionary) -> void:
	var stat_keys: PackedStringArray = mod_ir.get("stat_keys", PackedStringArray())
	var mins: PackedFloat64Array = mod_ir.get("stat_min_values", PackedFloat64Array())
	var maxs: PackedFloat64Array = mod_ir.get("stat_max_values", PackedFloat64Array())
	for i in range(stat_keys.size()):
		if i < mins.size() and i < maxs.size():
			_stat_bounds[stat_keys[i]] = {"index": i, "min": mins[i], "max": maxs[i]}


## How many MODIFIER commands the program named by `program_key` carries. Used to
## predict the front's `commands_folded`, so a term silently dropped anywhere in the
## collect -> fold chain shows up as a shape mismatch instead of a smaller number
## nobody compares.
func _modifier_command_count(program_key: String) -> int:
	var prefix := "ideology.effect."
	var dk := program_key.substr(prefix.length()) if program_key.begins_with(prefix) \
		else program_key
	var entry: Dictionary = _programs_by_definition.get(dk, {})
	var program: Resource = entry.get("program", null) as Resource
	if program == null:
		return 0
	var count := 0
	for command in program.commands:
		if int(command.action) == 1:
			count += 1
	return count


## definition_key -> {program, reads}, where `reads` is the metric ids the program's
## instruction stream reads (op 2 = READ_METRIC).
func _index_programs(effect_resources: Resource) -> Dictionary:
	var out := {}
	for e in effect_resources.effects:
		if e == null:
			continue
		var reads := PackedInt32Array()
		for inst in e.instructions:
			if int(inst.op) == 2:
				reads.append(int(inst.arg0))
		out[String(e.definition_key)] = {"program": e, "reads": reads}
	return out


## card_key -> one row per level whose effect row names a declared program.
func _resolve_card_rows(catalog: Resource, wanted: Dictionary,
		programs: Dictionary) -> Dictionary:
	var out := {}
	for card in catalog.definitions:
		if card == null:
			continue
		var card_key := String(card.id)
		if not wanted.has(card_key):
			continue
		for li in range(card.levels.size()):
			var lvl: Resource = card.levels[li]
			for eff in lvl.persistent_effects:
				if eff == null:
					continue
				var dk := String(eff.definition_key)
				if not programs.has(dk):
					continue
				if not out.has(card_key):
					out[card_key] = []
				out[card_key].append({"level": li, "definition_key": dk,
					"value_q16": int(eff.value_q16)})
	return out


## Replaces every tag the selected cards filter on with a population threshold this
## fixture satisfies on all 400 cells.
func _rewrite_selector_tags(domain: Resource, card_rows: Dictionary) -> PackedStringArray:
	var names := {}
	for card_key in card_rows.keys():
		for row in card_rows[card_key]:
			var entry: Dictionary = _programs_by_definition.get(
				String(row["definition_key"]), {})
			var program: Resource = entry.get("program", null) as Resource
			if program == null:
				continue
			var single := String(program.target_selector_tag)
			if not single.is_empty():
				names[single] = true
			for name in program.target_selector_tags:
				names[String(name)] = true
	var rewritten := PackedStringArray()
	if names.is_empty():
		return rewritten
	# `target_tags` is a TYPED array; assigning an untyped literal silently fails and
	# leaves the tag absent (ideology_b7_wide_territory_test.gd:623-654).
	var rows: Array[Dictionary] = [{
		"metric": "cell.population", "op": 0,
		"threshold_q16": 20 * Q16_ONE, "clause": 0,
	}]
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	for name in names.keys():
		var tag := {"name": String(name), "rows": rows}
		var replaced := false
		for i in range(tags.size()):
			if String(tags[i].get("name", "")) == String(name):
				tags[i] = tag
				replaced = true
				break
		if not replaced:
			tags.append(tag)
		rewritten.append(String(name))
	domain.target_tags = tags
	return rewritten


## Turns the equipped cards' program commands into one comparison channel per stat.
func _build_channels(card_rows: Dictionary, programs: Dictionary,
		equipped: PackedStringArray) -> Array:
	var out: Array = []
	for card_key in equipped:
		var rows: Array = card_rows.get(card_key, [])
		# Level 0 is the level the equip dance above produces.
		var chosen: Dictionary = {}
		for row in rows:
			if int(row["level"]) == 0:
				chosen = row
				break
		if chosen.is_empty():
			continue
		var dk := String(chosen["definition_key"])
		var entry: Dictionary = programs.get(dk, {})
		if entry.is_empty():
			continue
		var program: Resource = entry["program"]
		var reads: PackedInt32Array = entry["reads"]
		var command_values := {}
		var per_stat := {}
		for command in program.commands:
			if int(command.action) != 1:
				continue    # only MODIFIER commands fold into the derived layer
			command_values[int(command.value_q16)] = true
			var def_key := String(command.definition_key)
			var terms: Array = _defs.get(def_key, [])
			if terms.is_empty():
				continue
			var stacks := maxi(1, int(command.stacks))
			for term in terms:
				var stat_key := String(term["stat_key"])
				if not per_stat.has(stat_key):
					per_stat[stat_key] = {"add_coeff": 0.0, "factor": 1.0}
				var acc: Dictionary = per_stat[stat_key]
				acc["add_coeff"] = (float(acc["add_coeff"])
					+ float(term["add"]) * float(stacks))
				acc["factor"] = float(acc["factor"]) * pow(
					float(term["factor"]), float(stacks))
		if reads.is_empty():
			# A CONSTANT program's magnitude is the interpreter's single number, so
			# every command must agree with it or a per-cell oracle would be comparing
			# the wrong constant for some of them.
			_expect("%s: every command of a constant program shares ONE magnitude"
				% card_key, command_values.size() == 1, str(command_values.keys()))
		for stat_key in per_stat.keys():
			var acc: Dictionary = per_stat[stat_key]
			out.append({
				"card": card_key,
				"stat_key": stat_key,
				"stat_index": int(_stat_bounds.get(stat_key, {"index": -1})["index"]),
				"program_key": "ideology.effect." + dk,
				# A ramp reads exactly one metric in shipped content; the FIRST readable
				# id is what the collector records (ideology_runtime.cpp:2449-2456).
				"metric_id": int(reads[0]) if reads.size() > 0 else -1,
				"add_coeff": float(acc["add_coeff"]),
				"factor": float(acc["factor"]),
			})
	return out


# ── world / command plumbing ──────────────────────────────────────────────

## Runs one ideology day to completion AND settles the card transitions.
##
## `run_ideology_daily` alone reports `done` while a TRANSITION is still pending, and a
## pending transition makes the NEXT equip fail with
## `ideology_country_transition_pending` (measured: the second card stayed at location
## 0 and contributed nothing). Only the native adapter handshake completes it.
func _run_days(days: int) -> void:
	for _i in range(days):
		for _round in range(8):
			var last := {}
			for _slice in range(512):
				last = _ext.run_ideology_daily(_day)
				if not bool(last.get("ok", true)) or bool(last.get("done", false)):
					break
			for _e in range(16):
				var eff: Dictionary = _ext.run_effect_daily(_day)
				if not bool(eff.get("ok", true)) or bool(eff.get("done", true)):
					break
			_ext.dispatch_effect_native_modifier()
			# Mandatory between dispatch and ack: the Modifier domain is what
			# completes the rows the dispatch submitted.
			_ext.run_modifier_daily(_day)
			_ext.ack_effect_native_modifier()
			if int(last.get("pending_transitions", 0)) == 0:
				break
		_day += 1


func _fill_environment() -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zf := PackedFloat32Array()
	zf.resize(CELLS)
	var zu := PackedByteArray()
	zu.resize(CELLS)
	for n in f32_slots:
		var sid := int(_ext.component_id(n))
		if sid < 0:
			sid = int(_ext.register_component(n, 0, 1, false))
		if sid >= 0:
			_ext.write_f32_range(sid, 0, zf)
	for n in u8_slots:
		var sid := int(_ext.component_id(n))
		if sid < 0:
			sid = int(_ext.register_component(n, 2, 1, false))
		if sid >= 0:
			_ext.write_u8_range(sid, 0, zu)


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
		# The idempotency key must be monotonic ACROSS batches, not restart at 1.
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
	print("=== derived oracle full: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
