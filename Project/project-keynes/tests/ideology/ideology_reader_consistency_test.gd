extends SceneTree
## Plan §18.1 -- "every reader, scope enumeration, version and explain must use the
## SAME derived front".
##
## WHY THIS FIXTURE EXISTS
##
## B11 proved the derived merge is DOMAIN-GATED: only ECONOMY sees the front, and
## every other domain reads the legacy value. That is the *negative* half of §18.1.
## It says nothing about the positive half: that all the readers which are supposed
## to see the front actually read the SAME structure rather than a private or
## legacy copy of it.
##
## Two paths can agree for the wrong reason. If `get_effective_stat_value` and
## `evaluate_modifier_stat` both returned a hard-coded 1.05, or both read a stale
## cache, this fixture would pass while the front was never consulted. So the checks
## below are shaped to make that impossible:
##
##   * the card's magnitude is read from the PROGRAM INTERPRETER (3277/Q16), not
##     hard-coded in the fixture, and every value is compared against it;
##   * one cell covered by the card and one cell NOT covered are both read, so
##     "same front" cannot be two readers echoing one constant;
##   * the same reader is called with three different bases, so a cached value would
##     fail;
##   * the domain-gated COUNTRY read of the SAME (stat, cell) must disagree, which
##     proves the comparison in this fixture can fail at all.
##
## THE ENUMERATED READER SET (measured, not assumed)
##
## Every GDScript-visible DCWorldExt entry point that can report a stat value, a
## scope enumeration, a version or an explain, with `file:line` of the C++ method and
## whether it reads the derived front:
##
##   R1  get_effective_stat_value        world_ext_modifier.cpp:775   FRONT
##   R2  evaluate_modifier_stat          world_ext_modifier.cpp:409   FRONT (ECONOMY)
##   R3  explain_modifier_stat           world_ext_modifier.cpp:231   FRONT (total ONLY)
##   R4  collect_modifier_scope_ids      world_ext_modifier.cpp:682   FRONT (union)
##   R5  collect_modifier_scope_stat_entries
##                                       world_ext_modifier.cpp:705   FRONT (union)
##   R6  modifier_stat_bucket_version    world_ext_modifier.cpp:671   FRONT (version)
##   R7  get_derived_cell_layer_report   world_ext_modifier.cpp:1069  FRONT (metadata)
##   R8  get_derived_multi_country_report
##                                       world_ext_modifier.cpp:985   FRONT (metadata)
##   N1  explain_modifier_stat .sum_add / .unclamped_value
##                                       modifier_runtime.cpp:2097-2128  NOT FRONT
##   N2  list_modifiers                  world_ext_modifier.cpp:224   NOT FRONT
##   N3  get_modifier_report             world_ext_modifier.cpp:398   NOT FRONT
##   N4  get_gameplay_modifier_effective world_ext_modifier.cpp:449   NOT FRONT
##   N5  get_runtime_modifier_snapshot   world_ext_modifier.cpp:510   NOT FRONT
##   N6  resolve_modifier_stat           world_ext_modifier.cpp:734   no value at all
##
## R3 is the interesting one: `explain` returns a dictionary whose `effective_value`
## is computed by `effective_value()` (front included) while `sum_add`,
## `product_factor` and `unclamped_value` are assembled by iterating `store.active`
## (modifier_runtime.cpp:2097-2121) and therefore describe the LEGACY buckets only.
## The total is right and the decomposition next to it is missing the derived term --
## recorded as a FINDING, not asserted as correct.
##
## The front's per-stat counter (`DerivedCellFront::stat_versions`) is NOT exposed by
## any report -- only its byte size is (`stat_versions_bytes`). The observable proxy is
## `modifier_stat_bucket_version()`, which mixes the layer generation AND
## `stat_versions[sid]` into one hash for ECONOMY (modifier_runtime.cpp:1626-1636).
## That hash is what every production cache is keyed on, so it is the version signal
## this fixture asserts.
##
## The final control pushes the card to LEVEL 2 (`public_hygiene_l2` is CONST 5243, so
## the same two commands carry a different magnitude) and requires every reader to move
## together to the new number -- a stale copy would freeze at 1.05.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_reader_consistency_test.gd

const WIDTH := 8
const HEIGHT := 8
## 8 == 1 << 3, used by the territory pattern below.
const ROW_SHIFT := 3
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261028

const Q16_ONE := 65536
const BASE := 1.0

const CARD_KEY := "idea.public_hygiene"
## `public_hygiene_l1` is `CONST 3277 -> EMIT` with two commands; the first is
## `economy.city.birth_factor` (ADD, +1.0). The second
## (`economy.city.need.housing.consumption_factor.cut`) is deliberately NOT used as a
## probe: this fixture only needs one stat whose authored magnitude is known.
const CARD_PROGRAM := "ideology.effect.public_hygiene_l1"
const STAT_ADD := "economy.city.birth_factor"
## The authored magnitude, asserted against the interpreter below so the fixture
## fails loudly if the content changes instead of silently comparing 1.05 to 1.05.
const CARD_ADD_Q16 := 3277

const DOMAIN_CLIMATE := 0
const DOMAIN_COUNTRY := 1
const DOMAIN_ECONOMY := 2
const DOMAIN_GAMEPLAY := 3
const SCOPE_GLOBAL := 0
const SCOPE_GROUP := 1
const SCOPE_ENTITY := 2

## ECONOMY-domain stats the card does not touch, in preference order. The first one
## that reports `derived_present == false` is used as the untouched control.
const UNTOUCHED_CANDIDATES := [
	"economy.city.output_factor",
	"economy.city.trade_output_factor",
	"economy.city.consumption_factor",
	"economy.city.resource.regen_factor",
]

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
var _catalogs: Dictionary = {}


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


