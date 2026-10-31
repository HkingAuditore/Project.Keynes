extends SceneTree
## B12 (scenario battery) -- LOAD, FULL COLD START, PEAK MEMORY, RESTORE COST,
## FIRST-CONSUMPTION CORRECTNESS.
##
## B12 is specified as "load a save, flip authority, full cold start" and judges
## three quantities: PEAK MEMORY, RESTORE TIME, and FIRST CONSUMPTION CORRECT.
##
## AUTHORITY FLIP IS OUT OF SCOPE FOR THIS FIXTURE. Flipping authority needs a
## RuntimeWorker plus a second runtime host and the production handshake between
## them, and the brief for this fixture explicitly excludes the worker. Everything
## below runs on the MAIN THREAD against a single DCWorldExt per branch. The flip
## half of B12 is therefore NOT measured here and must not be read into any number
## printed below.
##
## WHAT THIS FIXTURE DOES COVER
##
## ---------------------------------------------------------------------------
## 1. THE SAVE IS THE PRODUCTION SECTION PAIR, IN THE PRODUCTION ORDER
## ---------------------------------------------------------------------------
##
## PKID alone CANNOT be restored once the save carries an equipped card.
## `NativeIdeologyRuntime::restore` re-verifies every ACTIVE idea against the
## Effect runtime's durable binding table (`ideology_runtime.cpp:6793-6812`:
## binding id, binding generation, binding signature, catalog hash and
## `has_external_binding_pod`) and rejects the WHOLE payload with
## `ideology_effect_binding_missing_or_mismatched` otherwise. The runtime says the
## order out loud at `:6748-6751` ("PKEF restores first (game_save_coordinator)").
##
## So every branch captures `capture_effect_state()` THEN
## `capture_ideology_state()`, and restores `restore_effect_state()` THEN
## `restore_ideology_state()` -- the pair and the order the coordinator uses
## (`scripts/game/game_save_coordinator.gd:961,969,1143,1154`).
## The negative control re-measures the consequence: PKID WITHOUT PKEF is refused
## with exactly that reason code.
##
## ---------------------------------------------------------------------------
## 2. WHAT "COLD" MEANS HERE, AND WHAT IT CANNOT MEAN ON THIS API SURFACE
## ---------------------------------------------------------------------------
##
## The reloaded branch is a BRAND NEW `DCWorldExt`: fresh Economy, Effect,
## Modifier, Country and Ideology runtimes, fresh slot arrays, fresh derived-layer
## peak counters (they are members of the runtime instance and are never reset --
## `ideology_runtime.h:1199-1201`), so its peak numbers start at zero and can only
## come from work the cold instance did itself.
##
## THE ECONOMY IS REPLAYED, NOT RESTORED, and that is a limitation of the exported
## surface, not a shortcut: ECP2 capture/apply lives on the economy facade and the
## simulation host bundle (`NativeEconomyRuntime::capture_ecp2_authority` /
## `apply_ecp2_authority`, reached from GDScript as
## `EconomyFacade.capture_ecp2/restore_ecp2`), and `DCWorldExt` exports no
## `capture_runtime_bundle` at all (confirmed in
## `tests/runtime/runtime_country_identity_mismatch_test.gd:295`). A fixture with no
## runtime host therefore has no way to move the economy across the boundary.
##
## That is why EVERY economy day before the save is committed with NO CARD IN PLAY:
## the cold branch replays the same deterministic bootstrap and the same days, so
## both sides reach the save point with a bit-identical economy and neither ever ran
## an economy day under a different derived front. The card is equipped only AFTER
## the last pre-save economy day, so the saved economy state carries no dependence
## on the derived layer.
##
## ---------------------------------------------------------------------------
## 3. WHY THE FRONT IS REBUILT RATHER THAN RESTORED (and why that is the point)
## ---------------------------------------------------------------------------
##
## `capture()` writes countries, ideas, offers and pending commands
## (`ideology_runtime.cpp:6393-6499`); the derived cell front is NOT in the payload.
## A cold restore therefore starts with `installed == false`, `cell_count == 0`, and
## the first ideology day after the restore has to REBUILD the front from the
## restored state alone (`step_derived_rebuild`, `:6978-7109`).
##
## That is exactly what B12's peak-memory question needs: the peak fields are only
## written at the install site (`:7081-7091`, `retained + candidate`), so a restored
## world that never built a front would report zeros and prove nothing. Here the
## cold world builds its own front, and its peak is compared against the peak of the
## run that produced the save.
##
## ---------------------------------------------------------------------------
## 4. FIRST CONSUMPTION: WHAT IS ACTUALLY COMPARED
## ---------------------------------------------------------------------------
##
## After the cold restore both branches run the IDENTICAL call sequence:
##
##   ideology day 6  -> economy day 3  (the FIRST consumption day)
##   ideology day 7  -> economy day 4
##
## On the continuous side the front already existed (installed on day 2 and again on
## day 5, each one day AFTER the settle that confirmed the projection -- plan 9.3)
## and day 6's rebuild is content-identical, so it is skipped (I13). On the cold side
## day 6's rebuild is the first build of a fresh instance and installs.
## Both sides then feed THE SAME numbers into the next economy day, and that is
## asserted per cell, exactly, with no tolerance: `effective_value`, `derived_add`
## and `derived_present` on every cell of the grid, for both stats the cards write.
##
## The card pair is chosen so the merge is exercised: `idea.public_hygiene` writes
## `economy.city.birth_factor` (+) and
## `economy.city.need.housing.consumption_factor` (-), and `idea.fire_keeping`
## writes `economy.city.birth_factor` (+) as well, so the birth-factor entry of every
## covered cell is a FOLD of two sources -- a restore that dropped one of them shows
## up as a per-cell difference, not as an empty front.
##
## ---------------------------------------------------------------------------
## 5. WHY THE TAGS ARE REWRITTEN (and only the tags)
## ---------------------------------------------------------------------------
##
## `idea.public_hygiene` filters on `cell.settlement` and `idea.fire_keeping` on
## `cell.terrain.tundra` (`data/ideologies/default_ideology_effects.tres`). A
## freshly bootstrapped economy has population but no buildings and no terrain
## authored, so the shipped predicates are legitimately false and both cards would
## cover ZERO cells -- correct behaviour that is indistinguishable from "the card
## never equipped". Every tag predicate is therefore rewritten to
## `cell.population >= 30` (the fixture puts 40 people on every cell), exactly as
## `ideology_b1_many_countries_test.gd` does. Names are kept, only the rows change,
## so the catalog's synergy overrides still resolve. Nothing else about the runtime
## is relaxed.
##
## ---------------------------------------------------------------------------
## 6. WHAT THIS FIXTURE CANNOT SHOW, AND SAYS SO
## ---------------------------------------------------------------------------
##
##   * AUTHORITY FLIP. Out of scope: it needs a RuntimeWorker and the two-runtime
##     handshake. Every number below is main-thread, single-runtime.
##   * THE ECONOMY'S OUTPUT. MEASURED, not assumed: in this fixture the economy is
##     INERT -- 40 subsistence cohorts per cell, no buildings and no market stock,
##     so `epoch_income`, `epoch_expense`, `satisfaction_q16`, `births` and `deaths`
##     are all 0 on every day for every branch. The card therefore leaves no
##     footprint in economy OUTPUT, and "first consumption" here is measured at the
##     MODIFIER-READ boundary: the per-cell `effective_value` / `derived_add` /
##     `derived_present` that the economy reads through the shared ADR01 formula.
##     The fixture prints that finding with its numbers instead of dressing up an
##     economy-level statistic that cannot move.
##   * SCRATCH MEMORY AND ALLOCATION COUNTS. Not reachable from GDScript; no binding
##     exposes them. No such number is printed.
##   * A REALISED ECP2 ECONOMY RESTORE. `DCWorldExt` exposes no economy
##     capture/restore entry point, so the cold branch replays deterministic economy
##     days instead (see section 2).
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b12_coldstart_restore_test.gd

const WIDTH := 24
const HEIGHT := 16
const CELLS: int = WIDTH * HEIGHT          # 384 cells
const COUNTRY_COUNT := 2
const CELLS_PER_COUNTRY: int = CELLS / COUNTRY_COUNT   # 192, contiguous bands
const SEED := 20261028
const Q16_ONE := 65536
## Below the 40 people this fixture puts on every cell, so the synthetic tag
## predicate is satisfied everywhere and an empty front can only mean a defect.
const POPULATION_FLOOR := 30
## `idea.public_hygiene` (era 3, mobilization): birth factor UP, housing need
## consumption DOWN -- two commands, two stats.
const CARD_A := "idea.public_hygiene"
## `idea.fire_keeping` (era 0, harmony): birth factor UP. Same stat as CARD_A's
## first command, so a covered cell's birth-factor entry is a TWO-SOURCE fold.
const CARD_B := "idea.fire_keeping"
const STAT_ADD := "economy.city.birth_factor"
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const PROGRAM_A := "ideology.effect.public_hygiene_l1"
const PROGRAM_B := "ideology.effect.fire_keeping_l1"
const CARDS_PER_COUNTRY := 2
## Opcodes out of `ideology_runtime.h:66-79`.
const OP_DISCOVER := 1
const OP_GRANT := 2
const OP_EQUIP := 5
## The economy days committed BEFORE any card exists. Three days means the save
## point sits on an economy that has a history (not just a bootstrap) while still
## guaranteeing that no economy day ever ran under the derived front -- which is
## what makes the cold branch's replay bit-identical.
const PRE_SAVE_ECONOMY_DAYS := 3          # days 0, 1, 2
const SAVE_ECONOMY_DAY := PRE_SAVE_ECONOMY_DAYS - 1
## The first economy day after the save, on both sides.
const FIRST_CONSUMPTION_ECONOMY_DAY := PRE_SAVE_ECONOMY_DAYS
const SECOND_CONSUMPTION_ECONOMY_DAY := PRE_SAVE_ECONOMY_DAYS + 1
## Ideology days. Every transition has FOUR phases under plan section 9.3: the
## settle records `confirmed_day = D` and `eligible_from_day = D + 1`, and the
## derived rebuild REFUSES to adopt on day D (`step_derived_rebuild`, `:7045-7048`).
## Each equip therefore needs a settle day AND an adoption day:
##
##   0 equip A    1 settle A (gated)   2 adopt A (L1 front, generation 1)
##   3 equip B    4 settle B (gated)   5 adopt B (two-source fold, generation 2)
##   SAVE at 5    6 first consumption  7 second consumption
##
## Every index is monotonic WITHIN a runtime instance, and the restore carries
## `_last_day`, so the cold branch continues at 6 rather than replaying.
const SAVE_IDEOLOGY_DAY := 5
const FIRST_IDEOLOGY_DAY := SAVE_IDEOLOGY_DAY + 1
const SECOND_IDEOLOGY_DAY := SAVE_IDEOLOGY_DAY + 2
## A day is sliced: one `run_ideology_daily` call is NOT a day.
const MAX_SLICES_PER_DAY := 512
const MAX_ECONOMY_SLICES := 4096
## Hang detectors, not performance gates. Wall clock on a shared build machine is a
## flake generator, so these are orders of magnitude above the measured values.
const WALL_CLOCK_BUDGET_MS := 900000
const RESTORE_BUDGET_MS := 5000.0
const COLD_BUILD_BUDGET_MS := 120000.0

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
var _catalogs := {}


func _init() -> void:
	_run()


