extends SceneTree
## Plan section 18.1 evidence row:
##
##   "copier, schools, synergy, EQUIP/UNEQUIP (装卸), LEVEL ADVANCEMENT (升级)
##    and national-spirit promotion produce correct results"
##
## This fixture owns exactly two of those mechanisms: EQUIP / UNEQUIP and LEVEL
## ADVANCEMENT. Copier+school and synergy+promotion are other fixtures.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS FIXTURE NECESSARY (the handshake)
## ---------------------------------------------------------------------------
##
## Every equip / unequip / level transition enqueues Effect transactions and then
## stays PENDING until the Effect runtime ACKs them:
##
##   * `start_transition` only becomes a pending transition when it enqueued at
##     least one Effect batch (`ideology_runtime.cpp:3675-3726`); the state flip
##     (`state.location`, `state.level`) happens at REQUEST time, the durable
##     commit at ACK time (`poll_pending_transition`, `:3729-3812`).
##   * `equip` (`:4547-4572`), `unequip` (`:4574-4588`) and
##     `start_next_level_transition` (`:3814-3828`) all refuse to start a second
##     transition while one is in flight. So every step must be SETTLED before
##     the next command can land.
##
## The ACK is a production path, driven here exactly as the daily graph drives
## it. The measured order is mandatory (`world_ext_bind_methods.cpp:471,635-638`):
##
##   dispatch_effect_native_modifier()  ->  run_modifier_daily(day)
##                                      ->  ack_effect_native_modifier()
##
## `run_modifier_daily` between dispatch and ack is NOT optional: the Modifier
## runtime is what completes the rows the dispatch submitted, and without it the
## ack keeps reporting `pending` forever. Measured on the failure mode: with
## dispatch+ack but no `run_modifier_daily`, `pending_transitions` stayed 1 for
## hundreds of `run_ideology_daily` slices.
##
## ---------------------------------------------------------------------------
## THE UNEQUIP RISK, AND WHY THIS FIXTURE BOOTSTRAPS FARMERS
## ---------------------------------------------------------------------------
##
## `unequip` runs the same class-opinion support gate as `equip`
## (`support_gate(country, id, SUPPORT_REPEAL, error)`, `:4582`). The gate needs a
## live Economy class-opinion snapshot (`evaluate_support`, `:1214-1306`) and
## compares the influence-weighted stance against the definition's
## `repeal_threshold_q16` (`:1303`). `idea.public_hygiene` has
## `repeal_threshold_q16 = 0` and repeal stances farmer +8192 / general -8192 /
## worker -24576 (`data/ideologies/default_ideology_catalog.tres:5368-5387,
## :5409`), so a population made ONLY of `general`-class cohorts produces a
## NEGATIVE repeal support and `unequip` is refused with
## `ideology_support_threshold_not_met`. That is the trap.
##
## The fixture therefore bootstraps `household_farmer` (political class "farmer",
## repeal stance +8192) together with `subsistence_farmer` (class "general") at a
## 3:1 population ratio, and PRINTS the support numbers it measured
## (`explain_ideology`) instead of assuming them. With that mix both the adopt and
## the repeal gates pass, so unequip is reachable and the mechanism can be judged.
##
## World C is the NEGATIVE CONTROL for exactly that claim: the same scenario with a
## general-only population, where the repeal support measures -8192, `unequip` is
## refused with `ideology_support_threshold_not_met`, and the card keeps serving.
## Without it, "unequip works" would be unfalsifiable -- and a fixture that
## bootstraps the usual `subsistence_farmer` + `serf` mix (both class "general")
## lands on world C by accident and reads a correct refusal as a broken runtime.
##
## ---------------------------------------------------------------------------
## THE TWO PENDING GUARDS, AND WHY THERE ARE TWO CATALOG WORLDS
## ---------------------------------------------------------------------------
##
## `equip` refuses a second command twice over, in this order (`:4547-4556`):
##
##   :4550  pending_transition_count > 0 && !_synergies.empty()
##          -> "ideology_country_transition_pending"
##   :4555  state->transition.active != 0
##          -> "ideology_transition_pending"
##
## The SHIPPED catalog carries 68 synergies, so the COUNTRY-level guard fires
## first and a second equip is reported as `ideology_country_transition_pending`.
## The per-card guard (`ideology_transition_pending`) is only reachable when the
## synergy table is empty, i.e. when the first guard is skipped by its own
## `!_synergies.empty()` term.
##
## Both are real behaviour and both are proven here:
##   world "A" - shipped catalog (68 synergies): the country-level guard fires.
##   world "B" - same catalog with the synergy table emptied (fixture
##               configuration, the same way B1 raises the slot budget): the
##               per-card guard fires and the assertion the plan asks for
##               (`ideology_transition_pending`) is measured exactly.
##
## For UNEQUIP the same two-layer order has a third consequence worth recording:
## `start_transition` moves `state.location` to INACTIVE at request time, so a
## repeated unequip of the same card hits "ideology_not_equipped" (`:4580`)
## BEFORE the per-card transition guard (`:4581`). World B measures that too and
## asserts the exact code, because a reader who expects
## `ideology_transition_pending` there would otherwise read a correct refusal as
## a defect.
##
## ---------------------------------------------------------------------------
## LEVEL ADVANCEMENT
## ---------------------------------------------------------------------------
##
## A level is the highest catalog row whose `understanding_threshold_q16` is
## <= `understanding_q16` (`unlocked_level`, `:1638-1647`). `ADD_UNDERSTANDING`
## adds the value and immediately asks for the next level transition
## (`:4847-4857`), which reports `_levels_advanced` once it starts (`:3826`).
## `public_hygiene` L2 needs 524288 (`:5331`), and the card's two stats are
## authored per level: `public_hygiene_l1` = 3277 (birth factor) + 5243 (housing
## cut), `public_hygiene_l2` = 5243 + 6554
## (`data/ideologies/default_ideology_effects.tres:5336-5447`). The magnitudes are
## read from the interpreter's own `evaluate_effect_program_magnitude` rather than
## hard-coded, and the per-cell effective values are compared around the change
## AND against the authored Q16 constants (which the fixture also states).
##
## ---------------------------------------------------------------------------
## THE FOUR PHASES A TRANSITION HAS (plan section 9.3: eligibility)
## ---------------------------------------------------------------------------
##
## The runtime implements this rule:
##
##   "the confirmed projection has eligible_from_day = D + 1. At the new economy
##    freeze boundary sample_day = S only the newest confirmed projection with
##    eligible_from_day <= S may be selected."
##
## So a transition has FOUR observable phases, and this fixture measures each one as
## its own phase instead of collapsing two of them:
##
##   1. PENDING     the request is in flight and its Effect batch is not ACKed yet
##                  -> it contributes NOTHING (`:2313-2321`, plan 10.1).
##   2. CONFIRMED   the poll (`poll_pending_transition`, `:3845-3846`) records
##                  `derived_basis_confirmed_day = D` and
##                  `derived_basis_eligible_day = D + 1`, but
##                  `step_derived_rebuild(day)` REFUSES to adopt while `day < D + 1`
##                  (`:7045-7048`) and counts the refusal in
##                  `derived_rebuild_gated_by_eligibility`. The PREVIOUS front keeps
##                  serving.
##   3. ELIGIBLE    on day D + 1 the same rebuild adopts the confirmed projection and
##                  the new front is installed (generation +1 if the content moved).
##   4. SUPERSEDED  the next transition moves the dates again.
##
## The consequence a reader must expect from the numbers below: a card settled on day
## D publishes its derived contribution NO EARLIER THAN D + 1. Reading the layer on
## the settle day itself legitimately shows `installed = false` and
## `layer_generation = 0`. That is the runtime working as specified, not an empty
## front and not a defect.
##
## Day indices must never go backwards, but RE-ENTERING a day is legal (the accrual
## guard is `_last_day < day`, `:5019`) -- and it is what makes the settle observable
## on the day it happens, because the runtime's own poll only runs at the start of an
## ideology day:
##
##   dispatch_effect_native_modifier(); run_modifier_daily(d); ack_effect_native_modifier()
##   run_ideology_daily(d)      -> SETTLES on d, eligible_from_day = d + 1, GATED
##   run_ideology_daily(d + 1)  -> the rebuild may now adopt
##
## Nothing is relaxed: no C++ change, no DLL swap, no worker, no bypass. The call
## set is the main-thread production set.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_mechanism_equip_level_test.gd

const WIDTH := 8
const HEIGHT := 8
const ROW_SHIFT := 3
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261028
## Permanent cell card (kind 12 = SELECTOR_OWN_TERRITORY, lifecycle 0).
const CARD_KEY := "idea.public_hygiene"
## The two stats both levels of the card write. The second one is the ".cut"
## variant: its program magnitude is POSITIVE and the sign comes from the
## definition, so comparing both proves the sign survives as well as the value.
const STAT_ADD := "economy.city.birth_factor"
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const Q16_ONE := 65536
const PROGRAM_L1 := "ideology.effect.public_hygiene_l1"
const PROGRAM_L2 := "ideology.effect.public_hygiene_l2"
## `LevelPublicHygieneL2.understanding_threshold_q16`
## (`data/ideologies/default_ideology_catalog.tres:5331`): the level-1 threshold.
const L2_THRESHOLD_Q16 := 524288
## The AUTHORED per-level magnitudes, quoted from the shipped content so the runtime's
## own interpretation can be checked against the data rather than against itself:
##
##   public_hygiene_l1  birth factor +3277/65536, housing cut -5243/65536
##                      (`default_ideology_effects.tres:5336-5401`)
##   public_hygiene_l2  birth factor +5243/65536, housing cut -6554/65536
##                      (`default_ideology_effects.tres:5403-5447`)
##
## The `.cut` row is authored as a POSITIVE magnitude on a `.cut` stat key and the
## sign comes from the definition, which is why the derived delta is negative.
const L1_ADD_Q16 := 3277
const L1_CUT_Q16 := 5243
const L2_ADD_Q16 := 5243
const L2_CUT_Q16 := 6554
## Opcodes out of `ideology_runtime.h:66-79`.
const OP_DISCOVER := 1
const OP_GRANT := 2
const OP_EQUIP := 5
const OP_UNEQUIP := 6
const OP_ADD_UNDERSTANDING := 8
## `ReceiptStatus` (`ideology_runtime.h:81-85`).
const RECEIPT_PENDING := 1
const RECEIPT_SETTLED := 2
const RECEIPT_REJECTED := 3
## `Location` (`ideology_runtime.h:80`).
const LOCATION_INACTIVE := 0
const LOCATION_IDEOLOGY := 1
## The two refuse codes a second equip can produce, in the order the runtime
## tests them (`ideology_runtime.cpp:4550` then `:4555`).
const REASON_PENDING_COUNTRY := "ideology_country_transition_pending"
const REASON_PENDING_CARD := "ideology_transition_pending"
## `unequip` on a card whose location already flipped to INACTIVE (`:4580`).
const REASON_NOT_EQUIPPED := "ideology_not_equipped"
## `support_gate`'s refusal when the weighted stance is below the threshold
## (`ideology_runtime.cpp:1321-1324`): what a general-class-only population gets
## from the card's negative repeal stance.
const REASON_SUPPORT_THRESHOLD := "ideology_support_threshold_not_met"
## Population per cell: `household_farmer` (political class "farmer", repeal
## stance +8192) 3x `subsistence_farmer` (class "general", repeal stance -8192).
## The 3:1 ratio is what keeps the weighted REPEAL support positive, which is what
## makes `unequip` reachable at all -- see the header.
const POP_FARMER := 60
const POP_GENERAL := 20
## World C's general-only population (the negative control).
const POP_C_GENERAL := 80
## `evaluate_effect_program_magnitude` takes a fixed metric vector; the programs
## read none of it.
const METRIC_SLOTS := 120
const MAX_SLICES := 512

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
var _summary: Array = []


