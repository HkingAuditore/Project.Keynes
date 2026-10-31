extends SceneTree
## B8 (plan §14.2 / §15.6 exit): 100+ sources, r=1..4, overlapping fan-outs, the
## count cap, and a cross-border target.
##
## WHY THIS IS THE M4 EXIT GATE
##
## §15.6 requires: "100+ 来源与 r=1–4、重叠、count cap、跨国边境、所有生产 program
## 数值通过；逐来源整图清零消失". Every earlier fixture used at most a few dozen
## sources, so none of those five properties was ever measured. B8 measures all five
## on ONE world.
##
## WHAT THE COUNT CAP ACTUALLY DOES (this is the thing to get right)
##
## `SELECTOR_TAG_SOURCE_COUNT` normalises each target to
##     scale = min(count, cap) / cap
## (`ideology_runtime.cpp:2082-2084`) where `cap` is bounded by
## `SOURCE_COUNT_CAP_MASK = 0x0F` -- FIFTEEN, not 32. So with 100+ sources every
## covered cell saturates at scale 1.0 and stops distinguishing 15 sources from 100.
## That saturation is the documented behaviour, not a bug; what WOULD be a bug is
## the scale exceeding 1.0 or the covered set stopping at 32 cells.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b8_source_overlap_test.gd