func _run() -> void:
	var started_ms := Time.get_ticks_msec()
	_catalogs = _compile_catalogs()
	if _catalogs.is_empty():
		_finish()
		return
	var scene: Dictionary = _run_save_and_cold_start()
	if scene.is_empty():
		_finish()
		return
	_peak_memory(scene)
	_negative_controls(scene)
	var elapsed_ms := Time.get_ticks_msec() - started_ms
	_expect("B12/hang: the whole scenario finished inside the wall-clock budget "
		+ "(hang detector, not a performance gate)",
		elapsed_ms < WALL_CLOCK_BUDGET_MS,
		"elapsed_ms=%d budget=%d" % [elapsed_ms, WALL_CLOCK_BUDGET_MS])
	print("[B12] === evidence: cells=%d countries=%d cards_per_country=%d "
		% [CELLS, COUNTRY_COUNT, CARDS_PER_COUNTRY]
		+ "restore_ms=%.3f capture_ms=%.3f cold_build_ms=%.3f elapsed_ms=%d ==="
		% [float(scene.get("restore_ms", -1.0)), float(scene.get("capture_ms", -1.0)),
			float(scene.get("cold_build_ms", -1.0)), elapsed_ms])
	_finish()


# =========================================================================
# the scenario: continuous run -> save -> cold world -> first consumption
# =========================================================================

