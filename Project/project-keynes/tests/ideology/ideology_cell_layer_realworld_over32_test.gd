extends SceneTree
## REAL-WORLD >32 PRODUCTION SAMPLE (plan §18.4 / M5-52).
##
## WHY THIS FILE EXISTS
##
## `ideology_cell_layer_e2e_realworld_test.gd` measured the gap the release was
## blocked on:
##
##   [FAIL] B: at least one country owns more than 32 cells widest=1 above_cap=0
##          -- with no territory above the old cap this migration has no
##          production case
##
## Every earlier >32 proof lived on a HAND-BUILT ext (`ideology_b7_wide_territory_test.gd`
## writes its own 1600-cell territory). This fixture does the opposite: it takes a
## REAL generated world (the same `generate_world(SEED)` construction the e2e
## fixture uses -- a hand-written MapData crashes the topology capture with
## 0xC0000005), GROWS one country past the old cap through the production command
## path, equips a real derived cell card, settles it through the real handshake and
## then checks that the derived front covers EXACTLY that country's cells.
##
## THE THREE MEASUREMENTS THIS FIXTURE HAD TO MAKE FIRST
##
##   1. `COMMAND_TRANSFER_TERRITORY` is STAGED. `submit_country_commands` answers
##      `submitted=1, pending=1` and the ownership column does not move until a
##      country day commits it.
##   2. `get_country_cell_summary()` reads a REPLICA published by
##      `capture_country_runtime_snapshot()`. Without that refresh a committed
##      claim is invisible -- which is what made D4 report widest=1 after 48
##      accepted claims.
##   3. `get_country_territory_counts()` and the derived target selector both read
##      the ECONOMY epoch plane (`_epoch_cell_country`), which is frozen by
##      `capture_country_epoch` when an epoch OPENS. A claim that is committed and
##      visible in the country runtime is still invisible there until a new economy
##      day opens a new epoch. That missing step is why the e2e fixture's
##      `widest=1` was a measurement artifact rather than an absence of production
##      territory.
##
## WHAT IT PINS
##
##   A. a real world generates, a DCWorldExt is bound and the economy territory
##      plane is sized like the map (abort if not -- everything else is meaningless);
##   B. the world starts at or under the old 32-cell cap (that is the premise);
##   C. the claims commit and give one country a CONTIGUOUS territory of >32 cells
##      (`widest` is PRINTED, never assumed);
##   D. the two readers agree: the country runtime's CSR count and the economy
##      epoch plane report the same territory (`territory_count` is DERIVED from
##      the CSR offsets in `country_runtime.cpp:3886-3915`);
##   E. a derived cell card equips and settles through the real handshake
##      (dispatch_effect_native_modifier -> run_modifier_daily ->
##      ack_effect_native_modifier, with `run_modifier_daily` in between because
##      otherwise the transition never lands);
##   F. the derived front covers EXACTLY the country's cells -- every covered cell
##      is owned by it, every owned cell is covered, no neighbour contamination --
##      and the ownership selector agrees with the front independently;
##   G. the cap is genuinely exceeded: covered cells > 32 and `contribution_count`
##      is larger than any 32-capped build of the same card could produce;
##   H. NEGATIVE CONTROL: shaving cells off the territory shrinks the covered set
##      to exactly the remainder, so "coverage == territory" is not a tautology.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_realworld_over32_test.gd

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const PRODUCTION_WIDTH := 96
const PRODUCTION_HEIGHT := 64
const SEED := 20260227
## Comfortably past the old 32-cell cap, with margin for the negative control to
## still leave a >32 territory behind (44 - 8 = 36).
const TARGET_CELLS := 44
const SHRINK_CELLS := 8
## A permanent kind-12 (SELECTOR_OWN_TERRITORY) derived cell card. Its compiled
## selector is `param = (0, tag_id)`: `param[0] == 0` means "the kind's own
## default", which `resolve_selector_cell_cap` resolves to the WHOLE territory
## (`selector_cell_cap.h:102-113`), so a 32-cell policy cap cannot hide behind the
## content the way it did for every `param[0] = 32` card.
const CARD_KEY := "idea.public_hygiene"
## The card's `target_selector_tag`, compiled into `param[1]` as a 1-based id
## (`effect_domain_catalog.gd:639`).
const CARD_TAG := "cell.settlement"
## `public_hygiene_l1` writes two stats, so the front holds one contribution per
## (stat, cell): a 32-capped build of this same card could produce at most 64.
const CARD_STAT := "economy.city.birth_factor"
const COMMAND_COUNT := 2
const SELECTOR_OWN_TERRITORY := 12
const OLD_CAP := 32

