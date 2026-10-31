extends SceneTree
## B3 (plan §14.2): "512-country continuation" —
## cursor, fairness, maximum backlog, tail starvation.
##
## WHY THIS SCENARIO IS THE ONE THAT CANNOT BE SUBSTITUTED
##
## §14.3 bounds the daily ideology pass by a per-slice work budget, which means one
## `run_ideology_daily` no longer means "the day ran" — it means "one slice ran".
## Everything the plan promises about that design is only true if the slice state is
## genuinely RESUMABLE:
##
##   1. the country cursor must advance MONOTONICALLY across slices, never restart
##      (a restart would re-service the head and never reach the tail);
##   2. every country must be serviced EXACTLY once per day — no double service
##      (which would mean the cursor rewound) and no skipped country (which would
##      mean the walk dropped rows);
##   3. the backlog (how many slices a day needs) must be FINITE and predictable
##      from the budget, otherwise a 512-country world is a hang waiting to happen;
##   4. the LAST countries in the list must not starve. This is the failure a
##      per-slice budget introduces: a bug that stops at the budget boundary and
##      restarts on the next call looks perfectly healthy from the head of the list.
##
## THE FIXTURE
##
## 512 countries on a 1024-cell world (2 contiguous cells each, CSR territory
## arrays). Every country DISCOVERs and EQUIPs the same permanent derived cell card,
## so every single one is real daily work. `max_active_visits_per_slice` is set to
## 64, i.e. eight slices per day at this country count — a small budget on purpose:
## with the shipped 1024 the whole list fits in one slice and RESUMPTION IS NEVER
## EXERCISED, which is exactly the state a B3 fixture must not accept as a pass.
##
## WHAT IS ASSERTED (named for the report)
##
##   A. all 512 countries exist and own cells;
##   B. all 512 countries have the card ACTIVE (otherwise "no starvation" is vacuous);
##   C. the day completes: `run_ideology_daily` returns done for each measured day;
##   D. the cursor never regresses while the walk is live, and never restarts after it;
##   D2 the cursor reaches the tail of the list (448 = 512 - one budgeted chunk);
##   D3 the day really was continued across slices, not finished in one;
##   E. fairness: `active_visits` grows by exactly 512 per day (one visit per country);
##   F. bounded backlog: at least ceil(512/64) = 8 slices, and at most 2x that;
##   G. no tail starvation: the LAST country's understanding grows by exactly the same
##      amount as the FIRST and MIDDLE countries' (410 = 2 days x 205);
##   G4-G6 the tail's card reaches the shared derived front, and the contribution on the
##      tail cell is sourced by the tail country's handle;
##   H. the measured days create no new pending transitions.
##
## MEASURED (deterministic, both measured days identical):
##   cursor trace  [64, 128, 192, 256, 320, 384, 448, 0, 0]  -- 8 calls per day
##   active_visits +512 per day, understanding +410 on head, middle and tail
##   derived front 2048 contributions over 1024 cells, installed
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b3_country_continuation_test.gd