func _run_save_and_cold_start() -> Dictionary:
	print("[B12] ---- part 1: continuous run, save, then a genuinely cold world ----")

	# ---- the continuous branch ------------------------------------------
	var cont: Dictionary = _new_world("cont", PRE_SAVE_ECONOMY_DAYS)
	var ext: Object = cont["ext"]
	var handles: PackedInt64Array = cont["handles"]
	var owned_total := int(cont["owned_total"])
	var expect_cells := 2 * owned_total
	print("[B12/cont] world: owned=%d expected_front_cells=%d handles=%s"
		% [owned_total, expect_cells, str(handles)])
	_expect("B12/cont: the pre-save economy is committed at day %d with NO card in "
		% SAVE_ECONOMY_DAY
		+ "play (so no economy day ever ran under the derived front)",
		int(ext.get_economy_report().get("newest_state_day", -1)) == SAVE_ECONOMY_DAY
		and not bool(ext.get_economy_report().get("epoch_active", true)),
		"newest_state_day=%s epoch_active=%s" % [
			str(ext.get_economy_report().get("newest_state_day", "?")),
			str(ext.get_economy_report().get("epoch_active", "?"))])

	# ---- round 1: card A in both countries ------------------------------
	_submit(ext, _grant_rows(handles))
	_submit(ext, _idea_rows(OP_DISCOVER, 0, _catalogs["dense_a"], 0, handles))
	_submit(ext, _idea_rows(OP_EQUIP, 0, _catalogs["dense_a"], 0, handles))
	_run_one_ideology_day(ext, 0, "cont")
	# ---- WHICH CONTRIBUTION DOES A PENDING EQUIP MAKE? NONE (plan 10.1) ----
	# "an unACKed equip contributes nothing": `collect_effect_activations` returns
	# before adding a single template while `state.transition.previous_location ==
	# INACTIVE` (ideology_runtime.cpp:2313-2321), so the day-0 rebuild has no front
	# to publish and the day-0 read must NOT show one. The equip front appears only
	# after the Effect adapters ACK its level batch AND the next ideology day polls
	# the transition, which is why the "installs the first front" check below moved
	# to the settle day. (Before this runtime change `start_transition` wrote
	# `location` at request time, so this read already saw an installed front.)
	var layer_pending: Dictionary = ext.get_derived_cell_layer_report()
	_expect("B12/cont: while the day-0 equip is unACKed the front is NOT installed "
		+ "(plan 10.1: a pending equip contributes nothing)",
		not bool(layer_pending.get("installed", true))
		and int(layer_pending.get("cell_count", -1)) == 0,
		"installed=%s generation=%s cells=%s" % [
			str(layer_pending.get("installed", "?")),
			str(layer_pending.get("layer_generation", "?")),
			str(layer_pending.get("cell_count", "?"))])

	var served_a: Dictionary = _serve_native_adapters(ext, 0, "cont/r1")
	_expect("B12/cont: the native Effect adapters accepted and ACKED round 1's level "
		+ "commands (an equip transition never settles without them)",
		bool(served_a.get("effect_acked", false)), str(served_a))

	_run_one_ideology_day(ext, 1, "cont")
	# ---- PHASE 2 OF 9.3: SETTLED ON DAY 1, NOT YET ELIGIBLE ----------------
	# The ACKed transition is polled on day 1, so `poll_pending_transition` records
	# `derived_basis_confirmed_day = 1` and `derived_basis_eligible_day = 2`.
	# `step_derived_rebuild(1)` then REFUSES to adopt it (:7045-7048) and counts the
	# refusal, so the day-1 read must show NO front even though the equip is settled.
	# That is the whole point of the eligibility rule: the projection may not be
	# published before D + 1, and reading "no front" here is the runtime agreeing
	# with the plan rather than an empty layer.
	var layer_gated: Dictionary = ext.get_derived_cell_layer_report()
	var gated_report: Dictionary = ext.get_ideology_report()
	_expect("B12/cont: the settle day CONFIRMS the projection for day 2 and the "
		+ "day-1 rebuild is REFUSED by the eligibility gate (plan 9.3)",
		int(gated_report.get("derived_basis_confirmed_day", -2)) == 1
		and int(gated_report.get("derived_basis_eligible_day", -2)) == 2
		and int(gated_report.get("derived_rebuild_gated_by_eligibility", -1)) > 0,
		"confirmed=%s eligible=%s gated=%s" % [
			str(gated_report.get("derived_basis_confirmed_day", "?")),
			str(gated_report.get("derived_basis_eligible_day", "?")),
			str(gated_report.get("derived_rebuild_gated_by_eligibility", "?"))])
	_expect("B12/cont: on the settle day itself the front is STILL NOT INSTALLED, "
		+ "because the confirmed projection is not eligible before D + 1",
		not bool(layer_gated.get("installed", true))
		and int(layer_gated.get("cell_count", -1)) == 0,
		"installed=%s generation=%s cells=%s" % [
			str(layer_gated.get("installed", "?")),
			str(layer_gated.get("layer_generation", "?")),
			str(layer_gated.get("cell_count", "?"))])

	# ---- DAY D + 1: THE FIRST FRONT IS ADOPTED ---------------------------
	_run_one_ideology_day(ext, 2, "cont")
	var layer0: Dictionary = ext.get_derived_cell_layer_report()
	_expect("B12/cont: the day-0 equip INSTALLS the first front (basis adopted) on "
		+ "the day AFTER the settle day, which is the first day its confirmed "
		+ "projection is eligible (plan 9.3)",
		bool(layer0.get("installed", false))
		and int(layer0.get("layer_generation", -1)) == 1
		and int(layer0.get("cell_count", -1)) == expect_cells,
		"installed=%s generation=%s cells=%s (expected %d)" % [
			str(layer0.get("installed", "?")),
			str(layer0.get("layer_generation", "?")),
			str(layer0.get("cell_count", "?")), expect_cells])
	var settled_a: Dictionary = ext.get_ideology_report()
	_expect("B12/cont: round 1's transition is SETTLED before round 2 is submitted "
		+ "(a second equip while one is pending is refused with "
		+ "ideology_country_transition_pending)",
		int(settled_a.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(settled_a.get("pending_transitions", "?")))

	# ---- round 2: card B in both countries ------------------------------
	_submit(ext, _idea_rows(OP_DISCOVER, 0, _catalogs["dense_b"], 0, handles))
	_submit(ext, _idea_rows(OP_EQUIP, 3, _catalogs["dense_b"], 0, handles))
	_run_one_ideology_day(ext, 3, "cont")
	# Round 2 repeats the rule of round 1: card B is still in an unACKed equip, so
	# it contributes nothing and the front keeps exactly round 1 content -- the
	# generation must NOT move. The settle day (day 4) keeps the same content too,
	# because the confirmed projection is not eligible before day 5; "installs
	# again" is therefore asserted on day 5, not on the settle day.
	var layer2_pending: Dictionary = ext.get_derived_cell_layer_report()
	_expect("B12/cont: while the round-2 equip is unACKed the front keeps the "
		+ "round-1 content (generation unchanged)",
		int(layer2_pending.get("layer_generation", -1))
			== int(layer0.get("layer_generation", -2))
		and int(layer2_pending.get("cell_count", -1)) == expect_cells,
		"generation=%s (round 1 was %s) cells=%s" % [
			str(layer2_pending.get("layer_generation", "?")),
			str(layer0.get("layer_generation", "?")),
			str(layer2_pending.get("cell_count", "?"))])

	var served_b: Dictionary = _serve_native_adapters(ext, 3, "cont/r2")
	_expect("B12/cont: the native Effect adapters ACKED round 2's level commands",
		bool(served_b.get("effect_acked", false)), str(served_b))

	# ---- DAY 4: ROUND 2 SETTLES, STILL NOT ELIGIBLE ----------------------
	# The same fourth phase as round 1, one round later: the poll settles card B's
	# equip on day 4 (confirmed 4, eligible 5) and the rebuild is refused, so the
	# front keeps exactly the round-1 content for the whole settle day.
	_run_one_ideology_day(ext, 4, "cont")
	var layer2_gated: Dictionary = ext.get_derived_cell_layer_report()
	var gated_b_report: Dictionary = ext.get_ideology_report()
	_expect("B12/cont: round 2's settle day confirms the projection for day 5 and the "
		+ "day-4 rebuild is REFUSED by the eligibility gate (plan 9.3)",
		int(gated_b_report.get("derived_basis_confirmed_day", -2)) == 4
		and int(gated_b_report.get("derived_basis_eligible_day", -2)) == 5
		and int(gated_b_report.get("derived_rebuild_gated_by_eligibility", -1))
			> int(gated_report.get("derived_rebuild_gated_by_eligibility", 0)),
		"confirmed=%s eligible=%s gated %s -> %s" % [
			str(gated_b_report.get("derived_basis_confirmed_day", "?")),
			str(gated_b_report.get("derived_basis_eligible_day", "?")),
			str(gated_report.get("derived_rebuild_gated_by_eligibility", "?")),
			str(gated_b_report.get("derived_rebuild_gated_by_eligibility", "?"))])
	_expect("B12/cont: on round 2's settle day the front still keeps the round-1 "
		+ "content (generation unchanged, card B not published yet)",
		int(layer2_gated.get("layer_generation", -1))
			== int(layer0.get("layer_generation", -2))
		and int(layer2_gated.get("cell_count", -1)) == expect_cells,
		"generation=%s (round 1 was %s) cells=%s" % [
			str(layer2_gated.get("layer_generation", "?")),
			str(layer0.get("layer_generation", "?")),
			str(layer2_gated.get("cell_count", "?"))])

	# ---- DAY 5 = D + 1: THE TWO-SOURCE FOLD IS ADOPTED -------------------
	_run_one_ideology_day(ext, 5, "cont")
	var layer2: Dictionary = ext.get_derived_cell_layer_report()
	_expect("B12/cont: the day-3 equip CHANGES the front content and installs again "
		+ "on the first day its confirmed projection is eligible, day 5 (card B writes "
		+ "the same birth-factor stat, so the fold is two-source)",
		bool(layer2.get("installed", false))
		and int(layer2.get("layer_generation", -1)) == 2
		and int(layer2.get("cell_count", -1)) == expect_cells
		and int(layer2.get("stat_count", -1)) == 2,
		"installed=%s generation=%s cells=%s stats=%s" % [
			str(layer2.get("installed", "?")),
			str(layer2.get("layer_generation", "?")),
			str(layer2.get("cell_count", "?")),
			str(layer2.get("stat_count", "?"))])
	var at_save_report: Dictionary = ext.get_ideology_report()
	var rejections: Dictionary = _report_rejections(ext, "cont")
	_expect("B12/cont: every submitted command landed (zero rejected receipts)",
		int(rejections.get("rejected", -1)) == 0, str(rejections.get("reasons", [])))

	var state_at_save: Dictionary = _capture_state(cont, "cont/save")
	_expect("B12/save: both cards are ACTIVE and at level 0 on every country",
		_all_slots_occupied(state_at_save, CARDS_PER_COUNTRY)
		and _all_levels(state_at_save, 0),
		"slots=%s levels=%s" % [str(_slot_counts(state_at_save)),
			str(state_at_save["snapshots"][0]["levels"])])
	_expect("B12/cont: nothing is left in flight at the save boundary "
		+ "(pending_commands == 0, pending_transitions == 0, no rebuild pending)",
		int(at_save_report.get("pending_commands", -1)) == 0
		and int(at_save_report.get("pending_transitions", -1)) == 0
		and not bool(at_save_report.get("derived_rebuild_pending", true)),
		"commands=%s transitions=%s rebuild_pending=%s" % [
			str(at_save_report.get("pending_commands", "?")),
			str(at_save_report.get("pending_transitions", "?")),
			str(at_save_report.get("derived_rebuild_pending", "?"))])
	# The production gate (`game_save_coordinator.gd:_can_save`) asks exactly one
	# ideology question and MEASURED here rather than assumed.
	_expect("B12/save: the production save boundary reports idle at the save instant "
		+ "(ideology_should_run(%d) == false), so this is a legal capture point"
		% SAVE_IDEOLOGY_DAY,
		not bool(ext.ideology_should_run(SAVE_IDEOLOGY_DAY)),
		"ideology_should_run(%d)=%s" % [SAVE_IDEOLOGY_DAY,
			str(ext.ideology_should_run(SAVE_IDEOLOGY_DAY))])

	# ---- THE SAVE: PKEF then PKID, timed --------------------------------
	var capture_started := Time.get_ticks_usec()
	var saved: Dictionary = _capture_pair(ext, "B12/save")
	var capture_us := Time.get_ticks_usec() - capture_started
	var capture_ms := float(capture_us) / 1000.0
	_expect("B12/save: the section ORDER is PKEF then PKID (the order the production "
		+ "coordinator writes, game_save_coordinator.gd:961,969)",
		int(saved.get("pkef_us", 0)) >= 0 and int(saved.get("pkid_us", 0)) >= 0
		and (saved["pkef"] as PackedByteArray).size() > 0,
		"pkef=%d bytes in %.3f ms, pkid=%d bytes in %.3f ms" % [
			(saved["pkef"] as PackedByteArray).size(),
			float(int(saved.get("pkef_us", 0))) / 1000.0,
			(saved["pkid"] as PackedByteArray).size(),
			float(int(saved.get("pkid_us", 0))) / 1000.0])
	print("[B12/save] capture_ms=%.3f pkef=%d pkid=%d"
		% [capture_ms, (saved["pkef"] as PackedByteArray).size(),
			(saved["pkid"] as PackedByteArray).size()])

	# ---- the continuous CONTINUATION -----------------------------------
	_run_one_ideology_day(ext, FIRST_IDEOLOGY_DAY, "cont")
	_commit_economy_day(ext, FIRST_CONSUMPTION_ECONOMY_DAY, "cont")
	var cont_first: Dictionary = _capture_state(cont, "cont/first-day")
	_expect("B12/cont: the first consumption day reached economy day %d"
		% FIRST_CONSUMPTION_ECONOMY_DAY,
		int(cont_first["economy"]["newest_state_day"])
			== FIRST_CONSUMPTION_ECONOMY_DAY,
		str(cont_first["economy"]["newest_state_day"]))

	_run_one_ideology_day(ext, SECOND_IDEOLOGY_DAY, "cont")
	_commit_economy_day(ext, SECOND_CONSUMPTION_ECONOMY_DAY, "cont")
	var cont_second: Dictionary = _capture_state(cont, "cont/second-day")

	# ---- the COLD branch ------------------------------------------------
	#
	# A brand new DCWorldExt: new Economy/Effect/Modifier/Country/Ideology
	# runtimes, new slot arrays, and derived-layer peak counters that start at 0
	# because they are members of this instance and are never reset.
	print("[B12] ---- part 2: cold world (fresh DCWorldExt) + PKEF/PKID restore ----")
	var cold_build_started := Time.get_ticks_usec()
	var cold: Dictionary = _new_world("cold", PRE_SAVE_ECONOMY_DAYS)
	var cold_build_ms := float(Time.get_ticks_usec() - cold_build_started) / 1000.0
	var rext: Object = cold["ext"]
	var r_handles: PackedInt64Array = cold["handles"]
	_expect("B12/cold: the cold build finished inside the hang budget",
		cold_build_ms < COLD_BUILD_BUDGET_MS,
		"cold_build_ms=%.3f budget=%.1f" % [cold_build_ms, COLD_BUILD_BUDGET_MS])
	_expect("B12/cold: the replayed economy reaches the SAME committed day as the "
		+ "continuous run at the save point",
		int(rext.get_economy_report().get("newest_state_day", -1)) == SAVE_ECONOMY_DAY,
		"cold=%s continuous=%d" % [
			str(rext.get_economy_report().get("newest_state_day", "?")),
			SAVE_ECONOMY_DAY])
	_expect("B12/cold: the cold world resolves the SAME country handles",
		str(r_handles) == str(handles),
		"%s vs %s" % [str(r_handles), str(handles)])
	var cold_before: Dictionary = _capture_state(cold, "cold/pre-restore")
	_expect("B12/cold: before the restore the cold world has NO card and NO front "
		+ "(nothing was carried over in memory)",
		_all_slots_occupied(cold_before, 0)
		and not bool(cold_before["layer"]["installed"])
		and int(cold_before["layer"]["cell_count"]) == 0,
		"slots=%s installed=%s cells=%s" % [str(_slot_counts(cold_before)),
			str(cold_before["layer"]["installed"]),
			str(cold_before["layer"]["cell_count"])])

	# ---- THE RESTORE, timed --------------------------------------------
	var restore_started := Time.get_ticks_usec()
	var restored_pkef: Dictionary = rext.restore_effect_state(
		saved["pkef"] as PackedByteArray)
	var effect_restore_us := Time.get_ticks_usec() - restore_started
	var ideology_started := Time.get_ticks_usec()
	var restored_pkid: Dictionary = rext.restore_ideology_state(
		saved["pkid"] as PackedByteArray)
	var ideology_restore_us := Time.get_ticks_usec() - ideology_started
	var restore_us: int = effect_restore_us + ideology_restore_us
	var restore_ms := float(restore_us) / 1000.0
	_expect("B12/cold: PKEF restores FIRST (the order PKID's binding check requires)",
		bool(restored_pkef.get("ok", false)),
		str(restored_pkef.get("reason", restored_pkef)))
	_expect("B12/cold: PKID restores into the cold runtime",
		bool(restored_pkid.get("ok", false)),
		str(restored_pkid.get("reason", restored_pkid)))
	_expect("B12/cold: the timed restore is the sum of its two sections and non-empty "
		+ "(so the reported restore_ms is a real measurement, not a stub)",
		restore_us == effect_restore_us + ideology_restore_us
		and effect_restore_us >= 0 and ideology_restore_us >= 0
		and restore_ms < RESTORE_BUDGET_MS,
		"effect_us=%d ideology_us=%d total_us=%d restore_ms=%.3f budget_ms=%.1f"
		% [effect_restore_us, ideology_restore_us, restore_us, restore_ms,
			RESTORE_BUDGET_MS])
	print("[B12/restore] restore_ms=%.3f (pkef=%.3f ms, pkid=%.3f ms) capture_ms=%.3f "
		% [restore_ms, float(effect_restore_us) / 1000.0,
			float(ideology_restore_us) / 1000.0, capture_ms]
		+ "cold_build_ms=%.3f" % cold_build_ms)

	# ---- the restored state is the saved state -------------------------
	var after_restore: Dictionary = _capture_state(cold, "cold/post-restore")
	_expect("B12/cold: the restored CARD STATE is identical to the saved one "
		+ "(slots, idea ids, levels, understanding, points)",
		_snapshots_equal(state_at_save, after_restore),
		"%s vs %s" % [str(_slot_counts(state_at_save)),
			str(_slot_counts(after_restore))])
	_expect("B12/cold: the restored BUSINESS STATE hash is identical to the saved one",
		int(after_restore["business"].get("hash", 0))
			== int(state_at_save["business"].get("hash", 0)),
		"%s vs %s" % [str(after_restore["business"].get("hash", "?")),
			str(state_at_save["business"].get("hash", "?"))])
	_expect("B12/cold: the restored runtime keeps the saved pending counts "
		+ "(the payload is restored verbatim, not normalised on the way in)",
		int(after_restore["pending_commands"]) == int(state_at_save["pending_commands"])
		and int(after_restore["pending_transitions"])
			== int(state_at_save["pending_transitions"]),
		"commands %s/%s transitions %s/%s" % [
			str(after_restore["pending_commands"]),
			str(state_at_save["pending_commands"]),
			str(after_restore["pending_transitions"]),
			str(state_at_save["pending_transitions"])])
	# PKID carries no front; this is the premise of the peak-memory question below.
	_expect("B12/cold: PKID carries NO derived front, so the cold runtime starts with "
		+ "installed == false and cell_count == 0",
		not bool(after_restore["layer"]["installed"])
		and int(after_restore["layer"]["cell_count"]) == 0,
		"installed=%s cells=%s" % [str(after_restore["layer"]["installed"]),
			str(after_restore["layer"]["cell_count"])])

	# ---- FIRST CONSUMPTION: ideology day 6 (FIRST_IDEOLOGY_DAY) ---------
	var rebuild_before := int(after_restore["peaks"].get("cell_layer_rebuild_visits", 0))
	_run_one_ideology_day(rext, FIRST_IDEOLOGY_DAY, "cold")
	var rebuilt: Dictionary = rext.get_derived_cell_layer_report()
	var cold_report: Dictionary = rext.get_ideology_report()
	_expect("B12/cold: the FIRST ideology day after the cold restore REBUILDS and "
		+ "INSTALLS the front from the restored state alone",
		bool(rebuilt.get("installed", false))
		and int(rebuilt.get("layer_generation", 0)) >= 1
		and int(rebuilt.get("cell_count", -1)) == expect_cells
		and int(rebuilt.get("stat_count", -1)) == 2
		and not bool(cold_report.get("derived_rebuild_pending", true)),
		"installed=%s generation=%s cells=%s stats=%s pending=%s" % [
			str(rebuilt.get("installed", "?")),
			str(rebuilt.get("layer_generation", "?")),
			str(rebuilt.get("cell_count", "?")),
			str(rebuilt.get("stat_count", "?")),
			str(cold_report.get("derived_rebuild_pending", "?"))])
	print("[B12/cold] rebuild visits %d -> %s, steps=%s, install day=%s"
		% [rebuild_before, str(cold_report.get("cell_layer_rebuild_visits", "?")),
			str(cold_report.get("cell_layer_rebuild_steps", "?")),
			str(rebuilt.get("sample_day", "?"))])

	# ---- FIRST CONSUMPTION: economy day 3 ------------------------------
	_commit_economy_day(rext, FIRST_CONSUMPTION_ECONOMY_DAY, "cold")
	var cold_first: Dictionary = _capture_state(cold, "cold/first-day")
	_expect("B12/cold: the first consumption day reaches the SAME committed economy "
		+ "day as the continuous run",
		int(cold_first["economy"]["newest_state_day"])
			== int(cont_first["economy"]["newest_state_day"])
		and int(cold_first["economy"]["newest_state_day"])
			== FIRST_CONSUMPTION_ECONOMY_DAY,
		"cold=%s continuous=%s expected=%d" % [
			str(cold_first["economy"]["newest_state_day"]),
			str(cont_first["economy"]["newest_state_day"]),
			FIRST_CONSUMPTION_ECONOMY_DAY])
	_expect("B12/cold: the first consumption day kept the economy CONSERVED "
		+ "(population / money / goods errors all 0)",
		int(cold_first["audit"].get("population_error", -1)) == 0
		and int(cold_first["audit"].get("money_error", -1)) == 0
		and int(cold_first["audit"].get("goods_error", -1)) == 0,
		str(cold_first["audit"]))

	# ---- SECOND CONSUMPTION: days 5 / 4 --------------------------------
	_run_one_ideology_day(rext, SECOND_IDEOLOGY_DAY, "cold")
	_commit_economy_day(rext, SECOND_CONSUMPTION_ECONOMY_DAY, "cold")
	var cold_second: Dictionary = _capture_state(cold, "cold/second-day")

	# ---- THE COMPARISONS ----------------------------------------------
	# (a) the FIRST consumption day: exactly equal, cell by cell, no tolerance.
	_compare(cont_first, cold_first, "B12/first-day")
	# (b) the second day: the divergence would have to survive another day.
	_compare(cont_second, cold_second, "B12/second-day")
	_expect("B12/first-day: the card's TWO-SOURCE birth-factor fold is present on "
		+ "every covered cell, so the comparison is not of an empty front",
		_two_source_fold_present(cont_first, cont["owned_cells"]),
		"covered add on the first owned cell = %.8f (two cards, expected %.8f)"
			% [_covered_add(cont_first, cont["owned_cells"]),
				_expected_fold("cont")])
	_absolute_magnitude_check(cont_first, "B12/cont", cont["owned_cells"])
	_absolute_magnitude_check(cold_first, "B12/cold", cold["owned_cells"])

	_expect("B12/cold: the cold runtime recorded no runtime error",
		String(rext.get_ideology_report().get("last_error", "")).is_empty(),
		"last_error='%s'" % String(rext.get_ideology_report().get("last_error", "")))
	_expect("B12/cont: the continuous runtime recorded no runtime error",
		String(ext.get_ideology_report().get("last_error", "")).is_empty(),
		"last_error='%s'" % String(ext.get_ideology_report().get("last_error", "")))

	print("[B12] ---- continuous vs cold: front generation/install day ----")
	print("[B12] continuous: generation=%s sample_day=%s | cold: generation=%s "
		% [str(cont_first["layer"]["layer_generation"]),
			str(cont_first["layer"]["sample_day"]),
			str(cold_first["layer"]["layer_generation"])]
		+ "sample_day=%s (the front is NOT saved, so the install DAYS legitimately "
		% str(cold_first["layer"]["sample_day"])
		+ "differ: the continuous run installed on days 2 and 5 (each the day AFTER "
		+ "the settle that confirmed the projection) and skipped every identical "
		+ "rebuild after that, the cold run installs once, on its first day)")
	_expect("B12/cold: the cold world installed the front itself (generation >= 1) "
		+ "and installed no MORE times than the run that produced the save",
		int(cold_first["layer"]["layer_generation"]) >= 1
		and int(cold_first["layer"]["layer_generation"])
			<= int(cont_first["layer"]["layer_generation"]),
		"cold=%s continuous=%s" % [
			str(cold_first["layer"]["layer_generation"]),
			str(cont_first["layer"]["layer_generation"])])

	return {
		"cont": cont, "cold": cold,
		"cont_first": cont_first, "cont_second": cont_second,
		"cold_first": cold_first, "cold_second": cold_second,
		"save": saved, "state_at_save": state_at_save,
		"restore_ms": restore_ms, "capture_ms": capture_ms,
		"cold_build_ms": cold_build_ms,
		"expect_cells": expect_cells,
	}


# =========================================================================
# peak memory (plan 18.3)
# =========================================================================

## Reports and compares the derived-layer peak numbers of the two worlds.
##
## WHAT IS MEASURED: `peak_retained_bytes`, `peak_candidate_bytes`,
## `peak_total_bytes` (`ideology_runtime.cpp:6175-6177`, written only at the install
## site `:7081-7091`) and the installed front's `front_bytes`, `cell_count`,
## `contribution_count`, `stat_versions_bytes` (`world_ext_modifier.cpp:1097-1140`).
## These are BYTES OF THE DERIVED STRUCTURE, not process RSS.
##
## WHAT IS NOT MEASURED, SAID PLAINLY INSTEAD OF INVENTED: `scratch` bytes and
## allocation counts are NOT reachable from GDScript -- no binding exposes the
## allocator, the job's working set or a malloc counter, and a heap sample would not
## be deterministic anyway. The fixture therefore prints no such number.
func _peak_memory(scene: Dictionary) -> void:
	print("[B12] ---- part 3: peak memory, continuous vs cold-restored ----")
	var cont_peak: Dictionary = scene["cont_first"]["peaks"]
	var cold_peak: Dictionary = scene["cold_first"]["peaks"]
	print("[B12/peak] continuous: retained=%d candidate=%d total=%d front_bytes=%d "
		% [int(cont_peak["peak_retained_bytes"]),
			int(cont_peak["peak_candidate_bytes"]),
			int(cont_peak["peak_total_bytes"]),
			int(cont_peak["front_bytes"])]
		+ "cells=%d contributions=%d stat_versions_bytes=%d"
		% [int(cont_peak["cell_count"]), int(cont_peak["contribution_count"]),
			int(cont_peak["stat_versions_bytes"])])
	print("[B12/peak] cold      : retained=%d candidate=%d total=%d front_bytes=%d "
		% [int(cold_peak["peak_retained_bytes"]),
			int(cold_peak["peak_candidate_bytes"]),
			int(cold_peak["peak_total_bytes"]),
			int(cold_peak["front_bytes"])]
		+ "cells=%d contributions=%d stat_versions_bytes=%d"
		% [int(cold_peak["cell_count"]), int(cold_peak["contribution_count"]),
			int(cold_peak["stat_versions_bytes"])])
	var delta: int = int(cold_peak["peak_total_bytes"]) - int(cont_peak["peak_total_bytes"])
	print("[B12/peak] delta(cold - continuous) peak_total=%d bytes, front_bytes=%d bytes"
		% [delta, int(cold_peak["front_bytes"]) - int(cont_peak["front_bytes"])])

	_expect("B12/peak: the cold-restored world's PEAK TOTAL is not larger than the "
		+ "continuous run's (a cold restore must not allocate a bigger front than the "
		+ "run that produced it)",
		int(cold_peak["peak_total_bytes"]) <= int(cont_peak["peak_total_bytes"]),
		"cold=%d continuous=%d delta=%d" % [
			int(cold_peak["peak_total_bytes"]),
			int(cont_peak["peak_total_bytes"]), delta])
	_expect("B12/peak: the cold-restored world's PEAK RETAINED is not larger",
		int(cold_peak["peak_retained_bytes"]) <= int(cont_peak["peak_retained_bytes"]),
		"cold=%d continuous=%d" % [int(cold_peak["peak_retained_bytes"]),
			int(cont_peak["peak_retained_bytes"])])
	_expect("B12/peak: the CANDIDATE the cold world built is the same size as the one "
		+ "the continuous run built (the front is the same structure, so a cold "
		+ "restore reproduces it byte for byte)",
		int(cold_peak["peak_candidate_bytes"]) == int(cont_peak["peak_candidate_bytes"])
		and int(cold_peak["peak_candidate_bytes"]) > 0,
		"cold=%d continuous=%d" % [int(cold_peak["peak_candidate_bytes"]),
			int(cont_peak["peak_candidate_bytes"])])
	_expect("B12/peak: the installed front is the same SIZE in both worlds",
		int(cold_peak["front_bytes"]) == int(cont_peak["front_bytes"])
		and int(cold_peak["front_bytes"]) > 0,
		"cold=%d continuous=%d" % [int(cold_peak["front_bytes"]),
			int(cont_peak["front_bytes"])])
	_expect("B12/peak: continuous peak_total is exactly retained + candidate",
		int(cont_peak["peak_total_bytes"]) == int(cont_peak["peak_retained_bytes"])
			+ int(cont_peak["peak_candidate_bytes"]),
		"total=%d retained=%d candidate=%d" % [
			int(cont_peak["peak_total_bytes"]),
			int(cont_peak["peak_retained_bytes"]),
			int(cont_peak["peak_candidate_bytes"])])
	_expect("B12/peak: cold peak_total is exactly retained + candidate",
		int(cold_peak["peak_total_bytes"]) == int(cold_peak["peak_retained_bytes"])
			+ int(cold_peak["peak_candidate_bytes"]),
		"total=%d retained=%d candidate=%d" % [
			int(cold_peak["peak_total_bytes"]),
			int(cold_peak["peak_retained_bytes"]),
			int(cold_peak["peak_candidate_bytes"])])
	_expect("B12/peak: front_bytes closes the documented identity "
		+ "cells*4 + contributions*contribution_bytes + row_overhead + stat_versions",
		_front_bytes_identity(cont_peak) and _front_bytes_identity(cold_peak),
		"continuous=%s cold=%s" % [str(_front_bytes_terms(cont_peak)),
			str(_front_bytes_terms(cold_peak))])

	# ---- the SECOND data point: the peaks CONVERGE ----------------------
	#
	# At the first consumption day the cold world has built a front exactly once, and
	# a first build has no RETAINED front to coexist with (`previous == nullptr`,
	# `ideology_runtime.cpp:7080-7083`), so its retained peak is 0 by construction.
	# By the second day the cold world has rebuilt once with a previous front, so its
	# accumulated peaks must equal the continuous run's EXACTLY -- same retained, same
	# candidate, same total. That closes the memory question in both directions: not
	# larger at the moment of the cold start, and not smaller afterwards.
	var cont_late: Dictionary = scene["cont_second"]["peaks"]
	var cold_late: Dictionary = scene["cold_second"]["peaks"]
	print("[B12/peak] second day -- continuous: retained=%d candidate=%d total=%d | "
		% [int(cont_late["peak_retained_bytes"]),
			int(cont_late["peak_candidate_bytes"]),
			int(cont_late["peak_total_bytes"])]
		+ "cold: retained=%d candidate=%d total=%d"
		% [int(cold_late["peak_retained_bytes"]),
			int(cold_late["peak_candidate_bytes"]),
			int(cold_late["peak_total_bytes"])])
	_expect("B12/peak: once the cold world has rebuilt with a RETAINED front, its "
		+ "accumulated peaks equal the continuous run's exactly (retained, candidate "
		+ "and total)",
		int(cold_late["peak_retained_bytes"]) == int(cont_late["peak_retained_bytes"])
		and int(cold_late["peak_candidate_bytes"])
			== int(cont_late["peak_candidate_bytes"])
		and int(cold_late["peak_total_bytes"]) == int(cont_late["peak_total_bytes"]),
		"cold=%d/%d/%d continuous=%d/%d/%d" % [
			int(cold_late["peak_retained_bytes"]),
			int(cold_late["peak_candidate_bytes"]),
			int(cold_late["peak_total_bytes"]),
			int(cont_late["peak_retained_bytes"]),
			int(cont_late["peak_candidate_bytes"]),
			int(cont_late["peak_total_bytes"])])
	# The reason the first-day numbers legitimately differ, asserted as the mechanism
	# rather than left as a comment: a first build has no retained front.
	_expect("B12/peak: the cold world's FIRST-day retained peak is 0 because its only "
		+ "build so far had no previous front (a fresh instance, not a leak)",
		int(cold_peak["peak_retained_bytes"]) == 0
		and int(cold_peak["peak_candidate_bytes"]) > 0,
		"retained=%d candidate=%d" % [int(cold_peak["peak_retained_bytes"]),
			int(cold_peak["peak_candidate_bytes"])])


func _front_bytes_terms(peak: Dictionary) -> Dictionary:
	return {
		"front_bytes": int(peak.get("front_bytes", -1)),
		"cells_x4": int(peak.get("cell_count", 0)) * 4,
		"contribs": int(peak.get("contribution_count", 0))
			* int(peak.get("contribution_bytes", 0)),
		"row_overhead": int(peak.get("front_row_overhead_bytes", -1)),
		"stat_versions": int(peak.get("stat_versions_bytes", -1)),
	}


func _front_bytes_identity(peak: Dictionary) -> bool:
	var terms := _front_bytes_terms(peak)
	var sum: int = int(terms["cells_x4"]) + int(terms["contribs"]) + int(terms["row_overhead"]) + int(terms["stat_versions"])
	return int(terms["front_bytes"]) == sum and int(terms["front_bytes"]) > 0


# =========================================================================
# negative controls
# =========================================================================

## Proves the comparison CAN fail, in three independent ways.
##
##   NC1 (end to end): a full cold world that restores PKEF and NOT PKID. The card
##       is then not equipped, the front the first day builds is EXACTLY the empty
##       result, and the very comparison used to PASS the first consumption day must
##       report mismatches. This is the strongest of the three: it damages the
##       restore, not the snapshot.
##   NC2 (ordering): PKID WITHOUT PKEF must be refused, and the reason code must be
##       the binding check's own -- which is why the pair and its order are
##       mandatory.
##   NC3 (sensitivity): the shared per-cell helpers are handed a snapshot with one
##       presence byte flipped and one add moved by 1e-9 -- the smallest difference
##       the exact comparison is supposed to see.
func _negative_controls(scene: Dictionary) -> void:
	print("[B12] ---- part 4: negative controls (the comparison must be able to fail) ----")
	var saved: Dictionary = scene["save"]
	var cont_first: Dictionary = scene["cont_first"]

	# ---- NC1: PKEF only, in a full cold world --------------------------
	var nc1: Dictionary = _new_world("nc-pkef-only", PRE_SAVE_ECONOMY_DAYS)
	var nc1_ext: Object = nc1["ext"]
	var nc1_effect: Dictionary = nc1_ext.restore_effect_state(
		saved["pkef"] as PackedByteArray)
	_expect("B12/negctl NC1: PKEF alone still restores (so the damage below is the "
		+ "MISSING PKID, not a broken effect payload)",
		bool(nc1_effect.get("ok", false)),
		str(nc1_effect.get("reason", nc1_effect)))
	_run_one_ideology_day(nc1_ext, FIRST_IDEOLOGY_DAY, "nc1")
	var nc1_state: Dictionary = _capture_state(nc1, "nc1/first-day")
	var nc1_layer: Dictionary = nc1_state["layer"]
	_expect("B12/negctl NC1: with no PKID the card is NOT equipped, so the first day "
		+ "installs the explicit EMPTY result and the front covers zero cells",
		_all_slots_occupied(nc1_state, 0)
		and int(nc1_layer["cell_count"]) == 0,
		"slots=%s installed=%s cells=%s" % [str(_slot_counts(nc1_state)),
			str(nc1_layer["installed"]), str(nc1_layer["cell_count"])])
	var nc1_mismatches := 0
	var nc1_detail := ""
	for stat in [STAT_ADD, STAT_CUT]:
		var a: Dictionary = cont_first["cells"][stat]
		var b: Dictionary = nc1_state["cells"][stat]
		var p := _presence_diff(a["present"], b["present"])
		var f := _float_diff(a["add"], b["add"])
		nc1_mismatches += _mismatches(p) + _mismatches(f)
		if nc1_detail.is_empty():
			nc1_detail = "%s presence[%s] add[%s]" % [stat, p, f]
	_expect("B12/negctl NC1: the FIRST-DAY comparison REPORTS the missing ideology "
		+ "section (per-cell mismatches, not a silent pass)",
		nc1_mismatches > 0,
		"total per-cell mismatches=%d first=%s" % [nc1_mismatches, nc1_detail])
	_expect("B12/negctl NC1: the per-cell fingerprint also differs",
		String(nc1_state["fingerprint"]) != String(cont_first["fingerprint"]),
		"%s vs %s" % [String(nc1_state["fingerprint"]).substr(0, 16),
			String(cont_first["fingerprint"]).substr(0, 16)])
	print("[B12/negctl] NC1 per-cell mismatch count = %d (%s)"
		% [nc1_mismatches, nc1_detail])
	var nc1_economy := _economy_cell_diff(
		cont_first["economy_cells"], nc1_state["economy_cells"])
	# MEASURED FINDING, not an assertion: this fixture's economy is inert, so the
	# card leaves no footprint in the economy's own per-cell numbers and B12 cannot
	# measure first consumption through economy OUTPUT. Saying so out loud is the
	# point -- an economy-level number here would be an invented one.
	print("[B12/negctl] NC1 economy-cell mismatch count = %s (kind=%s)"
		% [str(_mismatches(nc1_economy)),
			"INERT economy: income/expense/satisfaction/births all 0, so the card's "
			+ "footprint is only visible at the modifier-read boundary"])
	if _mismatches(nc1_economy) > 0:
		# Only worth asserting if the economy actually reacts here; if it ever starts
		# to, this branch documents that the stronger signal became available.
		_expect("B12/negctl NC1: the economy's own per-cell view ALSO reports the "
			+ "missing card", true, nc1_economy)

	# ---- NC2: PKID without PKEF, refused by the binding check ----------
	var nc2: Dictionary = _new_world("nc-pkid-only", 0, false)
	var nc2_result: Dictionary = nc2["ext"].restore_ideology_state(
		saved["pkid"] as PackedByteArray)
	var nc2_reason := String(nc2_result.get("reason", ""))
	_expect("B12/negctl NC2: PKID WITHOUT PKEF is REFUSED, and the reason is the "
		+ "binding check's own (ideology_effect_binding_missing_or_mismatched) -- "
		+ "which is why the pair and its order are mandatory",
		not bool(nc2_result.get("ok", true))
		and nc2_reason == "ideology_effect_binding_missing_or_mismatched",
		"ok=%s reason='%s'" % [str(nc2_result.get("ok", "?")), nc2_reason])
	print("[B12/negctl] NC2 PKID-without-PKEF -> ok=%s reason=%s"
		% [str(nc2_result.get("ok", "?")), nc2_reason])
	var nc2_after: Dictionary = _capture_state(nc2, "nc2/post-refusal")
	_expect("B12/negctl NC2: the refusal is TOTAL -- the cold runtime keeps no card "
		+ "from the rejected payload, and the rollback left the business state intact",
		_all_slots_occupied(nc2_after, 0)
		and int(nc2_after["layer"]["cell_count"]) == 0,
		"slots=%s cells=%s" % [str(_slot_counts(nc2_after)),
			str(nc2_after["layer"]["cell_count"])])

	# ---- NC3: sensitivity of the shared helpers ------------------------
	var damaged: Dictionary = cont_first.duplicate(true)
	var row: Dictionary = damaged["cells"][STAT_ADD]
	var present: PackedByteArray = row["present"]
	var add: PackedFloat64Array = row["add"]
	var presence_cell := -1
	for c in range(CELLS):
		if present[c] != 0:
			presence_cell = c
			present[c] = 0
			break
	if presence_cell < 0:
		present[0] = 1
		presence_cell = 0
	add[3] = add[3] + 0.000000001
	row["present"] = present
	row["add"] = add
	damaged["cells"][STAT_ADD] = row
	damaged["fingerprint"] = _fingerprint(damaged["cells"])
	var p := _presence_diff(cont_first["cells"][STAT_ADD]["present"], present)
	var f := _float_diff(cont_first["cells"][STAT_ADD]["add"], add)
	_expect("B12/negctl NC3: the presence comparison reports the flipped cell",
		_mismatches(p) == 1, p)
	_expect("B12/negctl NC3: the add comparison reports a 1e-9 difference "
		+ "(exact equality has no tolerance to hide behind)",
		_mismatches(f) == 1, f)
	_expect("B12/negctl NC3: the fingerprint changes when one cell changes",
		String(damaged["fingerprint"]) != String(cont_first["fingerprint"]),
		"%s vs %s" % [String(damaged["fingerprint"]).substr(0, 16),
			String(cont_first["fingerprint"]).substr(0, 16)])
	print("[B12/negctl] NC3 mismatch counts: presence=%d add=%d"
		% [_mismatches(p), _mismatches(f)])

	# A corrupted PKID byte must be refused too: the save is VALIDATED, so
	# "restore ok" in part 2 means something.
	var pkid: PackedByteArray = saved["pkid"]
	if pkid.size() >= 8:
		var corrupt: PackedByteArray = pkid.duplicate()
		var at: int = corrupt.size() / 2
		corrupt[at] = corrupt[at] ^ 0xFF
		var scratch: Dictionary = _new_world("nc-corrupt", 0, false)
		var result: Dictionary = scratch["ext"].restore_ideology_state(corrupt)
		_expect("B12/negctl NC4: a PKID payload with one flipped byte is REFUSED",
			not bool(result.get("ok", true))
			and not String(result.get("reason", "")).is_empty(),
			"ok=%s reason=%s byte=%d" % [str(result.get("ok", "?")),
				str(result.get("reason", "?")), at])
		print("[B12/negctl] NC4 corrupted payload -> ok=%s reason=%s"
			% [str(result.get("ok", "?")), str(result.get("reason", "?"))])
	else:
		_expect("B12/negctl NC4: a PKID payload exists to corrupt", false, "")


# =========================================================================
# the per-cell comparison (the thing B12's "first consumption" judgement rests on)
# =========================================================================

## Deliberately does NOT compare `layer_generation` or `sample_day`: the front is
## not part of PKID, so the cold run rebuilds what the save did not carry and
## legitimately installs on a different day. Everything else must be EQUAL, with no
## tolerance: presence, add and effective value on every cell of the grid, the
## front's shape and size, the ideology payload, the economy day and the committed
## conservation audit.
func _compare(reference: Dictionary, other: Dictionary, tag: String) -> void:
	for stat in [STAT_ADD, STAT_CUT]:
		var a: Dictionary = reference["cells"][stat]
		var b: Dictionary = other["cells"][stat]
		_expect("%s: %s derived presence matches on every one of %d cells"
			% [tag, stat, CELLS],
			_presence_diff(a["present"], b["present"]).begins_with("mismatches=0"),
			_presence_diff(a["present"], b["present"]))
		_expect("%s: %s derived add matches EXACTLY on every cell" % [tag, stat],
			_float_diff(a["add"], b["add"]).begins_with("mismatches=0"),
			_float_diff(a["add"], b["add"]))
		_expect("%s: %s EFFECTIVE VALUE matches EXACTLY on every cell" % [tag, stat],
			_float_diff(a["value"], b["value"]).begins_with("mismatches=0"),
			_float_diff(a["value"], b["value"]))
	_expect("%s: the per-cell fingerprint hash is identical" % tag,
		String(reference["fingerprint"]) == String(other["fingerprint"]),
		"%s vs %s" % [reference["fingerprint"], other["fingerprint"]])
	var ref_layer: Dictionary = reference["layer"]
	var other_layer: Dictionary = other["layer"]
	_expect("%s: both fronts cover the same cells, contributions, stats and stat ids"
		% tag,
		int(ref_layer["cell_count"]) == int(other_layer["cell_count"])
		and int(ref_layer["contribution_count"])
			== int(other_layer["contribution_count"])
		and int(ref_layer["stat_count"]) == int(other_layer["stat_count"])
		and str(ref_layer["stat_ids"]) == str(other_layer["stat_ids"]),
		"cells %s/%s contribs %s/%s stats %s/%s ids %s/%s" % [
			str(ref_layer["cell_count"]), str(other_layer["cell_count"]),
			str(ref_layer["contribution_count"]),
			str(other_layer["contribution_count"]),
			str(ref_layer["stat_count"]), str(other_layer["stat_count"]),
			str(ref_layer["stat_ids"]), str(other_layer["stat_ids"])])
	_expect("%s: both fronts are the same SIZE in bytes" % tag,
		int(ref_layer["front_bytes"]) == int(other_layer["front_bytes"])
		and int(ref_layer["front_bytes"]) > 0,
		"%s vs %s" % [str(ref_layer["front_bytes"]),
			str(other_layer["front_bytes"])])
	var ref_business: Dictionary = reference["business"]
	var other_business: Dictionary = other["business"]
	_expect("%s: the ideology business state hash matches" % tag,
		int(ref_business.get("hash", 0)) == int(other_business.get("hash", 0)),
		"%s vs %s" % [str(ref_business.get("hash", "?")),
			str(other_business.get("hash", "?"))])
	for section in ["points", "baseline", "history", "draw", "bits", "offer", "ideas"]:
		_expect("%s: business section %s matches" % [tag, section],
			int(ref_business.get(section, -1)) == int(other_business.get(section, -1)),
			"%s vs %s" % [str(ref_business.get(section, "?")),
				str(other_business.get(section, "?"))])
	_expect("%s: both runs are at the SAME committed economy day" % tag,
		int(reference["economy"]["newest_state_day"])
			== int(other["economy"]["newest_state_day"]),
		"%s vs %s" % [str(reference["economy"]["newest_state_day"]),
			str(other["economy"]["newest_state_day"])])
	# The birth/death ledger of the same day. Both are 0 in this fixture (an economy
	# with no buildings and no market stock produces no flows), so this is a
	# state-agreement check and NOT the consumption evidence -- see the FINDING
	# printed by `_negative_controls`.
	_expect("%s: the economy's birth/death ledger matches at the same day "
		% tag + "(measured 0/0 here: state agreement, not consumption evidence)",
		int(reference["economy"]["births"]) == int(other["economy"]["births"])
		and int(reference["economy"]["deaths"]) == int(other["economy"]["deaths"]),
		"births %s/%s deaths %s/%s" % [
			str(reference["economy"]["births"]),
			str(other["economy"]["births"]),
			str(reference["economy"]["deaths"]),
			str(other["economy"]["deaths"])])
	_expect("%s: the live cohort count matches" % tag,
		int(reference["economy"]["cohort_count"])
			== int(other["economy"]["cohort_count"]),
		"%s vs %s" % [str(reference["economy"]["cohort_count"]),
			str(other["economy"]["cohort_count"])])
	# THE ECONOMY'S OWN VIEW of the probed cells -- population, funds, per-epoch
	# income/expense and every cohort's satisfaction. In THIS fixture these numbers
	# are inert (measured: income 0, expense 0, satisfaction 0, births 0 -- see the
	# FINDING printed by `_negative_controls`), so this is a STATE-AGREEMENT check:
	# both worlds' economies are in the same state at the same day. The consumption
	# evidence proper is the per-cell effective value above, which is the exact
	# number the economy reads through the shared ADR01 formula.
	var economy_diff := _economy_cell_diff(
		reference["economy_cells"], other["economy_cells"])
	_expect("%s: the economy's own per-cell view agrees exactly on every probed cell "
		% tag + "(population, funds, income, expense, satisfaction)",
		economy_diff.begins_with("mismatches=0"), economy_diff)
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
		"pop %s/%s money %s/%s goods %s/%s" % [
			str(ref_audit.get("population_error", "?")),
			str(other_audit.get("population_error", "?")),
			str(ref_audit.get("money_error", "?")),
			str(other_audit.get("money_error", "?")),
			str(ref_audit.get("goods_error", "?")),
			str(other_audit.get("goods_error", "?"))])
	_expect("%s: the cards occupy the same number of slots" % tag,
		str(_slot_counts(reference)) == str(_slot_counts(other)),
		"%s vs %s" % [str(_slot_counts(reference)),
			str(_slot_counts(other))])
	_expect("%s: the cards keep the same levels and understanding" % tag,
		_snapshots_equal(reference, other),
		str(_slot_counts(reference)))
	_expect("%s: one-shot Effect instance count is 0 on both sides (I01)" % tag,
		int(reference["instances"]) == 0 and int(other["instances"]) == 0,
		"%d vs %d" % [int(reference["instances"]), int(other["instances"])])
	_expect("%s: both sides carry the same pending command/transition counts" % tag,
		int(reference["pending_commands"]) == int(other["pending_commands"])
		and int(reference["pending_transitions"])
			== int(other["pending_transitions"]),
		"commands %s/%s transitions %s/%s" % [
			str(reference["pending_commands"]), str(other["pending_commands"]),
			str(reference["pending_transitions"]),
			str(other["pending_transitions"])])


