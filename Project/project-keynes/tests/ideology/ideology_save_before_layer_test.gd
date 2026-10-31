extends SceneTree
## §11.7 time point 1: "no active epoch; a new game / load taken BEFORE the first
## derived cell layer is created".
##
## WHAT THE PLAN DEMANDS
##
##   §11.7 compares, at every time point, a CONTINUOUS run against the same run
##   after save -> reload, on the per-cell effective factors, the economy
##   conservation result, the one-shot execution counts and the business state.
##   A fresh-world roundtrip on its own does not pass.
##
## WHAT THIS FIXTURE DOES
##
##   One continuous timeline is built from scratch: 8x8 = 64 cells, one country
##   owning a scattered 2/3 of them, one kind-12 derived card equipped. It is
##   saved at TWO points, both of which really are "before the first layer":
##
##     SAVE-A  right after the economy's day-0 epoch is committed and before ANY
##             ideology command exists. No active epoch; the derived cell layer
##             has never been installed, so PKID carries no layer at all.
##     SAVE-B  after the equip command has been queued but before any day applied
##             it. Still no active epoch, still no installed layer -- but the save
##             now carries the country row, the points, the discovered card, its
##             understanding and the pending EQUIP command.
##
##   From each save point the SAME two days are then run twice:
##
##     * continuous -- the original runtime keeps going;
##     * reload     -- a NEW runtime is built from the same bootstrap, the PKID
##                     payload is restored into it, and it runs the same two days
##                     with the same command batches (identical idempotency keys).
##
##   The two sides are compared CELL BY CELL through `get_effective_stat_value`
##   on two stats (one positive card command and one negative ".cut" command), and
##   on the business state, the one-shot counters and the economy audit.
##
## WHY THE DERIVED LAYER *MUST* BE COMPARED HERE
##
##   PKID deliberately does NOT persist the derived cell front
##   (`ideology_runtime.cpp:6387` -- `capture()` writes country rows, ideas,
##   points, offers and pending commands, nothing else). The front is a pure
##   derivation from the restored idea rows plus the world. So this time point is
##   exactly the one where a reload has to PROVE the layer is rebuilt from
##   scratch, cell for cell, rather than silently skipped or left empty.
##
## SAVE / RESTORE API (the production pair)
##
##   `DCWorldExt.capture_ideology_state()` -> PKID stream
##   `DCWorldExt.restore_ideology_state(bytes)` -> {ok, reason}
##
##   These are the calls the shipped save coordinator uses:
##     scripts/game/game_save_coordinator.gd:967  writes section "pkid" from
##                                                `capture_ideology_state()`
##     scripts/game/game_save_coordinator.gd:1154 restores it (empty -> clear)
##   and the worker-side encoder is `native_simulation_host.cpp:15011`. A rejected
##   restore prints the runtime's own reason verbatim (`ideology_save_truncated`,
##   `ideology_save_catalog_mismatch`, `ideology_save_state_hash_mismatch`, ...),
##   so a failure is diagnosable instead of just "ok=false".
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_save_before_layer_test.gd

const WIDTH := 8
const HEIGHT := 8
## 8x8 keeps the fixture small; `c >> 3` is `c / 8` without an integer-division
## warning for the row index.
const ROW_SHIFT := 3
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261028
## A permanent cell card (kind 12 = SELECTOR_OWN_TERRITORY, lifecycle 0). Same
## card the B7 wide-territory fixture proves reaches the whole territory, so the
## derived path is the one under test rather than a country-scope instance.
const CARD_KEY := "idea.public_hygiene"
## The card's two commands. The first resolves to ADD +1.0, the second (".cut")
## to ADD -1.0 with the SAME positive program magnitude -- comparing both proves
## the sign survives the reload as well as the value.
const STAT_ADD := "economy.city.birth_factor"
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const Q16_ONE := 65536
## `LevelPublicHygieneL2.understanding_threshold_q16` in
## `data/ideologies/default_ideology_catalog.tres`. The continuation grants this
## much understanding, which is real business state even though the level change
## itself is a cross-domain transaction this fixture does not settle.
const LEVEL2_UNDERSTANDING_Q16 := 524288
## The level-1 persistent program of the card. Its magnitude is what the covered
## cells' derived add must equal (B7 asserts the same identity).
const PROGRAM_KEY := "ideology.effect.public_hygiene_l1"
## The two days both sides must agree on. §11.7 time point 1 only needs "continue
## after the load"; two days is enough for the layer to be rebuilt and installed.
const DAYS_AFTER_SAVE := 2
## Upper bound on the settle rounds of `_settle_transitions`. One round is enough
## for an equip (dispatch -> modifier day -> ACK -> poll), two when the fold needs
## a second slice; 8 leaves room without ever spinning.
const SETTLE_ROUND_LIMIT := 8

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

var _checks := 0
var _failures := 0
var _catalogs := {}


func _init() -> void:
	_run()