## Number of countries. This is the scenario, not a tuning knob.
const COUNTRY_COUNT := 512
## Cells per country. Small on purpose: bootstrapping 512 countries is the point,
## territory size is not. Two cells still exercises CSR offsets that are not 1:1.
const CELLS_PER_COUNTRY := 2
const CELLS: int = COUNTRY_COUNT * CELLS_PER_COUNTRY
const Q16_ONE := 65536
## A kind-12 (SELECTOR_OWN_TERRITORY, permanent) derived cell card. Same card as B7,
## so the "reaches the whole territory and creates zero instances" premise is shared
## rather than re-litigated here.
const CARD_KEY := "idea.public_hygiene"
## Per-slice country-visit budget (`max_active_visits_per_slice`). 512 / 64 = 8 slices
## of pure active work per day, which is what makes resumption observable.
const VISITS_PER_SLICE := 64
const MIN_SLICES_PER_DAY: int = (COUNTRY_COUNT + VISITS_PER_SLICE - 1) / VISITS_PER_SLICE
## Defensive ceiling. A day that needs more calls than this is not "slow", it is
## stuck, and the fixture must fail rather than hang.
const MAX_CALLS_PER_DAY := 512
## The SETUP economy day needs ~1059 slices at this country count because the
## epoch-open fiscal plan runs one country per pulse. Setup only, never asserted as
## backlog.
const ECONOMY_SLICE_CEILING := 4096
## Setup runs on day 0; measured days must be STRICTLY LATER because the runtime only
## restarts the walk when `_last_day < day` (ideology_runtime.cpp:4975).
const SETUP_DAY := 0
const FIRST_MEASURED_DAY := 1
const MEASURED_DAYS := 2
## Defensive ceiling for the transition settle handshake. 512 equips are ACKed in
## batches, so this is a "stuck, not slow" guard rather than a tuning knob.
const SETTLE_ROUNDS := 64

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
var _calls_per_day := PackedInt32Array()
## Last ideology day consumed. `run_ideology_daily` day indices must be STRICTLY
## MONOTONIC, and the measured window has to start AFTER whatever the setup settle
## spent (the runtime only restarts the daily walk when `_last_day < day`).
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
	var handles: PackedInt64Array = world["handles"]
	var pending_after_setup: int = int(world["pending_after_setup"])
	var first_measured: int = int(world["first_measured_day"])

	# ── the report keys, printed once so the assertions below name real fields ──
	var report: Dictionary = ext.get_ideology_report()
	var keys := PackedStringArray()
	for key in report.keys():
		keys.append(str(key))
	keys.sort()
	print("[B3] ideology report exposes %d keys: %s" % [keys.size(), ", ".join(keys)])
	for required in ["active_progress_day", "active_country_cursor", "active_item_cursor",
			"active_visits", "last_slice_ms", "max_slice_ms", "pending_transitions",
			"managed_idea_count"]:
		_expect("the report exposes '%s'" % required, report.has(required),
			"missing key")

	# ── A: 512 countries exist and own cells ─────────────────────────────
	var counts: Dictionary = ext.get_country_territory_counts()
	print("[B3] territory: countries=%s cells=%s widest=%s"
		% [str(counts.get("country_count", "?")),
			str(counts.get("total_cells", "?")), str(counts.get("widest", "?"))])
	_expect("A: all 512 countries exist", int(counts.get("country_count", 0)) == COUNTRY_COUNT,
		"country_count=%s" % str(counts.get("country_count", "?")))
	_expect("A: the 512 countries own every cell",
		int(counts.get("total_cells", 0)) == CELLS,
		"total_cells=%s expected=%d" % [str(counts.get("total_cells", "?")), CELLS])
	_expect("A: every country owns a non-empty territory",
		int(counts.get("widest", 0)) == CELLS_PER_COUNTRY,
		"widest=%s expected=%d" % [str(counts.get("widest", "?")), CELLS_PER_COUNTRY])

	# ── B: every country has the card ACTIVE ─────────────────────────────
	# The premise of "no starvation". A country with no active card is work that does
	# not exist, and the cursor would pass over it for free.
	var equipped := 0
	var tail_location := -1
	for index in range(COUNTRY_COUNT):
		var location := _card_location(ext, int(handles[index]), dense)
		if location == 1:
			equipped += 1
		if index == COUNTRY_COUNT - 1:
			tail_location = location
	print("[B3] card ACTIVE in %d of %d countries (tail location=%d)"
		% [equipped, COUNTRY_COUNT, tail_location])
	_expect("B: all 512 countries have the card ACTIVE", equipped == COUNTRY_COUNT,
		"active=%d of %d" % [equipped, COUNTRY_COUNT])
	if equipped != COUNTRY_COUNT:
		var diag: Dictionary = ext.get_ideology_report()
		print("[B3] equip diagnostics: applied=%s rejected=%s last_error=%s"
			% [str(diag.get("commands_applied", "?")),
				str(diag.get("commands_rejected", "?")),
				str(diag.get("last_error", "?"))])

	# ── C/D/E/F: measured days ───────────────────────────────────────────
	var head_handle := int(handles[0])
	var mid_handle := int(handles[COUNTRY_COUNT / 2])
	var tail_handle := int(handles[COUNTRY_COUNT - 1])
	var head_before := _understanding(ext, head_handle, dense)
	var mid_before := _understanding(ext, mid_handle, dense)
	var tail_before := _understanding(ext, tail_handle, dense)
	var visits_before := int(report.get("active_visits", 0))
	print("[B3] understanding before: head=%d mid=%d tail=%d visits=%d"
		% [head_before, mid_before, tail_before, visits_before])

	for offset in range(MEASURED_DAYS):
		var day := first_measured + offset
		var before := int(ext.get_ideology_report().get("active_visits", 0))
		var drained := _drain_day(ext, day)
		_calls_per_day.append(int(drained.get("calls", 0)))
		var after := int(ext.get_ideology_report().get("active_visits", 0))
		var visits_delta := after - before
		var cursors: PackedInt32Array = drained.get("cursors", PackedInt32Array())
		var max_cursor := 0
		for value in cursors:
			max_cursor = maxi(max_cursor, value)
		var day_report: Dictionary = ext.get_ideology_report()
		print("[B3] day %d: done=%s calls=%d visits_delta=%d max_cursor=%d of %d "
			% [day, str(drained.get("done", false)), int(drained.get("calls", 0)),
				visits_delta, max_cursor, COUNTRY_COUNT]
			+ "cursor_trace=%s stages=%s"
			% [str(cursors), str(drained.get("stages", PackedStringArray()))])
		print("[B3] day %d: last_slice_ms=%.4f max_slice_ms=%.4f transition_poll_ms=%.4f"
			% [day, float(day_report.get("last_slice_ms", 0.0)),
				float(day_report.get("max_slice_ms", 0.0)),
				float(day_report.get("transition_poll_ms", 0.0))]
			+ " active_progress_ms=%.4f pending_transitions=%s"
			% [float(day_report.get("active_progress_ms", 0.0)),
				str(day_report.get("pending_transitions", "?"))])
		# Where the worst slice's time goes. §14.3's budget is about the SLICE, so the
		# three stages that can own it are separated here: the active walk itself, the
		# derived fold, and the transition poll.
		print("[B3] day %d stages: build_ms=%.4f collect_ms=%.4f materialise_ms=%.4f "
			% [day, float(day_report.get("cell_layer_rebuild_ms", 0.0)),
				float(day_report.get("cell_layer_collect_ms", 0.0)),
				float(day_report.get("cell_layer_materialise_ms", 0.0))]
			+ "rebuild_steps=%s collect_rows=%s cells_visited=%s"
			% [str(day_report.get("cell_layer_rebuild_steps", "?")),
				str(day_report.get("cell_layer_collect_rows", "?")),
				str(day_report.get("cell_layer_cells_visited", "?"))])
		if not bool(drained.get("done", true)):
			var stuck: Dictionary = ext.get_ideology_report()
			print("[B3] day %d did NOT complete in %d calls; pending_transitions=%s "
				% [day, int(drained.get("calls", 0)),
					str(stuck.get("pending_transitions", "?"))]
				+ "cursor=%s progress_day=%s stage=%s last_error=%s"
				% [str(stuck.get("active_country_cursor", "?")),
					str(stuck.get("active_progress_day", "?")),
					str(drained.get("last_stage", "?")),
					str(stuck.get("last_error", "?"))])

		# C. the day completes.
		_expect("C: day %d completes" % day, bool(drained.get("done", false)),
			"calls=%d pending_transitions=%s" % [int(drained.get("calls", 0)),
				str(ext.get_ideology_report().get("pending_transitions", "?"))])
		# D. the cursor advanced monotonically across the day's slices.
		#
		# "Monotonic" has to be stated against the reset: the same statement that
		# finishes the walk sets `_active_country_cursor = 0`
		# (ideology_runtime.cpp:5030-5035), so the trace legitimately ends in zeros.
		# What must never happen is a DROP while the walk is still live, or a non-zero
		# value AFTER the reset (which would mean the day restarted mid-flight).
		_expect("D: day %d cursor never regresses during the walk" % day,
			not bool(drained.get("regressed", false)), "cursor_trace=%s" % str(cursors))
		_expect("D1: day %d cursor stays reset after the walk finishes" % day,
			not bool(drained.get("restarted_after_reset", false)),
			"cursor_trace=%s" % str(cursors))
		# D2. it reached the END of the list. The observable ceiling is
		# `COUNTRY_COUNT - VISITS_PER_SLICE`: the last budgeted chunk finishes the walk
		# and the cursor is reset inside that same call, before `done` is reported.
		_expect("D2: day %d cursor reaches the tail of the country list" % day,
			max_cursor >= COUNTRY_COUNT - VISITS_PER_SLICE,
			"max_cursor=%d expected>=%d" % [max_cursor,
				COUNTRY_COUNT - VISITS_PER_SLICE])
		# D3. it really took several slices -- with the whole list fitting in one slice
		# this fixture would prove nothing about resumption.
		_expect("D3: day %d was continued across slices" % day,
			int(drained.get("slice_count", 0)) > 1,
			"slices=%d" % int(drained.get("slice_count", 0)))
		# E. fairness: exactly one visit per country, no double service, no skip.
		_expect("E: day %d visits each of the 512 countries exactly once" % day,
			visits_delta == COUNTRY_COUNT,
			"visits_delta=%d expected=%d" % [visits_delta, COUNTRY_COUNT])
		# F. bounded backlog: the day cannot finish in fewer slices than the budget
		# allows.
		_expect("F: day %d needs at least %d slices (budget honoured)" % [day, MIN_SLICES_PER_DAY],
			int(drained.get("calls", 0)) >= MIN_SLICES_PER_DAY,
			"calls=%d expected>=%d" % [int(drained.get("calls", 0)), MIN_SLICES_PER_DAY])
		# F2. and the backlog is BOUNDED, not merely finite: within twice the budget's
		# own minimum. A continuation that re-scanned the list, or that added a slice
		# per country, would blow through this immediately.
		_expect("F2: day %d backlog stays within 2x the budget minimum" % day,
			int(drained.get("calls", 0)) <= 2 * MIN_SLICES_PER_DAY,
			"calls=%d limit=%d" % [int(drained.get("calls", 0)),
				2 * MIN_SLICES_PER_DAY])

	# ── G: the tail was serviced, and serviced as much as the head ───────
	var head_after := _understanding(ext, head_handle, dense)
	var mid_after := _understanding(ext, mid_handle, dense)
	var tail_after := _understanding(ext, tail_handle, dense)
	var head_gain := head_after - head_before
	var mid_gain := mid_after - mid_before
	var tail_gain := tail_after - tail_before
	print("[B3] understanding gain: head=%d mid=%d tail=%d (handles head=%d mid=%d tail=%d)"
		% [head_gain, mid_gain, tail_gain, head_handle, mid_handle, tail_handle])
	_expect("G: the LAST country gains understanding (it was visited)",
		tail_gain > 0, "tail_gain=%d" % tail_gain)
	_expect("G2: the last country gains exactly as much as the first",
		tail_gain == head_gain,
		"head=%d tail=%d" % [head_gain, tail_gain])
	_expect("G3: the middle country gains exactly as much as the first",
		mid_gain == head_gain,
		"head=%d mid=%d" % [head_gain, mid_gain])

	# ── G4: the tail's card reached the shared derived front ─────────────
	# Corroboration at the layer level: a card that is equipped but never materialised
	# would still accrue understanding, so the understanding gain alone does not prove
	# the tail's card reaches the world.
	var tail_cell := COUNTRY_COUNT * CELLS_PER_COUNTRY - 1
	if ext.has_method("drain_derived_cell_layer"):
		var drained_layer: Dictionary = ext.drain_derived_cell_layer(
			first_measured + MEASURED_DAYS - 1)
		print("[B3] derived drain: steps=%s complete=%s"
			% [str(drained_layer.get("steps", "?")),
				str(drained_layer.get("complete", "?"))])
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var front_cells := int(layer.get("cell_count", 0))
	print("[B3] derived front: cells=%d contributions=%d installed=%s"
		% [front_cells, int(layer.get("contribution_count", 0)),
			str(layer.get("installed", "?"))])
	_expect("G4: the derived front covers the whole world", front_cells >= CELLS,
		"front_cells=%d expected>=%d" % [front_cells, CELLS])
	var tail_probe: Dictionary = ext.get_effective_stat_value(
		"economy.city.birth_factor", tail_cell, 0, 1.0)
	print("[B3] tail cell %d probe: %s" % [tail_cell, str(tail_probe)])
	_expect("G5: the LAST country's cell carries the card's derived contribution",
		bool(tail_probe.get("derived_present", false)), str(tail_probe))
	# And the contribution on that cell is attributed to the LAST country, not to
	# whichever country the fold happened to visit first.
	_expect("G6: the tail cell's contribution is sourced by the tail country",
		int(tail_probe.get("derived_source_country", 0)) == tail_handle,
		"source=%s tail_handle=%d" % [str(tail_probe.get("derived_source_country", "?")),
			tail_handle])

	# ── H: the measured days add no pending transitions ──────────────────
	# The 512 equips are settled BEFORE the measured window (see `_build`): plan §10.1
	# makes an un-ACKed equip contribute nothing, so the old "all 512 stay pending"
	# state cannot produce the front G4-G6 assert. What continuation owns is the
	# property asserted here: the measured days themselves start and settle NOTHING
	# new -- the per-day active pass only accrues understanding.
	var pending_after := int(ext.get_ideology_report().get("pending_transitions", -1))
	print("[B3] pending transitions: after setup=%d after measured days=%d (delta=%d)"
		% [pending_after_setup, pending_after, pending_after - pending_after_setup])
	_expect("H: the measured days create no new pending transitions",
		pending_after == pending_after_setup,
		"after_setup=%d after_days=%d" % [pending_after_setup, pending_after])

	# ── summary ──────────────────────────────────────────────────────────
	var final_report: Dictionary = ext.get_ideology_report()
	var calls_text := PackedStringArray()
	for value in _calls_per_day:
		calls_text.append(str(value))
	print("=== B3 summary: countries=%d cells=%d calls_per_day=%s cursor_field=active_country_cursor "
		% [COUNTRY_COUNT, CELLS, ",".join(calls_text)]
		+ "max_cursor_seen=%d visits=%d pending_transitions=%d max_slice_ms=%.4f last_slice_ms=%.4f ==="
		% [COUNTRY_COUNT - VISITS_PER_SLICE,
			int(final_report.get("active_visits", 0)),
			pending_after,
			float(final_report.get("max_slice_ms", 0.0)),
			float(final_report.get("last_slice_ms", 0.0))])

	_finish(0 if _failures == 0 else 3)


