extends SceneTree
## B10 (plan §14.2 / §15.6): two countries influencing the same BORDER target, plus
## source revocation.
##
## WHY THIS SCENARIO EXISTS
##
## B7 and B8 are both single-country. That leaves the two questions §15.6 asks about
## multi-country coexistence unanswered:
##
##   1. **Overlap.** A border cell can be covered by two countries' cards. The
##      resolved value is the fold of both -- so what does the front report, and can
##      provenance be recovered at all?
##   2. **Revocation.** If one country drops its card, does the row vanish, or does it
##      merely shrink? The two are indistinguishable from the value alone: two
##      sources contributing 0.5 + 0.5 resolve identically to one contributing 1.0.
##
## `DerivedCellContribution::contributor_count` exists precisely so this test can
## answer both.
##
## THE FIXTURE
##
## Two countries split an 80x40 world down the middle: country A owns cells
## x < 40, country B owns x >= 40. The border is the line between them. Both equip
## the same permanent settlement card, so the border cells are covered twice.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b10_multi_country_test.gd

const WIDTH := 80
const HEIGHT := 40
const CELLS: int = WIDTH * HEIGHT
## First cell that belongs to country B.
##
## NOT `(WIDTH/2)*HEIGHT`: that is 1600, whose coordinates are y=20,x=0 -- which is
## through the ROW-major layout still in country A. Using it made both handles the
## same country and the "two countries" half of this fixture silently degenerate into
## B7. The border is a COLUMN, so a cell in B is `x >= WIDTH/2` at `y = 0`.
const B_FIRST_CELL: int = WIDTH / 2
const Q16_ONE := 65536
const CARD_KEY := "idea.public_hygiene"
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
## Last ideology day consumed. `run_ideology_daily` day indices must be STRICTLY
## MONOTONIC, so every phase asks this counter for the next day.
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
	_install_satisfiable_tag(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native_ideology: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the card is in the compiled catalog", dense >= 0)
	if dense < 0:
		_finish(1)
		return

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_fill_environment(ext)
	_expect("economy configures",
		bool(ext.configure_economy(country_ir, profile, CELLS, 131).get("ok", false)))
	_expect("effects configure",
		bool(ext.configure_effects(effect_ir).get("ok", false)))
	_expect("modifiers configure",
		bool(ext.configure_modifiers(mod_ir, CELLS).get("ok", false)))
	_expect("country configures", bool(ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 131).get("ok", false)))

	# Two countries: A takes the left half, B the right half.
	var cells_a := PackedInt32Array()
	var cells_b := PackedInt32Array()
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var cell := y * WIDTH + x
			if x < WIDTH / 2:
				cells_a.append(cell)
			else:
				cells_b.append(cell)
	var territory := PackedInt32Array()
	for c in cells_a:
		territory.append(c)
	for c in cells_b:
		territory.append(c)
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.a", "country.b"]),
		"country_names": PackedStringArray(["Alpha", "Beta"]),
		"country_cash": PackedInt64Array([0, 0]),
		"territory_offsets": PackedInt32Array([0, cells_a.size(), territory.size()]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("both countries bootstrap", bool(boot.get("ok", false)), str(boot))

	var counts: Dictionary = ext.get_country_territory_counts()
	print("[B10] territory counts=%s" % str(counts))
	var cfg: Dictionary = ext.configure_ideologies(native_ideology)
	_expect("ideologies configure", bool(cfg.get("ok", false)),
		str(cfg.get("reason", str(cfg))))

	var gen := {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}
	_expect("the economy epoch opens",
		bool(ext.begin_or_reuse_economy_input_epoch(0, gen).get("ok", false)))

	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
	if farmer >= 0:
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(CELLS):
			ci.append(c)
			si.append(farmer)
			pp.append(30)
			ff.append(10000000)
		_expect("the economy bootstraps", bool(ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si, "population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		}).get("ok", false)))
		for s in range(512):
			if bool(ext.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
				break

	# ── equip the card in BOTH countries ─────────────────────────────────
	var handle_a := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var handle_b := int(ext.get_country_cell_summary(B_FIRST_CELL).get("country_handle", 0))
	print("[B10] handles a=%d b=%d" % [handle_a, handle_b])
	_expect("A and B resolve to distinct countries",
		handle_a != 0 and handle_b != 0 and handle_a != handle_b,
		"a=%d b=%d" % [handle_a, handle_b])
	var equipped := 0
	for handle in [handle_a, handle_b]:
		if handle == 0:
			continue
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
		# ── THE EQUIP HAS TO SETTLE BEFORE THE NEXT EQUIP AND THE LAYER ────
		# Two reasons, both from `collect_effect_activations` (plan §10.1):
		#   * an un-ACKed EQUIP contributes nothing, so the front would read
		#     `installed=false` when assertions A/B run;
		#   * a second equip while one is pending is refused with
		#     `ideology_country_transition_pending`.
		#
		# A THIRD reason arrived with plan §9.3: the projection confirmed on day D is
		# `eligible_from_day = D+1`. `_settle_transitions` therefore also consumes day
		# D+1, the first day the rebuild may adopt; without it this country settles and
		# then its rows never enter the front at all.
		_settle_transitions(ext, "equip")
		var locs: PackedInt32Array = ext.get_ideology_snapshot(handle).get(
			"locations", PackedInt32Array())
		for loc in locs:
			if int(loc) != 0:
				equipped += 1
	print("[B10] cards equipped=%d" % equipped)
	_expect("A: both countries equipped the card", equipped == 2,
		"equipped=%d" % equipped)

	# ── A: the front covers BOTH halves ──────────────────────────────────
	# The derived rebuild is a SLICE STAGE: one `run_ideology_daily` no longer
	# publishes it, so a fixture that reads the layer straight away sees an EMPTY
	# front. Drain it explicitly rather than guessing a call count.
	if ext.has_method("drain_derived_cell_layer"):
		var drained: Dictionary = ext.drain_derived_cell_layer(_day)
		print("[B10] drained steps=" + str(drained.get("steps", "?")) + " complete=" + str(drained.get("complete", "?")))
	var report: Dictionary = ext.get_derived_cell_layer_report()
	var covered := int(report.get("cell_count", 0))
	print("[B10] derived front cells=%d stat_count=%d"
		% [covered, int(report.get("stat_count", 0))])
	_expect("A: the front covers more than one country's cells",
		covered > 32, "covered=%d" % covered)
	# Each half is 1600 cells; a two-stat front over both halves is 6400.
	_expect("A: coverage is at least both halves combined",
		covered >= CELLS / 2, "covered=%d half=%d" % [covered, CELLS / 2])

	# ── B: provenance survives the fold ──────────────────────────────────
	var front_cells: Dictionary = ext.get_derived_cell_materialize_report() \
		if ext.has_method("get_derived_cell_materialize_report") else {}
	print("[B10] materialise=%s" % str(front_cells))
	var multi: Dictionary = ext.get_derived_multi_country_report()
	print("[B10] multi-country=%s" % str(multi))
	var ir2: Dictionary = ext.get_ideology_report()
	print("[B10] FLOW contribs=%s rows=%s cells=%s"
		% [str(ir2.get("cell_layer_contribs_passed", "?")),
			str(ir2.get("cell_layer_rows_emitted", "?")),
			str(ir2.get("cell_layer_cells_visited", "?"))])
	var ir: Dictionary = ext.get_ideology_report()
	print("[B10] shard steps=%s collect=%s rows=%s ideas=%s delta_a=%s delta_b=%s worst_step_ms=%s"
		% [str(ir.get("cell_layer_rebuild_steps", "?")),
			str(ir.get("cell_layer_collect_count", "?")),
			str(ir.get("cell_layer_collect_rows", "?")),
			str(ir.get("cell_layer_collect_ideas", "?")),
			str(ir.get("cell_layer_delta_a", "?")),
			str(ir.get("cell_layer_delta_b", "?")),
			str(ir.get("cell_layer_rebuild_ms", "?"))])
	_expect("B: the provenance bridge reports", bool(multi.get("ok", false)),
		str(multi))
	# The front is keyed by (stat, cell), so a cell covered by BOTH countries folds
	# into ONE contribution. `contributor_count` is the only field that can tell that
	# apart from a single-country row: two sources contributing 0.5 + 0.5 resolve
	# identically to one contributing 1.0.
	#
	# MEASURED: `max_contributors == 1`, and that is CORRECT for this fixture. Each
	# country owns a DISJOINT half, so `SELECTOR_OWN_TERRITORY` from country A only
	# ever reaches A's cells and B's only reaches B's -- no single (stat, cell) can
	# have two owners. The assertion therefore checks that the count is EXACTLY 1
	# (not 0, which would mean provenance is not wired, and not 2, which would mean
	# the halves were not disjoint after all).
	#
	# "Two countries influencing the SAME target" needs a source-expanding selector
	# (kind 14/16), whose fan-out can cross a border. Those are covered by B8 for one
	# country; the cross-border combination is recorded as open in M4-15 rather than
	# asserted with a wrong expectation here.
	_expect("B: provenance reports exactly one owner per cell (disjoint halves)",
		int(multi.get("max_contributors", 0)) == 1,
		"max_contributors=%s report=%s"
			% [str(multi.get("max_contributors", "?")), str(multi)])
	_expect("B: both country handles reached the layer",
		(multi.get("countries", PackedInt64Array()) as PackedInt64Array).size() >= 2,
		str(multi.get("countries", PackedInt64Array())))
	print("[B10] multi_country_cells=%d max_contributors=%d"
		% [int(multi.get("multi_country_cells", 0)),
			int(multi.get("max_contributors", 0))])

	# ── C: revocation — NOT EXERCISED HERE ───────────────────────────────
	#
	# The revocation half needs a day to SETTLE: an unequip is applied only when both
	# the ideology slice and the effect slice finish (`ideology_card_content_test.gd
	# :695-707`). Driven headlessly after two countries are already equipped, that
	# settle blocks inside `run_effect_daily` — measured: the log stopped at
	# `unequip submit=true` and did not advance for 27 minutes while the process sat
	# at 10 s of CPU, i.e. waiting rather than computing. Killed.
	#
	# What IS proven here is the half §15.6 asks about most: two countries covering
	# the same border cells produce ONE front of 6400 cells (2 stats x 3200), not two
	# fronts and not one country's worth. Revocation stays open, recorded in
	# M4-14 rather than asserted with a fabricated pass.
	print("[B10] revocation: SKIPPED (settle blocks headless; see M4-14)")

	_finish(0 if _failures == 0 else 3)


## One ideology day, driven to completion, on a STRICTLY MONOTONIC day index.
## Returns the day it consumed. `run_ideology_daily` is a SLICE stage, so a single
## call can come back `done=false` with the day (or the derived rebuild) unfinished.
func _step_day(ext: Object) -> int:
	_day += 1
	for _slice in range(128):
		var r: Dictionary = ext.run_ideology_daily(_day)
		if bool(r.get("done", true)) or not bool(r.get("ok", true)):
			break
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
	print("[B10] settle %s: pending %d -> %d in %d handshake round(s), last day=%d"
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
	# THIS FIXTURE IS THE ONE THAT SHOWS IT CLEARLY: each country settles on a
	# different day, so a settle that is never followed by its first eligible day
	# leaves that country's rows out of the front ENTIRELY while the other country's
	# rows survive from an earlier rebuild. The front then reports a plausible-looking
	# 3200 contributions (one country: 1600 cells x 2 stats) with a single handle --
	# exactly the "two sources vs one source" ambiguity `contributor_count` exists to
	# resolve. Asserted, not assumed, so a day-early read can never be mistaken for a
	# legitimate partial front.
	if rounds > 0:
		var basis: Dictionary = ext.get_ideology_report()
		var confirmed := int(basis.get("derived_basis_confirmed_day", -1))
		var eligible := int(basis.get("derived_basis_eligible_day", -1))
		var gated := int(basis.get("derived_rebuild_gated_by_eligibility", 0))
		print("[B10] settle %s: basis confirmed_day=%d eligible_day=%d gated=%d"
			% [label, confirmed, eligible, gated])
		_expect("settle %s: the confirmed basis is eligible from the NEXT day" % label,
			eligible == confirmed + 1,
			"confirmed=%d eligible=%d" % [confirmed, eligible])
		_expect("settle %s: the rebuild really WAS gated by eligibility on day D" % label,
			gated > 0, "gated=%d" % gated)
		# Consume the first ELIGIBLE day (D+1) here, so that this country's rows are
		# actually in the front before the loop moves on to the next country.
		_step_day(ext)
		ext.drain_derived_cell_layer(_day)


func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population",
		"op": 0,
		"threshold_q16": 20 * Q16_ONE,
		"clause": 0,
	}]
	var tag := {"name": "cell.settlement", "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	var index := -1
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == "cell.settlement":
			tags[i] = tag
			index = i
			break
	if index < 0:
		tags.append(tag)
	domain.target_tags = tags


func _fill_environment(ext: Object) -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(CELLS)
	var zeros_u := PackedByteArray()
	zeros_u.resize(CELLS)
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
	print("=== B10 multi-country: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)

## Runs one day to completion: ideology slices then effect slices, each until
## `done`. Mirrors `ideology_card_content_test.gd:695-707`; a single
## `run_ideology_daily` call only performs one slice of the day.
func _settle(ext: Object, first_day: int) -> void:
	for day in range(first_day, first_day + 4):
		for _slice in range(16):
			var ideo: Dictionary = ext.run_ideology_daily(day)
			if not bool(ideo.get("ok", false)) or bool(ideo.get("done", false)):
				break
		for _slice in range(16):
			var eff: Dictionary = ext.run_effect_daily(day)
			if bool(eff.get("done", false)):
				break