func _init() -> void:
	_run()


func _run() -> void:
	# The SHIPPED catalog first, from a pristine resource: `load_default()` hands
	# back the cached instance, so world B's synergy erasure must happen AFTER the
	# shipped compile or both worlds would lose their synergies.
	_catalogs = _compile_catalogs(false, "A(68 synergies)")
	if _catalogs.is_empty():
		_finish()
		return
	var ids: PackedStringArray = _catalogs["native_ideology"].get(
		"ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("catalog: the card %s is in the compiled ideology catalog" % CARD_KEY,
		dense >= 0, "dense=%d of %d" % [dense, ids.size()])
	if dense < 0:
		_finish()
		return
	_catalogs["dense"] = dense
	var capacity := int(_catalogs["native_ideology"].get("ideology_capacity", -1))
	var synergy_count := (_catalogs["native_ideology"].get(
		"synergy_ids", PackedStringArray()) as PackedStringArray).size()
	_expect("catalog: the shipped catalog carries synergies, so the COUNTRY-level "
		+ "pending guard is live (equip/unequip/level all bail while one is in flight)",
		synergy_count > 0, "synergy_ids=%d" % synergy_count)
	_expect("catalog: the shipped slot budget is a positive number of slots",
		capacity >= 1, "ideology_capacity=%d" % capacity)
	_summary.append("catalog: capacity=%d synergies=%d" % [capacity, synergy_count])

	_phase_a_equip_level_unequip(dense)
	_phase_b_pending_guard_isolation(dense)
	_phase_c_repeal_negative_control(dense)
	_finish()


# =========================================================================
# world A: equip -> guard -> settle -> level -> unequip -> guard -> settle
# =========================================================================