const WIDTH := 40
const HEIGHT := 40
const CELLS: int = WIDTH * HEIGHT
## §15.6 asks for 100+. 144 = 12x12 block, comfortably past the requirement and
## still one contiguous country so the border is the block's own edge.
const SOURCE_SIDE := 12
const SOURCE_COUNT: int = SOURCE_SIDE * SOURCE_SIDE
const Q16_ONE := 65536
const CARD_KEY := "idea.public_hygiene"
## `SOURCE_COUNT_CAP_MASK = 0x0F`; the schema cannot express more.
const MAX_CAP := 15
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
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")

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
	var tag_index := _install_satisfiable_tag(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot and fails silently.
	ext.create_entities(CELLS)
	_fill_environment(ext)
	_expect("economy configures",
		bool(ext.configure_economy(country_ir, profile, CELLS, 97).get("ok", false)))
	_expect("effects configure",
		bool(ext.configure_effects(effect_ir).get("ok", false)))
	_expect("modifiers configure",
		bool(ext.configure_modifiers(mod_ir, CELLS).get("ok", false)))
	_expect("country configures", bool(ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 97).get("ok", false)))

	# One country owning everything, so the source block's edge is also a border.
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.b8"]),
		"country_names": PackedStringArray(["B8 Overlap"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("the country bootstraps", bool(boot.get("ok", false)), str(boot))

	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native_ideology: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the cardinal is in the compiled catalog", dense >= 0,
		"dense=%d of %d" % [dense, ids.size()])
	if dense < 0:
		_finish(1)
		return
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
	var serf: int = sig_keys.find("serf|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
	if farmer >= 0 and serf >= 0:
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(CELLS):
			for pair in [[farmer, 20], [serf, 20]]:
				ci.append(c)
				si.append(int(pair[0]))
				pp.append(int(pair[1]))
				ff.append(10000000)
		var eb: Dictionary = ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si,
			"population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		_expect("the economy bootstraps", bool(eb.get("ok", false)), str(eb))
		for s in range(512):
			if bool(ext.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
				break

	# ── equip the cardinal ───────────────────────────────────────────────
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if handle != 0:
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
		# ── THE EQUIP HAS TO SETTLE BEFORE THE LAYER IS READ ─────────────
		# `collect_effect_activations` implements plan §10.1 ("an equip that is not
		# yet ACKed contributes nothing"): while the equip transition is un-ACKed
		# the card contributes nothing and the front reads
		# `installed=false, layer_generation=0`. Assertions A and B below are about
		# the INSTALLED front, so the production handshake runs here.
		#
		# The handshake alone stopped being enough when plan §9.3 landed: the projection
		# confirmed on day D is `eligible_from_day = D+1`, so `_settle_transitions` also
		# consumes day D+1 -- the first day the rebuild may adopt -- before returning.
		_settle_transitions(ext, "equip")
	var locs: PackedInt32Array = ext.get_ideology_snapshot(handle).get(
		"locations", PackedInt32Array())
	var active := 0
	for loc in locs:
		if int(loc) != 0:
			active += 1
	print("[B8] cardinal active=%d" % active)

	# ── A: the tag covers 100+ cells (the source pool) ────────────────────
	var plane: Dictionary = ext.get_economy_territory_plane()
	print("[B8] territory plane=%s" % str(plane))
	# The derived rebuild is a SLICE STAGE; drain it before reading the layer.
	if ext.has_method("drain_derived_cell_layer"):
		ext.drain_derived_cell_layer(_day)
	var covered := int(ext.get_derived_cell_layer_report().get("cell_count", 0))
	print("[B8] derived front cells=%d" % covered)
	_expect("A: 100+ sources exist in the tag set", SOURCE_COUNT >= 100,
		str(SOURCE_COUNT))
	_expect("A: the card covers more than 32 cells (no policy cap)",
		covered > 32, "covered=%d" % covered)

	# ── B: the count cap saturates rather than truncating the cell set ────
	# `scale = min(count, cap)/cap` with cap <= 15, so 144 sources all read 1.0.
	# The thing that must NOT happen is the covered set shrinking to `cap`.
	_expect("B: coverage exceeds the count cap (saturation, not truncation)",
		covered > MAX_CAP, "covered=%d cap=%d" % [covered, MAX_CAP])

	# ── C: r=1..4 all decode and stay in range ───────────────────────────
	for radius in range(1, 5):
		var packed := IdeologyEffectDefinitionScript.pack_source_count(32, radius, MAX_CAP,
			tag_index + 1)
		var round_trip := IdeologyEffectDefinitionScript.unpack_source_count(packed)
		_expect("C: r=%d round-trips" % radius,
			int(round_trip.get("radius", -1)) == radius, str(round_trip))
	_expect("C: r=5 is rejected (schema bound is 4)",
		(IdeologyEffectDefinitionScript.pack_source_count(32, 5, MAX_CAP,
			tag_index + 1) as PackedInt32Array).is_empty())

	# ── D: zero instances (I01) at this scale ────────────────────────────
	var instances := 0
	if ext.has_method("get_ideology_effect_instance_report"):
		instances = int(ext.get_ideology_effect_instance_report(handle).get("count", 0))
	print("[B8] effect instances=%d" % instances)
	_expect("D: 100+ sources still create ZERO instances", instances == 0,
		"instances=%d" % instances)

	# ── E: the rebuild cost at this size, and the tag snapshot cost ──────
	var report: Dictionary = ext.get_ideology_report()
	print("[B8] rebuild_ms=%.3f visits=%s ramp_taken=%s"
		% [float(report.get("cell_layer_rebuild_ms", 0.0)),
			str(report.get("cell_layer_rebuild_visits", "?")),
			str(report.get("ramp_samples_taken", "?"))])
	var econ_report: Dictionary = ext.get_economy_report()
	print("[B8] tag_build_ms=%.4f builds=%s"
		% [float(econ_report.get("tag_snapshot_build_ms", 0.0)),
			str(econ_report.get("tag_snapshot_build_count", "?"))])

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
	print("[B8] settle %s: pending %d -> %d in %d handshake round(s), last day=%d"
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
	# nothing was ever installed, so it reads `installed=false, layer_generation=0` and
	# assertions A/B below see `covered=0`. The gate is ASSERted rather than assumed, so
	# a future regression that starts publishing a day early fails HERE with a clear
	# message instead of silently changing a cell count.
	if rounds > 0:
		var basis: Dictionary = ext.get_ideology_report()
		var confirmed := int(basis.get("derived_basis_confirmed_day", -1))
		var eligible := int(basis.get("derived_basis_eligible_day", -1))
		var gated := int(basis.get("derived_rebuild_gated_by_eligibility", 0))
		print("[B8] settle %s: basis confirmed_day=%d eligible_day=%d gated=%d"
			% [label, confirmed, eligible, gated])
		_expect("settle %s: the confirmed basis is eligible from the NEXT day" % label,
			eligible == confirmed + 1,
			"confirmed=%d eligible=%d" % [confirmed, eligible])
		_expect("settle %s: the rebuild really WAS gated by eligibility on day D" % label,
			gated > 0, "gated=%d" % gated)
		# Consume the first ELIGIBLE day (D+1) here, so that every caller reads an
		# adopted front instead of the pre-settle one.
		_step_day(ext)
		ext.drain_derived_cell_layer(_day)


## Replaces `cell.settlement` with a population threshold, KEEPING every other tag.
##
## Two constraints learned the hard way:
##   * `target_tags` is `Array[Dictionary]`, a typed array -- an untyped literal
##     fails the assignment and the tag silently stays absent;
##   * the ideology catalogue declares synergy overrides that name OTHER tags, so
##     overwriting the whole list fails with `ideology_synergy_override_tag_unknown`.
## Returns the replacement's 0-based index.
func _install_satisfiable_tag(domain: Resource) -> int:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population",
		"op": 0,                                  # TARGET_TAG_GTE
		"threshold_q16": 30 * Q16_ONE,
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
		index = tags.size() - 1
	domain.target_tags = tags
	return index


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
	var count: int = rows.size()
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
	for i in range(count):
		var row: Dictionary = rows[i]
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		producers.append(1)
		# `sequences` is the idempotency key; it must be monotonic ACROSS batches.
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
	print("=== B8 source overlap: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)