func _run() -> void:
	_catalogs = _compile_catalogs()
	if _catalogs.is_empty():
		_finish()
		return
	var ids: PackedStringArray = _catalogs["native_ideology"].get(
		"ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the card is in the compiled ideology catalog", dense >= 0,
		"%s -> dense=%d of %d" % [CARD_KEY, dense, ids.size()])
	if dense < 0:
		_finish()
		return
	_catalogs["dense"] = dense
	# Batches are built ONCE with fixed sequences and submitted to every branch.
	# `sequences` is the idempotency key and the high watermark is part of PKID;
	# handing identical batches to both sides is what makes the two timelines the
	# same timeline rather than two similar ones.
	var batches: Array = _equip_batches(dense)

	# ── continuous timeline ───────────────────────────────────────────────
	var continuous: Dictionary = _new_world("continuous")
	var ext: Object = continuous["ext"]
	var save_a: PackedByteArray = _capture(ext, "SAVE-A")
	_expect_pre_layer(continuous, "SAVE-A")
	_expect("SAVE-A: the world has no active economy epoch",
		not bool(continuous["epoch_active"]), str(continuous["epoch_active"]))

	var handle: int = int(continuous["handle"])
	_submit(ext, batches[0], handle)              # grant points
	_submit(ext, batches[1], handle)              # discover the card
	_run_ideology_days(ext, 0, 3)
	_submit(ext, batches[2], handle)              # understanding
	_run_ideology_days(ext, 0, 3)
	_submit(ext, batches[3], handle)              # EQUIP -- queued, not applied
	var save_b: PackedByteArray = _capture(ext, "SAVE-B")
	_expect_pre_layer(continuous, "SAVE-B")
	_expect("SAVE-B: the queued equip is still pending, so no effect ran yet",
		int(_report(ext).get("pending_commands", -1)) == 1,
		"pending=%s" % str(_report(ext).get("pending_commands", "?")))
	var reference: Dictionary = _advance_and_capture(
		continuous, "continuous", DAYS_AFTER_SAVE)

	# ── reload of SAVE-A: replay the whole equip lead, then the same two days ─
	var reload_a: Dictionary = _new_world("reload-A")
	_expect("SAVE-A: PKID restores into a freshly built runtime",
		_restore(reload_a["ext"], save_a))
	var reload_a_handle: int = int(reload_a["handle"])
	_expect("SAVE-A: the replayed world resolves the same country handle",
		reload_a_handle == handle, "%d vs %d" % [reload_a_handle, handle])
	_submit(reload_a["ext"], batches[0], reload_a_handle)
	_submit(reload_a["ext"], batches[1], reload_a_handle)
	_run_ideology_days(reload_a["ext"], 0, 3)
	_submit(reload_a["ext"], batches[2], reload_a_handle)
	_run_ideology_days(reload_a["ext"], 0, 3)
	_submit(reload_a["ext"], batches[3], reload_a_handle)
	var reload_a_final: Dictionary = _advance_and_capture(
		reload_a, "reload-A", DAYS_AFTER_SAVE)

	# ── reload of SAVE-B: the equip command comes out of the save itself ─────
	var reload_b: Dictionary = _new_world("reload-B")
	_expect("SAVE-B: PKID restores into a freshly built runtime",
		_restore(reload_b["ext"], save_b))
	var reload_b_final: Dictionary = _advance_and_capture(
		reload_b, "reload-B", DAYS_AFTER_SAVE)

	# ── §11.7 comparison ─────────────────────────────────────────────────
	_compare(reference, reload_a_final, "SAVE-A")
	_compare(reference, reload_b_final, "SAVE-B")
	_finish()


# ─────────────────────────────────────────────────────────────────────────
# catalogs
# ─────────────────────────────────────────────────────────────────────────

func _compile_catalogs() -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `EffectDomainCatalog.build()` short-circuits to a PRECOMPILED catalog when one
	# is cached; passing the ideology effects explicitly bypasses that cache so the
	# `ideology.effect.*` programs are always merged in.
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
	if country_ir.is_empty() or effect_ir.is_empty() or mod_ir.is_empty() \
			or native_ideology.is_empty():
		_expect("all four native catalogs compile", false, "one of them is empty")
		return {}
	return {
		"country_ir": country_ir, "profile": profile, "effect_ir": effect_ir,
		"mod_ir": mod_ir, "native_ideology": native_ideology,
	}


## Declares `cell.settlement` as `cell.population >= 30`, which every cell of this
## fixture satisfies (two cohorts of 20 each).
##
## The shipped predicate reads building data that a bootstrapped economy does not
## have, so a card filtered on it legitimately matches NOTHING -- correct
## behaviour that is indistinguishable from "the card never equipped". B7
## documents the same substitution; `target_tags` must be replaced on the
## RESOURCE before `compile_native_catalog`, never on the compiled Dictionary.
func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population",   # dense id 9 -- never move this
		"op": 0,                       # TARGET_TAG_GTE
		"threshold_q16": 30 * Q16_ONE,
		"clause": 0,
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


# ─────────────────────────────────────────────────────────────────────────
# world construction (identical for every branch)
# ─────────────────────────────────────────────────────────────────────────