func _phase_a_equip_level_unequip(dense: int) -> void:
	print("[EM] ========== world A: equip / level / unequip (shipped catalog) ==========")
	var world: Dictionary = _new_world(_catalogs, "A")
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var owned: int = int(world["owned"])
	# One equipped level row writes one contribution per (stat, cell): the card's
	# two stats over every owned cell.
	var card_rows: int = 2 * owned
	var slots_capacity := int(ext.get_ideology_snapshot(handle).get(
		"ideology_slots_capacity", -1))
	print("[EM] A/territory: owned=%d of %d cells -> the card must contribute %d rows"
		% [owned, CELLS, card_rows])

	var l1_add := _program_magnitude(ext, PROGRAM_L1, "L1")
	var cut_baseline := _probe_all(ext, STAT_CUT)

	# ---- EQUIP ---------------------------------------------------------
	print("[EM] ---- A1: equip, pre-settle ----")
	_submit(ext, OP_GRANT, 0, -1, 64 * Q16_ONE, handle, "grant")
	_submit(ext, OP_DISCOVER, 0, dense, 0, handle, "discover")
	var equip_seq := _submit(ext, OP_EQUIP, 0, dense, 0, handle, "equip")
	_run_one_ideology_day(ext, 0, "A/equip")
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var report: Dictionary = ext.get_ideology_report()
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var explain: Dictionary = ext.explain_ideology(handle, dense)
	_print_support("A1", explain)
	_print_state("A1 equip (pre-settle)", snap, layer, report)

	_expect("A1 equip: the equip command is admitted and the card occupies the "
		+ "IDEOLOGY slot at level 0",
		snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_IDEOLOGY])
		and snap.get("levels", PackedInt32Array()) == PackedInt32Array([0]),
		"locations=%s levels=%s" % [str(snap.get("locations", "?")),
			str(snap.get("levels", "?"))])
	_expect("A1 equip: the equip leaves a transition IN FLIGHT "
		+ "(pending_transitions == 1) until the Effect adapters ACK it",
		int(report.get("pending_transitions", -1)) == 1,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	_expect("A1 equip: the slot budget counts the card while the transition is in "
		+ "flight", int(snap.get("ideology_slots_used", -1)) == 1
		and int(snap.get("ideology_slots_capacity", -1)) >= 1,
		"slots_used=%s of %s" % [str(snap.get("ideology_slots_used", "?")),
			str(snap.get("ideology_slots_capacity", "?"))])
	# ---- WHICH CONTRIBUTION DOES A PENDING EQUIP MAKE? NONE (plan 10.1) ----
	# `equip` already wrote `location` at REQUEST time (`start_transition`,
	# ideology_runtime.cpp:3631-3633), which is why the slot checks above pass, but
	# `collect_effect_activations` contributes NOTHING while the transition is
	# unACKed and `previous_location == INACTIVE` (:2313-2321) -- plan 10.1: "an
	# unACKed equip contributes nothing". So the day-0 rebuild publishes no front
	# and these two checks pin that half. The settled half -- front installed, two
	# stats, cells == card_rows -- is asserted at A4, on day D + 1, because the
	# settle day itself is GATED by the new eligibility rule (plan 9.3) and is
	# asserted separately at A3. These two checks REPLACED two that asserted the old
	# behaviour (a front already built from the new location before the ACK); the
	# shape they covered moved to A4 rather than being dropped.
	_expect("A1 equip: an unACKed equip publishes NO front at all (plan 10.1: a "
		+ "pending equip contributes nothing)",
		not bool(layer.get("installed", true))
		and int(layer.get("cell_count", -1)) == 0
		and _front_contributions(layer) == 0,
		"installed=%s cells=%s contributions=%s expected=0 rows" % [
			str(layer.get("installed", "?")), str(layer.get("cell_count", "?")),
			_front_text(layer)])
	_expect("A1 equip: the front therefore sums ZERO stats while the equip is "
		+ "pending (nothing lands before the ACK)",
		int(layer.get("stat_count", 0)) == 0,
		"stat_count=%s" % str(layer.get("stat_count", "?")))

	# ---- SECOND EQUIP WHILE PENDING ------------------------------------
	print("[EM] ---- A2: a second equip while one is pending ----")
	var second_seq := _submit(ext, OP_EQUIP, 0, dense, 0, handle,
		"equip-while-pending")
	_run_one_ideology_day(ext, 1, "A/equip-while-pending")
	var second := _receipt(ext, second_seq)
	var report2: Dictionary = ext.get_ideology_report()
	print("[EM] A2 receipt: opcode=%d status=%d reason='%s'"
		% [int(second.get("opcode", -1)), int(second.get("status", -1)),
			String(second.get("reason", ""))])
	_expect("A2 equip: a SECOND equip while one transition is pending is REFUSED "
		+ "by the pending guard (country level, because the shipped catalog has "
		+ "synergies: ideology_runtime.cpp:4550)",
		int(second.get("status", -1)) == RECEIPT_REJECTED
		and String(second.get("reason", "")) == REASON_PENDING_COUNTRY,
		"status=%s reason='%s'" % [str(second.get("status", "?")),
			String(second.get("reason", ""))])
	_expect("A2 equip: the refusal does NOT consume the command queue and does NOT "
		+ "settle or break the transition that is already in flight",
		int(report2.get("pending_commands", -1)) == 0
		and int(report2.get("pending_transitions", -1)) == 1,
		"pending_commands=%s pending_transitions=%s" % [
			str(report2.get("pending_commands", "?")),
			str(report2.get("pending_transitions", "?"))])

	# ---- SETTLE (the handshake) ----------------------------------------
	# Day 1: the adapters ACK the equip's level batch, and RE-ENTERING day 1 is what
	# lets the runtime's own poll turn that ACK into a settled transition. Settling
	# on day 1 means `confirmed = 1` and `eligible_from_day = 2`, so the rebuild on
	# day 1 must be REFUSED (plan 9.3) -- which is the phase this fixture now pins.
	print("[EM] ---- A3 (day 1): the native adapter handshake, settled but NOT "
		+ "yet eligible ----")
	var served := _serve_native_adapters(ext, 1, "A")
	_expect("A3 settle: the native Effect adapters accepted and ACKED the equip's "
		+ "level commands", bool(served.get("ok", false))
		and bool(served.get("effect_acked", false)), str(served))
	_run_one_ideology_day(ext, 1, "A/settle")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A3 settled (day 1, before eligibility)", snap, layer, report)
	_print_basis("A3 settled (day 1)", report)
	_expect("A3 settle: after the handshake the transition is SETTLED "
		+ "(pending_transitions == 0)", int(report.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	_expect("A3 settle: the card is ACTIVE in the IDEOLOGY slot at level 0",
		snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_IDEOLOGY])
		and snap.get("levels", PackedInt32Array()) == PackedInt32Array([0]),
		"locations=%s levels=%s" % [str(snap.get("locations", "?")),
			str(snap.get("levels", "?"))])
	# ---- THE FOURTH PHASE (plan 9.3): SETTLED BUT NOT YET ELIGIBLE ------
	#
	# The transition really is settled above (pending_transitions == 0), and yet the
	# derived basis is NOT usable on this day: the poll recorded `confirmed = 1` and
	# `eligible_from_day = 2`, and `step_derived_rebuild(1)` refuses because
	# `1 < 2` (`:7045-7048`). The refusal is counted, and the previously installed
	# front (here: none, because the equip never had one) keeps serving.
	var confirmed_a := int(report.get("derived_basis_confirmed_day", -2))
	var eligible_a := int(report.get("derived_basis_eligible_day", -2))
	var gated_a := int(report.get("derived_rebuild_gated_by_eligibility", -1))
	_expect("A3 basis: the settle CONFIRMS the projection on day 1 and makes it "
		+ "eligible from day 2 (plan 9.3: eligible_from_day = confirmed_day + 1)",
		confirmed_a == 1 and eligible_a == confirmed_a + 1,
		"confirmed_day=%d eligible_day=%d (expected 1 and 2)"
			% [confirmed_a, eligible_a])
	_expect("A3 basis: the day-1 rebuild is REFUSED by the eligibility gate and the "
		+ "refusal is COUNTED (derived_rebuild_gated_by_eligibility > 0)",
		gated_a > 0, "gated=%d" % gated_a)
	_expect("A3 settle: on the settle day itself the front is STILL NOT INSTALLED -- "
		+ "the confirmed projection is not adopted before eligible_from_day (plan 9.3)",
		not bool(layer.get("installed", true))
		and int(layer.get("cell_count", -1)) == 0
		and _front_contributions(layer) == 0
		and int(layer.get("stat_count", 0)) == 0,
		"installed=%s cells=%s contributions=%s stats=%s (expected none)"
			% [str(layer.get("installed", "?")),
				str(layer.get("cell_count", "?")), _front_text(layer),
				str(layer.get("stat_count", "?"))])
	_expect("A3 settle: therefore NO cell carries the new L1 contribution on the "
		+ "settle day (the contribution is one day away, not zero)",
		_present_count(ext, STAT_ADD) == 0
		and _present_count(ext, STAT_CUT) == 0,
		"add=%d cut=%d present" % [_present_count(ext, STAT_ADD),
			_present_count(ext, STAT_CUT)])
	_summary.append("A basis (plan 9.3): settled on day 1, confirmed=1 eligible=2, "
		+ "gated=%d, front still not installed on the settle day" % gated_a)

	# ---- ELIGIBILITY DAY: D + 1 ----------------------------------------
	print("[EM] ---- A4 (day 2 = D + 1): the rebuild may now ADOPT ----")
	_run_one_ideology_day(ext, 2, "A/adopt")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A4 adopted (day 2 = D + 1)", snap, layer, report)
	_print_basis("A4 adopted (day 2)", report)
	_expect("A4 adopt: on day D + 1 the eligibility gate does NOT fire again (no new "
		+ "refusal is counted)",
		int(report.get("derived_rebuild_gated_by_eligibility", -1)) == gated_a,
		"%d -> %s (expected unchanged)" % [gated_a,
			str(report.get("derived_rebuild_gated_by_eligibility", "?"))])
	_expect("A4 adopt: the adopted front is stamped with the ADOPTION day, not the "
		+ "confirmation day (front sample_day == 2)",
		int(layer.get("sample_day", -1)) == 2,
		"sample_day=%s expected=2" % str(layer.get("sample_day", "?")))
	# The shape half of A1, on the ADOPTED side: now the front really is the
	# card's two stats over every owned cell, which neither the pending read nor
	# the settle-day read could show.
	_expect("A4 adopt: the adopted front holds exactly the card's rows -- 2 stats "
		+ "x %d owned cells" % owned,
		bool(layer.get("installed", false))
		and int(layer.get("cell_count", -1)) == card_rows
		and _front_contributions(layer) == card_rows,
		"installed=%s cells=%s contributions=%s expected=%d" % [
			str(layer.get("installed", "?")), str(layer.get("cell_count", "?")),
			_front_text(layer), card_rows])
	_expect("A4 adopt: the front covers exactly the card's two stats",
		int(layer.get("stat_count", -1)) == 2,
		"stat_count=%s" % str(layer.get("stat_count", "?")))
	_expect("A4 adopt: every owned cell carries the card's two derived stats",
		_all_cells_present(ext, STAT_ADD, world["owned_cells"], true)
		and _all_cells_present(ext, STAT_CUT, world["owned_cells"], true),
		"add=%s cut=%s" % [_present_count(ext, STAT_ADD),
			_present_count(ext, STAT_CUT)])
	_expect("A4 adopt: NO unowned cell carries a derived contribution",
		_no_unowned_present(ext, STAT_ADD, world["owned_cells"])
		and _no_unowned_present(ext, STAT_CUT, world["owned_cells"]),
		"add=%s cut=%s" % [_present_count(ext, STAT_ADD),
			_present_count(ext, STAT_CUT)])
	var l1_add_cell := _covered_add(ext, STAT_ADD)
	var l1_cut_cell := _covered_add(ext, STAT_CUT)
	_expect("A4 adopt: the covered cell's add is the L1 program magnitude "
		+ "(%.8f from evaluate_effect_program_magnitude)" % l1_add,
		absf(l1_add_cell - l1_add) <= 1e-6,
		"derived=%.8f expected=%.8f" % [l1_add_cell, l1_add])
	_expect("A4 adopt: the .cut stat's derived delta is NEGATIVE at L1",
		l1_cut_cell < 0.0, "cut=%.8f" % l1_cut_cell)
	_expect("A4 adopt: the L1 numbers are the CATALOG's authored ones -- add "
		+ "%d/Q16 and cut -%d/Q16 (default_ideology_effects.tres:5336-5401)"
		% [L1_ADD_Q16, L1_CUT_Q16],
		absf(l1_add_cell - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6
		and absf(l1_cut_cell - (-float(L1_CUT_Q16) / float(Q16_ONE))) <= 1e-6,
		"add=%.8f (authored %.8f) cut=%.8f (authored %.8f)" % [
			l1_add_cell, float(L1_ADD_Q16) / float(Q16_ONE), l1_cut_cell,
			-float(L1_CUT_Q16) / float(Q16_ONE)])
	print("[EM] A4 magnitudes: add=%.8f cut=%.8f (L1)" % [l1_add_cell, l1_cut_cell])
	var layer_generation_l1 := int(layer.get("layer_generation", -1))
	_summary.append("A equip adopted on day 2 (D + 1): cells=%d contributions=%d "
		% [int(layer.get("cell_count", -1)),
			_front_contributions(layer)]
		+ "add=%.8f cut=%.8f" % [l1_add_cell, l1_cut_cell])

	# ---- LEVEL ADVANCEMENT ---------------------------------------------
	print("[EM] ---- A5 (day 3): level advancement (ADD_UNDERSTANDING %d) ----"
		% L2_THRESHOLD_Q16)
	var report_before: Dictionary = ext.get_ideology_report()
	var understanding_before := int((snap.get("understanding_q16",
		PackedInt64Array()) as PackedInt64Array)[0])
	var levels_advanced_before := int(report_before.get("levels_advanced", -1))
	var commands_applied_before := int(report_before.get("commands_applied", -1))
	_expect("A5 level: before the change the card is at level 0 and its "
		+ "understanding is below the level-1 threshold",
		snap.get("levels", PackedInt32Array()) == PackedInt32Array([0])
		and understanding_before < L2_THRESHOLD_Q16,
		"levels=%s understanding=%d threshold=%d" % [
			str(snap.get("levels", "?")), understanding_before,
			L2_THRESHOLD_Q16])
	_submit(ext, OP_ADD_UNDERSTANDING, 3, dense, L2_THRESHOLD_Q16, handle,
		"understanding")
	_run_one_ideology_day(ext, 3, "A/level")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A5 level (command day 3)", snap, layer, report)
	var understanding_after := int((snap.get("understanding_q16",
		PackedInt64Array()) as PackedInt64Array)[0])
	_expect("A5 level: the level ADVANCES by exactly 1 on the command day",
		snap.get("levels", PackedInt32Array()) == PackedInt32Array([1]),
		"levels=%s" % str(snap.get("levels", "?")))
	_expect("A5 level: the understanding CROSSES the level-1 threshold (%d)"
		% L2_THRESHOLD_Q16,
		understanding_after >= L2_THRESHOLD_Q16
		and understanding_after > understanding_before,
		"%d -> %d (threshold %d)" % [understanding_before, understanding_after,
			L2_THRESHOLD_Q16])
	_expect("A5 level: the report's levels_advanced counter increments by 1",
		int(report.get("levels_advanced", -1)) == levels_advanced_before + 1,
		"%d -> %s" % [levels_advanced_before,
			str(report.get("levels_advanced", "?"))])
	_expect("A5 level: the report's commands_applied counter increments",
		int(report.get("commands_applied", -1)) > commands_applied_before,
		"%d -> %s" % [commands_applied_before,
			str(report.get("commands_applied", "?"))])
	var l2_add := _program_magnitude(ext, PROGRAM_L2, "L2")
	# ---- THE PENDING WINDOW STILL SERVES THE OLD LEVEL (plan 10.1) ----------
	# "a pending level-up keeps the old level": `start_transition` already wrote
	# `state.level = 1` at REQUEST time (:3633), but `collect_effect_activations`
	# serves `transition.previous_level` while the transition is unACKed
	# (:2316-2321). So on THIS day the covered cell must still read the L1
	# magnitudes; the L2 ones may only appear one day after A6 settles the batch
	# (A7, day E + 1), because the confirmed projection is not eligible before E + 1.
	# Measured before the runtime change: the pending cell already read L2, which
	# made "L1 -> L2" unobservable and every number below a settled number.
	var pending_add_cell := _covered_add(ext, STAT_ADD)
	var pending_cut_cell := _covered_add(ext, STAT_CUT)
	print("[EM] A5 magnitudes (PENDING, pre-ACK): add=%.8f cut=%.8f "
		% [pending_add_cell, pending_cut_cell]
		+ "(L1 %.8f/%.8f, L2 %.8f/%.8f)" % [l1_add, -float(L1_CUT_Q16)
			/ float(Q16_ONE), l2_add, -float(L2_CUT_Q16) / float(Q16_ONE)])
	_expect("A5 level: the level-up leaves a transition IN FLIGHT "
		+ "(pending_transitions == 1) -- every magnitude below is measured while it "
		+ "is UNACKed",
		int(report.get("pending_transitions", -1)) == 1,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	_expect("A5 level: while PENDING the covered cell still serves the OLD L1 add "
		+ "(plan 10.1: a pending level-up keeps the old level) and NOT the L2 one",
		absf(pending_add_cell - l1_add) <= 1e-6
		and absf(pending_add_cell - l2_add) > 0.02,
		"derived=%.8f L1=%.8f L2=%.8f" % [pending_add_cell, l1_add, l2_add])
	_expect("A5 level: the two authored levels really differ, so the comparison "
		+ "above discriminates (the derived magnitudes are not a constant)",
		absf(l2_add - l1_add) > 0.02,
		"L1 %.8f vs L2 %.8f" % [l1_add, l2_add])
	_expect("A5 level: the .cut magnitude is also still the OLD L1 one while "
		+ "pending (negative, and not yet the deeper L2 cut)",
		pending_cut_cell < 0.0
		and absf(pending_cut_cell - l1_cut_cell) <= 1e-6
		and absf(pending_cut_cell - (-float(L2_CUT_Q16) / float(Q16_ONE))) > 1e-4,
		"cut %.8f (pending) L1 %.8f L2 %.8f" % [pending_cut_cell, l1_cut_cell,
			-float(L2_CUT_Q16) / float(Q16_ONE)])
	# ABSOLUTE correctness of the PENDING numbers against the authored L1 data, so
	# "still L1" is pinned to real numbers rather than to "not L2".
	_expect("A5 level: both PENDING magnitudes are the CATALOG's authored L1 ones -- "
		+ "add %d/Q16 and cut -%d/Q16" % [L1_ADD_Q16, L1_CUT_Q16],
		absf(pending_add_cell - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6
		and absf(pending_cut_cell - (-float(L1_CUT_Q16) / float(Q16_ONE))) <= 1e-6,
		"add=%.8f (authored %.8f) cut=%.8f (authored %.8f)" % [
			pending_add_cell, float(L1_ADD_Q16) / float(Q16_ONE), pending_cut_cell,
			-float(L1_CUT_Q16) / float(Q16_ONE)])
	_expect("A5 level: the front still covers exactly the card's rows after the "
		+ "level change (same shape, still the OLD numbers)",
		int(layer.get("cell_count", -1)) == card_rows
		and _front_contributions(layer) == card_rows,
		"cells=%s contributions=%s expected=%d" % [
			str(layer.get("cell_count", "?")),
			_front_text(layer), card_rows])
	_expect("A5 level: the pending day's fold is content-identical to the L1 front "
		+ "adopted on day 2, so the front is NOT re-installed (I13: generation "
		+ "unchanged while the level-up is unACKed)",
		int(layer.get("layer_generation", -1)) == layer_generation_l1,
		"%d -> %s (expected unchanged)" % [layer_generation_l1,
			str(layer.get("layer_generation", "?"))])

	# ---- SETTLE THE LEVEL TRANSITION -----------------------------------
	# Day 3 again: the adapters ACK the level-up's batch, and re-entering day 3 lets
	# the runtime's own poll settle it ON day 3 -> confirmed = 3,
	# eligible_from_day = 4. The front must keep serving L1 for the whole settle day
	# (phase 2 of 9.3), which is strictly stronger than the old expectation that the
	# settle already showed L2.
	print("[EM] ---- A6 (day 3): the level-up settles -- basis confirmed, front "
		+ "still L1 ----")
	var gen_before_level_settle := int(layer.get("layer_generation", -1))
	var gated_before_level_settle := int(
		report.get("derived_rebuild_gated_by_eligibility", -1))
	_serve_native_adapters(ext, 3, "A/level")
	_run_one_ideology_day(ext, 3, "A/level-settle")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A6 level settled (day 3, before eligibility)", snap, layer, report)
	_print_basis("A6 level settled (day 3)", report)
	_expect("A6 level settle: the level transition settles through the same "
		+ "handshake (pending_transitions == 0)",
		int(report.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	_expect("A6 level settle: the card keeps its earned level 1 in the "
		+ "IDEOLOGY slot",
		snap.get("levels", PackedInt32Array()) == PackedInt32Array([1])
		and snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_IDEOLOGY]),
		"levels=%s locations=%s" % [str(snap.get("levels", "?")),
			str(snap.get("locations", "?"))])
	var confirmed_l := int(report.get("derived_basis_confirmed_day", -2))
	var eligible_l := int(report.get("derived_basis_eligible_day", -2))
	var gated_l := int(report.get("derived_rebuild_gated_by_eligibility", -1))
	_expect("A6 basis: the level-up settle CONFIRMS the projection on day 3 and makes "
		+ "it eligible from day 4 (plan 9.3: eligible_from_day = confirmed_day + 1)",
		confirmed_l == 3 and eligible_l == confirmed_l + 1,
		"confirmed_day=%d eligible_day=%d (expected 3 and 4)"
			% [confirmed_l, eligible_l])
	_expect("A6 basis: the day-3 rebuild is REFUSED by the eligibility gate again, so "
		+ "the refusal counter RISES on the settle day",
		gated_l > gated_before_level_settle,
		"%d -> %d" % [gated_before_level_settle, gated_l])
	# THE CONSEQUENCE, measured rather than asserted from the code above: the level is
	# already settled and the card is at level 1, and the derived front still serves
	# the L1 magnitudes because L2 only becomes eligible on day 4.
	var still_l1_add := _covered_add(ext, STAT_ADD)
	var still_l1_cut := _covered_add(ext, STAT_CUT)
	print("[EM] A6 magnitudes (settled, day 3, NOT eligible yet): add=%.8f cut=%.8f "
		% [still_l1_add, still_l1_cut]
		+ "(L1 %.8f/%.8f, L2 %.8f/%.8f)" % [l1_add, -float(L1_CUT_Q16)
			/ float(Q16_ONE), l2_add, -float(L2_CUT_Q16) / float(Q16_ONE)])
	_expect("A6 level settle: the level is SETTLED and yet the front STILL serves the "
		+ "OLD L1 add -- the confirmed L2 projection is not eligible before day 4",
		absf(still_l1_add - l1_add) <= 1e-6
		and absf(still_l1_add - l2_add) > 0.02,
		"derived=%.8f L1=%.8f L2=%.8f" % [still_l1_add, l1_add, l2_add])
	_expect("A6 level settle: the .cut magnitude is still the OLD L1 one too "
		+ "(negative, and not yet the deeper L2 cut)",
		still_l1_cut < 0.0
		and absf(still_l1_cut - l1_cut_cell) <= 1e-6
		and absf(still_l1_cut - (-float(L2_CUT_Q16) / float(Q16_ONE))) > 1e-4,
		"cut %.8f (settled) L1 %.8f L2 %.8f" % [still_l1_cut, l1_cut_cell,
			-float(L2_CUT_Q16) / float(Q16_ONE)])
	_expect("A6 level settle: the front was NOT re-installed on the settle day -- the "
		+ "gate kept the previous front, so the generation does not move",
		int(layer.get("layer_generation", -1)) == gen_before_level_settle,
		"%d -> %s (expected unchanged)" % [gen_before_level_settle,
			str(layer.get("layer_generation", "?"))])
	_expect("A6 level settle: the front still covers exactly the card's rows",
		int(layer.get("cell_count", -1)) == card_rows
		and _front_contributions(layer) == card_rows,
		"cells=%s contributions=%s expected=%d" % [
			str(layer.get("cell_count", "?")), _front_text(layer), card_rows])

	# ---- ELIGIBILITY DAY FOR THE LEVEL: E + 1 ---------------------------
	print("[EM] ---- A7 (day 4 = E + 1): the L2 projection may now be ADOPTED ----")
	_run_one_ideology_day(ext, 4, "A/level-adopt")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A7 level adopted (day 4)", snap, layer, report)
	_print_basis("A7 level adopted (day 4)", report)
	# EXPECTED NUMBER, derived from the new semantics rather than relaxed: the content
	# really does change here -- A5/A6 measured the front serving L1 (pending, then
	# settled but not eligible) and the L2 projection becomes eligible on day 4 -- so
	# the fold result differs from the installed L1 front and the front is
	# re-installed exactly ONCE, generation +1. The old expectation ("generation
	# unchanged") was only true while the settle day ALREADY served L2, which is the
	# behaviour the eligibility gate removed.
	_expect("A7 adopt: on day E + 1 the front is re-installed exactly once, because the "
		+ "content moves from L1 to L2 here (I13)",
		int(layer.get("layer_generation", -1)) == gen_before_level_settle + 1,
		"%d -> %s (expected %d)" % [gen_before_level_settle,
			str(layer.get("layer_generation", "?")),
			gen_before_level_settle + 1])
	var l2_add_cell := _covered_add(ext, STAT_ADD)
	var l2_cut_cell := _covered_add(ext, STAT_CUT)
	print("[EM] A7 magnitudes (adopted, day 4): add=%.8f cut=%.8f (L2)"
		% [l2_add_cell, l2_cut_cell])
	_expect("A7 adopt: the adopted front carries the L2 program magnitude",
		absf(l2_add_cell - l2_add) <= 1e-6,
		"derived=%.8f expected=%.8f" % [l2_add_cell, l2_add])
	_expect("A7 adopt: the adopted cell really MOVED off the L1 values it served "
		+ "while pending and on the settle day (both stats)",
		absf(l2_add_cell - l1_add_cell) > 0.02
		and absf(l2_cut_cell - l1_cut_cell) > 2e-3,
		"add L1 %.8f -> L2 %.8f, cut L1 %.8f -> L2 %.8f" % [l1_add_cell,
			l2_add_cell, l1_cut_cell, l2_cut_cell])
	# ABSOLUTE correctness of the new level, against the authored data rather than
	# against the previous level: the two numbers below are what the content table
	# says the L2 row is (`default_ideology_effects.tres:5403-5447`).
	_expect("A7 adopt: both adopted magnitudes are the CATALOG's authored L2 "
		+ "ones -- add %d/Q16 and cut -%d/Q16" % [L2_ADD_Q16, L2_CUT_Q16],
		absf(l2_add_cell - float(L2_ADD_Q16) / float(Q16_ONE)) <= 1e-6
		and absf(l2_cut_cell - (-float(L2_CUT_Q16) / float(Q16_ONE))) <= 1e-6,
		"add=%.8f (authored %.8f) cut=%.8f (authored %.8f)" % [
			l2_add_cell, float(L2_ADD_Q16) / float(Q16_ONE), l2_cut_cell,
			-float(L2_CUT_Q16) / float(Q16_ONE)])
	_expect("A7 adopt: the adopted front still covers exactly the card's rows",
		int(layer.get("cell_count", -1)) == card_rows
		and _front_contributions(layer) == card_rows,
		"cells=%s contributions=%s expected=%d" % [
			str(layer.get("cell_count", "?")), _front_text(layer), card_rows])
	_summary.append("A level up: level 0 -> 1, understanding %d -> %d, "
		% [understanding_before, understanding_after]
		+ "add %.8f -> %.8f on day 4 (E + 1), levels_advanced %d -> %d"
		% [l1_add_cell, l2_add_cell, levels_advanced_before,
			int(report.get("levels_advanced", -1))])

	# ---- UNEQUIP -------------------------------------------------------
	# An UNEQUIP is the one transition where the pending window is already the final
	# answer: `collect_effect_activations` returns before adding a template while
	# `state.location == INACTIVE` (`:2313`), and `start_transition` writes INACTIVE
	# at REQUEST time, so the request-day rebuild already publishes the empty front.
	# The eligibility day still moves (plan 9.3), which is asserted at A10.
	print("[EM] ---- A8 (day 5): unequip ----")
	var ex_before: Dictionary = ext.explain_ideology(handle, dense)
	_print_support("A8 (before unequip)", ex_before)
	var slots_before := int(snap.get("ideology_slots_used", -1))
	var cells_before := int(layer.get("cell_count", -1))
	var contribs_before := _front_contributions(layer)
	var unequip_seq := _submit(ext, OP_UNEQUIP, 5, dense, 0, handle, "unequip")
	_run_one_ideology_day(ext, 5, "A/unequip")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A8 unequip (request day, pre-settle)", snap, layer, report)
	var unequip_receipt := _receipt(ext, unequip_seq)
	print("[EM] A8 unequip receipt: status=%d reason='%s'"
		% [int(unequip_receipt.get("status", -1)),
			String(unequip_receipt.get("reason", ""))])
	_expect("A8 unequip: the unequip command is ACCEPTED (the class-opinion "
		+ "REPEAL gate passes with this fixture's farmer population)",
		int(unequip_receipt.get("status", -1)) != RECEIPT_REJECTED,
		"status=%s reason='%s' (measured support=%s threshold=%s allowed=%s)" % [
			str(unequip_receipt.get("status", "?")),
			String(unequip_receipt.get("reason", "")),
			str(ex_before.get("support_q16", "?")),
			str(ex_before.get("support_thresholds_q16", "?")),
			str(ex_before.get("support_allowed", "?"))])
	_expect("A8 unequip: the unequip leaves its own transition IN FLIGHT",
		int(report.get("pending_transitions", -1)) == 1,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	var cells_after := int(layer.get("cell_count", -1))
	var contribs_after := _front_contributions(layer)
	print("[EM] A8 front: cells %d -> %d, contributions %d -> %d "
		% [cells_before, cells_after, contribs_before, contribs_after]
		+ "(the card owned exactly %d rows)" % card_rows)
	_expect("A8 unequip: a PENDING unequip already contributes nothing (location is "
		+ "INACTIVE at request time, :2313), so the card's rows leave the front on "
		+ "the request day -- cell_count falls by EXACTLY the card's rows",
		cells_before - cells_after == card_rows,
		"%d - %d = %d, expected %d" % [cells_before, cells_after,
			cells_before - cells_after, card_rows])
	_expect("A8 unequip: the front's contribution_count falls by EXACTLY the "
		+ "card's rows too (an absent key means the no-front branch of "
		+ "world_ext_modifier.cpp:1082-1086, i.e. zero rows)",
		contribs_before - contribs_after == card_rows,
		"%d - %d = %d, expected %d" % [contribs_before, contribs_after,
			contribs_before - contribs_after, card_rows])
	_expect("A8 unequip: the front is the explicit EMPTY result (no stale rows left "
		+ "behind)", cells_after == 0 and contribs_after == 0
		and not bool(layer.get("installed", true)),
		"installed=%s cells=%d contributions=%d (raw key: %s)" % [
			str(layer.get("installed", "?")), cells_after, contribs_after,
			_front_text(layer)])
	_expect("A8 unequip: NO cell still reports a derived contribution",
		_present_count(ext, STAT_ADD) == 0 and _present_count(ext, STAT_CUT) == 0,
		"add=%d cut=%d" % [_present_count(ext, STAT_ADD),
			_present_count(ext, STAT_CUT)])

	# ---- SECOND UNEQUIP WHILE PENDING ----------------------------------
	print("[EM] ---- A9 (day 6): a second unequip while one is pending ----")
	var second_unequip_seq := _submit(ext, OP_UNEQUIP, 5, dense, 0, handle,
		"unequip-while-pending")
	_run_one_ideology_day(ext, 6, "A/unequip-while-pending")
	var second_unequip := _receipt(ext, second_unequip_seq)
	print("[EM] A9 receipt: status=%d reason='%s'"
		% [int(second_unequip.get("status", -1)),
			String(second_unequip.get("reason", ""))])
	_expect("A9 unequip: a SECOND unequip while one transition is pending is "
		+ "REFUSED by the pending guard (ideology_runtime.cpp:4576)",
		int(second_unequip.get("status", -1)) == RECEIPT_REJECTED
		and String(second_unequip.get("reason", "")) == REASON_PENDING_COUNTRY,
		"status=%s reason='%s'" % [str(second_unequip.get("status", "?")),
			String(second_unequip.get("reason", ""))])

	# ---- SETTLE THE UNEQUIP --------------------------------------------
	# Day 6 again: the adapters ACK the remove batch and re-entering day 6 lets the
	# poll settle it on day 6 -> confirmed = 6, eligible_from_day = 7.
	print("[EM] ---- A10 (day 6): settle the unequip ----")
	var served_un := _serve_native_adapters(ext, 6, "A/unequip")
	_expect("A10 unequip settle: the native adapters ACKED the unequip's remove "
		+ "commands", bool(served_un.get("ok", false))
		and bool(served_un.get("effect_acked", false)), str(served_un))
	_run_one_ideology_day(ext, 6, "A/unequip-settle")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A10 unequipped (day 6, settled)", snap, layer, report)
	_print_basis("A10 unequipped (day 6)", report)
	_expect("A10 unequip: after the handshake the transition is SETTLED and the "
		+ "IDEOLOGY slot is EMPTY",
		int(report.get("pending_transitions", -1)) == 0
		and snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_INACTIVE]),
		"pending_transitions=%s locations=%s" % [
			str(report.get("pending_transitions", "?")),
			str(snap.get("locations", "?"))])
	var confirmed_u := int(report.get("derived_basis_confirmed_day", -2))
	var eligible_u := int(report.get("derived_basis_eligible_day", -2))
	_expect("A10 basis: the unequip settle also moves the basis dates (confirmed 6, "
		+ "eligible 7), so the next confirmed projection is what day 7 may adopt",
		confirmed_u == 6 and eligible_u == confirmed_u + 1,
		"confirmed_day=%d eligible_day=%d (expected 6 and 7)"
			% [confirmed_u, eligible_u])
	_expect("A10 unequip: the settle does not resurrect a single row -- the front is "
		+ "still the explicit EMPTY result",
		int(layer.get("cell_count", -1)) == 0
		and _front_contributions(layer) == 0
		and not bool(layer.get("installed", true)),
		"installed=%s cells=%s contributions=%s" % [
			str(layer.get("installed", "?")),
			str(layer.get("cell_count", "?")), _front_text(layer)])
	_expect("A10 unequip: the slot budget is FREED (ideology_slots_used returns to 0)",
		int(snap.get("ideology_slots_used", -1)) == 0
		and slots_before == 1,
		"slots_used %d -> %s of %s" % [slots_before,
			str(snap.get("ideology_slots_used", "?")),
			str(snap.get("ideology_slots_capacity", "?"))])

	# ---- THE FREED SLOT IS USABLE --------------------------------------
	# Day 7: the freed slot accepts a new equip. Its transition settles on day 7
	# (re-entered after the ACK), which makes the projection eligible on day 8 -- so
	# the front must stay EMPTY through the whole settle day and only come back on
	# day 8. That is the same 9.3 rule as the very first equip, now applied to a
	# RE-equip whose front already existed once.
	print("[EM] ---- A11 (day 7): the freed capacity slot accepts a new equip ----")
	var reequip_seq := _submit(ext, OP_EQUIP, 7, dense, 0, handle, "re-equip")
	_run_one_ideology_day(ext, 7, "A/re-equip")
	var reequip := _receipt(ext, reequip_seq)
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	print("[EM] A11 receipt: status=%d reason='%s' slots_used=%s"
		% [int(reequip.get("status", -1)), String(reequip.get("reason", "")),
			str(snap.get("ideology_slots_used", "?"))])
	_expect("A11 re-equip: a NEW equip after the unequip is ACCEPTED (the freed "
		+ "capacity slot is usable)",
		int(reequip.get("status", -1)) != RECEIPT_REJECTED
		and snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_IDEOLOGY]),
		"status=%s reason='%s' locations=%s" % [
			str(reequip.get("status", "?")),
			String(reequip.get("reason", "")),
			str(snap.get("locations", "?"))])
	_expect("A11 re-equip: while the re-equip is PENDING the front stays EMPTY (a "
		+ "pending equip contributes nothing, plan 10.1)",
		int(layer.get("cell_count", -1)) == 0
		and not bool(layer.get("installed", true)),
		"installed=%s cells=%s" % [str(layer.get("installed", "?")),
			str(layer.get("cell_count", "?"))])

	print("[EM] ---- A12 (day 7): the re-equip settles -- the front stays empty ----")
	_serve_native_adapters(ext, 7, "A/re-equip")
	_run_one_ideology_day(ext, 7, "A/re-equip-settle")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A12 re-equipped (day 7, settled, before eligibility)",
		snap, layer, report)
	_print_basis("A12 re-equipped (day 7)", report)
	_expect("A12 re-equip settle: the transition is SETTLED and the card is at level 1 "
		+ "in the IDEOLOGY slot",
		int(report.get("pending_transitions", -1)) == 0
		and snap.get("levels", PackedInt32Array()) == PackedInt32Array([1])
		and snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_IDEOLOGY]),
		"pending=%s levels=%s locations=%s" % [
			str(report.get("pending_transitions", "?")),
			str(snap.get("levels", "?")), str(snap.get("locations", "?"))])
	_expect("A12 re-equip settle: the settle day publishes NOTHING -- the confirmed "
		+ "projection is not eligible before day 8 (plan 9.3)",
		int(layer.get("cell_count", -1)) == 0
		and _front_contributions(layer) == 0,
		"cells=%s contributions=%s" % [str(layer.get("cell_count", "?")),
			_front_text(layer)])

	print("[EM] ---- A13 (day 8 = D + 1): the re-equipped card is ADOPTED ----")
	_run_one_ideology_day(ext, 8, "A/re-equip-adopt")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("A13 re-equipped (day 8, adopted)", snap, layer, report)
	_print_basis("A13 re-equipped (day 8)", report)
	_expect("A13 re-equip adopt: on day D + 1 the card is settled and back in the front "
		+ "with exactly its %d rows" % card_rows,
		int(report.get("pending_transitions", -1)) == 0
		and snap.get("levels", PackedInt32Array()) == PackedInt32Array([1])
		and int(layer.get("cell_count", -1)) == card_rows
		and _front_contributions(layer) == card_rows,
		"pending=%s levels=%s cells=%s contributions=%s expected=%d" % [
			str(report.get("pending_transitions", "?")),
			str(snap.get("levels", "?")), str(layer.get("cell_count", "?")),
			_front_text(layer), card_rows])
	_expect("A13 re-equip adopt: the L2 magnitudes come back with the card "
		+ "(the level was never lost by the unequip)",
		absf(_covered_add(ext, STAT_ADD) - l2_add) <= 1e-6,
		"derived=%.8f expected=%.8f" % [_covered_add(ext, STAT_ADD), l2_add])
	_summary.append("A unequip: accepted on day 5, slots_used 1 -> 0, front %d -> 0 "
		% card_rows
		+ "rows on the request day, settled day 6; re-equip accepted day 7, front "
		+ "back to %d rows on day 8" % card_rows)
	var final_cut := _covered_add(ext, STAT_CUT)
	print("[EM] A/final: cut=%.8f (baseline before the equip was %.8f: the stat was "
		% [final_cut, _covered_add_of(cut_baseline)]
		+ "untouched on every cell at that point)")
	_expect("A/final: the re-equipped card at level 1 writes the authored L2 .cut "
		+ "value (-%d / Q16, default_ideology_effects.tres:5443)" % L2_CUT_Q16,
		absf(final_cut - (-float(L2_CUT_Q16) / float(Q16_ONE))) <= 1e-6,
		"derived=%.8f expected=%.8f" % [final_cut,
			-float(L2_CUT_Q16) / float(Q16_ONE)])