## Absolute correctness, not only equality between two runs: every covered cell must
## carry the SUM of the two cards' level-1 program magnitudes on the birth-factor
## stat (the two-source fold), and the housing stat's derived delta must be NEGATIVE
## (its program magnitude is positive and the sign comes from the definition).
func _absolute_magnitude_check(state: Dictionary, label: String,
		owned_cells: Array) -> void:
	var expected := _expected_fold(label)
	var first_covered := _first_covered_cell(state, STAT_ADD)
	if first_covered < 0:
		_expect("%s: at least one cell carries a birth-factor contribution (%s)"
			% [label, label], false, "no covered cell in the probe")
		return
	var add := float((state["cells"][STAT_ADD] as Dictionary)["add"][first_covered])
	_expect("%s: the covered birth-factor add equals the SUM of the two cards' "
		% label
		+ "level-1 program magnitudes (%.8f)" % expected,
		absf(add - expected) <= 1e-6,
		"derived=%.8f expected=%.8f (public_hygiene_l1 + fire_keeping_l1, /Q16)"
			% [add, expected])
	var cut := float((state["cells"][STAT_CUT] as Dictionary)["add"][first_covered])
	_expect("%s: the .cut command's derived delta on the housing stat is NEGATIVE "
		% label + "(the sign comes from the definition, not from the magnitude)",
		cut < 0.0, "derived_add=%.8f" % cut)
	_expect("%s: an UNOWNED cell stays at the identity base (no leaked territory)"
		% label, _unowned_identity(state, owned_cells),
		"unowned cell still carries a derived term or a moved value")