func _new_world(label: String) -> Dictionary:
	var country_ir: Dictionary = _catalogs["country_ir"]
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot.
	ext.create_entities(CELLS)
	_ext_fill_environment(ext)
	_expect("%s: economy configures" % label,
		bool(ext.configure_economy(country_ir, _catalogs["profile"], CELLS, SEED)
			.get("ok", false)))
	_expect("%s: effects configure" % label,
		bool(ext.configure_effects(_catalogs["effect_ir"]).get("ok", false)))
	_expect("%s: modifiers configure" % label,
		bool(ext.configure_modifiers(_catalogs["mod_ir"], CELLS).get("ok", false)))
	_expect("%s: country configures" % label,
		bool(ext.configure_country(country_ir, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": PackedStringArray(["tech.hunting"]),
		}, CELLS, SEED).get("ok", false)))

	# A scattered 2/3 of the grid: (x + 2y) % 3 != 0. Non-contiguous on purpose --
	# a uniform "everything is covered" territory would make a per-cell comparison
	# unable to see a shifted or dropped cell index.
	var owned_cells := PackedInt32Array()
	for c in range(CELLS):
		var x: int = c % WIDTH
		var y: int = c >> ROW_SHIFT
		if (x + 2 * y) % 3 != 0:
			owned_cells.append(c)
	_expect("%s: the fixture territory is a proper subset of the grid" % label,
		owned_cells.size() > 0 and owned_cells.size() < CELLS,
		"%d of %d" % [owned_cells.size(), CELLS])

	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.sv1"]),
		"country_names": PackedStringArray(["Save Point One"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, owned_cells.size()]),
		"territory_cells": owned_cells,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("%s: the country bootstraps" % label, bool(boot.get("ok", false)),
		str(boot))
	var ideo_cfg: Dictionary = ext.configure_ideologies(_catalogs["native_ideology"])
	_expect("%s: ideologies configure" % label, bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg)))

	var owned := 0
	for c in range(CELLS):
		var cs: Dictionary = ext.get_country_cell_summary(c)
		if bool(cs.get("ok", false)) and bool(cs.get("owned", false)):
			owned += 1
	_expect("%s: bootstrap_country registered exactly the intended territory" % label,
		owned == owned_cells.size(), "%d vs %d" % [owned, owned_cells.size()])

	# The economy epoch is what hands the country territory to the economy-side
	# target resolver. `begin_or_reuse_economy_input_epoch` + one full day of slices
	# leaves `_epoch_active` false -- i.e. the save point really has NO ACTIVE EPOCH.
	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	_expect("%s: the economy epoch opens" % label, bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))

	var econ_catalog: Dictionary = _catalogs.get("economy_catalog", {})
	if econ_catalog.is_empty():
		econ_catalog = EconomyCatalogScript.compile_native_catalog()
		_catalogs["economy_catalog"] = econ_catalog
	var sig_keys: PackedStringArray = econ_catalog.get(
		"signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var serf: int = sig_keys.find("serf|default")
	_expect("%s: the fixture resolves both bootstrap signatures" % label,
		farmer >= 0 and serf >= 0, "farmer=%d serf=%d" % [farmer, serf])
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
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
	_expect("%s: the economy bootstraps" % label, bool(eb.get("ok", false)), str(eb))
	var slices := _advance_economy_day(ext, 0)
	_expect("%s: economy day 0 reaches its committed boundary" % label,
		slices > 0, str(slices))

	var handle := int(ext.get_country_cell_summary(owned_cells[0]).get(
		"country_handle", 0))
	_expect("%s: the fixture resolves the country handle" % label, handle != 0,
		str(handle))
	var economy: Dictionary = ext.get_economy_report()
	return {
		"label": label, "ext": ext, "handle": handle,
		"owned": owned_cells.size(), "owned_cells": owned_cells,
		"epoch_active": bool(economy.get("epoch_active", true)),
	}


func _ext_fill_environment(ext: Object) -> void:
	# The 10 environment slots `capture_environment` requires. Registered AFTER
	# `create_entities` so they are sized.
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


# ─────────────────────────────────────────────────────────────────────────
# ideology commands
# ─────────────────────────────────────────────────────────────────────────

## The equip lead, as four one-command batches with FIXED sequences (1..4). Every
## branch submits the same rows, so the idempotency keys -- and the high watermark
## PKID stores -- are identical on both sides of the comparison.
func _equip_batches(dense: int) -> Array:
	return [
		_batch(2, 0, -1, 64 * Q16_ONE, 1),   # GRANT_IDEOLOGY_POINTS
		_batch(1, 0, dense, 0, 2),           # DISCOVER_IDEOLOGY
		_batch(8, 0, dense, 0, 3),           # ADD_UNDERSTANDING
		_batch(5, 0, dense, 0, 4),           # EQUIP_IDEOLOGY
	]


## One command row. The country handle is stamped in at submit time by `_submit`,
## because the handle only exists once that branch's world is built.
func _batch(op: int, day: int, idea: int, value_q16: int, sequence: int) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([op]),
		"effective_days": PackedInt64Array([day]),
		"source_priorities": PackedInt32Array([0]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([sequence]),
		"country_handles": PackedInt64Array([0]),
		"ideology_ids": PackedInt32Array([idea]),
		"values_q16": PackedInt64Array([value_q16]),
		"offer_generations": PackedInt64Array([0]),
		"choice_indices": PackedInt32Array([-1]),
		"gate_ids": PackedInt32Array([-1]),
	}


func _submit(ext: Object, batch: Dictionary, handle: int) -> void:
	var copy: Dictionary = batch.duplicate(true)
	copy["country_handles"] = PackedInt64Array([handle])
	var result: Dictionary = ext.submit_ideology_commands(copy)
	_expect("ideology batch (seq %d) is admitted" % int(batch["sequences"][0]),
		bool(result.get("ok", false)), str(result))


# ─────────────────────────────────────────────────────────────────────────
# advancing
# ─────────────────────────────────────────────────────────────────────────

## One ideology day, driven to completion. `run_ideology_daily` is a SLICE stage:
## a single call may come back `done=false` with the day still in progress, and
## the derived rebuild only installs a front once its fold completes. Looping on
## the runtime's own `done` flag is what lets this fixture wait honestly instead
## of guessing a call count.
func _run_one_ideology_day(ext: Object, day: int, label: String) -> bool:
	var done := false
	var last := {}
	for _i in range(512):
		last = ext.run_ideology_daily(day)
		if not bool(last.get("ok", true)):
			_expect("%s: ideology day %d reports ok" % [label, day], false, str(last))
			return false
		if bool(last.get("done", false)):
			done = true
			break
	_expect("%s: ideology day %d completes" % [label, day], done, str(last))
	return done


func _run_ideology_days(ext: Object, day: int, count: int) -> void:
	for _i in range(count):
		_run_one_ideology_day(ext, day, "day%d" % day)


## Settles every in-flight ideology transition (plan §10.1).
##
## `equip()` only REQUESTS the transition: `start_transition` writes
## `state.location`/`state.level` at request time (`ideology_runtime.cpp:3631-3634`)
## and only `poll_pending_transition` commits it once every Effect transaction of
## the transition is ACKED (`:3776-3836`). Plan §10.1 turns that into an
## observable rule -- "an equip card that is not yet confirmed produces no
## contribution" -- implemented in `collect_effect_activations` (`:2313-2321`):
## while the equip is pending, the card contributes NOTHING, so the derived layer
## is legitimately empty. Every read of derived data therefore has to come after
## this round.
##
## The order is the production daily graph's (`world_ext_bind_methods.cpp:635-648`):
##
##   dispatch_effect_native_modifier() -> run_modifier_daily(day)
##                                     -> ack_effect_native_modifier()
##                                     -> run_ideology_daily(day)   (the poll)
##
## `run_modifier_daily` is MANDATORY between the dispatch and the ACK: without it
## the dispatched rows never complete, the ACK keeps reporting `pending` and
## `pending_transitions` never returns to 0. The ideology day is the caller's
## current day -- the day index only ever moves forward, and the poll stage runs on
## every slice regardless of the day, which is why re-entering the same day settles
## a transition requested earlier on that day.
##
## Returns true when `pending_transitions` reached 0; a failure is reported as a
## real check so a future regression names itself instead of surfacing as "the
## layer is empty".
func _settle_transitions(ext: Object, day: int, label: String) -> bool:
	for _round in range(SETTLE_ROUND_LIMIT):
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		if not bool(acked.get("ok", true)):
			_expect("%s: the native modifier ACK on day %d succeeds" % [label, day],
				false, str(acked))
			return false
		_run_one_ideology_day(ext, day, label)
		if int(_report(ext).get("pending_transitions", -1)) == 0:
			return true
	_expect("%s: every ideology transition settles to 0 pending on day %d"
		% [label, day], false, str(_report(ext).get("pending_transitions", "?")))
	return false


func _advance_economy_day(ext: Object, day: int) -> int:
	for s in range(4096):
		var r: Dictionary = ext.run_economy_slice({"day_index": day, "tick_index": s})
		if bool(r.get("fatal", false)):
			_expect("economy day %d stays non-fatal" % day, false,
				str(r.get("fatal_reason", r)))
			return s
		if bool(r.get("done", false)):
			return s + 1
	_expect("economy day %d completes" % day, false, "4096 slices")
	return 0


## Everything that happens AFTER a save point: the day-0 tail that applies the
## queued equip, then DAYS_AFTER_SAVE more days. Identical for every branch.
##
## The continuation is not a no-op: one ADD_UNDERSTANDING (due day 1) adds
## `LEVEL2_UNDERSTANDING_Q16` of understanding, and the daily accrual keeps moving
## the points ledger. That is real ideology business state which a lossy save /
## reload would expose through `get_ideology_business_state().hash` below.
##
## It deliberately does NOT change the card's LEVEL, and therefore not the derived
## magnitudes -- but the two halves of that statement are now different:
##
##   * The EQUIP's own transition IS settled, at day 0, immediately after the day-0
##     tail applied the queued command (`_settle_transitions`). Plan §10.1 says an
##     equip card that is not yet confirmed produces no contribution, and
##     `collect_effect_activations` implements it
##     (`ideology_runtime.cpp:2313-2321`: a pending transition whose
##     `previous_location == INACTIVE` contributes NOTHING). An equip left PENDING
##     therefore makes the derived layer legitimately EMPTY, and the per-cell
##     comparison below would be the comparison of two empty layers. Settling it is
##     what makes this time point measure a rebuilt front at all.
##   * The LEVEL-UP transition that the day-1 understanding opens is left PENDING on
##     purpose. The same §10.1 rule keeps a pending level-up on its PREVIOUS level
##     (`contribution_level = transition.previous_level`), so the card keeps serving
##     `public_hygiene_l1` -- the magnitudes `PROGRAM_KEY` asserts -- while the
##     `pending_transitions` count stays non-zero and is compared between branches.
##     Settling it would move the card to the L2 magnitudes and turn this fixture
##     into a level-up test, which is not what time point 1 is.
##
## So the front's CONTENT is stable across the two days; what the comparison proves
## is that the front is REBUILT from the restored rows with exactly the same
## content, on exactly the same day, with exactly the same number of installs.
func _advance_and_capture(world: Dictionary, label: String, days: int) -> Dictionary:
	var ext: Object = world["ext"]
	_submit(ext, _batch(8, 1, int(_catalogs["dense"]), LEVEL2_UNDERSTANDING_Q16, 5),
		int(world["handle"]))
	_run_ideology_days(ext, 0, 4)
	# The day-0 tail has applied the EQUIP command; under §10.1 the card contributes
	# nothing until this settle round has ACKed its Effect transactions and the
	# runtime has polled them. It runs BEFORE day 1 so the day-1 understanding opens
	# the level-up with the equip already settled (and that level-up then stays
	# pending, on the L1 magnitudes -- see the note above).
	_settle_transitions(ext, 0, label)
	for day in range(1, days + 1):
		_advance_economy_day(ext, day)
		_run_one_ideology_day(ext, day, label)
	# Belt and braces: if a day's slices ended before the sharded rebuild folded,
	# drain it explicitly. `complete` must be true either way.
	var drained: Dictionary = ext.drain_derived_cell_layer(days)
	_expect("%s: the derived rebuild has no work left after day %d"
		% [label, days], bool(drained.get("complete", false)), str(drained))
	return _capture_state(world, label)


# ─────────────────────────────────────────────────────────────────────────
# save / restore
# ─────────────────────────────────────────────────────────────────────────

func _capture(ext: Object, label: String) -> PackedByteArray:
	var bytes: PackedByteArray = ext.capture_ideology_state()
	_expect("%s: PKID payload is produced" % label, not bytes.is_empty(),
		str(bytes.size()))
	_expect("%s: PKID payload carries the PKID magic" % label,
		_ascii_magic(bytes) == "PKID", "%s (%d bytes)" % [_ascii_magic(bytes),
			bytes.size()])
	return bytes


func _restore(ext: Object, bytes: PackedByteArray) -> bool:
	var result: Dictionary = ext.restore_ideology_state(bytes)
	if not bool(result.get("ok", false)):
		# The reason code is the whole diagnosis: truncation, catalog mismatch and
		# state-hash mismatch all report `ok=false` and nothing else.
		print("[sv1/restore] reason=%s" % String(result.get("reason", "")))
		return false
	return true


## Both save points must have NO installed layer and NO active epoch. This is the
## time point's own precondition: if the layer already existed here, the reload
## would be testing an incremental refresh instead.
func _expect_pre_layer(world: Dictionary, tag: String) -> void:
	var ext: Object = world["ext"]
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var economy: Dictionary = ext.get_economy_report()
	_expect("%s: no derived cell layer has been installed yet" % tag,
		int(layer.get("cell_count", -1)) == 0,
		"cell_count=%s installed=%s" % [str(layer.get("cell_count", "?")),
			str(layer.get("installed", "?"))])
	_expect("%s: no derived contribution exists yet" % tag,
		int(layer.get("contribution_count", 0)) == 0,
		str(layer.get("contribution_count", "?")))
	# An empty-but-installed front is legitimate (the day ran with no active card);
	# what matters is that nothing is COVERED. Printed so a change in shape is
	# visible instead of silently re-interpreted.
	print("[sv1/%s] layer installed=%s cells=%s contributions=%s epoch_active=%s"
		% [tag, str(layer.get("installed", "?")),
			str(layer.get("cell_count", "?")),
			str(layer.get("contribution_count", "?")),
			str(economy.get("epoch_active", "?"))])


# ─────────────────────────────────────────────────────────────────────────
# state capture + comparison
# ─────────────────────────────────────────────────────────────────────────

func _capture_state(world: Dictionary, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var cells := {}
	for stat in [STAT_ADD, STAT_CUT]:
		cells[stat] = _probe_all_cells(ext, stat)
	var layer_cells := int(layer.get("cell_count", 0))
	var expected_layer_cells := 2 * int(world["owned"])
	# THE "the layer really came back" assertion. PKID does not carry the front,
	# so a non-zero, exactly right cell count can only come from a rebuild.
	_expect("%s: the reloaded/built runtime HAS a derived cell layer" % label,
		int(layer.get("installed", 0)) != 0 and layer_cells > 0,
		"installed=%s cells=%s" % [str(layer.get("installed", "?")),
			str(layer_cells)])
	_expect("%s: the layer covers exactly the owned cells x 2 stats" % label,
		layer_cells == expected_layer_cells,
		"%d vs %d" % [layer_cells, expected_layer_cells])
	_expect("%s: the layer carries the expected contribution count" % label,
		int(layer.get("contribution_count", 0)) == expected_layer_cells,
		"%d vs %d" % [int(layer.get("contribution_count", 0)),
			expected_layer_cells])
	# The day the front was last INSTALLED is not necessarily the last day run: the
	# materialiser skips the install when the new front is byte-identical to the
	# previous one. The number itself is therefore only compared between branches
	# (see `_compare`); here it only has to be a real day.
	_expect("%s: the layer reports the day it was built for" % label,
		int(layer.get("sample_day", -1)) >= 0
		and int(layer.get("sample_day", -1)) <= DAYS_AFTER_SAVE,
		str(layer.get("sample_day", "?")))
	# Coverage sanity: a covered cell must move off the identity base and an
	# uncovered one must stay on it. Without this the per-cell comparison could
	# pass on two worlds where the layer is empty everywhere.
	var covered_cell := int((world["owned_cells"] as PackedInt32Array)[0])
	var uncovered_cell := -1
	for c in range(CELLS):
		if not (world["owned_cells"] as PackedInt32Array).has(c):
			uncovered_cell = c
			break
	var covered_probe: Dictionary = ext.get_effective_stat_value(
		STAT_ADD, covered_cell, 0, 1.0)
	var uncovered_probe: Dictionary = ext.get_effective_stat_value(
		STAT_ADD, uncovered_cell, 0, 1.0)
	_expect("%s: a covered cell carries a derived contribution" % label,
		bool(covered_probe.get("derived_present", false)), str(covered_probe))
	_expect("%s: a covered cell's merged value leaves the identity base" % label,
		absf(float(covered_probe.get("value", 1.0)) - 1.0) > 1e-9,
		str(covered_probe.get("value", "?")))
	_expect("%s: an unowned cell stays at the identity base" % label,
		not bool(uncovered_probe.get("derived_present", true))
		and absf(float(uncovered_probe.get("value", 1.0)) - 1.0) < 1e-12,
		str(uncovered_probe))
	# ABSOLUTE correctness, not just equality between two runs. The covered cells
	# must carry the CARD's own magnitude, read from the program interpreter rather
	# than from a hard-coded constant. Two worlds could agree on a wrong number;
	# this is what makes "they match" also mean "they match the right value".
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	var interp: Dictionary = ext.evaluate_effect_program_magnitude(
		PROGRAM_KEY, metrics)
	var expected_add := float(int(interp.get("magnitude", 0))) / float(Q16_ONE)
	_expect("%s: the card's persistent program evaluates" % label,
		bool(interp.get("ok", false)), str(interp))
	var covered_add := float(covered_probe.get("derived_add", 0.0))
	_expect("%s: the covered add equals the program magnitude / Q16 (%.8f)"
		% [label, expected_add],
		absf(covered_add - expected_add) <= 1e-6,
		"derived=%.8f expected=%.8f" % [covered_add, expected_add])

	var business: Dictionary = ext.get_ideology_business_state()
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var instances: Dictionary = ext.get_ideology_effect_instance_report(handle)
	var report: Dictionary = ext.get_ideology_report()
	var audit: Dictionary = ext.get_economy_committed_audit_report()
	var economy: Dictionary = ext.get_economy_report()
	var out := {
		"label": label, "cells": cells, "layer": layer,
		"business": business, "instances": int(instances.get("count", -1)),
		"layer_generation": int(layer.get("layer_generation", -1)),
		"layer_sample_day": int(layer.get("sample_day", -1)),
		"snapshot": {
			"locations": snapshot.get("locations", PackedInt32Array()),
			"levels": snapshot.get("levels", PackedInt32Array()),
			"idea_ids": snapshot.get("idea_ids", PackedInt32Array()),
			"understanding_q16": snapshot.get("understanding_q16",
				PackedInt64Array()),
			"points_q16": int(snapshot.get("ideology_points_q16", 0)),
			"lifetime_points_q16": int(snapshot.get("lifetime_points_q16", 0)),
			"pending_commands": int(report.get("pending_commands", -1)),
			"pending_transitions": int(report.get("pending_transitions", -1)),
		},
		"audit": audit, "economy_newest_day": int(
			economy.get("newest_state_day", -1)),
		"fingerprint": "",
	}
	out["fingerprint"] = _fingerprint(cells)
	print("[sv1/%s] layer cells=%d contributions=%s stats=%s day=%s generation=%s"
		% [label, layer_cells, str(layer.get("contribution_count", "?")),
			str(layer.get("stat_count", "?")), str(layer.get("sample_day", "?")),
			str(layer.get("layer_generation", "?"))])
	_expect("%s: the economy reached the last continued day" % label,
		int(economy.get("newest_state_day", -1)) == DAYS_AFTER_SAVE,
		str(economy.get("newest_state_day", "?")))
	print("[sv1/%s] card locations=%s levels=%s understanding=%s pending_transitions=%s"
		% [label, str(snapshot.get("locations", "?")),
			str(snapshot.get("levels", "?")),
			str(snapshot.get("understanding_q16", "?")),
			str(report.get("pending_transitions", "?"))])
	print("[sv1/%s] economy newest_state_day=%s" % [label,
		str(economy.get("newest_state_day", "?"))])
	print("[sv1/%s] business hash=%s points=%s ideas=%s instances=%d pending=%d"
		% [label, str(business.get("hash", "?")), str(business.get("points", "?")),
			str(business.get("ideas", "?")), int(instances.get("count", -1)),
			int(report.get("pending_commands", -1))])
	print("[sv1/%s] audit available=%s pop_err=%s money_err=%s goods_err=%s"
		% [label, str(audit.get("available", false)),
			str(audit.get("population_error", "?")),
			str(audit.get("money_error", "?")),
			str(audit.get("goods_error", "?"))])
	print("[sv1/%s] per-cell fingerprint=%s" % [label, out["fingerprint"]])
	var add_cells: PackedFloat64Array = (cells[STAT_ADD] as Dictionary)["value"]
	var present: PackedByteArray = (cells[STAT_ADD] as Dictionary)["present"]
	var first := PackedStringArray()
	for c in range(mini(8, CELLS)):
		first.append("%d:%s/%.8f" % [c, str(int(present[c])), add_cells[c]])
	print("[sv1/%s] first 8 cells (present/value, %s)=%s"
		% [label, STAT_ADD, ", ".join(first)])
	return out


func _probe_all_cells(ext: Object, stat: String) -> Dictionary:
	var present := PackedByteArray()
	present.resize(CELLS)
	var add := PackedFloat64Array()
	add.resize(CELLS)
	var value := PackedFloat64Array()
	value.resize(CELLS)
	for c in range(CELLS):
		# The production read shape: entity_handle 0 and the CELL in the group slot,
		# which is the pair `economy_runtime_family_buff.cpp` passes.
		var probe: Dictionary = ext.get_effective_stat_value(stat, c, 0, 1.0)
		if not bool(probe.get("ok", false)):
			present[c] = 0
			continue
		present[c] = 1 if bool(probe.get("derived_present", false)) else 0
		add[c] = float(probe.get("derived_add", 0.0))
		value[c] = float(probe.get("value", 1.0))
	return {"present": present, "add": add, "value": value}


func _fingerprint(cells: Dictionary) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for stat in [STAT_ADD, STAT_CUT]:
		var row: Dictionary = cells[stat]
		context.update(var_to_bytes(row["present"]))
		context.update(var_to_bytes(row["add"]))
		context.update(var_to_bytes(row["value"]))
	return context.finish().hex_encode()


func _compare(reference: Dictionary, other: Dictionary, tag: String) -> void:
	for stat in [STAT_ADD, STAT_CUT]:
		var a: Dictionary = reference["cells"][stat]
		var b: Dictionary = other["cells"][stat]
		_expect("%s: %s derived presence matches on every one of %d cells"
			% [tag, stat, CELLS],
			_presence_diff(a["present"], b["present"]).begins_with("mismatches=0"),
			_presence_diff(a["present"], b["present"]))
		_expect("%s: %s derived add matches EXACTLY on every cell"
			% [tag, stat],
			_float_diff(a["add"], b["add"]).begins_with("mismatches=0"),
			_float_diff(a["add"], b["add"]))
		_expect("%s: %s effective value matches EXACTLY on every cell"
			% [tag, stat],
			_float_diff(a["value"], b["value"]).begins_with("mismatches=0"),
			_float_diff(a["value"], b["value"]))
	_expect("%s: the per-cell fingerprint hash is identical" % tag,
		String(reference["fingerprint"]) == String(other["fingerprint"]),
		"%s vs %s" % [reference["fingerprint"], other["fingerprint"]])
	# Business state: the whole ideology payload, not a subset of it.
	var ref_business: Dictionary = reference["business"]
	var other_business: Dictionary = other["business"]
	_expect("%s: ideology business state hash matches" % tag,
		int(ref_business.get("hash", 0)) == int(other_business.get("hash", 0)),
		"%s vs %s" % [str(ref_business.get("hash", "?")),
			str(other_business.get("hash", "?"))])
	for section in ["points", "baseline", "history", "draw", "bits", "offer", "ideas"]:
		_expect("%s: business section %s matches" % [tag, section],
			int(ref_business.get(section, -1)) == int(other_business.get(section, -1)),
			"%s vs %s" % [str(ref_business.get(section, "?")),
				str(other_business.get(section, "?"))])
	# One-shot execution counts: a derived card must create ZERO Effect instances
	# in both runs (I01), and neither run may leave a command unapplied.
	_expect("%s: one-shot effect instance count is 0 in both runs" % tag,
		int(reference["instances"]) == 0 and int(other["instances"]) == 0,
		"%d vs %d" % [int(reference["instances"]), int(other["instances"])])
	_expect("%s: no ideology command is left pending in either run" % tag,
		int(reference["snapshot"]["pending_commands"]) == 0
		and int(other["snapshot"]["pending_commands"]) == 0,
		"%d vs %d" % [int(reference["snapshot"]["pending_commands"]),
			int(other["snapshot"]["pending_commands"])])
	_expect("%s: both runs carry the same in-flight transition count" % tag,
		int(reference["snapshot"]["pending_transitions"])
		== int(other["snapshot"]["pending_transitions"]),
		"%d vs %d" % [int(reference["snapshot"]["pending_transitions"]),
			int(other["snapshot"]["pending_transitions"])])
	_expect("%s: both runs advanced the economy to the same committed day" % tag,
		int(reference["economy_newest_day"]) == int(other["economy_newest_day"]),
		"%d vs %d" % [int(reference["economy_newest_day"]),
			int(other["economy_newest_day"])])
	# The card must be ACTIVE on both sides -- otherwise "the layer matches" would
	# be the equality of two empty layers.
	_expect("%s: the card is equipped (IDEOLOGY slot) on both sides" % tag,
		_active_locations(reference["snapshot"]) == _active_locations(
			other["snapshot"]) and _active_locations(reference["snapshot"]) > 0,
		"%d vs %d" % [_active_locations(reference["snapshot"]),
			_active_locations(other["snapshot"])])
	_expect("%s: the equipped card keeps the same level and understanding" % tag,
		str(reference["snapshot"]["levels"]) == str(other["snapshot"]["levels"])
		and str(reference["snapshot"]["understanding_q16"])
			== str(other["snapshot"]["understanding_q16"]),
		"%s / %s vs %s / %s" % [
			str(reference["snapshot"]["levels"]),
			str(reference["snapshot"]["understanding_q16"]),
			str(other["snapshot"]["levels"]),
			str(other["snapshot"]["understanding_q16"])])
	# The front is a CACHE of a derivation: it is only re-installed when the new
	# front differs. Both runs must agree on WHEN it was installed and on how many
	# installs happened, or they are not the same timeline.
	_expect("%s: the layer was installed on the same day in both runs" % tag,
		int(reference["layer_sample_day"]) == int(other["layer_sample_day"]),
		"%d vs %d" % [int(reference["layer_sample_day"]),
			int(other["layer_sample_day"])])
	_expect("%s: both runs installed the layer the same number of times" % tag,
		int(reference["layer_generation"]) == int(other["layer_generation"]),
		"%d vs %d" % [int(reference["layer_generation"]),
			int(other["layer_generation"])])
	# Economy conservation (§11.7 also compares it at every time point).
	var ref_audit: Dictionary = reference["audit"]
	var other_audit: Dictionary = other["audit"]
	_expect("%s: the committed economy audit is available on both sides" % tag,
		bool(ref_audit.get("available", false))
			and bool(other_audit.get("available", false)),
		"%s vs %s" % [str(ref_audit.get("available", "?")),
			str(other_audit.get("available", "?"))])
	_expect("%s: economy conservation errors are 0 on both sides" % tag,
		int(ref_audit.get("population_error", -1)) == 0
		and int(ref_audit.get("money_error", -1)) == 0
		and int(ref_audit.get("goods_error", -1)) == 0
		and int(other_audit.get("population_error", -1)) == 0
		and int(other_audit.get("money_error", -1)) == 0
		and int(other_audit.get("goods_error", -1)) == 0,
		"%s vs %s" % [str(ref_audit.get("population_error", "?")),
			str(other_audit.get("population_error", "?"))])


func _active_locations(snapshot: Dictionary) -> int:
	var locations: PackedInt32Array = snapshot["locations"]
	var count := 0
	for value in locations:
		if int(value) != 0:
			count += 1
	return count


func _presence_diff(a: PackedByteArray, b: PackedByteArray) -> String:
	if a.size() != b.size():
		return "size %d vs %d" % [a.size(), b.size()]
	var mismatches := 0
	var first := -1
	for i in range(a.size()):
		if a[i] != b[i]:
			mismatches += 1
			if first < 0:
				first = i
	return "mismatches=%d first=%d" % [mismatches, first]


func _float_diff(a: PackedFloat64Array, b: PackedFloat64Array) -> String:
	if a.size() != b.size():
		return "size %d vs %d" % [a.size(), b.size()]
	var mismatches := 0
	var first := -1
	var worst := 0.0
	for i in range(a.size()):
		if a[i] != b[i]:
			mismatches += 1
			if first < 0:
				first = i
			worst = maxf(worst, absf(a[i] - b[i]))
	return "mismatches=%d first=%d max_abs_diff=%.12f" % [mismatches, first, worst]


func _report(ext: Object) -> Dictionary:
	return ext.get_ideology_report()


func _ascii_magic(bytes: PackedByteArray) -> String:
	return bytes.slice(0, mini(4, bytes.size())).get_string_from_ascii()


## Every check is printed, pass or fail: §11.7 evidence is the LIST of things that
## were compared, and a log that only shows failures cannot tell a reader whether
## the per-cell comparison ran at all.
func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	print("  [FAIL] %s %s" % [label, detail])
	printerr("FAIL %s %s" % [label, detail])


func _finish() -> void:
	print("=== ideology save before layer (§11.7 time point 1): %d checks, %d failures ==="
		% [_checks, _failures])
	quit(0 if _failures == 0 else 1)