# =========================================================================
# world B: the per-card pending guard, with the synergy table removed
# =========================================================================

## The shipped catalog's 68 synergies make the COUNTRY-level guard
## (`pending_transition_count > 0 && !_synergies.empty()`) fire before the
## PER-CARD one, so `ideology_transition_pending` is unreachable there. Emptying
## the synergy table removes exactly that one term (it is fixture configuration of
## the Resource, compiled through the same `compile_native_catalog`, the same way
## `ideology_b1_many_countries_test.gd` raises the slot budget).
##
## Two exact codes are measured here:
##   second EQUIP   -> "ideology_transition_pending"   (`:4555`)
##   second UNEQUIP -> "ideology_not_equipped"         (`:4580`, because
##                     `start_transition` already moved the location to INACTIVE)
func _phase_b_pending_guard_isolation(dense: int) -> void:
	print("[EM] ========== world B: per-card pending guard (synergies emptied) "
		+ "==========")
	var catalogs := _compile_catalogs(true, "B(0 synergies)")
	if catalogs.is_empty():
		_expect("B catalog: the synergy-free catalog compiles", false, "")
		return
	var synergies := (catalogs["native_ideology"].get(
		"synergy_ids", PackedStringArray()) as PackedStringArray).size()
	_expect("B catalog: the fixture's catalog really has NO synergies, so the "
		+ "country-level pending term is skipped", synergies == 0,
		"synergy_ids=%d" % synergies)
	var world: Dictionary = _new_world(catalogs, "B")
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])

	_submit(ext, OP_GRANT, 0, -1, 64 * Q16_ONE, handle, "B/grant")
	_submit(ext, OP_DISCOVER, 0, dense, 0, handle, "B/discover")
	_submit(ext, OP_EQUIP, 0, dense, 0, handle, "B/equip")
	_run_one_ideology_day(ext, 0, "B/equip")
	var report: Dictionary = ext.get_ideology_report()
	_expect("B1 equip: the equip is in flight (pending_transitions == 1)",
		int(report.get("pending_transitions", -1)) == 1,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))

	var equip_seq := _submit(ext, OP_EQUIP, 0, dense, 0, handle,
		"B/equip-while-pending")
	_run_one_ideology_day(ext, 1, "B/equip-while-pending")
	var equip_receipt := _receipt(ext, equip_seq)
	print("[EM] B2 receipt: status=%d reason='%s'"
		% [int(equip_receipt.get("status", -1)),
			String(equip_receipt.get("reason", ""))])
	_expect("B2 equip: with the synergy table empty a SECOND equip while one is "
		+ "pending is REFUSED by the PER-CARD guard -- reason is exactly "
		+ "'ideology_transition_pending' (ideology_runtime.cpp:4555)",
		int(equip_receipt.get("status", -1)) == RECEIPT_REJECTED
		and String(equip_receipt.get("reason", "")) == REASON_PENDING_CARD,
		"status=%s reason='%s'" % [str(equip_receipt.get("status", "?")),
			String(equip_receipt.get("reason", ""))])
	_expect("B2 equip: the in-flight transition is untouched by the refusal",
		int(ext.get_ideology_report().get("pending_transitions", -1)) == 1,
		"pending_transitions=%s"
			% str(ext.get_ideology_report().get("pending_transitions", "?")))

	_serve_native_adapters(ext, 1, "B")
	_run_one_ideology_day(ext, 2, "B/settle")
	report = ext.get_ideology_report()
	_expect("B3 settle: the equip settles through the handshake "
		+ "(pending_transitions == 0)",
		int(report.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))

	_submit(ext, OP_UNEQUIP, 3, dense, 0, handle, "B/unequip")
	_run_one_ideology_day(ext, 3, "B/unequip")
	var unequip_seq := _submit(ext, OP_UNEQUIP, 3, dense, 0, handle,
		"B/unequip-while-pending")
	_run_one_ideology_day(ext, 4, "B/unequip-while-pending")
	var unequip_receipt := _receipt(ext, unequip_seq)
	print("[EM] B4 receipt: status=%d reason='%s'"
		% [int(unequip_receipt.get("status", -1)),
			String(unequip_receipt.get("reason", ""))])
	_expect("B4 unequip: a SECOND unequip while one is pending is REFUSED -- and "
		+ "without synergies the code is 'ideology_not_equipped', because the "
		+ "request already moved the location to INACTIVE (:4580 runs before :4581)",
		int(unequip_receipt.get("status", -1)) == RECEIPT_REJECTED
		and String(unequip_receipt.get("reason", "")) == REASON_NOT_EQUIPPED,
		"status=%s reason='%s'" % [str(unequip_receipt.get("status", "?")),
			String(unequip_receipt.get("reason", ""))])
	_serve_native_adapters(ext, 4, "B/unequip")
	_run_one_ideology_day(ext, 5, "B/unequip-settle")
	report = ext.get_ideology_report()
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("B5 unequip settle: the unequip settles and the slot is empty with no "
		+ "contribution left",
		int(report.get("pending_transitions", -1)) == 0
		and snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_INACTIVE])
		and int(layer.get("cell_count", -1)) == 0,
		"pending=%s locations=%s cells=%s" % [
			str(report.get("pending_transitions", "?")),
			str(snap.get("locations", "?")), str(layer.get("cell_count", "?"))])