const OP_GRANT_POINTS := 2
const OP_DISCOVER := 1
const OP_ADD_UNDERSTANDING := 8
const OP_EQUIP := 5
const OPCODE_TRANSFER_TERRITORY := 3
const Q16_ONE := 65536

var _checks := 0
var _failures := 0
var _seq := 0
var _day_cursor := 0
var _receipt_cursor := 0
var _host: Node = null
var _clock: Node = null
var _ext: Object = null
var _cell_count := 0
var _handle := 0
var _slot := -1
var _gate_bypassed := false


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _require(label: String, ok: bool, detail: String = "") -> bool:
	_expect(label, ok, detail)
	return ok


func _run() -> void:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	_clock = clock

	var host := WorldRuntimeHost.new()
	host.map_width = PRODUCTION_WIDTH
	host.map_height = PRODUCTION_HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = false
	host.runtime_parity_forcing = false
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	_host = host
	# A child added during `_init()` is not inside the tree yet, so
	# `generate_world()` would return silently (runtime_ideology_parity_test:81).
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "Over32 Realworld"
	config.country.foreign_count = 2
	config.base.map_width = PRODUCTION_WIDTH
	config.base.map_height = PRODUCTION_HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})
	if not _require("A: session configures", bool(session.get("ok", false)),
			str(session)):
		_finish(1)
		return

	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("A: production world generation succeeded", generator != null):
		_finish(2)
		return
	var ext = generator.get_data_core_world_ext()
	if not _require("A: production DCWorldExt is bound", ext != null):
		_finish(3)
		return
	_ext = ext

	var plane0: Dictionary = ext.get_economy_territory_plane()
	_cell_count = int(plane0.get("cell_count", 0))
	if not _require("A: the economy territory plane is sized like the map",
			_cell_count > 0 and int(plane0.get("plane_size", 0)) == _cell_count,
			str(plane0)):
		_finish(4)
		return
	print("[over32] map=%dx%d cells=%d plane_matches_map=%s"
		% [PRODUCTION_WIDTH, PRODUCTION_HEIGHT, _cell_count,
			str(plane0.get("plane_matches_cell_count", "?"))])

	# ── B: the premise ────────────────────────────────────────────────────
	var baseline := _read_territory()
	var widest_before := int(baseline.get("widest", 0))
	print("[over32] BASELINE (real generated map): countries=%d widest=%d total=%d"
		% [int(baseline.get("country_count", 0)), widest_before,
			int(baseline.get("total", 0))])
	_expect("B: the generated world starts at or under the old 32-cell cap",
		widest_before <= OLD_CAP,
		"widest=%d -- the premise of this fixture" % widest_before)
	_slot = int(baseline.get("widest_slot", -1))
	var anchor := int(baseline.get("widest_anchor", -1))
	_handle = int(baseline.get("widest_handle", 0))
	if not _require("B: the target country is resolvable",
			_handle != 0 and anchor >= 0,
			"handle=%d anchor=%d" % [_handle, anchor]):
		_teardown()
		_finish(5)
		return
	print("[over32] target country slot=%d handle=%d anchor=%d"
		% [_slot, _handle, anchor])
	var baseline_owners: Dictionary = baseline.get("owner_of", {})

	# ── C: grow a CONTIGUOUS territory past the old cap ───────────────────
	var claimed := _grow_territory(anchor, baseline_owners)
	print("[over32] claims submitted=%d (target %d cells)"
		% [claimed.size(), TARGET_CELLS])
	var country_days := _advance_country_days(1, 2)
	print("[over32] country days advanced=%d" % country_days)
	if not _require("C: the claim path is reachable (commands were staged)",
			claimed.size() > 0, str(claimed.size())):
		_teardown()
		_finish(6)
		return

	var grown := _read_territory()
	var territory := _cells_of(grown, _slot)
	var widest_after := int(grown.get("widest", 0))
	print("[over32] GROWN (country runtime): widest=%d territory=%d"
		% [widest_after, territory.size()])
	_expect("C: one country owns more than 32 cells on a REAL generated map",
		widest_after > OLD_CAP,
		"widest=%d (was %d) -- >32 is the whole point of the migration"
			% [widest_after, widest_before])
	_expect("C: the grown territory is one contiguous blob",
		_is_contiguous(territory, anchor), "cells=%d" % territory.size())
	# The authoritative single-country count comes from the CSR rebuild
	# (`country_runtime.cpp:3886-3915`), which recomputes `territory_count` from
	# the offsets of `_cell_country_slot`.
	var summary: Dictionary = ext.get_country_cell_summary(anchor)
	_expect("C: the country runtime's own territory_count agrees with its CSR",
		int(summary.get("territory_count", -1)) == territory.size(),
		"territory_count=%d csr_cells=%d"
			% [int(summary.get("territory_count", -1)), territory.size()])

	# ── D: make the ECONOMY epoch see the claim ───────────────────────────
	#
	# `get_country_territory_counts()` and the derived target selector both read
	# `_epoch_cell_country`, frozen when the epoch OPENS. The claim is committed, so
	# all that is missing is a new epoch: `sync_country_territory_to_map()` mirrors
	# the runtime column into MapData (what the host does after every claim), then
	# one economy day re-captures the country epoch (`capture_country_epoch`).
	if ext.has_method("sync_country_territory_to_map"):
		var synced: Dictionary = ext.sync_country_territory_to_map()
		print("[over32] sync_country_territory_to_map: ok=%s cells=%s"
			% [str(synced.get("ok", "?")), str(synced.get("cells", "?"))])
	_install_tag_override(CARD_TAG, territory)
	var day0 := _drive_economy_day(0)
	print("[over32] economy day 0: done=%s" % str(day0.get("done", "?")))
	var day1 := _drive_economy_day(1)
	print("[over32] economy day 1: done=%s pending_input=%s"
		% [str(day1.get("done", "?")), str(day1.get("pending_input", "?"))])
	var counts_after: Dictionary = ext.get_country_territory_counts()
	print("[over32] GROWN (economy epoch plane): %s" % str(counts_after))
	_expect("D: the economy epoch plane now reports the >32 territory too",
		int(counts_after.get("widest", 0)) > OLD_CAP,
		"widest=%d counts=%s" % [int(counts_after.get("widest", 0)),
			str(counts_after)])
	_expect("D: both readers report the same widest territory",
		int(counts_after.get("widest", 0)) == widest_after,
		"country-runtime widest=%d economy-epoch widest=%d"
			% [widest_after, int(counts_after.get("widest", 0))])
	var epoch_slot_count := _slot_count(counts_after, _slot)
	print("[over32] two readers: CSR slot %d cells=%d, epoch slot cells=%d"
		% [_slot, territory.size(), epoch_slot_count])
	_expect("D: the epoch's per-country count equals the CSR count",
		epoch_slot_count == territory.size(),
		"epoch=%d csr=%d" % [epoch_slot_count, territory.size()])
	var health_after_epochs := _economy_health()
	print("[over32] economy health after the new epochs: %s"
		% str(health_after_epochs))

	# ── E: equip the derived card and settle it ───────────────────────────
	var dense := _dense_id()
	if not _require("E: the card exists in the compiled ideology catalog",
			dense >= 0, "%s dense=%d" % [CARD_KEY, dense]):
		_teardown()
		_finish(7)
		return
	var equipped := _equip_and_settle(dense)
	if not equipped:
		# The live support gate reads real class opinion. When the card is refused
		# there, retry once against the same catalogue with the stance tables
		# zeroed -- the bypass every card-content fixture uses. Reported, not
		# hidden: the assertion detail says which gate produced the front.
		print("[over32] live support gate refused the card; retrying with the "
			+ "zeroed-stance catalogue")
		_gate_bypassed = _reconfigure_ideologies_no_gate()
		print("[over32] reconfigure_ideologies(no gate) ok=%s"
			% str(_gate_bypassed))
		if _gate_bypassed:
			equipped = _equip_and_settle(dense)
	var report: Dictionary = ext.get_ideology_report()
	_expect("E: the derived card is equipped and live", equipped,
		"%s location=%d managed=%s (support gate bypassed=%s)"
			% [CARD_KEY, _card_location(dense),
				str(report.get("managed_idea_count", "?")), str(_gate_bypassed)])

	# ── F/G: the front covers exactly the territory, past the cap ─────────
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var materialize: Dictionary = ext.get_derived_materialize_report()
	print("[over32] layer=%s" % str(layer))
	print("[over32] materialize=%s" % str(materialize))
	var contributions := int(layer.get("contribution_count", 0))
	var front_cells := int(layer.get("cell_count", 0))
	var covered := _covered_cells()
	var selector_cells := _selector_cells(anchor)
	print("[over32] FRONT: contributions=%d cells=%d covered_distinct=%d selector=%d territory=%d"
		% [contributions, front_cells, covered.size(), selector_cells.size(),
			territory.size()])
	_expect("G: the covered cell count exceeds the old 32-cell cap",
		covered.size() > OLD_CAP,
		"covered=%d -- 32 or fewer means the cap is still applied"
			% covered.size())
	_expect("G: contribution_count exceeds any 32-capped build of this card",
		contributions > OLD_CAP * COMMAND_COUNT,
		"contributions=%d vs the 32-capped ceiling %d (%d stats x 32 cells)"
			% [contributions, OLD_CAP * COMMAND_COUNT, COMMAND_COUNT])
	_expect("F: the front covers exactly the country's cells (no more, no fewer)",
		_same_set(covered, territory),
		"covered=%d territory=%d missing=%d extra=%d"
			% [covered.size(), territory.size(),
				_missing(territory, covered).size(),
				_missing(covered, territory).size()])
	_expect("F: the front's structural cell count is one per (stat, cell)",
		front_cells == covered.size() * COMMAND_COUNT and
			contributions == covered.size() * COMMAND_COUNT,
		"cells=%d contributions=%d covered=%d x %d stats"
			% [front_cells, contributions, covered.size(), COMMAND_COUNT])
	_expect("F: the ownership selector independently returns the same cells",
		_same_set(_set_of(selector_cells), territory),
		"selector=%d territory=%d" % [selector_cells.size(), territory.size()])
	_expect("F: no covered cell belongs to another country or to nobody",
		_foreign_covered(covered).is_empty(),
		"foreign covered=%s" % str(_foreign_covered(covered)))
	_expect("F: every covered cell carries the card's derived value",
		_covered_values_are_live(covered),
		"a covered cell returned derived_present=false")
	_expect("F: the derived path never truncates (12.4)",
		int(materialize.get("truncated", -1)) == 0, str(materialize))
	_expect("F: every activated program took the derived backend (I01)",
		int(materialize.get("programs_derived", 0)) > 0 and
			int(materialize.get("programs_skipped_legacy", -1)) == 0,
		str(materialize))

	# ── H: NEGATIVE CONTROL -- shrink the territory, coverage follows ─────
	#
	# Abandon the highest-index cells back to neutral through the same production
	# command (`target_handle = 0` is NEUTRAL). The territory stays >32, so the
	# control proves the covered set TRACKS the territory instead of being a
	# constant, without dropping back under the cap.
	var shrunk := _shrink_territory(territory, SHRINK_CELLS)
	var abandoned: PackedInt32Array = shrunk.get("abandoned", PackedInt32Array())
	var shrink_commits := _advance_country_days(3, 4)
	print("[over32] control: abandoned=%d commits=%d cells=%s"
		% [abandoned.size(), shrink_commits, str(abandoned)])
	var after_shrink := _read_territory()
	var reduced := _cells_of(after_shrink, _slot)
	print("[over32] control: widest=%d territory=%d"
		% [int(after_shrink.get("widest", 0)), reduced.size()])
	_expect("H: the control really shrank the territory",
		reduced.size() == territory.size() - SHRINK_CELLS,
		"before=%d after=%d" % [territory.size(), reduced.size()])
	_install_tag_override(CARD_TAG, reduced)
	_drive_economy_day(2)
	_settle_days(3)
	var layer2: Dictionary = ext.get_derived_cell_layer_report()
	var covered2 := _covered_cells()
	print("[over32] control: contributions=%d covered=%d"
		% [int(layer2.get("contribution_count", 0)), covered2.size()])
	_expect("H: the covered set follows the shrunk territory exactly",
		_same_set(covered2, reduced),
		"covered=%d territory=%d missing=%d extra=%d"
			% [covered2.size(), reduced.size(),
				_missing(reduced, covered2).size(),
				_missing(covered2, reduced).size()])
	_expect("H: the abandoned cells are no longer covered",
		_intersect(_set_of(abandoned), covered2).is_empty(),
		"still covered=%s" % str(_intersect(_set_of(abandoned), covered2)))
	_expect("H: the shrunk front is smaller but still past the old cap",
		covered2.size() < covered.size() and covered2.size() > OLD_CAP,
		"before=%d after=%d" % [covered.size(), covered2.size()])

	print("[over32] RESULT: widest=%d cells, covered=%d, contributions=%d, control_covered=%d, support_gate_bypassed=%s"
		% [widest_after, covered.size(), contributions, covered2.size(),
			str(_gate_bypassed)])
	# The `real world` path is only usable while the economy stays healthy:
	# `ideology_cell_layer_m0_realworld_cost_test.gd` dies with
	# `money_conservation_failed` once the world is too big, so this fixture keeps
	# the world modest and says out loud that the audit came back clean.
	var health := _economy_health()
	print("[over32] economy health at end: %s" % str(health))
	_expect("D: the economy stayed healthy while the territory grew",
		bool(health.get("reported", false)) and
			String(health.get("fatal_reason", "?")) == "",
		str(health))
	_teardown()
	_finish(0 if _failures == 0 else 9)