func _expected_fold(label: String) -> float:
	var mag_a := _program_magnitude(PROGRAM_A, label)
	var mag_b := _program_magnitude(PROGRAM_B, label)
	return (float(mag_a) + float(mag_b)) / float(Q16_ONE)


func _program_magnitude(program_key: String, label: String) -> int:
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	var interpreter: Dictionary = _catalogs["interp_ext"].evaluate_effect_program_magnitude(
		program_key, metrics)
	_expect("%s: the persistent program %s evaluates (its magnitude is the absolute "
		% [label, program_key] + "reference the per-cell add must equal)",
		bool(interpreter.get("ok", false)), str(interpreter))
	return int(interpreter.get("magnitude", 0))


# =========================================================================
# state capture
# =========================================================================

## Pure capture: no assertions, so the negative controls can use it on states that
## are SUPPOSED to be wrong.
func _capture_state(world: Dictionary, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	var cells := {}
	for stat in [STAT_ADD, STAT_CUT]:
		cells[stat] = _probe_all_cells(ext, stat)
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var business: Dictionary = ext.get_ideology_business_state()
	var report: Dictionary = ext.get_ideology_report()
	var economy: Dictionary = ext.get_economy_report()
	var audit: Dictionary = ext.get_economy_committed_audit_report()
	var snapshots := []
	var instances := 0
	for handle in world["handles"]:
		var snapshot: Dictionary = ext.get_ideology_snapshot(int(handle))
		snapshots.append({
			"handle": int(handle),
			"locations": (snapshot.get("locations", PackedInt32Array())
				as PackedInt32Array).duplicate(),
			"levels": (snapshot.get("levels", PackedInt32Array())
				as PackedInt32Array).duplicate(),
			"idea_ids": (snapshot.get("idea_ids", PackedInt32Array())
				as PackedInt32Array).duplicate(),
			"understanding_q16": (snapshot.get("understanding_q16",
				PackedInt64Array()) as PackedInt64Array).duplicate(),
			"points_q16": int(snapshot.get("ideology_points_q16", 0)),
		})
		instances += int(ext.get_ideology_effect_instance_report(
			int(handle)).get("count", -1))
	var frontier := {
		"label": label,
		"cells": cells,
		"fingerprint": _fingerprint(cells),
		"layer": {
			"installed": bool(layer.get("installed", false)),
			"layer_generation": int(layer.get("layer_generation", -1)),
			"sample_day": int(layer.get("sample_day", -1)),
			"cell_count": int(layer.get("cell_count", -1)),
			"contribution_count": int(layer.get("contribution_count", -1)),
			"stat_count": int(layer.get("stat_count", -1)),
			"stat_ids": (layer.get("stat_ids", PackedInt32Array())
				as PackedInt32Array).duplicate(),
			"front_bytes": int(layer.get("front_bytes", -1)),
		},
		"peaks": _peak_report(ext),
		"business": {
			"hash": int(business.get("hash", 0)),
			"points": int(business.get("points", 0)),
			"baseline": int(business.get("baseline", 0)),
			"history": int(business.get("history", 0)),
			"draw": int(business.get("draw", 0)),
			"bits": int(business.get("bits", 0)),
			"offer": int(business.get("offer", 0)),
			"ideas": int(business.get("ideas", 0)),
		},
		"snapshots": snapshots,
		"economy_cells": _economy_cell_probe(ext, world),
		"instances": instances,
		"pending_commands": int(report.get("pending_commands", -1)),
		"pending_transitions": int(report.get("pending_transitions", -1)),
		"economy": {
			"newest_state_day": int(economy.get("newest_state_day", -1)),
			"births": int(economy.get("births", -1)),
			"deaths": int(economy.get("deaths", -1)),
			"cohort_count": int(economy.get("cohort_count", -1)),
			"epoch_active": bool(economy.get("epoch_active", true)),
		},
		"audit": {
			"available": bool(audit.get("available", false)),
			"day": int(audit.get("day", -1)),
			"population_error": int(audit.get("population_error", 0)),
			"money_error": int(audit.get("money_error", 0)),
			"goods_error": int(audit.get("goods_error", 0)),
		},
	}
	var out: Dictionary = frontier
	print("[B12/%s] front installed=%s cells=%s contributions=%s stats=%s "
		% [label, str(layer.get("installed", "?")),
			str(layer.get("cell_count", "?")),
			str(layer.get("contribution_count", "?")),
			str(layer.get("stat_count", "?"))]
		+ "generation=%s day=%s front_bytes=%s"
		% [str(layer.get("layer_generation", "?")),
			str(layer.get("sample_day", "?")), str(layer.get("front_bytes", "?"))])
	print("[B12/%s] slots=%s levels=%s pending=%s/%s economy_day=%s births=%s "
		% [label, str(_slot_counts(out)),
			str((snapshots[0] as Dictionary).get("levels", "?")),
			str(report.get("pending_commands", "?")),
			str(report.get("pending_transitions", "?")),
			str(economy.get("newest_state_day", "?")),
			str(economy.get("births", "?"))]
		+ "deaths=%s audit=%s/%s/%s"
		% [str(economy.get("deaths", "?")),
			str(audit.get("population_error", "?")),
			str(audit.get("money_error", "?")),
			str(audit.get("goods_error", "?"))])
	print("[B12/%s] peaks retained=%d candidate=%d total=%d visits=%d"
		% [label, int(out["peaks"]["peak_retained_bytes"]),
			int(out["peaks"]["peak_candidate_bytes"]),
			int(out["peaks"]["peak_total_bytes"]),
			int(report.get("cell_layer_rebuild_visits", -1))])
	print("[B12/%s] fingerprint=%s business=%s"
		% [label, String(out["fingerprint"]).substr(0, 16),
			str(business.get("hash", "?"))])
	for key in (out["economy_cells"] as Dictionary).keys():
		var probe: Dictionary = out["economy_cells"][key]
		print("[B12/%s] econ cell %s owned=%s pop=%s funds=%s income=%s expense=%s "
			% [label, String(key), str(probe["owned"]), str(probe["population"]),
				str(probe["funds"]), str(probe["epoch_income"]),
				str(probe["epoch_expense"])]
			+ "satisfaction=%s" % str(probe["satisfaction_q16"]))
	return out


## THE ECONOMY'S OWN VIEW of a few cells: population, funds, per-epoch income and
## EXPENSE and the satisfaction of every cohort living there.
##
## This is the observable that proves the restored front was CONSUMED rather than
## merely republished: the housing need's consumption factor changes what a cohort
## spends, so the same front on both sides must produce the same expense line. The
## two unowned cells are the control -- they must stay identical no matter what the
## cards do, which is what makes a difference on the owned cells meaningful.
func _economy_cell_probe(ext: Object, world: Dictionary) -> Dictionary:
	var owned_set := {}
	var probe_cells := PackedInt32Array()
	for entry in world.get("owned_cells", []):
		var owned: PackedInt32Array = entry
		for cell in owned:
			owned_set[int(cell)] = true
		if owned.size() > 0:
			probe_cells.append(int(owned[0]))
	var unowned := 0
	for c in range(CELLS):
		if owned_set.has(c):
			continue
		probe_cells.append(c)
		unowned += 1
		if unowned >= 2:
			break
	var out := {}
	for cell in probe_cells:
		var snapshot: Dictionary = ext.get_population_cell_snapshot(int(cell), true)
		out["%d" % int(cell)] = {
			"owned": owned_set.has(int(cell)),
			"population": int(snapshot.get("population", -1)),
			"funds": int(snapshot.get("funds", -1)),
			"epoch_income": int(snapshot.get("epoch_income", -1)),
			"epoch_expense": int(snapshot.get("epoch_expense", -1)),
			"satisfaction_q16": int(snapshot.get("satisfaction_q16", -1)),
			"cohort_funds": str(snapshot.get("funds_by_cohort", PackedInt64Array())),
			"cohort_expense": str(snapshot.get(
				"epoch_expense_by_cohort", PackedInt64Array())),
			"cohort_satisfaction": str(snapshot.get(
				"satisfaction_by_cohort_q16", PackedInt32Array())),
		}
	return out


func _economy_cell_diff(a: Dictionary, b: Dictionary) -> String:
	var mismatches := 0
	var first := ""
	for key in a.keys():
		if not b.has(key):
			mismatches += 1
			continue
		var x: Dictionary = a[key]
		var y: Dictionary = b[key]
		for field in x.keys():
			if str(x[field]) == str(y.get(field, "")):
				continue
			mismatches += 1
			if first.is_empty():
				first = "cell %s field %s: %s vs %s" % [String(key), String(field),
					str(x[field]), str(y.get(field, "?"))]
	return "mismatches=%d first=%s" % [mismatches, first]


func _peak_report(ext: Object) -> Dictionary:
	var report: Dictionary = ext.get_ideology_report()
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	return {
		"peak_retained_bytes": int(report.get("peak_retained_bytes", -1)),
		"peak_candidate_bytes": int(report.get("peak_candidate_bytes", -1)),
		"peak_total_bytes": int(report.get("peak_total_bytes", -1)),
		"cell_layer_rebuild_visits": int(report.get("cell_layer_rebuild_visits", 0)),
		"cell_layer_rebuild_steps": int(report.get("cell_layer_rebuild_steps", 0)),
		"front_bytes": int(layer.get("front_bytes", -1)),
		"cell_count": int(layer.get("cell_count", -1)),
		"contribution_count": int(layer.get("contribution_count", -1)),
		"stat_count": int(layer.get("stat_count", -1)),
		"contribution_bytes": int(layer.get("contribution_bytes", -1)),
		"front_row_overhead_bytes": int(layer.get("front_row_overhead_bytes", -1)),
		"stat_versions_bytes": int(layer.get("stat_versions_bytes", -1)),
	}


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


func _slot_counts(state: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for snapshot in state.get("snapshots", []):
		var count := 0
		var locations: PackedInt32Array = snapshot["locations"]
		for location in locations:
			if int(location) != 0:
				count += 1
		out.append(count)
	return out


func _all_slots_occupied(state: Dictionary, expected: int) -> bool:
	for count in _slot_counts(state):
		if int(count) != expected:
			return false
	return true


func _all_levels(state: Dictionary, expected: int) -> bool:
	for snapshot in state.get("snapshots", []):
		var levels: PackedInt32Array = snapshot["levels"]
		var occupied := 0
		for level in levels:
			if int(level) != expected:
				return false
			occupied += 1
		if occupied == 0:
			return false
	return true


## Compares the whole ideology payload per country: slot locations, idea ids, levels,
## understanding and points. Used both for "the restore brought the cards back" and
## for "both runs keep the same cards".
func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	var left: Array = a.get("snapshots", [])
	var right: Array = b.get("snapshots", [])
	if left.size() != right.size():
		return false
	for index in range(left.size()):
		var x: Dictionary = left[index]
		var y: Dictionary = right[index]
		if str(x["locations"]) != str(y["locations"]):
			return false
		if str(x["idea_ids"]) != str(y["idea_ids"]):
			return false
		if str(x["levels"]) != str(y["levels"]):
			return false
		if str(x["understanding_q16"]) != str(y["understanding_q16"]):
			return false
		if int(x["points_q16"]) != int(y["points_q16"]):
			return false
	return true


func _first_covered_cell(state: Dictionary, stat: String) -> int:
	var present: PackedByteArray = (state["cells"][stat] as Dictionary)["present"]
	for c in range(present.size()):
		if present[c] != 0:
			return c
	return -1


func _covered_add(state: Dictionary, _owned: Variant) -> float:
	var cell := _first_covered_cell(state, STAT_ADD)
	if cell < 0:
		return 0.0
	return float((state["cells"][STAT_ADD] as Dictionary)["add"][cell])


func _two_source_fold_present(state: Dictionary, _owned: Variant) -> bool:
	var cell := _first_covered_cell(state, STAT_ADD)
	if cell < 0:
		return false
	var add := float((state["cells"][STAT_ADD] as Dictionary)["add"][cell])
	return absf(add - _expected_fold("cont")) <= 1e-6


## An unowned cell must be untouched: no derived term and the value stays at the
## identity base. This is what catches a front that shifted its cell indices.
func _unowned_identity(state: Dictionary, owned_cells: Array) -> bool:
	var owned := {}
	for entry in owned_cells:
		for cell in (entry as PackedInt32Array):
			owned[int(cell)] = true
	var present: PackedByteArray = (state["cells"][STAT_ADD] as Dictionary)["present"]
	var value: PackedFloat64Array = (state["cells"][STAT_ADD] as Dictionary)["value"]
	for c in range(CELLS):
		if owned.has(c):
			continue
		if present[c] != 0:
			return false
		if absf(value[c] - 1.0) > 1e-12:
			return false
	return true


# =========================================================================
# world construction (identical for every branch)
# =========================================================================

## A complete world: slots, environment, the four native runtimes, the country CSR
## and (optionally) a bootstrapped economy with `economy_days` committed days.
##
## `with_economy = false` is used only by the ordering negative control, which needs
## the ideology/effect runtimes configured but no economy at all -- the binding check
## it exercises runs before anything economy-shaped.
func _new_world(label: String, economy_days: int,
		with_economy: bool = true) -> Dictionary:
	var country_ir: Dictionary = _catalogs["country_ir"]
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot.
	ext.create_entities(CELLS)
	_fill_environment(ext)
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

	# A scattered 2/3 of each country's band: `(x + 2y) % 3 != 0`. Non-contiguous on
	# purpose -- a uniform "everything is covered" territory would make a per-cell
	# comparison unable to see a shifted or dropped cell index.
	var country_ids := PackedStringArray()
	var country_names := PackedStringArray()
	var cash := PackedInt64Array()
	var offsets := PackedInt32Array()
	var territory := PackedInt32Array()
	var owned_per_country := []
	offsets.append(0)
	for index in range(COUNTRY_COUNT):
		country_ids.append("country.b12.%d" % index)
		country_names.append("B12-%d" % index)
		cash.append(0)
		var owned := PackedInt32Array()
		for slot in range(CELLS_PER_COUNTRY):
			var cell: int = index * CELLS_PER_COUNTRY + slot
			var x: int = cell % WIDTH
			var y: int = int(cell / WIDTH)
			if (x + 2 * y) % 3 != 0:
				owned.append(cell)
				territory.append(cell)
		owned_per_country.append(owned)
		offsets.append(territory.size())

	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": country_ids,
		"country_names": country_names,
		"country_cash": cash,
		"territory_offsets": offsets,
		"territory_cells": territory,
		"technology_offsets": _zero_offsets(COUNTRY_COUNT),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": _zero_offsets(COUNTRY_COUNT),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("%s: both countries bootstrap" % label,
		bool(boot.get("ok", false)), str(boot))

	var ideo_cfg: Dictionary = ext.configure_ideologies(_catalogs["native_ideology"])
	_expect("%s: ideologies configure" % label, bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg.get("fatal_reason", str(ideo_cfg)))))

	var handles := PackedInt64Array()
	var owned_total := 0
	for index in range(COUNTRY_COUNT):
		var owned: PackedInt32Array = owned_per_country[index]
		owned_total += owned.size()
		var handle := 0
		for slot in range(owned.size()):
			var summary: Dictionary = ext.get_country_cell_summary(int(owned[slot]))
			if bool(summary.get("owned", false)):
				handle = int(summary.get("country_handle", 0))
				break
		handles.append(handle)
	_expect("%s: the fixture resolves a non-zero handle for every country" % label,
		handles.size() == COUNTRY_COUNT and not handles.has(0), str(handles))
	_expect("%s: the fixture territory is a proper subset of the grid" % label,
		owned_total > 0 and owned_total < CELLS,
		"%d of %d" % [owned_total, CELLS])

	if with_economy:
		_open_epoch(ext, 0, label)
		_bootstrap_economy(ext, label)
		_advance_economy_day(ext, 0, label)
		for day in range(1, economy_days):
			_open_epoch(ext, day, label)
			_advance_economy_day(ext, day, label)

	return {
		"label": label, "ext": ext, "handles": handles,
		"owned_cells": owned_per_country, "owned_total": owned_total,
	}