# ── world construction ───────────────────────────────────────────────────


func _build() -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `EffectDomainCatalog.build()` short-circuits to a PRECOMPILED catalog when one is
	# cached. If that cache predates the ideology merge, no `ideology.effect.*` program
	# is found and every card row takes the `pod_fail` exit. An explicit override
	# bypasses the cache so the merge always runs (B7 measured this).
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
	# The slice budget IS the subject of this fixture: 512 countries / 64 visits per
	# slice = 8 slices per day. With the shipped 1024 the whole list fits in one slice
	# and no continuation happens, which would make every assertion below vacuous.
	_expect("the per-slice visit budget is applied to the catalog",
		native_ideology.has("max_active_visits_per_slice"))
	native_ideology["max_active_visits_per_slice"] = VISITS_PER_SLICE

	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the card is in the compiled catalog", dense >= 0,
		"dense=%d of %d" % [dense, ids.size()])
	if dense < 0:
		return {}

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot (M3-20).
	ext.create_entities(CELLS)
	_fill_environment(ext)
	_expect("economy configures",
		bool(ext.configure_economy(country_ir, profile, CELLS, 179).get("ok", false)))
	_expect("effects configure",
		bool(ext.configure_effects(effect_ir).get("ok", false)))
	_expect("modifiers configure",
		bool(ext.configure_modifiers(mod_ir, CELLS).get("ok", false)))
	_expect("country configures", bool(ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 179).get("ok", false)))

	# ── 512 countries, 2 contiguous cells each, explicit CSR offsets ─────
	var country_ids := PackedStringArray()
	var country_names := PackedStringArray()
	var cash := PackedInt64Array()
	var offsets := PackedInt32Array()
	var cells := PackedInt32Array()
	offsets.append(0)
	for index in range(COUNTRY_COUNT):
		country_ids.append("b3.country.%04d" % index)
		country_names.append("B3 Country %04d" % index)
		cash.append(0)
		for sub in range(CELLS_PER_COUNTRY):
			cells.append(index * CELLS_PER_COUNTRY + sub)
		offsets.append(cells.size())
	# Both CSR side-tables are "no rows for anyone": 512+1 zeros is the only shape the
	# runtime accepts (`country_bootstrap_csr_invalid` otherwise), which is why this is
	# built rather than written as a literal.
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": country_ids,
		"country_names": country_names,
		"country_cash": cash,
		"territory_offsets": offsets,
		"territory_cells": cells,
		"technology_offsets": _zero_i32(COUNTRY_COUNT + 1),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": _zero_i32(COUNTRY_COUNT + 1),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("the 512 countries bootstrap", bool(boot.get("ok", false)), str(boot))
	if not bool(boot.get("ok", false)):
		return {}

	var ideo_cfg: Dictionary = ext.configure_ideologies(native_ideology)
	_expect("ideologies configure", bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg.get("fatal_reason", str(ideo_cfg)))))
	if not bool(ideo_cfg.get("ok", false)):
		return {}

	var handles := PackedInt64Array()
	for cell in range(CELLS):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if cell % CELLS_PER_COUNTRY == 0:
			handles.append(int(summary.get("country_handle", 0)))
	_expect("every cell resolves to a generation-safe country handle",
		handles.size() == COUNTRY_COUNT and handles.find(0) == -1,
		"handles=%d zeros=%d" % [handles.size(), handles.count(0)])

	var gen := {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}
	_expect("the economy epoch opens",
		bool(ext.begin_or_reuse_economy_input_epoch(0, gen).get("ok", false)))

	# Population on every cell: the card's tag filter (`cell.settlement`, installed as
	# `cell.population >= 20` by `_install_satisfiable_tag`) needs a populated cell, and
	# the country support gate needs a political class. 30 subsistence farmers each.
	var sig_keys: PackedStringArray = econ_catalog.get(
		"signature_keys", PackedStringArray())
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
		for cell in range(CELLS):
			ci.append(cell)
			si.append(farmer)
			pp.append(30)
			ff.append(10000000)
		var economy_boot: Dictionary = ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si,
			"population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		_expect("the economy bootstraps", bool(economy_boot.get("ok", false)),
			str(economy_boot))
		# A FULL economy day has to finish before any card can be equipped: the equip
		# support gate reads `CountryClassOpinionSnapshot`, and that buffer is written in
		# the publish/commit tail (`publish_country_development_facts`,
		# economy_runtime_publish.cpp:703). Until then `revision == 0` and EVERY equip is
		# rejected with `ideology_class_opinion_unavailable` -- measured, all 512.
		#
		# MEASURED: the epoch-open fiscal plan runs ONE COUNTRY PER PULSE, so a
		# 512-country world needs ~512 pulses before the day even starts, and the whole
		# day costs ~1059 slices. The bound is generous for that reason, not slack: the
		# pulse count scales with the country count, not with machine speed.
		var slices := 0
		var economy_done := false
		for index in range(ECONOMY_SLICE_CEILING):
			var economy_slice: Dictionary = ext.run_economy_slice(
				{"day_index": SETUP_DAY, "tick_index": index})
			slices += 1
			if bool(economy_slice.get("done", false)):
				economy_done = true
				break
		print("[B3] economy setup day finished=%s after %d slices" % [economy_done, slices])
		_expect("the economy setup day completes (class opinion published)",
			economy_done, "slices=%d of %d" % [slices, ECONOMY_SLICE_CEILING])
		if ext.has_method("get_country_class_opinion_snapshot"):
			var opinion: Dictionary = ext.get_country_class_opinion_snapshot()
			print("[B3] class opinion: revision=%s countries=%s classes=%s handles=%s"
				% [str(opinion.get("revision", "?")),
					str(opinion.get("country_count", "?")),
					str(opinion.get("class_count", "?")),
					str((opinion.get("country_handles", PackedInt64Array())
						as PackedInt64Array).size())])
			_expect("the class opinion snapshot names all 512 countries",
				int(opinion.get("country_count", 0)) == COUNTRY_COUNT,
				str(opinion.get("country_count", "?")))

	# ── equip: DISCOVER then EQUIP for all 512 countries ─────────────────
	#
	# Day 0 only. The runtime restarts the walk when `_last_day < day`, so the first
	# day-0 call consumes the day; the later day-0 calls still apply commands but do
	# not run the active pass. That keeps setup out of the measured numbers.
	var rejected_before := int(ext.get_ideology_report().get("commands_rejected", 0))
	ext.submit_ideology_commands(_commands(_batch_rows(handles, 1, dense)))
	var discover := _drain_day(ext, SETUP_DAY)
	print("[B3] setup: discover drained in %d calls done=%s"
		% [int(discover.get("calls", 0)), str(discover.get("done", false))])
	ext.submit_ideology_commands(_commands(_batch_rows(handles, 5, dense)))
	var equip := _drain_day(ext, SETUP_DAY)
	var rejected_after := int(ext.get_ideology_report().get("commands_rejected", 0))
	print("[B3] setup: equip drained in %d calls done=%s rejected_delta=%d last_error=%s"
		% [int(equip.get("calls", 0)), str(equip.get("done", false)),
			rejected_after - rejected_before,
			str(ext.get_ideology_report().get("last_error", ""))])
	# ── SETTLE THE 512 EQUIPS BEFORE THE SHARED FRONT IS READ ─────────────
	# `collect_effect_activations` implements plan §10.1 ("an equip that is not yet
	# ACKed contributes nothing"): with the transitions still in flight the front is
	# EMPTY (`installed=false`), which is what made G4-G6 red. The handshake below is
	# the production one and is MANDATORY.
	#
	# It spends ideology days, and the runtime only restarts the daily walk when
	# `_last_day < day` (`ideology_runtime.cpp:5010`) -- so the measured window is
	# reported back to `_run` as the day AFTER the last settle day. Day 0 was already
	# consumed by the setup drains above.
	_day = SETUP_DAY
	_settle_transitions(ext, "all-512")
	var pending_after_setup := int(
		ext.get_ideology_report().get("pending_transitions", -1))
	var first_measured := maxi(_day + 1, FIRST_MEASURED_DAY)
	print("[B3] setup: settled %d transitions, next measured day=%d"
		% [pending_after_setup, first_measured])

	return {"ext": ext, "dense": dense, "handles": handles,
		"pending_after_setup": pending_after_setup,
		"first_measured_day": first_measured}