# ── territory readers ────────────────────────────────────────────────────
## Reads the country runtime's ownership column. The reads go through
## `country_query_runtime()`, which serves a REPLICA published by
## `capture_country_runtime_snapshot()`; without that refresh a committed claim is
## invisible -- which is what made D4 measure widest=1 after 48 accepted claims.
func _read_territory() -> Dictionary:
	if _ext.has_method("capture_country_runtime_snapshot"):
		_ext.capture_country_runtime_snapshot()
	var by_slot := {}
	var owner_of := {}
	for cell in range(_cell_count):
		var row: Dictionary = _ext.get_country_cell_summary(cell)
		if not bool(row.get("owned", false)):
			continue
		var slot := int(row.get("country_slot", -1))
		if slot < 0:
			continue
		var list: PackedInt32Array = by_slot.get(slot, PackedInt32Array())
		list.append(cell)
		by_slot[slot] = list
		owner_of[cell] = slot
	var widest := 0
	var widest_slot := -1
	for slot in by_slot:
		var count := (by_slot[slot] as PackedInt32Array).size()
		if count > widest:
			widest = count
			widest_slot = int(slot)
	var widest_anchor := -1
	var widest_handle := 0
	if widest_slot >= 0:
		var cells: PackedInt32Array = by_slot[widest_slot]
		widest_anchor = int(cells[0])
		widest_handle = int(_ext.get_country_cell_summary(widest_anchor).get(
			"country_handle", 0))
	return {
		"country_count": by_slot.size(), "widest": widest,
		"widest_slot": widest_slot, "widest_anchor": widest_anchor,
		"widest_handle": widest_handle, "total": owner_of.size(),
		"cells_by_slot": by_slot, "owner_of": owner_of,
	}