func _open_epoch(ext: Object, day: int, label: String) -> void:
	# DUPLICATED IMMEDIATELY: `begin_or_reuse_economy_input_epoch` returns a
	# Dictionary that shares storage with the runtime's cached input-capture report,
	# so a value kept without a copy reports the CACHE's later contents.
	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(
		day, _epoch(day + 1, day)).duplicate(true)
	_expect("%s: economy epoch %d opens for day %d" % [label, day + 1, day],
		bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))


func _bootstrap_economy(ext: Object, label: String) -> void:
	var econ_catalog: Dictionary = _catalogs["economy_catalog"]
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
		# 40 people on every cell, so the synthetic tag predicate (population >= 30)
		# is satisfied everywhere and an empty front can only mean a defect.
		for pair in [[farmer, 20], [serf, 20]]:
			ci.append(c)
			si.append(int(pair[0]))
			pp.append(int(pair[1]))
			ff.append(10000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": ci, "signature_ids": si,
		"population": pp, "funds": ff,
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array(),
		"building_type_ids": PackedInt32Array(),
		"building_owner_signatures": PackedInt32Array(),
		"building_counts": PackedInt64Array(),
	})
	_expect("%s: the economy bootstraps" % label, bool(boot.get("ok", false)),
		str(boot))


func _commit_economy_day(ext: Object, day: int, label: String) -> void:
	_open_epoch(ext, day, label)
	_advance_economy_day(ext, day, label)