# =========================================================================
# world C: negative control -- the repeal gate CAN refuse
# =========================================================================

## The unequip in world A passes because this fixture bootstraps a FARMER-majority
## population. That makes the farmer mix load-bearing, so it has to be shown that a
## different mix really does refuse the unequip -- otherwise "unequip works" would
## be unfalsifiable.
##
## World C is the same scenario with the same card and the same call set, and the
## only difference is the population: 100% `subsistence_farmer` (political class
## "general", repeal stance -8192) instead of the 3:1 farmer mix. The weighted
## repeal support becomes exactly the general stance, which is below the card's
## `repeal_threshold_q16 = 0`, and `support_gate` refuses with
## `ideology_support_threshold_not_met` (`ideology_runtime.cpp:1321-1324`).
##
## THIS is the wall an equipping fixture hits by accident -- the template world
## (`subsistence_farmer` + `serf`, both class "general") is exactly this mix, and
## its unequip is refused for a reason that has nothing to do with the harness.
func _phase_c_repeal_negative_control(dense: int) -> void:
	print("[EM] ========== world C: negative control (general-only population) "
		+ "==========")
	var world: Dictionary = _new_world(_catalogs, "C", 0, POP_C_GENERAL)
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])

	_submit(ext, OP_GRANT, 0, -1, 64 * Q16_ONE, handle, "C/grant")
	_submit(ext, OP_DISCOVER, 0, dense, 0, handle, "C/discover")
	var equip_seq := _submit(ext, OP_EQUIP, 0, dense, 0, handle, "C/equip")
	_run_one_ideology_day(ext, 0, "C/equip")
	var equip_receipt := _receipt(ext, equip_seq)
	_expect("C1 control: with a general-only population the EQUIP is still "
		+ "accepted (its adopt stance is positive), so only the repeal differs",
		int(equip_receipt.get("status", -1)) != RECEIPT_REJECTED,
		"status=%s reason='%s'" % [str(equip_receipt.get("status", "?")),
			String(equip_receipt.get("reason", ""))])
	_serve_native_adapters(ext, 0, "C")
	_run_one_ideology_day(ext, 1, "C/settle")

	var support: Dictionary = ext.explain_ideology(handle, dense)
	_print_support("C (before unequip)", support)
	var support_q16: PackedInt32Array = support.get("support_q16",
		PackedInt32Array())
	_expect("C2 control: the REPEAL support is NEGATIVE with this population "
		+ "(the general class repeal stance), i.e. below the card's threshold 0",
		support_q16.size() >= 2 and int(support_q16[1]) < 0,
		"support_q16=%s thresholds=%s" % [str(support.get("support_q16", "?")),
			str(support.get("support_thresholds_q16", "?"))])
	var unequip_seq := _submit(ext, OP_UNEQUIP, 2, dense, 0, handle,
		"C/unequip")
	_run_one_ideology_day(ext, 2, "C/unequip")
	var unequip_receipt := _receipt(ext, unequip_seq)
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	print("[EM] C3 receipt: status=%d reason='%s' locations=%s"
		% [int(unequip_receipt.get("status", -1)),
			String(unequip_receipt.get("reason", "")),
			str(snap.get("locations", "?"))])
	_expect("C3 control: the UNEQUIP is REFUSED with "
		+ "'ideology_support_threshold_not_met' -- this is the gate, not a stuck "
		+ "transition (pending_transitions is 0 here)",
		int(unequip_receipt.get("status", -1)) == RECEIPT_REJECTED
		and String(unequip_receipt.get("reason", ""))
			== REASON_SUPPORT_THRESHOLD,
		"status=%s reason='%s' pending_transitions=%s" % [
			str(unequip_receipt.get("status", "?")),
			String(unequip_receipt.get("reason", "")),
			str(ext.get_ideology_report().get("pending_transitions", "?"))])
	_expect("C3 control: the card stays equipped and serving after the refusal "
		+ "(a refused unequip is a no-op, not a half transition)",
		snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_IDEOLOGY])
		and int(ext.get_ideology_report().get("pending_transitions", -1)) == 0
		and int(ext.get_derived_cell_layer_report().get("cell_count", -1))
			== 2 * int(world["owned"]),
		"locations=%s pending=%s cells=%s" % [
			str(snap.get("locations", "?")),
			str(ext.get_ideology_report().get("pending_transitions", "?")),
			str(ext.get_derived_cell_layer_report().get("cell_count", "?"))])