func _cells_of(report: Dictionary, slot: int) -> PackedInt32Array:
	var by_slot: Dictionary = report.get("cells_by_slot", {})
	if not by_slot.has(slot):
		return PackedInt32Array()
	return by_slot[slot] as PackedInt32Array


## Per-slot count from `get_country_territory_counts()`: `slots` is the slot column
## and `counts` the parallel cell counts.
func _slot_count(counts: Dictionary, slot: int) -> int:
	var slots: PackedInt64Array = counts.get("slots", PackedInt64Array())
	var values: PackedInt32Array = counts.get("counts", PackedInt32Array())
	for i in range(mini(slots.size(), values.size())):
		if int(slots[i]) == slot:
			return int(values[i])
	return -1


# ── growth / shrink through the production command path ──────────────────
## Walks the map's own neighbour graph outward from `anchor` and claims each land
## cell it meets, so the result is contiguous BY CONSTRUCTION. Every claim goes
## through `submit_country_commands(COMMAND_TRANSFER_TERRITORY)` -- the same
## command the GM click-to-claim action submits
## (`world_runtime_host.gd:3335` -> `country_facade.transfer_territory`
## -> `country_facade.gd:202-206` -> native `country_runtime.cpp:3172-3210`).
func _grow_territory(anchor: int, already_owned: Dictionary) -> PackedInt32Array:
	var claimed := PackedInt32Array()
	var owned := {anchor: true}
	var frontier := PackedInt32Array([anchor])
	var map_data: MapData = _host.current_map()
	if map_data == null:
		return claimed
	var neighbours: PackedInt32Array = map_data.neighbor_indices_packed()
	var water: PackedByteArray = map_data.is_water_arr
	var cursor := 0
	while cursor < frontier.size() and owned.size() < TARGET_CELLS:
		var cell := int(frontier[cursor])
		cursor += 1
		for i in range(6):
			if owned.size() >= TARGET_CELLS:
				break
			var index := cell * 6 + i
			if index < 0 or index >= neighbours.size():
				continue
			var neighbour := int(neighbours[index])
			if neighbour < 0 or neighbour >= _cell_count:
				continue
			if owned.has(neighbour) or already_owned.has(neighbour):
				continue
			if neighbour < water.size() and int(water[neighbour]) != 0:
				continue
			var result: Dictionary = _submit_transfer(neighbour, _handle, 1)
			if not bool(result.get("ok", false)):
				continue
			owned[neighbour] = true
			claimed.append(neighbour)
			frontier.append(neighbour)
	return claimed