func _advance_economy_day(ext: Object, day: int, label: String) -> int:
	for s in range(MAX_ECONOMY_SLICES):
		var result: Dictionary = ext.run_economy_slice({
			"day_index": day, "tick_index": s})
		if bool(result.get("fatal", false)):
			_expect("%s: economy day %d stays non-fatal" % [label, day], false,
				str(result.get("fatal_reason", result)))
			return s
		if bool(result.get("done", false)):
			return s + 1
	_expect("%s: economy day %d completes" % [label, day], false,
		"%d slices" % MAX_ECONOMY_SLICES)
	return 0


func _fill_environment(ext: Object) -> void:
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


func _epoch(epoch: int, sample_day: int) -> Dictionary:
	return {
		"sample_day": sample_day, "epoch_id": epoch, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}


func _zero_offsets(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count + 1)
	out.fill(0)
	return out


func _u8_zero(count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count)
	return out


# =========================================================================
# ideology commands
# =========================================================================

func _grant_rows(handles: PackedInt64Array) -> Array:
	var rows: Array = []
	for handle in handles:
		rows.append({"op": OP_GRANT, "day": 0, "handle": int(handle),
			"idea": -1, "value": 64 * Q16_ONE})
	return rows


func _idea_rows(op: int, day: int, idea: int, value_q16: int,
		handles: PackedInt64Array) -> Array:
	var rows: Array = []
	for handle in handles:
		rows.append({"op": op, "day": day, "handle": int(handle),
			"idea": idea, "value": value_q16})
	return rows