# =========================================================================
# production side channel: the native Effect adapters
# =========================================================================

## Serves the native Effect adapters, which is what the daily graph does every day
## (`dispatch_effect_native_modifier` / `ack_effect_native_modifier` are bound at
## `world_ext_bind_methods.cpp:635-638`).
##
## The order is measured and mandatory:
##
##   dispatch_effect_native_modifier()  ->  run_modifier_daily(day)
##                                      ->  ack_effect_native_modifier()
##
## `run_modifier_daily` is what completes the rows the dispatch submitted to the
## Modifier runtime (`world_ext_bind_methods.cpp:471`). Without it the ack keeps
## reporting `pending`, `pending_transition_count` never returns to 0, and every
## later equip/unequip/level command is refused by the pending guard.
func _serve_native_adapters(ext: Object, day: int, label: String) -> Dictionary:
	var rounds := 0
	var ok := true
	var effect_acked := false
	var last_ack := {}
	for _i in range(8):
		rounds += 1
		ext.run_effect_daily(day)
		var d_mod: Dictionary = ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var a_mod: Dictionary = ext.ack_effect_native_modifier()
		var d_cty: Dictionary = ext.dispatch_effect_native_country()
		var a_cty: Dictionary = ext.ack_effect_native_country()
		last_ack = a_mod
		if rounds == 1:
			print("[%s/adapters] r1 modifier dispatch=%s ack=%s country=%s/%s"
				% [label, str(d_mod), str(a_mod), str(d_cty), str(a_cty)])
		if not bool(d_mod.get("ok", true)) or not bool(a_mod.get("ok", true)):
			ok = false
			print("[%s/adapters] modifier dispatch=%s ack=%s"
				% [label, str(d_mod), str(a_mod)])
			break
		if not bool(d_cty.get("ok", true)) or not bool(a_cty.get("ok", true)):
			ok = false
			print("[%s/adapters] country dispatch=%s ack=%s"
				% [label, str(d_cty), str(a_cty)])
			break
		if int(a_mod.get("acknowledged", 0)) > 0 \
				and int(a_mod.get("pending", 0)) == 0:
			# The Effect side has ACKED. The ideology runtime has not polled it
			# yet: `_pending_transitions` is drained only at the start of a
			# `run_ideology_daily` slice (`ideology_runtime.cpp:4918-4932`), so the
			# NEXT ideology day is what turns this into a settled transition.
			effect_acked = true
			break
		if int(ext.get_ideology_report().get("pending_transitions", -1)) == 0:
			effect_acked = true
			break
	var final_report: Dictionary = ext.get_ideology_report()
	print("[%s/adapters] rounds=%d effect_acked=%s pre_poll_pending_transitions=%s"
		% [label, rounds, str(effect_acked),
			str(final_report.get("pending_transitions", "?"))])
	return {"ok": ok, "rounds": rounds, "effect_acked": effect_acked,
		"pre_poll_pending_transitions": int(
			final_report.get("pending_transitions", -1)),
		"last_ack": last_ack}