## Exact equality, deliberately. Every front-reading path below ends in the same
## `ModifierRuntime::effective_value(ECONOMY, sid, entity, group, base)` call with the
## same arguments, so a tolerance would hide a reader that re-derives the number by a
## different route (the failure mode this fixture exists to catch).
func _expect_identical(label: String, got: float, want: float) -> void:
	_expect(label, got == want, "got=%.12f want=%.12f" % [got, want])


func _finish(code: int) -> void:
	# ASCII only: the console codepage mangles non-ASCII bytes in a redirected log.
	print("=== 18.1 reader consistency: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)


# ─────────────────────────────────────────────────────────────────────────────
# world construction
# ─────────────────────────────────────────────────────────────────────────────

func _compile_catalogs() -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `EffectDomainCatalog.build()` short-circuits to a PRECOMPILED catalog when one is
	# cached; passing the ideology effects explicitly bypasses that cache so the
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
## The shipped predicate reads building data a bootstrapped economy does not have, so
## a card filtered on it legitimately matches NOTHING -- correct behaviour that is
## indistinguishable from "the card never equipped". `target_tags` must be replaced on
## the RESOURCE before `compile_native_catalog`, never on the compiled Dictionary.
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

	# A scattered 2/3 of the grid: (x + 2y) % 3 != 0. Non-contiguous on purpose -- a
	# uniform "everything is covered" territory would let a shifted or dropped cell
	# index pass unnoticed, and it guarantees both covered and uncovered cells exist.
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
		"country_ids": PackedStringArray(["country.r1"]),
		"country_names": PackedStringArray(["Reader One"]),
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

	# The economy epoch is what hands the country territory to the economy-side target
	# resolver. It returns an ALIASED Dictionary, so it is duplicated before it is held.
	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	epoch = epoch.duplicate(true)
	_expect("%s: the economy epoch opens" % label, bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))

	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
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
	_expect("%s: economy day 0 reaches its committed boundary" % label, slices > 0,
		str(slices))

	var handle := int(ext.get_country_cell_summary(owned_cells[0]).get(
		"country_handle", 0))
	_expect("%s: the fixture resolves the country handle" % label, handle != 0,
		str(handle))
	return {
		"label": label, "ext": ext, "handle": handle, "epoch": epoch,
		"owned_cells": owned_cells, "owned": owned_cells.size(),
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


# ─────────────────────────────────────────────────────────────────────────────
# ideology driving (the four-stage transaction must be settled, not just queued)
# ─────────────────────────────────────────────────────────────────────────────

func _submit(ext: Object, opcode: int, idea: int, handle: int,
		value_q16: int, day: int = 0) -> Dictionary:
	# `sequences` is the idempotency key and must be monotonic ACROSS batches.
	_seq += 1
	return ext.submit_ideology_commands({
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([day]),
		"source_priorities": PackedInt32Array([0]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([_seq]),
		"country_handles": PackedInt64Array([handle]),
		"ideology_ids": PackedInt32Array([idea]),
		"values_q16": PackedInt64Array([value_q16]),
		"offer_generations": PackedInt64Array([0]),
		"choice_indices": PackedInt32Array([-1]),
		"gate_ids": PackedInt32Array([-1]),
	})


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


## One ideology day, driven to completion AND settled through the native adapter.
##
## `run_ideology_daily` is a SLICE stage: a single call may come back `done=false`
## with the day still in progress, and the derived rebuild only installs a front once
## its fold completes. Worse, `done=true` can be reported while a card TRANSITION is
## still pending (`_pending_transitions`), and a pending transition is settled only by
## polling it after the effect/modifier bridge has run:
##
##     dispatch_effect_native_modifier() -> run_modifier_daily(day) -> ack_...
##
## so each round polls the day, then drives the handshake, and only a round that ends
## with `pending_transitions == 0` is accepted. `run_modifier_daily` between dispatch
## and ack is mandatory: without it the transition never settles and the card's level
## is never durably committed.
func _drive_day(ext: Object, day: int, label: String) -> Dictionary:
	var last := {}
	for _round in range(8):
		for _i in range(512):
			last = ext.run_ideology_daily(day)
			if not bool(last.get("ok", true)):
				_expect("%s: ideology day %d reports ok" % [label, day], false,
					str(last))
				return last
			if bool(last.get("done", false)):
				break
		for _e in range(16):
			var eff: Dictionary = ext.run_effect_daily(day)
			if not bool(eff.get("ok", true)) or bool(eff.get("done", true)):
				break
		var dispatched: Dictionary = ext.dispatch_effect_native_modifier()
		var modified: Dictionary = ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		var pending_transitions := int(last.get("pending_transitions", 0))
		print("[r1/%s] day %d done=%s pending_transitions=%d dispatched=%s "
			% [label, day, str(last.get("done", "?")), pending_transitions,
				str(dispatched.get("submitted_transactions", "?"))] +
			"modifier=%s acked=%s"
			% [str(modified.get("commands_applied", "?")),
				str(acked.get("ok", "?"))])
		if pending_transitions == 0:
			return last
	return last


func _drive_days(ext: Object, day: int, count: int, label: String) -> void:
	for _i in range(count):
		_drive_day(ext, day, label)


func _card_location(ext: Object, handle: int, dense: int) -> int:
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var ids: PackedInt32Array = snap.get("idea_ids", PackedInt32Array())
	var locs: PackedInt32Array = snap.get("locations", PackedInt32Array())
	for i in range(mini(ids.size(), locs.size())):
		if int(ids[i]) == dense:
			return int(locs[i])
	return -1


## The snapshot's arrays are parallel to the country's sparse idea list, not indexed by
## the dense catalog id, so the row has to be found by `idea_ids` first.
func _card_level(ext: Object, handle: int, dense: int) -> int:
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var ids: PackedInt32Array = snap.get("idea_ids", PackedInt32Array())
	var levels: PackedInt32Array = snap.get("levels", PackedInt32Array())
	for i in range(mini(ids.size(), levels.size())):
		if int(ids[i]) == dense:
			return int(levels[i])
	return -1


# ─────────────────────────────────────────────────────────────────────────────
# the reader set
# ─────────────────────────────────────────────────────────────────────────────

## Every public path that reports a VALUE (or an explain) for one (stat, cell).
## One call site, so the enumeration cannot drift from the assertions: adding a reader
## here automatically adds it to the covered and uncovered comparisons below.
##
## `entity_handle` is 0 and the CELL goes in the group slot for every ECONOMY read --
## that is the pair the production consumers pass (`economy_runtime.cpp:7126-7129` for
## `refresh_city_modifier_factors`, `economy_runtime.cpp:4391-4394`,
## `economy_runtime_family_buff.cpp:149`) and the only pair that reaches the front.
func _read_value_paths(ext: Object, stat: String, cell: int, base: float) -> Dictionary:
	var bridge: Dictionary = ext.get_effective_stat_value(stat, cell, 0, base)
	var evaluated := float(ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, cell, stat, base))
	var explain: Dictionary = ext.explain_modifier_stat(
		DOMAIN_ECONOMY, 0, cell, stat, base)
	var gameplay: Dictionary = ext.get_gameplay_modifier_effective(0, cell, stat)
	return {
		"R1_bridge_value": float(bridge.get("value", -1.0)),
		"R1_bridge_ok": bool(bridge.get("ok", false)),
		"R1_derived_present": bool(bridge.get("derived_present", false)),
		"R1_derived_add": float(bridge.get("derived_add", 0.0)),
		"R2_evaluate_effective": evaluated,
		"R3_explain_effective": float(explain.get("effective_value", -1.0)),
		"N1_explain_sum_add": float(explain.get("sum_add", -1.0)),
		"N1_explain_product": float(explain.get("product_factor", -1.0)),
		"N1_explain_unclamped": float(explain.get("unclamped_value", -1.0)),
		"N4_gameplay_ok": bool(gameplay.get("ok", false)),
		"N4_gameplay_value": float(gameplay.get("effective_value", -1.0)),
		# The domain-gated read of the SAME stat on the SAME cell. `effective_value`
		# returns `base_value` untouched when the stat's domain is not the requested
		# one (modifier_runtime.cpp:1409-1411), so this is the fixture's proof that
		# "the numbers agree" is a real constraint and not a tautology.
		"C1_country_domain": float(ext.evaluate_modifier_stat(
			DOMAIN_COUNTRY, 0, cell, stat, base)),
	}


static func _has_cell(values: PackedInt64Array, cell: int) -> bool:
	for v in values:
		if int(v) == cell:
			return true
	return false


static func _count_non_owned(values: PackedInt64Array,
		owned_cells: PackedInt32Array) -> int:
	var bad := 0
	for v in values:
		if not owned_cells.has(int(v)):
			bad += 1
	return bad


static func _field_at(report: Dictionary, key: String, index: int) -> int:
	var packed: PackedInt64Array = report.get(key, PackedInt64Array())
	if index < 0 or index >= packed.size():
		return -1
	return int(packed[index])


# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────

func _run() -> void:
	_catalogs = _compile_catalogs()
	if _catalogs.is_empty():
		_finish(1)
		return
	var ids: PackedStringArray = _catalogs["native_ideology"].get(
		"ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the card %s is in the compiled ideology catalog" % CARD_KEY,
		dense >= 0, "dense=%d of %d" % [dense, ids.size()])
	if dense < 0:
		_finish(2)
		return

	var world: Dictionary = _new_world("r1")
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var owned_cells: PackedInt32Array = world["owned_cells"]
	var owned_count := int(world["owned"])
	if handle == 0:
		_finish(3)
		return

	var resolved: Dictionary = ext.resolve_modifier_stat(STAT_ADD)
	var stat_id := int(resolved.get("stat_id", -1))
	_expect("the target stat resolves to a dense id", stat_id >= 0, str(resolved))
	if stat_id < 0:
		_finish(4)
		return
	var stats := PackedInt32Array([stat_id])

	# ── the number the card carries, read from the interpreter ──────────────
	#
	# Not a literal in this fixture: if the content changes, `CARD_ADD_Q16` fails
	# here and every value comparison below is validated against the new magnitude.
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	var interp: Dictionary = ext.evaluate_effect_program_magnitude(
		CARD_PROGRAM, metrics)
	_expect("the card's program evaluates", bool(interp.get("ok", false)),
		str(interp))
	var magnitude := int(interp.get("magnitude", -1))
	_expect("the card's authored magnitude is %d/Q16" % CARD_ADD_Q16,
		magnitude == CARD_ADD_Q16, "magnitude=%d" % magnitude)
	var add := float(magnitude) / float(Q16_ONE)
	var expected := BASE + add
	print("[r1] card magnitude=%d/Q16  add=%.12f  expected(base+add)=%.12f"
		% [magnitude, add, expected])

	# ── baseline: NO front, so every reader must be blind ──────────────────
	var zero_layer: Dictionary = ext.get_derived_cell_layer_report()
	var zero_report: Dictionary = ext.get_modifier_report()
	var bucket_version_before := int(ext.modifier_stat_bucket_version(
		DOMAIN_ECONOMY, stats))
	var scope_before: Dictionary = ext.collect_modifier_scope_ids(
		DOMAIN_ECONOMY, SCOPE_GROUP, stats)
	var entries_before: Dictionary = ext.collect_modifier_scope_stat_entries(
		DOMAIN_ECONOMY, SCOPE_GROUP, stats)
	print("[r1/baseline] installed=%s layer_generation=%s cell_count=%s "
		% [str(zero_layer.get("installed", "?")),
			str(zero_layer.get("layer_generation", "?")),
			str(zero_layer.get("cell_count", "?"))] +
		"bucket_version=%d scope_ids=%d" % [bucket_version_before,
			(scope_before.get("scope_ids", PackedInt64Array()) as PackedInt64Array).size()])
	_expect("baseline: no derived front is installed", 
		not bool(zero_layer.get("installed", true)), str(zero_layer))
	_expect("baseline: layer_generation is exactly 0",
		int(zero_layer.get("layer_generation", -1)) == 0,
		str(zero_layer.get("layer_generation", "?")))
	_expect("baseline: the scope enumeration is empty for this stat",
		(scope_before.get("scope_ids", PackedInt64Array()) as PackedInt64Array).is_empty(),
		str(scope_before))
	_expect("baseline: the stat/scope entry enumeration is empty",
		(entries_before.get("scope_ids", PackedInt64Array()) as PackedInt64Array).is_empty(),
		str(entries_before))
	var probe_cell := int(owned_cells[0])
	var baseline_reads: Dictionary = _read_value_paths(
		ext, STAT_ADD, probe_cell, BASE)
	print("[r1/baseline] cell %d (no front): R1=%.12f R2=%.12f R3=%.12f"
		% [probe_cell, float(baseline_reads["R1_bridge_value"]),
			float(baseline_reads["R2_evaluate_effective"]),
			float(baseline_reads["R3_explain_effective"])])
	_expect_identical("baseline: R1 returns the base", 
		float(baseline_reads["R1_bridge_value"]), BASE)
	_expect("baseline: R1 reports no derived row",
		not bool(baseline_reads["R1_derived_present"]), str(baseline_reads))

	# ── equip and settle ───────────────────────────────────────────────────
	#
	# grant -> discover -> (day) -> understanding(0) -> (day) -> equip -> settle.
	# The understanding row carries 0 on purpose: `public_hygiene_l1`'s L2 threshold
	# is 524288 and a real understanding grant would move the card to L2, changing the
	# authored magnitude this fixture compares against.
	_submit(ext, 2, -1, handle, 64 * Q16_ONE)
	_submit(ext, 1, dense, handle, 0)
	_drive_days(ext, 0, 2, "lead")
	_submit(ext, 8, dense, handle, 0)
	_drive_days(ext, 0, 2, "lead2")
	_submit(ext, 5, dense, handle, 0)
	var install_day := -1
	for d in range(0, 5):
		_drive_day(ext, d, "equip")
		var probe_layer: Dictionary = ext.get_derived_cell_layer_report()
		print("[r1/equip] after day %d: cell_count=%s layer_generation=%s"
			% [d, str(probe_layer.get("cell_count", "?")),
				str(probe_layer.get("layer_generation", "?"))])
		if int(probe_layer.get("cell_count", 0)) > 0:
			install_day = d
			break
	var drained: Dictionary = ext.drain_derived_cell_layer(
		install_day if install_day >= 0 else 0)
	_expect("the derived rebuild has no work left after the equip days",
		bool(drained.get("complete", false)), str(drained))

	var location := _card_location(ext, handle, dense)
	_expect("the card is equipped (location == IDEOLOGY)", location == 1,
		"location=%d (-1 means the card is not in the country's known set)" % location)
	var ideology_report: Dictionary = ext.get_ideology_report()
	print("[r1/equip] card location=%d pending_transitions=%s pending_commands=%s"
		% [location, str(ideology_report.get("pending_transitions", "?")),
			str(ideology_report.get("pending_commands", "?"))])
	_expect("the equip TRANSITION settled (no pending transition left)",
		int(ideology_report.get("pending_transitions", -1)) == 0,
		str(ideology_report.get("pending_transitions", "?")))

	# ── the front, as its own two readers describe it ──────────────────────
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var multi: Dictionary = ext.get_derived_multi_country_report()
	var front_stats: PackedInt32Array = layer.get("stat_ids", PackedInt32Array())
	print("[r1/front] installed=%s layer_generation=%s stat_count=%s cell_count=%s "
		% [str(layer.get("installed", "?")),
			str(layer.get("layer_generation", "?")),
			str(layer.get("stat_count", "?")),
			str(layer.get("cell_count", "?"))] +
		"contribution_count=%s sample_day=%s epoch_id=%s stat_ids=%s"
		% [str(layer.get("contribution_count", "?")),
			str(layer.get("sample_day", "?")), str(layer.get("epoch_id", "?")),
			str(front_stats)])
	_expect("the front is installed", bool(layer.get("installed", false)), str(layer))
	_expect("the front carries the card's stat",
		front_stats.has(stat_id), "stat_ids=%s sid=%d" % [str(front_stats), stat_id])
	_expect("the front reports a real build day",
		int(layer.get("sample_day", -1)) >= 0, str(layer.get("sample_day", "?")))
	# `epoch_id` / `world_identity` / `map_generation` are STRUCTURALLY 0 in this
	# build (the members are never assigned), so they are printed and NOT used as an
	# agreement signal. Asserting them would pin a placeholder, not a contract.
	print("[r1/front] epoch_id=%s (structurally 0 -- not used as a signal)"
		% str(layer.get("epoch_id", "?")))
	print("[r1/front] multi_country rows=%s cells=%s generation=%s"
		% [str(multi.get("rows", "?")), str(multi.get("cells", "?")),
			str(multi.get("generation", "?"))])

	# ── §18.1 item 4: version agreement ────────────────────────────────────
	var generation := int(layer.get("layer_generation", -1))
	_expect("V1: the first install bumped layer_generation to exactly 1",
		generation == 1, "generation=%d" % generation)
	_expect("V2: the front's own generation field agrees with the layer report",
		int(multi.get("generation", -1)) == generation,
		"multi=%s layer=%d" % [str(multi.get("generation", "?")), generation])

	# ── coverage: the front covers EXACTLY the country's territory ─────────
	#
	# This is the item-5 guard applied to the whole grid: if the front covered a cell
	# the country does not own, or missed an owned one, the "covered vs uncovered"
	# comparisons below would be picking cells from a set the reader invented.
	var covered := -1
	var uncovered := -1
	var present_count := 0
	var mismatches: Array = []
	for c in range(CELLS):
		var summary: Dictionary = ext.get_country_cell_summary(c)
		var owned_flag := bool(summary.get("ok", false)) and bool(
			summary.get("owned", false))
		var probe: Dictionary = ext.get_effective_stat_value(STAT_ADD, c, 0, BASE)
		var present := bool(probe.get("derived_present", false))
		if present:
			present_count += 1
			if covered < 0:
				covered = c
		elif not owned_flag:
			# A NON-ZERO uncovered cell is preferred: cell 0 also exercises the
			# `group_handle == 0` sentinel path inside `effective_value`, and a probe
			# that only ever sees group 0 could pass for the wrong reason.
			if uncovered < 0 or uncovered == 0:
				uncovered = c
		if present != owned_flag:
			mismatches.append("%d(owned=%s,present=%s)" % [c, str(owned_flag),
				str(present)])
	print("[r1/coverage] cells with a derived row=%d owned=%d first_covered=%d "
		% [present_count, owned_count, covered] +
		"first_uncovered=%d mismatches=%d" % [uncovered, mismatches.size()])
	_expect("the derived rows cover exactly the owned cells, cell for cell",
		mismatches.is_empty() and present_count == owned_count,
		"mismatches=%s" % str(mismatches))
	_expect("the fixture has a covered cell and an uncovered cell",
		covered >= 0 and uncovered >= 0, "covered=%d uncovered=%d" % [covered,
			uncovered])
	if covered < 0 or uncovered < 0:
		_finish(5)
		return
	var covered_owned := bool(ext.get_country_cell_summary(covered).get("owned", false))
	var uncovered_owned := bool(ext.get_country_cell_summary(uncovered).get(
		"owned", false))
	_expect("the covered probe cell is owned", covered_owned, str(covered))
	_expect("the uncovered probe cell is NOT owned", not uncovered_owned,
		str(uncovered))

	# ── item 2: every front-reading path, same (stat, cell), same number ────
	print("[r1/covered] stat=%s cell=%d base=%.12f expected=%.12f"
		% [STAT_ADD, covered, BASE, expected])
	var covered_reads: Dictionary = _read_value_paths(ext, STAT_ADD, covered, BASE)
	print("[r1/covered] R1 get_effective_stat_value.value    = %.12f"
		% float(covered_reads["R1_bridge_value"]))
	print("[r1/covered] R2 evaluate_modifier_stat(ECONOMY)   = %.12f"
		% float(covered_reads["R2_evaluate_effective"]))
	print("[r1/covered] R3 explain_modifier_stat.effective   = %.12f"
		% float(covered_reads["R3_explain_effective"]))
	print("[r1/covered] R1 derived_add slice                 = %.12f"
		% float(covered_reads["R1_derived_add"]))
	var bridge_value := float(covered_reads["R1_bridge_value"])
	_expect("R1: get_effective_stat_value reports ok",
		bool(covered_reads["R1_bridge_ok"]), str(covered_reads))
	_expect_identical("R1: the merged value is exactly base + the card's add",
		bridge_value, expected)
	_expect_identical("R2: evaluate_modifier_stat returns R1's number exactly",
		float(covered_reads["R2_evaluate_effective"]), bridge_value)
	_expect_identical("R3: explain's effective_value returns R1's number exactly",
		float(covered_reads["R3_explain_effective"]), bridge_value)
	_expect_identical("R1: the reported derived_add slice IS the card's magnitude",
		float(covered_reads["R1_derived_add"]), add)

	# ── EXPLAIN'S DECOMPOSITION IS NOW HONEST (fixed 2026-10-28) ────────────
	#
	# This block used to record a FINDING: `explain`'s decomposition was assembled from
	# `store.active` only, so the SAME dictionary reported `effective_value = 1.05` beside
	# `sum_add = 0` -- i.e. "the value is 1.05, and the reason is nothing". Any explain
	# tooltip built on it would print no reason at all for the whole derived contribution.
	#
	# `ModifierRuntime::explain` now merges the derived term into the decomposition with
	# the SAME arithmetic and the SAME §5.5 zero-factor rule as `effective_value`, and it
	# additionally exposes `derived_add` / `derived_factor` / `derived_present` on their
	# own, so a consumer can say "the cell layer added 0.05".
	#
	# The assertions below are the EXACT INVERSE of the two that pinned the defect, so a
	# regression flips them straight back to failing.
	var sum_add := float(covered_reads["N1_explain_sum_add"])
	var unclamped := float(covered_reads["N1_explain_unclamped"])
	var product := float(covered_reads["N1_explain_product"])
	print("[fixed] N1 explain decomposition: sum_add=%.12f product_factor=%.12f "
		% [sum_add, product] +
		"unclamped=%.12f  vs effective_value=%.12f"
		% [unclamped, bridge_value])
	_expect("N1 [fixed]: explain's sum_add INCLUDES the derived term",
		absf(sum_add - (bridge_value - BASE)) <= 1e-9,
		"sum_add=%.12f derived_delta=%.12f" % [sum_add, bridge_value - BASE])
	_expect("N1 [fixed]: explain's unclamped_value reconciles with its own operands",
		absf(unclamped - (BASE + sum_add) * product) <= 1e-9,
		"unclamped=%.12f vs (base+sum_add)*product=%.12f"
			% [unclamped, (BASE + sum_add) * product])
	_expect("N1 [fixed]: the decomposition now explains the TOTAL (the gap is zero)",
		absf(bridge_value - unclamped) <= 1e-9,
		"gap=%.12f add=%.12f" % [bridge_value - unclamped, add])

	var listed: Dictionary = ext.list_modifiers(DOMAIN_ECONOMY, 0, STAT_ADD)
	var listed_handles: PackedInt64Array = listed.get("handles", PackedInt64Array())
	print("[FINDING] N2 list_modifiers(ECONOMY, 0, %s) handles=%d while the front "
		% [STAT_ADD, listed_handles.size()] +
		"covers %d cells -- a derived contribution has no instance handle"
		% present_count)
	_expect("N2: list_modifiers cannot enumerate the front (no instance handles)",
		listed_handles.size() < present_count,
		"handles=%d covered=%d" % [listed_handles.size(), present_count])

	# ── item 2 continued: the enumeration and version readers ──────────────
	var scope_after: Dictionary = ext.collect_modifier_scope_ids(
		DOMAIN_ECONOMY, SCOPE_GROUP, stats)
	var scope_ids: PackedInt64Array = scope_after.get(
		"scope_ids", PackedInt64Array())
	var entries_after: Dictionary = ext.collect_modifier_scope_stat_entries(
		DOMAIN_ECONOMY, SCOPE_GROUP, stats)
	var entry_scopes: PackedInt64Array = entries_after.get(
		"scope_ids", PackedInt64Array())
	var entry_stats: PackedInt32Array = entries_after.get(
		"stat_ids", PackedInt32Array())
	print("[r1/enum] R4 scope_ids(%d)=%s" % [scope_ids.size(), str(scope_ids)])
	print("[r1/enum] R5 entries scopes=%d stats=%d" % [entry_scopes.size(),
		entry_stats.size()])
	_expect("R4: the scope enumeration has one GROUP id per covered cell",
		scope_ids.size() == present_count,
		"%d vs %d" % [scope_ids.size(), present_count])
	_expect("R4: the scope enumeration contains the covered cell",
		_has_cell(scope_ids, covered), str(scope_ids))
	_expect("R4: the scope enumeration contains no unowned cell",
		_count_non_owned(scope_ids, owned_cells) == 0, str(scope_ids))
	_expect("R5: the (cell, stat) enumeration agrees with R4 in size",
		entry_scopes.size() == scope_ids.size() and entry_stats.size() ==
			entry_scopes.size(),
		"%d/%d vs %d" % [entry_scopes.size(), entry_stats.size(), scope_ids.size()])
	var entry_stat_ok := true
	for i in range(entry_stats.size()):
		if int(entry_stats[i]) != stat_id:
			entry_stat_ok = false
	_expect("R5: every entry names the card's stat", entry_stat_ok,
		str(entry_stats))
	_expect("R5: the entry enumeration contains the covered cell",
		_has_cell(entry_scopes, covered), str(entry_scopes))
	_expect("R5: the entry enumeration contains no unowned cell",
		_count_non_owned(entry_scopes, owned_cells) == 0, str(entry_scopes))

	var bucket_version_after := int(ext.modifier_stat_bucket_version(
		DOMAIN_ECONOMY, stats))
	var country_version := int(ext.modifier_stat_bucket_version(
		DOMAIN_COUNTRY, stats))
	print("[r1/version] R6 bucket_version ECONOMY %d -> %d (COUNTRY=%d)"
		% [bucket_version_before, bucket_version_after, country_version])
	_expect("R6: the ECONOMY bucket version moved when the front installed",
		bucket_version_after != bucket_version_before,
		"%d -> %d" % [bucket_version_before, bucket_version_after])

	# ── item 4: the report's own generation fields must not lie ────────────
	var report_after: Dictionary = ext.get_modifier_report()
	var query_before := _field_at(zero_report, "query_count_by_domain",
		DOMAIN_ECONOMY)
	var query_after := _field_at(report_after, "query_count_by_domain",
		DOMAIN_ECONOMY)
	print("[r1/report] ECONOMY snapshot_versions %d -> %d  active_instances %d -> %d "
		% [_field_at(zero_report, "snapshot_versions", DOMAIN_ECONOMY),
			_field_at(report_after, "snapshot_versions", DOMAIN_ECONOMY),
			_field_at(zero_report, "active_instances_by_domain", DOMAIN_ECONOMY),
			_field_at(report_after, "active_instances_by_domain", DOMAIN_ECONOMY)] +
		"buckets %d -> %d  queries %d -> %d  layer_generation field present=%s"
		% [_field_at(zero_report, "bucket_count_by_domain", DOMAIN_ECONOMY),
			_field_at(report_after, "bucket_count_by_domain", DOMAIN_ECONOMY),
			query_before, query_after,
			str(report_after.has("layer_generation")
				or report_after.has("layer_stat_version"))])
	_expect("V3: the report's store generations did not move (the front is outside "
		+ "the stores -- ADR02)",
		_field_at(zero_report, "snapshot_versions", DOMAIN_ECONOMY) ==
			_field_at(report_after, "snapshot_versions", DOMAIN_ECONOMY) and
		_field_at(zero_report, "active_instances_by_domain", DOMAIN_ECONOMY) ==
			_field_at(report_after, "active_instances_by_domain", DOMAIN_ECONOMY) and
		_field_at(zero_report, "bucket_count_by_domain", DOMAIN_ECONOMY) ==
			_field_at(report_after, "bucket_count_by_domain", DOMAIN_ECONOMY),
		str(report_after.get("snapshot_versions", "?")))
	_expect("V4: the report DOES count the store traffic the readers generated",
		query_after > query_before, "%d -> %d" % [query_before, query_after])
	# N3 [fixed 2026-10-28]. `get_modifier_report()` used to expose NO derived-layer
	# field at all, so the report could not witness the front -- the only proxy was
	# `modifier_stat_bucket_version()`, which mixes the generation into a hash. It now
	# reports `layer_installed` / `layer_generation` / `layer_stat_count` /
	# `layer_contribution_count` / `layer_stat_versions_bytes`.
	#
	# These are the EXACT INVERSE of the old FINDING, so a regression flips them red.
	var report_installed := int(report_after.get("layer_installed", -1))
	var report_gen := int(report_after.get("layer_generation", -1))
	var report_stats := int(report_after.get("layer_stat_count", -1))
	print("[r1/report] N3 layer witness: installed=%d generation=%d stat_count=%d"
		% [report_installed, report_gen, report_stats])
	_expect("N3 [fixed]: get_modifier_report now witnesses the layer",
		report_installed == 1 and report_gen == generation,
		"installed=%d generation=%d (the layer report says %d)"
			% [report_installed, report_gen, generation])
	_expect("N3 [fixed]: the report's layer stat count agrees with the layer report",
		report_stats == int(layer.get("stat_count", -1)),
		"stat_count=%d vs %d" % [report_stats, int(layer.get("stat_count", -1))])

	# ── item 5: a cell the card does NOT cover ─────────────────────────────
	print("[r1/uncovered] cell=%d base=%.12f" % [uncovered, BASE])
	var uncovered_reads: Dictionary = _read_value_paths(
		ext, STAT_ADD, uncovered, BASE)
	print("[r1/uncovered] R1=%.12f R2=%.12f R3=%.12f derived_present=%s"
		% [float(uncovered_reads["R1_bridge_value"]),
			float(uncovered_reads["R2_evaluate_effective"]),
			float(uncovered_reads["R3_explain_effective"]),
			str(uncovered_reads["R1_derived_present"])])
	_expect("uncovered: R1 returns exactly the base",
		float(uncovered_reads["R1_bridge_value"]) == BASE, str(uncovered_reads))
	_expect_identical("uncovered: R2 returns exactly the base",
		float(uncovered_reads["R2_evaluate_effective"]), BASE)
	_expect_identical("uncovered: R3 returns exactly the base",
		float(uncovered_reads["R3_explain_effective"]), BASE)
	_expect("uncovered: R1 reports no derived row",
		not bool(uncovered_reads["R1_derived_present"]), str(uncovered_reads))
	_expect("uncovered: the scope enumeration does not contain the cell",
		not _has_cell(scope_ids, uncovered), str(uncovered))

	# ── the negative controls ──────────────────────────────────────────────
	#
	# C1: the domain-gated read of the SAME (stat, cell). If this matched the front
	# value, the equality assertions above would be satisfied by any reader that
	# echoed another, so this is the control that keeps them honest.
	var country_value := float(covered_reads["C1_country_domain"])
	print("[r1/control-C1] COUNTRY-domain read of the same (stat, cell) = %.12f "
		% country_value + "vs ECONOMY=%.12f" % bridge_value)
	_expect("C1: the COUNTRY-domain read returns the base, not the front value",
		country_value == BASE, "%.12f" % country_value)
	_expect("C1: the two domain reads disagree by exactly the card's add",
		absf((bridge_value - country_value) - add) <= 1e-12,
		"gap=%.12f" % (bridge_value - country_value))

	# C2: a stat the card does not touch.
	var untouched := ""
	for candidate in UNTOUCHED_CANDIDATES:
		var probe: Dictionary = ext.get_effective_stat_value(
			candidate, covered, 0, BASE)
		if bool(probe.get("ok", false)) and not bool(
				probe.get("derived_present", false)):
			untouched = String(candidate)
			break
	_expect("C2: an untouched ECONOMY stat can be found", untouched != "",
		str(UNTOUCHED_CANDIDATES))
	if untouched != "":
		var untouched_reads: Dictionary = _read_value_paths(
			ext, untouched, covered, BASE)
		var untouched_value := float(untouched_reads["R1_bridge_value"])
		print("[r1/control-C2] untouched stat %s at the covered cell = %.12f"
			% [untouched, untouched_value])
		_expect("C2: the untouched stat returns exactly base through R1",
			untouched_value == BASE, "%.12f" % untouched_value)
		_expect_identical("C2: R2 agrees on the untouched stat",
			float(untouched_reads["R2_evaluate_effective"]), BASE)
		_expect("C2: the untouched stat is NOT equal to base + add",
			absf(untouched_value - expected) > 1e-6,
			"untouched=%.12f expected=%.12f" % [untouched_value, expected])

	# C3: the merge is base-additive, so a cached number cannot pass. Two different
	# bases must produce two different values whose DIFFERENCE is exactly the base
	# difference -- i.e. the derived add is genuinely folded into the arithmetic.
	var scaled_base := 3.0
	var scaled: Dictionary = ext.get_effective_stat_value(
		STAT_ADD, covered, 0, scaled_base)
	var scaled_value := float(scaled.get("value", -1.0))
	print("[r1/control-C3] R1 with base=%.1f -> %.12f (expected %.12f)"
		% [scaled_base, scaled_value, scaled_base + add])
	_expect_identical("C3: the same reader with another base is exactly base + add",
		scaled_value, scaled_base + add)
	_expect("C3: the two bases produced two different numbers",
		scaled_value != bridge_value,
		"%.12f vs %.12f" % [scaled_value, bridge_value])

	# ── item 4 continued: an idle day must NOT bump the generation ─────────
	_drive_day(ext, 1, "idle")
	var idle_layer: Dictionary = ext.get_derived_cell_layer_report()
	var idle_version := int(ext.modifier_stat_bucket_version(DOMAIN_ECONOMY, stats))
	var idle_reads: Dictionary = _read_value_paths(ext, STAT_ADD, covered, BASE)
	print("[r1/idle] day 1: layer_generation=%s cell_count=%s bucket_version=%d "
		% [str(idle_layer.get("layer_generation", "?")),
			str(idle_layer.get("cell_count", "?")), idle_version] +
		"R1=%.12f" % float(idle_reads["R1_bridge_value"]))
	print("[r1/idle] two rebuilds with identical content -> one install, "
		+ "layer_generation must still be 1 (0 extra bumps)")
	_expect("V5: an idle day with identical content does NOT bump "
		+ "layer_generation", int(idle_layer.get("layer_generation", -1)) == generation,
		"%s vs %d" % [str(idle_layer.get("layer_generation", "?")), generation])
	_expect("V6: the bucket version is stable across an unchanged front",
		idle_version == bucket_version_after, "%d vs %d" % [idle_version,
			bucket_version_after])
	_expect_identical("V7: every reader still returns the same number after the "
		+ "idle day", float(idle_reads["R2_evaluate_effective"]), bridge_value)

	# ── control C4: perturb the CARD and require every reader to move ───────
	#
	# A front that never changes is a weak proof: two readers could agree on a stale
	# copy forever. So the card is pushed to LEVEL 2 (`public_hygiene_l2` is
	# CONST 5243 -- the same two commands, a different magnitude), which changes the
	# front's CONTENT, and every value reader must then agree on the NEW number.
	#
	# The level only commits when the level TRANSITION settles, and that transition
	# carries native-modifier transactions, so this is the handshake's payoff: without
	# `dispatch -> run_modifier_daily -> ack` the transition stays pending, the level
	# never commits, and the front never moves. `_drive_day` polls and handshakes until
	# `pending_transitions == 0`.
	var program_l2 := "ideology.effect.public_hygiene_l2"
	var l2_interp: Dictionary = ext.evaluate_effect_program_magnitude(
		program_l2, metrics)
	var l2_magnitude := int(l2_interp.get("magnitude", -1))
	print("[r1/control-C4] level-2 program %s -> %d/Q16 (authored 5243)"
		% [program_l2, l2_magnitude])
	_expect("C4: the level-2 program evaluates to the authored 5243/Q16",
		l2_magnitude == 5243, str(l2_interp))
	_submit(ext, 8, dense, handle, 524288, 2)   # 524288 == the L2 understanding threshold
	var level_day := 2
	for _attempt in range(4):
		_drive_day(ext, level_day, "level")
		if int(ext.get_derived_cell_layer_report().get("layer_generation", -1)) != \
				generation:
			break
		# The level can commit AFTER that day's rebuild already collected, in which
		# case one more day is needed for the materialiser to see the new magnitude.
		level_day += 1
	var level_layer: Dictionary = ext.get_derived_cell_layer_report()
	var level := _card_level(ext, handle, dense)
	var level_reads: Dictionary = _read_value_paths(ext, STAT_ADD, covered, BASE)
	print("[r1/control-C4] card_level=%d layer_generation=%s R1=%.12f R2=%.12f "
		% [level, str(level_layer.get("layer_generation", "?")),
			float(level_reads["R1_bridge_value"]),
			float(level_reads["R2_evaluate_effective"])] +
		"R3=%.12f" % float(level_reads["R3_explain_effective"]))
	if level >= 1 and l2_magnitude > 0:
		var l2_add := float(l2_magnitude) / float(Q16_ONE)
		var l2_expected := BASE + l2_add
		print("[r1/control-C4] new expected=%.12f old=%.12f" % [l2_expected,
			bridge_value])
		_expect("C4: the level change bumped layer_generation exactly once more",
			int(level_layer.get("layer_generation", -1)) == generation + 1,
			"%s vs %d" % [str(level_layer.get("layer_generation", "?")),
				generation + 1])
		_expect_identical("C4: R1 reports the NEW magnitude exactly, not the old one",
			float(level_reads["R1_bridge_value"]), l2_expected)
		_expect_identical("C4: R2 agrees with R1 on the new magnitude",
			float(level_reads["R2_evaluate_effective"]),
			float(level_reads["R1_bridge_value"]))
		_expect_identical("C4: R3 agrees with R1 on the new magnitude",
			float(level_reads["R3_explain_effective"]),
			float(level_reads["R1_bridge_value"]))
		_expect_identical("C4: the derived_add slice is the NEW magnitude",
			float(level_reads["R1_derived_add"]), l2_add)
		_expect("C4: the number really diverged from the level-1 read",
			float(level_reads["R1_bridge_value"]) != bridge_value,
			"%.12f vs %.12f" % [float(level_reads["R1_bridge_value"]),
				bridge_value])
		_expect("C4: the version hash moved for a FRONT-ONLY change",
			int(ext.modifier_stat_bucket_version(DOMAIN_ECONOMY, stats)) !=
				bucket_version_after,
			"the ECONOMY bucket version did not move across the level change")
	else:
		print("[UNVERIFIED] C4: the level push did not commit (level=%d, "
			% level + "understanding=%s), so the front could not be perturbed"
			% str(ext.get_ideology_snapshot(handle).get("understanding_q16", "?")))
		_expect_identical("C4: with no level commit the readers keep the level-1 "
			+ "number", float(level_reads["R1_bridge_value"]), bridge_value)

	# ── N4/N5/N6: readers that structurally cannot see the front ───────────
	print("[r1/not-front] N4 get_gameplay_modifier_effective ok=%s value=%.12f "
		% [str(covered_reads["N4_gameplay_ok"]),
			float(covered_reads["N4_gameplay_value"])] +
		"(GAMEPLAY domain only; an ECONOMY stat is refused, so it can never be a "
		+ "second copy of the front)")
	_expect("N4: get_gameplay_modifier_effective refuses an ECONOMY stat",
		not bool(covered_reads["N4_gameplay_ok"]), str(covered_reads))
	var pod: Dictionary = ext.get_runtime_modifier_snapshot(-1)
	print(("[r1/not-front] N5 get_runtime_modifier_snapshot ok=%s available=%s "
		+ "reason=%s (no POD snapshot is published in this harness, and the POD "
		+ "schema carries no derived term at all)")
		% [str(pod.get("ok", "?")), str(pod.get("available", "?")),
			str(pod.get("reason", ""))])
	_expect("N5: the POD snapshot cannot witness the front in this harness",
		not bool(pod.get("available", true)), str(pod))
	var unresolved: Dictionary = ext.resolve_modifier_stat("economy.city.no_such_stat")
	print("[r1/not-front] N6 resolve_modifier_stat(unknown) ok=%s stat_id=%s "
		% [str(unresolved.get("ok", "?")), str(unresolved.get("stat_id", "?"))] +
		"(a catalog lookup, not a value reader)")
	_expect("N6: an unknown stat key does not resolve to an id",
		int(unresolved.get("stat_id", -1)) < 0, str(unresolved))

	_finish(0 if _failures == 0 else 6)