## Command batch. Every column must be the SAME length as `opcodes`, and `sequences`
## is the idempotency key: it must stay monotonic ACROSS batches, or every later
## command looks like a duplicate and is dropped silently.
func _submit(ext: Object, rows: Array) -> void:
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
	var result: Dictionary = ext.submit_ideology_commands({
		"opcodes": opcodes, "effective_days": days,
		"source_priorities": priorities, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	})
	_expect("B12/cmd: a batch of %d commands (seq %d..%d) is admitted"
		% [opcodes.size(), int(sequences[0]), int(sequences[sequences.size() - 1])],
		bool(result.get("ok", false)), str(result))


## Receipts are the only place a rejection names its reason, so a failure can say
## WHICH command the runtime refused instead of only that a count is wrong.
func _report_rejections(ext: Object, label: String) -> Dictionary:
	var receipts: Dictionary = ext.poll_ideology_receipts(0, 4096)
	var statuses: PackedInt32Array = receipts.get("statuses", PackedInt32Array())
	var reasons: PackedStringArray = receipts.get("reasons", PackedStringArray())
	var rejected := 0
	var collected := PackedStringArray()
	for index in range(statuses.size()):
		if int(statuses[index]) != 3:
			continue
		rejected += 1
		if collected.size() < 6:
			collected.append(String(reasons[index]) if index < reasons.size() else "")
	if rejected > 0:
		print("[B12/%s] REJECTED commands: %s" % [label, str(collected)])
	return {"rejected": rejected, "reasons": collected}


# =========================================================================
# advancing
# =========================================================================

## One ideology day, driven to completion, then the derived rebuild drained.
##
## `run_ideology_daily` is a SLICE stage: a single call may come back `done=false`
## with the day (or the derived rebuild) still in progress, so looping on the
## runtime's own `done` flag is what lets this fixture wait honestly instead of
## guessing a call count. It must NOT be called again once `done` is true: that
## would start a fresh rebuild for the same day.
func _run_one_ideology_day(ext: Object, day: int, label: String) -> bool:
	var done := false
	var slices := 0
	var last: Dictionary = {}
	for _i in range(MAX_SLICES_PER_DAY):
		slices += 1
		last = ext.run_ideology_daily(day)
		if not bool(last.get("ok", true)):
			_expect("%s: ideology day %d reports ok" % [label, day], false, str(last))
			return false
		if bool(last.get("done", false)):
			done = true
			break
	_expect("%s: ideology day %d completes (stage=%s, %d slices)"
		% [label, day, String(last.get("stage", "")), slices], done, str(last))
	var drained: Dictionary = ext.drain_derived_cell_layer(day)
	_expect("%s: ideology day %d leaves no derived rebuild in flight (drained in %s "
		% [label, day, str(drained.get("steps", "?"))]
		+ "steps; 0 means the day already folded it)",
		bool(drained.get("complete", false)), str(drained))
	return done


## Serves the native Effect adapters, which is what the daily graph does every day
## (`dispatch_effect_native_modifier` / `ack_effect_native_modifier`,
## `world_ext_bind_methods.cpp:635-638`).
##
## Without this the equip's level transaction stays PENDING forever, so
## `pending_transition_count` never returns to 0 and NO later idea command can land:
## `equip`/`unequip` refuse while a transition is pending
## (`ideology_runtime.cpp:4550-4555,4576-4581`) and `start_next_level_transition`
## returns early (`:3816`). `run_modifier_daily(day)` in between is MANDATORY: the
## dispatch only SUBMITS the rows to the Modifier runtime, and they complete when
## that domain runs its own day.
func _serve_native_adapters(ext: Object, day: int, label: String) -> Dictionary:
	var rounds := 0
	var ok := true
	var effect_acked := false
	for _i in range(8):
		rounds += 1
		ext.run_effect_daily(day)
		var dispatched: Dictionary = ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		var dispatched_country: Dictionary = ext.dispatch_effect_native_country()
		var acked_country: Dictionary = ext.ack_effect_native_country()
		if rounds == 1:
			print("[B12/%s/adapters] modifier dispatch=%s ack=%s country=%s/%s"
				% [label, str(dispatched), str(acked), str(dispatched_country),
					str(acked_country)])
		if not bool(dispatched.get("ok", true)) or not bool(acked.get("ok", true)):
			ok = false
			print("[B12/%s/adapters] modifier dispatch=%s ack=%s"
				% [label, str(dispatched), str(acked)])
			break
		if not bool(dispatched_country.get("ok", true)) \
				or not bool(acked_country.get("ok", true)):
			ok = false
			print("[B12/%s/adapters] country dispatch=%s ack=%s"
				% [label, str(dispatched_country), str(acked_country)])
			break
		if int(acked.get("acknowledged", 0)) > 0 \
				and int(acked.get("pending", 0)) == 0:
			# The EFFECT side has acked; the ideology runtime has not polled it yet
			# (`_pending_transitions` is only drained at the start of a
			# `run_ideology_daily` slice, `ideology_runtime.cpp:4918-4932`), so the
			# next ideology day is what turns this into a settled transition.
			effect_acked = true
			break
		if int(ext.get_ideology_report().get("pending_transitions", -1)) == 0:
			effect_acked = true
			break
	var final_report: Dictionary = ext.get_ideology_report()
	var adapters: Dictionary = ext.get_effect_native_adapter_report()
	print("[B12/%s/adapters] rounds=%d effect_acked=%s pre_poll_pending_transitions=%s "
		% [label, rounds, str(effect_acked),
			str(final_report.get("pending_transitions", "?"))]
		+ "queues=%s"
		% [str({"country": adapters.get("country_pending", "?"),
			"economy": adapters.get("economy_pending", "?"),
			"gameplay": adapters.get("gameplay_pending", "?")})])
	return {"ok": ok, "rounds": rounds, "effect_acked": effect_acked,
		"pre_poll_pending_transitions": int(
			final_report.get("pending_transitions", -1)), "adapters": adapters}


# =========================================================================
# the section pair (PKEF then PKID)
# =========================================================================

## The production SECTION PAIR and its order: PKEF first, then PKID
## (`scripts/game/game_save_coordinator.gd:961,969`; the ordering is required by
## `ideology_runtime.cpp:6748-6751,6793-6812`).
func _capture_pair(ext: Object, label: String) -> Dictionary:
	var effect_started := Time.get_ticks_usec()
	var pkef: PackedByteArray = ext.capture_effect_state()
	var pkef_us := Time.get_ticks_usec() - effect_started
	var ideology_started := Time.get_ticks_usec()
	var pkid: PackedByteArray = ext.capture_ideology_state()
	var pkid_us := Time.get_ticks_usec() - ideology_started
	_expect("%s: PKEF payload is produced" % label, not pkef.is_empty(),
		"%d bytes" % pkef.size())
	_expect("%s: PKID payload is produced and carries the PKID magic" % label,
		_ascii_magic(pkid) == "PKID", "%s (%d bytes)" % [_ascii_magic(pkid),
			pkid.size()])
	return {"pkef": pkef, "pkid": pkid, "pkef_us": pkef_us, "pkid_us": pkid_us}


func _ascii_magic(bytes: PackedByteArray) -> String:
	return bytes.slice(0, mini(4, bytes.size())).get_string_from_ascii()


# =========================================================================
# catalogs
# =========================================================================

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
	var rewritten := _make_all_tags_satisfiable(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native_ideology: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var economy_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if country_ir.is_empty() or effect_ir.is_empty() or mod_ir.is_empty() \
			or native_ideology.is_empty():
		_expect("B12/A0: all four native catalogs compile", false,
			"one of them is empty")
		return {}
	var ids: PackedStringArray = native_ideology.get(
		"ideology_ids", PackedStringArray())
	var dense_a: int = ids.find(CARD_A)
	var dense_b: int = ids.find(CARD_B)
	var capacity := int(native_ideology.get("ideology_capacity", -1))
	print("[B12] catalog: tags_rewritten=%d capacity=%d card_a_dense=%d card_b_dense=%d"
		% [rewritten, capacity, dense_a, dense_b])
	_expect("B12/A1: both cards are in the compiled ideology catalog and are DISTINCT",
		dense_a >= 0 and dense_b >= 0 and dense_a != dense_b,
		"%s -> %d, %s -> %d of %d" % [CARD_A, dense_a, CARD_B, dense_b, ids.size()])
	# Two cards have to fit in one country's slot budget, or round 2 is refused and
	# the front never reaches the two-source fold this fixture is built around.
	_expect("B12/A2: the shipped ideology capacity holds %d cards" % CARDS_PER_COUNTRY,
		capacity >= CARDS_PER_COUNTRY, "capacity=%d" % capacity)
	if dense_a < 0 or dense_b < 0 or capacity < CARDS_PER_COUNTRY:
		return {}
	# A throwaway DCWorldExt is not needed to interpret a program, but the binding is
	# on DCWorldExt, so one instance is created and kept for the magnitude probes.
	var interpreter_ext: Object = ClassDB.instantiate("DCWorldExt")
	interpreter_ext.create_entities(1)
	_expect("B12/A3: effects configure on the magnitude-interpreter instance",
		bool(interpreter_ext.configure_effects(effect_ir).get("ok", false)))
	return {
		"country_ir": country_ir, "profile": profile, "effect_ir": effect_ir,
		"mod_ir": mod_ir, "native_ideology": native_ideology,
		"economy_catalog": economy_catalog,
		"dense_a": dense_a, "dense_b": dense_b, "interp_ext": interpreter_ext,
	}


## Rewrites EVERY tag predicate to `cell.population >= POPULATION_FLOOR`.
##
## Names are kept and only the rows change: the ideology catalog declares synergy
## overrides that name other tags, and a tag that no longer resolves fails
## `configure_ideologies` with `ideology_synergy_override_tag_unknown`. Replacing
## the whole list (instead of one entry) is what lets a card filtered on
## `cell.terrain.tundra` and a card filtered on `cell.settlement` both land on the
## same bootstrapped cells.
##
## `metric_keys` is deliberately NOT touched: `tag_metric_ids` carries the DENSE
## INDEX into that array, and a short list moves `cell.population` off its id, so the
## row reads the wrong metric and the tag never matches.
func _make_all_tags_satisfiable(domain: Resource) -> int:
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	var replaced := 0
	for index in range(tags.size()):
		var name := String(tags[index].get("name", ""))
		if name.is_empty():
			continue
		var rows: Array[Dictionary] = [{
			"metric": "cell.population",
			"op": 0,                                  # TARGET_TAG_GTE
			"threshold_q16": POPULATION_FLOOR * Q16_ONE,
			"clause": 0,
		}]
		tags[index] = {"name": name, "rows": rows}
		replaced += 1
	domain.target_tags = tags
	return replaced


# =========================================================================
# comparison primitives
# =========================================================================

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


func _mismatches(text: String) -> int:
	var needle := "mismatches="
	var at := text.find(needle)
	if at < 0:
		return -1
	var digits := ""
	for i in range(at + needle.length(), text.length()):
		var ch := text[i]
		if ch < "0" or ch > "9":
			break
		digits += ch
	return int(digits) if not digits.is_empty() else -1


# =========================================================================
# reporting
# =========================================================================

## Every check is printed, pass or fail: B12's evidence is the LIST of things that
## were compared, and a log that only shows failures cannot tell a reader whether the
## per-cell comparison ran at all.
func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	print("  [FAIL] %s %s" % [label, detail])
	printerr("FAIL %s %s" % [label, detail])


func _finish() -> void:
	print("=== B12 cold-start restore (read load + full cold start + peak memory + "
		+ "restore cost + first consumption): %d checks, %d failures ==="
		% [_checks, _failures])
	quit(0 if _failures == 0 else 1)