# =========================================================================
# catalogs
# =========================================================================

func _compile_catalogs(drop_synergies: bool, label: String) -> Dictionary:
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
	if drop_synergies:
		# Fixture configuration of the RESOURCE (the same object each
		# `load_default()` returns, which is why the shipped compile above already
		# finished). Only the compiled Dictionary reaches the native side.
		var empty: Array[Resource] = []
		catalog.synergies = empty
	var native_ideology: Dictionary = catalog.compile_native_catalog(
		country_ir, country_ir)
	var compiled_reason := String(native_ideology.get("reason", ""))
	native_ideology.erase("ok")
	if country_ir.is_empty() or effect_ir.is_empty() or mod_ir.is_empty() \
			or native_ideology.is_empty():
		_expect("catalog %s: all four native catalogs compile" % label, false,
			"country=%d effect=%d modifier=%d ideology=%d reason='%s'"
				% [country_ir.size(), effect_ir.size(), mod_ir.size(),
					native_ideology.size(), compiled_reason])
		return {}
	var economy_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	economy_catalog.erase("ok")
	return {
		"label": label, "country_ir": country_ir, "profile": profile,
		"effect_ir": effect_ir, "mod_ir": mod_ir,
		"native_ideology": native_ideology, "economy_catalog": economy_catalog,
	}


## Declares `cell.settlement` as `cell.population >= 30`, which every cell of this
## fixture satisfies (80 people per cell). The shipped predicate reads building
## data a bootstrapped economy does not have, so a card filtered on it legitimately
## matches NOTHING -- correct behaviour indistinguishable from "the card never
## equipped". `target_tags` must be replaced on the RESOURCE before
## `compile_native_catalog`, never on the compiled Dictionary.
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


# =========================================================================
# world construction
# =========================================================================

## One economy day (day 0, its own input epoch) is committed BEFORE any card
## exists, which is what makes the Economy class-opinion snapshot live -- the
## support gate behind `equip` and `unequip` cannot answer without one
## (`evaluate_support` returns `available = false` until `snapshot.revision != 0`).
##
## `farmer_pop` / `general_pop` are the per-cell populations of the two professions
## the support gate is steered with (world C uses 0 farmer + `POP_C_GENERAL`
## general, which is the negative control). A population of 0 skips that cohort.
func _new_world(catalogs: Dictionary, label: String,
		farmer_pop: int = POP_FARMER,
		general_pop: int = POP_GENERAL) -> Dictionary:
	var country_ir: Dictionary = catalogs["country_ir"]
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot.
	ext.create_entities(CELLS)
	_ext_fill_environment(ext)
	_expect("%s: economy configures" % label,
		bool(ext.configure_economy(country_ir, catalogs["profile"], CELLS, SEED)
			.get("ok", false)))
	_expect("%s: effects configure" % label,
		bool(ext.configure_effects(catalogs["effect_ir"]).get("ok", false)))
	_expect("%s: modifiers configure" % label,
		bool(ext.configure_modifiers(catalogs["mod_ir"], CELLS).get("ok", false)))
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
		"country_ids": PackedStringArray(["country.em.%s" % label]),
		"country_names": PackedStringArray(["Equip Level %s" % label]),
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
	var ideo_cfg: Dictionary = ext.configure_ideologies(catalogs["native_ideology"])
	_expect("%s: ideologies configure" % label, bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg)))

	var owned := 0
	for c in range(CELLS):
		var cs: Dictionary = ext.get_country_cell_summary(c)
		if bool(cs.get("ok", false)) and bool(cs.get("owned", false)):
			owned += 1
	_expect("%s: bootstrap_country registered exactly the intended territory"
		% label, owned == owned_cells.size(), "%d vs %d" % [owned,
			owned_cells.size()])

	# DUPLICATED IMMEDIATELY: `begin_or_reuse_economy_input_epoch` returns a
	# Dictionary that shares storage with the runtime's cached input-capture
	# report (`world_ext_economy.cpp:680`), which the next `run_economy_slice` for
	# the same day rewrites in place.
	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1,
		"resource_generation": 1}).duplicate(true)
	_expect("%s: the economy input epoch for day 0 opens" % label,
		bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))

	var econ_catalog: Dictionary = catalogs["economy_catalog"]
	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys",
		PackedStringArray())
	var farmer_class: int = sig_keys.find("household_farmer|default")
	var general_class: int = sig_keys.find("subsistence_farmer|default")
	_expect(("%s: the fixture resolves both bootstrap signatures "
		+ "(household_farmer = political class 'farmer', subsistence_farmer = "
		+ "'general')") % label, farmer_class >= 0 and general_class >= 0,
		"household_farmer=%d subsistence_farmer=%d" % [farmer_class,
			general_class])
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
	var ci := PackedInt32Array()
	var si := PackedInt32Array()
	var pp := PackedInt64Array()
	var ff := PackedInt64Array()
	for c in range(CELLS):
		for pair in [[farmer_class, farmer_pop], [general_class, general_pop]]:
			if int(pair[1]) <= 0:
				continue
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
	_expect("%s: the economy bootstraps (farmer %d + general %d per cell)"
		% [label, farmer_pop, general_pop], bool(eb.get("ok", false)), str(eb))
	var slices := _advance_economy_day(ext, 0, label)
	_expect("%s: economy day 0 reaches its committed boundary" % label,
		slices > 0, str(slices))

	var handle := int(ext.get_country_cell_summary(owned_cells[0]).get(
		"country_handle", 0))
	_expect("%s: the fixture resolves the country handle" % label, handle != 0,
		str(handle))
	return {"label": label, "ext": ext, "handle": handle,
		"owned": owned_cells.size(), "owned_cells": owned_cells}


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


# =========================================================================
# ideology commands
# =========================================================================