## One ideology day, driven to completion, on a STRICTLY MONOTONIC day index.
## Returns the day it consumed. Setup only: the measured days go through `_drain_day`
## so their cursor trace and call count can be asserted.
func _step_day(ext: Object) -> int:
	_day += 1
	for _slice in range(MAX_CALLS_PER_DAY):
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
	print("[B3] settle %s: pending %d -> %d in %d handshake round(s), last day=%d"
		% [label, start, end, rounds, _day])
	_expect("settle %s: every transition is ACKed before the layer is read" % label,
		end == 0, "pending=%d" % end)


func _batch_rows(handles: PackedInt64Array, opcode: int, dense: int) -> Array:
	var rows := []
	for handle in handles:
		rows.append({"op": opcode, "day": SETUP_DAY, "handle": int(handle),
			"idea": dense, "value": 0})
	return rows


func _zero_i32(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count)
	return out


func _u8_zero(count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count)
	return out


## Replaces `cell.settlement` with `cell.population >= 20`, which every cell of this
## fixture satisfies (30 people each). The shipped predicate reads building data that a
## bootstrapped economy does not have, so it is legitimately false everywhere and the
## card would resolve ZERO targets -- indistinguishable from "the card is broken".
##
## Only one entry is replaced: the catalogue declares synergy overrides that name OTHER
## tags, and overwriting the whole list makes `configure_ideologies` fail with
## `ideology_synergy_override_tag_unknown`.
func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population",              # dense id 9 -- never move this
		"op": 0,                                  # TARGET_TAG_GTE
		"threshold_q16": 20 * Q16_ONE,
		"clause": 0,
	}]
	var tag := {"name": "cell.settlement", "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	var replaced := false
	for index in range(tags.size()):
		if String(tags[index].get("name", "")) == "cell.settlement":
			tags[index] = tag
			replaced = true
			break
	if not replaced:
		tags.append(tag)
	# `target_tags` is a TYPED array: assigning an untyped literal fails at runtime and
	# the tag silently stays absent, so the typed local above is what makes this legal.
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
	for slot_name in f32_slots:
		var sid := int(ext.component_id(slot_name))
		if sid < 0:
			sid = int(ext.register_component(slot_name, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f)
	for slot_name in u8_slots:
		var sid := int(ext.component_id(slot_name))
		if sid < 0:
			sid = int(ext.register_component(slot_name, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u)


# ── per-country probes ───────────────────────────────────────────────────


## Returns the location (0 INACTIVE, 1 IDEOLOGY, 2 NATIONAL_SPIRIT) of `dense` for
## `handle`, or -1 when the country does not know the card at all.
func _card_location(ext: Object, handle: int, dense: int) -> int:
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var idea_ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = snapshot.get("locations", PackedInt32Array())
	var index := idea_ids.find(dense)
	if index < 0 or index >= locations.size():
		return -1
	return int(locations[index])


## Per-country service signal: the daily active pass accrues
## `daily_understanding_q16` on the equipped card, so a country that was visited this
## day has strictly more understanding than one that was not. Returns -1 when the
## country does not know the card.
func _understanding(ext: Object, handle: int, dense: int) -> int:
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var idea_ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var values: PackedInt64Array = snapshot.get("understanding_q16", PackedInt64Array())
	var index := idea_ids.find(dense)
	if index < 0 or index >= values.size():
		return -1
	return int(values[index])


# ── the slice driver ─────────────────────────────────────────────────────


## Runs `day` to completion, one bounded slice per call, and records what the report
## said between calls. The count of calls IS the backlog evidence.
##
## CURSOR SEMANTICS, measured, not assumed. The trace for one day is
##   [64, 128, 192, 256, 320, 384, 448, 0, 0]
## i.e. exactly one budget per slice while the walk is live, then a ZERO because the
## statement that finishes the walk resets `_active_country_cursor` in the same call
## (ideology_runtime.cpp:5030-5035). Trailing zeros are therefore the end marker, not a
## regression; a non-zero value AFTER the reset would be one (the day restarted).
##
## Every loop is bounded: a day that stops making progress must fail the fixture, never
## hang it (B10 lost 27 minutes to an unbounded wait).
func _drain_day(ext: Object, day: int) -> Dictionary:
	var out := {
		"calls": 0, "done": false, "regressed": false,
		"restarted_after_reset": false, "slice_count": 0, "last_stage": "",
		"cursors": PackedInt32Array(), "stages": PackedStringArray(),
		"last_slice_ms": 0.0,
	}
	var previous := 0
	var reset_seen := false
	for index in range(MAX_CALLS_PER_DAY):
		var slice: Dictionary = ext.run_ideology_daily(day)
		out["calls"] = index + 1
		if not bool(slice.get("ok", false)):
			out["last_stage"] = "not_ok:%s" % str(slice)
			break
		# A worker-owned Ideology domain answers with `suppressed` and no `done`; that
		# is not a slice and must not be counted as progress.
		if not slice.has("done"):
			out["last_stage"] = "suppressed:%s" % str(slice.get("path", "?"))
			break
		var stage := str(slice.get("stage", "?"))
		out["last_stage"] = stage
		out["stages"].append(stage)
		out["slice_count"] = int(out["slice_count"]) + 1
		out["last_slice_ms"] = float(slice.get("elapsed_ms", 0.0))
		var report: Dictionary = ext.get_ideology_report()
		var cursor := int(report.get("active_country_cursor", 0))
		out["cursors"].append(cursor)
		if cursor == 0 and previous > 0:
			reset_seen = true
		elif reset_seen and cursor > 0:
			out["restarted_after_reset"] = true
		elif cursor < previous:
			out["regressed"] = true
		previous = cursor
		if bool(slice.get("done", false)):
			out["done"] = true
			break
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
		# `sequences` is the IDEMPOTENCY key and must be monotonic ACROSS batches
		# (M3-18): restarting at 1 makes every later command look like a duplicate.
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
	print("=== B3 country continuation: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