## Abandons `count` cells (highest indices first, so the survivor stays contiguous)
## back to neutral: `target_handle = 0` is NEUTRAL_SLOT in the native command.
func _shrink_territory(territory: PackedInt32Array, count: int) -> Dictionary:
	var sorted := territory.duplicate()
	sorted.sort()
	var abandoned := PackedInt32Array()
	for i in range(sorted.size() - 1, -1, -1):
		if abandoned.size() >= count:
			break
		var cell := int(sorted[i])
		var result: Dictionary = _submit_transfer(cell, 0, 3)
		if not bool(result.get("ok", false)):
			continue
		abandoned.append(cell)
	return {"abandoned": abandoned, "count": abandoned.size()}


func _submit_transfer(cell: int, handle: int, day: int) -> Dictionary:
	_seq += 1
	return _ext.submit_country_commands({
		"opcodes": PackedInt32Array([OPCODE_TRANSFER_TERRITORY]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([_seq]),
		"target_handles": PackedInt64Array([handle]),
		"cell_indices": PackedInt32Array([cell]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([-1]),
		"tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_basis_points": PackedInt32Array([0]),
		"tax_assessment_modes": PackedInt32Array([1]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	})


func _advance_country_days(from_day: int, to_day: int) -> int:
	var advanced := 0
	for day in range(from_day, to_day + 1):
		for slice in range(256):
			var r: Dictionary = _ext.run_country_slice(
				{"day_index": day, "tick_index": slice})
			if bool(r.get("done", false)):
				advanced += 1
				break
			if not bool(r.get("ok", true)):
				print("[over32] country day %d stopped: %s" % [day, str(r)])
				break
	return advanced


func _drive_economy_day(day: int) -> Dictionary:
	var last := {}
	for slice in range(4096):
		last = _ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(last.get("done", false)):
			return last
		if not bool(last.get("ok", true)):
			return last
		if bool(last.get("pending_input", false)):
			return last
	return last


## Makes the card's selector tag true for the territory under test.
##
## `public_hygiene_l1` compiles its `target_selector_tag` into `param[1]` (the
## 1-based tag id), so the tag is an AND over the territory. The shipped predicate
## reads a population threshold that a freshly claimed cell does not meet, and this
## hook exists for exactly that
## (`economy_runtime_family_buff.cpp:2171-2200`). Tagging only the territory keeps
## the tag out of the ownership question: a cell the country does not own is never
## a candidate in the first place.
func _install_tag_override(tag: StringName, cells: PackedInt32Array) -> void:
	if not _ext.has_method("set_cell_tag_override_for_test"):
		return
	var accepted := 0
	var first_failure := {}
	for cell in cells:
		var res: Dictionary = _ext.set_cell_tag_override_for_test(tag, int(cell), true)
		if bool(res.get("ok", false)):
			accepted += 1
		elif first_failure.is_empty():
			first_failure = res
	print("[over32] tag override %s accepted=%d of %d %s"
		% [String(tag), accepted, cells.size(),
			("first_failure=" + str(first_failure)) if not first_failure.is_empty() else ""])


# ── ideology: equip the derived card and settle the handshake ─────────────
func _dense_id() -> int:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var country_ir: Dictionary = economy_ir.duplicate(false)
	var native: Dictionary = IdeologyCatalogScript.load_default().compile_native_catalog(
		country_ir, economy_ir)
	var ids: PackedStringArray = native.get("ideology_ids", PackedStringArray())
	return ids.find(CARD_KEY)


## Same catalogue, stance tables zeroed: the support gate always passes. Used only
## when the live gate refuses the card, and reported when it happens.
func _reconfigure_ideologies_no_gate() -> bool:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var country_ir: Dictionary = economy_ir.duplicate(false)
	var compiled: Dictionary = IdeologyCatalogScript.load_default().compile_native_catalog(
		country_ir, economy_ir)
	if not bool(compiled.get("ok", false)):
		return false
	var native := compiled.duplicate(false)
	native.erase("ok")
	var count := (native["ideology_ids"] as PackedStringArray).size()
	var zeros := PackedInt32Array()
	zeros.resize(count + 1)
	native["stance_offsets"] = zeros
	native["stance_class_indices"] = PackedInt32Array()
	native["stance_adopt_q16"] = PackedInt32Array()
	native["stance_repeal_q16"] = PackedInt32Array()
	native["stance_promote_q16"] = PackedInt32Array()
	native["stance_adopt_min_q16"] = PackedInt32Array()
	native["stance_repeal_min_q16"] = PackedInt32Array()
	native["stance_promote_min_q16"] = PackedInt32Array()
	var thresholds := PackedInt32Array()
	thresholds.resize(count)
	native["adopt_thresholds_q16"] = thresholds
	native["repeal_thresholds_q16"] = thresholds.duplicate()
	native["promote_thresholds_q16"] = thresholds.duplicate()
	native["world_seed"] = SEED
	return bool(_ext.configure_ideologies(native).get("ok", false))


func _equip_and_settle(dense: int) -> bool:
	var grant: Dictionary = _submit_ideology(OP_GRANT_POINTS, dense, 64 * Q16_ONE)
	var discover: Dictionary = _submit_ideology(OP_DISCOVER, dense, 0)
	print("[over32] ideology grant_ok=%s discover_ok=%s"
		% [str(grant.get("ok", "?")), str(discover.get("ok", "?"))])
	_settle_days(2)
	_submit_ideology(OP_ADD_UNDERSTANDING, dense, 0)
	_settle_days(1)
	var equip: Dictionary = _submit_ideology(OP_EQUIP, dense, 0)
	print("[over32] ideology equip submit=%s" % str(equip))
	_settle_days(3)
	_print_receipts()
	var location := _card_location(dense)
	var report: Dictionary = _ext.get_ideology_report()
	print("[over32] ideology: location=%d managed=%s selector_matched=%s"
		% [location, str(report.get("managed_idea_count", "?")),
			str(report.get("selector_matched_total", "?"))])
	return location > 0


## The card's location in the country snapshot. `idea_ids` / `locations` are
## SPARSE, one row per known idea, so the dense catalogue id must be SEARCHED for
## rather than used as an index -- using it as an index reported location=-999 for
## a card that was demonstrably live.
func _card_location(dense: int) -> int:
	var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
	var idea_ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = snapshot.get("locations", PackedInt32Array())
	for i in range(mini(idea_ids.size(), locations.size())):
		if int(idea_ids[i]) == dense:
			return int(locations[i])
	return -999


func _submit_ideology(opcode: int, dense: int, value: int) -> Dictionary:
	_seq += 1
	return _ext.submit_ideology_commands({
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([0]),
		"source_priorities": PackedInt32Array([0]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([_seq]),
		"country_handles": PackedInt64Array([_handle]),
		"ideology_ids": PackedInt32Array([dense]),
		"values_q16": PackedInt64Array([value]),
		"offer_generations": PackedInt64Array([0]),
		"choice_indices": PackedInt32Array([-1]),
		"gate_ids": PackedInt32Array([-1]),
	})


func _print_receipts() -> void:
	if not _ext.has_method("poll_ideology_receipts"):
		return
	var result: Dictionary = _ext.poll_ideology_receipts(_receipt_cursor, 256)
	if not bool(result.get("ok", false)):
		print("[over32] receipts unavailable: %s" % str(result))
		return
	var ids: PackedInt64Array = result.get("receipt_ids", PackedInt64Array())
	var statuses: PackedInt32Array = result.get("statuses", PackedInt32Array())
	var reasons: PackedStringArray = result.get("reasons", PackedStringArray())
	var opcodes: PackedInt32Array = result.get("opcodes", PackedInt32Array())
	for i in range(ids.size()):
		_receipt_cursor = maxi(_receipt_cursor, int(ids[i]))
		print("[over32] receipt op=%d status=%d reason=%s"
			% [int(opcodes[i]) if i < opcodes.size() else -1,
				int(statuses[i]) if i < statuses.size() else -1,
				String(reasons[i]) if i < reasons.size() else ""])


## One production ideology day plus the mandatory modifier handshake and a derived
## drain. `run_modifier_daily` between dispatch and ack is what lets the card's
## transition settle; without it the transition never lands. The day index only
## ever moves forward (`run_ideology_daily` requires monotonic days).
func _settle_days(count: int) -> void:
	for _i in range(count):
		var day := _day_cursor
		_day_cursor += 1
		for _slice in range(16):
			var ideology_slice: Dictionary = _ext.run_ideology_daily(day)
			if not bool(ideology_slice.get("ok", false)):
				print("[over32] ideology day %d failed: %s" % [day, str(ideology_slice)])
				break
			if bool(ideology_slice.get("done", false)):
				break
		for _slice in range(16):
			var effect_slice: Dictionary = _ext.run_effect_daily(day)
			if not bool(effect_slice.get("ok", true)):
				break
			if bool(effect_slice.get("done", true)):
				break
		_ext.dispatch_effect_native_modifier()
		_ext.run_modifier_daily(day)
		_ext.ack_effect_native_modifier()
		var drained: Dictionary = _ext.drain_derived_cell_layer(day)
		if _i == 0:
			print("[over32] derived drain day %d: steps=%s complete=%s"
				% [day, str(drained.get("steps", "?")),
					str(drained.get("complete", "?"))])


# ── economy health ───────────────────────────────────────────────────────
## The `real world` path is only usable while the economy stays healthy:
## `ideology_cell_layer_m0_realworld_cost_test.gd` dies with
## `money_conservation_failed` once the world is too big. `report()` carries the
## runtime's own `fatal_reason`, so this is the audit hook that actually exists
## (there is no `get_economy_audit` binding in this build).
func _economy_health() -> Dictionary:
	if not _ext.has_method("get_economy_report"):
		return {"reported": false}
	var report: Dictionary = _ext.get_economy_report()
	return {
		"reported": report.has("fatal_reason"),
		"fatal_reason": String(report.get("fatal_reason", "")),
		"committed_day": int(report.get("committed_day", -1)),
		"epoch_active": bool(report.get("epoch_active", false)),
		"mode": String(report.get("runtime_mode", report.get("mode", ""))),
	}


# ── front readers ────────────────────────────────────────────────────────## The cells the derived front actually serves: `get_effective_stat_value` answers
## `derived_present` straight from the derived front's row for that cell
## (`world_ext_modifier.cpp:798-826`), so this is a per-cell view of exactly the
## front `get_derived_cell_layer_report()` counts, plus the merged value.
func _covered_cells() -> Dictionary:
	var out := {}
	for cell in range(_cell_count):
		var probe: Dictionary = _ext.get_effective_stat_value(CARD_STAT, cell, 0, 1.0)
		if bool(probe.get("derived_present", false)):
			out[cell] = true
	return out


## Independent third reader: the ownership selector the card resolves through,
## asked directly (`world_ext_ideology.cpp:621-634`). `param1 = 0` means "no tag
## filter", i.e. the whole territory of whatever country owns the anchor.
func _selector_cells(anchor: int) -> PackedInt32Array:
	if not _ext.has_method("query_effect_target_cells"):
		return PackedInt32Array()
	return _ext.query_effect_target_cells(anchor, SELECTOR_OWN_TERRITORY, 0, 0)


func _covered_values_are_live(covered: Dictionary) -> bool:
	for cell in covered:
		var probe: Dictionary = _ext.get_effective_stat_value(CARD_STAT, int(cell), 0, 1.0)
		if absf(float(probe.get("value", 1.0)) - 1.0) <= 1e-9:
			return false
	return true


func _foreign_covered(covered: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in covered:
		var row: Dictionary = _ext.get_country_cell_summary(int(cell))
		if not bool(row.get("owned", false)) or int(row.get("country_slot", -2)) != _slot:
			out.append(int(cell))
	return out


# ── set helpers ──────────────────────────────────────────────────────────
func _set_of(cells: PackedInt32Array) -> Dictionary:
	var out := {}
	for cell in cells:
		out[int(cell)] = true
	return out


func _same_set(a: Dictionary, b) -> bool:
	var other: Dictionary = b if b is Dictionary else _set_of(b)
	if a.size() != other.size():
		return false
	for key in a:
		if not other.has(key):
			return false
	return true


func _missing(want, have) -> PackedInt32Array:
	var have_set: Dictionary = have if have is Dictionary else _set_of(have)
	var want_set: Dictionary = want if want is Dictionary else _set_of(want)
	var out := PackedInt32Array()
	for key in want_set:
		if not have_set.has(key):
			out.append(int(key))
	return out


## Cells present in BOTH sets. `_missing` is `want - have`; this is `want & have`,
## which is what "these cells are no longer covered" has to ask.
func _intersect(a, b) -> PackedInt32Array:
	var a_set: Dictionary = a if a is Dictionary else _set_of(a)
	var b_set: Dictionary = b if b is Dictionary else _set_of(b)
	var out := PackedInt32Array()
	for key in a_set:
		if b_set.has(key):
			out.append(int(key))
	return out


## Contiguity by BFS over the map's own neighbour graph, restricted to the set.
func _is_contiguous(cells: PackedInt32Array, anchor: int) -> bool:
	if cells.size() <= 1:
		return true
	var in_set := _set_of(cells)
	var map_data: MapData = _host.current_map()
	if map_data == null:
		return false
	var neighbours: PackedInt32Array = map_data.neighbor_indices_packed()
	var seed_cell := anchor if in_set.has(anchor) else int(cells[0])
	var seen := {seed_cell: true}
	var frontier := PackedInt32Array([seed_cell])
	var cursor := 0
	while cursor < frontier.size():
		var cell := int(frontier[cursor])
		cursor += 1
		for i in range(6):
			var index := cell * 6 + i
			if index < 0 or index >= neighbours.size():
				continue
			var neighbour := int(neighbours[index])
			if neighbour < 0 or not in_set.has(neighbour) or seen.has(neighbour):
				continue
			seen[neighbour] = true
			frontier.append(neighbour)
	return seen.size() == in_set.size()


func _teardown() -> void:
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
		_host = null
	if _clock != null and is_instance_valid(_clock):
		_clock.queue_free()
		_clock = null


func _finish(code: int) -> void:
	print("=== cell layer realworld over32: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