## One single-row command batch. `sequences` is the idempotency key and must be
## monotonic ACROSS batches, so it comes from one counter.
func _submit(ext: Object, op: int, day: int, idea: int, value_q16: int,
		handle: int, label: String) -> int:
	_seq += 1
	var batch := {
		"opcodes": PackedInt32Array([op]),
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
	}
	var result: Dictionary = ext.submit_ideology_commands(batch)
	_expect("%s: command seq %d (opcode %d) is admitted by the queue"
		% [label, _seq, op], bool(result.get("ok", false))
		and int(result.get("accepted", 0)) == 1, str(result))
	return _seq


## The receipt the runtime wrote for one sequence. The reason text is the whole
## diagnosis of a refusal, so every guard assertion reads it rather than inferring
## from the state.
func _receipt(ext: Object, sequence: int) -> Dictionary:
	var polled: Dictionary = ext.poll_ideology_receipts(0, 4096)
	var sequences: PackedInt64Array = polled.get("sequences", PackedInt64Array())
	var statuses: PackedInt32Array = polled.get("statuses", PackedInt32Array())
	var opcodes: PackedInt32Array = polled.get("opcodes", PackedInt32Array())
	var reasons: PackedStringArray = polled.get("reasons", PackedStringArray())
	var found := {}
	for i in range(sequences.size()):
		if int(sequences[i]) != sequence:
			continue
		found = {
			"status": int(statuses[i]) if i < statuses.size() else 0,
			"opcode": int(opcodes[i]) if i < opcodes.size() else -1,
			"reason": String(reasons[i]) if i < reasons.size() else "",
		}
	return found


# =========================================================================
# advancing
# =========================================================================

## One ideology day, driven to completion. `run_ideology_daily` is a SLICE stage: a
## single call may come back `done=false` with the day (or the derived rebuild)
## still in progress, so looping on the runtime's own `done` flag is what lets this
## fixture wait honestly instead of guessing a call count.
func _run_one_ideology_day(ext: Object, day: int, label: String) -> bool:
	var done := false
	var last := {}
	for _i in range(MAX_SLICES):
		last = ext.run_ideology_daily(day)
		if not bool(last.get("ok", true)):
			_expect("%s: ideology day %d reports ok" % [label, day], false, str(last))
			return false
		if bool(last.get("done", false)):
			done = true
			break
	_expect("%s: ideology day %d completes" % [label, day], done, str(last))
	return done


func _advance_economy_day(ext: Object, day: int, label: String) -> int:
	for s in range(4096):
		var r: Dictionary = ext.run_economy_slice({"day_index": day, "tick_index": s})
		if bool(r.get("fatal", false)):
			_expect("%s: economy day %d stays non-fatal" % [label, day], false,
				str(r.get("fatal_reason", r)))
			return s
		if bool(r.get("done", false)):
			return s + 1
	_expect("%s: economy day %d completes" % [label, day], false, "4096 slices")
	return 0


# =========================================================================
# probes
# =========================================================================

## The production read shape: entity_handle 0 and the CELL in the group slot,
## which is the pair `economy_runtime_family_buff.cpp` passes.
func _probe(ext: Object, stat: String, cell: int) -> Dictionary:
	return ext.get_effective_stat_value(stat, cell, 0, 1.0)


func _probe_all(ext: Object, stat: String) -> Dictionary:
	var present := PackedByteArray()
	present.resize(CELLS)
	var add := PackedFloat64Array()
	add.resize(CELLS)
	var value := PackedFloat64Array()
	value.resize(CELLS)
	for c in range(CELLS):
		var probe: Dictionary = _probe(ext, stat, c)
		if not bool(probe.get("ok", false)):
			continue
		present[c] = 1 if bool(probe.get("derived_present", false)) else 0
		add[c] = float(probe.get("derived_add", 0.0))
		value[c] = float(probe.get("value", 1.0))
	return {"present": present, "add": add, "value": value}


func _present_count(ext: Object, stat: String) -> int:
	var count := 0
	for c in range(CELLS):
		if bool(_probe(ext, stat, c).get("derived_present", false)):
			count += 1
	return count


## True when EVERY cell of the requested group (owned when `want_owned = true`,
## unowned when `false`) has exactly the derived presence that group implies.
func _all_cells_present(ext: Object, stat: String, owned_cells: PackedInt32Array,
		want_owned: bool) -> bool:
	for c in range(CELLS):
		if owned_cells.has(c) != want_owned:
			continue
		if bool(_probe(ext, stat, c).get("derived_present", false)) != want_owned:
			return false
	return true


## True when NO unowned cell carries a contribution (the owned cells are covered
## by `_all_cells_present(..., true)`).
func _no_unowned_present(ext: Object, stat: String,
		owned_cells: PackedInt32Array) -> bool:
	for c in range(CELLS):
		if owned_cells.has(c):
			continue
		if bool(_probe(ext, stat, c).get("derived_present", false)):
			return false
	return true


## The add every covered cell must carry, taken from the first cell that reports a
## contribution -- used to compare one LEVEL's content against another's.
func _covered_add(ext: Object, stat: String) -> float:
	return _covered_add_of(_probe_all(ext, stat))


## Same, for a probe row already captured.
func _covered_add_of(row: Dictionary) -> float:
	var present: PackedByteArray = row["present"]
	for c in range(present.size()):
		if present[c] != 0:
			return float((row["add"] as PackedFloat64Array)[c])
	return 0.0


## The front's contribution count, with the ONE structural caveat made explicit:
## `get_derived_cell_layer_report` returns EARLY when no front is installed and
## never writes `contribution_count` in that branch
## (`world_ext_modifier.cpp:1082-1086`), so the empty front's contribution count is
## absent rather than 0. Reading it as 0 is the correct interpretation: the report
## it means is "the front holds no rows at all", which `installed` and `cell_count`
## state independently.
func _front_contributions(layer: Dictionary) -> int:
	if not layer.has("contribution_count"):
		return 0
	return int(layer.get("contribution_count", 0))


## The raw `contribution_count` field for a log line, spelled out when the report
## omitted it, so a reader is not left guessing what the missing key meant.
func _front_text(layer: Dictionary) -> String:
	if not layer.has("contribution_count"):
		return "absent (no front installed)"
	return str(layer.get("contribution_count"))


func _program_magnitude(ext: Object, program_key: String, label: String) -> float:
	var metrics := PackedInt64Array()
	metrics.resize(METRIC_SLOTS)
	metrics.fill(0)
	var interp: Dictionary = ext.evaluate_effect_program_magnitude(program_key, metrics)
	var magnitude := float(int(interp.get("magnitude", 0))) / float(Q16_ONE)
	print("[EM] program %s (%s): ok=%s magnitude_q16=%s -> %.8f"
		% [program_key, label, str(interp.get("ok", "?")),
			str(interp.get("magnitude", "?")), magnitude])
	return magnitude


# =========================================================================
# printing + bookkeeping
# =========================================================================

func _print_state(tag: String, snap: Dictionary, layer: Dictionary,
		report: Dictionary) -> void:
	print("[EM] %s: locations=%s levels=%s understanding=%s slots_used=%s/%s"
		% [tag, str(snap.get("locations", "?")), str(snap.get("levels", "?")),
			str(snap.get("understanding_q16", "?")),
			str(snap.get("ideology_slots_used", "?")),
			str(snap.get("ideology_slots_capacity", "?"))])
	print("[EM] %s: pending_transitions=%s pending_commands=%s commands_applied=%s "
		% [tag, str(report.get("pending_transitions", "?")),
			str(report.get("pending_commands", "?")),
			str(report.get("commands_applied", "?"))]
		+ "levels_advanced=%s commands_rejected=%s"
		% [str(report.get("levels_advanced", "?")),
			str(report.get("commands_rejected", "?"))])
	print("[EM] %s: front installed=%s cells=%s contributions=%s stats=%s "
		% [tag, str(layer.get("installed", "?")),
			str(layer.get("cell_count", "?")),
			_front_text(layer),
			str(layer.get("stat_count", "?")),]
		+ "generation=%s sample_day=%s"
		% [str(layer.get("layer_generation", "?")),
			str(layer.get("sample_day", "?"))])


## The plan-9.3 basis dates and the gate counter, printed on EVERY read taken within
## one day of a settle. That is the whole point of the fourth phase: `confirmed_day`,
## `eligible_day` and `gated_by_eligibility` answer "why is the front not installed
## yet" from the report instead of from the C++ source.
func _print_basis(tag: String, report: Dictionary) -> void:
	print("[EM] %s basis: confirmed_day=%s eligible_day=%s "
		% [tag, str(report.get("derived_basis_confirmed_day", "?")),
			str(report.get("derived_basis_eligible_day", "?"))]
		+ "gated_by_eligibility=%s rebuild_visits=%s pending=%s"
		% [str(report.get("derived_rebuild_gated_by_eligibility", "?")),
			str(report.get("cell_layer_rebuild_visits", "?")),
			str(report.get("derived_rebuild_pending", "?"))])


## The class-opinion numbers behind the equip/unequip support gate, printed rather
## than assumed: `support_q16` / threshold / allowed per direction, plus the
## influence of every class named by the card's stances.
func _print_support(tag: String, explain: Dictionary) -> void:
	print("[EM] %s support: adopt=%s repeal=%s promote=%s (thresholds %s)"
		% [tag, str((explain.get("support_q16", PackedInt32Array())
			as PackedInt32Array)[0]), str((explain.get("support_q16",
			PackedInt32Array()) as PackedInt32Array)[1]),
			str((explain.get("support_q16", PackedInt32Array())
			as PackedInt32Array)[2]), str(explain.get("support_thresholds_q16", "?"))])
	print("[EM] %s support: allowed=%s available=%s blocking=%s revision=%s"
		% [tag, str(explain.get("support_allowed", "?")),
			str(explain.get("support_available", "?")),
			str(explain.get("support_blocking_classes", "?")),
			str(explain.get("support_revision", "?"))])
	print("[EM] %s support: class_influence=%s repeal_stances=%s"
		% [tag, str(explain.get("class_influence", "?")),
			str(explain.get("repeal_stances_q16", "?"))])


## Every check is printed, pass or fail: the evidence is the LIST of things that
## were asserted, and a log that only shows failures cannot tell a reader whether
## the mechanism was exercised at all.
func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	print("  [FAIL] %s %s" % [label, detail])
	printerr("FAIL %s %s" % [label, detail])


func _finish() -> void:
	print("[EM] ---- summary ----")
	for line in _summary:
		print("[EM] %s" % String(line))
	print("=== ideology mechanism: equip/unequip + level advancement: "
		+ "%d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
